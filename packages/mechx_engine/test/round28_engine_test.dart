/// Round 28 (2026-10-18) — engine seed suite.
///
///  1. regression-envelope-scenario-a-not-iterated — the balance-against-pump
///     envelope's scenario (a) is iterated to a fixed point: a hotel with a
///     circulator on every return riser never sizes its supply main below the
///     OPEN network (every circulator leg closed = the returns absent).
///  2. regression-classifier-quadratic-dijkstra — classification cost: a
///     30-riser x 10-storey hotel with a return check valve per riser sizes
///     within a small multiple of the identical valveless drawing.
///  3. residuals-1 — a duty/standby pump set drawn WITHOUT check valves is
///     the same Round-13 parallel set as with them: every leg on the full set
///     flow.
///  4. residuals-2 — a circulator on the heater discharge with a valveless
///     return: the supply main carries the whole peak (envelope with the
///     return closed).
///  5. residuals-3 — an ambiguous heater discharge valve beside per-riser
///     circulators feeding a plain return chain is a FEED (the return chain is
///     fed only through circulators).
///  6. fire systems — independent standpipes count their own stacks; the
///     sized index-path friction (Hazen–Williams) feeds the rated head.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_sprinkler_hydraulic.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b,
        {EdgeKind k = EdgeKind.run, ServiceType s = ServiceType.hotWater}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

BuildingLevels _levels(int f) => BuildingLevels(
    [for (var i = 0; i < f; i++) Floor('L$i', const Length(3.0))]);

const _sni = SniProfile();
double _curve(double ubap) =>
    _sni.probableFlowForFixtureUnits(ubap).inLitersPerSecond;

class _Run {
  final Map<String, EdgeSizing> s;
  final Set<String> moverAgainst;
  final Map<String, CheckValveAmbiguity> amb;
  final Set<String> par;
  _Run(this.s, this.moverAgainst, this.amb, this.par);
  double q(String id) => s[id]?.flow.inLitersPerSecond ?? 0.0;
  int dn(String id) => s[id]!.diameter.inMillimeters.round();
  String? from(String id) => s[id]?.flowFromId;
}

_Run _size(Network net,
    {bool cal = false,
    int floors = 5,
    ServiceType service = ServiceType.hotWater,
    double ubap = 2.0}) {
  final ma = <String>{};
  final amb = <String, CheckValveAmbiguity>{};
  final par = <String>{};
  final s = autoSizeNetwork(
    net,
    const SizingContext(),
    leafDemand: {service: const FlowRate(0)},
    leafFixtureUnits: {service: ubap},
    building: cal ? _levels(floors) : null,
    calibrationBySheet: cal ? const {'s1': ScaleCalibration(0.05)} : const {},
    moverAgainstBalanceOut: ma,
    checkValveAmbiguousOut: amb,
    parallelLegEdgeIdsOut: par,
  );
  return _Run(s, ma, amb, par);
}

/// A hotel: heater H -> M -> T0..T(n-1) supply main; each T_k a supply riser
/// of [f] floors (a 2-UBAP fixture per floor), the riser top down a return
/// riser to R_k_0, then [ret] back to RB_k on a return main RB(n-1) .. RB0 ->
/// RJ -> H (valveless). [ret]: 'pump' a valveless circulator, 'cv' a check
/// valve drawn toward the heater, 'pumpcv' / 'cvpump' both, 'none' a pipe.
/// [open] leaves every return out (= every circulator leg closed).
Network _hotel(int n, int f,
    {String ret = 'pump',
    bool open = false,
    List<double>? xs,
    List<double>? rby}) {
  final nodes = <NetNode>[_n('H', 0, 0, role: NodeRole.plant), _n('M', 50, 0)];
  final edges = <NetEdge>[_e('hm', 'H', 'M')];
  for (var k = 0; k < n; k++) {
    final x = xs?[k] ?? 100.0 + 120 * k;
    nodes.add(_n('T$k', x, 0));
    edges.add(_e('m$k', k == 0 ? 'M' : 'T${k - 1}', 'T$k'));
    for (var i = 0; i < f; i++) {
      nodes
        ..add(_n('S${k}_$i', x, 0, floor: i))
        ..add(_n('fx${k}_$i', x + 40, 0, floor: i, role: NodeRole.fixture));
      edges.add(_e('b${k}_$i', 'S${k}_$i', 'fx${k}_$i'));
      edges.add(i == 0
          ? _e('s${k}_0', 'T$k', 'S${k}_0')
          : _e('s${k}_$i', 'S${k}_${i - 1}', 'S${k}_$i', k: EdgeKind.riser));
      if (!open) nodes.add(_n('R${k}_$i', x + 20, 30, floor: i));
    }
    if (open) continue;
    edges.add(_e('top$k', 'S${k}_${f - 1}', 'R${k}_${f - 1}'));
    for (var i = f - 1; i >= 1; i--) {
      edges
          .add(_e('r${k}_$i', 'R${k}_$i', 'R${k}_${i - 1}', k: EdgeKind.riser));
    }
    nodes.add(_n('RB$k', x + 20, rby?[k] ?? 60.0));
    if (ret == 'pump' || ret == 'cv') {
      final c = ret == 'pump' ? NodeComponent.pump : NodeComponent.checkValve;
      nodes.add(_n('P$k', x + 20, 45,
          role: ret == 'pump' ? NodeRole.plant : NodeRole.main, c: c));
      edges
        ..add(_e('rp$k', 'R${k}_0', 'P$k'))
        ..add(_e('pb$k', 'P$k', 'RB$k'));
    } else if (ret == 'pumpcv' || ret == 'cvpump') {
      final pumpFirst = ret == 'pumpcv';
      nodes
        ..add(_n('P$k', x + 20, 45,
            role: pumpFirst ? NodeRole.plant : NodeRole.main,
            c: pumpFirst ? NodeComponent.pump : NodeComponent.checkValve))
        ..add(_n('Q$k', x + 20, 50,
            role: pumpFirst ? NodeRole.main : NodeRole.plant,
            c: pumpFirst ? NodeComponent.checkValve : NodeComponent.pump));
      edges
        ..add(_e('rp$k', 'R${k}_0', 'P$k'))
        ..add(_e('pq$k', 'P$k', 'Q$k'))
        ..add(_e('qb$k', 'Q$k', 'RB$k'));
    } else {
      edges.add(_e('rb$k', 'R${k}_0', 'RB$k'));
    }
    if (k > 0) edges.add(_e('rm$k', 'RB$k', 'RB${k - 1}'));
  }
  if (!open) {
    nodes.add(_n('RJ', 60, 40));
    edges
      ..add(_e('rbj', 'RB0', 'RJ'))
      ..add(_e('rjh', 'RJ', 'H'));
  }
  return Network(nodes: nodes, edges: edges);
}

/// Every SUPPLY pipe of the hotel (heater outlet, supply main, risers).
Iterable<String> _supplyIds(int n, int f) sync* {
  yield 'hm';
  for (var k = 0; k < n; k++) {
    yield 'm$k';
    for (var i = 0; i < f; i++) {
      yield 's${k}_$i';
    }
  }
}

void main() {
  group('1 — scenario (a) iterated to a fixed point', () {
    test(
        'first principles: 24 risers x 4 floors x 2 UBAP = 192 UBAP -> '
        'curve(192); 25 risers -> curve(200); both need DN65', () {
      // The flush-tank curve is linear between its tabulated points; the
      // engine's own curve is the reference.
      expect(_curve(192), closeTo(4.5973, 1e-4));
      expect(_curve(200), closeTo(4.7333, 1e-4));
      // DN50 (50 mm bore) at 4.5973 L/s: 4Q/(pi D^2) = 2.34 m/s > 2.0.
      expect(4 * 4.5973e-3 / (math.pi * 0.05 * 0.05), greaterThan(2.0));
    });

    test(
        'the regular hotel with a circulator per return riser: the heater '
        'outlet carries the OPEN network curve(UBAP) at 24, 25 and 30 '
        'risers, for pump / pump+valve / valve+pump legs (was 2.75 L/s DN50 '
        'at 24 risers)', () {
      for (final n in [24, 25, 30]) {
        final open = _size(_hotel(n, 4, open: true));
        expect(open.q('hm'), closeTo(_curve(n * 4 * 2.0), 1e-9));
        for (final ret in ['pump', 'pumpcv', 'cvpump']) {
          final why = 'n=$n ret=$ret';
          final r = _size(_hotel(n, 4, ret: ret));
          expect(r.q('hm'), closeTo(_curve(n * 4 * 2.0), 1e-9), reason: why);
          expect(r.dn('hm'), open.dn('hm'), reason: why);
          expect(r.dn('hm'), 65, reason: why);
        }
      }
    });

    test(
        'the reviewer 3-riser x 5-floor geometry: hm = curve(30) = 1.0733 '
        'L/s (DN32: 2.19 m/s in DN25) and s0_1 = curve(8) = 0.400 L/s '
        '(DN20), calibrated or not', () {
      const xs = [133.8, 366.2, 595.0];
      const rby = [153.2, 91.5, 177.5];
      expect(4 * 1.0733e-3 / (math.pi * 0.025 * 0.025), greaterThan(2.0));
      for (final cal in [false, true]) {
        final r = _size(_hotel(3, 5, xs: xs, rby: rby), cal: cal);
        expect(r.q('hm'), closeTo(_curve(30), 1e-9), reason: 'cal=$cal');
        expect(r.dn('hm'), 32, reason: 'cal=$cal');
        expect(r.q('s0_1'), closeTo(_curve(8), 1e-9), reason: 'cal=$cal');
        expect(r.dn('s0_1'), 20, reason: 'cal=$cal');
      }
    });

    test(
        'seeded property: a hotel with a circulator on every return riser '
        '(2-7 risers, random geometry, any leg variant, calibrated or not) '
        'never sizes a supply pipe below the open network', () {
      final rnd = math.Random(28);
      for (var trial = 0; trial < 30; trial++) {
        final n = 2 + rnd.nextInt(6);
        final f = 2 + rnd.nextInt(5);
        final xs = <double>[];
        var x = 100.0;
        for (var k = 0; k < n; k++) {
          x += 60 + rnd.nextDouble() * 240;
          xs.add(x);
        }
        final rby = [for (var k = 0; k < n; k++) 40 + rnd.nextDouble() * 160];
        final ret = const ['pump', 'pumpcv', 'cvpump'][rnd.nextInt(3)];
        final cal = rnd.nextBool();
        final why = 'trial=$trial n=$n f=$f ret=$ret cal=$cal';
        final r = _size(_hotel(n, f, ret: ret, xs: xs, rby: rby),
            cal: cal, floors: f);
        final open =
            _size(_hotel(n, f, open: true, xs: xs), cal: cal, floors: f);
        for (final id in _supplyIds(n, f)) {
          expect(r.q(id), greaterThanOrEqualTo(open.q(id) - 1e-9),
              reason: '$why $id');
          expect(r.dn(id), greaterThanOrEqualTo(open.dn(id)),
              reason: '$why $id');
        }
      }
    });
  });

  test(
      '2 — classification is not quadratic: 30 risers x 10 floors with a '
      'return check valve per riser sizes within 5x the valveless drawing '
      '(was 1.2-1.7 s against ~40 ms)', () {
    final cv = _hotel(30, 10, ret: 'cv');
    final plain = _hotel(30, 10, ret: 'none');
    int once(Network net) {
      final sw = Stopwatch()..start();
      _size(net, floors: 10);
      return sw.elapsedMilliseconds;
    }

    _size(cv, floors: 10); // warm-up (JIT)
    _size(plain, floors: 10);
    // Interleaved best-of-5 (the suite runs files in parallel, so a single
    // timing can land on a busy core); the margin stays far below the old
    // quadratic cost (> 1 s).
    var tCv = 1 << 30, tPlain = 1 << 30;
    for (var i = 0; i < 5; i++) {
      tCv = math.min(tCv, once(cv));
      tPlain = math.min(tPlain, once(plain));
    }
    expect(tCv, lessThan(5 * tPlain + 150),
        reason: 'valved $tCv ms vs valveless $tPlain ms');
  });

  group('3 — a valveless duty/standby pump set', () {
    /// Cold water: GT -> P_i -> [C_i ->] HDR for i = 1..[pumps], HDR ->
    /// 4-floor riser with a 4-UBAP fixture per floor.
    Network pumpSet({bool valves = false, int pumps = 2}) {
      const s = ServiceType.coldWater;
      final nodes = <NetNode>[
        _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('HDR', 100, 0),
      ];
      final edges = <NetEdge>[];
      for (var i = 1; i <= pumps; i++) {
        nodes.add(_n('P$i', 50, 20.0 * i,
            role: NodeRole.plant, c: NodeComponent.pump));
        edges.add(_e('h$i', 'GT', 'P$i', s: s));
        if (valves) {
          nodes.add(_n('C$i', 75, 20.0 * i, c: NodeComponent.checkValve));
          edges
            ..add(_e('p$i', 'P$i', 'C$i', s: s))
            ..add(_e('c$i', 'C$i', 'HDR', s: s));
        } else {
          edges.add(_e('p$i', 'P$i', 'HDR', s: s));
        }
      }
      for (var f = 0; f < 4; f++) {
        nodes
          ..add(_n('S$f', 150, 0, floor: f))
          ..add(_n('fx$f', 190, 0, floor: f, role: NodeRole.fixture));
        edges.add(_e('b$f', 'S$f', 'fx$f', s: s));
        edges.add(f == 0
            ? _e('m', 'HDR', 'S0', s: s)
            : _e('s$f', 'S${f - 1}', 'S$f', k: EdgeKind.riser, s: s));
      }
      return Network(nodes: nodes, edges: edges);
    }

    test(
        'every leg carries the full set flow curve(16) = 0.6533 L/s at DN25 '
        '(DN20: 4Q/(pi D^2) = 2.08 m/s > 2.0), exactly as with check valves; '
        'the standby legs are recorded as mirrored legs (was 0.3267 L/s DN15 '
        'each)', () {
      expect(_curve(16), closeTo(0.6533, 1e-4));
      expect(4 * 0.6533e-3 / (math.pi * 0.02 * 0.02), greaterThan(2.0));
      for (final pumps in [2, 3]) {
        for (final cal in [false, true]) {
          final why = 'pumps=$pumps cal=$cal';
          final r = _size(pumpSet(pumps: pumps),
              cal: cal, floors: 4, service: ServiceType.coldWater, ubap: 4);
          final v = _size(pumpSet(pumps: pumps, valves: true),
              cal: cal, floors: 4, service: ServiceType.coldWater, ubap: 4);
          for (var i = 1; i <= pumps; i++) {
            for (final id in ['h$i', 'p$i']) {
              expect(r.q(id), closeTo(_curve(16), 1e-9), reason: '$why $id');
              expect(r.dn(id), 25, reason: '$why $id');
              expect(r.q(id), closeTo(v.q(id), 1e-9), reason: '$why $id');
            }
            expect(r.from('h$i'), 'GT', reason: why);
            expect(r.from('p$i'), 'P$i', reason: why);
          }
          expect(r.q('m'), closeTo(_curve(16), 1e-9), reason: why);
          expect(
              r.par,
              {
                for (var i = 2; i <= pumps; i++) ...['h$i', 'p$i'],
              },
              reason: why);
        }
      }
    });
  });

  test(
      '4 — a circulator on the heater discharge + a valveless return: the '
      'supply main carries curve(8) = 0.400 L/s at DN20 (2.26 m/s in DN15) '
      '— the envelope of the return closed and the balanced ring (was '
      '0.2296 L/s DN15 fed partly up the return)', () {
    Network net({bool open = false}) {
      final nodes = <NetNode>[
        _n('H', 0, 0, role: NodeRole.plant),
        _n('P', 25, 0, role: NodeRole.plant, c: NodeComponent.pump),
        _n('HDR', 50, 0),
      ];
      final edges = <NetEdge>[_e('hp', 'H', 'P'), _e('ph', 'P', 'HDR')];
      for (var f = 0; f < 4; f++) {
        nodes
          ..add(_n('S$f', 100, 0, floor: f))
          ..add(_n('fx$f', 140, 0, floor: f, role: NodeRole.fixture));
        if (!open) nodes.add(_n('R$f', 60, 40, floor: f));
        edges.add(_e('b$f', 'S$f', 'fx$f'));
        edges.add(f == 0
            ? _e('m', 'HDR', 'S0')
            : _e('s$f', 'S${f - 1}', 'S$f', k: EdgeKind.riser));
        if (!open && f > 0) {
          edges.add(_e('r$f', 'R$f', 'R${f - 1}', k: EdgeKind.riser));
        }
      }
      if (!open) {
        edges
          ..add(_e('top', 'S3', 'R3'))
          ..add(_e('rh', 'R0', 'H'));
      }
      return Network(nodes: nodes, edges: edges);
    }

    expect(4 * 0.400e-3 / (math.pi * 0.015 * 0.015), greaterThan(2.0));
    for (final cal in [false, true]) {
      final r = _size(net(), cal: cal, floors: 4);
      final o = _size(net(open: true), cal: cal, floors: 4);
      for (final id in ['hp', 'ph', 'm', 's1', 's2', 's3']) {
        expect(r.q(id), greaterThanOrEqualTo(o.q(id) - 1e-9),
            reason: 'cal=$cal $id');
      }
      expect(r.q('m'), closeTo(_curve(8), 1e-9), reason: 'cal=$cal');
      expect(r.dn('m'), 20, reason: 'cal=$cal');
      expect(r.q('hp'), closeTo(_curve(8), 1e-9), reason: 'cal=$cal');
      // The return stays sized (scenario (b)), never dropped.
      expect(r.q('rh'), greaterThan(0), reason: 'cal=$cal');
    }
  });

  group('5 — per-riser circulators into a plain return chain', () {
    /// Heater H -> CVd -> M ([cvd]: 'amb' both pipes out of CVd, 'drawn'
    /// H -> CVd -> M, 'plain' a bare node); two 4-floor supply risers off M
    /// (2 UBAP per floor); each return riser R_k -> Pr_k (circulator drawn
    /// toward RJ) -> RJ, then a pump-free RJ -> K -> H.
    Network hotel(String cvd) {
      final nodes = <NetNode>[
        _n('H', 0, 0, role: NodeRole.plant),
        _n('M', 50, 0),
        _n('CVd', 25, 0, c: cvd == 'plain' ? null : NodeComponent.checkValve),
        _n('RJ', 30, 40),
        _n('K', 15, 20),
      ];
      final edges = <NetEdge>[
        if (cvd == 'amb') ...[
          _e('hm1', 'CVd', 'H'),
          _e('hm2', 'CVd', 'M'),
        ] else ...[
          _e('hm1', 'H', 'CVd'),
          _e('hm2', 'CVd', 'M'),
        ],
        _e('jk', 'RJ', 'K'),
        _e('kh', 'K', 'H'),
      ];
      for (var r = 0; r < 2; r++) {
        final x = 100.0 + 200 * r;
        for (var f = 0; f < 4; f++) {
          nodes
            ..add(_n('S${r}_$f', x, 0, floor: f))
            ..add(_n('fx${r}_$f', x + 40, 0, floor: f, role: NodeRole.fixture))
            ..add(_n('R${r}_$f', x + 20, 0, floor: f));
          edges.add(_e('b${r}_$f', 'S${r}_$f', 'fx${r}_$f'));
          edges.add(f == 0
              ? _e('m$r', 'M', 'S${r}_0')
              : _e('s${r}_$f', 'S${r}_${f - 1}', 'S${r}_$f',
                  k: EdgeKind.riser));
          if (f > 0) {
            edges.add(_e('r${r}_$f', 'R${r}_$f', 'R${r}_${f - 1}',
                k: EdgeKind.riser));
          }
        }
        nodes.add(
            _n('Pr$r', x, 40, role: NodeRole.plant, c: NodeComponent.pump));
        edges
          ..add(_e('top$r', 'S${r}_3', 'R${r}_3'))
          ..add(_e('rp$r', 'R${r}_0', 'Pr$r'))
          ..add(_e('pj$r', 'Pr$r', 'RJ'));
      }
      return Network(nodes: nodes, edges: edges);
    }

    test(
        'the ambiguous heater discharge CVd is a FEED: hm1 = curve(16) = '
        '0.6533 L/s DN25 and each riser main curve(8) = 0.400 L/s DN20 — '
        'identical to CVd drawn or a bare node (was a closed return: hm1 0 '
        'DN15, the building fed backwards up the circulators)', () {
      for (final cal in [false, true]) {
        final amb = _size(hotel('amb'), cal: cal, floors: 4);
        final drawn = _size(hotel('drawn'), cal: cal, floors: 4);
        final plain = _size(hotel('plain'), cal: cal, floors: 4);
        expect(amb.amb, {'CVd': CheckValveAmbiguity.supplyLeg},
            reason: 'cal=$cal');
        expect(amb.q('hm1'), closeTo(_curve(16), 1e-9), reason: 'cal=$cal');
        expect(amb.dn('hm1'), 25, reason: 'cal=$cal');
        expect(amb.from('hm1'), 'H', reason: 'cal=$cal');
        for (final k in [0, 1]) {
          expect(amb.q('m$k'), closeTo(_curve(8), 1e-9),
              reason: 'cal=$cal m$k');
          expect(amb.dn('m$k'), 20, reason: 'cal=$cal m$k');
        }
        for (final id in amb.s.keys) {
          expect(amb.q(id), closeTo(drawn.q(id), 1e-9),
              reason: 'cal=$cal $id (drawn)');
          expect(amb.q(id), closeTo(plain.q(id), 1e-9),
              reason: 'cal=$cal $id (plain)');
        }
      }
    });
  });

  group('6 — fire systems', () {
    /// Two independent towers: GT_t -> FP_t -> an 8-storey hydrant stack.
    Network towers() {
      const s = ServiceType.fireHydrant;
      final nodes = <NetNode>[];
      final edges = <NetEdge>[];
      for (var t = 0; t < 2; t++) {
        final x = 1000.0 * t;
        nodes
          ..add(_n('GT$t', x, 0,
              role: NodeRole.plant, c: NodeComponent.groundTank))
          ..add(_n('FP$t', x + 20, 0,
              role: NodeRole.plant, c: NodeComponent.pump));
        edges
          ..add(_e('g$t', 'GT$t', 'FP$t', s: s))
          ..add(_e('h$t', 'FP$t', 'S${t}_0', s: s));
        for (var f = 0; f < 8; f++) {
          nodes
            ..add(_n('S${t}_$f', x + 50, 0, floor: f))
            ..add(_n('HB${t}_$f', x + 80, 0,
                floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
          edges.add(_e('b${t}_$f', 'S${t}_$f', 'HB${t}_$f', s: s));
          if (f > 0) {
            edges.add(_e('r${t}_$f', 'S${t}_${f - 1}', 'S${t}_$f',
                s: s, k: EdgeKind.riser));
          }
        }
      }
      return Network(nodes: nodes, edges: edges);
    }

    test(
        'two independent single-stack towers are two 500 gpm systems: '
        'drawnStandpipeRiserCount 1 (was 2 -> 750 gpm), each system 1 stack, '
        'standpipeFlow(1) = 1893 L/min = 31.55 L/s', () {
      final net = towers();
      final systems = fireSystems(net);
      expect(systems, hasLength(2));
      for (final s in systems) {
        expect(s.hasHydrant, isTrue);
        expect(s.standpipeRisers(net), 1);
      }
      expect(drawnStandpipeRiserCount(net), 1);
      expect(standpipeFlow(1).inLitersPerSecond, closeTo(1892.7 / 60, 0.05));
    });

    test(
        'index-path friction is the Hazen-Williams loss of the sized pipes '
        'from the pump to the worst terminal (C 120); null when a flowing '
        'pipe is unmeasured', () {
      const s = ServiceType.fireSprinkler;
      final net = Network(nodes: [
        _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('SP', 10, 0, role: NodeRole.plant, c: NodeComponent.pump),
        _n('A', 20, 0),
        _n('H1', 30, 0, role: NodeRole.fixture, c: NodeComponent.sprinklerHead),
        _n('H2', 20, 10,
            role: NodeRole.fixture, c: NodeComponent.sprinklerHead),
      ], edges: [
        _e('g', 'GT', 'SP', s: s),
        _e('a', 'SP', 'A', s: s),
        _e('b', 'A', 'H1', s: s),
        _e('c', 'A', 'H2', s: s),
      ]);
      EdgeSizing es(String id, double lps, double mm) => EdgeSizing(
            edgeId: id,
            service: s,
            flow: FlowRate.litersPerSecond(lps),
            diameter: Diameter.mm(mm),
            velocity: const Velocity(0),
          );
      final sizing = {
        'g': es('g', 4.714, 50),
        'a': es('a', 4.714, 32),
        'b': es('b', 2.0, 25),
        'c': es('c', 1.0, 25),
      };
      final lengths = {'g': 2.0, 'a': 4.0, 'b': 3.0, 'c': 3.0};
      final sys = fireSystems(net).single;
      final f = fireIndexPathFrictionM(
        net: net,
        system: sys,
        pumpId: 'SP',
        sizing: sizing,
        lengthOf: (e) => lengths[e.id]!,
      );
      double hw(double lps, double mm, double l) =>
          10.67 *
          l *
          math.pow(lps / 1000, 1.852) /
          (math.pow(120, 1.852) * math.pow(mm / 1000, 4.8704));
      // The worst terminal is H1: a (4 m DN32 at 4.714 L/s) + b (3 m DN25 at
      // 2.0 L/s); H2's branch carries half the flow.
      final want = hw(4.714, 32, 4) + hw(2.0, 25, 3);
      expect(f, closeTo(want, 1e-9));
      // The DN32 riser alone: ~5.6 m over 4 m (1.41 m/m at 5.86 m/s).
      expect(hw(4.714, 32, 4), closeTo(5.64, 0.05));
      expect(
          headLossHazenWilliams(
            flow: FlowRate.litersPerSecond(4.714),
            length: const Length(4),
            diameter: Diameter.mm(32),
            hazenWilliamsC: 120,
          ).meters,
          closeTo(hw(4.714, 32, 4), 1e-6));
      // An unmeasured flowing pipe: the friction is unknown.
      expect(
          fireIndexPathFrictionM(
            net: net,
            system: sys,
            pumpId: 'SP',
            sizing: sizing,
            lengthOf: (e) => e.id == 'b' ? 0 : lengths[e.id]!,
          ),
          isNull);
    });

    test(
        'the rated head takes the LARGER of the 15 m allowance and the sized '
        'index friction (never lower than before)', () {
      final small = designStandpipe(
          risers: 1,
          buildingHeight: const Length(30),
          indexPathFriction: const Head(4));
      final base = designStandpipe(risers: 1, buildingHeight: const Length(30));
      expect(small.pumpHead.meters, closeTo(base.pumpHead.meters, 1e-12));
      final big = designStandpipe(
          risers: 1,
          buildingHeight: const Length(30),
          indexPathFriction: const Head(60));
      expect(big.pumpHead.meters - base.pumpHead.meters, closeTo(45, 1e-9));

      final remote = remoteAreaHydraulics(
          design: designSprinklerSystem(hazard: FireHazardClass.lightHazard),
          kFactor: kDefaultPendentKFactor);
      final a = sprinklerPumpRatedPoint(remote: remote, staticLiftM: 31.6);
      final b = sprinklerPumpRatedPoint(
          remote: remote, staticLiftM: 31.6, indexPathFriction: const Head(97));
      const rhoG = 1000 * 9.81;
      expect(b.head.meters,
          closeTo(31.6 + remote.remoteHeadPressure.pascals / rhoG + 97, 1e-9));
      expect(b.head.meters, greaterThan(a.head.meters));
      final c = sprinklerPumpRatedPoint(
          remote: remote, staticLiftM: 31.6, indexPathFriction: const Head(1));
      expect(c.head.meters, closeTo(a.head.meters, 1e-12));
    });
  });
}
