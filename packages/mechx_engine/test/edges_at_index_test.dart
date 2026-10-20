import 'dart:math' as math;

import 'package:mechx_engine/network/network.dart';
import 'package:test/test.dart';

/// Drafting-feel perf (2026-10-20) — `Network.edgesAt` is served from a lazily
/// built incidence index. It must stay EXACTLY the old linear scan (same edges,
/// same edge-list order, a self-loop once) and re-index when the edge list
/// changes, like `nodeById` / `edgeById`.
void main() {
  List<NetEdge> scan(Network net, String id) => net.edges
      .where((e) => e.fromId == id || e.toId == id)
      .toList(growable: false);

  test('matches the linear scan on random networks (order + self-loops)', () {
    final rnd = math.Random(20261020);
    for (var trial = 0; trial < 40; trial++) {
      final nNodes = 2 + rnd.nextInt(40);
      final nodes = [
        for (var i = 0; i < nNodes; i++)
          NetNode(id: 'n$i', sheetId: 's', x: i * 1.0, y: 0, floorIndex: 0),
      ];
      final edges = [
        for (var i = 0; i < rnd.nextInt(80); i++)
          NetEdge(
            id: 'e$i',
            fromId: 'n${rnd.nextInt(nNodes)}',
            toId: 'n${rnd.nextInt(nNodes)}', // self-loops included
            service: ServiceType.values[rnd.nextInt(ServiceType.values.length)],
          ),
      ];
      final net = Network(nodes: nodes, edges: edges);
      for (final n in [...nodes.map((n) => n.id), 'missing']) {
        expect(net.edgesAt(n).toList(), scan(net, n), reason: 'trial $trial $n');
      }
    }
  });

  test('a new edge list re-indexes (no stale incidence)', () {
    const a = NetNode(id: 'a', sheetId: 's', x: 0, y: 0, floorIndex: 0);
    const b = NetNode(id: 'b', sheetId: 's', x: 1, y: 0, floorIndex: 0);
    const e1 = NetEdge(
        id: 'e1', fromId: 'a', toId: 'b', service: ServiceType.coldWater);
    final net1 = Network(nodes: const [a, b], edges: const [e1]);
    expect(net1.edgesAt('a').map((e) => e.id), ['e1']);
    final net2 = net1.copyWith(edges: [
      e1,
      const NetEdge(
          id: 'e2', fromId: 'b', toId: 'a', service: ServiceType.drainage),
    ]);
    expect(net2.edgesAt('a').map((e) => e.id), ['e1', 'e2']);
    expect(net1.edgesAt('a').map((e) => e.id), ['e1']);
  });
}
