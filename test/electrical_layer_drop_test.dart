/// The unified Layout canvas's ELECTRICAL layer — drop / snap / feeder / tray
/// contract.
///
/// Regressions pinned here:
///  * a palette card dropped ON a placed board's MARKER used to call
///    `addCircuit`, minting a way with NO `loadPos` — an invisible orphan that
///    only surfaced in the "Not on this sheet" tray. It must now be created
///    ALREADY PLACED beside the marker, with the same sized-result toast the
///    single-line canvas gives;
///  * the drag-preview ring promised an 18-screen-px snap radius while the drop
///    attached to the nearest board at ANY distance — ring and drop now share
///    one rule, and beyond it the honest floating-load stub applies;
///  * the blank-sheet sub-board drop minted its designation from
///    `panels.length + 1`, which re-issues a tag a surviving board already
///    carries once an earlier board is deleted;
///  * the layer had no way to create a FEEDER at all (the plan could only be
///    wired by leaving for the single-line view);
///  * the tray hid the ways of UNPLACED boards, and had no way to clean up an
///    empty stub board.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/canvas/viewport.dart';
import 'package:mechx/ui/electrical/electrical_layout_view.dart'
    show kLayoutPanelW;
import 'package:mechx/ui/electrical/electrical_palette.dart' show PaletteLoad;
import 'package:mechx/ui/layout/electrical_layer.dart';
import 'package:mechx/ui/widgets/palette_card.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/geo_length.dart' show LayoutPos;
import 'package:mechx_engine/geometry/scale_calibration.dart';

import 'test_util.dart';

// ── Harness ──────────────────────────────────────────────────────────────────

/// Pump the app onto the unified Layout workspace with the ELECTRICAL
/// discipline active and sheet `s1` calibrated (so geo cable lengths resolve).
Future<ProviderContainer> _pumpLayoutElectrical(WidgetTester tester) async {
  setDesktopSurface(tester, size: const Size(1440, 900));
  await tester.pumpWidget(const ProviderScope(child: MechXApp()));
  await tester.pump();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MechXApp)),
    listen: false,
  );
  seedDemoSheets(container);
  container
      .read(projectControllerProvider.notifier)
      .setCalibration('s1', const ScaleCalibration(0.01));
  container.read(workspaceViewProvider.notifier).set(WorkspaceView.plan);
  container
      .read(activeDisciplineProvider.notifier)
      .set(DisciplineLayer.electrical);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.byType(ElectricalLayoutLayer), findsOneWidget);
  return container;
}

Finder get _layer => find.byType(ElectricalLayoutLayer);

ViewportTransform _vt(WidgetTester tester) =>
    tester.widget<ElectricalLayoutLayer>(_layer).transform;

/// GLOBAL (test) coordinates ⇒ the world point under them.
Offset _worldOf(WidgetTester tester, Offset global) =>
    _vt(tester).screenToWorld(global - tester.getRect(_layer).topLeft);

Finder _paletteCard(String label) => find.ancestor(
      of: find.text(label),
      matching: find.byType(PaletteCard<PaletteLoad>),
    );

/// Drag the Loads-palette card labelled [label] onto [globalTarget].
Future<void> _dragCardTo(
    WidgetTester tester, String label, Offset globalTarget) async {
  final card = _paletteCard(label);
  expect(card, findsOneWidget, reason: 'palette card "$label"');
  await tester.ensureVisible(card);
  await tester.pumpAndSettle();
  final from = tester.getCenter(card);
  final gesture = await tester.startGesture(from);
  await tester.pump(const Duration(milliseconds: 20));
  await gesture.moveTo(Offset(
    (from.dx + globalTarget.dx) / 2,
    (from.dy + globalTarget.dy) / 2,
  ));
  await tester.pump(const Duration(milliseconds: 20));
  await gesture.moveTo(globalTarget);
  await tester.pump(const Duration(milliseconds: 20));
  await gesture.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
}

/// Place [panelId] so its marker centres on [global], returning that world pos.
Offset _placeAt(
  WidgetTester tester,
  ProviderContainer container,
  String panelId,
  Offset global,
) {
  final world = _worldOf(tester, global);
  container.read(electricalProjectProvider.notifier).setPanelLayoutPos(
        panelId,
        LayoutPos(
            sheetId: 's1', floorIndex: 0, x: world.dx, y: world.dy),
      );
  return world;
}

ElectricalPanel _panel(ProviderContainer c, String id) =>
    c.read(electricalProjectProvider).panels.firstWhere((p) => p.id == id);

void main() {
  testWidgets(
      'a palette card dropped ON a placed board becomes a PLACED way on that '
      'board (not an unplaced orphan) and toasts its sized breaker',
      (tester) async {
    final container = await _pumpLayoutElectrical(tester);
    final ctrl = container.read(electricalProjectProvider.notifier);
    final mdp = ctrl.addPanelAt(name: 'MDP', tag: 'MDP', x: 0, y: 0);
    await tester.pump();

    final layerRect = tester.getRect(_layer);
    final markerGlobal = Offset(
      layerRect.left + layerRect.width * 0.35,
      layerRect.top + layerRect.height * 0.3,
    );
    _placeAt(tester, container, mdp, markerGlobal);
    await tester.pump();
    expect(find.text('MDP'), findsWidgets, reason: 'the marker is on the plan');

    await _dragCardTo(tester, 'Lighting', markerGlobal);

    final panel = _panel(container, mdp);
    expect(panel.circuits, hasLength(1),
        reason: 'the drop should add exactly one way to the board');
    final added = panel.circuits.single;
    expect(added.loadPos, isNotNull,
        reason: 'REGRESSION: a marker drop used to mint an UNPLACED way');
    expect(added.loadPos!.sheetId, 's1');
    expect(added.loadPos!.floorIndex, 0);
    // Beside the marker, never on top of it.
    expect(added.loadPos!.x, greaterThan(panel.layoutPos!.x));

    expect(container.read(statusMessageProvider), isNotNull);
    expect(container.read(statusMessageProvider), contains('MCB'));
    expect(container.read(statusMessageProvider), contains('MDP'));
  });

  testWidgets(
      'a blank-plan drop BEYOND the snap radius makes a floating stub, and one '
      'within it joins that board', (tester) async {
    final container = await _pumpLayoutElectrical(tester);
    final ctrl = container.read(electricalProjectProvider.notifier);
    final mdp = ctrl.addPanelAt(name: 'MDP', tag: 'MDP', x: 0, y: 0);
    await tester.pump();

    final layerRect = tester.getRect(_layer);
    final markerGlobal = Offset(
      layerRect.left + layerRect.width * 0.3,
      layerRect.top + layerRect.height * 0.2,
    );
    _placeAt(tester, container, mdp, markerGlobal);
    await tester.pump();

    // ── Far from every board: an honest floating LOAD stub, not a silent join ──
    await _dragCardTo(tester, 'Lighting', markerGlobal + const Offset(0, 330));

    expect(_panel(container, mdp).circuits, isEmpty,
        reason: 'REGRESSION: the drop used to attach to the nearest board at '
            'ANY distance, even one the preview ring never highlighted');
    final stubs = container
        .read(electricalProjectProvider)
        .panels
        .where((p) => p.id != mdp)
        .toList();
    expect(stubs, hasLength(1), reason: 'a floating stub board is created');
    expect(stubs.single.layoutPos, isNull,
        reason: 'the stub board itself stays unplaced — only its load is on '
            'the plan');
    expect(stubs.single.circuits.single.loadPos, isNotNull);

    // ── Within the ring's own radius: the way joins that board ────────────────
    await _dragCardTo(tester, 'Sockets', markerGlobal + const Offset(5, 0));

    final joined = _panel(container, mdp);
    expect(joined.circuits, hasLength(1),
        reason: 'a drop inside the highlighted radius attaches to that board');
    expect(joined.circuits.single.loadPos, isNotNull);
  });

  testWidgets(
      'a sub-board drop mints the next FREE designation — it never re-issues a '
      'tag a surviving board already carries', (tester) async {
    final container = await _pumpLayoutElectrical(tester);
    final ctrl = container.read(electricalProjectProvider.notifier);
    // Drive the store directly for the setup: three minted boards, the middle
    // one then deleted (the classic "SP-2 was scrapped" project).
    ctrl.addPanelAt(name: 'Sub-panel 1', tag: 'SP-1', x: 0, y: 0);
    final sp2 = ctrl.addPanelAt(name: 'Sub-panel 2', tag: 'SP-2', x: 0, y: 0);
    ctrl.addPanelAt(name: 'Sub-panel 3', tag: 'SP-3', x: 0, y: 0);
    ctrl.deletePanel(sp2);
    await tester.pump();

    final layerRect = tester.getRect(_layer);
    await _dragCardTo(
      tester,
      'Sub-panel',
      Offset(layerRect.left + layerRect.width * 0.4,
          layerRect.top + layerRect.height * 0.55),
    );

    final tags = [
      for (final p in container.read(electricalProjectProvider).panels)
        if (p.tag != null) p.tag!,
    ];
    expect(tags.toSet().length, tags.length,
        reason: 'REGRESSION: `panels.length + 1` re-minted SP-3, duplicating '
            'the surviving board of that designation');
    expect(tags, containsAll(<String>['SP-1', 'SP-3', 'SP-4']));
    expect(tags, isNot(contains('SP-2')),
        reason: 'a scrapped designation is never reused');
  });

  testWidgets(
      "the selected board's outlet grip drags a FEEDER onto another placed "
      'board, and its length comes from the plan geometry', (tester) async {
    final container = await _pumpLayoutElectrical(tester);
    final ctrl = container.read(electricalProjectProvider.notifier);
    final mdp = ctrl.addPanelAt(name: 'MDP', tag: 'MDP', x: 0, y: 0);
    final sub = ctrl.addPanelAt(name: 'Sub-panel 1', tag: 'SP-1', x: 0, y: 0);
    await tester.pump();

    final layerRect = tester.getRect(_layer);
    final fromGlobal = Offset(
      layerRect.left + layerRect.width * 0.25,
      layerRect.top + layerRect.height * 0.35,
    );
    final toGlobal = Offset(
      layerRect.left + layerRect.width * 0.68,
      layerRect.top + layerRect.height * 0.35,
    );
    _placeAt(tester, container, mdp, fromGlobal);
    _placeAt(tester, container, sub, toGlobal);
    await tester.pump();

    // No selection ⇒ no grip (the at-rest canvas is untouched).
    expect(
      find.bySemanticsLabel('Feeder outlet — drag onto a board to feed it'),
      findsNothing,
    );

    container.read(electricalSelectionProvider.notifier).selectPanel(mdp);
    await tester.pump();

    // The grip hangs off the marker's RIGHT edge, outside its hit rect.
    final scale = _vt(tester).scale;
    final grip = fromGlobal +
        Offset(kLayoutPanelW * scale / 2 + 3 + 10, 0);

    final gesture = await tester.startGesture(grip);
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveTo(Offset((grip.dx + toGlobal.dx) / 2, grip.dy));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveTo(toGlobal);
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.up();
    await tester.pump();

    final parent = _panel(container, mdp);
    final feeder =
        parent.circuits.where((c) => c.feedsPanelId == sub).firstOrNull;
    expect(feeder, isNotNull,
        reason: 'releasing the grip over a board should feed it');
    expect(_panel(container, sub).fedByCircuitId, feeder!.id);
    expect(container.read(statusMessageProvider), contains('SP-1 fed from MDP'));

    // The wiring the layer draws carries the engine's GEO length — the same
    // figure `_WiringPainter` labels the feeder with.
    final sized = container
        .read(electricalResultProvider)
        .panels[mdp]
        ?.circuits
        .where((c) => c.circuitId == feeder.id)
        .firstOrNull;
    expect(sized, isNotNull);
    expect(sized!.lengthM, greaterThan(0),
        reason: 'the feeder run length is derived from the two placements');
  });

  testWidgets(
      'the tray lists the ways of an UNPLACED board (named by its parent), and '
      'dragging one out places the LOAD while its board stays unplaced',
      (tester) async {
    final container = await _pumpLayoutElectrical(tester);
    final ctrl = container.read(electricalProjectProvider.notifier);
    final sub = ctrl.addPanelAt(name: 'Sub-panel 1', tag: 'SP-1', x: 0, y: 0);
    final circuitId = ctrl.addCircuit(sub, kind: LoadKind.lighting);
    await tester.pump();

    final chip = find.descendant(
      of: _layer,
      matching: find.textContaining('SP-1 · '),
    );
    expect(chip, findsOneWidget,
        reason: 'REGRESSION: ways of an unplaced board were hidden from the '
            'tray entirely');

    final layerRect = tester.getRect(_layer);
    final target = Offset(
      layerRect.left + layerRect.width * 0.35,
      layerRect.top + layerRect.height * 0.6,
    );
    final from = tester.getCenter(chip);
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 20));
    await gesture
        .moveTo(Offset((from.dx + target.dx) / 2, (from.dy + target.dy) / 2));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveTo(target);
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.up();
    await tester.pump();

    final panel = _panel(container, sub);
    expect(panel.circuits.firstWhere((c) => c.id == circuitId).loadPos,
        isNotNull,
        reason: 'dragging the chip out places the LOAD');
    expect(panel.layoutPos, isNull,
        reason: 'its board is still unplaced — that is the honest model');
  });

  testWidgets('an EMPTY unplaced stub board can be removed from the tray',
      (tester) async {
    final container = await _pumpLayoutElectrical(tester);
    final ctrl = container.read(electricalProjectProvider.notifier);
    final stub = ctrl.addPanelAt(name: 'Sub-panel 1', tag: 'SP-1', x: 0, y: 0);
    // A board that DOES carry ways gets no remove affordance — deleting real
    // work must not hide behind a chip glyph.
    final real = ctrl.addPanelAt(name: 'Sub-panel 2', tag: 'SP-2', x: 0, y: 0);
    ctrl.addCircuit(real, kind: LoadKind.lighting);
    await tester.pump();

    final remove = find.descendant(of: _layer, matching: find.text('×'));
    expect(remove, findsOneWidget,
        reason: 'only the EMPTY stub offers a remove affordance');

    await tester.tap(remove);
    await tester.pump();

    expect(
      container.read(electricalProjectProvider).panels.map((p) => p.id),
      isNot(contains(stub)),
    );
    expect(
      container.read(electricalProjectProvider).panels.map((p) => p.id),
      contains(real),
    );
    expect(container.read(statusMessageProvider), contains('SP-1 removed.'));
  });
}
