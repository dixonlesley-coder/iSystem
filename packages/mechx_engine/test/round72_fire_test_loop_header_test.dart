// Round 72 (fire-convergence-24-test-loop-to-suction-header-bypasses-pump) —
// a closed-loop METERING test line / pump bypass drawn from the discharge
// header back to the SUCTION HEADER (NFPA 20 4.21.3.4 flow-meter loop,
// 4.14.4 bypass) is a test line exactly like one returned to the tank: it
// carries the pump's test flow, never fire-event demand.
//
// Probe: 11 storeys of 4 m, calibrated 0.01 m/px.
//   GT -g- SH -s- P -d- DH -m- X0, riser X0..X10, a hydrant box per storey
//   X1..X10, and a test loop DH -t1- TH (flow meter / gate valve) -t2- SH.
//
// First principles: one Class I stack, standpipeFlow(1) = 500 gpm =
// 500 x 3.785411784 / 60 = 31.545 L/s. NFPA 20 Table 4.28(a) for 500 gpm
// floors the suction and the discharge at 5 in = DN125; in DN100 the
// suction would run at 0.031545 / (pi 0.1^2 / 4) = 4.02 m/s, 6.02 m/s at
// 150 % flow — above the 4.57 m/s suction limit. So g, s, d, m and the
// first riser x1 are DN125 at 31.545 L/s, and the loop carries 0 L/s
// flowing DH -> TH -> SH, whatever end (GT or SH) or direction it is drawn.
// Before the fix the SH loop was a pipe in parallel with the pump: g / m /
// x1 fell to DN100 and t1 / t2 carried the full 31.545 L/s SH -> TH -> DH.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _hy = ServiceType.fireHydrant;
const _q = 31.545;

NetNode _n(String id, double x,
        {int f = 0,
        double y = 0,
        NodeRole r = NodeRole.main,
        NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: f,
        role: r,
        component: c);

enum _Loop { none, toTank, toHeader }

/// [duplex] adds P2 (SH -> P2 -> DH); [jockey] adds JP likewise.
/// [flip] redraws those pipe ids reversed.
Network _room(
    {required _Loop loop,
    bool duplex = false,
    bool jockey = false,
    Set<String> flip = const {}}) {
  NetEdge e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
      NetEdge(
          id: id,
          fromId: flip.contains(id) ? b : a,
          toId: flip.contains(id) ? a : b,
          service: _hy,
          kind: k);
  return Network(nodes: [
    _n('GT', 0, r: NodeRole.plant, c: NodeComponent.groundTank),
    _n('SH', 50),
    _n('P', 100, r: NodeRole.plant, c: NodeComponent.pump),
    if (duplex) _n('P2', 100, y: 40, r: NodeRole.plant, c: NodeComponent.pump),
    if (jockey) _n('JP', 100, y: 80, r: NodeRole.plant, c: NodeComponent.pump),
    _n('DH', 160),
    if (loop != _Loop.none) _n('TH', 100, y: -60, c: NodeComponent.gateValve),
    for (var f = 0; f <= 10; f++) _n('X$f', 200, f: f),
    for (var f = 1; f <= 10; f++)
      _n('B$f', 300, f: f, r: NodeRole.fixture, c: NodeComponent.hydrantBox),
  ], edges: [
    e('g', 'GT', 'SH'),
    e('s', 'SH', 'P'),
    e('d', 'P', 'DH'),
    if (duplex) ...[e('s2', 'SH', 'P2'), e('d2', 'P2', 'DH')],
    if (jockey) ...[e('sj', 'SH', 'JP'), e('dj', 'JP', 'DH')],
    e('m', 'DH', 'X0'),
    for (var f = 1; f <= 10; f++)
      e('x$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser),
    for (var f = 1; f <= 10; f++) e('b$f', 'X$f', 'B$f'),
    if (loop != _Loop.none) ...[
      e('t1', 'DH', 'TH'),
      e('t2', 'TH', loop == _Loop.toTank ? 'GT' : 'SH'),
    ],
  ]);
}

Map<String, EdgeSizing> _size(Network net,
        {Set<String>? legs, Map<String, FlowRate> jockey = const {}}) =>
    autoSizeNetwork(net, const SizingContext(),
        leafDemand: const {_hy: FlowRate(0.005)},
        hydrantDesignFlow: standpipeFlow(1),
        jockeyLegFlows: jockey,
        building: BuildingLevels(
            [for (var i = 0; i < 11; i++) Floor('L$i', const Length(4))]),
        calibrationBySheet: const {'s1': ScaleCalibration(0.01)},
        parallelLegEdgeIdsOut: legs);

void _expectSame(Map<String, EdgeSizing> r, Map<String, EdgeSizing> base,
    Iterable<String> ids, String why) {
  for (final id in ids) {
    expect(r[id]?.diameter.inMillimeters, base[id]?.diameter.inMillimeters,
        reason: '$why $id DN');
    expect(r[id]?.flow.inLitersPerSecond,
        closeTo(base[id]!.flow.inLitersPerSecond, 1e-6),
        reason: '$why $id flow');
    expect(r[id]?.flowFromId, base[id]?.flowFromId, reason: '$why $id from');
  }
}

void main() {
  test('first principles: 500 gpm = 31.545 L/s', () {
    expect(standpipeFlow(1).inLitersPerSecond, closeTo(_q, 0.001));
    // DN100 at 150 % flow breaches 4.57 m/s; DN125 holds it.
    double v(double mm) =>
        1.5 * _q / 1000 / (math.pi * math.pow(mm / 1000, 2) / 4);
    expect(v(100), greaterThan(4.57));
    expect(v(125), lessThan(4.57));
  });

  test('no loop: the NFPA 20 pump train is DN125 at 31.545 L/s', () {
    final r = _size(_room(loop: _Loop.none));
    for (final id in ['g', 's', 'd', 'm', 'x1']) {
      expect(r[id]!.diameter.inMillimeters, 125, reason: '$id DN');
      expect(r[id]!.flow.inLitersPerSecond, closeTo(_q, 0.01), reason: id);
    }
  });

  for (final reversed in [false, true]) {
    test('loop to the SUCTION HEADER (reversed: $reversed) == no loop', () {
      final base = _size(_room(loop: _Loop.none));
      final net = _room(
          loop: _Loop.toHeader, flip: reversed ? const {'t1', 't2'} : const {});
      final r = _size(net);
      _expectSame(r, base, base.keys, 'header loop');
      expect(r['t1']!.flow.inLitersPerSecond, 0);
      expect(r['t2']!.flow.inLitersPerSecond, 0);
      expect(r['t1']!.flowFromId, 'DH');
      expect(r['t2']!.flowFromId, 'TH');
      final lines = fireTestLineChains(net);
      expect(lines.single.edgeIds, ['t1', 't2']);
      expect(lines.single.joinId, 'DH');
      expect(lines.single.tankId, 'SH');
    });
  }

  test('loop to the tank (Round 67) is unchanged', () {
    final base = _size(_room(loop: _Loop.none));
    final net = _room(loop: _Loop.toTank);
    final r = _size(net);
    _expectSame(r, base, base.keys, 'tank loop');
    expect(fireTestLineChains(net).single.tankId, 'GT');
  });

  test('a duplex + jockey room with a header loop == without', () {
    const jockey = {'JP': FlowRate(0.0005)};
    final legs0 = <String>{}, legs1 = <String>{};
    final base = _size(_room(loop: _Loop.none, duplex: true, jockey: true),
        legs: legs0, jockey: jockey);
    final r = _size(_room(loop: _Loop.toHeader, duplex: true, jockey: true),
        legs: legs1, jockey: jockey);
    _expectSame(r, base, base.keys, 'duplex+jockey');
    expect(legs1, legs0);
    expect(r['t1']!.flow.inLitersPerSecond, 0);
  });

  test('the pump legs themselves are never test lines', () {
    // A duplex room's parallel pump legs sit on the same cycle as the
    // header loop but pass a plant: no candidate.
    final lines =
        fireTestLineChains(_room(loop: _Loop.none, duplex: true, jockey: true));
    expect(lines, isEmpty);
  });

  test(
      'seeded: the loop end (GT vs SH) and its drawn direction never move a '
      'pump-room size, flow or arrow', () {
    final rng = math.Random(72);
    for (var trial = 0; trial < 12; trial++) {
      final duplex = rng.nextBool();
      final base = _size(_room(loop: _Loop.none, duplex: duplex));
      final loop = rng.nextBool() ? _Loop.toTank : _Loop.toHeader;
      final flip = <String>{
        for (final id in ['t1', 't2', 'g', 's', 'd', 'm'])
          if (rng.nextBool()) id,
      };
      final r = _size(_room(loop: loop, duplex: duplex, flip: flip));
      _expectSame(r, base, base.keys, 'trial $trial ($loop, $flip)');
      expect(r['t1']!.flow.inLitersPerSecond, 0);
      expect(r['t2']!.flow.inLitersPerSecond, 0);
      expect(r['t1']!.flowFromId, 'DH');
    }
  });
}
