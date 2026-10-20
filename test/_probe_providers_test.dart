import 'package:flutter/widgets.dart';
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
import '_probe_names.dart';

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
  testWidgets('provider self times', (tester) async {
    setDesktopSurface(tester, size: const Size(1440, 900));
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final c = ProviderScope.containerOf(tester.element(find.byType(MechXApp)),
        listen: false);
    const floors = 30, branches = 24;
    c.read(sheetsControllerProvider.notifier).loadSheets([
      for (var f = 0; f < floors; f++)
        Sheet(id: 'f$f', name: 'L$f', sizePx: const Size(1684, 1190)),
    ]);
    c.read(projectControllerProvider.notifier).setFloors([
      for (var f = 0; f < floors; f++) Floor('L$f', const Length(3.5)),
    ]);
    for (var f = 0; f < floors; f++) {
      c.read(projectControllerProvider.notifier)
          .setCalibration('f$f', const ScaleCalibration(0.01));
    }
    c.read(networkControllerProvider.notifier).loadNetwork(bigNet(floors, branches));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    c.read(networkControllerProvider.notifier).moveNode('cw0-x3', 230, 200);
    await tester.pump();
    final res = <String, int>{};
    for (var pass = 0; pass < 2; pass++) {
      final els = c.getAllProviderElements().toList();
      for (final el in els) {
        final p = el.origin;
        if (p is! Provider && p is! AutoDisposeProvider) continue;
        final name = kNames[p] ?? (p.from != null ? '${kNames[p.from] ?? p.from}(${p.argument})' : p.toString());
        for (final q in els) {
          final o = q.origin;
          if (o is Provider || o is AutoDisposeProvider) { try { c.read(o); } catch (_) {} }
        }
        c.invalidate(p);
        final sw = Stopwatch()..start();
        try { c.read(p); } catch (_) {}
        final us = sw.elapsedMicroseconds;
        if (pass == 1) res[name] = us;
      }
    }
    final top = res.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    for (final t in top.take(45)) {
      // ignore: avoid_print
      print('SELF ${(t.value / 1000).toStringAsFixed(2)} ms  ${t.key.length > 120 ? t.key.substring(0, 120) : t.key}');
    }
    // ignore: avoid_print
    print('total self ${(res.values.fold<int>(0, (a, b) => a + b) / 1000).toStringAsFixed(1)} ms over ${res.length}');
    await tester.pump(const Duration(seconds: 5));
  });
}
