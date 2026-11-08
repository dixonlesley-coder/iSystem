/// Electrical canvases — drafting-feel batch (interaction + frame cost).
///
/// Pins, on the single-line canvas:
///  * E2 — a board drag / arrow nudge is a SCHEMATIC (x/y) move the engine
///    never reads, so it re-runs the electrical solve ZERO times;
///  * E4 — a pan frame rebuilds no board-schedule sheet and repaints no
///    schedule (memoized sheets, reused card subtrees, RepaintBoundary);
///  * K1 — the shared view keys (F / Ctrl +-0 / arrows pan) ease where they
///    should, and hold-Space + left-drag pans instead of marqueeing;
///  * S1 — a board follows the cursor ON the grid during the drag;
///  * V5 — the marquee is a window left-to-right, a crossing right-to-left.
///
/// And on the Layout electrical layer:
///  * E1 — a zoomed-out marker takes pointers over its WHOLE painted box (it
///    used to take them only in its top-left scale x scale corner);
///  * E3 — a marker drag re-solves at most ONCE per gesture (on release), and
///    is one undo step; S1 — the marker steps on the calibrated grid live;
///  * E5 — multi-select (shift-click, marquee, Ctrl+A), group drag, a nudge
///    burst that is one undo step, and multi-delete in one undo step.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/canvas/canvas_grid.dart';
import 'package:mechx/ui/canvas/viewport.dart';
import 'package:mechx/ui/electrical/electrical_canvas.dart';
import 'package:mechx/ui/electrical/electrical_layout_view.dart'
    show kLayoutPanelW, kLayoutPanelH;
import 'package:mechx/ui/electrical/electrical_palette.dart' show PaletteLoad;
import 'package:mechx/ui/electrical/panel_geometry.dart' show kGrid;
import 'package:mechx/ui/electrical/sld_sheet_painter.dart';
import 'package:mechx/ui/layout/electrical_layer.dart';
import 'package:mechx/ui/widgets/palette_card.dart';
import 'package:mechx_engine/electrical/geo_length.dart' show LayoutPos;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';

import 'test_util.dart';

ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MechXApp)),
        listen: false);

// ── Single-line harness ───────────────────────────────────────────────────────

Future<ProviderContainer> _pumpSingleLine(WidgetTester tester) async {
  setDesktopSurface(tester);
  await tester.pumpWidget(const ProviderScope(child: MechXApp()));
  await tester.pump();
  final container = _containerOf(tester);
  container.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
  container
      .read(electricalProjectProvider.notifier)
      .setProject(sampleElectricalProject());
  await tester.pump();
  await tester.pump(); // the one-shot initial fit (post-frame)
  return container;
}

ElectricalCanvasState _canvas(WidgetTester tester) =>
    tester.state<ElectricalCanvasState>(find.byType(ElectricalCanvas));

KeyEventResult _sendKey(WidgetTester tester, LogicalKeyboardKey key,
    {bool up = false}) {
  final focusWidget = tester
      .widgetList<Focus>(find.descendant(
        of: find.byType(ElectricalCanvas),
        matching: find.byType(Focus),
      ))
      .firstWhere((f) => f.onKeyEvent != null);
  final physical = PhysicalKeyboardKey.findKeyByCode(key.keyId) ??
      PhysicalKeyboardKey.keyA;
  final event = up
      ? KeyUpEvent(
          physicalKey: physical, logicalKey: key, timeStamp: Duration.zero)
      : KeyDownEvent(
          physicalKey: physical, logicalKey: key, timeStamp: Duration.zero);
  return focusWidget.onKeyEvent!(focusWidget.focusNode!, event);
}

ElectricalPanel _panel(ProviderContainer c, String id) =>
    c.read(electricalProjectProvider).panels.firstWhere((p) => p.id == id);

Rect _cardRect(WidgetTester tester, String id) =>
    tester.getRect(find.byKey(ValueKey('electrical-card-$id')));

// ── Layout-layer harness ──────────────────────────────────────────────────────

Future<ProviderContainer> _pumpLayoutElectrical(WidgetTester tester) async {
  setDesktopSurface(tester, size: const Size(1440, 900));
  await tester.pumpWidget(const ProviderScope(child: MechXApp()));
  await tester.pump();
  final container = _containerOf(tester);
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

Offset _worldOf(WidgetTester tester, Offset global) =>
    _vt(tester).screenToWorld(global - tester.getRect(_layer).topLeft);

Offset _globalOf(WidgetTester tester, Offset world) =>
    _vt(tester).worldToScreen(world) + tester.getRect(_layer).topLeft;

LayoutPos _at(Offset world) =>
    LayoutPos(sheetId: 's1', floorIndex: 0, x: world.dx, y: world.dy);

/// The layer's own element is a [WidgetRef] (a ConsumerWidget's element).
WidgetRef _layerRef(WidgetTester tester) => tester.element(_layer) as WidgetRef;

Future<void> _dragCardTo(
    WidgetTester tester, String label, Offset globalTarget) async {
  final card = find.ancestor(
    of: find.text(label),
    matching: find.byType(PaletteCard<PaletteLoad>),
  );
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

void main() {
  // ══ Single-line canvas ══════════════════════════════════════════════════════

  testWidgets(
      'E2 + S1 — dragging a board re-solves nothing and the board rides the '
      'grid live; one undo restores it', (tester) async {
    final container = await _pumpSingleLine(tester);
    final before = _panel(container, 'lp1');
    final resultBefore = container.read(electricalResultProvider);
    final solves = debugElectricalSolveCount;

    final rect = _cardRect(tester, 'lp1');
    final gesture = await tester.startGesture(
        Offset(rect.left + rect.width * 0.25, rect.top + rect.height * 0.5));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(13, 7));
      await tester.pump();
      // S1 — mid-drag, the board already sits on the kGrid lattice.
      final mid = _panel(container, 'lp1');
      if (mid.x != null) {
        expect(mid.x! % kGrid, 0, reason: 'live x on the grid');
        expect(mid.y! % kGrid, 0, reason: 'live y on the grid');
      }
    }
    await gesture.up();
    await tester.pump();

    final after = _panel(container, 'lp1');
    expect(after.x, isNotNull);
    expect(after.x != before.x || after.y != before.y, isTrue,
        reason: 'the board moved');
    expect(debugElectricalSolveCount, solves,
        reason: 'a schematic x/y move never re-runs computeSystem');
    expect(identical(container.read(electricalResultProvider), resultBefore),
        isTrue);

    // An arrow-key nudge is a schematic move too.
    expect(_canvas(tester).selectedPanelIds, {'lp1'});
    _sendKey(tester, LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(_panel(container, 'lp1').x, after.x! + kGrid);
    expect(debugElectricalSolveCount, solves);

    // Undo the nudge, then the drag (each ONE step).
    container.read(historyProvider.notifier).undo();
    container.read(historyProvider.notifier).undo();
    await tester.pump();
    expect(_panel(container, 'lp1').x, before.x);
    expect(_panel(container, 'lp1').y, before.y);
  });

  testWidgets(
      'E4 — panning across 10 frames at the schedule LOD builds no board '
      'schedule and repaints none', (tester) async {
    await _pumpSingleLine(tester);
    final state = _canvas(tester);
    state.focusPanelSchedule('mdp');
    await tester.pump();
    await tester.pump();
    expect(state.currentScale, greaterThanOrEqualTo(kLodThreshold));
    expect(debugCanvasPanelDetailBuildCount, greaterThan(0),
        reason: 'the schedule tier is really on screen');

    debugCanvasPanelDetailBuildCount = 0;
    debugBoardSchedulePaintCount = 0;
    final start = state.transform.offset;
    for (var i = 0; i < 10; i++) {
      // Nothing selected ⇒ an arrow pans the view (K1).
      expect(_sendKey(tester, LogicalKeyboardKey.arrowLeft),
          KeyEventResult.handled);
      await tester.pump();
    }
    expect(state.transform.offset, start + const Offset(640, 0),
        reason: '10 immediate 64 px pans');
    expect(debugCanvasPanelDetailBuildCount, 0);
    expect(debugBoardSchedulePaintCount, 0);
  });

  testWidgets(
      'K1 — F fits (eased), Ctrl+= zooms 1.2x about the centre (eased), '
      'Ctrl+0 is 100 %', (tester) async {
    await _pumpSingleLine(tester);
    final state = _canvas(tester);
    final fitted = state.transform;
    // Move away, then F eases back to the fit.
    state.zoomIn();
    await tester.pump();
    expect(state.transform, isNot(fitted));
    expect(_sendKey(tester, LogicalKeyboardKey.keyF), KeyEventResult.handled);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(state.transform.scale, isNot(closeTo(fitted.scale, 1e-9)),
        reason: 'mid-ease, not a jump');
    await tester.pumpAndSettle();
    expect(state.transform.scale, closeTo(fitted.scale, 1e-9));
    expect(state.transform.offset.dx, closeTo(fitted.offset.dx, 1e-6));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    _sendKey(tester, LogicalKeyboardKey.equal);
    await tester.pumpAndSettle();
    expect(state.transform.scale, closeTo(fitted.scale * 1.2, 1e-9));
    _sendKey(tester, LogicalKeyboardKey.digit0);
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(state.transform.scale, 1.0);
  });

  testWidgets('K1 — with reduced motion the zoom buttons land at once',
      (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _pumpSingleLine(tester);
    final state = _canvas(tester);
    final s0 = state.transform.scale;
    state.zoomIn(animate: true);
    await tester.pump();
    expect(state.transform.scale, closeTo(s0 * 1.2, 1e-9));
  });

  testWidgets(
      'K1 — hold Space + left-drag pans (no marquee, no board moved); the '
      'cursor is the grab hand while held', (tester) async {
    final container = await _pumpSingleLine(tester);
    final state = _canvas(tester);
    final project = container.read(electricalProjectProvider);
    final start = state.transform.offset;
    expect(_sendKey(tester, LogicalKeyboardKey.space), KeyEventResult.handled);
    await tester.pump();

    // Start ON a board: Space-drag must still pan, never move the board.
    final rect = _cardRect(tester, 'mdp');
    final gesture = await tester.startGesture(rect.center,
        kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
    await tester.pump();
    await gesture.moveBy(const Offset(40, 30));
    await tester.pump();
    await gesture.moveBy(const Offset(20, 10));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    _sendKey(tester, LogicalKeyboardKey.space, up: true);
    await tester.pump();

    expect(state.transform.offset, start + const Offset(60, 40));
    expect(identical(container.read(electricalProjectProvider), project),
        isTrue, reason: 'no board moved');
    expect(state.selectedPanelIds, isEmpty, reason: 'no marquee selection');
  });

  testWidgets(
      'V5 — a left-to-right marquee takes only fully-enclosed boards; the '
      'same box right-to-left takes any it touches', (tester) async {
    await _pumpSingleLine(tester);
    final state = _canvas(tester);
    final card = _cardRect(tester, 'mdp');
    // A box covering the LEFT half of the MDP card only, starting on blank
    // canvas above-left of it.
    final a = Offset(card.left - 30, card.top - 30);
    final b = Offset(card.left + card.width * 0.5, card.bottom + 10);

    Future<void> sweep(Offset from, Offset to) async {
      final g = await tester.startGesture(from,
          kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
      await tester.pump();
      await g.moveTo(Offset.lerp(from, to, 0.5)!);
      await tester.pump();
      await g.moveTo(to);
      await tester.pump();
      await g.up();
      await tester.pump();
    }

    await sweep(a, b); // window
    expect(state.selectedPanelIds.contains('mdp'), isFalse);
    // Crossing: start at the right (blank below the card), drag left.
    await sweep(Offset(b.dx, card.bottom + 30), Offset(a.dx, card.top - 30));
    expect(state.selectedPanelIds.contains('mdp'), isTrue);
  });

  // ══ Layout electrical layer ═════════════════════════════════════════════════

  testWidgets(
      'E1 — at 0.4x a marker takes a tap AND a palette drop at its '
      'bottom-right, not only its top-left corner', (tester) async {
    final container = await _pumpLayoutElectrical(tester);
    final ctrl = container.read(electricalProjectProvider.notifier);
    final mdp = ctrl.addPanelAt(name: 'MDP', tag: 'MDP', x: 0, y: 0);
    container
        .read(sheetsControllerProvider.notifier)
        .setViewport('s1', const ViewportTransform(scale: 0.4));
    await tester.pump();
    expect(_vt(tester).scale, 0.4);

    final layerRect = tester.getRect(_layer);
    final centre = Offset(layerRect.left + layerRect.width * 0.4,
        layerRect.top + layerRect.height * 0.4);
    ctrl.setPanelLayoutPos(mdp, _at(_worldOf(tester, centre)));
    await tester.pump();

    // Bottom-right corner region of the 150 x 56 marker, at 0.4x.
    final corner = centre +
        const Offset(kLayoutPanelW * 0.4 / 2 - 4, kLayoutPanelH * 0.4 / 2 - 3);
    await tester.tapAt(corner);
    await tester.pump(const Duration(milliseconds: 400));
    expect(container.read(electricalSelectionProvider)?.panelId, mdp);

    final waysBefore = _panel(container, mdp).circuits.length;
    await _dragCardTo(tester, 'Lighting', corner);
    final after = _panel(container, mdp);
    expect(after.circuits.length, waysBefore + 1,
        reason: 'the drop landed ON the marker (a way on that board)');
    expect(after.circuits.last.loadPos, isNotNull);
  });

  testWidgets(
      'E3 + S1 — a marker drag re-solves at most once (on release), steps on '
      'the calibrated grid live, and is one undo step', (tester) async {
    final container = await _pumpLayoutElectrical(tester);
    final ctrl = container.read(electricalProjectProvider.notifier);
    final mdp = ctrl.addPanelAt(name: 'MDP', tag: 'MDP', x: 0, y: 0);
    final layerRect = tester.getRect(_layer);
    final markerGlobal = Offset(layerRect.left + layerRect.width * 0.35,
        layerRect.top + layerRect.height * 0.35);
    final world0 = _worldOf(tester, markerGlobal);
    ctrl.setPanelLayoutPos(mdp, _at(world0));
    final wayId = ctrl.addLoadAtLayout(mdp,
        kind: LoadKind.lighting,
        pos: _at(world0 + const Offset(600, 0)));
    await tester.pump();
    double runM() => container
        .read(electricalResultProvider)
        .panels[mdp]!
        .circuits
        .firstWhere((c) => c.circuitId == wayId)
        .lengthM;
    final len0 = runM();
    final step = calibratedGridWorldStep(0.01);

    final solves = debugElectricalSolveCount;
    final gesture = await tester.startGesture(markerGlobal);
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(-37, 11));
      await tester.pump();
      runM(); // a reader mid-drag must not force a re-solve either
      // The first move only crosses the drag slop (no update yet).
      if (i == 0) continue;
      final p = _panel(container, mdp).layoutPos!;
      expect((p.x / step - (p.x / step).round()).abs(), lessThan(1e-9),
          reason: 'live x on the calibrated grid');
    }
    expect(debugElectricalSolveCount, solves,
        reason: 'no re-solve while the marker is dragged');
    await gesture.up();
    await tester.pump();
    expect(runM(), isNot(closeTo(len0, 1e-9)),
        reason: 'the geo cable length follows the release');
    expect(debugElectricalSolveCount - solves, lessThanOrEqualTo(1));

    container.read(historyProvider.notifier).undo();
    await tester.pump();
    final back = _panel(container, mdp).layoutPos!;
    expect(back.x, closeTo(world0.dx, 1e-9));
    expect(back.y, closeTo(world0.dy, 1e-9));
    await tester.pump(const Duration(seconds: 4)); // status pill timers
  });

  testWidgets(
      'E5 — shift-click multi-selects; dragging one member moves both; a '
      'nudge burst and a multi-delete are each one undo step', (tester) async {
    final container = await _pumpLayoutElectrical(tester);
    final ctrl = container.read(electricalProjectProvider.notifier);
    final a = ctrl.addPanelAt(name: 'A', tag: 'A', x: 0, y: 0);
    final b = ctrl.addPanelAt(name: 'B', tag: 'B', x: 200, y: 0);
    final layerRect = tester.getRect(_layer);
    final ga = Offset(layerRect.left + layerRect.width * 0.3,
        layerRect.top + layerRect.height * 0.3);
    final gb = ga + const Offset(260, 120);
    ctrl.setPanelLayoutPos(a, _at(_worldOf(tester, ga)));
    ctrl.setPanelLayoutPos(b, _at(_worldOf(tester, gb)));
    await tester.pump();

    await tester.tapAt(ga);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tapAt(gb);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    final sel = container.read(electricalSelectionProvider)!;
    expect(sel.isMulti, isTrue);
    expect(sel.contains(a) && sel.contains(b), isTrue);

    // Group drag: grab A, both move by the same delta.
    final a0 = _panel(container, a).layoutPos!;
    final b0 = _panel(container, b).layoutPos!;
    final g = await tester.startGesture(ga);
    await tester.pump();
    await g.moveBy(const Offset(60, 0));
    await tester.pump();
    await g.moveBy(const Offset(60, 0));
    await tester.pump();
    await g.up();
    await tester.pump();
    final a1 = _panel(container, a).layoutPos!;
    final b1 = _panel(container, b).layoutPos!;
    expect(a1.x - a0.x, greaterThan(0));
    expect(b1.x - b0.x, closeTo(a1.x - a0.x, 1e-9));
    expect(b1.y - b0.y, closeTo(a1.y - a0.y, 1e-9));
    container.read(historyProvider.notifier).undo();
    await tester.pump();
    expect(_panel(container, a).layoutPos!.x, closeTo(a0.x, 1e-9));
    expect(_panel(container, b).layoutPos!.x, closeTo(b0.x, 1e-9));

    // Nudge burst: three presses, ONE undo step back.
    final ref = _layerRef(tester);
    final step = calibratedGridWorldStep(0.01);
    for (var i = 0; i < 3; i++) {
      expect(
          nudgeElectricalSelection(ref, LogicalKeyboardKey.arrowDown,
              sheetId: 's1', floorIndex: 0),
          isTrue);
    }
    await tester.pump();
    expect(_panel(container, a).layoutPos!.y, closeTo(a0.y + 3 * step, 1e-9));
    expect(_panel(container, b).layoutPos!.y, closeTo(b0.y + 3 * step, 1e-9));
    container.read(historyProvider.notifier).undo();
    await tester.pump();
    expect(_panel(container, a).layoutPos!.y, closeTo(a0.y, 1e-9));
    expect(_panel(container, b).layoutPos!.y, closeTo(b0.y, 1e-9));
    // Let the burst's idle window lapse.
    await tester.pump(const Duration(seconds: 1));

    // Multi-delete: both boards go, one undo brings both back.
    expect(
        handleElectricalLayerKey(
            ref,
            const KeyDownEvent(
                physicalKey: PhysicalKeyboardKey.delete,
                logicalKey: LogicalKeyboardKey.delete,
                timeStamp: Duration.zero),
            sheetId: 's1',
            floorIndex: 0),
        isTrue);
    await tester.pump();
    final ids = container.read(electricalProjectProvider).panels.map((p) => p.id);
    expect(ids, isNot(contains(a)));
    expect(ids, isNot(contains(b)));
    container.read(historyProvider.notifier).undo();
    await tester.pump();
    final back = container.read(electricalProjectProvider).panels.map((p) => p.id);
    expect(back, containsAll([a, b]));
  });

  testWidgets(
      'E5 — through the Layout host\'s REAL key routing: arrows nudge the '
      'electrical multi-selection, Delete removes every member', (tester) async {
    final container = await _pumpLayoutElectrical(tester);
    final ctrl = container.read(electricalProjectProvider.notifier);
    final a = ctrl.addPanelAt(name: 'A', tag: 'A', x: 0, y: 0);
    final b = ctrl.addPanelAt(name: 'B', tag: 'B', x: 200, y: 0);
    final layerRect = tester.getRect(_layer);
    final ga = Offset(layerRect.left + layerRect.width * 0.3,
        layerRect.top + layerRect.height * 0.3);
    final gb = ga + const Offset(260, 120);
    ctrl.setPanelLayoutPos(a, _at(_worldOf(tester, ga)));
    ctrl.setPanelLayoutPos(b, _at(_worldOf(tester, gb)));
    await tester.pump();
    await tester.tapAt(ga);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tapAt(gb);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(container.read(electricalSelectionProvider)!.isMulti, isTrue);

    final a0 = _panel(container, a).layoutPos!;
    final b0 = _panel(container, b).layoutPos!;
    final step = calibratedGridWorldStep(0.01);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_panel(container, a).layoutPos!.y, closeTo(a0.y + 2 * step, 1e-9));
    expect(_panel(container, b).layoutPos!.y, closeTo(b0.y + 2 * step, 1e-9));

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    final ids =
        container.read(electricalProjectProvider).panels.map((p) => p.id);
    expect(ids, isNot(contains(a)));
    expect(ids, isNot(contains(b)));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
      'E5 — a blank-plan marquee selects the markers it encloses (window) '
      'and Ctrl+A selects every marker on the sheet', (tester) async {
    final container = await _pumpLayoutElectrical(tester);
    final ctrl = container.read(electricalProjectProvider.notifier);
    final a = ctrl.addPanelAt(name: 'A', tag: 'A', x: 0, y: 0);
    final b = ctrl.addPanelAt(name: 'B', tag: 'B', x: 200, y: 0);
    final layerRect = tester.getRect(_layer);
    final ga = Offset(layerRect.left + layerRect.width * 0.3,
        layerRect.top + layerRect.height * 0.3);
    final gb = ga + const Offset(300, 160);
    ctrl.setPanelLayoutPos(a, _at(_worldOf(tester, ga)));
    ctrl.setPanelLayoutPos(b, _at(_worldOf(tester, gb)));
    await tester.pump();
    final s = _vt(tester).scale;
    final half = Offset(kLayoutPanelW * s / 2 + 12, kLayoutPanelH * s / 2 + 12);

    // Window around A only (left-to-right, from blank plan).
    final g = await tester.startGesture(ga - half,
        kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
    await tester.pump();
    await g.moveTo(ga);
    await tester.pump();
    await g.moveTo(ga + half);
    await tester.pump();
    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
    final sel = container.read(electricalSelectionProvider);
    expect(sel?.panelId, a);
    expect(sel?.isMulti, isFalse);

    selectAllElectricalOnSheet(_layerRef(tester), 's1', 0);
    final all = container.read(electricalSelectionProvider)!;
    expect(all.contains(a) && all.contains(b), isTrue);
    // A blank tap clears it.
    await tester.tapAt(_globalOf(tester, _worldOf(tester, ga) + const Offset(0, 900)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(container.read(electricalSelectionProvider), isNull);
  });

  // ══ Review fixes (Fable) ═══════════════════════════════════════════════════

  testWidgets(
      'a marker drag that snaps back onto its start records NO undo step '
      '(Ctrl+Z still reverts the real edit before it)', (tester) async {
    final container = await _pumpLayoutElectrical(tester);
    final ctrl = container.read(electricalProjectProvider.notifier);
    final mdp = ctrl.addPanelAt(name: 'MDP', tag: 'MDP', x: 0, y: 0);
    final layerRect = tester.getRect(_layer);
    final step = calibratedGridWorldStep(0.01);
    final raw = _worldOf(tester,
        Offset(layerRect.left + layerRect.width * 0.35,
            layerRect.top + layerRect.height * 0.35));
    // Placed exactly on a grid point, so a small drag snaps back to it.
    final onGrid = Offset((raw.dx / step).round() * step,
        (raw.dy / step).round() * step);
    ctrl.setPanelLayoutPos(mdp, _at(onGrid));
    await tester.pump();
    final placed = container.read(electricalProjectProvider);

    final at = _globalOf(tester, onGrid);
    final g = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      await g.moveBy(const Offset(2, 1));
      await tester.pump();
    }
    await g.up();
    await tester.pump();
    expect(identical(container.read(electricalProjectProvider), placed), isTrue,
        reason: 'the drag snapped back: nothing changed');

    container.read(historyProvider.notifier).undo();
    await tester.pump();
    expect(identical(container.read(electricalProjectProvider), placed),
        isFalse,
        reason: 'Ctrl+Z reverted a REAL edit, not a phantom no-move drag step');
    await tester.pump(const Duration(seconds: 4));
  });

  test('a lazy gesture step: nothing written ⇒ no step; several writes ⇒ '
      'ONE step; an abandoned gesture never doubles a later edit', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(electricalProjectProvider.notifier);
    ctrl.setProject(sampleElectricalProject());
    final history = c.read(historyProvider.notifier);
    final p0 = c.read(electricalProjectProvider);

    ctrl.beginUndoableGesture();
    ctrl.endUndoableGesture();
    expect(history.canUndo, isFalse);

    ctrl.beginUndoableGesture();
    ctrl.setPanelPosition('lp1', 100, 100);
    ctrl.setPanelPosition('lp1', 140, 100);
    ctrl.endUndoableGesture();
    history.undo();
    expect(identical(c.read(electricalProjectProvider), p0), isTrue);
    expect(history.canUndo, isFalse, reason: 'exactly one step');

    ctrl.beginUndoableGesture(); // never ended (an abandoned gesture)
    ctrl.setName('Renamed');
    history.undo();
    expect(identical(c.read(electricalProjectProvider), p0), isTrue);
    expect(history.canUndo, isFalse, reason: 'the rename was ONE step');
  });

  test('schematic-move tags stay depth 1: any two frames of one drag are moves '
      'of each other; a real edit breaks the chain', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(electricalProjectProvider.notifier);
    ctrl.setProject(sampleElectricalProject());
    final root = c.read(electricalProjectProvider);
    final frames = <ElectricalProject>[];
    for (var i = 1; i <= 50; i++) {
      ctrl.setPanelPosition('lp1', i * 20.0, 40);
      frames.add(c.read(electricalProjectProvider));
    }
    expect(ctrl.isSchematicMoveOf(frames.last, root), isTrue);
    expect(ctrl.isSchematicMoveOf(frames.last, frames[3]), isTrue);
    ctrl.setName('Edited');
    final edited = c.read(electricalProjectProvider);
    expect(ctrl.isSchematicMoveOf(edited, root), isFalse);
    expect(ctrl.isSchematicMoveOf(edited, frames.last), isFalse);
  });
}
