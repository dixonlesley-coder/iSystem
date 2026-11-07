// Round 65 — a fire pump room sizes on the water it delivers, whichever fire
// service each pump-room pipe was drawn on.
//
//  * regression-1 (fedThroughOtherFireService rooted at a DOWNSTREAM join):
//    GT -g- SH -s- P -d- DS; DS -dh(hydrant)- a 4-storey Class I riser, one
//    box a floor; DS -dq(sprinkler)- a 4-storey OH2 sprinkler riser, 4 heads
//    a floor (remote-area cap 12 L/s). The pump train carries the hydrant
//    standpipe flow:
//      standpipeFlow(1) = 500 gpm = 500 x 3.785411784 / 60 = 31.545 L/s,
//    floored at NFPA 20 Table 4.28(a) 500 gpm => 5 in = DN125 on suction AND
//    discharge (150 % suction velocity on DN125: 1.5 x 0.031545 /
//    (pi 0.125^2 / 4) = 0.047318 / 0.012272 = 3.86 m/s <= 4.57 m/s).
//    Drawing d on the sprinkler service made DS (a join DOWNSTREAM of P, 3
//    source hops vs P's 2) the fragment's root: d flowed DS -> P into a
//    dead-leaf pump and g / s / d sized at 0 L/s DN25..DN65. Every edge must
//    match the all-hydrant drawing for every (g, s, d) service choice.
library;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
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

const _hy = ServiceType.fireHydrant, _sp = ServiceType.fireSprinkler;
const _cal = {'s1': ScaleCalibration(0.01)};

Map<String, EdgeSizing> _size(Network net) => autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {_hy: FlowRate(0.005), _sp: FlowRate(0.0015)},
      hydrantDesignFlow: standpipeFlow(1),
      sprinklerDemandCap: const FlowRate(0.012),
      building: BuildingLevels(
          [for (var i = 0; i < 5; i++) Floor('L$i', const Length(3.5))]),
      calibrationBySheet: _cal,
    );

/// The combined pump room; [g], [s], [d] are the services of the tank main,
/// the suction and the discharge.
Network _room(ServiceType g, ServiceType s, ServiceType d) {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('SH', 100),
    _n('P', 200, role: NodeRole.plant, c: NodeComponent.pump),
    _n('DS', 300),
    _n('X0', 400),
    _n('Q0', 300, y: 400),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'SH', s: g),
    _e('s', 'SH', 'P', s: s),
    _e('d', 'P', 'DS', s: d),
    _e('dh', 'DS', 'X0'),
    _e('dq', 'DS', 'Q0', s: _sp),
  ];
  for (var f = 1; f <= 4; f++) {
    nodes
      ..add(_n('X$f', 400, floor: f))
      ..add(_n('B$f', 500,
          floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox))
      ..add(_n('Q$f', 300, y: 400, floor: f));
    edges
      ..add(_e('r$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser))
      ..add(_e('b$f', 'X$f', 'B$f'))
      ..add(_e('q$f', 'Q${f - 1}', 'Q$f', k: EdgeKind.riser, s: _sp));
    var prev = 'Q$f';
    for (var h = 0; h < 4; h++) {
      nodes
        ..add(_n('M$f$h', 600.0 + 300 * h, floor: f, y: 400))
        ..add(_n('S$f$h', 600.0 + 300 * h,
            floor: f,
            y: 500,
            role: NodeRole.fixture,
            c: NodeComponent.sprinklerHead));
      edges
        ..add(_e('m$f$h', prev, 'M$f$h', s: _sp))
        ..add(_e('h$f$h', 'M$f$h', 'S$f$h', s: _sp));
      prev = 'M$f$h';
    }
  }
  return Network(nodes: nodes, edges: edges);
}

void main() {
  final forward = _size(_room(_hy, _hy, _hy));

  test('all-hydrant pump train: 31.545 L/s DN125, d flows P -> DS', () {
    for (final id in ['g', 's', 'd']) {
      expect(forward[id]!.flow.inLitersPerSecond, closeTo(31.545, 0.001),
          reason: id);
      expect(forward[id]!.diameter.inMillimeters, 125, reason: id);
    }
    expect(forward['d']!.flowFromId, 'P');
    expect(forward['s']!.flowFromId, 'SH');
  });

  // Exhaustive over the 8 service assignments (the whole property space):
  // no pump-room pipe's service may move a size or an arrow.
  for (final g in [_hy, _sp]) {
    for (final s in [_hy, _sp]) {
      for (final d in [_hy, _sp]) {
        test('g ${g.name} / s ${s.name} / d ${d.name} == all-hydrant', () {
          final r = _size(_room(g, s, d));
          expect(r.keys.toSet(), forward.keys.toSet());
          for (final id in forward.keys) {
            expect(r[id]!.flow.inLitersPerSecond,
                closeTo(forward[id]!.flow.inLitersPerSecond, 1e-6),
                reason: id);
            expect(r[id]!.diameter.inMillimeters,
                forward[id]!.diameter.inMillimeters,
                reason: id);
            expect(r[id]!.flowFromId, forward[id]!.flowFromId, reason: id);
          }
        });
      }
    }
  }
}
