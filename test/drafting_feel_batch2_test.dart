import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/smart_input_store.dart';
import 'package:mechx/store/snap_settings_store.dart';
import 'package:mechx/ui/canvas/canvas_view.dart';
import 'package:mechx/ui/canvas/drawing_overlay.dart';
import 'package:mechx/ui/canvas/edge_context_menu.dart'
    show TrimExtendTarget, trimExtendArmedProvider;
import 'package:mechx/ui/canvas/mode_pill.dart';
import 'package:mechx/ui/canvas/network_layer.dart';
import 'package:mechx/ui/canvas/selection_overlay.dart';
import 'package:mechx/ui/canvas/text_entry_guard.dart';
import 'package:mechx/ui/canvas/viewport.dart';
import 'package:mechx/ui/canvas/zoom_controls.dart';
import 'package:mechx/ui/layout/layout_canvas.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';

import 'test_util.dart';

/// Drafting-feel batch 2 — the Layout canvas keyboard / pointer / preview
/// fixes, driven through the FULL app (real focus tree, real key routing).
/// Store halves: `drafting_feel_batch2_store_test.dart`.
void main() {
  ProviderContainer containerOf(WidgetTester t) => ProviderScope.containerOf(
      t.element(find.byType(MechXApp)),
      listen: false);

  late String sheetId;

  /// Pump the app on a seeded, calibrated (0.01 m/px) demo sheet, optionally
  /// carrying [build]'s network (built against the live sheet id).
  Future<ProviderContainer> pumpApp(WidgetTester tester,
      {Network Function(String sheetId)? build}) async {
    setDesktopSurface(tester, size: const Size(1440, 900));
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final c = containerOf(tester);
    seedDemoSheets(c);
    await tester.pump(const Duration(milliseconds: 300));
    sheetId = c.read(sheetsControllerProvider).current!.id;
    c
        .read(projectControllerProvider.notifier)
        .setCalibration(sheetId, const ScaleCalibration(0.01));
    if (build != null) {
      c.read(networkControllerProvider.notifier).loadNetwork(build(sheetId));
    }
    await tester.pump(const Duration(milliseconds: 300));
    return c;
  }

  Rect canvasRect(WidgetTester tester) =>
      tester.getRect(find.byType(CanvasView).first);

  /// Screen (global) position of a world point on the current sheet.
  Offset screenOf(WidgetTester tester, ProviderContainer c, Offset world) {
    final vt =
        c.read(sheetViewportProvider(sheetId)) ?? const ViewportTransform();
    return canvasRect(tester).topLeft + vt.worldToScreen(world);
  }

  Future<void> click(WidgetTester tester, Offset at) async {
    await tester.tapAt(at, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 120));
  }

  Network net(ProviderContainer c) =>
      c.read(networkControllerProvider).network;

  DrawingState draw(ProviderContainer c) => c.read(networkControllerProvider);

  Future<void> arm(WidgetTester tester, ProviderContainer c, DrawTool t) async {
    c.read(networkControllerProvider.notifier).setTool(t);
    await tester.pump(const Duration(milliseconds: 100));
  }

  group('H1 — typing a length mid-run', () {
    testWidgets('click, type 3 0 0 0 Enter: one 3 m run, service unchanged, '
        'chain still pending', (tester) async {
      final c = await pumpApp(tester);
      await arm(tester, c, DrawTool.drawRun);
      final svc = draw(c).service;
      final start = canvasRect(tester).center;
      await click(tester, start);
      await tester.pump(const Duration(milliseconds: 50));
      expect(draw(c).pendingPoint, isNotNull);
      // The bar claimed the keyboard after the frame that showed it.
      expect(isTextEntryFocused(), isTrue);
      for (final k in [
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.digit0,
      ]) {
        await tester.sendKeyEvent(k);
      }
      await tester.pump();
      expect(draw(c).service, svc,
          reason: 'a digit mid-run types a length, never picks a service');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 50));
      final n = net(c);
      expect(n.edges.length, 1);
      final e = n.edges.single;
      final a = n.nodeById(e.fromId)!, b = n.nodeById(e.toId)!;
      final lenM = (Offset(b.x, b.y) - Offset(a.x, a.y)).distance * 0.01;
      expect(lenM, closeTo(3.0, 1e-6));
      expect(draw(c).pendingPoint, isNotNull, reason: 'the chain continues');
      // Esc from inside the bar still backs out: first the run, then the tool
      // (the keyboard is handed back to the canvas when the bar unmounts).
      await tester.pump(const Duration(milliseconds: 50));
      expect(isTextEntryFocused(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit7);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 50));
      expect(draw(c).pendingPoint, isNull);
      expect(net(c).edges.length, 1, reason: 'the typed 7 was never placed');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(draw(c).tool, DrawTool.select);
    });

    testWidgets('digits reach the bar even when the CANVAS holds focus',
        (tester) async {
      final c = await pumpApp(tester);
      await arm(tester, c, DrawTool.drawRun);
      await click(tester, canvasRect(tester).center);
      // Something took the keyboard back to the canvas (a click on a node
      // grip, say): the canvas handler forwards the digits.
      tester
          .state<CanvasViewState>(find.byType(CanvasView).first)
          .requestKeyboardFocus();
      await tester.pump();
      expect(isTextEntryFocused(), isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 50));
      final n = net(c);
      expect(n.edges.length, 1);
      final e = n.edges.single;
      final a = n.nodeById(e.fromId)!, b = n.nodeById(e.toId)!;
      expect((Offset(b.x, b.y) - Offset(a.x, a.y)).distance * 0.01,
          closeTo(2.5, 1e-6));
    });
  });

  group('H2 — ortho on: clicks keep chaining', () {
    testWidgets('three clicks: two CONNECTED runs and a live chain',
        (tester) async {
      final c = await pumpApp(tester);
      expect(c.read(orthoProvider), isTrue);
      await arm(tester, c, DrawTool.drawRun);
      final p0 = canvasRect(tester).center;
      await click(tester, p0);
      await click(tester, p0 + const Offset(120, 0));
      await click(tester, p0 + const Offset(240, 0));
      final n = net(c);
      expect(n.edges.length, 2);
      final shared = {n.edges[0].fromId, n.edges[0].toId}
          .intersection({n.edges[1].fromId, n.edges[1].toId});
      expect(shared, hasLength(1), reason: 'the second run continues the first');
      expect(draw(c).pendingPoint, isNotNull);
    });
  });

  group('H4 — Backspace / Delete mid-run', () {
    testWidgets('arming a draw tool drops the hidden selection; Delete '
        'mid-run deletes nothing; Backspace undoes the last point',
        (tester) async {
      final c = await pumpApp(
          tester,
          build: (s) => Network(nodes: [
                NetNode(id: 'a', sheetId: s, x: 20, y: 20, floorIndex: 0),
                NetNode(id: 'b', sheetId: s, x: 60, y: 20, floorIndex: 0),
              ], edges: const [
                NetEdge(
                    id: 'e1',
                    fromId: 'a',
                    toId: 'b',
                    service: ServiceType.coldWater),
              ]));
      c.read(selectionProvider.notifier).setMulti(const {}, const {'e1'});
      await tester.pump();
      await arm(tester, c, DrawTool.drawRun);
      expect(c.read(selectionProvider).isEmpty, isTrue);
      final p0 = canvasRect(tester).center;
      await click(tester, p0);
      await click(tester, p0 + const Offset(120, 0));
      await click(tester, p0 + const Offset(240, 0));
      expect(net(c).edges.length, 3);
      // A selection set behind the overlay mid-draw is still never deleted.
      c.read(selectionProvider.notifier).setMulti(const {}, const {'e1'});
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(net(c).edgeById('e1'), isNotNull);
      expect(net(c).edges.length, 3);
      // Backspace: the last segment goes, the chain re-anchors.
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump(const Duration(milliseconds: 50));
      expect(net(c).edges.length, 2);
      expect(net(c).edgeById('e1'), isNotNull);
      expect(draw(c).pendingPoint, isNotNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump(const Duration(milliseconds: 50));
      expect(net(c).edges.length, 1);
      expect(draw(c).pendingPoint, isNotNull,
          reason: 'back at the start point');
      // Nothing left in the chain: Backspace drops the start point itself.
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump(const Duration(milliseconds: 50));
      expect(draw(c).pendingPoint, isNull);
      expect(net(c).edges.length, 1);
      expect(draw(c).tool, DrawTool.drawRun);
    });
  });

  group('H5 — clicking a node returns the keyboard to the canvas', () {
    testWidgets('focus a text field, click a node, Delete deletes it',
        (tester) async {
      final c = await pumpApp(
          tester,
          build: (s) => Network(nodes: [
                NetNode(id: 'a', sheetId: s, x: 300, y: 300, floorIndex: 0),
              ]));
      // A focusable control OUTSIDE the canvas (the inspector / chrome)
      // holds the keyboard — the state an inspector-field commit leaves.
      final layout = find.byType(LayoutCanvas).evaluate().single;
      bool insideLayout(FocusNode n) {
        var inside = false;
        n.context?.visitAncestorElements((a) {
          if (a == layout) inside = true;
          return !inside;
        });
        return inside;
      }

      final outside = FocusManager.instance.rootScope.descendants.firstWhere(
          (n) => n.canRequestFocus && n.context != null && !insideLayout(n));
      outside.requestFocus();
      await tester.pump();
      expect(insideLayout(FocusManager.instance.primaryFocus!), isFalse);
      await click(tester, screenOf(tester, c, const Offset(300, 300)));
      expect(c.read(selectionProvider).nodeId, 'a');
      expect(insideLayout(FocusManager.instance.primaryFocus!), isTrue,
          reason: 'the click on the node handle gave the canvas the keyboard');
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(net(c).nodeById('a'), isNull);
    });
  });

  group('H6 — Shift-click on a node toggles', () {
    testWidgets('Shift-click adds, Shift-click again removes', (tester) async {
      final c = await pumpApp(
          tester,
          build: (s) => Network(nodes: [
                NetNode(id: 'a', sheetId: s, x: 300, y: 300, floorIndex: 0),
                NetNode(id: 'b', sheetId: s, x: 420, y: 300, floorIndex: 0),
              ]));
      await click(tester, screenOf(tester, c, const Offset(300, 300)));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await click(tester, screenOf(tester, c, const Offset(420, 300)));
      expect(c.read(selectionProvider).nodeIds, {'a', 'b'});
      await tester.pump(const Duration(milliseconds: 400));
      await click(tester, screenOf(tester, c, const Offset(300, 300)));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(c.read(selectionProvider).nodeIds, {'b'});
    });
  });

  group('M2 / L3 — Enter / Space end a run', () {
    testWidgets('Enter with nothing typed finishes; the tool stays armed',
        (tester) async {
      final c = await pumpApp(tester);
      await arm(tester, c, DrawTool.drawRun);
      final p0 = canvasRect(tester).center;
      await click(tester, p0);
      await click(tester, p0 + const Offset(120, 0));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 50));
      expect(draw(c).pendingPoint, isNull);
      expect(draw(c).tool, DrawTool.drawRun);
      expect(net(c).edges.length, 1);
      // The keyboard is back on the canvas: a second Esc exits the tool.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(draw(c).tool, DrawTool.select);
    });

    testWidgets('a TAP of Space finishes; HOLDING Space pans (chain kept)',
        (tester) async {
      final c = await pumpApp(tester);
      await arm(tester, c, DrawTool.drawRun);
      final p0 = canvasRect(tester).center;
      await click(tester, p0);
      // Held: down + auto-repeat + up — a pan, not a finish.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      await tester.pump();
      // The draw overlay stands down while Space is held.
      final ignoring = tester
          .widgetList<IgnorePointer>(find.ancestor(
              of: find.byType(DrawingOverlay),
              matching: find.byType(IgnorePointer)))
          .any((w) => w.ignoring);
      expect(ignoring, isTrue);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(draw(c).pendingPoint, isNotNull);
      // Tapped: finish.
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 50));
      expect(draw(c).pendingPoint, isNull);
      expect(draw(c).tool, DrawTool.drawRun);
    });
  });

  group('M3 — Enter repeats the last tool whichever path armed it', () {
    testWidgets('armed from the Draw panel API, Enter re-arms it',
        (tester) async {
      final c = await pumpApp(tester);
      await arm(tester, c, DrawTool.drawRiser); // the Draw panel's path
      await arm(tester, c, DrawTool.select);
      await click(tester, canvasRect(tester).center); // canvas keyboard
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(draw(c).tool, DrawTool.drawRiser);
    });
  });

  group('M4 — Esc backs out of an armed trim/extend first', () {
    testWidgets('Esc disarms and KEEPS the selection; the pill names the mode',
        (tester) async {
      final c = await pumpApp(
          tester,
          build: (s) => Network(nodes: [
                NetNode(id: 'a', sheetId: s, x: 300, y: 300, floorIndex: 0),
                NetNode(id: 'b', sheetId: s, x: 420, y: 300, floorIndex: 0),
              ], edges: const [
                NetEdge(
                    id: 'e1',
                    fromId: 'a',
                    toId: 'b',
                    service: ServiceType.coldWater),
              ]));
      await click(tester, canvasRect(tester).topLeft + const Offset(40, 300));
      c.read(selectionProvider.notifier).selectEdge('e1');
      c
          .read(trimExtendArmedProvider.notifier)
          .arm(const TrimExtendTarget('e1', 'b'));
      await tester.pump();
      expect(
          find.descendant(
              of: find.byType(ModePill), matching: find.text('Done')),
          findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(c.read(trimExtendArmedProvider), isNull);
      expect(c.read(selectionProvider).edgeId, 'e1',
          reason: 'the first Esc only disarms');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(c.read(selectionProvider).isEmpty, isTrue);
    });
  });

  group('M5 — F8 / F3 / F9', () {
    testWidgets('toggle ortho, snap-to-plan and grid snap', (tester) async {
      final c = await pumpApp(tester);
      await click(tester, canvasRect(tester).center);
      expect(c.read(orthoProvider), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      await tester.pump();
      expect(c.read(orthoProvider), isFalse);
      expect(c.read(snapToPlanProvider), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.f3);
      await tester.pump();
      expect(c.read(snapToPlanProvider), isFalse);
      expect(c.read(gridSnapProvider), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.f9);
      await tester.pump();
      expect(c.read(gridSnapProvider), isFalse);
      // They also work while the smart input bar holds the keyboard.
      await arm(tester, c, DrawTool.drawRun);
      await click(tester, canvasRect(tester).center);
      await tester.pump(const Duration(milliseconds: 50));
      expect(isTextEntryFocused(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      await tester.pump();
      expect(c.read(orthoProvider), isTrue);
      expect(draw(c).pendingPoint, isNotNull);
    });

    testWidgets('F9 off: the draw preview no longer offers the grid',
        (tester) async {
      final c = await pumpApp(tester);
      await arm(tester, c, DrawTool.drawRun);
      final p0 = canvasRect(tester).center;
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: p0);
      addTearDown(g.removePointer);
      await g.down(p0);
      await g.up();
      await tester.pump(const Duration(milliseconds: 120));
      // Hover near a grid crossing on the ortho ray (the calibrated 1-2-5 m
      // ladder at this zoom), then read the marker kind.
      RubberBandPainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<RubberBandPainter>()
          .first;
      var gridSeen = false;
      for (var dx = 30.0; dx < 400 && !gridSeen; dx += 7) {
        await g.moveTo(p0 + Offset(dx, 0));
        await tester.pump();
        gridSeen = painter().snapLabel == 'Grid';
      }
      expect(gridSeen, isTrue, reason: 'the grid snaps with F9 on');
      c.read(gridSnapProvider.notifier).set(false);
      await tester.pump();
      expect(painter().snapLabel == 'Grid', isFalse);
    });
  });

  group('M7 / L2 — crossing marquee and subtract', () {
    Network longRun(String s) => Network(nodes: [
          NetNode(id: 'a', sheetId: s, x: 100, y: 300, floorIndex: 0),
          NetNode(id: 'b', sheetId: s, x: 700, y: 300, floorIndex: 0),
        ], edges: const [
          NetEdge(
              id: 'e1', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
        ]);

    Future<void> marquee(
        WidgetTester tester, Offset from, Offset to) async {
      final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      for (var i = 1; i <= 6; i++) {
        await g.moveTo(Offset.lerp(from, to, i / 6)!);
        await tester.pump();
      }
      await g.up();
      await tester.pump();
    }

    testWidgets('right-to-left over the MIDDLE of a long run selects it; '
        'left-to-right (window) does not', (tester) async {
      final c = await pumpApp(tester, build: longRun);
      final mid = screenOf(tester, c, const Offset(400, 300));
      // Window: L->R over the middle only — both ends outside: nothing.
      await marquee(tester, mid + const Offset(-30, -30),
          mid + const Offset(30, 30));
      expect(c.read(selectionProvider).edgeIds, isEmpty);
      // Crossing: R->L over the same box — the run is cut through: selected.
      await marquee(tester, mid + const Offset(30, -30),
          mid + const Offset(-30, 30));
      expect(c.read(selectionProvider).edgeIds, {'e1'});
      // L2 — Ctrl+Shift crossing over it again REMOVES it.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await marquee(tester, mid + const Offset(30, -30),
          mid + const Offset(-30, 30));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(c.read(selectionProvider).edgeIds, isEmpty);
    });

    testWidgets('a crossing box over a riser foot selects the riser',
        (tester) async {
      final c = await pumpApp(
          tester,
          build: (s) => Network(nodes: [
                NetNode(id: 'r0', sheetId: s, x: 400, y: 300, floorIndex: 0),
                NetNode(id: 'r1', sheetId: s, x: 400, y: 300, floorIndex: 1),
              ], edges: const [
                NetEdge(
                    id: 'riser',
                    fromId: 'r0',
                    toId: 'r1',
                    service: ServiceType.coldWater,
                    kind: EdgeKind.riser),
              ]));
      final at = screenOf(tester, c, const Offset(400, 300));
      // Start the drag off the node (empty space), sweep R->L over it.
      await marquee(tester, at + const Offset(40, -40),
          at + const Offset(-40, 40));
      expect(c.read(selectionProvider).edgeIds, contains('riser'));
    });
  });

  group('H3 — the preview marker honours the commit rule', () {
    testWidgets('a cold-water draw over a duct junction / duct midpoint shows '
        'no marker; a cold-water node does', (tester) async {
      final c = await pumpApp(
          tester,
          build: (s) => Network(nodes: [
                NetNode(id: 'd0', sheetId: s, x: 300, y: 500, floorIndex: 0),
                NetNode(id: 'd1', sheetId: s, x: 300, y: 700, floorIndex: 0),
                NetNode(id: 'w0', sheetId: s, x: 600, y: 500, floorIndex: 0),
                NetNode(id: 'w1', sheetId: s, x: 600, y: 700, floorIndex: 0),
              ], edges: const [
                NetEdge(
                    id: 'duct',
                    fromId: 'd0',
                    toId: 'd1',
                    service: ServiceType.duct),
                NetEdge(
                    id: 'cw',
                    fromId: 'w0',
                    toId: 'w1',
                    service: ServiceType.coldWater),
              ]));
      c.read(networkControllerProvider.notifier).setService(
          ServiceType.coldWater);
      c.read(orthoProvider.notifier).toggle(); // free angle: hover is raw
      await arm(tester, c, DrawTool.drawRun);
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      final startAt = screenOf(tester, c, const Offset(450, 300));
      await g.addPointer(location: startAt);
      addTearDown(g.removePointer);
      await g.down(startAt);
      await g.up();
      await tester.pump(const Duration(milliseconds: 120));
      RubberBandPainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<RubberBandPainter>()
          .first;
      Future<void> hover(Offset world) async {
        await g.moveTo(screenOf(tester, c, world) + const Offset(2, 1));
        await tester.pump();
      }

      c.read(gridSnapProvider.notifier).set(false);
      c.read(snapToPlanProvider.notifier).set(false);
      await hover(const Offset(300, 500)); // the duct junction
      expect(painter().snapLabel, anyOf(isNull, 'Aligned'),
          reason: 'never a Node / Tee marker on the foreign duct');
      await hover(const Offset(300, 600)); // the duct midpoint
      expect(painter().snapLabel, anyOf(isNull, 'Aligned'));
      await hover(const Offset(600, 500)); // a cold-water node
      expect(painter().snapLabel, 'Node');
      await hover(const Offset(600, 600)); // beside the cold-water midpoint
      // Both are honest same-service attach points (the tee projection wins
      // when it is nearer than the exact midpoint).
      expect(painter().snapLabel, anyOf('Midpoint', 'Tee'));
    });
  });

  group('P14 — a tool switch with auto-pan latched does not throw', () {
    testWidgets('V while the draw probe is set', (tester) async {
      final c = await pumpApp(tester);
      await arm(tester, c, DrawTool.drawRun);
      await click(tester, canvasRect(tester).center);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape); // canvas focus
      await tester.pump();
      c.read(canvasAutoPanProbeProvider.notifier).set(const Offset(2, 2));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(draw(c).tool, DrawTool.select);
      expect(c.read(canvasAutoPanProbeProvider), isNull);
    });
  });

  group('P1 / P3 / P13 — frame-cost isolation (identity pins)', () {
    testWidgets('each canvas layer paints into its own RepaintBoundary',
        (tester) async {
      await pumpApp(tester);
      bool boundaryParent(Finder f) {
        final el = f.evaluate().single;
        RepaintBoundary? nearest;
        el.visitAncestorElements((a) {
          if (a.widget is RepaintBoundary) {
            nearest = a.widget as RepaintBoundary;
            return false;
          }
          // Stop at the canvas Stack — a boundary above it is the shared one.
          return a.widget is! Stack;
        });
        return nearest != null;
      }

      expect(boundaryParent(find.byType(NetworkLayer)), isTrue);
      expect(boundaryParent(find.byType(NetworkSelectionOverlay)), isTrue);
    });

    testWidgets('a hover change does not rebuild the node-handle layer; a pan '
        'at the same zoom does not rebuild the zoom cluster', (tester) async {
      final c = await pumpApp(
          tester,
          build: (s) => Network(nodes: [
                NetNode(id: 'a', sheetId: s, x: 300, y: 300, floorIndex: 0),
              ]));
      final handles = find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_NodeHandlesLayer');
      final before = tester.widget(handles);
      c.read(hoverTargetProvider.notifier).set((nodeId: 'a', edgeId: null));
      await tester.pump();
      expect(identical(tester.widget(handles), before), isTrue);

      final zoom0 = tester.widget(find.byType(ZoomControls));
      final vt = c.read(sheetViewportProvider(sheetId))!;
      c
          .read(sheetsControllerProvider.notifier)
          .setViewport(sheetId, vt.panned(const Offset(25, 10)));
      await tester.pump();
      expect(identical(tester.widget(find.byType(ZoomControls)), zoom0), isTrue);
    });
  });
}
