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
            : _e('s${r}_$f', 'S${r}_${f - 1}', 'S${r}_$f',
                k: EdgeKind.riser));
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
      calibrationBySheet:
          cal ? const {'s1': ScaleCalibration(0.05)} : const {},
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
      for (final ids in [('CVd', 'CV'), ('CV', 'CVd'), ('A', 'Z'), ('Z', 'A')]) {
        final s = _size(
            _hotel(discharge: true, cvdId: ids.$1, cvId: ids.$2),
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
            s[trunk]!.flow.inLitersPerSecond +
                s['ch']!.flow.inLitersPerSecond,
            closeTo(_curve(16), 1e-9),
            reason: why);
        expect(s['ch']!.flow.inLitersPerSecond, greaterThan(0), reason: why);
        expect(s['ch']!.flowFromId, 'H', reason: why);
        expect(s['jc']!.flowFromId, 'CV', reason: why);
        expect(ring, contains('CV'), reason: why);
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
        _n(id, x, y, role: id.startsWith('f') ? NodeRole.fixture : NodeRole.main),
    ], edges: [
      e('tm', 'T', 'M'),
      e('m1', 'M', cv1),
      e('c1', cv1, e1),
      e('m2', 'M', cv2),
      e('c2', cv2, e2),
      for (final (id, a, b) in ring) e(id, a, b),
    ]);
  }

  Map<String, EdgeSizing> sizeCold(Network net) => autoSizeNetwork(
      net, const SizingContext(),
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
      final s = sizeCold(
          dualFeed(ring, nodes, 'J1', 'J2', cv1: ids.$1, cv2: ids.$2));
      expect(s['tm']!.flow.inLitersPerSecond, closeTo(_curve(8), 1e-9));
      expect(
          s['m1']!.flow.inLitersPerSecond + s['m2']!.flow.inLitersPerSecond,
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
      final s = sizeCold(
          dualFeed(ring, nodes, 'J1', 'J2', cv1: ids.$1, cv2: ids.$2));
      for (final id in ref.keys) {
        expect(s[id]!.flow.inLitersPerSecond,
            closeTo(ref[id]!.flow.inLitersPerSecond, 1e-9),
            reason: '$ids $id');
      }
      expect(
          s['m1']!.flow.inLitersPerSecond + s['m2']!.flow.inLitersPerSecond,
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
      final net = Network(
          nodes: nodes, edges: [...edges]..shuffle(math.Random(trial)));

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
      if (nodes.any((n) => n.role == NodeRole.fixture && !dr.containsKey(n.id))) {
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
        // (An exactly zero-flow ring pipe is left unsized: flow 0.)
        final inS = sOf(i, v), outS = sOf(v, o);
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
}
