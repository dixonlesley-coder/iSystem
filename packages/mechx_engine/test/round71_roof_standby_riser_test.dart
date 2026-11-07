// Round 71 (fire-convergence-23-roof-standby-riser-arrow-into-tank) — a
// roof-tank GRAVITY STANDBY tied to the top of a pumped hydrant riser,
// drawn as a RISER (RT on the roof storey above the riser top):
//
//   GT -s- P -d(riser)- X1 .. X4 (hydrant box per storey), RT (L5) -o- X4
//
// On the hydrant service the riser o joined the standpipe riser component,
// the trunk pass carried it oriented X4 -> RT, and the Round-50/67 roof-tank
// chain pass skipped it because it already carried flow: the issued arrow
// showed the standby pumped INTO the tank at fire flow. Drawn as a run, or
// on the sprinkler service, it read RT -> X4 (Round 67 group 5).
//
// First principles: the tank only ever delivers into the riser (the pump
// room refills it through its own make-up, not the standpipe), so every
// drawing flows FROM RT at the standpipe flow standpipeFlow(1) = 500 gpm =
// 31.545 L/s, on >= DN100 (0.031545 / (pi 0.1^2 / 4) = 4.02 m/s <= 6 m/s).
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _hy = ServiceType.fireHydrant, _sp = ServiceType.fireSprinkler;

NetNode _n(String id, double x, int floor, {double y = 0, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: c?.role ?? NodeRole.main,
        component: c);

Network _net(
    {required bool riser,
    required ServiceType svc,
    bool flip = false,
    math.Random? shuffle}) {
  final nodes = <NetNode>[
    _n('GT', 0, 0, c: NodeComponent.groundTank),
    _n('P', 100, 0, c: NodeComponent.pump),
    for (var f = 1; f <= 4; f++) ...[
      _n('X$f', 200, f),
      _n('B$f', 300, f, c: NodeComponent.hydrantBox),
    ],
    _n('RT', 200, riser ? 5 : 4, y: 50, c: NodeComponent.roofTank),
  ];
  NetEdge e(String id, String a, String b,
          {EdgeKind k = EdgeKind.run, ServiceType s = _hy}) =>
      NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);
  final edges = <NetEdge>[
    e('s', 'GT', 'P'),
    e('d', 'P', 'X1', k: EdgeKind.riser),
    for (var f = 2; f <= 4; f++)
      e('r$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser),
    for (var f = 1; f <= 4; f++) e('b$f', 'X$f', 'B$f'),
    flip
        ? e('o', 'X4', 'RT',
            k: riser ? EdgeKind.riser : EdgeKind.run, s: svc)
        : e('o', 'RT', 'X4',
            k: riser ? EdgeKind.riser : EdgeKind.run, s: svc),
  ];
  if (shuffle != null) {
    nodes.shuffle(shuffle);
    edges.shuffle(shuffle);
  }
  return Network(nodes: nodes, edges: edges);
}

Map<String, EdgeSizing> _size(Network net) => autoSizeNetwork(
    net, const SizingContext(),
    leafDemand: const {_hy: FlowRate(0.005), _sp: FlowRate(0.0015)},
    hydrantDesignFlow: standpipeFlow(1),
    sprinklerDemandCap: const FlowRate(0.012),
    building: BuildingLevels(
        [for (var i = 0; i < 6; i++) Floor('L$i', const Length(3.5))]),
    calibrationBySheet: const {'s1': ScaleCalibration(0.01)});

void main() {
  final q = standpipeFlow(1).inLitersPerSecond; // 31.545 L/s

  test('run / riser x hydrant / sprinkler x drawn direction: from RT', () {
    for (final riser in [false, true]) {
      for (final svc in [_hy, _sp]) {
        for (final flip in [false, true]) {
          final why = 'riser $riser $svc flip $flip';
          final r = _size(_net(riser: riser, svc: svc, flip: flip));
          expect(r['o']!.flowFromId, 'RT', reason: why);
          expect(r['o']!.flow.inLitersPerSecond, closeTo(q, 1e-3),
              reason: why);
          expect(r['o']!.diameter.inMillimeters, greaterThanOrEqualTo(100),
              reason: why);
          // The pump room is untouched.
          expect(r['s']!.flowFromId, 'GT', reason: why);
          expect(r['d']!.flowFromId, 'P', reason: why);
          expect(r['s']!.flow.inLitersPerSecond, closeTo(q, 1e-3),
              reason: why);
        }
      }
    }
  });

  test('seeded: list order never moves the standby arrow', () {
    final rnd = math.Random(711);
    for (var t = 0; t < 16; t++) {
      final r = _size(_net(
          riser: rnd.nextBool(),
          svc: rnd.nextBool() ? _hy : _sp,
          flip: rnd.nextBool(),
          shuffle: rnd));
      expect(r['o']!.flowFromId, 'RT', reason: 'trial $t');
      expect(r['o']!.flow.inLitersPerSecond, closeTo(q, 1e-3),
          reason: 'trial $t');
    }
  });
}
