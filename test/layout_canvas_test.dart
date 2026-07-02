import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show EditableText;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/calibration_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/canvas/calibration_overlay.dart';
import 'package:mechx/ui/canvas/canvas_grid.dart';
import 'package:mechx/ui/canvas/network_layer.dart';
import 'package:mechx/ui/canvas/viewport.dart';
import 'package:mechx/ui/electrical/electrical_palette.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx/ui/layout/layout_canvas.dart';
import 'package:mechx/ui/layout/layer_switcher.dart';
import 'package:mechx/ui/shell/nav_rail.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/network/network.dart';

import 'test_util.dart';

/// The unified Layout canvas: the shared PDF with plumbing · HVAC · electrical
/// layers, a working active-layer switcher + visibility toggles + fading.
Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final sans = FontLoader('Roboto')
    ..addFont(bytes('assets/fonts/Roboto-Regular.ttf'))
    ..addFont(bytes('assets/fonts/Roboto-Medium.ttf'));
  await sans.load();
  final mono = FontLoader('Roboto Mono')
    ..addFont(bytes('assets/fonts/RobotoMono-Regular.ttf'));
  await mono.load();
}

ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );

void main() {
  setUpAll(_loadFonts);

  testWidgets('the Layout design view renders the unified canvas + switcher',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    // Default boot is the Layout design view.
    final c = _containerOf(tester);
    expect(c.read(workspaceViewProvider), WorkspaceView.plan);
    expect(find.byType(LayoutCanvas), findsOneWidget);
    expect(find.byType(LayerSwitcher), findsOneWidget);
    // The system layers offered (in the switcher) + the mechanical network.
    expect(find.descendant(
        of: find.byType(LayerSwitcher), matching: find.text('Plumbing')),
        findsOneWidget);
    expect(find.descendant(
        of: find.byType(LayerSwitcher), matching: find.text('HVAC')),
        findsOneWidget);
    expect(find.descendant(
        of: find.byType(LayerSwitcher), matching: find.text('Electrical')),
        findsOneWidget);
    expect(find.byType(NetworkLayer), findsWidgets);
  });

  testWidgets('a mechanical layer is active: the DRAW inspector is shown',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final c = _containerOf(tester);
    expect(c.read(activeDisciplineProvider), DisciplineLayer.plumbing);
    // The mechanical project inspector (with its DRAW section) is the right pane.
    expect(find.byType(ProjectPanel), findsOneWidget);
    expect(find.text('DRAW'), findsOneWidget);
    // The electrical Loads palette is NOT mounted while a mechanical layer edits.
    expect(find.byType(ElectricalPalette), findsNothing);
  });

  testWidgets('DRAW service chips scope to the active discipline', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final c = _containerOf(tester);
    // Plumbing active → plumbing services show (in the DRAW chips AND the node
    // palette), air services do not. Both surfaces scope to the active layer.
    expect(find.text('Cold water'), findsWidgets);
    expect(find.text('Supply air'), findsNothing);

    // Switch the active layer to HVAC → the air services replace the plumbing.
    c.read(activeDisciplineProvider.notifier).set(DisciplineLayer.hvac);
    await tester.pump();
    expect(find.text('Supply air'), findsWidgets);
    expect(find.text('Cold water'), findsNothing);
    // The draw service followed the active discipline (an air service now).
    expect(c.read(networkControllerProvider).service.isAir, isTrue);
  });

  testWidgets('Electrical active: the Loads palette replaces the DRAW inspector',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final c = _containerOf(tester);
    c.read(activeDisciplineProvider.notifier).set(DisciplineLayer.electrical);
    await tester.pump();

    // The electrical Loads palette is the active-layer toolset; the mechanical
    // DRAW inspector is gone.
    expect(find.byType(ElectricalPalette), findsOneWidget);
    expect(find.byType(ProjectPanel), findsNothing);
    expect(find.text('DRAW'), findsNothing);
  });

  testWidgets('placed electrical panel: drawn when its layer is visible, '
      'hidden when toggled off', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final c = _containerOf(tester);
    // Place the sample MDP on the active sheet/floor.
    c.read(electricalProjectProvider.notifier).setPanelLayoutPos(
        'mdp', const LayoutPos(sheetId: 's1', floorIndex: 0, x: 400, y: 300));
    // Electrical active so its marker is crisp + the layer drawn.
    c.read(activeDisciplineProvider.notifier).set(DisciplineLayer.electrical);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('MDP'), findsWidgets);

    // Make a mechanical layer active (electrical becomes a faded layer) — still
    // drawn for coordination.
    c.read(activeDisciplineProvider.notifier).set(DisciplineLayer.plumbing);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('MDP'), findsWidgets);

    // Toggle the electrical layer OFF → its marker is removed entirely.
    c
        .read(layerVisibilityProvider.notifier)
        .toggle(DisciplineLayer.electrical);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('MDP'), findsNothing);
  });

  testWidgets('one shared viewport: the mechanical + electrical layers ride the '
      'same per-sheet transform', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    await tester.pump(); // post-frame fit emits the viewport

    final c = _containerOf(tester);
    final sheet = c.read(sheetsControllerProvider).current!;
    // The unified canvas drives the per-sheet viewport (so the electrical layer,
    // which reads the same provider, shares the pan/zoom).
    expect(c.read(sheetsControllerProvider).viewportFor(sheet.id), isNotNull);
  });

  testWidgets('the rail item is "Layout" and routes to the unified canvas',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    // Navigate away and back via the relabelled rail item.
    final c = _containerOf(tester);
    await tester.tap(find.descendant(
        of: find.byType(NavRail), matching: find.text('Riser')));
    await tester.pump();
    expect(find.byType(LayoutCanvas), findsNothing);

    await tester.tap(find.descendant(
        of: find.byType(NavRail), matching: find.text('Layout')));
    await tester.pump();
    expect(c.read(workspaceViewProvider), WorkspaceView.plan);
    expect(find.byType(LayoutCanvas), findsOneWidget);
  });

  group('calibratedGridWorldStep (E8 — grid tied to round metres)', () {
    test('snaps the minor step to the 1-2-5 metre ladder nearest the default '
        'texture', () {
      // 0.02 m/px → 50 px/m. Candidates: 0.5 m = 25 px (|ln 25/32| ≈ 0.247)
      // beats 1 m = 50 px (|ln 50/32| ≈ 0.446) → 0.5 m minors.
      expect(calibratedGridWorldStep(0.02), closeTo(25.0, 1e-9));
      // 0.05 m/px → 20 px/m. 2 m = 40 px (≈0.223) beats 1 m = 20 px (≈0.470).
      expect(calibratedGridWorldStep(0.05), closeTo(40.0, 1e-9));
      // An exact 1 m = 32 px scale keeps the default spacing on the metre.
      expect(calibratedGridWorldStep(1 / 32), closeTo(32.0, 1e-9));
    });

    test('invalid scales fall back to the uncalibrated default', () {
      expect(calibratedGridWorldStep(0), 32.0);
      expect(calibratedGridWorldStep(-1), 32.0);
      expect(calibratedGridWorldStep(double.nan), 32.0);
      expect(calibratedGridWorldStep(double.infinity), 32.0);
    });
  });

  test('paintCanvasGrid draws major/minor hierarchy without hanging on panned '
      '/ far-out transforms', () {
    // A paint smoke over awkward transforms (negative pan, tiny scale where
    // minors hide but majors survive, zero-ish step guard).
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    const size = Size(800, 600);
    paintCanvasGrid(
        canvas,
        size,
        const ViewportTransform(offset: Offset(-1234.5, 987.0), scale: 1.0),
        const Color(0xFF888888));
    paintCanvasGrid(
        canvas,
        size,
        const ViewportTransform(offset: Offset(50, -50), scale: 0.1),
        const Color(0xFF888888),
        worldStep: 40); // minors 4 px < 6 → majors only (16 px)
    paintCanvasGrid(
        canvas,
        size,
        const ViewportTransform(scale: 0.001),
        const Color(0xFF888888)); // everything below threshold → no lines
    rec.endRecording();
  });

  testWidgets('hold-Space engages pan pass-through and releases cleanly',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Space down then up over the layout canvas must not throw and must leave
    // the app interactive (the flag is internal; this is a lifecycle smoke).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(find.byType(LayoutCanvas), findsOneWidget);
  });

  testWidgets('Ctrl+A selects all on the floor scoped to the active layer',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final c = _containerOf(tester);
    final ctrl = c.read(networkControllerProvider.notifier);
    final sheet = c.read(sheetsControllerProvider).current!;
    // A plumbing run + an HVAC duct on the same floor.
    ctrl.addSegment(sheet.id, 0, const Offset(400, 400),
        service: ServiceType.coldWater);
    ctrl.addSegment(sheet.id, 0, const Offset(400, 600),
        service: ServiceType.duct);
    await tester.pump();

    // Active layer defaults to Plumbing — Ctrl+A grabs only the plumbing run.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    final sel = c.read(selectionProvider);
    expect(sel.edgeIds.length, 1);
    final net = c.read(networkControllerProvider).network;
    expect(net.edgeById(sel.edgeIds.single)!.service, ServiceType.coldWater);
    expect(sel.nodeIds.length, 2);
  });

  testWidgets(
      'B4: Backspace / Ctrl+A typed into the calibration field edit the FIELD '
      '- they never delete the selected node or grab the drawing selection',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final c = _containerOf(tester);
    final ctrl = c.read(networkControllerProvider.notifier);
    final sheet = c.read(sheetsControllerProvider).current!;
    ctrl.addSegment(sheet.id, 0, const Offset(400, 400),
        service: ServiceType.coldWater);
    final node = c.read(networkControllerProvider).network.nodes.first;
    c.read(selectionProvider.notifier).selectNode(node.id);
    await tester.pump();

    // Drive calibration to the distance-entry phase — its "Known distance"
    // field is a DESCENDANT of the Layout canvas's key-handling Focus.
    final cal = c.read(calibrationControllerProvider.notifier);
    cal.start();
    cal.addWorldPoint(const Offset(0, 0));
    cal.addWorldPoint(const Offset(0, 200));
    await tester.pump();
    expect(find.text('Known distance'), findsOneWidget);

    // Type into the field (this focuses its EditableText), then press
    // Backspace — the empirically-proven probe that used to DELETE the node.
    final field = find.descendant(
        of: find.byType(CalibrationOverlay),
        matching: find.byType(EditableText));
    await tester.enterText(field, '5.0');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    // The keystroke edited the FIELD (the root DefaultTextEditingShortcuts
    // got it) — the drawing is untouched.
    expect(tester.widget<EditableText>(field).controller.text, '5.');
    expect(
      c.read(networkControllerProvider).network.nodes.any((n) => n.id == node.id),
      isTrue,
      reason: 'Backspace in a text field must never delete the selected node',
    );

    // Ctrl+A while the field is focused selects the field text — it must NOT
    // run the canvas select-all (which would grab the run's nodes + edge).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    final sel = c.read(selectionProvider);
    expect(sel.nodeId, node.id);
    expect(sel.edgeIds, isEmpty,
        reason: 'Ctrl+A in a text field must not select-all on the canvas');
  });
}
