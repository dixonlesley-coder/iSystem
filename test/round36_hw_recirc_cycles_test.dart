// Round 36 (2026-10-18) — mech-props-5-hw-return-cycles-basis-dependent.
//
// The drawn hot-water recirculation loops are a CANONICAL set (every simple
// cycle through the source / a plant / a check valve that runs each flowing
// pipe in its solved direction) — never the fundamental cycles of a BFS
// spanning tree, whose choice of tree edge (an edge id, a bend on the return
// header) decided whether a riser loop survived. Same drawing ⇒ same loop
// count, flow shares, index-loop length and circulator head.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/hot_water.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _hw(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.hotWater, kind: k);

/// H -[ha]-> A -> T0 -> T1 (supply main); each T_k rises to U_k (L1, one
/// fixture), U_k returns down to R_k (L0) and R_k -> J; the common return
/// header J -> [bends] -> CV -> P (circulator) -> H. [bends] bare nodes lie
/// ON the straight header, so its length never changes.
Network _twoRiserHotel(String haId, int bends, {List<String>? order}) {
  final nodes = <NetNode>[
    _n('H', 0, 0, role: NodeRole.plant),
    _n('A', 100, 0),
    _n('J', 100, 200),
    _n('CV', 40, 200, c: NodeComponent.checkValve),
    _n('P', 0, 200, role: NodeRole.plant, c: NodeComponent.pump),
  ];
  final edges = <NetEdge>[
    _hw(haId, 'H', 'A'),
    _hw('m0', 'A', 'T0'),
    _hw('m1', 'T0', 'T1'),
    _hw('cp', 'CV', 'P'),
    _hw('ph', 'P', 'H'),
  ];
  for (var k = 0; k < 2; k++) {
    final x = 200.0 + 100 * k;
    nodes
      ..add(_n('T$k', x, 0))
      ..add(_n('U$k', x, 0, floor: 1))
      ..add(_n('F$k', x + 40, 0, floor: 1, role: NodeRole.fixture))
      ..add(_n('V$k', x + 20, 0, floor: 1))
      ..add(_n('R$k', x + 20, 0));
    edges
      ..add(_hw('s$k', 'T$k', 'U$k', k: EdgeKind.riser))
      ..add(_hw('f$k', 'U$k', 'F$k'))
      ..add(_hw('t$k', 'U$k', 'V$k'))
      ..add(_hw('r$k', 'V$k', 'R$k', k: EdgeKind.riser))
      ..add(_hw('j$k', 'R$k', 'J'));
  }
  // The header J -> b1 .. bn -> CV, evenly on the straight J..CV line.
  var prev = 'J';
  for (var i = 1; i <= bends; i++) {
    final id = 'b$i';
    nodes.add(_n(id, 100 - 60.0 * i / (bends + 1), 200));
    edges.add(_hw('h$i', prev, id));
    prev = id;
  }
  edges.add(_hw('hc', prev, 'CV'));
  if (order != null) {
    final byId = {for (final e in edges) e.id: e};
    return Network(nodes: nodes, edges: [for (final id in order) byId[id]!]);
  }
  return Network(nodes: nodes, edges: edges);
}

void main() {
  test(
      'two riser loops on a common header: the loop set, shares, index '
      'length and recirc head never depend on the H-A edge id (a0 / z9) or '
      'on 0..7 bends on the return header', () {
    ({int systems, List<double>? shares, double? len, double head}) run(
        String haId, int bends,
        {List<String>? order}) {
      final net = _twoRiserHotel(haId, bends, order: order);
      final byId = {for (final n in net.nodes) n.id: n};
      // Runs: plan pixels x 0.02 m/px; risers: the 3.5 m storey.
      double len(NetEdge e) {
        if (e.kind == EdgeKind.riser) return 3.5;
        final a = byId[e.fromId]!, b = byId[e.toId]!;
        return math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2)) *
            0.02;
      }

      final sizing = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: {ServiceType.hotWater: const FlowRate(0)},
        leafFixtureUnits: {ServiceType.hotWater: 2},
      );
      final loops = hotWaterRecircLoops(net, sizing, lengthOf: len);
      final loop = loops.single;
      final d = sizeHotWaterRecirculation(
        heatLoss: heatLossFromLength(loopLength: Length(loop.circulatedLengthM)),
        loopLength: Length(loop.returnLengthM),
        returnDiameter: kDefaultRecircReturnDiameter,
        supplyPath: loop.indexPath,
        supplyPathFlowShares: loop.indexFlowShares,
      );
      return (
        systems: loops.length,
        shares: loop.indexFlowShares,
        len: loop.drawnLoopLengthM,
        head: d.loopHead.meters,
      );
    }

    final ref = run('a0', 0);
    // Both riser loops survive: the index loop carries shares (parallel).
    expect(ref.systems, 1);
    expect(ref.shares, isNotNull);
    expect(ref.len, isNotNull);
    final rnd = math.Random(36);
    for (final haId in ['a0', 'z9']) {
      for (var bends = 0; bends <= 7; bends++) {
        final why = 'ha=$haId bends=$bends';
        final r = run(haId, bends);
        expect(r.systems, ref.systems, reason: why);
        expect(r.shares, isNotNull, reason: why);
        // The bends split a header edge, so compare the share PROFILE as a
        // set of distinct values (a bend repeats the share of the edge it
        // splits) and the loop totals.
        expect(r.shares!.toSet().map((x) => x.toStringAsFixed(9)).toSet(),
            ref.shares!.toSet().map((x) => x.toStringAsFixed(9)).toSet(),
            reason: why);
        expect(r.len, closeTo(ref.len!, 1e-9), reason: why);
        expect(r.head, closeTo(ref.head, 1e-12), reason: why);
        // Shuffling the edge list never changes the answer either.
        final ids = [
          for (final e in _twoRiserHotel(haId, bends).edges) e.id,
        ]..shuffle(rnd);
        final s = run(haId, bends, order: ids);
        expect(s.len, closeTo(ref.len!, 1e-9), reason: '$why shuffled');
        expect(s.head, closeTo(ref.head, 1e-12), reason: '$why shuffled');
      }
    }
  });
}
