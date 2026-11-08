import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/base_point_command_store.dart';
import 'package:mechx/store/calibration_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/smart_input_store.dart';
import 'package:mechx/ui/canvas/base_point_overlay.dart';
import 'package:mechx/ui/canvas/canvas_view.dart';
import 'package:mechx/ui/canvas/mode_pill.dart';
import 'package:mechx/ui/canvas/smart_input_bar.dart';
import 'package:mechx/ui/canvas/viewport.dart';
import 'package:mechx/ui/shell/shell_shortcuts.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';

import 'test_util.dart';

/// Drafting-feel batch 5 — the remaining AutoCAD-convention commands on the
/// Layout canvas, driven through the FULL app (real focus tree, real key and
/// pointer routing): M9 typed coordinates, the typed length that finishes a
/// grip stretch, M8 base-point Move / Copy / Rotate, double-middle-click zoom
/// extents and Shift+Space selection cycling. Store halves:
/// `drafting_feel_batch5_store_test.dart`.
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

  Network twoNodeRun(String s) => Network(nodes: [
        NetNode(id: 'a', sheetId: s, x: 300, y: 300, floorIndex: 0),
        NetNode(id: 'b', sheetId: s, x: 400, y: 300, floorIndex: 0),
      ], edges: const [
        NetEdge(id: 'e1', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
      ]);

  Rect canvasRect(WidgetTester tester) =>
      tester.getRect(find.byType(CanvasView).first);

  Offset screenOf(WidgetTester tester, ProviderContainer c, Offset world) {
    final vt =
        c.read(sheetViewportProvider(sheetId)) ?? const ViewportTransform();
    return canvasRect(tester).topLeft + vt.worldToScreen(world);
  }

  Future<void> click(WidgetTester tester, Offset at) async {
    await tester.tapAt(at, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 120));
  }

  /// Type [text] key by key (each key carrying its character), the way the
  /// canvas receives it.
  Future<void> type(WidgetTester tester, String text) async {
    const keys = <String, LogicalKeyboardKey>{
      '0': LogicalKeyboardKey.digit0,
      '1': LogicalKeyboardKey.digit1,
      '2': LogicalKeyboardKey.digit2,
      '3': LogicalKeyboardKey.digit3,
      '4': LogicalKeyboardKey.digit4,
      '5': LogicalKeyboardKey.digit5,
      '6': LogicalKeyboardKey.digit6,
      '7': LogicalKeyboardKey.digit7,
      '8': LogicalKeyboardKey.digit8,
      '9': LogicalKeyboardKey.digit9,
      '@': LogicalKeyboardKey.at,
      ',': LogicalKeyboardKey.comma,
      ';': LogicalKeyboardKey.semicolon,
      // Shift+comma on a US layout (the logical key is the unshifted one;
      // the canvas reads the CHARACTER).
      '<': LogicalKeyboardKey.comma,
      '-': LogicalKeyboardKey.minus,
      '.': LogicalKeyboardKey.period,
    };
    // The shifted marks ride a real Shift + their US-layout physical key.
    const shifted = <String, PhysicalKeyboardKey>{
      '@': PhysicalKeyboardKey.digit2,
      '<': PhysicalKeyboardKey.comma,
    };
    for (final ch in text.split('')) {
      final phys = shifted[ch];
      if (phys != null) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      }
      await tester.sendKeyEvent(keys[ch]!, character: ch, physicalKey: phys);
      if (phys != null) {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      }
    }
    await tester.pump();
  }

  Future<void> enter(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 50));
  }

  Network net(ProviderContainer c) =>
      c.read(networkControllerProvider).network;
  Offset at(ProviderContainer c, String id) {
    final n = net(c).nodeById(id)!;
    return Offset(n.x, n.y);
  }

  String? pillText(WidgetTester tester) {
    final texts = tester
        .widgetList<Text>(find.descendant(
            of: find.byType(ModePill), matching: find.byType(Text)))
        .map((t) => t.data)
        .toList();
    return texts.isEmpty ? null : texts.first;
  }

  group('M9 — typed coordinates while drawing a run', () {
    testWidgets('@1000,-500 Enter lands 1 m east and 0.5 m SOUTH (+y is up)',
        (tester) async {
      final c = await pumpApp(tester);
      c.read(networkControllerProvider.notifier).setTool(DrawTool.drawRun);
      await tester.pump(const Duration(milliseconds: 100));
      await click(tester, canvasRect(tester).center);
      final start = c.read(networkControllerProvider).pendingPoint!;
      await type(tester, '@1000,-500');
      expect(find.textContaining('@ x 1.00 m, y -0.50 m'), findsOneWidget,
          reason: 'the bar reads the parsed entry back');
      await enter(tester);
      final e = net(c).edges.single;
      final end = at(c, e.toId);
      expect(end.dx - start.dx, closeTo(100, 1e-9));
      expect(end.dy - start.dy, closeTo(50, 1e-9),
          reason: 'AutoCAD -y is DOWN the screen (screen y grows downward)');
      expect(c.read(networkControllerProvider).pendingPoint, end,
          reason: 'the chain continues from the typed point');
    });

    testWidgets('2000<90 is polar: 2 m due north (0 = east, CCW +)',
        (tester) async {
      final c = await pumpApp(tester);
      c.read(networkControllerProvider.notifier).setTool(DrawTool.drawRun);
      await tester.pump(const Duration(milliseconds: 100));
      await click(tester, canvasRect(tester).center);
      final start = c.read(networkControllerProvider).pendingPoint!;
      await type(tester, '2000<90');
      await enter(tester);
      final end = at(c, net(c).edges.single.toId);
      expect(end.dx - start.dx, closeTo(0, 1e-9));
      expect(end.dy - start.dy, closeTo(-200, 1e-9));
    });
  });

  group('M8 — base-point Move / Copy / Rotate', () {
    testWidgets('G: pick the base on a node, type @500,0 — the selection '
        'moves 0.5 m east in ONE undo step and the command ends',
        (tester) async {
      final c = await pumpApp(tester, build: twoNodeRun);
      await click(tester, canvasRect(tester).topLeft + const Offset(40, 300));
      c.read(selectionProvider.notifier).selectEdge('e1');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      await tester.pump();
      expect(c.read(basePointCommandProvider)?.kind, BasePointCommandKind.move);
      expect(pillText(tester), 'Move · pick base point');
      // A digit while the base is still to be picked types nothing and never
      // re-picks the service.
      final svc = c.read(networkControllerProvider).service;
      await type(tester, '3');
      expect(c.read(networkControllerProvider).service, svc);
      // Click near (not exactly on) node a: the base snaps onto it.
      await click(tester,
          screenOf(tester, c, const Offset(300, 300)) + const Offset(3, -2));
      expect(c.read(basePointCommandProvider)!.base, const Offset(300, 300));
      expect(pillText(tester), 'Move · pick target or type @x,y');
      expect(find.byType(SmartInputBar), findsOneWidget);
      expect(find.text('Move'), findsOneWidget, reason: 'the bar label');
      await type(tester, '@500,0');
      await enter(tester);
      expect(c.read(basePointCommandProvider), isNull);
      expect(at(c, 'a'), const Offset(350, 300));
      expect(at(c, 'b'), const Offset(450, 300));
      expect(c.read(selectionProvider).edgeId, 'e1',
          reason: 'the moved selection stays selected');
      c.read(historyProvider.notifier).undo();
      await tester.pump();
      expect(at(c, 'a'), const Offset(300, 300));
    });

    testWidgets('G then a CLICKED target snaps onto a node', (tester) async {
      final c = await pumpApp(
          tester,
          build: (s) => Network(nodes: [
                ...twoNodeRun(s).nodes,
                NetNode(id: 'x', sheetId: s, x: 600, y: 300, floorIndex: 0),
              ], edges: twoNodeRun(s).edges));
      // The hovering mouse is added BEFORE any click (one mouse device).
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: canvasRect(tester).topLeft);
      await click(tester, canvasRect(tester).topLeft + const Offset(40, 300));
      c.read(selectionProvider.notifier).selectEdge('e1');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      await tester.pump();
      await click(tester, screenOf(tester, c, const Offset(300, 300)));
      // Hovering paints the ghost + the rubber band with its OSNAP chip.
      final target =
          screenOf(tester, c, const Offset(600, 300)) + const Offset(2, 3);
      await mouse.moveTo(target - const Offset(30, 0));
      await mouse.moveTo(target);
      await tester.pump();
      expect(find.byType(BasePointOverlay), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(at(c, 'a'), const Offset(300, 300),
          reason: 'the preview moves nothing');
      // The target click lands a few px off node x: the node snap wins, and
      // the moved end that lands ON x JOINS it (review: no stacked twin).
      await click(tester, target);
      final net = c.read(networkControllerProvider).network;
      expect(net.nodeById('a'), isNull, reason: 'a joined x');
      expect(net.edgeById('e1')!.fromId, 'x');
      expect(at(c, 'b'), const Offset(700, 300));
    });

    testWidgets('C is COPY-multiple: every typed target places a fresh-id '
        'copy of the originals, Enter ends, each placement undoes alone',
        (tester) async {
      final c = await pumpApp(tester, build: twoNodeRun);
      await click(tester, canvasRect(tester).topLeft + const Offset(40, 300));
      c.read(selectionProvider.notifier).selectEdge('e1');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.pump();
      await click(tester, screenOf(tester, c, const Offset(300, 300)));
      await type(tester, '@0,1000');
      await enter(tester);
      expect(pillText(tester), 'Copy · 1 placed · next target, Enter ends');
      await type(tester, '@0;2000'); // the locale-safe separator
      await enter(tester);
      expect(c.read(basePointCommandProvider)?.placed, 2);
      expect(net(c).edges, hasLength(3));
      expect({for (final n in net(c).nodes) n.y}, {300.0, 200.0, 100.0},
          reason: 'copies are relative to the ORIGINALS (+y up)');
      expect(at(c, 'a'), const Offset(300, 300), reason: 'originals stay');
      await enter(tester); // nothing typed: ends the command
      expect(c.read(basePointCommandProvider), isNull);
      c.read(historyProvider.notifier).undo();
      await tester.pump();
      expect(net(c).edges, hasLength(2));
    });

    testWidgets('T: pick the pivot, type 90 — the run turns NORTH about it',
        (tester) async {
      final c = await pumpApp(tester, build: twoNodeRun);
      await click(tester, canvasRect(tester).topLeft + const Offset(40, 300));
      c.read(selectionProvider.notifier).selectEdge('e1');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await tester.pump();
      expect(pillText(tester), 'Rotate · pick base point');
      await click(tester, screenOf(tester, c, const Offset(300, 300)));
      expect(find.text('Angle'), findsOneWidget);
      await type(tester, '90');
      expect(find.textContaining('counter-clockwise'), findsOneWidget);
      await enter(tester);
      expect(c.read(basePointCommandProvider), isNull);
      expect(at(c, 'a'), const Offset(300, 300));
      expect(at(c, 'b'), const Offset(300, 200));
    });

    testWidgets('T with a CLICKED bearing (ortho on): the pick sets the angle '
        'in exact 45 deg steps', (tester) async {
      final c = await pumpApp(tester, build: twoNodeRun);
      expect(c.read(orthoProvider), isTrue);
      await click(tester, canvasRect(tester).topLeft + const Offset(40, 300));
      c.read(selectionProvider.notifier).selectEdge('e1');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await tester.pump();
      await click(tester, screenOf(tester, c, const Offset(300, 300)));
      // A bearing a little off due-south-west: ortho rounds it to 225 deg.
      await click(tester, screenOf(tester, c, const Offset(250, 356)));
      final b = at(c, 'b') - at(c, 'a');
      expect(b.dx.abs(), b.dy.abs(), reason: 'exactly diagonal');
      expect(b.dx, lessThan(0));
      expect(b.dy, greaterThan(0));
    });

    testWidgets('Esc backs out of the command FIRST, keeping the selection; '
        'right-click cancels too', (tester) async {
      final c = await pumpApp(tester, build: twoNodeRun);
      await click(tester, canvasRect(tester).topLeft + const Offset(40, 300));
      c.read(selectionProvider.notifier).selectEdge('e1');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      await tester.pump();
      await click(tester, screenOf(tester, c, const Offset(300, 300)));
      await type(tester, '12');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(c.read(basePointCommandProvider), isNotNull,
          reason: 'the first Esc clears the typed text');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(c.read(basePointCommandProvider), isNull);
      expect(c.read(selectionProvider).edgeId, 'e1');
      expect(at(c, 'a'), const Offset(300, 300));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.pump();
      expect(c.read(basePointCommandProvider), isNotNull);
      final g = await tester.startGesture(canvasRect(tester).center,
          kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await g.up();
      await tester.pump();
      expect(c.read(basePointCommandProvider), isNull);
    });

    testWidgets('with nothing selected, G arms nothing and says why',
        (tester) async {
      final c = await pumpApp(tester, build: twoNodeRun);
      await click(tester, canvasRect(tester).topLeft + const Offset(40, 300));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      await tester.pump();
      expect(c.read(basePointCommandProvider), isNull);
      expect(find.textContaining('Select something on this sheet first'),
          findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('the run context menu arms Move from base point',
        (tester) async {
      final c = await pumpApp(tester, build: twoNodeRun);
      final mid = screenOf(tester, c, const Offset(350, 300));
      final g = await tester.startGesture(mid,
          kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
      final row = find.text('Move from base point   G');
      await tester.ensureVisible(row);
      await tester.pump();
      await tester.tap(row);
      await tester.pump(const Duration(milliseconds: 100));
      final cmd = c.read(basePointCommandProvider)!;
      expect(cmd.kind, BasePointCommandKind.move);
      expect(cmd.edgeIds, {'e1'});
      expect(cmd.pickingBase, isTrue);
    });
  });

  group('Item 2 — typing a length while stretching a run end', () {
    testWidgets('drag the free end, type 3000 Enter: the run is exactly 3 m '
        'along the drag; the rest of the drag is inert; one undo step',
        (tester) async {
      final c = await pumpApp(tester, build: twoNodeRun);
      await click(tester, canvasRect(tester).topLeft + const Offset(40, 300));
      c.read(selectionProvider.notifier).selectNode('b');
      await tester.pump();
      final from = screenOf(tester, c, const Offset(400, 300));
      final g =
          await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      for (var i = 1; i <= 4; i++) {
        await g.moveTo(from + Offset(10.0 * i, 0));
        await tester.pump();
      }
      expect(c.read(endpointStretchProvider)?.nodeId, 'b');
      expect(find.byType(SmartInputBar), findsOneWidget);
      await type(tester, '3000');
      await enter(tester);
      expect((at(c, 'b') - at(c, 'a')).distance, closeTo(300, 1e-9));
      expect(at(c, 'b').dy, closeTo(300, 1e-9), reason: 'along the drag');
      // The pointer keeps moving, then releases: nothing changes.
      await g.moveTo(from + const Offset(90, 40));
      await tester.pump();
      await g.up();
      await tester.pump(const Duration(milliseconds: 50));
      expect(at(c, 'b'), const Offset(600, 300));
      expect(c.read(endpointStretchProvider), isNull);
      c.read(historyProvider.notifier).undo();
      await tester.pump();
      expect(at(c, 'b'), const Offset(400, 300),
          reason: 'the drag + typed length were ONE step');
    });
  });

  group('Item 5 — double-middle-click zooms to the drawing extents', () {
    testWidgets('frames the drawn nodes; a single middle-drag still pans',
        (tester) async {
      final c = await pumpApp(tester, build: twoNodeRun);
      final before = c.read(sheetViewportProvider(sheetId))!;
      // Middle-drag pans.
      final p = canvasRect(tester).center;
      final g = await tester.startGesture(p,
          kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
      await g.moveBy(const Offset(40, 0));
      await tester.pump();
      await g.up();
      await tester.pump();
      final panned = c.read(sheetViewportProvider(sheetId))!;
      expect(panned.offset.dx - before.offset.dx, closeTo(40, 1e-6));
      // Double middle-click: zoom extents.
      for (var i = 0; i < 2; i++) {
        final m = await tester.startGesture(p,
            kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
        await m.up();
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pump(const Duration(milliseconds: 600));
      final vt = c.read(sheetViewportProvider(sheetId))!;
      expect(vt.scale, greaterThan(panned.scale),
          reason: 'a 1 m run fills the view');
      final rect = canvasRect(tester);
      final mid = vt.worldToScreen(const Offset(350, 300));
      expect(mid.dx, closeTo(rect.width / 2, 1));
      expect(mid.dy, closeTo(rect.height / 2, 1));
    });
  });

  testWidgets('Item 5 — reduced motion: zoom extents JUMPS (no ease)',
      (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final c = await pumpApp(tester, build: twoNodeRun);
    final p = canvasRect(tester).center;
    final before = c.read(sheetViewportProvider(sheetId))!.scale;
    for (var i = 0; i < 2; i++) {
      final m = await tester.startGesture(p,
          kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
      await m.up();
      await tester.pump(const Duration(milliseconds: 40));
    }
    // One frame later (no animation time) the view is already framed.
    final vt = c.read(sheetViewportProvider(sheetId))!;
    expect(vt.scale, greaterThan(before));
    final mid = vt.worldToScreen(const Offset(350, 300));
    expect(mid.dx, closeTo(canvasRect(tester).width / 2, 1));
  });

  group('Item 6 — Shift+Space cycles the pick under the cursor', () {
    testWidgets('a loose node lying on a run: the click takes the node, '
        'Shift+Space walks to the run and back', (tester) async {
      final c = await pumpApp(
          tester,
          build: (s) => Network(nodes: [
                ...twoNodeRun(s).nodes,
                NetNode(id: 'n', sheetId: s, x: 350, y: 300, floorIndex: 0),
              ], edges: twoNodeRun(s).edges));
      final spot = screenOf(tester, c, const Offset(350, 300));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: spot + const Offset(0, 20));
      await mouse.moveTo(spot);
      await tester.pump();
      await click(tester, spot);
      expect(c.read(selectionProvider).nodeId, 'n');
      Future<void> shiftSpace() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
      }

      await shiftSpace();
      expect(c.read(selectionProvider).edgeId, 'e1');
      expect(c.read(hoverTargetProvider), (nodeId: null, edgeId: 'e1'),
          reason: 'the halo follows the cycled candidate');
      expect(find.textContaining('2 of 2 under the cursor'), findsOneWidget);
      await shiftSpace();
      expect(c.read(selectionProvider).nodeId, 'n');
      expect(find.byType(BasePointOverlay), findsNothing,
          reason: 'Shift+Space never engages the hold-Space pan / a command');
      await tester.pump(const Duration(seconds: 4));
    });
  });

  test('the F1 sheet documents every new binding', () {
    final docs = {
      for (final g in kCanvasShortcutGroups)
        for (final d in g.shortcuts) d.keys,
    };
    for (final k in [
      'G',
      'C',
      'T',
      '@ x,y',
      'len < ang',
      'Shift Space',
      'Double middle-click',
      'Drag end + 0 - 9',
    ]) {
      expect(docs, contains(k));
    }
  });

  group('review fixes (Fable, batch 5)', () {
    testWidgets('two quick SHORT middle-drags pan twice — never zoom extents',
        (tester) async {
      final c = await pumpApp(tester, build: twoNodeRun);
      final before = c.read(sheetViewportProvider(sheetId))!;
      final p = canvasRect(tester).center;
      for (var i = 0; i < 2; i++) {
        final g = await tester.startGesture(p,
            kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
        await g.moveBy(const Offset(20, 0));
        await tester.pump();
        await g.up();
        await tester.pump(const Duration(milliseconds: 40));
      }
      await tester.pump(const Duration(milliseconds: 600));
      final vt = c.read(sheetViewportProvider(sheetId))!;
      expect(vt.scale, before.scale, reason: 'no zoom extents');
      expect(vt.offset.dx - before.offset.dx, closeTo(40, 1e-6));
    });

    testWidgets('a trackpad pan still works after a middle-button press on '
        'a host-owned-middle canvas', (tester) async {
      ViewportTransform? live;
      await tester.pumpWidget(ProviderScope(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: CanvasView(
            contentSize: const Size(1000, 800),
            initialTransform: const ViewportTransform(),
            onTransformChanged: (t) => live = t,
            background: const Color(0xFF000000),
            externalMiddlePan: true,
            child: const SizedBox(width: 1000, height: 800),
          ),
        ),
      ));
      await tester.pump();
      final p = tester.getCenter(find.byType(CanvasView));
      final m = await tester.startGesture(p,
          kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
      await m.up();
      await tester.pump();
      final before = live ?? const ViewportTransform();
      final pad = await tester.createGesture(kind: PointerDeviceKind.trackpad);
      await pad.panZoomStart(p);
      await tester.pump();
      await pad.panZoomUpdate(p, pan: const Offset(0, 50));
      await tester.pump();
      await pad.panZoomEnd();
      await tester.pump();
      expect((live ?? before).offset.dy - before.offset.dy,
          isNot(closeTo(0, 1e-6)),
          reason: 'the trackpad pan reached the canvas');
    });

    testWidgets('G during scale-point picking arms nothing; leaving the '
        'mechanical layer cancels an armed command', (tester) async {
      final c = await pumpApp(tester, build: twoNodeRun);
      c.read(selectionProvider.notifier).selectEdge('e1');
      c.read(calibrationControllerProvider.notifier).start();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      await tester.pump();
      expect(c.read(basePointCommandProvider), isNull);
      c.read(calibrationControllerProvider.notifier).cancel();
      await tester.pump();

      c.read(selectionProvider.notifier).selectEdge('e1');
      await click(tester, canvasRect(tester).topLeft + const Offset(40, 300));
      c.read(selectionProvider.notifier).selectEdge('e1');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      await tester.pump();
      expect(c.read(basePointCommandProvider), isNotNull);
      c
          .read(activeDisciplineProvider.notifier)
          .set(DisciplineLayer.electrical);
      await tester.pump();
      expect(c.read(basePointCommandProvider), isNull);
    });
  });
}
