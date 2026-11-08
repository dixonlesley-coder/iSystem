// Round 70 (regression-peer-room-mirror-breaks-on-service-change) — the
// Round-69 yard: two pump rooms on a yard hydrant ring / tree, each a
// parallel pump set. Drawing ONE room-B pipe (its tank main, a pump leg, a
// jockey leg or the discharge main) on the SPRINKLER service never changes
// a size, a flow or a flow direction: the peer-room mirror runs over the
// combined fire network.
//
// First principles (as Round 69): each peer room carries the WHOLE set flow
// while the other is isolated, so every room-B main pipe carries the yard
// flow >= 38 L/s (SNI 03-1735, `kYardHydrantFlowLps`) on >= DN150, flowing
// tank -> pumps -> yard, exactly as in the all-hydrant drawing; a jockey leg
// carries its own jockey flow (0.5 L/s here).
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, double y, {NodeComponent? c}) => NetNode(
    id: id,
    sheetId: 's1',
    x: x,
    y: y,
    floorIndex: 0,
    role: c?.role ?? NodeRole.main,
    component: c);

Network _yard(
    {required int pumps, required bool ring, Set<String> sprinkler = const {}}) {
  NetEdge e(String id, String a, String b) => NetEdge(
      id: id,
      fromId: a,
      toId: b,
      service: sprinkler.contains(id)
          ? ServiceType.fireSprinkler
          : ServiceType.fireHydrant,
      kind: EdgeKind.run);
  final nodes = <NetNode>[
    for (var i = 0; i < 8; i++) ...[
      _n('Y$i', 400.0 * math.cos(i * math.pi / 4),
          400.0 * math.sin(i * math.pi / 4)),
      _n('PH$i', 500.0 * math.cos(i * math.pi / 4),
          500.0 * math.sin(i * math.pi / 4),
          c: NodeComponent.pillarHydrant),
    ],
  ];
  final edges = <NetEdge>[
    for (var i = 0; i < 8; i++) ...[
      if (ring || i != 2) e('y$i', 'Y$i', 'Y${(i + 1) % 8}'),
      e('ph$i', 'Y$i', 'PH$i'),
    ],
  ];
  for (final (r, x) in [('A', -900.0), ('B', 900.0)]) {
    final s = x.sign;
    nodes
      ..add(_n('G$r', x + s * 300, 0, c: NodeComponent.groundTank))
      ..add(_n('S$r', x + s * 200, 0))
      ..add(_n('H$r', x, 0));
    edges.add(e('g$r', 'G$r', 'S$r'));
    for (var k = 1; k <= pumps; k++) {
      final id = k == 3 ? '${r}J' : '$r$k';
      nodes.add(_n(id, x + s * 100, 60.0 * (k - 1), c: NodeComponent.pump));
      edges
        ..add(e('s$id', 'S$r', id))
        ..add(e('d$id', id, 'H$r'));
    }
    edges.add(e('h$r', 'H$r', r == 'A' ? 'Y0' : 'Y4'));
  }
  return Network(nodes: nodes, edges: edges);
}

Map<String, EdgeSizing> _size(Network net, int pumps) => autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {
        ServiceType.fireHydrant: FlowRate(0.005),
        ServiceType.fireSprinkler: FlowRate(0.001),
      },
      hydrantDesignFlow: standpipeFlow(1),
      building: BuildingLevels(
          [for (var i = 0; i < 3; i++) Floor('L$i', const Length(6))]),
      calibrationBySheet: const {'s1': ScaleCalibration(0.01)},
      jockeyLegFlows: pumps >= 3
          ? const {'AJ': FlowRate(0.0005), 'BJ': FlowRate(0.0005)}
          : const {},
    );

List<String> _roomB(int pumps) => [
      'gB',
      for (var k = 1; k <= math.min(pumps, 2); k++) ...['sB$k', 'dB$k'],
      if (pumps >= 3) ...['sBJ', 'dBJ'],
      'hB',
    ];

void _expectEqual(Map<String, EdgeSizing> r, Map<String, EdgeSizing> base,
    List<String> ids, String why) {
  for (final id in ids) {
    expect(r[id], isNotNull, reason: '$why: $id sized');
    expect(r[id]!.diameter.inMillimeters, base[id]!.diameter.inMillimeters,
        reason: '$why: $id DN');
    expect(r[id]!.flow.cubicMetersPerSecond,
        closeTo(base[id]!.flow.cubicMetersPerSecond, 1e-6),
        reason: '$why: $id flow');
    expect(r[id]!.flowFromId, base[id]!.flowFromId, reason: '$why: $id dir');
  }
}

void main() {
  for (final pumps in [1, 2, 3]) {
    for (final ring in [true, false]) {
      final label = '$pumps pump(s), ${ring ? 'ring' : 'tree'}';
      test('$label: all hydrant, room B main pipes >= 38 L/s on >= DN150', () {
        final base = _size(_yard(pumps: pumps, ring: ring), pumps);
        for (final id in _roomB(pumps)) {
          final s = base[id]!;
          if (id.endsWith('J')) {
            expect(s.flow.inLitersPerSecond, closeTo(0.5, 1e-9), reason: id);
          } else {
            expect(s.flow.inLitersPerSecond,
                greaterThanOrEqualTo(kYardHydrantFlowLps - 1e-9),
                reason: id);
            expect(s.diameter.inMillimeters, greaterThanOrEqualTo(150),
                reason: id);
          }
        }
      });

      test('$label: any one room-B pipe on sprinkler == all hydrant', () {
        final base = _size(_yard(pumps: pumps, ring: ring), pumps);
        for (final id in _roomB(pumps)) {
          final r =
              _size(_yard(pumps: pumps, ring: ring, sprinkler: {id}), pumps);
          _expectEqual(r, base, _roomB(pumps), 'sprinkler $id');
        }
      });
    }
  }

  test('seeded property: one random room-B pipe on sprinkler == all hydrant',
      () {
    final rnd = math.Random(7001);
    for (var t = 0; t < 30; t++) {
      final pumps = 1 + rnd.nextInt(3);
      final ring = rnd.nextBool();
      final ids = _roomB(pumps);
      final pick = ids[rnd.nextInt(ids.length)];
      final base = _size(_yard(pumps: pumps, ring: ring), pumps);
      final r =
          _size(_yard(pumps: pumps, ring: ring, sprinkler: {pick}), pumps);
      _expectEqual(r, base, ids, 'trial $t pumps=$pumps ring=$ring $pick');
    }
  });
}
