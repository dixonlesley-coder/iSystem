import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import "package:mechx/ui/canvas/network_layer.dart";
import "package:flutter/rendering.dart";
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/canvas/viewport.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

class _Obs extends ProviderObserver {
  final counts = <String, int>{};
  bool on = false;
  final gaps = <String, int>{};
  final clock = Stopwatch()..start();
  int last = 0;
  @override
  void didUpdateProvider(ProviderBase<Object?> provider, Object? previousValue,
      Object? newValue, ProviderContainer container) {
    if (!on) return;
    final now = clock.elapsedMicroseconds;
    final k = provider.name ?? provider.toString();
    counts[k] = (counts[k] ?? 0) + 1;
    gaps[k] = (gaps[k] ?? 0) + (now - last);
    last = now;
  }
}

Network bigNet(int floors, int branches) {
  final nodes = <NetNode>[];
  final edges = <NetEdge>[];
  var e = 0;
  void edge(String a, String b, ServiceType s, [EdgeKind k = EdgeKind.run]) =>
      edges.add(NetEdge(id: 'e${e++}', fromId: a, toId: b, service: s, kind: k));
  for (var f = 0; f < floors; f++) {
    final sh = 'f$f';
    // cold water main
    nodes.add(NetNode(id: 'cw$f-h', sheetId: sh, x: 100, y: 100, floorIndex: f));
    var prev = 'cw$f-h';
    for (var b = 0; b < branches; b++) {
      final t = 'cw$f-t$b';
      nodes.add(NetNode(id: t, sheetId: sh, x: 200.0 + b * 60, y: 100, floorIndex: f));
      edge(prev, t, ServiceType.coldWater);
      final fx = 'cw$f-x$b';
      nodes.add(NetNode(
          id: fx, sheetId: sh, x: 200.0 + b * 60, y: 200, floorIndex: f,
          role: NodeRole.fixture,
          fixture: b.isEven ? PlumbingFixture.lavatory : PlumbingFixture.waterClosetFlushTank));
      edge(t, fx, ServiceType.coldWater);
      prev = t;
    }
    // drainage main
    nodes.add(NetNode(id: 'dr$f-h', sheetId: sh, x: 100, y: 400, floorIndex: f));
    var dprev = 'dr$f-h';
    for (var b = 0; b < branches; b++) {
      final t = 'dr$f-t$b';
      nodes.add(NetNode(id: t, sheetId: sh, x: 200.0 + b * 60, y: 400, floorIndex: f));
      edge(t, dprev, ServiceType.drainage);
      edge('cw$f-x$b', t, ServiceType.drainage);
      dprev = t;
    }
    // supply air
    nodes.add(NetNode(id: 'sa$f-h', sheetId: sh, x: 100, y: 700, floorIndex: f));
    var aprev = 'sa$f-h';
    for (var b = 0; b < branches ~/ 2; b++) {
      final t = 'sa$f-t$b';
      nodes.add(NetNode(id: t, sheetId: sh, x: 200.0 + b * 120, y: 700, floorIndex: f));
      edge(aprev, t, ServiceType.duct);
      final d = 'sa$f-d$b';
      nodes.add(NetNode(
          id: d, sheetId: sh, x: 200.0 + b * 120, y: 800, floorIndex: f,
          role: NodeRole.fixture, component: NodeComponent.supplyDiffuser,
          airflow: FlowRate.litersPerSecond(100)));
      edge(t, d, ServiceType.duct);
      aprev = t;
    }
    if (f > 0) {
      edge('cw${f - 1}-h', 'cw$f-h', ServiceType.coldWater, EdgeKind.riser);
      edge('dr$f-h', 'dr${f - 1}-h', ServiceType.drainage, EdgeKind.riser);
    }
  }
  nodes.add(const NetNode(
      id: 'pump', sheetId: 'f0', x: 20, y: 100, floorIndex: 0,
      role: NodeRole.plant, component: NodeComponent.pump));
  edge('pump', 'cw0-h', ServiceType.coldWater);
  nodes.add(const NetNode(
      id: 'ahu', sheetId: 'f0', x: 20, y: 700, floorIndex: 0,
      role: NodeRole.plant, component: NodeComponent.ahu));
  edge('ahu', 'sa0-h', ServiceType.duct);
  return Network(nodes: nodes, edges: edges);
}


void main() {
  testWidgets('interaction probe', (tester) async {
    setDesktopSurface(tester, size: const Size(1440, 900));
    final obs = _Obs();
    await tester.pumpWidget(ProviderScope(observers: [obs], child: const MechXApp()));
    await tester.pump();
    final c = ProviderScope.containerOf(tester.element(find.byType(MechXApp)), listen: false);
    const floors = 30, branches = 24;
    c.read(sheetsControllerProvider.notifier).loadSheets([
      for (var f = 0; f < floors; f++)
        Sheet(id: 'f$f', name: 'L$f', sizePx: const Size(1684, 1190)),
    ]);
    c.read(projectControllerProvider.notifier).setFloors([
      for (var f = 0; f < floors; f++) Floor('L$f', const Length(3.5)),
    ]);
    for (var f = 0; f < floors; f++) {
      c.read(projectControllerProvider.notifier).setCalibration('f$f', const ScaleCalibration(0.01));
    }
    c.read(networkControllerProvider.notifier).loadNetwork(bigNet(floors, branches));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    c.read(sheetsControllerProvider.notifier).selectSheet(5);
    await tester.pump();
    c.read(sheetsControllerProvider.notifier).setViewport('f5', const ViewportTransform(scale: 0.6, offset: Offset(0, 0)));
    await tester.pump(const Duration(milliseconds: 300));
    final layerRect = tester.getRect(find.byType(NetworkLayer));
    Offset scr(double wx, double wy) {
      final t = c.read(sheetViewportProvider('f5'))!;
      return layerRect.topLeft + t.worldToScreen(Offset(wx, wy));
    }
    print('layer rect $layerRect');
    RenderObject boundaryOf(RenderObject r) { var o = r; while (!o.isRepaintBoundary) { o = o.parent!; } return o; }
    final netRo = tester.renderObject(find.descendant(of: find.byType(NetworkLayer), matching: find.byType(CustomPaint)).first);
    final b1 = boundaryOf(netRo);
    print('NetworkLayer boundary: ${b1.runtimeType}#${identityHashCode(b1)} size ${(b1 as RenderBox).size}');
    for (final cp in tester.renderObjectList(find.byType(CustomPaint))) {
      final b = boundaryOf(cp);
      if (identical(b, b1)) print('  shares boundary: ${(cp as RenderCustomPaint).painter?.runtimeType} / fg ${cp.foregroundPainter?.runtimeType}');
    }


    Future<void> measure(String label, Future<void> Function(int i) act, {int reps = 6, bool rebuilt = false}) async {
      obs.counts.clear();
      obs.gaps.clear();
      obs.on = true;
      final acts = <int>[]; final builds = <int>[]; final pts = <int>[];
      final rb = <String, int>{};
      if (rebuilt) {
        debugOnRebuildDirtyWidget = (e, b) { final k = e.widget.runtimeType.toString(); rb[k] = (rb[k] ?? 0) + 1; };
      }
      for (var i = 0; i < reps; i++) {
        final sw = Stopwatch()..start();
        obs.last = obs.clock.elapsedMicroseconds;
        await act(i);
        final t0 = sw.elapsedMicroseconds;
        final b = tester.binding;
        b.buildOwner!.buildScope(b.rootElement!);
        final t1 = sw.elapsedMicroseconds;
        b.rootPipelineOwner.flushLayout();
        b.rootPipelineOwner.flushCompositingBits();
        b.rootPipelineOwner.flushPaint();
        final t3 = sw.elapsedMicroseconds;
        acts.add(t0); builds.add(t1 - t0); pts.add(t3 - t1);
        await tester.pump();
      }
      debugOnRebuildDirtyWidget = null;
      obs.on = false;
      String med(List<int> l) { final s = [...l]..sort(); return (s[s.length ~/ 2] / 1000).toStringAsFixed(1); }
      print('== $label: act ${med(acts)} build ${med(builds)} layout+paint ${med(pts)} ms (median of $reps); providers ${obs.counts.length}');
      final top = obs.gaps.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      for (final t in top.take(6)) {
        print('     ${(t.value / 1000 / reps).toStringAsFixed(1)}ms/rep x${obs.counts[t.key]} ${t.key.length > 110 ? t.key.substring(0, 110) : t.key}');
      }
      if (rebuilt) {
        final r = rb.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
        print('     REBUILT ${r.take(80).map((e) => '${e.key}:${e.value}').join(', ')}');
      }
    }

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: scr(1500, 1100));
    await tester.pump();
    // hover over empty area
    await measure('hover empty', (i) => mouse.moveTo(scr(1500 + i * 3.0, 1100)), rebuilt: true);
    // hover toggling node vs empty (target change every move)
    await measure('hover node<->empty', (i) => mouse.moveTo(i.isEven ? scr(200.0 + 60 * (i % 20), 200) : scr(1500, 1100)), rebuilt: true);
    await measure('hover edge<->edge', (i) => mouse.moveTo(scr(230.0 + 60 * (i % 20), 100)), rebuilt: true);
    // inert: lock HVAC
    c.read(lockedDisciplinesProvider.notifier).toggle(DisciplineLayer.hvac);
    await tester.pump();
    await measure('hover empty (HVAC locked)', (i) => mouse.moveTo(scr(1500 + i * 3.0, 1100)));
    await measure('hover node<->empty (HVAC locked)', (i) => mouse.moveTo(i.isEven ? scr(200.0 + 60 * (i % 20), 200) : scr(1500, 1100)));
    var px = 0.0;
    await measure('pan (HVAC locked)', (i) async { px += 7; c.read(sheetsControllerProvider.notifier).setViewport('f5', ViewportTransform(scale: 0.6, offset: Offset(px, 0))); });
    c.read(lockedDisciplinesProvider.notifier).toggle(DisciplineLayer.hvac);
    await tester.pump();
    await mouse.moveTo(scr(1600, 1150));
    await tester.pump();
    await measure('pan baseline', (i) async { px += 7; c.read(sheetsControllerProvider.notifier).setViewport('f5', ViewportTransform(scale: 0.6, offset: Offset(px, 0))); }, rebuilt: true);
    c.read(showSizingProvider.notifier).toggle();
    await tester.pump(const Duration(milliseconds: 300));
    await measure('pan sizes shown', (i) async { px += 7; c.read(sheetsControllerProvider.notifier).setViewport('f5', ViewportTransform(scale: 0.6, offset: Offset(px, 0))); });
    await measure('pan sizes shown zoom1.5', (i) async { px += 7; c.read(sheetsControllerProvider.notifier).setViewport('f5', ViewportTransform(scale: 1.5, offset: Offset(px, 0))); });
    c.read(showSizingProvider.notifier).toggle();
    c.read(showHeatmapProvider.notifier).toggle();
    await tester.pump(const Duration(milliseconds: 300));
    print('residual nodes ${c.read(residualByNodeProvider).length}');
    await measure('pan heatmap', (i) async { px += 7; c.read(sheetsControllerProvider.notifier).setViewport('f5', ViewportTransform(scale: 0.6, offset: Offset(px, 0))); }, rebuilt: true);
    c.read(showHeatmapProvider.notifier).toggle();
    await tester.pump();
    c.read(sheetsControllerProvider.notifier).setViewport('f5', const ViewportTransform(scale: 0.6, offset: Offset(0, 0)));
    await tester.pump();
    await measure('wheel zoom', (i) async {
      tester.binding.handlePointerEvent(PointerScrollEvent(position: scr(600, 400), scrollDelta: Offset(0, i.isEven ? -20 : 20)));
    });
    // selection of 1 node, drag session frames
    c.read(selectionProvider.notifier).selectNode('cw5-x3');
    await tester.pump(const Duration(milliseconds: 300));
    c.read(dragSessionProvider.notifier).beginDrag();
    var x = 200.0;
    await measure('drag frame w/ selection', (i) async { x += 5; c.read(networkControllerProvider.notifier).moveNode('cw5-x3', x, 200); c.read(dragSessionProvider.notifier).tickDrag(); }, rebuilt: true);
    c.read(dragSessionProvider.notifier).endDrag();
    await tester.pump(const Duration(milliseconds: 300));
    // multi selection 200 nodes + group drag
    final ids = [for (final n in c.read(networkControllerProvider).network.nodes) if (n.sheetId == 'f5') n.id].take(200).toSet();
    print('selected ${ids.length}');
    c.read(selectionProvider.notifier).setMulti(ids, {});
    await tester.pump(const Duration(milliseconds: 300));
    c.read(dragSessionProvider.notifier).beginDrag();
    await measure('group drag frame (200 sel)', (i) async { c.read(networkControllerProvider.notifier).moveMany(ids, 3, 0); c.read(dragSessionProvider.notifier).tickDrag(); }, rebuilt: true);
    c.read(dragSessionProvider.notifier).endDrag();
    await tester.pump(const Duration(milliseconds: 300));
    await measure('pan w/ 200 selected', (i) async { px += 7; c.read(sheetsControllerProvider.notifier).setViewport('f5', ViewportTransform(scale: 0.6, offset: Offset(px, 0))); });
    c.read(selectionProvider.notifier).setMulti({}, {});
    await tester.pump(const Duration(milliseconds: 300));
    // marquee
    c.read(sheetsControllerProvider.notifier).setViewport('f5', const ViewportTransform(scale: 0.6, offset: Offset(0, 0)));
    await tester.pump();
    await mouse.moveTo(scr(1600, 1150));
    await mouse.down(scr(1600, 1150));
    await tester.pump();
    await measure('marquee move', (i) => mouse.moveTo(scr(1600 - 40.0 * (i + 1), 1150 - 30.0 * (i + 1))), rebuilt: true);
    await mouse.up();
    await tester.pump(const Duration(milliseconds: 300));
    c.read(selectionProvider.notifier).setMulti({}, {});
    // drawing rubber band
    c.read(networkControllerProvider.notifier).setTool(DrawTool.drawRun);
    await tester.pump();
    c.read(networkControllerProvider.notifier).placeRunPoint('f5', 5, const Offset(1500, 1000));
    await tester.pump(const Duration(milliseconds: 300));
    await measure('draw rubber-band hover', (i) => mouse.moveTo(scr(1300.0 - i * 13, 1000.0 - i * 7)), rebuilt: true);
    c.read(networkControllerProvider.notifier).cancelPending();
    await tester.pump(const Duration(seconds: 5));
  });
}
