// Round 63 (regression-combined-room-suction-capped-at-hydrant-flow) — the
// caller's hydrant design flow caps the STANDPIPE term only, never a
// combined (hydrant + sprinkler) room's sprinkler remote-area demand.
//
// Probe: GT -> SH (bare shared suction header) -> P (room A) -> a 1-stack
// Class I hydrant riser on 4 storeys, a hydrant box and a 6-head sprinkler
// branch on every floor; SH -> PB (room B) -> one hydrant box.
//
// First principles:
//  * hydrantDesignFlow = standpipeFlow(1) = 500 gpm = 500 x 3.785411784 / 60
//    = 31.545 L/s (one Class I stack).
//  * EH remote area 10 mm/min x 260 m2 = 2600 L/min = 43.33 L/s (687 gpm):
//    room A's rated flow is max(31.545, 43.33) = 43.33 L/s (Round 50).
//  * NFPA 20 Table 4.28(a): 687 gpm sits on the 750 gpm row, suction 6 in
//    => DN150; on DN150 v150 = 1.5 x 0.04333 / (pi 0.15^2 / 4) = 0.0650 /
//    0.017671 = 3.68 m/s <= 4.57 m/s, on DN125 it would be 0.0650 /
//    0.012272 = 5.30 m/s > 4.57 (the defect: g = sa = 31.545 L/s DN125).
//  * the shared header carries the LARGER room (43.33 L/s), whichever fire
//    service room A's suction leg is drawn on.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_pump_suction.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x,
        {int floor = 0,
        double y = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b,
        {EdgeKind k = EdgeKind.run, ServiceType s = ServiceType.fireHydrant}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

const _cal = {'s1': ScaleCalibration(0.01)};
const _cap = FlowRate(0.04333);

double _v150(EdgeSizing s) =>
    1.5 *
    s.flow.cubicMetersPerSecond /
    (math.pi * math.pow(s.diameter.meters, 2) / 4);

Network _probe(ServiceType suctionA) {
  const sp = ServiceType.fireSprinkler;
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('SH', 100),
    _n('P', 200, role: NodeRole.plant, c: NodeComponent.pump),
    _n('X0', 300),
    _n('PB', 200, y: 800, role: NodeRole.plant, c: NodeComponent.pump),
    _n('YB', 300, y: 800),
    _n('BB', 400, y: 800, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'SH'),
    _e('sa', 'SH', 'P', s: suctionA),
    _e('d', 'P', 'X0'),
    _e('sb', 'SH', 'PB'),
    _e('db', 'PB', 'YB'),
    _e('bb', 'YB', 'BB'),
  ];
  for (var f = 1; f <= 4; f++) {
    nodes
      ..add(_n('X$f', 300, floor: f))
      ..add(_n('B$f', 400,
          floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
    edges
      ..add(_e('r$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser))
      ..add(_e('b$f', 'X$f', 'B$f'));
    var prev = 'X$f';
    for (var h = 0; h < 6; h++) {
      nodes
        ..add(_n('M$f$h', 600.0 + 300 * h, floor: f, y: 200))
        ..add(_n('S$f$h', 600.0 + 300 * h,
            floor: f,
            y: 300,
            role: NodeRole.fixture,
            c: NodeComponent.sprinklerHead));
      edges
        ..add(_e('m$f$h', prev, 'M$f$h', s: sp))
        ..add(_e('h$f$h', 'M$f$h', 'S$f$h', s: sp));
      prev = 'M$f$h';
    }
  }
  return Network(nodes: nodes, edges: edges);
}

Map<String, EdgeSizing> _size(Network net) => autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {
        ServiceType.fireHydrant: FlowRate(0.005),
        ServiceType.fireSprinkler: FlowRate(0.0015),
      },
      hydrantDesignFlow: standpipeFlow(1),
      sprinklerDemandCap: _cap,
      building: BuildingLevels(
          [for (var i = 0; i < 5; i++) Floor('L$i', const Length(3.5))]),
      calibrationBySheet: _cal,
    );

void main() {
  test('standpipeFlow(1) is 31.545 L/s (500 gpm)', () {
    expect(standpipeFlow(1).inLitersPerSecond, closeTo(31.545, 0.001));
  });

  for (final svc in [ServiceType.fireHydrant, ServiceType.fireSprinkler]) {
    test('combined room suction on ${svc.name}: 43.33 L/s DN150', () {
      final r = _size(_probe(svc));
      for (final id in ['g', 'sa']) {
        expect(r[id]!.flow.inLitersPerSecond, closeTo(43.33, 1e-6), reason: id);
        expect(r[id]!.diameter.inMillimeters, 150, reason: id);
        expect(_v150(r[id]!), lessThanOrEqualTo(kFirePumpSuctionMaxVelocityMps),
            reason: id);
      }
      // The suction is never smaller than the discharge.
      expect(r['sa']!.diameter.inMillimeters,
          greaterThanOrEqualTo(r['d']!.diameter.inMillimeters));
      // Room B (hydrant only) keeps the capped standpipe flow.
      expect(r['sb']!.flow.inLitersPerSecond, closeTo(31.545, 0.01));
    });
  }
}
