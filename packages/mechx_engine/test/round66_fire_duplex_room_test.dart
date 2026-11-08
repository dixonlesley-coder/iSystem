// Round 66 — a DUPLEX fire pump room sizes on the water it delivers,
// whichever fire service each pump-room pipe was drawn on and whichever way
// it was drawn.
//
//  * regression-duplex-pump-room-standby-suction-service-reverses-leg: the
//    Round-65 room with a parallel standby: GT -g- SH -s- P -d- DS and
//    SH -s2- P2 -d2- DS; DS -dh(hydrant)- a 4-storey Class I riser (one box
//    a floor) and DS -dq(sprinkler)- a 4-storey OH2 sprinkler riser. Drawing
//    only s2 on the sprinkler service left P2 a degree-1 leaf of the hydrant
//    fragment, so d2 was oriented DS -> P2 (backwards through the standby)
//    and the NFPA 20 pass found no header with two mover inflows at DS: the
//    discharge main dh dropped DN125 -> DN100.
//  * fire-convergence-18-standby-discharge-unoriented-skips-nfpa20-floor:
//    a room on the sprinkler service under a hydrant main is a zero-demand
//    loop on its own service: its legs carried a flow entry with NO
//    direction, so the standby discharge and the main skipped the floor.
//
// First principles: both pumps take suction from SH and discharge into DS,
// so each leg flows SH -> P(2) -> DS (the pump direction, away from the
// tank). The set delivers standpipeFlow(1) = 500 gpm = 500 x 3.785411784 /
// 60 = 31.545 L/s; each leg is a full-duty leg (duty or mirrored standby) at
// 31.545 L/s, and NFPA 20 Table 4.28(a) for 500 gpm floors the suction and
// discharge at 5 in = DN125 (150 % suction velocity 1.5 x 0.031545 /
// (pi 0.125^2 / 4) = 3.86 m/s <= 4.57 m/s), the discharge main dh past the
// header included. No pump-room pipe's service or drawn direction may move a
// size or an arrow.
library;

import 'dart:math' as math;

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

const _room = ['g', 's', 'd', 's2', 'd2'];

Network _duplex(Map<String, ServiceType> svc, {Set<String> flip = const {}}) {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('SH', 100),
    _n('P', 200, role: NodeRole.plant, c: NodeComponent.pump),
    _n('P2', 200, y: 100, role: NodeRole.plant, c: NodeComponent.pump),
    _n('DS', 300),
    _n('X0', 400),
    _n('Q0', 300, y: 400),
  ];
  NetEdge e(String id, String a, String b) => flip.contains(id)
      ? _e(id, b, a, s: svc[id] ?? _hy)
      : _e(id, a, b, s: svc[id] ?? _hy);
  final edges = <NetEdge>[
    e('g', 'GT', 'SH'),
    e('s', 'SH', 'P'),
    e('d', 'P', 'DS'),
    e('s2', 'SH', 'P2'),
    e('d2', 'P2', 'DS'),
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

void _expectSame(
    Map<String, EdgeSizing> r, Map<String, EdgeSizing> base, String why) {
  expect(r.keys.toSet(), base.keys.toSet(), reason: why);
  for (final id in base.keys) {
    expect(r[id]!.flow.inLitersPerSecond,
        closeTo(base[id]!.flow.inLitersPerSecond, 1e-6),
        reason: '$why $id');
    expect(r[id]!.diameter.inMillimeters, base[id]!.diameter.inMillimeters,
        reason: '$why $id');
    expect(r[id]!.flowFromId, base[id]!.flowFromId, reason: '$why $id');
  }
}

void main() {
  final base = _size(_duplex(const {}));

  test('all-hydrant duplex room: both legs 31.545 L/s DN125, dh DN125', () {
    for (final id in [..._room, 'dh']) {
      expect(base[id]!.flow.inLitersPerSecond, closeTo(31.545, 0.001),
          reason: id);
      expect(base[id]!.diameter.inMillimeters, 125, reason: id);
    }
    expect(base['d']!.flowFromId, 'P');
    expect(base['d2']!.flowFromId, 'P2');
    expect(base['s']!.flowFromId, 'SH');
    expect(base['s2']!.flowFromId, 'SH');
  });

  test('only s2 on the sprinkler service == all-hydrant (the finding)', () {
    _expectSame(_size(_duplex(const {'s2': _sp})), base, 's2 sprinkler');
  });

  test('the whole room on the sprinkler service == all-hydrant', () {
    _expectSame(_size(_duplex({for (final id in _room) id: _sp})), base,
        'room sprinkler');
  });

  test('seeded: pump-room services + drawn directions never move a result', () {
    final rnd = math.Random(66);
    for (var trial = 0; trial < 60; trial++) {
      final svc = {
        for (final id in _room) id: rnd.nextBool() ? _hy : _sp,
      };
      final flip = {
        for (final id in _room)
          if (rnd.nextBool()) id,
      };
      _expectSame(_size(_duplex(svc, flip: flip)), base,
          'trial $trial $svc flip $flip');
    }
  });
}
