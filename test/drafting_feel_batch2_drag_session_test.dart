import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/ui/canvas/canvas_view.dart';
import 'package:mechx/ui/canvas/viewport.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';

import 'test_util.dart';

/// Reviewer-verified K1 / viewport defects of the drafting-feel perf batch:
///   1. a POINTER drag opens the K1 drag session (sizing frozen per frame,
///      refreshed on release);
///   2. an open session can never lack its settle timer, and replacing the
///      network (load / undo / redo / restore) closes it;
///   3. the Layout canvas remounts at the LIVE viewport, not the stale
///      content snapshot's.
void main() {
  ProviderContainer containerOf(WidgetTester t) => ProviderScope.containerOf(
      t.element(find.byType(MechXApp)),
      listen: false);

  late String sheetId;

  Network run(String s) => Network(nodes: [
        NetNode(id: 'a', sheetId: s, x: 300, y: 300, floorIndex: 0),
        NetNode(id: 'b', sheetId: s, x: 600, y: 300, floorIndex: 0),
        NetNode(
            id: 'f',
            sheetId: s,
            x: 600,
            y: 450,
            floorIndex: 0,
            role: NodeRole.fixture),
      ], edges: const [
        NetEdge(id: 'e1', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
        NetEdge(id: 'e2', fromId: 'b', toId: 'f', service: ServiceType.coldWater),
      ]);

  Future<ProviderContainer> pumpApp(WidgetTester tester,
      {Network Function(String)? build}) async {
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

  Offset screenOf(WidgetTester tester, ProviderContainer c, Offset world) {
    final vt =
        c.read(sheetViewportProvider(sheetId)) ?? const ViewportTransform();
    return tester.getRect(find.byType(CanvasView).first).topLeft +
        vt.worldToScreen(world);
  }

  testWidgets('1: a real pointer drag of a node freezes sizing on every move '
      'frame and refreshes it on release', (tester) async {
    final c = await pumpApp(tester, build: run);
    final before = c.read(sizingProvider);
    expect(before, isNotEmpty);
    final g = await tester.startGesture(
        screenOf(tester, c, const Offset(300, 300)) + const Offset(9, 0),
        kind: PointerDeviceKind.mouse);
    for (var i = 1; i <= 8; i++) {
      await g.moveBy(const Offset(0, 12));
      await tester.pump(const Duration(milliseconds: 16));
      if (i > 2) {
        expect(c.read(dragSessionProvider).active, isTrue,
            reason: 'the drag opened the K1 session');
        expect(identical(c.read(sizingProvider), before), isTrue,
            reason: 'frame $i must not re-size the network');
      }
    }
    expect(c.read(networkControllerProvider).network.nodeById('a')!.y,
        greaterThan(300), reason: 'the node really moved');
    await g.up();
    await tester.pump();
    expect(c.read(dragSessionProvider).active, isFalse);
    expect(identical(c.read(sizingProvider), before), isFalse,
        reason: 'the release refreshes the heavy chain');
  });

  test('2a: beginDrag alone arms the settle timer (never an open session '
      'without one)', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final drag = c.read(dragSessionProvider.notifier);
    drag.throttleInterval = const Duration(milliseconds: 30);
    drag.beginDrag();
    expect(c.read(dragSessionProvider).active, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(c.read(dragSessionProvider).active, isFalse);
  });

  test('2b: undo / redo / load / restore close an open session', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(networkControllerProvider.notifier);
    final drag = c.read(dragSessionProvider.notifier);
    n.setTool(DrawTool.drawRun);
    n.placeRunPoint('s1', 0, const Offset(0, 0));
    n.placeRunPoint('s1', 0, const Offset(100, 0));
    for (final replace in <void Function()>[
      n.undo,
      n.redo,
      () => n.restoreNetwork(const Network()),
      () => n.loadNetwork(const Network()),
    ]) {
      drag.beginDrag();
      expect(c.read(dragSessionProvider).active, isTrue);
      replace();
      expect(c.read(dragSessionProvider).active, isFalse);
      expect(identical(c.read(sizingNetworkProvider),
              c.read(networkControllerProvider).network),
          isTrue);
    }
  });

  testWidgets('2c: Ctrl+A, undo, ArrowRight, then Open shows the OPENED '
      'network to the heavy chain at once', (tester) async {
    final c = await pumpApp(tester);
    final n = c.read(networkControllerProvider.notifier);
    n.setTool(DrawTool.drawRun);
    n.placeRunPoint(sheetId, 0, const Offset(300, 300));
    n.placeRunPoint(sheetId, 0, const Offset(500, 300));
    n.setTool(DrawTool.select);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(tester.getRect(find.byType(CanvasView).first).topLeft +
        const Offset(40, 40));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(c.read(selectionProvider).hasSelection, isTrue);
    c.read(historyProvider.notifier).undo(); // the run is gone, ids stale
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(c.read(dragSessionProvider).active, isFalse,
        reason: 'a stale selection opens no session');
    final other = run(sheetId);
    n.loadNetwork(other);
    expect(identical(c.read(sizingNetworkProvider), other), isTrue);
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('3: Layout -> Riser -> Layout restores the LIVE zoom',
      (tester) async {
    final c = await pumpApp(tester, build: run);
    final canvas =
        tester.state<CanvasViewState>(find.byType(CanvasView).first);
    canvas.zoomTo(2.5);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50)); // the eased zoom
    }
    final live = c.read(sheetViewportProvider(sheetId))!;
    expect(live.scale, closeTo(2.5, 1e-9));
    c.read(workspaceViewProvider.notifier).set(WorkspaceView.schematic);
    await tester.pump(const Duration(milliseconds: 300));
    c.read(workspaceViewProvider.notifier).set(WorkspaceView.plan);
    await tester.pump(const Duration(milliseconds: 300));
    final remounted = tester.widget<CanvasView>(find.byType(CanvasView).first);
    expect(remounted.initialTransform, live,
        reason: 'seeded from the live viewport, not the stale snapshot');
    expect(c.read(sheetViewportProvider(sheetId)), live,
        reason: 'no re-fit on remount');
  });
}
