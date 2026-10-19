/// Round 27 — check-valve classification on the hotel recirculation:
///
/// * regression-mixed-discharge-and-return-cv — a DISCHARGE valve on the
///   heater outlet (H -> CVd -> M) beside the common RETURN valve (RJ -> CV
///   -> H). Cutting both isolated the root, the return valve read as a second
///   parallel discharge, and Hardy–Cross pushed half the peak forward through
///   the return valve (heater feed DN15 instead of DN25).
/// * residuals-0 — the return valve drawn heater-outward (H -> CV -> RJ).
///   Round 27 r3 (binding design decision): the drawn direction is
///   authoritative, so it is read AS DRAWN (a feed) and the hot-water
///   `check-valve-feeds-ring` advisory names it; each valve is classified on
///   its own (only itself removed): permitted direction toward the source =>
///   a zeroed return, else a feed that is never zeroed.
/// * residuals-4 — a hotel return teed at the inline top fixture left the
///   supply-riser / return-riser ring in Hardy–Cross; the far riser base sized
///   one DN small.
///
/// The reference for every case is the engine's own open network (no return
/// drawn): a return check valve carries no draw-off (the Round-12 principle).
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
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

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: ServiceType.hotWater, kind: k);

/// Heater H -> M -> [risers] supply risers of 4 floors with a 2-UBAP fixture
/// on each floor. [ret]: each riser top runs down a return riser to RJ, then
/// RJ -> CV -> H ([reversedReturn] draws the valve legs H -> CV -> RJ).
/// [discharge] replaces the plain H -> M pipe by H -> CVd -> M (ids hm1 /
/// hm2). [fixtureTee] tees each return top from the top fixture instead of
/// the riser top. [cvdId] / [cvId] rename the valves (id-order metamorphic).
Network _hotel({
  int risers = 2,
  bool ret = true,
  bool discharge = false,
  bool reversedReturn = false,
  bool fixtureTee = false,
  String cvdId = 'CVd',
  String cvId = 'CV',
}) {
  final nodes = <NetNode>[
    _n('H', 0, 0, role: NodeRole.plant),
    _n('M', 50, 0),
  ];
  final edges = <NetEdge>[];
  if (discharge) {
    nodes.add(_n(cvdId, 25, 0, c: NodeComponent.checkValve));
    edges
      ..add(_e('hm1', 'H', cvdId))
      ..add(_e('hm2', cvdId, 'M'));
  } else {
    edges.add(_e('hm', 'H', 'M'));
  }
  for (var r = 0; r < risers; r++) {
    final x = 100.0 + 200 * r;
    for (var f = 0; f < 4; f++) {
      nodes
        ..add(_n('S${r}_$f', x, 0, floor: f))
        ..add(_n('fx${r}_$f', x + 40, 0, floor: f, role: NodeRole.fixture));
      edges
        ..add(_e('b${r}_$f', 'S${r}_$f', 'fx${r}_$f'))
        ..add(f == 0
            ? _e('m$r', 'M', 'S${r}_0')
            : _e('s${r}_$f', 'S${r}_${f - 1}', 'S${r}_$f', k: EdgeKind.riser));
    }
    if (ret) {
      for (var f = 0; f < 4; f++) {
        nodes.add(_n('R${r}_$f', x + 20, 0, floor: f));
      }
      edges.add(_e('top$r', fixtureTee ? 'fx${r}_3' : 'S${r}_3', 'R${r}_3'));
      for (var f = 3; f >= 1; f--) {
        edges.add(
            _e('r${r}_$f', 'R${r}_$f', 'R${r}_${f - 1}', k: EdgeKind.riser));
      }
      edges.add(_e('rj$r', 'R${r}_0', 'RJ'));
    }
  }
  if (ret) {
    nodes
      ..add(_n('RJ', 30, 0))
      ..add(_n(cvId, 10, 0, c: NodeComponent.checkValve));
    edges.addAll(reversedReturn
        ? [_e('ch', 'H', cvId), _e('jc', cvId, 'RJ')]
        : [_e('jc', 'RJ', cvId), _e('ch', cvId, 'H')]);
  }
  return Network(nodes: nodes, edges: edges);
}

const _levels = BuildingLevels([
  Floor('L1', Length(3.0)),
  Floor('L2', Length(3.0)),
  Floor('L3', Length(3.0)),
  Floor('L4', Length(3.0)),
]);

Map<String, EdgeSizing> _size(Network net, {bool cal = false}) =>
    autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {ServiceType.hotWater: FlowRate(0)},
      leafFixtureUnits: const {ServiceType.hotWater: 2.0},
      building: cal
          ? const BuildingLevels([
              Floor('L1', Length(3.0)),
              Floor('L2', Length(3.0)),
              Floor('L3', Length(3.0)),
              Floor('L4', Length(3.0)),
            ])
          : null,
      calibrationBySheet: cal ? const {'s1': ScaleCalibration(0.05)} : const {},
    );

const _sni = SniProfile();
double _curve(double ubap) =>
    _sni.probableFlowForFixtureUnits(ubap).inLitersPerSecond;

void main() {
  test('first principles: the reference flows', () {
    // Flush-tank Gambar 1: 10..20 UBAP and 0..10 UBAP segments. A riser base
    // carries 4 floors x 2 UBAP = 8 UBAP -> 8/10 x 0.5 = 0.400 L/s; the
    // heater feed 2 x 8 = 16 UBAP. DN15 at 0.4 L/s is v = 4Q/(pi D^2) =
    // 2.26 m/s, over the 2.0 m/s cap, so a riser base must be DN20.
    expect(_curve(8), closeTo(0.400, 1e-12));
    expect(4 * 0.400e-3 / (math.pi * 0.015 * 0.015), greaterThan(2.0));
    final open = _size(_hotel(ret: false));
    expect(open['hm']!.flow.inLitersPerSecond, closeTo(_curve(16), 1e-9));
    expect(open['m0']!.flow.inLitersPerSecond, closeTo(_curve(8), 1e-9));
    expect(open['hm']!.diameter.inMillimeters, 25);
    expect(open['m0']!.diameter.inMillimeters, 20);
  });

  test(
      'regression: a discharge CV on the heater outlet + the return CV — the '
      'feed is curve(16) DN25, riser bases curve(8) DN20, the return 0', () {
    for (final cal in [false, true]) {
      final open = _size(_hotel(ret: false, discharge: true), cal: cal);
      for (final ids in [
        ('CVd', 'CV'),
        ('CV', 'CVd'),
        ('A', 'Z'),
        ('Z', 'A')
      ]) {
        final s = _size(_hotel(discharge: true, cvdId: ids.$1, cvId: ids.$2),
            cal: cal);
        final why = 'cal=$cal ids=$ids';
        for (final id in ['hm1', 'hm2']) {
          expect(s[id]!.flow.inLitersPerSecond, closeTo(_curve(16), 1e-9),
              reason: '$why $id');
          expect(s[id]!.diameter.inMillimeters, 25, reason: '$why $id');
        }
        for (final id in ['m0', 'm1']) {
          expect(s[id]!.flow.inLitersPerSecond, closeTo(_curve(8), 1e-9),
              reason: '$why $id');
          expect(s[id]!.diameter.inMillimeters, 20, reason: '$why $id');
        }
        // The whole supply sizes exactly as with no return drawn.
        for (final id in open.keys) {
          expect(s[id]!.flow.inLitersPerSecond,
              closeTo(open[id]!.flow.inLitersPerSecond, 1e-9),
              reason: '$why $id');
        }
        for (final id in ['ch', 'jc', 'rj0', 'rj1', 'top0', 'top1', 'r0_1']) {
          expect(s[id]!.flow.inLitersPerSecond, closeTo(0, 1e-12),
              reason: '$why $id');
        }
        // The return valve is oriented RJ -> CV -> H (its pass direction).
        expect(s['jc']!.flowFromId, 'RJ', reason: why);
        expect(s['ch']!.flowFromId, ids.$2, reason: why);
      }
    }
  });

  test(
      'r3 (binding decision): a return CV drawn heater-outward (H -> CV -> '
      'RJ) is read AS DRAWN — a feed that flows, plus the hot-water advisory',
      () {
    // The drawn arrow H -> RJ is unambiguous and, with only CV removed, RJ
    // is FARTHER from the heater (via the supply risers) than H itself: the
    // permitted direction points away from the root => a FEED, a plain pipe
    // of the ring. The water then reaches the fixtures both ways round, so
    // the heater delivers curve(16) through hm + ch together (continuity at
    // the root — the ring splits ONE diversified flow) and ch flows WITH its
    // valve. Topology alone cannot tell this from a genuine second feed, so
    // the engine flags it (check-valve-feeds-ring) instead of re-reading it.
    for (final cal in [false, true]) {
      for (final discharge in [false, true]) {
        final ring = <String>{};
        final s = autoSizeNetwork(
          _hotel(reversedReturn: true, discharge: discharge),
          const SizingContext(),
          leafDemand: const {ServiceType.hotWater: FlowRate(0)},
          leafFixtureUnits: const {ServiceType.hotWater: 2.0},
          building: cal ? _levels : null,
          calibrationBySheet:
              cal ? const {'s1': ScaleCalibration(0.05)} : const {},
          checkValveFeedsRingOut: ring,
        );
        final why = 'cal=$cal discharge=$discharge';
        final trunk = discharge ? 'hm1' : 'hm';
        expect(
            s[trunk]!.flow.inLitersPerSecond + s['ch']!.flow.inLitersPerSecond,
            closeTo(_curve(16), 1e-9),
            reason: why);
        expect(s['ch']!.flow.inLitersPerSecond, greaterThan(0), reason: why);
        expect(s['ch']!.flowFromId, 'H', reason: why);
        expect(s['jc']!.flowFromId, 'CV', reason: why);
        // Round 27 r5 — only the backwards return is named: the heater's own
        // discharge valve CVd (on the shortest heater -> draw-off route) is
        // correctly drawn, so the "arrow drawn backwards" message is not
        // about it.
        expect(ring, {'CV'}, reason: why);
      }
    }
  });

  test('r3: the correctly drawn hotel return raises no feed advisory', () {
    for (final discharge in [false, true]) {
      final ring = <String>{};
      autoSizeNetwork(
        _hotel(discharge: discharge),
        const SizingContext(),
        leafDemand: const {ServiceType.hotWater: FlowRate(0)},
        leafFixtureUnits: const {ServiceType.hotWater: 2.0},
        checkValveFeedsRingOut: ring,
      );
      // CVd closed + the return valve closed isolates the heater: no other
      // feed path, so the heater discharge valve is not flagged either.
      expect(ring, isEmpty, reason: 'discharge=$discharge');
    }
  });

  test(
      'r3: an AMBIGUOUSLY drawn return valve (both pipes into it) keeps the '
      'Round-15 topological reading — a return, supply == open network', () {
    // RJ -> CV and H -> CV: no drawn direction. With every cycle valve cut
    // both sides are reached; the valve lies on no shortest root -> draw-off
    // path, so its FARTHER side (RJ) is the inlet => RJ -> CV -> H, a
    // return toward the heater => zero draw-off.
    final base = _hotel();
    final net = Network(nodes: base.nodes, edges: [
      for (final e in base.edges)
        if (e.id == 'ch') _e('ch', 'H', 'CV') else e,
    ]);
    final s = _size(net);
    final open = _size(_hotel(ret: false));
    for (final id in open.keys) {
      expect(s[id]!.flow.inLitersPerSecond,
          closeTo(open[id]!.flow.inLitersPerSecond, 1e-9),
          reason: id);
    }
    expect(s['ch']!.flow.inLitersPerSecond, 0);
    expect(s['jc']!.flow.inLitersPerSecond, 0);
    expect(s['jc']!.flowFromId, 'RJ');
  });

  test(
      'r4 regression: an AMBIGUOUS return valve beside a heater DISCHARGE '
      'valve is read with only itself removed — a return, supply == open '
      'network, no feeds-ring advisory', () {
    // H -> CVd -> M plus RJ -> CV and H -> CV (no drawn direction). r3 read
    // rule 3 with EVERY cycle valve cut: CVd's cut isolated H, the only
    // reached side of CV was H itself, so CV read H -> CV -> RJ (a FEED) and
    // Hardy–Cross pushed draw-off forward through it (heater feed 0.3237 L/s
    // instead of curve(16) = 0.6533 L/s). With only CV removed (CVd a plain
    // pipe) both sides are reached; CV shortens no root -> draw-off path (via
    // CV every fixture is reached up the RETURN riser, strictly farther), so
    // its FARTHER side RJ is the inlet: RJ -> CV -> H, a return with zero
    // draw-off. [tee]: the returns teed at the top fixture, which is then
    // reached as far through CV as up the supply riser (7 hops each way):
    // CV shortens no path (it only ties one), so it reads the same way.
    for (final (risers, tee) in [
      (2, false),
      (3, false),
      (2, true),
      (3, true)
    ]) {
      for (final cal in [false, true]) {
        final base = _hotel(risers: risers, discharge: true, fixtureTee: tee);
        final net = Network(nodes: base.nodes, edges: [
          for (final e in base.edges)
            if (e.id == 'ch') _e('ch', 'H', 'CV') else e,
        ]);
        final ring = <String>{};
        final s = autoSizeNetwork(
          net,
          const SizingContext(),
          leafDemand: const {ServiceType.hotWater: FlowRate(0)},
          leafFixtureUnits: const {ServiceType.hotWater: 2.0},
          building: cal ? _levels : null,
          calibrationBySheet:
              cal ? const {'s1': ScaleCalibration(0.05)} : const {},
          checkValveFeedsRingOut: ring,
        );
        final open = _size(_hotel(risers: risers, ret: false, discharge: true),
            cal: cal);
        final why = 'risers=$risers tee=$tee cal=$cal';
        for (final id in ['hm1', 'hm2']) {
          expect(s[id]!.flow.inLitersPerSecond,
              closeTo(_curve(8.0 * risers), 1e-9),
              reason: '$why $id');
        }
        for (var r = 0; r < risers; r++) {
          expect(s['m$r']!.flow.inLitersPerSecond, closeTo(_curve(8), 1e-9),
              reason: '$why m$r');
          expect(s['m$r']!.diameter.inMillimeters, 20, reason: '$why m$r');
        }
        for (final id in open.keys) {
          expect(s[id]!.flow.inLitersPerSecond,
              closeTo(open[id]!.flow.inLitersPerSecond, 1e-9),
              reason: '$why $id');
        }
        expect(s['ch']!.flow.inLitersPerSecond, 0, reason: why);
        expect(s['jc']!.flow.inLitersPerSecond, 0, reason: why);
        expect(s['jc']!.flowFromId, 'RJ', reason: why);
        expect(s['ch']!.flowFromId, 'CV', reason: why);
        // Neither the return valve nor the heater's own discharge valve is a
        // "second feed into a ring".
        expect(ring, isEmpty, reason: why);
      }
    }
  });

  /// One supply riser H -> S0..S3 (2-UBAP fixture per floor) with a return
  /// valve at the TOP of the return riser: S3 -> CV -> R3 -> R2 -> R1 -> R0
  /// -> H. [bends] routes R0 -> K0 -> K1 -> K2 -> H.
  Network topReturn({bool bends = false}) {
    final nodes = <NetNode>[_n('H', 0, 0, role: NodeRole.plant)];
    final edges = <NetEdge>[];
    for (var f = 0; f < 4; f++) {
      nodes
        ..add(_n('S$f', 100, 0, floor: f))
        ..add(_n('fx$f', 140, 0, floor: f, role: NodeRole.fixture))
        ..add(_n('R$f', 120, 0, floor: f));
      edges.add(_e('b$f', 'S$f', 'fx$f'));
      edges.add(f == 0
          ? _e('m', 'H', 'S0')
          : _e('s$f', 'S${f - 1}', 'S$f', k: EdgeKind.riser));
      if (f > 0) edges.add(_e('r$f', 'R$f', 'R${f - 1}', k: EdgeKind.riser));
    }
    nodes.add(_n('CV', 110, 0, floor: 3, c: NodeComponent.checkValve));
    edges
      ..add(_e('sc', 'S3', 'CV'))
      ..add(_e('cr', 'CV', 'R3'));
    if (bends) {
      nodes
        ..add(_n('K0', 90, 0))
        ..add(_n('K1', 60, 0))
        ..add(_n('K2', 30, 0));
      edges
        ..add(_e('k0', 'R0', 'K0'))
        ..add(_e('k1', 'K0', 'K1'))
        ..add(_e('k2', 'K1', 'K2'))
        ..add(_e('rh', 'K2', 'H'));
    } else {
      edges.add(_e('rh', 'R0', 'H'));
    }
    return Network(nodes: nodes, edges: edges);
  }

  test(
      'r4 regression: a return valve at the TOP of the return riser — a feed '
      'the balance CLOSES is output exactly like a return: every return pipe '
      'sized at zero (DN15, fu 0) calibrated or not, no feeds-ring advisory',
      () {
    // Rule 2 reads the valve on distances with only itself removed:
    // calibrated (0.05 m/px, 3 m floors) S3 is 11 m from H and R3 13 m, and
    // uncalibrated the hops tie (4 / 4) — either way a FEED, which the
    // Hardy–Cross balance then CLOSES (the split would run against it). A
    // closed valve carries no draw-off: the supply riser carries the open
    // network's flows — m = 4 x 2 = 8 UBAP => curve(8) = 0.400 L/s (DN20),
    // s1 / s2 / s3 curve(6) / curve(4) / curve(2) — and the return pipes
    // behind it are pipework the installer buys: present, zero flow, the DN15
    // minimum, fixture units 0, oriented in the valve's permitted direction
    // (away from it on its outlet side). r3 dropped them from the result (an
    // exactly-zero balanced edge stays unsized) and named the valve "a second
    // feed that carries draw-off".
    for (final bends in [false, true]) {
      final returnIds = [
        'sc',
        'cr',
        'r3',
        'r2',
        'r1',
        if (bends) ...['k0', 'k1', 'k2'],
        'rh',
      ];
      final from = <bool, Map<String, String?>>{};
      for (final cal in [false, true]) {
        final ring = <String>{};
        final fu = <String, double>{};
        final s = autoSizeNetwork(
          topReturn(bends: bends),
          const SizingContext(),
          leafDemand: const {ServiceType.hotWater: FlowRate(0)},
          leafFixtureUnits: const {ServiceType.hotWater: 2.0},
          building: cal ? _levels : null,
          calibrationBySheet:
              cal ? const {'s1': ScaleCalibration(0.05)} : const {},
          checkValveFeedsRingOut: ring,
          fixtureUnitsOut: fu,
        );
        final why = 'bends=$bends cal=$cal';
        expect(s['m']!.flow.inLitersPerSecond, closeTo(_curve(8), 1e-9),
            reason: why);
        expect(s['m']!.diameter.inMillimeters, 20, reason: why);
        for (final (id, ubap) in [('s1', 6.0), ('s2', 4.0), ('s3', 2.0)]) {
          expect(s[id]!.flow.inLitersPerSecond, closeTo(_curve(ubap), 1e-9),
              reason: '$why $id');
        }
        for (final id in returnIds) {
          expect(s[id], isNotNull, reason: '$why $id');
          expect(s[id]!.flow.inLitersPerSecond, 0, reason: '$why $id');
          expect(s[id]!.diameter.inMillimeters, 15, reason: '$why $id');
          expect(fu[id], 0, reason: '$why $id');
        }
        expect(s['sc']!.flowFromId, 'S3', reason: why);
        expect(s['cr']!.flowFromId, 'CV', reason: why);
        expect(s['r3']!.flowFromId, 'R3', reason: why);
        expect(s['rh']!.flowFromId, bends ? 'K2' : 'R0', reason: why);
        expect(ring, isEmpty, reason: why);
        from[cal] = {for (final id in returnIds) id: s[id]!.flowFromId};
      }
      // Calibration never changes what the drawing outputs.
      expect(from[true], from[false], reason: 'bends=$bends');
    }
  });

  test(
      'documented residual (inherent to the binding rule): a genuine second '
      'feed whose leg is LONGER than the ring route to its entry reads as a '
      'return — zeroed, but its leg is sized at zero, never left unsized', () {
    // T -> M -> J1; ring J1 - A - B - J2 - J1; long leg M -> X -> Y -> Z ->
    // CV2 -> J2. With only CV2 removed J2 is 3 hops from T (via J1) and Z 4,
    // so CV2's drawn direction points TOWARD the source => a RETURN (rule
    // 2). Topology alone cannot tell this from a recirculation return: the
    // whole curve(8) = 0.400 L/s enters by m1 (plain pipes would split it
    // 0.1424 / 0.0576). Recorded in CLAUDE.md / §15; the zero leg is still
    // pipework, so x1..x3 are sized at zero (DN15, fu 0).
    NetEdge e(String id, String a, String b) =>
        NetEdge(id: id, fromId: a, toId: b, service: ServiceType.coldWater);
    final net = Network(nodes: [
      _n('T', 0, 0, role: NodeRole.plant),
      _n('M', 20, 0),
      _n('J1', 40, 0),
      _n('A', 60, -20),
      _n('B', 80, -20),
      _n('J2', 40, 20),
      _n('fA', 60, -40, role: NodeRole.fixture),
      _n('fB', 80, -40, role: NodeRole.fixture),
      _n('X', 20, 40),
      _n('Y', 20, 60),
      _n('Z', 30, 60),
      _n('CV2', 40, 40, c: NodeComponent.checkValve),
    ], edges: [
      e('tm', 'T', 'M'),
      e('m1', 'M', 'J1'),
      e('ja', 'J1', 'A'),
      e('ab', 'A', 'B'),
      e('bj', 'B', 'J2'),
      e('jj', 'J2', 'J1'),
      e('fa', 'A', 'fA'),
      e('fb', 'B', 'fB'),
      e('x1', 'M', 'X'),
      e('x2', 'X', 'Y'),
      e('x3', 'Y', 'Z'),
      e('zc', 'Z', 'CV2'),
      e('c2', 'CV2', 'J2'),
    ]);
    final fu = <String, double>{};
    final s = autoSizeNetwork(net, const SizingContext(),
        leafDemand: const {ServiceType.coldWater: FlowRate(0)},
        leafFixtureUnits: const {ServiceType.coldWater: 4.0},
        fixtureUnitsOut: fu);
    expect(s['m1']!.flow.inLitersPerSecond, closeTo(_curve(8), 1e-9));
    for (final id in ['x1', 'x2', 'x3', 'zc', 'c2']) {
      expect(s[id], isNotNull, reason: id);
      expect(s[id]!.flow.inLitersPerSecond, 0, reason: id);
      expect(s[id]!.diameter.inMillimeters, 15, reason: id);
      expect(fu[id], 0, reason: id);
    }
    expect(s['zc']!.flowFromId, 'Z');
    expect(s['c2']!.flowFromId, 'CV2');
  });

  test(
      'residuals-4: a common return teed at the inline top fixture — every '
      'riser base carries curve(8) DN20, the returns carry no draw-off', () {
    for (final risers in [2, 3]) {
      for (final cal in [false, true]) {
        final s = _size(_hotel(risers: risers, fixtureTee: true), cal: cal);
        final open = _size(_hotel(risers: risers, ret: false), cal: cal);
        final why = 'risers=$risers cal=$cal';
        expect(s['hm']!.flow.inLitersPerSecond,
            closeTo(_curve(8.0 * risers), 1e-9),
            reason: why);
        for (var r = 0; r < risers; r++) {
          expect(s['m$r']!.flow.inLitersPerSecond, closeTo(_curve(8), 1e-9),
              reason: '$why m$r');
          expect(s['m$r']!.diameter.inMillimeters, 20, reason: '$why m$r');
          for (final id in ['top$r', 'r${r}_3', 'r${r}_1', 'rj$r']) {
            expect(s[id]!.flow.inLitersPerSecond, closeTo(0, 1e-12),
                reason: '$why $id');
          }
        }
        for (final id in open.keys) {
          expect(s[id]!.flow.inLitersPerSecond,
              closeTo(open[id]!.flow.inLitersPerSecond, 1e-9),
              reason: '$why $id');
        }
      }
    }
  });

  /// A pumpless DUAL-FEED cold-water ring: T -> M; M -> CV1 -> J1 and
  /// M -> CV2 -> J2. [plain] draws the two valve nodes as bare junctions
  /// (the reference: a feed valve is a transparent pipe).
  Network dualFeed(List<(String, String, String)> ring,
      List<(String, double, double)> ringNodes, String e1, String e2,
      {bool plain = false, String cv1 = 'CV1', String cv2 = 'CV2'}) {
    NetEdge e(String id, String a, String b) =>
        NetEdge(id: id, fromId: a, toId: b, service: ServiceType.coldWater);
    return Network(nodes: [
      _n('T', 0, 0, role: NodeRole.plant),
      _n('M', 20, 0),
      _n(cv1, 40, -20, c: plain ? null : NodeComponent.checkValve),
      _n(cv2, 40, 20, c: plain ? null : NodeComponent.checkValve),
      for (final (id, x, y) in ringNodes)
        _n(id, x, y,
            role: id.startsWith('f') ? NodeRole.fixture : NodeRole.main),
    ], edges: [
      e('tm', 'T', 'M'),
      e('m1', 'M', cv1),
      e('c1', cv1, e1),
      e('m2', 'M', cv2),
      e('c2', cv2, e2),
      for (final (id, a, b) in ring) e(id, a, b),
    ]);
  }

  Map<String, EdgeSizing> sizeCold(Network net) =>
      autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {ServiceType.coldWater: FlowRate(0)},
          leafFixtureUnits: const {ServiceType.coldWater: 4.0});

  test(
      'r3 regression: a pumpless DUAL-FEED ring entered at two different '
      'nodes — both feeds flow WITH their valves, split exactly as the same '
      'ring with plain pipes (Hardy–Cross), never zeroed', () {
    // T -> M; header J1 - J2; fixture A one hop off J1, fixture B two hops
    // off J2 (via X), 4 UBAP each. Both valves are drawn M -> valve -> J,
    // and with only one removed its outlet J is farther from T than M: both
    // are FEEDS (rule 2), transparent pipes => the network sizes exactly as
    // with bare junctions in their place. The whole ring carries ONE
    // diversified flow, curve(8) = 8/10 x 0.5 = 0.400 L/s (flush-tank
    // Gambar 1), entering through m1 + m2.
    final ring = [
      ('hdr', 'J1', 'J2'),
      ('a', 'J1', 'fA'),
      ('x', 'J2', 'X'),
      ('b', 'X', 'fB'),
    ];
    final nodes = [
      ('J1', 60.0, -20.0),
      ('J2', 60.0, 20.0),
      ('X', 80.0, 20.0),
      ('fA', 80.0, -20.0),
      ('fB', 100.0, 20.0),
    ];
    final ref = sizeCold(dualFeed(ring, nodes, 'J1', 'J2', plain: true));
    for (final ids in [('CV1', 'CV2'), ('CV2', 'CV1')]) {
      final s =
          sizeCold(dualFeed(ring, nodes, 'J1', 'J2', cv1: ids.$1, cv2: ids.$2));
      expect(s['tm']!.flow.inLitersPerSecond, closeTo(_curve(8), 1e-9));
      expect(s['m1']!.flow.inLitersPerSecond + s['m2']!.flow.inLitersPerSecond,
          closeTo(_curve(8), 1e-9));
      for (final id in ref.keys) {
        expect(s[id]!.flow.inLitersPerSecond,
            closeTo(ref[id]!.flow.inLitersPerSecond, 1e-9),
            reason: '$ids $id');
      }
      for (final id in ['c1', 'c2', 'm1', 'm2']) {
        expect(s[id]!.flow.inLitersPerSecond, greaterThan(0),
            reason: '$ids $id');
      }
      expect(s['c1']!.flowFromId, ids.$1, reason: '$ids');
      expect(s['c2']!.flowFromId, ids.$2, reason: '$ids');
    }
  });

  test(
      'r3 regression (Fable probe): the second entry junction is a real tee '
      'FARTHER by hops from every draw-off — still a feed, never flipped', () {
    // M -> CV1 -> J1; M -> CV2 -> J2; ring J1 - A - B - N - J2 - P - J1 (N, P
    // bare bends), fixtures off A and B (4 UBAP each). From J2 the nearest
    // draw-off is three hops away (J2-N-B-fB) against two from J1: r2 read
    // CV2 as a return and zeroed it with its flow pointing back through the
    // valve. CV2's drawn direction M -> J2 points AWAY from T (with only CV2
    // removed J2 is reached via J1-P), so it is a feed: the ring sizes
    // exactly as with plain pipes and both feeds flow forward.
    final ring = [
      ('r1', 'J1', 'A'),
      ('r2', 'A', 'B'),
      ('r3', 'B', 'N'),
      ('r4', 'N', 'J2'),
      ('r5', 'J2', 'P'),
      ('r6', 'P', 'J1'),
      ('fa', 'A', 'fA'),
      ('fb', 'B', 'fB'),
    ];
    final nodes = [
      ('J1', 60.0, -20.0),
      ('A', 80.0, -40.0),
      ('B', 120.0, -40.0),
      ('N', 140.0, 0.0),
      ('J2', 60.0, 20.0),
      ('P', 40.0, 0.0),
      ('fA', 80.0, -60.0),
      ('fB', 120.0, -60.0),
    ];
    final ref = sizeCold(dualFeed(ring, nodes, 'J1', 'J2', plain: true));
    for (final ids in [('CV1', 'CV2'), ('CV2', 'CV1')]) {
      final s =
          sizeCold(dualFeed(ring, nodes, 'J1', 'J2', cv1: ids.$1, cv2: ids.$2));
      for (final id in ref.keys) {
        expect(s[id]!.flow.inLitersPerSecond,
            closeTo(ref[id]!.flow.inLitersPerSecond, 1e-9),
            reason: '$ids $id');
      }
      expect(s['m1']!.flow.inLitersPerSecond + s['m2']!.flow.inLitersPerSecond,
          closeTo(_curve(8), 1e-9));
      expect(s['m2']!.flow.inLitersPerSecond, greaterThan(0));
      expect(s['c2']!.flow.inLitersPerSecond, greaterThan(0));
      expect(s['c2']!.flowFromId, ids.$2, reason: '$ids');
      expect(s['c1']!.flowFromId, ids.$1, reason: '$ids');
      for (final id in ['r4', 'r5', 'r6']) {
        expect(s[id], isNotNull, reason: '$ids $id');
        expect(s[id]!.flowFromId, isNotNull, reason: '$ids $id');
      }
    }
  });

  test(
      'property: drawing direction, valve ids, edge order, riser count and '
      'tee placement never move the supply off the open network (seeded)', () {
    final rnd = math.Random(27);
    for (var trial = 0; trial < 40; trial++) {
      final n = 2 + rnd.nextInt(3);
      final discharge = rnd.nextBool();
      // Round 27 r3: a reversed (H -> CV -> RJ) return is read as drawn —
      // covered by its own test and the drawn-direction property below.
      const reversed = false;
      final tee = rnd.nextBool();
      final cal = rnd.nextBool();
      final ids = rnd.nextBool() ? ('CVd', 'CV') : ('CV', 'CVd');
      final net = _hotel(
          risers: n,
          discharge: discharge,
          reversedReturn: reversed,
          fixtureTee: tee,
          cvdId: ids.$1,
          cvId: ids.$2);
      final shuffled = Network(
          nodes: net.nodes,
          edges: [...net.edges]..shuffle(math.Random(500 + trial)));
      final s = _size(shuffled, cal: cal);
      final open =
          _size(_hotel(risers: n, ret: false, discharge: discharge), cal: cal);
      final why = 'trial $trial n=$n discharge=$discharge reversed=$reversed '
          'tee=$tee cal=$cal ids=$ids';
      for (final id in open.keys) {
        expect(s[id]!.flow.inLitersPerSecond,
            closeTo(open[id]!.flow.inLitersPerSecond, 1e-9),
            reason: '$why $id');
      }
      for (final id in ['ch', 'jc']) {
        expect(s[id]!.flow.inLitersPerSecond, closeTo(0, 1e-12),
            reason: '$why $id');
      }
    }
  });

  test(
      'r3 property (seeded): a valve whose DRAWN permitted direction points '
      'away from the source flows >= 0 its own way and is never zero-forced; '
      'one pointing toward the source carries exactly 0', () {
    var checkedReturns = 0, checkedFeeds = 0, skipped = 0;
    for (var trial = 0; trial < 300; trial++) {
      final rnd = math.Random(2700 + trial);
      final nodes = <NetNode>[
        _n('T', 0, 0, role: NodeRole.plant),
        _n('M', 20, 0),
      ];
      final edges = <NetEdge>[];
      var eid = 0;
      void pipe(String a, String b) => edges.add(NetEdge(
          id: 'e${eid++}', fromId: a, toId: b, service: ServiceType.coldWater));
      // valve id -> (in-node, out-node) as drawn; [leg] marks a feed leg.
      final valves = <String, (String, String)>{};
      final legValves = <String>{};
      var vid = 0;
      String valve(String a, String b, double x, double y, {bool leg = false}) {
        // Ids are random so id order never matters.
        final id = 'V${rnd.nextInt(1 << 20)}_${vid++}';
        nodes.add(_n(id, x, y, c: NodeComponent.checkValve));
        final forward = rnd.nextBool();
        final (i, o) = forward ? (a, b) : (b, a);
        pipe(i, id);
        pipe(id, o);
        valves[id] = (i, o);
        if (leg) legValves.add(id);
        return id;
      }

      pipe('T', 'M');
      final k = 4 + rnd.nextInt(4);
      var anyFixture = false;
      for (var i = 0; i < k; i++) {
        final a = 2 * math.pi * i / k;
        final (x, y) = (200 + 100 * math.cos(a), 100 * math.sin(a));
        nodes.add(_n('R$i', x, y));
        if (rnd.nextBool() || (i == k - 1 && !anyFixture)) {
          anyFixture = true;
          nodes.add(_n('f$i', x * 1.1, y * 1.1, role: NodeRole.fixture));
          pipe('R$i', 'f$i');
        }
      }
      final ringValveAt = rnd.nextDouble() < 0.4 ? rnd.nextInt(k) : -1;
      for (var i = 0; i < k; i++) {
        final j = (i + 1) % k;
        if (i == ringValveAt) {
          valve('R$i', 'R$j', 210, 10.0 * i);
        } else {
          rnd.nextBool() ? pipe('R$i', 'R$j') : pipe('R$j', 'R$i');
        }
      }
      final entries = ([for (var i = 0; i < k; i++) i]..shuffle(rnd))
          .take(1 + rnd.nextInt(2))
          .toList();
      for (final en in entries) {
        if (rnd.nextDouble() < 0.8) {
          valve('M', 'R$en', 60, 5.0 * en, leg: true);
        } else {
          pipe('M', 'R$en');
        }
      }
      final hasReturn = rnd.nextDouble() < 0.4;
      if (hasReturn) {
        final r = rnd.nextInt(k);
        nodes.add(_n('Q', 30, 80));
        pipe('R$r', 'Q');
        valve('Q', 'T', 10, 60);
      }
      final net =
          Network(nodes: nodes, edges: [...edges]..shuffle(math.Random(trial)));

      // Independent oracle: hop distances from T with only [blocked] gone.
      Map<String, int> hops(Set<String> blocked) {
        final d = <String, int>{'T': 0};
        final q = ['T'];
        for (var i = 0; i < q.length; i++) {
          for (final e in edges) {
            final n = q[i];
            final m = e.fromId == n ? e.toId : (e.toId == n ? e.fromId : null);
            if (m == null || blocked.contains(m) || d.containsKey(m)) continue;
            d[m] = d[n]! + 1;
            q.add(m);
          }
        }
        return d;
      }

      // Only CYCLE valves are classified (an off-cycle valve is a plain tree
      // edge): both ends reachable with the valve gone.
      final cycle = {
        for (final MapEntry(key: v, value: (i, o)) in valves.entries)
          if (hops({v}).containsKey(i) && hops({v}).containsKey(o)) v,
      };
      valves.removeWhere((v, _) => !cycle.contains(v));
      final towardRoot = <String>{
        for (final MapEntry(key: v, value: (i, o)) in valves.entries)
          if (() {
            final d = hops({v});
            return d[o]! < d[i]!;
          }())
            v,
      };
      // A drawing whose returns cut a fixture off the source is
      // self-contradictory (handled topologically) — outside this property.
      final dr = hops(towardRoot);
      if (nodes
          .any((n) => n.role == NodeRole.fixture && !dr.containsKey(n.id))) {
        skipped++;
        continue;
      }
      final s = sizeCold(net);
      EdgeSizing? sOf(String a, String b) {
        for (final e in edges) {
          if ((e.fromId == a && e.toId == b) ||
              (e.fromId == b && e.toId == a)) {
            return s[e.id];
          }
        }
        return null;
      }

      for (final MapEntry(key: v, value: (i, o)) in valves.entries) {
        // Round 27 r4 — every classified valve is sized, closed or open
        // (never silently left out of the result).
        final inS = sOf(i, v), outS = sOf(v, o);
        expect(inS, isNotNull, reason: 'trial $trial valve $v in');
        expect(outS, isNotNull, reason: 'trial $trial valve $v out');
        final qIn = inS?.flow.inLitersPerSecond ?? 0.0;
        final qOut = outS?.flow.inLitersPerSecond ?? 0.0;
        final why = 'trial $trial valve $v ($i -> $o)';
        if (towardRoot.contains(v)) {
          checkedReturns++;
          expect(inS, isNotNull, reason: why);
          expect(qIn, 0, reason: why);
          expect(qOut, 0, reason: why);
        } else {
          checkedFeeds++;
          expect(qIn, greaterThanOrEqualTo(0), reason: why);
          if (qIn > 1e-12) {
            expect(inS!.flowFromId, i, reason: why);
            expect(outS!.flowFromId, v, reason: why);
          }
          // Never zero-forced: a feed leg straight off the main, with no
          // other source path, always carries water its own way.
          if (legValves.contains(v) && !hasReturn) {
            expect(qIn, greaterThan(0), reason: why);
            expect(inS!.flowFromId, i, reason: why);
          }
        }
      }
    }
    expect(checkedReturns, greaterThan(20));
    expect(checkedFeeds, greaterThan(50));
    expect(skipped, lessThan(150));
  });
  // ── r5 — the binding conservative rule for AMBIGUOUSLY drawn valves ────────

  /// A heater H with duty/standby CIRCULATION pumps, each with its own
  /// discharge valve drawn in the flow direction: H -> P1 -> CV1 -> HDR and
  /// H -> P2 -> CV2 -> HDR. HDR -> S0..S3 supply riser (a 2-UBAP fixture per
  /// floor), the riser top S3 -> R3 -> R2 -> R1 -> R0 return riser, then the
  /// common return valve CVr drawn AMBIGUOUSLY (R0 -> CVr and H -> CVr).
  /// [rj] adds one bare node on the return (R0 -> RJ -> CVr).
  Network dutyStandby({bool rj = false, bool ambiguous = true}) {
    final nodes = <NetNode>[
      _n('H', 0, 0, role: NodeRole.plant),
      _n('P1', 20, -20, c: NodeComponent.pump),
      _n('P2', 20, 20, c: NodeComponent.pump),
      _n('CV1', 40, -20, c: NodeComponent.checkValve),
      _n('CV2', 40, 20, c: NodeComponent.checkValve),
      _n('HDR', 60, 0),
      _n('CVr', 10, 40, c: NodeComponent.checkValve),
    ];
    final edges = <NetEdge>[
      _e('h1', 'H', 'P1'),
      _e('p1', 'P1', 'CV1'),
      _e('c1', 'CV1', 'HDR'),
      _e('h2', 'H', 'P2'),
      _e('p2', 'P2', 'CV2'),
      _e('c2', 'CV2', 'HDR'),
    ];
    for (var f = 0; f < 4; f++) {
      nodes
        ..add(_n('S$f', 100, 0, floor: f))
        ..add(_n('fx$f', 140, 0, floor: f, role: NodeRole.fixture))
        ..add(_n('R$f', 120, 40, floor: f));
      edges.add(_e('b$f', 'S$f', 'fx$f'));
      edges.add(f == 0
          ? _e('m', 'HDR', 'S0')
          : _e('s$f', 'S${f - 1}', 'S$f', k: EdgeKind.riser));
      if (f > 0) edges.add(_e('r$f', 'R$f', 'R${f - 1}', k: EdgeKind.riser));
    }
    edges.add(_e('top', 'S3', 'R3'));
    final last = rj ? 'RJ' : 'R0';
    if (rj) {
      nodes.add(_n('RJ', 60, 40));
      edges.add(_e('rr', 'R0', 'RJ'));
    }
    edges
      ..add(_e('jc', last, 'CVr'))
      ..add(ambiguous ? _e('ch', 'H', 'CVr') : _e('ch', 'CVr', 'H'));
    return Network(nodes: nodes, edges: edges);
  }

  test(
      'r5 (binding rule): duty/standby circulation pumps + an AMBIGUOUS '
      'common return — supply main curve(8) DN20, each pump leg the full set '
      'flow, the return 0; calibrated or not, with or without a bare node on '
      'the return; only CVr is named (closed return), never feeds-ring', () {
    // The ambiguous CVr shares no leg-end pair with another valve (its legs
    // end at H and at the riser top S3), so it is not in a parallel set; it
    // is read as a CLOSED RETURN, and closing it cuts no fixture off the
    // heater (the pumps feed HDR). So the supply sizes as the open network:
    // 4 floors x 2 UBAP = 8 UBAP => curve(8) = 8/10 x 0.5 = 0.400 L/s
    // (flush-tank Gambar 1), DN20 (DN15 at 0.4 L/s is 2.26 m/s > 2.0 m/s).
    // CV1 / CV2 are drawn (rule 1) and share the leg ends {H, HDR}: a
    // Round-13 duty/standby set — the duty leg carries the set flow and the
    // standby leg MIRRORS it (a standby pump is a full-duty machine), so
    // every pump-leg pipe carries 0.400 L/s and the standby leg is recorded
    // in parallelLegEdgeIdsOut. r4 read CVr as a FEED here (hop-distance
    // heuristics: m = 0.2381 L/s DN15, -40 %) and named CV1/CV2/CVr.
    for (final rj in [false, true]) {
      for (final cal in [false, true]) {
        final ring = <String>{};
        final par = <String>{};
        final amb = <String, CheckValveAmbiguity>{};
        final s = autoSizeNetwork(
          dutyStandby(rj: rj),
          const SizingContext(),
          leafDemand: const {ServiceType.hotWater: FlowRate(0)},
          leafFixtureUnits: const {ServiceType.hotWater: 2.0},
          building: cal ? _levels : null,
          calibrationBySheet:
              cal ? const {'s1': ScaleCalibration(0.05)} : const {},
          checkValveFeedsRingOut: ring,
          parallelLegEdgeIdsOut: par,
          checkValveAmbiguousOut: amb,
        );
        final why = 'rj=$rj cal=$cal';
        expect(s['m']!.flow.inLitersPerSecond, closeTo(_curve(8), 1e-9),
            reason: why);
        expect(s['m']!.diameter.inMillimeters, 20, reason: why);
        for (final id in ['h1', 'p1', 'c1', 'h2', 'p2', 'c2']) {
          expect(s[id]!.flow.inLitersPerSecond, closeTo(_curve(8), 1e-9),
              reason: '$why $id');
        }
        expect(par, {'h2', 'p2', 'c2'}, reason: why);
        for (final id in ['top', 'r3', 'r2', 'r1', if (rj) 'rr', 'jc', 'ch']) {
          expect(s[id]!.flow.inLitersPerSecond, 0, reason: '$why $id');
        }
        expect(ring, isEmpty, reason: why);
        expect(amb, {'CVr': CheckValveAmbiguity.closedReturn}, reason: why);
      }
    }
    // The same return drawn R0 -> CVr -> H (unambiguous) sizes identically.
    final drawn = _size(dutyStandby(ambiguous: false));
    final amb = _size(dutyStandby());
    for (final id in drawn.keys) {
      expect(amb[id]!.flow.inLitersPerSecond,
          closeTo(drawn[id]!.flow.inLitersPerSecond, 1e-9),
          reason: id);
    }
  });

  test(
      'r5: an ambiguous valve PAIRED with a drawn one (pump + bypass / '
      'duty-standby onto one header) is a standby-set member', () {
    // CV2 drawn ambiguously (P2 -> CV2 and HDR -> CV2) beside the drawn CV1:
    // both legs end at {H, HDR} — a parallel set (structural, no distance).
    // The drawn partner fixes the direction (H side in), so the set keeps
    // the Round-13 standby rule: both legs carry the full set flow.
    final base = dutyStandby(ambiguous: false);
    final net = Network(nodes: base.nodes, edges: [
      for (final e in base.edges)
        if (e.id == 'c2') _e('c2', 'HDR', 'CV2') else e,
    ]);
    for (final cal in [false, true]) {
      final par = <String>{};
      final amb = <String, CheckValveAmbiguity>{};
      final s = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.hotWater: FlowRate(0)},
        leafFixtureUnits: const {ServiceType.hotWater: 2.0},
        building: cal ? _levels : null,
        calibrationBySheet:
            cal ? const {'s1': ScaleCalibration(0.05)} : const {},
        parallelLegEdgeIdsOut: par,
        checkValveAmbiguousOut: amb,
      );
      for (final id in ['h1', 'p1', 'c1', 'h2', 'p2', 'c2', 'm']) {
        expect(s[id]!.flow.inLitersPerSecond, closeTo(_curve(8), 1e-9),
            reason: 'cal=$cal $id');
      }
      expect(s['c2']!.flowFromId, 'CV2', reason: 'cal=$cal');
      expect(par, {'h2', 'p2', 'c2'}, reason: 'cal=$cal');
      expect(amb, {'CV2': CheckValveAmbiguity.standbySet}, reason: 'cal=$cal');
    }
  });

  test(
      'r5: the hotel + heater discharge + AMBIGUOUS return keeps its result '
      '(supply == open network, return 0) and names the valve closed return',
      () {
    for (final cal in [false, true]) {
      final base = _hotel(discharge: true);
      final net = Network(nodes: base.nodes, edges: [
        for (final e in base.edges)
          if (e.id == 'ch') _e('ch', 'H', 'CV') else e,
      ]);
      final amb = <String, CheckValveAmbiguity>{};
      final ring = <String>{};
      final s = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.hotWater: FlowRate(0)},
        leafFixtureUnits: const {ServiceType.hotWater: 2.0},
        building: cal ? _levels : null,
        calibrationBySheet:
            cal ? const {'s1': ScaleCalibration(0.05)} : const {},
        checkValveAmbiguousOut: amb,
        checkValveFeedsRingOut: ring,
      );
      final open = _size(_hotel(ret: false, discharge: true), cal: cal);
      for (final id in open.keys) {
        expect(s[id]!.flow.inLitersPerSecond,
            closeTo(open[id]!.flow.inLitersPerSecond, 1e-9),
            reason: 'cal=$cal $id');
      }
      expect(s['hm1']!.flow.inLitersPerSecond, closeTo(_curve(16), 1e-9));
      expect(s['ch']!.flow.inLitersPerSecond, 0);
      expect(s['jc']!.flow.inLitersPerSecond, 0);
      expect(amb, {'CV': CheckValveAmbiguity.closedReturn});
      expect(ring, isEmpty);
    }
  });

  /// T -> M -> J1 (or M -> CV1 -> J1 with [cv1]); ring J1 - A0 - A1 - J2 -
  /// J1 with a 4-UBAP fixture off A0 and A1; second leg M -> CV2 <- J2
  /// (AMBIGUOUS, both pipes drawn into CV2). [cv1Return] instead draws the
  /// FIRST leg J1 -> CV1 -> M (a drawn valve pointing toward the source).
  Network secondFeed({bool cv1 = false, bool cv1Return = false}) {
    NetEdge e(String id, String a, String b) =>
        NetEdge(id: id, fromId: a, toId: b, service: ServiceType.coldWater);
    final useCv1 = cv1 || cv1Return;
    return Network(nodes: [
      _n('T', 0, 0, role: NodeRole.plant),
      _n('M', 20, 0),
      if (useCv1) _n('CV1', 30, -10, c: NodeComponent.checkValve),
      _n('J1', 40, -20),
      _n('A0', 60, -20),
      _n('A1', 60, 20),
      _n('J2', 40, 20),
      _n('fA0', 80, -20, role: NodeRole.fixture),
      _n('fA1', 80, 20, role: NodeRole.fixture),
      _n('CV2', 30, 10, c: NodeComponent.checkValve),
    ], edges: [
      e('tm', 'T', 'M'),
      if (!useCv1) e('m1', 'M', 'J1'),
      if (cv1) ...[e('m1', 'M', 'CV1'), e('c1', 'CV1', 'J1')],
      if (cv1Return) ...[e('m1', 'CV1', 'M'), e('c1', 'J1', 'CV1')],
      e('ja', 'J1', 'A0'),
      e('aa', 'A0', 'A1'),
      e('aj', 'A1', 'J2'),
      e('jj', 'J2', 'J1'),
      e('fa0', 'A0', 'fA0'),
      e('fa1', 'A1', 'fA1'),
      e('zc', 'M', 'CV2'),
      e('c2', 'J2', 'CV2'),
    ]);
  }

  test(
      'r5: an ambiguous genuine second feed reads as a CLOSED return — the '
      'first leg carries the whole curve(8) — whether or not the first leg '
      'carries a valve (r4 flipped on that)', () {
    // Closing CV2 cuts no fixture off T (the ring is fed through J1), so it
    // is a closed return: the first leg carries the whole ring demand,
    // 2 x 4 = 8 UBAP => curve(8) = 0.400 L/s, and zc / c2 are sized at zero
    // (DN15, fu 0). Recorded behaviour: an ambiguous valve that only TIES or
    // even shortens a draw-off path is not a feed.
    for (final cv1 in [false, true]) {
      final fu = <String, double>{};
      final amb = <String, CheckValveAmbiguity>{};
      final s = autoSizeNetwork(secondFeed(cv1: cv1), const SizingContext(),
          leafDemand: const {ServiceType.coldWater: FlowRate(0)},
          leafFixtureUnits: const {ServiceType.coldWater: 4.0},
          fixtureUnitsOut: fu,
          checkValveAmbiguousOut: amb);
      expect(s['m1']!.flow.inLitersPerSecond, closeTo(_curve(8), 1e-9),
          reason: 'cv1=$cv1');
      if (cv1) {
        expect(s['c1']!.flow.inLitersPerSecond, closeTo(_curve(8), 1e-9));
      }
      for (final id in ['zc', 'c2']) {
        expect(s[id]!.flow.inLitersPerSecond, 0, reason: 'cv1=$cv1 $id');
        expect(s[id]!.diameter.inMillimeters, 15, reason: 'cv1=$cv1 $id');
        expect(fu[id], 0, reason: 'cv1=$cv1 $id');
      }
      expect(amb, {'CV2': CheckValveAmbiguity.closedReturn});
    }
  });

  test(
      'r5: an ambiguous valve whose closing would starve a fixture is a '
      'PLAIN PIPE (+ advisory); two that starve it only together are both '
      'pipes, sized exactly as bare junctions', () {
    // (a) The first leg is a drawn RETURN (J1 -> CV1 -> M points toward T):
    // zeroed. Closing CV2 too would cut A0 / A1 off T, so CV2 is a plain
    // pipe and the whole curve(8) = 0.400 L/s enters by it.
    final amb = <String, CheckValveAmbiguity>{};
    final s = autoSizeNetwork(
        secondFeed(cv1Return: true), const SizingContext(),
        leafDemand: const {ServiceType.coldWater: FlowRate(0)},
        leafFixtureUnits: const {ServiceType.coldWater: 4.0},
        checkValveAmbiguousOut: amb);
    expect(amb, {'CV2': CheckValveAmbiguity.plainPipe});
    expect(s['zc']!.flow.inLitersPerSecond, closeTo(_curve(8), 1e-9));
    expect(s['c2']!.flow.inLitersPerSecond, closeTo(_curve(8), 1e-9));
    expect(s['m1']!.flow.inLitersPerSecond, 0);
    expect(s['c1']!.flow.inLitersPerSecond, 0);

    // (b) A dual-feed ring entered through TWO ambiguous valves: either
    // alone may close, both together starve the ring — reopening either
    // restores it, so (symmetrically, never by id order) both are pipes and
    // the network sizes exactly as with bare junctions (Hardy–Cross).
    NetEdge e(String id, String a, String b) =>
        NetEdge(id: id, fromId: a, toId: b, service: ServiceType.coldWater);
    Network dual({required bool valves, String v1 = 'V1', String v2 = 'V2'}) =>
        Network(nodes: [
          _n('T', 0, 0, role: NodeRole.plant),
          _n('M', 20, 0),
          _n(v1, 40, -20, c: valves ? NodeComponent.checkValve : null),
          _n(v2, 40, 20, c: valves ? NodeComponent.checkValve : null),
          _n('J1', 60, -20),
          _n('J2', 60, 20),
          _n('X', 80, 20),
          _n('fA', 80, -20, role: NodeRole.fixture),
          _n('fB', 100, 20, role: NodeRole.fixture),
        ], edges: [
          e('tm', 'T', 'M'),
          e('m1', 'M', v1),
          e('c1', 'J1', v1),
          e('m2', v2, 'M'),
          e('c2', v2, 'J2'),
          e('hdr', 'J1', 'J2'),
          e('a', 'J1', 'fA'),
          e('x', 'J2', 'X'),
          e('b', 'X', 'fB'),
        ]);
    final ref = sizeCold(dual(valves: false));
    for (final ids in [('V1', 'V2'), ('V2', 'V1')]) {
      final amb2 = <String, CheckValveAmbiguity>{};
      final s2 = autoSizeNetwork(
          dual(valves: true, v1: ids.$1, v2: ids.$2), const SizingContext(),
          leafDemand: const {ServiceType.coldWater: FlowRate(0)},
          leafFixtureUnits: const {ServiceType.coldWater: 4.0},
          checkValveAmbiguousOut: amb2);
      expect(amb2, {
        'V1': CheckValveAmbiguity.plainPipe,
        'V2': CheckValveAmbiguity.plainPipe,
      });
      for (final id in ref.keys) {
        expect(s2[id]!.flow.inLitersPerSecond,
            closeTo(ref[id]!.flow.inLitersPerSecond, 1e-9),
            reason: '$ids $id');
      }
    }
  });

  test(
      'r5 property (seeded): for every AMBIGUOUS valve the result — its '
      'reading and every pipe size — is invariant to bare bends anywhere and '
      'to calibration', () {
    var checked = 0;
    final seen = <CheckValveAmbiguity>{};
    for (var trial = 0; trial < 120; trial++) {
      final rnd = math.Random(5200 + trial);
      final nodes = <NetNode>[
        _n('T', 0, 0, role: NodeRole.plant),
        _n('M', 20, 0),
      ];
      final edges = <(String, String, String)>[];
      var eid = 0;
      void pipe(String a, String b) => edges.add(('e${eid++}', a, b));
      var vid = 0;
      void valve(String a, String b, double x, double y) {
        final id = 'V${rnd.nextInt(1 << 20)}_${vid++}';
        nodes.add(_n(id, x, y, c: NodeComponent.checkValve));
        if (rnd.nextBool()) {
          pipe(a, id); // both INTO the valve
          pipe(b, id);
        } else {
          pipe(id, a); // both OUT of it
          pipe(id, b);
        }
      }

      pipe('T', 'M');
      final k = 4 + rnd.nextInt(4);
      var anyFixture = false;
      for (var i = 0; i < k; i++) {
        final a = 2 * math.pi * i / k;
        final (x, y) = (200 + 100 * math.cos(a), 100 * math.sin(a));
        nodes.add(_n('R$i', x, y));
        if (rnd.nextBool() || (i == k - 1 && !anyFixture)) {
          anyFixture = true;
          nodes.add(_n('f$i', x * 1.1, y * 1.1, role: NodeRole.fixture));
          pipe('R$i', 'f$i');
        }
      }
      final ringValveAt = rnd.nextDouble() < 0.4 ? rnd.nextInt(k) : -1;
      for (var i = 0; i < k; i++) {
        final j = (i + 1) % k;
        if (i == ringValveAt) {
          valve('R$i', 'R$j', 210, 10.0 * i);
        } else {
          rnd.nextBool() ? pipe('R$i', 'R$j') : pipe('R$j', 'R$i');
        }
      }
      final entries = ([for (var i = 0; i < k; i++) i]..shuffle(rnd))
          .take(1 + rnd.nextInt(2))
          .toList();
      for (final en in entries) {
        if (rnd.nextDouble() < 0.7) {
          valve('M', 'R$en', 60, 5.0 * en);
        } else {
          pipe('M', 'R$en');
        }
      }
      if (rnd.nextDouble() < 0.5) {
        final r = rnd.nextInt(k);
        nodes.add(_n('Q', 30, 80));
        pipe('R$r', 'Q');
        valve('Q', 'T', 10, 60);
      }
      final pos = {for (final n in nodes) n.id: (n.x, n.y)};
      final bent = {
        for (final (id, _, _) in edges)
          if (rnd.nextDouble() < 0.35) id,
      };
      NetEdge cw(String id, String a, String b) =>
          NetEdge(id: id, fromId: a, toId: b, service: ServiceType.coldWater);
      Network build({required bool bends}) {
        final ns = [...nodes];
        final es = <NetEdge>[];
        for (final (id, a, b) in edges) {
          if (bends && bent.contains(id)) {
            // A bare bend at the exact midpoint: same drawn direction, same
            // pixel length.
            final (xa, ya) = pos[a]!;
            final (xb, yb) = pos[b]!;
            ns.add(_n('K$id', (xa + xb) / 2, (ya + yb) / 2));
            es
              ..add(cw(id, a, 'K$id'))
              ..add(cw('${id}k', 'K$id', b));
          } else {
            es.add(cw(id, a, b));
          }
        }
        return Network(nodes: ns, edges: es);
      }

      final results =
          <(Map<String, EdgeSizing>, Map<String, CheckValveAmbiguity>)>[];
      for (final bends in [false, true]) {
        for (final cal in [false, true]) {
          final amb = <String, CheckValveAmbiguity>{};
          final s = autoSizeNetwork(build(bends: bends), const SizingContext(),
              leafDemand: const {ServiceType.coldWater: FlowRate(0)},
              leafFixtureUnits: const {ServiceType.coldWater: 4.0},
              building:
                  cal ? const BuildingLevels([Floor('L1', Length(3.0))]) : null,
              calibrationBySheet:
                  cal ? const {'s1': ScaleCalibration(0.05)} : const {},
              checkValveAmbiguousOut: amb);
          results.add((s, amb));
        }
      }
      // Variants: 0 plain, 1 calibrated, 2 bends, 3 bends + calibrated. The
      // valve READING never moves; every pipe size is bend-invariant (a bend
      // at the exact midpoint keeps the pixel length, so even a plain-pipe
      // ring's Hardy–Cross split is unchanged); a CLOSED valve's legs carry
      // exactly 0 in every variant. (A plain-pipe ring's split may move
      // with calibration — real lengths, incl. vertical legs, are its
      // resistance basis — that is the pipe, not the valve reading.)
      final (s0, amb0) = results.first;
      seen.addAll(amb0.values);
      for (var v = 1; v < results.length; v++) {
        final (s, amb) = results[v];
        final why = 'trial $trial variant $v';
        expect(amb, amb0, reason: why);
        for (final (id, a, b) in edges) {
          final ref = results[v & 1].$1[id];
          for (final sid in [id, if (v >= 2 && bent.contains(id)) '${id}k']) {
            final got = s[sid];
            expect(got == null, s0[id] == null, reason: '$why $sid');
            final closed =
                [a, b].any((n) => amb0[n] == CheckValveAmbiguity.closedReturn);
            if (closed) {
              expect(got!.flow.inLitersPerSecond, 0, reason: '$why $sid');
            }
            // Round 27 r6 — a valve on the source's discharge leg is never
            // zero-forced: it always carries water away from the source.
            final supply =
                [a, b].any((n) => amb0[n] == CheckValveAmbiguity.supplyLeg);
            if (supply) {
              expect(got!.flow.inLitersPerSecond, greaterThan(0),
                  reason: '$why $sid');
            }
            if (v < 2 || got == null || ref == null) continue;
            expect(got.flow.inLitersPerSecond,
                closeTo(ref.flow.inLitersPerSecond, 1e-6),
                reason: '$why $sid');
            expect(got.diameter.inMillimeters, ref.diameter.inMillimeters,
                reason: '$why $sid');
          }
        }
      }
      if (amb0.isNotEmpty) checked++;
    }
    expect(checked, greaterThan(60));
    expect(
        seen,
        containsAll(
            [CheckValveAmbiguity.closedReturn, CheckValveAmbiguity.plainPipe]));
  });
}
