// Round 74 (regression-1) — a test loop from a SERIES room's top discharge
// header back to the FIRST stage's suction header is a test line, exactly
// like one returned to its own stage's suction header.
//
// Probe: 11 storeys of 4 m, calibrated 0.01 m/px, hydrant class I.
//   GT -g- SH -s- P1 -d- DH1 -m- X0, riser X0..X5 (boxes L1-L4),
//   X5 -h- SH2 -s2- P2 (L5) -d2- DH2 -m2- Y5, riser Y5..Y10 (boxes L6-L10),
//   test loop DH2 -t1- TH (gate valve) -t2- SH  (or SH2, or GT — the
//   common NFPA 20 flow-meter loop back to the suction TANK, Round 74 r2:
//   before it t1 / t2 carried 31.545 L/s GT -> TH -> DH2, h reversed and
//   m2 / y6 fell from DN125 to DN100).
//
// First principles: standpipeFlow(1) = 500 gpm = 31.545 L/s. The loop
// carries the pump's TEST flow, never fire-event demand: every pipe sizes,
// flows and points exactly as with no loop, and t1 / t2 carry 0 L/s from
// DH2. Before the fix the SH loop was a pipe in parallel with both pumps:
// t1 / t2 carried 31.55 L/s SH -> TH -> DH2 at DN100, g fell to DN100
// (1.5 x 0.031545 / (pi 0.1^2 / 4) = 6.02 m/s > the NFPA 20 4.57 m/s
// suction cap) and the upper stage read reversed.
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

enum _Loop { none, toFirstSuction, toOwnSuction, toTank }

const _pumpRoomIds = ['g', 's', 'd', 'm', 'h', 's2', 'd2', 'm2'];

Network _room({required _Loop loop, Set<String> flip = const {}}) {
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
    _n('P1', 100, r: NodeRole.plant, c: NodeComponent.pump),
    _n('DH1', 160),
    for (var f = 0; f <= 5; f++) _n('X$f', 200, f: f),
    for (var f = 1; f <= 4; f++)
      _n('B$f', 300, f: f, r: NodeRole.fixture, c: NodeComponent.hydrantBox),
    _n('SH2', 250, f: 5),
    _n('P2', 300, f: 5, r: NodeRole.plant, c: NodeComponent.pump),
    _n('DH2', 350, f: 5),
    for (var f = 5; f <= 10; f++) _n('Y$f', 400, f: f),
    for (var f = 6; f <= 10; f++)
      _n('C$f', 500, f: f, r: NodeRole.fixture, c: NodeComponent.hydrantBox),
    if (loop != _Loop.none) _n('TH', 100, y: -60, c: NodeComponent.gateValve),
  ], edges: [
    e('g', 'GT', 'SH'),
    e('s', 'SH', 'P1'),
    e('d', 'P1', 'DH1'),
    e('m', 'DH1', 'X0'),
    for (var f = 1; f <= 5; f++)
      e('x$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser),
    for (var f = 1; f <= 4; f++) e('b$f', 'X$f', 'B$f'),
    e('h', 'X5', 'SH2'),
    e('s2', 'SH2', 'P2'),
    e('d2', 'P2', 'DH2'),
    e('m2', 'DH2', 'Y5'),
    for (var f = 6; f <= 10; f++)
      e('y$f', 'Y${f - 1}', 'Y$f', k: EdgeKind.riser),
    for (var f = 6; f <= 10; f++) e('c$f', 'Y$f', 'C$f'),
    if (loop != _Loop.none) ...[
      e('t1', 'DH2', 'TH'),
      e(
          't2',
          'TH',
          switch (loop) {
            _Loop.toFirstSuction => 'SH',
            _Loop.toTank => 'GT',
            _ => 'SH2',
          }),
    ],
  ]);
}

Map<String, EdgeSizing> _size(Network net) => autoSizeNetwork(
    net, const SizingContext(),
    leafDemand: const {_hy: FlowRate(0.005)},
    hydrantDesignFlow: standpipeFlow(1),
    building: BuildingLevels(
        [for (var i = 0; i < 11; i++) Floor('L$i', const Length(4))]),
    calibrationBySheet: const {'s1': ScaleCalibration(0.01)});

void main() {
  final base = _size(_room(loop: _Loop.none));
  final ids = [
    for (final e in _room(loop: _Loop.none).edges) e.id,
  ];

  void expectSame(Map<String, EdgeSizing> r, String why) {
    for (final id in ids) {
      expect(r[id]?.diameter.inMillimeters, base[id]?.diameter.inMillimeters,
          reason: '$why $id DN');
      expect(r[id]?.flow.inLitersPerSecond,
          closeTo(base[id]!.flow.inLitersPerSecond, 1e-6),
          reason: '$why $id flow');
      expect(r[id]?.flowFromId, base[id]?.flowFromId, reason: '$why $id from');
    }
    expect(r['t1']?.flow.cubicMetersPerSecond ?? 0, 0, reason: '$why t1');
    expect(r['t2']?.flow.cubicMetersPerSecond ?? 0, 0, reason: '$why t2');
    if (r['t1'] != null) {
      expect(r['t1']!.flowFromId, 'DH2', reason: '$why t1 from');
    }
  }

  test('the loop to the FIRST stage suction header is a test line', () {
    final lines = fireTestLineChains(_room(loop: _Loop.toFirstSuction));
    expect(lines, hasLength(1));
    expect(lines.single.joinId, 'DH2');
    expect(lines.single.tankId, 'SH');
    expect(base['g']!.diameter.inMillimeters, 125);
  });

  test('the loop back to the suction TANK is a test line (r2)', () {
    final lines = fireTestLineChains(_room(loop: _Loop.toTank));
    expect(lines, hasLength(1));
    expect(lines.single.joinId, 'DH2');
    expect(lines.single.tankId, 'GT');
    expect(base['m2']!.diameter.inMillimeters, 125);
    expect(base['y6']!.diameter.inMillimeters, 125);
  });

  test('loop to SH / SH2 / GT, every drawn direction of t1 / t2 == no loop',
      () {
    for (final loop in [
      _Loop.toFirstSuction,
      _Loop.toOwnSuction,
      _Loop.toTank,
    ]) {
      for (final flip in [
        <String>{},
        {'t1'},
        {'t2'},
        {'t1', 't2'},
      ]) {
        expectSame(_size(_room(loop: loop, flip: flip)), '$loop $flip');
      }
    }
  });

  test('seeded: flips of the pump-room pipes with the SH / GT loop == no loop', () {
    final rnd = math.Random(7401);
    for (var t = 0; t < 12; t++) {
      final flip = {
        for (final id in [..._pumpRoomIds, 't1', 't2'])
          if (rnd.nextBool()) id,
      };
      final noLoop = _size(_room(loop: _Loop.none, flip: flip));
      final r = _size(_room(
          loop: t.isEven ? _Loop.toFirstSuction : _Loop.toTank, flip: flip));
      for (final id in ids) {
        expect(r[id]?.diameter.inMillimeters,
            noLoop[id]?.diameter.inMillimeters,
            reason: 't$t $flip $id DN');
        expect(r[id]?.flow.inLitersPerSecond,
            closeTo(noLoop[id]!.flow.inLitersPerSecond, 1e-6),
            reason: 't$t $flip $id flow');
        expect(r[id]?.flowFromId, noLoop[id]?.flowFromId,
            reason: 't$t $flip $id from');
      }
      expect(r['t1']?.flow.cubicMetersPerSecond ?? 0, 0);
    }
  });
}
