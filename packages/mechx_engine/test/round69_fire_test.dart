// Round 69 (2026-10-18) — fire-convergence-21:
//
//  peer-pump-room-with-parallel-set-unsized — two pump rooms on a yard
//    hydrant ring, each a parallel pump SET (duty + standby, optionally a
//    jockey) between a suction header and a discharge header. The Round-14
//    peer-source mirror walked the peer's bridge only through degree-2
//    nodes, so it stopped at the peer room's suction header: on the ring
//    the peer room's pump legs and discharge main dropped out of the result
//    (no size, no BOM line, no NFPA 20 raise for a whole 500 gpm room); on
//    the tree they kept the reversed orientation the spanning tree gave
//    them.
//
// First principles: each yard (pillar) hydrant main carries >= 38 L/s
// (SNI 03-1735, `kYardHydrantFlowLps`) on >= DN150. Each pump room is a
// parallel peer source and carries the WHOLE set flow while the other is
// isolated, so every peer-room main leg (suction, duty and standby pump
// legs, discharge main) carries the same 38 L/s as its twin in the room the
// tree happens to root at, on the same bore (NFPA 20 Table 4.28(a): 500-750
// gpm => >= DN150 discharge), flowing tank -> pumps -> yard. A jockey leg
// carries its own jockey flow, never the main set flow.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _hy = ServiceType.fireHydrant;

NetNode _n(String id, double x, double y, {NodeComponent? c}) => NetNode(
    id: id,
    sheetId: 's1',
    x: x,
    y: y,
    floorIndex: 0,
    role: c?.role ?? NodeRole.main,
    component: c);

NetEdge _e(String id, String a, String b) =>
    NetEdge(id: id, fromId: a, toId: b, service: _hy, kind: EdgeKind.run);

/// Yard ring Y0..Y7 (a pillar hydrant PH_i off each), room A into Y0 and its
/// mirror room B into Y4. [pumps] per room: 1 = duty only, 2 = duty +
/// standby, 3 = + a jockey (`<room>J`). [ring] closes Y7 -> Y0 (else the
/// yard main is a tree, edge y2 removed).
Network _yard({required int pumps, required bool ring}) {
  final nodes = <NetNode>[
    for (var i = 0; i < 8; i++) ...[
      _n('Y$i', 100.0 * math.cos(i * math.pi / 4) * 4,
          100.0 * math.sin(i * math.pi / 4) * 4),
      _n('PH$i', 100.0 * math.cos(i * math.pi / 4) * 5,
          100.0 * math.sin(i * math.pi / 4) * 5,
          c: NodeComponent.pillarHydrant),
    ],
  ];
  final edges = <NetEdge>[
    for (var i = 0; i < 8; i++) ...[
      if (ring || i != 2) _e('y$i', 'Y$i', 'Y${(i + 1) % 8}'),
      _e('ph$i', 'Y$i', 'PH$i'),
    ],
  ];
  for (final (r, x, y) in [('A', -900.0, 0.0), ('B', 900.0, 0.0)]) {
    final s = x.sign;
    nodes
      ..add(_n('G$r', x + s * 300, y, c: NodeComponent.groundTank))
      ..add(_n('S$r', x + s * 200, y))
      ..add(_n('H$r', x, y));
    edges.add(_e('g$r', 'G$r', 'S$r'));
    for (var k = 1; k <= pumps; k++) {
      final id = k == 3 ? '${r}J' : '$r$k';
      nodes.add(_n(id, x + s * 100, y + 60.0 * (k - 1), c: NodeComponent.pump));
      edges
        ..add(_e('s$id', 'S$r', id))
        ..add(_e('d$id', id, 'H$r'));
    }
    edges.add(_e('h$r', 'H$r', r == 'A' ? 'Y0' : 'Y4'));
  }
  return Network(nodes: nodes, edges: edges);
}

final _bld =
    BuildingLevels([for (var i = 0; i < 3; i++) Floor('L$i', const Length(6))]);

Map<String, EdgeSizing> _size(Network net,
        {Set<String>? legs, int pumps = 1}) =>
    autoSizeNetwork(net, const SizingContext(),
        leafDemand: const {_hy: FlowRate(0.005)},
        hydrantDesignFlow: standpipeFlow(1),
        building: _bld,
        calibrationBySheet: const {'s1': ScaleCalibration(0.01)},
        jockeyLegFlows: pumps >= 3
            ? const {'AJ': FlowRate(0.0005), 'BJ': FlowRate(0.0005)}
            : const {},
        parallelLegEdgeIdsOut: legs);

Network _swapRooms(Network n) {
  String sw(String id) {
    if (id.contains('A')) return id.replaceAll('A', '\u0001');
    if (id.contains('B')) return id.replaceAll('B', 'A');
    return id;
  }

  String fix(String id) => sw(id).replaceAll('\u0001', 'B');
  return Network(nodes: [
    for (final x in n.nodes.reversed)
      NetNode(
          id: fix(x.id),
          sheetId: x.sheetId,
          x: x.x,
          y: x.y,
          floorIndex: x.floorIndex,
          role: x.role,
          component: x.component)
  ], edges: [
    for (final e in n.edges.reversed)
      NetEdge(
          id: fix(e.id),
          fromId: fix(e.fromId),
          toId: fix(e.toId),
          service: e.service,
          kind: e.kind)
  ]);
}

void main() {
  for (final pumps in [1, 2, 3]) {
    for (final ring in [true, false]) {
      test(
          '$pumps pump(s) per room, ${ring ? 'ring' : 'tree'}: room B == '
          'room A', () {
        final legs = <String>{};
        final sz =
            _size(_yard(pumps: pumps, ring: ring), legs: legs, pumps: pumps);
        final main = [
          for (var k = 1; k <= math.min(pumps, 2); k++) '$k',
        ];
        final pairs = <(String, String, String)>[
          ('gA', 'gB', 'G'),
          for (final k in main) ...[
            ('sA$k', 'sB$k', 'S'),
            ('dA$k', 'dB$k', 'P'),
          ],
          ('hA', 'hB', 'H'),
        ];
        for (final (a, b, fromKind) in pairs) {
          final sa = sz[a], sb = sz[b];
          expect(sa, isNotNull, reason: '$a sized');
          expect(sb, isNotNull, reason: '$b sized');
          expect(sa!.flow.inLitersPerSecond,
              greaterThanOrEqualTo(kYardHydrantFlowLps - 1e-9),
              reason: '$a carries the yard flow');
          expect(sb!.flow.inLitersPerSecond,
              closeTo(sa.flow.inLitersPerSecond, 1e-9),
              reason: '$b == $a flow');
          expect(sb.diameter.inMillimeters, sa.diameter.inMillimeters,
              reason: '$b == $a DN');
          expect(sb.diameter.inMillimeters, greaterThanOrEqualTo(150),
              reason: '$b >= DN150');
          // Direction: tank -> header -> pump -> header -> yard.
          final from = switch (fromKind) {
            'G' => 'GB',
            'S' => 'SB',
            'P' => b.substring(1),
            _ => 'HB',
          };
          expect(sb.flowFromId, from, reason: '$b direction');
        }
        if (pumps >= 3) {
          for (final id in ['sBJ', 'dBJ']) {
            final s = sz[id];
            expect(s, isNotNull, reason: '$id sized');
            expect(s!.flow.inLitersPerSecond, closeTo(0.5, 1e-9),
                reason: '$id at the jockey flow');
            expect(s.flowFromId, id == 'sBJ' ? 'SB' : 'BJ');
          }
        }
      });
    }
  }

  test('seeded property: the result never depends on which room roots', () {
    final rnd = math.Random(69);
    for (var trial = 0; trial < 6; trial++) {
      final pumps = 1 + rnd.nextInt(3);
      final ring = rnd.nextBool();
      final net = _yard(pumps: pumps, ring: ring);
      final a = _size(net, pumps: pumps);
      final swapped = _swapRooms(net);
      final b = _size(
          Network(
              nodes: [...swapped.nodes]..shuffle(rnd),
              edges: [...swapped.edges]..shuffle(rnd)),
          pumps: pumps);
      String back(String id) => id
          .replaceAll('A', '\u0001')
          .replaceAll('B', 'A')
          .replaceAll('\u0001', 'B');
      for (final e in net.edges) {
        final x = a[e.id], y = b[back(e.id)];
        expect(x?.diameter.inMillimeters, y?.diameter.inMillimeters,
            reason: 'trial $trial (pumps $pumps ring $ring) ${e.id} DN');
        if (x == null || y == null) continue;
        expect(
            x.flow.inLitersPerSecond, closeTo(y.flow.inLitersPerSecond, 1e-6),
            reason: 'trial $trial ${e.id} flow');
      }
    }
  });

  group('suction-tank-below-pump-floor-lift-understated', () {
    // 32 storeys x 3.2 m. A break tank BT on L16, a duty / standby pair on
    // [pumpFloor], hydrant boxes X17..X31 on a riser off the discharge.
    final bld = BuildingLevels(
        [for (var i = 0; i < 32; i++) Floor('L$i', const Length(3.2))]);
    Network upper(
        {required int pumpFloor,
        int tankFloor = 16,
        NodeComponent tank = NodeComponent.roofTank}) {
      NetNode n(String id, int f, {NodeComponent? c, double y = 0}) => NetNode(
          id: id,
          sheetId: 's1',
          x: 0,
          y: y,
          floorIndex: f,
          role: c?.role ?? NodeRole.main,
          component: c);
      NetEdge e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
          NetEdge(id: id, fromId: a, toId: b, service: _hy, kind: k);
      return Network(nodes: [
        n('BT', tankFloor, c: tank),
        n('SH2', pumpFloor),
        n('P3', pumpFloor, c: NodeComponent.pump),
        n('P4', pumpFloor, c: NodeComponent.pump, y: 40),
        n('DH', pumpFloor),
        for (var f = 17; f <= 31; f++) ...[
          n('X$f', f),
          n('B$f', f, c: NodeComponent.hydrantBox, y: 60),
        ],
      ], edges: [
        e('bt', 'BT', 'SH2',
            k: tankFloor == pumpFloor ? EdgeKind.run : EdgeKind.riser),
        e('s3', 'SH2', 'P3'),
        e('s4', 'SH2', 'P4'),
        e('d3', 'P3', 'DH'),
        e('d4', 'P4', 'DH'),
        e('dx', 'DH', 'X17',
            k: pumpFloor == 17 ? EdgeKind.run : EdgeKind.riser),
        for (var f = 18; f <= 31; f++)
          e('x$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser),
        for (var f = 17; f <= 31; f++) e('b$f', 'X$f', 'B$f'),
      ]);
    }

    double lift(Network net) {
      final sys = fireSystems(net).single;
      return sys.staticLiftM(net, bld, FireTerminalKind.hydrant);
    }

    // From the L16 tank surface (16 x 3.2 = 51.2 m) to the L31 hose outlet
    // (31 x 3.2 + 1.2 = 100.4 m): 49.2 m either way.
    const expected = 31 * 3.2 + 1.2 - 16 * 3.2;
    for (final tank in [NodeComponent.roofTank, NodeComponent.groundTank]) {
      test('$tank on L16, pumps on L17 == pumps on L16 (49.2 m)', () {
        final above = upper(pumpFloor: 17, tank: tank);
        final beside = upper(pumpFloor: 16, tank: tank);
        expect(lift(beside), closeTo(expected, 1e-9));
        expect(lift(above), closeTo(expected, 1e-9));
        expect(fireSystems(above).single.suctionTankBelowPumps(above), 'BT');
        expect(
            fireSystems(beside).single.suctionTankBelowPumps(beside), isNull);
      });
    }

    test('a tank above its pumps (positive suction) keeps the pump datum', () {
      // Tank on L17, pumps on L16 below it: lift from L16.
      final net = upper(pumpFloor: 16, tankFloor: 17);
      expect(fireSystems(net).single.suctionTankBelowPumps(net), isNull);
      expect(lift(net), closeTo(31 * 3.2 + 1.2 - 16 * 3.2, 1e-9));
    });
  });
}
