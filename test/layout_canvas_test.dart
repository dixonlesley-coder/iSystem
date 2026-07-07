import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show EditableText, Offset, ValueKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/calibration_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/ui/canvas/calibration_overlay.dart';
import 'package:mechx/ui/canvas/canvas_grid.dart';
import 'package:mechx/ui/canvas/canvas_view.dart';
import 'package:mechx/ui/canvas/network_layer.dart';
import 'package:mechx/ui/canvas/viewport.dart';
import 'package:mechx/ui/electrical/electrical_palette.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx/ui/layout/layout_canvas.dart';
import 'package:mechx/ui/layout/layer_switcher.dart';
import 'package:mechx/ui/shell/nav_rail.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

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

/// Boot the full app on a desktop surface and seed the demo sheets, returning
/// the app's ProviderContainer (shared setup for the B10/B11 drag tests).
Future<ProviderContainer> _boot(WidgetTester tester) async {
  setDesktopSurface(tester);
  await tester.pumpWidget(const ProviderScope(child: MechXApp()));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  final c = _containerOf(tester);
  seedDemoSheets(c);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return c;
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('the Layout design view renders the unified canvas + switcher',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    // Default boot is the Layout design view.
    final c = _containerOf(tester);
    seedDemoSheets(c);
    await tester.pump();
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
    seedDemoSheets(c);
    seedSampleElectrical(c);
    await tester.pump();
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

    final c = _containerOf(tester);
    seedDemoSheets(c);
    await tester.pump();
    await tester.pump(); // post-frame fit emits the viewport

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
    seedDemoSheets(c);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
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
    seedDemoSheets(c);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
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

  testWidgets(
      'C3: single-key shortcuts arm tools, pick the layer service, toggle '
      'ortho, and Enter repeats the last tool', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final c = _containerOf(tester);
    seedDemoSheets(c);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // R arms Run.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pump();
    expect(c.read(networkControllerProvider).tool, DrawTool.drawRun);

    // Number key 2 picks the plumbing layer's 2nd service (hot water).
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();
    expect(c.read(networkControllerProvider).service, ServiceType.hotWater);

    // V returns to Select (and does NOT become the "last tool").
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.pump();
    expect(c.read(networkControllerProvider).tool, DrawTool.select);

    // O toggles ortho (default on → off).
    expect(c.read(orthoProvider), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
    await tester.pump();
    expect(c.read(orthoProvider), isFalse);

    // Enter (idle) repeats the last real tool — Run, not Select.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(c.read(networkControllerProvider).tool, DrawTool.drawRun);
  });

  testWidgets('E2: arrow keys nudge the selected nodes by the grid step',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final c = _containerOf(tester);
    seedDemoSheets(c);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final ctrl = c.read(networkControllerProvider.notifier);
    final sheet = c.read(sheetsControllerProvider).current!;
    ctrl.addSegment(sheet.id, 0, const Offset(400, 400),
        service: ServiceType.coldWater);
    await tester.pump();

    // Select all on the floor (the run's two nodes + its edge).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(c.read(selectionProvider).nodeIds.length, 2);

    final before = {
      for (final n in c.read(networkControllerProvider).network.nodes)
        n.id: Offset(n.x, n.y),
    };
    final cal =
        c.read(projectControllerProvider).calibrationFor(sheet.id);
    final step =
        cal == null ? 32.0 : calibratedGridWorldStep(cal.metersPerPixel);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    for (final n in c.read(networkControllerProvider).network.nodes) {
      final b = before[n.id]!;
      expect(n.x, closeTo(b.dx + step, 1e-6));
      expect(n.y, closeTo(b.dy, 1e-6));
    }
    // The nudge is undoable in one step.
    c.read(networkControllerProvider.notifier).undo();
    for (final n in c.read(networkControllerProvider).network.nodes) {
      final b = before[n.id]!;
      expect(n.x, closeTo(b.dx, 1e-6));
    }
  });

  test('canvasFitRequestProvider bumps its counter on request (W3-P5 fit seam)',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final before = c.read(canvasFitRequestProvider);
    c.read(canvasFitRequestProvider.notifier).request();
    expect(c.read(canvasFitRequestProvider), before + 1);
  });

  testWidgets('C7: an outlet nub renders only for the SELECTED non-fixture node',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final c = _containerOf(tester);
    seedDemoSheets(c);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final ctrl = c.read(networkControllerProvider.notifier);
    final sheet = c.read(sheetsControllerProvider).current!;
    ctrl.addFitting(sheet.id, 0, const Offset(500, 500)); // a bare junction node
    await tester.pump();
    final id = c.read(networkControllerProvider).network.nodes.last.id;
    final nub = find.byKey(ValueKey('outlet-$id'));

    // At rest (nothing hovered/selected) the nub is NOT painted — no confetti.
    expect(nub, findsNothing);

    // Selecting the node reveals its outlet nub.
    c.read(selectionProvider.notifier).selectNode(id);
    await tester.pump();
    expect(nub, findsOneWidget);

    // Deselecting hides it again.
    c.read(selectionProvider.notifier).clear();
    await tester.pump();
    expect(nub, findsNothing);
  });

  testWidgets(
      'E1: right-clicking a multi-selected edge batch-applies size to the '
      'whole selection and KEEPS it selected', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final c = _containerOf(tester);
    seedDemoSheets(c);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final ctrl = c.read(networkControllerProvider.notifier);
    final sheet = c.read(sheetsControllerProvider).current!;
    // Two separated cold-water runs (pipe → the DN size ladder is offered).
    ctrl.addSegment(sheet.id, 0, const Offset(360, 360),
        service: ServiceType.coldWater);
    ctrl.addSegment(sheet.id, 0, const Offset(360, 620),
        service: ServiceType.coldWater);
    await tester.pump();

    final edges = c.read(networkControllerProvider).network.edges.toList();
    expect(edges.length, 2);
    final e1 = edges[0], e2 = edges[1];
    c.read(selectionProvider.notifier).setMulti(const {}, {e1.id, e2.id});
    await tester.pump();

    // Right-click on the FIRST edge's midpoint (global coords).
    final net = c.read(networkControllerProvider).network;
    final a = net.nodeById(e1.fromId)!, b = net.nodeById(e1.toId)!;
    final vt = c.read(sheetsControllerProvider).viewportFor(sheet.id) ??
        const ViewportTransform();
    final mid = vt.worldToScreen(Offset((a.x + b.x) / 2, (a.y + b.y) / 2));
    final canvasRect = tester.getRect(find.byType(CanvasView));
    // One explicit secondary-tap gesture (tapAt double-fires the recognizer).
    final rc = await tester.startGesture(canvasRect.topLeft + mid,
        buttons: kSecondaryButton);
    await rc.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350)); // settle the entrance

    // The batch header shows (proving the menu resolved multi=true against the
    // preserved selection); MechXMenuHeader upper-cases it.
    expect(find.text('APPLY TO 2 SELECTED'), findsWidgets);
    // The right-click kept the multi-selection intact (E1, selection_overlay).
    expect(c.read(selectionProvider).edgeIds.length, 2);

    // Tap a DN size row → BOTH edges take that override in one undo step, and
    // the multi-selection survives (batch edit, not a collapse).
    await tester.tap(find.textContaining('DN').last, warnIfMissed: false);
    await tester.pump();

    final after = c.read(networkControllerProvider).network;
    final s1 = after.edgeById(e1.id)!.sizeOverride;
    final s2 = after.edgeById(e2.id)!.sizeOverride;
    expect(s1, isNotNull, reason: 'batch size must apply to the first edge');
    expect(s2, isNotNull, reason: 'batch size must apply to the second edge');
    expect(s1!.meters, s2!.meters);
    expect(c.read(selectionProvider).edgeIds.length, 2,
        reason: 'a batch edit must keep the multi-selection alive');
  });

  testWidgets(
      'B11: a pull from a HOVERED (unselected) nub survives the mid-pull '
      'hover-clear and lays the run at the FULL distance', (tester) async {
    final c = await _boot(tester);

    final ctrl = c.read(networkControllerProvider.notifier);
    final sheet = c.read(sheetsControllerProvider).current!;
    ctrl.addFitting(sheet.id, 0, const Offset(500, 500)); // a bare junction
    await tester.pump();
    final id = c.read(networkControllerProvider).network.nodes.last.id;

    // Merely HOVER the node (do NOT select it) — the C7 gate mounts the nub.
    c.read(hoverTargetProvider.notifier).set((nodeId: id, edgeId: null));
    await tester.pump();
    expect(c.read(selectionProvider).nodeId, isNot(id),
        reason: 'the node must be hovered, not selected');
    final theNub = find.byKey(ValueKey('outlet-$id'));
    expect(theNub, findsOneWidget);

    final vt = c.read(sheetsControllerProvider).viewportFor(sheet.id) ??
        const ViewportTransform();

    // Pull the mainline 200 px to the right, releasing far from the source.
    final g = await tester.startGesture(tester.getCenter(theNub));
    await tester.pump();
    await g.moveBy(const Offset(80, 0)); // pull begins → _pullFrom == id
    await tester.pump();
    // Production fires the nub's MouseRegion.onExit here (the pointer left the
    // 18 px nub) which cleared the hover latch. Reproduce that pressure: the
    // B11 gate must keep the nub mounted (_pullFrom == id) so the live pan
    // gesture is not torn down mid-pull.
    c.read(hoverTargetProvider.notifier).clear();
    await tester.pump();
    await g.moveBy(const Offset(120, 0)); // continue to the full 200 px
    await tester.pump();
    await g.up();
    await tester.pump();

    final net = c.read(networkControllerProvider).network;
    final runs =
        net.edges.where((e) => e.fromId == id || e.toId == id).toList();
    expect(runs.length, 1, reason: 'the pull must lay exactly one run');
    final e = runs.first;
    final farId = e.fromId == id ? e.toId : e.fromId;
    final far = net.nodeById(farId)!;
    final src = net.nodeById(id)!;
    final distScreen =
        (Offset(far.x, far.y) - Offset(src.x, src.y)).distance * vt.scale;
    expect(distScreen, greaterThan(150),
        reason: 'the run reached the full pull distance, not frozen short');
  });

  testWidgets(
      'B10: resizing a selected run endpoint snaps to a 45-degree ray when '
      'Ortho is on', (tester) async {
    final c = await _boot(tester);
    expect(c.read(orthoProvider), isTrue); // ortho is default-on

    final sheet = c.read(sheetsControllerProvider).current!;
    c.read(networkControllerProvider.notifier).addSegment(
        sheet.id, 0, const Offset(500, 500),
        service: ServiceType.coldWater);
    await tester.pump();
    final edge = c.read(networkControllerProvider).network.edges.single;
    c.read(selectionProvider.notifier).selectEdge(edge.id);
    await tester.pump();

    final vt = c.read(sheetsControllerProvider).viewportFor(sheet.id) ??
        const ViewportTransform();
    final canvasRect = tester.getRect(find.byType(CanvasView));
    Offset worldOf(String nid) {
      final n = c.read(networkControllerProvider).network.nodeById(nid)!;
      return Offset(n.x, n.y);
    }

    final a0 = worldOf(edge.fromId), b0 = worldOf(edge.toId);
    final bId = b0.dx >= a0.dx ? edge.toId : edge.fromId; // right endpoint
    final aId = bId == edge.toId ? edge.fromId : edge.toId; // the anchor

    // Drag B by a world delta whose raw angle from A (~-45 deg but not on it)
    // rounds to the -45 deg ray; ortho must pull it exactly onto that ray.
    final bScreen = canvasRect.topLeft + vt.worldToScreen(worldOf(bId));
    final g = await tester.startGesture(bScreen);
    await tester.pump();
    await g.moveBy(Offset(180 * vt.scale, -300 * vt.scale));
    await tester.pump();
    await g.up();
    await tester.pump();

    final v = worldOf(bId) - worldOf(aId);
    expect(v.dx.abs(), greaterThan(50));
    expect(v.dy.abs(), greaterThan(50));
    expect((v.dx.abs() - v.dy.abs()).abs(), lessThan(2.0),
        reason: 'ortho snaps the resized run onto the 45-degree diagonal; '
            'got $v');
  });

  testWidgets(
      'B10: Shift frees the endpoint resize from the ortho constraint',
      (tester) async {
    final c = await _boot(tester);

    final sheet = c.read(sheetsControllerProvider).current!;
    c.read(networkControllerProvider.notifier).addSegment(
        sheet.id, 0, const Offset(500, 500),
        service: ServiceType.coldWater);
    await tester.pump();
    final edge = c.read(networkControllerProvider).network.edges.single;
    c.read(selectionProvider.notifier).selectEdge(edge.id);
    await tester.pump();

    final vt = c.read(sheetsControllerProvider).viewportFor(sheet.id) ??
        const ViewportTransform();
    final canvasRect = tester.getRect(find.byType(CanvasView));
    Offset worldOf(String nid) {
      final n = c.read(networkControllerProvider).network.nodeById(nid)!;
      return Offset(n.x, n.y);
    }

    final a0 = worldOf(edge.fromId), b0 = worldOf(edge.toId);
    final bId = b0.dx >= a0.dx ? edge.toId : edge.fromId;
    final aId = bId == edge.toId ? edge.fromId : edge.toId;

    // Hold Shift → effectiveOrtho is off → a mostly-horizontal drag with a
    // clear vertical keeps its vertical rise (ortho would zero it).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final bScreen = canvasRect.topLeft + vt.worldToScreen(worldOf(bId));
    final g = await tester.startGesture(bScreen);
    await tester.pump();
    await g.moveBy(Offset(300 * vt.scale, -90 * vt.scale));
    await tester.pump();
    await g.up();
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    final v = worldOf(bId) - worldOf(aId);
    expect(v.dy.abs(), greaterThan(30),
        reason: 'Shift frees the drag — the vertical rise survives, it is not '
            'snapped to the horizontal ray; got $v');
  });

  testWidgets(
      'B10: a degree>=2 junction node drags FREELY under Ortho (snapping one '
      'edge would un-straighten the other)', (tester) async {
    final c = await _boot(tester);
    expect(c.read(orthoProvider), isTrue);

    final ctrl = c.read(networkControllerProvider.notifier);
    final sheet = c.read(sheetsControllerProvider).current!;
    ctrl.addFitting(sheet.id, 0, const Offset(500, 500));
    final jId = c.read(networkControllerProvider).network.nodes.last.id;
    // Two runs out of J → degree 2 (one horizontal, one vertical neighbour).
    ctrl.drawRunFromNode(jId, const Offset(760, 500));
    ctrl.drawRunFromNode(jId, const Offset(500, 760));
    await tester.pump();
    // Confirm the junction really is degree 2.
    final degree = c
        .read(networkControllerProvider)
        .network
        .edges
        .where((e) => e.fromId == jId || e.toId == jId)
        .length;
    expect(degree, 2);

    final vt = c.read(sheetsControllerProvider).viewportFor(sheet.id) ??
        const ViewportTransform();
    final canvasRect = tester.getRect(find.byType(CanvasView));
    Offset worldOf(String nid) {
      final n = c.read(networkControllerProvider).network.nodeById(nid)!;
      return Offset(n.x, n.y);
    }

    final j0 = worldOf(jId);
    final jScreen = canvasRect.topLeft + vt.worldToScreen(j0);
    // A non-axis, non-45-degree drag (dy/dx ~ -0.56), driven in steps so the
    // gesture arena settles on the node's drag handle (tap+pan) before moving.
    final g = await tester.startGesture(jScreen);
    await tester.pump();
    final jStep = Offset(180 * vt.scale, -100 * vt.scale) / 5;
    for (var i = 0; i < 5; i++) {
      await g.moveBy(jStep);
      await tester.pump();
    }
    await g.up();
    await tester.pump();

    final moved = worldOf(jId) - j0;
    expect(moved.dx, greaterThan(0));
    expect(moved.dy, lessThan(0));
    // Free: the displacement follows the raw drag direction — NOT snapped to
    // an axis (ratio ~ 0) nor a 45-degree ray (ratio ~ -1).
    final ratio = moved.dy / moved.dx;
    expect(ratio, lessThan(-0.2), reason: 'not snapped to horizontal; $moved');
    expect(ratio, greaterThan(-0.9), reason: 'not snapped to 45 deg; $moved');
  });

  testWidgets(
      'B5: a calibrated true-width duct is clickable across its rendered '
      'body, not just an 8px hairline centreline', (tester) async {
    final c = await _boot(tester);

    final ctrl = c.read(networkControllerProvider.notifier);
    final sheet = c.read(sheetsControllerProvider).current!;
    c
        .read(projectControllerProvider.notifier)
        .setCalibration(sheet.id, const ScaleCalibration(0.01));

    ctrl.addSegment(sheet.id, 0, const Offset(700, 700),
        service: ServiceType.duct);
    await tester.pump();
    final edge = c.read(networkControllerProvider).network.edges.last;
    // Give the far end demand so the run actually carries flow — an edge
    // with no accumulated flow is skipped by autoSizeNetwork regardless of
    // any size override.
    ctrl.setNodeAirflow(edge.toId, FlowRate.litersPerSecond(500));
    await tester.pump();

    final vt = c.read(sheetsControllerProvider).viewportFor(sheet.id) ??
        const ViewportTransform();
    // A diameter chosen to render a robust ~48 screen-px true width at THIS
    // test's actual zoom scale (a large calibrated trunk, zoomed in — the
    // very scenario B5 concerns), whatever that scale happens to be.
    const mpp = 0.01;
    final mmForTarget = 48.0 * mpp * 1000 / vt.scale;
    ctrl.setEdgeSizeOverride(edge.id, Diameter.mm(mmForTarget));
    await tester.pump();

    final sizing = c.read(sizingProvider);
    final s = sizing[edge.id];
    expect(s, isNotNull, reason: 'the duct must carry flow to be sized');
    final outer = pipeOuterPx(s, ServiceType.duct,
        scale: vt.scale, metersPerPixel: mpp);
    expect(outer, greaterThan(30),
        reason: 'the calibrated duct should render wide; got $outer');

    final net = c.read(networkControllerProvider).network;
    final a = net.nodeById(edge.fromId)!, b = net.nodeById(edge.toId)!;
    final mid = Offset((a.x + b.x) / 2, (a.y + b.y) / 2);
    final canvasRect = tester.getRect(find.byType(CanvasView));

    // A tap 15 screen px off the (horizontal) run's centreline must still
    // hit it — the old fixed 8px band would have missed this.
    final probe = mid + Offset(0, 15 / vt.scale);
    await tester.tapAt(canvasRect.topLeft + vt.worldToScreen(probe));
    await tester.pump();
    expect(c.read(selectionProvider).edgeId, edge.id,
        reason: 'a tap 15px off the fat duct centreline must still hit it');
  });

  testWidgets(
      'B5: an unsized/hairline run keeps the original fixed 8px hit band',
      (tester) async {
    final c = await _boot(tester);

    final ctrl = c.read(networkControllerProvider.notifier);
    final sheet = c.read(sheetsControllerProvider).current!;
    // No calibration, no manual size override — this run only ever gets the
    // flat default fixture-unit demand (~2 UBAP, a small DN), so its rendered
    // body stays thin regardless.
    ctrl.addSegment(sheet.id, 0, const Offset(900, 300),
        service: ServiceType.coldWater);
    await tester.pump();
    final edge = c.read(networkControllerProvider).network.edges.last;

    final vt = c.read(sheetsControllerProvider).viewportFor(sheet.id) ??
        const ViewportTransform();
    final outer = pipeOuterPx(c.read(sizingProvider)[edge.id],
        ServiceType.coldWater, scale: vt.scale, metersPerPixel: null);
    expect(math.max(8.0, outer / 2 + 4.0), 8.0,
        reason: 'an uncalibrated/thin pipe must resolve to the original '
            '8px hairline corridor; got outer=$outer');

    final net = c.read(networkControllerProvider).network;
    final a = net.nodeById(edge.fromId)!, b = net.nodeById(edge.toId)!;
    final mid = Offset((a.x + b.x) / 2, (a.y + b.y) / 2);
    final canvasRect = tester.getRect(find.byType(CanvasView));

    // 15px off the centreline MISSES the fixed 8px band.
    final far = mid + Offset(0, 15 / vt.scale);
    await tester.tapAt(canvasRect.topLeft + vt.worldToScreen(far));
    await tester.pump();
    expect(c.read(selectionProvider).edgeId, isNot(edge.id),
        reason: 'an unsized hairline run must not extend its hit band');

    // 6px off the centreline still HITS (inside the original 8px band).
    final near = mid + Offset(0, 6 / vt.scale);
    await tester.tapAt(canvasRect.topLeft + vt.worldToScreen(near));
    await tester.pump();
    expect(c.read(selectionProvider).edgeId, edge.id,
        reason: 'the original 8px hairline band must still register a hit');
  });

  testWidgets(
      'B6: a drag started at the NUB centre pulls a mainline, a drag '
      'started at the NODE centre moves the node — the two hit boxes no '
      'longer overlap', (tester) async {
    final c = await _boot(tester);

    final ctrl = c.read(networkControllerProvider.notifier);
    final sheet = c.read(sheetsControllerProvider).current!;
    ctrl.addFitting(sheet.id, 0, const Offset(500, 500)); // a bare junction
    await tester.pump();
    final id = c.read(networkControllerProvider).network.nodes.last.id;

    c.read(selectionProvider.notifier).selectNode(id);
    await tester.pump();
    final nub = find.byKey(ValueKey('outlet-$id'));
    expect(nub, findsOneWidget);

    Offset worldOf(String nid) {
      final n = c.read(networkControllerProvider).network.nodeById(nid)!;
      return Offset(n.x, n.y);
    }

    final before = worldOf(id);

    // 1) A drag STARTING AT THE NUB'S CENTRE pulls a new mainline — the
    // source node itself never moves.
    final g1 = await tester.startGesture(tester.getCenter(nub));
    await tester.pump();
    await g1.moveBy(const Offset(80, 0));
    await tester.pump();
    await g1.up();
    await tester.pump();

    final afterPull = c.read(networkControllerProvider).network;
    expect(
        afterPull.edges.where((e) => e.fromId == id || e.toId == id).length,
        1,
        reason: 'the nub drag must lay exactly one new run');
    expect(worldOf(id), before,
        reason: 'a pull from the nub must never move the source node');

    // 2) A drag STARTING AT THE NODE'S OWN CENTRE moves the node instead —
    // no second run is laid.
    final vt = c.read(sheetsControllerProvider).viewportFor(sheet.id) ??
        const ViewportTransform();
    final canvasRect = tester.getRect(find.byType(CanvasView));
    final nodeCentre = canvasRect.topLeft + vt.worldToScreen(before);
    final g2 = await tester.startGesture(nodeCentre);
    await tester.pump();
    // Driven in steps so the gesture arena settles on the node's drag handle
    // (tap+pan) before moving — matches the B10 junction-drag test's pattern.
    final step = const Offset(0, 80) / 5;
    for (var i = 0; i < 5; i++) {
      await g2.moveBy(step);
      await tester.pump();
    }
    await g2.up();
    await tester.pump();

    final afterMove = c.read(networkControllerProvider).network;
    expect(
        afterMove.edges.where((e) => e.fromId == id || e.toId == id).length,
        1,
        reason: 'the node drag must not lay a second run');
    expect(worldOf(id), isNot(before),
        reason: 'a drag started at the node centre must move the node');
  });
}
