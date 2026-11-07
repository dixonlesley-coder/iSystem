// Round 71 (fire-convergence-23) — a BREAK tank's fill drawn on the OTHER
// fire service when the UPPER pump room is a DUPLEX set behind a suction
// header:
//
//   GT -> S -> P1 / P2 -> DH -> riser X1..X12 (hydrant box per storey)
//   fill X12 -> BT (ground tank, L12 or L13; run or riser)
//   BT -u- US -us1- UP1 / -us2- UP2 -> UDH -> riser X14..X26 (boxes)
//
// The Round-67 r2 fill pass sizes the fill on the largest flow on the tank's
// SUCTION LEGS; its walk stopped at the suction header US (two onward
// pipes) and found no leg, so a fill drawn on the sprinkler service was left
// DN25 at 0 L/s (64 m/s at the real flow).
//
// First principles: the upper zone is one Class I stack, standpipeFlow(1) =
// 500 gpm = 500 x 3.785411784 / 60 = 31.545 L/s; one duty pump runs, so the
// fill carries 31.545 L/s (never the sum of the legs) INTO BT, at the first
// fire bore with v <= 6 m/s that is >= the joined bore (DN100): at DN100
// v = 0.031545 / (pi x 0.1^2 / 4) = 4.02 m/s <= 6 => DN100, flowing from X12.
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

NetNode _n(String id, double x, int floor,
        {double y = 0, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: c?.role ?? NodeRole.main,
        component: c);

Network _tower(
    {required bool duplex,
    required int btFloor,
    required bool fillRiser,
    required ServiceType fillSvc,
    math.Random? shuffle}) {
  final nodes = <NetNode>[
    _n('GT', 0, 0, c: NodeComponent.groundTank),
    _n('S', 20, 0),
    _n('P1', 40, 0, c: NodeComponent.pump),
    _n('P2', 40, 0, y: 40, c: NodeComponent.pump),
    _n('DH', 60, 0),
    for (var f = 1; f <= 12; f++) ...[
      _n('X$f', 80, f),
      _n('B$f', 100, f, c: NodeComponent.hydrantBox),
    ],
    _n('BT', 120, btFloor, c: NodeComponent.groundTank),
    _n('US', 140, btFloor),
    _n('UP1', 160, btFloor, c: NodeComponent.pump),
    if (duplex) _n('UP2', 160, btFloor, y: 40, c: NodeComponent.pump),
    _n('UDH', 180, btFloor),
    for (var f = 14; f <= 26; f++) ...[
      _n('X$f', 200, f),
      _n('B$f', 220, f, c: NodeComponent.hydrantBox),
    ],
  ];
  NetEdge e(String id, String a, String b,
          {EdgeKind k = EdgeKind.run, ServiceType s = _hy}) =>
      NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);
  final edges = <NetEdge>[
    e('g', 'GT', 'S'),
    e('s1', 'S', 'P1'),
    e('s2', 'S', 'P2'),
    e('d1', 'P1', 'DH'),
    e('d2', 'P2', 'DH'),
    e('x1', 'DH', 'X1', k: EdgeKind.riser),
    for (var f = 2; f <= 12; f++)
      e('x$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser),
    for (var f = 1; f <= 12; f++) e('b$f', 'X$f', 'B$f'),
    e('fill', 'X12', 'BT',
        k: fillRiser ? EdgeKind.riser : EdgeKind.run, s: fillSvc),
    e('u', 'BT', 'US'),
    e('us1', 'US', 'UP1'),
    if (duplex) e('us2', 'US', 'UP2'),
    e('ud1', 'UP1', 'UDH'),
    if (duplex) e('ud2', 'UP2', 'UDH'),
    e('x14', 'UDH', 'X14', k: EdgeKind.riser),
    for (var f = 15; f <= 26; f++)
      e('x$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser),
    for (var f = 14; f <= 26; f++) e('b$f', 'X$f', 'B$f'),
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
        [for (var i = 0; i < 27; i++) Floor('L$i', const Length(3.5))]),
    calibrationBySheet: const {'s1': ScaleCalibration(0.01)});

void main() {
  final q = standpipeFlow(1).inLitersPerSecond; // 31.545 L/s

  test(
      'the fill reads the duplex suction header: DN100 at 31.545 L/s into BT '
      'on every service / floor / kind', () {
    for (final duplex in [false, true]) {
      for (final btFloor in [12, 13]) {
        for (final fillRiser in [false, true]) {
          for (final svc in [_hy, _sp]) {
            final why = 'duplex $duplex L$btFloor riser $fillRiser $svc';
            final r = _size(_tower(
                duplex: duplex,
                btFloor: btFloor,
                fillRiser: fillRiser,
                fillSvc: svc));
            final f = r['fill'];
            expect(f, isNotNull, reason: why);
            expect(f!.flow.inLitersPerSecond, closeTo(q, 1e-3), reason: why);
            expect(f.diameter.inMillimeters, 100, reason: why);
            expect(f.flowFromId, 'X12', reason: why);
          }
        }
      }
    }
  });

  test('seeded: services x floor x kind x list order never move the fill', () {
    final rnd = math.Random(71);
    for (var t = 0; t < 16; t++) {
      final svc = rnd.nextBool() ? _hy : _sp;
      final r = _size(_tower(
          duplex: true,
          btFloor: 12 + rnd.nextInt(2),
          fillRiser: rnd.nextBool(),
          fillSvc: svc,
          shuffle: rnd));
      expect(r['fill']!.flow.inLitersPerSecond, closeTo(q, 1e-3),
          reason: 'trial $t');
      expect(r['fill']!.diameter.inMillimeters, 100, reason: 'trial $t');
      expect(r['fill']!.flowFromId, 'X12', reason: 'trial $t');
    }
  });
}
