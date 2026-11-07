// Round 67 — fire pump rooms read from what is drawn, never from the tank
// TYPE, the drawn fire service or a test line:
//
//  1 regression-1  an upper pump room whose suction tank is drawn as a ROOF
//                  tank (on its own floor) takes suction from it;
//  2 regression-2  a series room via a BREAK tank: the fill carries what the
//                  upper room draws, on every fire-service assignment / flip;
//  3 regression-3  a roof-tank booster set at the riser top draws from its
//                  roof tank (with or without a lower pump room);
//  4 regression-4  an FDC-fed pump's discharge carries the pump flow;
//  5 regression-5  a roof-tank standby feed into a pumped riser is sized on
//                  the riser flow (plain / check valve / sprinkler service);
//  19 fire-convergence-19  a pump TEST line back to the tank changes no
//                  pump-room size, flow, arrow or parallel-leg record.
//
// First principles (every case): one Class I stack, standpipeFlow(1) =
// 500 gpm = 500 x 3.785411784 / 60 = 31.545 L/s. NFPA 20 Table 4.28(a) for
// 500 gpm floors a pump's suction AND discharge at 5 in = DN125 (150 %
// suction velocity 1.5 x 0.031545 / (pi 0.125^2 / 4) = 3.86 m/s <= 4.57 m/s).
// A riser / run carrying 31.545 L/s at the 6 m/s fire velocity cap needs
// D >= sqrt(4 x 0.031545 / (pi x 6)) = 81.8 mm => DN100 (the riser bore a
// standby feed or a break-tank fill joins, so never below it).
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

const _hy = ServiceType.fireHydrant, _sp = ServiceType.fireSprinkler;
const _plant = NodeRole.plant;
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

Map<String, EdgeSizing> _size(Network net, int floors, {Set<String>? legs}) =>
    autoSizeNetwork(net, const SizingContext(),
        leafDemand: const {_hy: FlowRate(0.005), _sp: FlowRate(0.0015)},
        hydrantDesignFlow: standpipeFlow(1),
        sprinklerDemandCap: const FlowRate(0.012),
        building: BuildingLevels(
            [for (var i = 0; i < floors; i++) Floor('L$i', const Length(3.5))]),
        calibrationBySheet: const {'s1': ScaleCalibration(0.01)},
        parallelLegEdgeIdsOut: legs);

/// Builds a network from [nodes] and `(id, from, to, kind, service)` pipes,
/// moving pipes onto [svc] and redrawing [flip] in reverse.
Network _net(List<NetNode> nodes,
    List<(String, String, String, EdgeKind, ServiceType)> pipes,
    {Map<String, ServiceType> svc = const {}, Set<String> flip = const {}}) {
  return Network(nodes: nodes, edges: [
    for (final (id, a, b, k, s) in pipes)
      NetEdge(
          id: id,
          fromId: flip.contains(id) ? b : a,
          toId: flip.contains(id) ? a : b,
          service: svc[id] ?? s,
          kind: k),
  ]);
}

const _run = EdgeKind.run, _riser = EdgeKind.riser;

void _expectPipe(Map<String, EdgeSizing> r, String id,
    {required double mm,
    required double lps,
    required String from,
    String? why}) {
  final s = r[id];
  expect(s, isNotNull, reason: '${why ?? ''} $id sized');
  expect(s!.diameter.inMillimeters, mm, reason: '${why ?? ''} $id DN');
  expect(s.flow.inLitersPerSecond, closeTo(lps, 0.001),
      reason: '${why ?? ''} $id flow');
  expect(s.flowFromId, from, reason: '${why ?? ''} $id from');
}

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

// ── 1 ─────────────────────────────────────────────────────────────────────
Network _upperRoom(NodeComponent tank, {int tankFloor = 4}) => _net([
      _n('GT', 0, r: _plant, c: NodeComponent.groundTank),
      _n('P1', 100, r: _plant, c: NodeComponent.pump),
      for (var f = 1; f <= 8; f++) ...[
        _n('X$f', 200, f: f),
        _n('B$f', 300, f: f, r: NodeRole.fixture, c: NodeComponent.hydrantBox),
      ],
      _n('T', 0, f: tankFloor, y: 50, r: _plant, c: tank),
      _n('P2', 100, f: 4, y: 50, r: _plant, c: NodeComponent.pump),
    ], [
      ('s1', 'GT', 'P1', _run, _hy),
      ('d1', 'P1', 'X1', _riser, _hy),
      for (var f = 2; f <= 4; f++) ('r$f', 'X${f - 1}', 'X$f', _riser, _hy),
      ('t', 'X4', 'X5', _riser, _hy),
      ('s2', 'T', 'P2', tankFloor == 4 ? _run : _riser, _hy),
      ('d2', 'P2', 'X5', _riser, _hy),
      for (var f = 6; f <= 8; f++) ('r$f', 'X${f - 1}', 'X$f', _riser, _hy),
      for (var f = 1; f <= 8; f++) ('b$f', 'X$f', 'B$f', _run, _hy),
    ]);

// ── 2 ─────────────────────────────────────────────────────────────────────
List<NetNode> _breakNodes(bool duplex) => [
      _n('GT', 0, r: _plant, c: NodeComponent.groundTank),
      _n('SH', 50),
      _n('P1', 100, r: _plant, c: NodeComponent.pump),
      if (duplex) _n('P1b', 100, y: 30, r: _plant, c: NodeComponent.pump),
      _n('DS', 150),
      for (var f = 1; f <= 8; f++) ...[
        _n('X$f', 200, f: f),
        _n('B$f', 300, f: f, r: NodeRole.fixture, c: NodeComponent.hydrantBox),
      ],
      _n('T2', 0, f: 4, y: 50, r: _plant, c: NodeComponent.groundTank),
      _n('P2', 100, f: 4, y: 50, r: _plant, c: NodeComponent.pump),
      _n('RT', 0, f: 8, y: 50, r: _plant, c: NodeComponent.roofTank),
      _n('H6', 200,
          f: 6, y: -50, r: NodeRole.fixture, c: NodeComponent.sprinklerHead),
    ];
List<(String, String, String, EdgeKind, ServiceType)> _breakPipes(
        bool duplex) =>
    [
      ('g', 'GT', 'SH', _run, _hy),
      ('s1', 'SH', 'P1', _run, _hy),
      ('d1', 'P1', 'DS', _run, _hy),
      if (duplex) ...[
        ('s1b', 'SH', 'P1b', _run, _hy),
        ('d1b', 'P1b', 'DS', _run, _hy),
      ],
      ('dr', 'DS', 'X1', _riser, _hy),
      for (var f = 2; f <= 4; f++) ('r$f', 'X${f - 1}', 'X$f', _riser, _hy),
      ('fill', 'X4', 'T2', _run, _hy),
      ('s2', 'T2', 'P2', _run, _hy),
      ('d2', 'P2', 'X5', _riser, _hy),
      for (var f = 6; f <= 8; f++) ('r$f', 'X${f - 1}', 'X$f', _riser, _hy),
      ('o', 'RT', 'X8', _run, _hy),
      for (var f = 1; f <= 8; f++) ('b$f', 'X$f', 'B$f', _run, _hy),
      ('sh', 'X6', 'H6', _run, _sp),
    ];

// ── 19 ────────────────────────────────────────────────────────────────────
Network _testLineRoom(
    {required bool valves, required bool duplex, required bool testLine}) {
  return _net([
    _n('GT', 0, r: _plant, c: NodeComponent.groundTank),
    _n('SH', 50),
    _n('P', 100, r: _plant, c: NodeComponent.pump),
    if (duplex) _n('P2', 100, y: 40, r: _plant, c: NodeComponent.pump),
    if (valves) _n('CV1', 130, c: NodeComponent.checkValve),
    if (valves && duplex) _n('CV2', 130, y: 40, c: NodeComponent.checkValve),
    _n('DS', 160),
    _n('TV', 100, y: -60, c: NodeComponent.gateValve),
    for (var f = 1; f <= 4; f++) ...[
      _n('X$f', 200, f: f),
      _n('B$f', 300, f: f, r: NodeRole.fixture, c: NodeComponent.hydrantBox),
      _n('Q$f', 200, f: f, y: 80),
      _n('H$f', 300,
          f: f, y: 80, r: NodeRole.fixture, c: NodeComponent.sprinklerHead),
    ],
  ], [
    ('g', 'GT', 'SH', _run, _hy),
    ('s', 'SH', 'P', _run, _hy),
    if (valves) ...[
      ('d', 'P', 'CV1', _run, _hy),
      ('dc', 'CV1', 'DS', _run, _hy),
    ] else
      ('d', 'P', 'DS', _run, _hy),
    if (duplex) ...[
      ('s2', 'SH', 'P2', _run, _hy),
      if (valves) ...[
        ('d2', 'P2', 'CV2', _run, _hy),
        ('dc2', 'CV2', 'DS', _run, _hy),
      ] else
        ('d2', 'P2', 'DS', _run, _hy),
    ],
    ('dh', 'DS', 'X1', _riser, _hy),
    for (var f = 2; f <= 4; f++) ('r$f', 'X${f - 1}', 'X$f', _riser, _hy),
    for (var f = 1; f <= 4; f++) ('b$f', 'X$f', 'B$f', _run, _hy),
    ('dq', 'DS', 'Q1', _riser, _sp),
    for (var f = 2; f <= 4; f++) ('q$f', 'Q${f - 1}', 'Q$f', _riser, _sp),
    for (var f = 1; f <= 4; f++) ('h$f', 'Q$f', 'H$f', _run, _sp),
    if (testLine) ...[
      ('t1', 'DS', 'TV', _run, _hy),
      ('t2', 'TV', 'GT', _run, _hy),
    ],
  ]);
}

void main() {
  group('1 — an upper room\'s roof-TYPED suction tank on its own floor', () {
    final roof = _size(_upperRoom(NodeComponent.roofTank), 9);
    final ground = _size(_upperRoom(NodeComponent.groundTank), 9);
    test('s2 is the suction: DN125 at 31.545 L/s from the tank', () {
      _expectPipe(roof, 's2', mm: 125, lps: _q, from: 'T');
      _expectPipe(roof, 'd2', mm: 125, lps: _q, from: 'P2');
      expect(firePumpsDrawnBackwards(_upperRoom(NodeComponent.roofTank), roof),
          isEmpty);
    });
    test('the tank type never moves a size, flow or arrow', () {
      _expectSame(roof, ground, ground.keys, 'roof vs ground');
    });
    // Round 68 (regression-4) — the suction tank drawn on the slab ABOVE
    // the pump room (s2 a riser up to it): the roof-TYPED tank is reached
    // through P2's own leg (no junction), so it is the suction tank, read
    // exactly as a ground tank on any floor and as the same-floor drawing.
    for (final tf in [5, 6]) {
      test('the tank on L$tf (above the L4 pump) is still the suction', () {
        final net = _upperRoom(NodeComponent.roofTank, tankFloor: tf);
        final up = _size(net, 9);
        final gUp = _size(
            _upperRoom(NodeComponent.groundTank, tankFloor: tf), 9);
        _expectPipe(up, 's2', mm: 125, lps: _q, from: 'T');
        _expectPipe(up, 'd2', mm: 125, lps: _q, from: 'P2');
        expect(firePumpsDrawnBackwards(net, up), isEmpty);
        _expectSame(up, gUp, gUp.keys, 'roof L$tf vs ground L$tf');
        for (final id in ground.keys) {
          if (id == 's2') continue; // a riser here, a run on L4
          expect(up[id]?.diameter.inMillimeters,
              ground[id]?.diameter.inMillimeters,
              reason: 'L$tf vs L4 $id DN');
          expect(up[id]?.flowFromId, ground[id]?.flowFromId,
              reason: 'L$tf vs L4 $id from');
        }
      });
    }
  });

  group('2 — a series room via a break tank', () {
    for (final duplex in [false, true]) {
      final base = _size(_net(_breakNodes(duplex), _breakPipes(duplex)), 9);
      test('duplex=$duplex all hydrant: fill DN100 at 31.545 from X4', () {
        _expectPipe(base, 'fill', mm: 100, lps: _q, from: 'X4');
      });
      test('duplex=$duplex seeded services x flips: fill + pump rooms fixed',
          () {
        final rnd = math.Random(67 + (duplex ? 1 : 0));
        final candidates = [
          'g', 's1', 'd1', 'dr', 'r2', 'r3', 'r4', 'fill', 's2', 'd2', //
          'r6', 'r7', 'r8', 'o',
        ];
        final room = ['g', 's1', 'd1', 's2', 'd2', 'fill'];
        for (var trial = 0; trial < 40; trial++) {
          final svc = <String, ServiceType>{
            for (final id in candidates)
              if (rnd.nextDouble() < 0.3) id: _sp,
          };
          // The named single-pipe moves of the finding, always covered.
          if (trial < 4) {
            svc
              ..clear()
              ..[['fill', 'd2', 's2', 'r4'][trial]] = _sp;
          }
          final flip = <String>{
            for (final (id, _, _, _, _) in _breakPipes(duplex))
              if (rnd.nextDouble() < 0.3) id,
          };
          final r = _size(
              _net(_breakNodes(duplex), _breakPipes(duplex),
                  svc: svc, flip: flip),
              9);
          final why = 'trial $trial svc ${svc.keys} flip $flip';
          _expectSame(r, base, room, why);
        }
      });
    }
  });

  group('3 — a roof-tank booster set at the riser top', () {
    for (final lower in [true, false]) {
      test('lower pump room $lower: RT -> BP -> X4 at 31.545 on DN125', () {
        final net = _net([
          if (lower) ...[
            _n('GT', 0, r: _plant, c: NodeComponent.groundTank),
            _n('P', 100, r: _plant, c: NodeComponent.pump),
          ],
          for (var f = 1; f <= 4; f++) ...[
            _n('X$f', 200, f: f),
            _n('B$f', 300,
                f: f, r: NodeRole.fixture, c: NodeComponent.hydrantBox),
          ],
          _n('RT', 0, f: 4, y: 50, r: _plant, c: NodeComponent.roofTank),
          _n('BP', 100, f: 4, y: 50, r: _plant, c: NodeComponent.boosterSet),
          _n('H1', 200,
              f: 1,
              y: -50,
              r: NodeRole.fixture,
              c: NodeComponent.sprinklerHead),
        ], [
          if (lower) ...[
            ('s', 'GT', 'P', _run, _hy),
            ('d', 'P', 'X1', _riser, _hy),
          ],
          for (var f = 2; f <= 4; f++) ('r$f', 'X${f - 1}', 'X$f', _riser, _hy),
          ('o', 'RT', 'BP', _run, _hy),
          ('bd', 'BP', 'X4', _run, _hy),
          for (var f = 1; f <= 4; f++) ('b$f', 'X$f', 'B$f', _run, _hy),
          ('sh', 'X1', 'H1', _run, _sp),
        ]);
        final r = _size(net, 5);
        _expectPipe(r, 'o', mm: 125, lps: _q, from: 'RT');
        _expectPipe(r, 'bd', mm: 125, lps: _q, from: 'BP');
        expect(firePumpsDrawnBackwards(net, r), isEmpty);
      });
    }
  });

  group('4 — an FDC-fed pump with a roof standby', () {
    for (final head in [false, true]) {
      test('sprinkler head $head: FDC -> P -> DS on DN125 at 31.545', () {
        final net = _net([
          _n('FDC', 0, r: _plant, c: NodeComponent.fireDeptConnection),
          _n('P', 100, r: _plant, c: NodeComponent.pump),
          _n('DS', 150),
          for (var f = 1; f <= 4; f++) ...[
            _n('X$f', 200, f: f),
            _n('B$f', 300,
                f: f, r: NodeRole.fixture, c: NodeComponent.hydrantBox),
          ],
          _n('RT', 0, f: 4, y: 50, r: _plant, c: NodeComponent.roofTank),
          if (head)
            _n('H1', 200,
                f: 1,
                y: -50,
                r: NodeRole.fixture,
                c: NodeComponent.sprinklerHead),
        ], [
          ('f', 'FDC', 'P', _run, _hy),
          ('d', 'P', 'DS', _run, _hy),
          ('r1', 'DS', 'X1', _riser, _hy),
          for (var f = 2; f <= 4; f++) ('r$f', 'X${f - 1}', 'X$f', _riser, _hy),
          ('o', 'RT', 'X4', _run, _hy),
          for (var f = 1; f <= 4; f++) ('b$f', 'X$f', 'B$f', _run, _hy),
          if (head) ('sh', 'X1', 'H1', _run, _sp),
        ]);
        final r = _size(net, 5);
        _expectPipe(r, 'f', mm: 125, lps: _q, from: 'FDC');
        _expectPipe(r, 'd', mm: 125, lps: _q, from: 'P');
        expect(r['r1']!.flowFromId, 'DS');
      });
    }
  });

  group('5 — a roof standby feed into a pumped riser', () {
    for (final cv in [false, true]) {
      for (final s in [_hy, _sp]) {
        test('check valve $cv, drawn on $s: >= DN100 at 31.545 from RT', () {
          final net = _net([
            _n('GT', 0, r: _plant, c: NodeComponent.groundTank),
            _n('P', 100, r: _plant, c: NodeComponent.pump),
            for (var f = 1; f <= 4; f++) ...[
              _n('X$f', 200, f: f),
              _n('B$f', 300,
                  f: f, r: NodeRole.fixture, c: NodeComponent.hydrantBox),
            ],
            _n('RT', 0, f: 4, y: 50, r: _plant, c: NodeComponent.roofTank),
            if (cv) _n('CV', 100, f: 4, y: 50, c: NodeComponent.checkValve),
          ], [
            ('s', 'GT', 'P', _run, _hy),
            ('d', 'P', 'X1', _riser, _hy),
            for (var f = 2; f <= 4; f++)
              ('r$f', 'X${f - 1}', 'X$f', _riser, _hy),
            if (cv) ...[
              ('o1', 'RT', 'CV', _run, s),
              ('o2', 'CV', 'X4', _run, s),
            ] else
              ('o', 'RT', 'X4', _run, s),
            for (var f = 1; f <= 4; f++) ('b$f', 'X$f', 'B$f', _run, _hy),
          ]);
          final r = _size(net, 5);
          expect(r['r4']!.diameter.inMillimeters, 100);
          if (cv) {
            _expectPipe(r, 'o1', mm: 100, lps: _q, from: 'RT');
            _expectPipe(r, 'o2', mm: 100, lps: _q, from: 'CV');
          } else {
            _expectPipe(r, 'o', mm: 100, lps: _q, from: 'RT');
          }
          // The pump room is untouched.
          _expectPipe(r, 's', mm: 125, lps: _q, from: 'GT');
          _expectPipe(r, 'd', mm: 125, lps: _q, from: 'P');
        });
      }
    }
  });

  group('19 — a pump test line back to the ground tank', () {
    for (final valves in [true, false]) {
      for (final duplex in [true, false]) {
        test('valves $valves duplex $duplex: the room is unchanged', () {
          final legs0 = <String>{}, legs1 = <String>{};
          final without = _size(
              _testLineRoom(valves: valves, duplex: duplex, testLine: false), 5,
              legs: legs0);
          final withLine =
              _testLineRoom(valves: valves, duplex: duplex, testLine: true);
          final r = _size(withLine, 5, legs: legs1);
          _expectSame(r, without, without.keys, 'test line');
          expect(legs1, legs0);
          expect(firePumpsDrawnBackwards(withLine, r), isEmpty);
          // The test line carries no fire-event flow, header -> tank.
          expect(r['t1']!.flow.inLitersPerSecond, 0);
          expect(r['t1']!.flowFromId, 'DS');
          expect(r['t2']!.flowFromId, 'TV');
          expect(fireTestLineChains(withLine).single.edgeIds, ['t1', 't2']);
          // A pump discharge through a check valve flows pump -> header.
          if (valves) expect(r['dc']!.flowFromId, 'CV1');
          if (valves && duplex) expect(r['dc2']!.flowFromId, 'CV2');
        });
      }
    }
    test('a roof standby (its only pipe the feed) is no test line', () {
      final net = _net([
        _n('GT', 0, r: _plant, c: NodeComponent.groundTank),
        _n('P', 100, r: _plant, c: NodeComponent.pump),
        _n('X1', 200, f: 1),
        _n('B1', 300, f: 1, r: NodeRole.fixture, c: NodeComponent.hydrantBox),
        _n('RT', 0, f: 1, y: 50, r: _plant, c: NodeComponent.roofTank),
      ], [
        ('s', 'GT', 'P', _run, _hy),
        ('d', 'P', 'X1', _riser, _hy),
        ('b1', 'X1', 'B1', _run, _hy),
        ('o', 'RT', 'X1', _run, _hy),
      ]);
      expect(fireTestLineChains(net), isEmpty);
    });
    test('a break-tank fill is no test line', () {
      expect(fireTestLineChains(_net(_breakNodes(false), _breakPipes(false))),
          isEmpty);
    });
  });
}
