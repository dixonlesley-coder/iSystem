/// Round 26 (hot-water-2-common-return-cv-hardy-cross) — several riser
/// returns joined on a common header, then ONE check valve + circulator back
/// to the heater (the usual hotel recirculation). Cutting the valve alone
/// leaves the supply-riser / return-riser ring, which used to fall to
/// Hardy–Cross and route draw-off up the returns. The return side (edges on no
/// shortest root -> draw-off path) is now deferred with the valve, so the
/// supply sizes exactly as with no return drawn and every return carries 0.
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

/// Heater H -> M -> [risers] supply risers of 4 floors, a 2-UBAP fixture at
/// each floor node. With [common], each riser top runs down a return riser to
/// a shared header RJ -> CV -> H; [perRiser] puts a CV in every return
/// instead (the Round-12 topology, the reference answer).
///
/// Round 26 r3 — [branchTee] (per riser index) tees the return top from a
/// BARE node T on the top branch S_r_3 - fx_r_3 instead of the riser top
/// S_r_3 (the Run tool's tee-in); without a return the tee is drawn too, so
/// the open network compares like for like.
///
/// Round 26 r4 — [fixtureTee] tees the return top straight from the top
/// fixture fx_r_3 (fixture INLINE on the return path) and [beyondTee] from a
/// bare node Q_r beyond it (S_r_3 -> fx_r_3 -> Q_r -> return riser). Both are
/// drawn only with a return (Q_r alone would be a demand leaf).
Network _hotel(
    {int risers = 2,
    bool common = false,
    bool perRiser = false,
    Set<int> branchTee = const {},
    Set<int> fixtureTee = const {},
    Set<int> beyondTee = const {}}) {
  final nodes = <NetNode>[
    _n('H', 0, 0, role: NodeRole.plant),
    _n('M', 50, 0),
  ];
  final edges = <NetEdge>[_e('hm', 'H', 'M')];
  for (var r = 0; r < risers; r++) {
    final x = 100.0 + 200 * r;
    for (var f = 0; f < 4; f++) {
      nodes
        ..add(_n('S${r}_$f', x, 0, floor: f))
        ..add(_n('fx${r}_$f', x + 40, 0, floor: f, role: NodeRole.fixture));
      if (f == 3 && branchTee.contains(r)) {
        nodes.add(_n('T$r', x + 30, 0, floor: f));
        edges
          ..add(_e('b${r}_$f', 'S${r}_$f', 'T$r'))
          ..add(_e('bt$r', 'T$r', 'fx${r}_$f'));
      } else {
        edges.add(_e('b${r}_$f', 'S${r}_$f', 'fx${r}_$f'));
      }
      edges.add(f == 0
          ? _e('m$r', 'M', 'S${r}_0')
          : _e('s${r}_$f', 'S${r}_${f - 1}', 'S${r}_$f', k: EdgeKind.riser));
    }
    if (common || perRiser) {
      for (var f = 0; f < 4; f++) {
        nodes.add(_n('R${r}_$f', x + 20, 0, floor: f));
      }
      if (beyondTee.contains(r)) {
        nodes.add(_n('Q$r', x + 60, 0, floor: 3));
        edges.add(_e('bq$r', 'fx${r}_3', 'Q$r'));
      }
      final topFrom = beyondTee.contains(r)
          ? 'Q$r'
          : fixtureTee.contains(r)
              ? 'fx${r}_3'
              : branchTee.contains(r)
                  ? 'T$r'
                  : 'S${r}_3';
      edges.add(_e('top$r', topFrom, 'R${r}_3'));
      for (var f = 3; f >= 1; f--) {
        edges.add(
            _e('r${r}_$f', 'R${r}_$f', 'R${r}_${f - 1}', k: EdgeKind.riser));
      }
      if (perRiser) {
        nodes.add(_n('CV$r', 10.0 + r, 0, c: NodeComponent.checkValve));
        edges
          ..add(_e('rc$r', 'R${r}_0', 'CV$r'))
          ..add(_e('ch$r', 'CV$r', 'H'));
      } else {
        edges.add(_e('rj$r', 'R${r}_0', 'RJ'));
      }
    }
  }
  if (common) {
    nodes
      ..add(_n('RJ', 30, 0))
      ..add(_n('CV', 10, 0, c: NodeComponent.checkValve));
    edges
      ..add(_e('jc', 'RJ', 'CV'))
      ..add(_e('ch', 'CV', 'H'));
  }
  return Network(nodes: nodes, edges: edges);
}

Map<String, EdgeSizing> _size(Network net) => autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {ServiceType.hotWater: FlowRate(0)},
      leafFixtureUnits: const {ServiceType.hotWater: 2.0},
    );

void main() {
  test('one common check valve sizes the supply as if no return were drawn',
      () {
    // Main: 2 risers x 4 floors x 2 UBAP = 16 UBAP; flush-tank Gambar 1
    // (10..20 UBAP segment) ⇒ curve(16). Each riser base: curve(8) = 8/10 x
    // 0.5 = 0.400 L/s.
    const sni = SniProfile();
    final main = sni.probableFlowForFixtureUnits(16).inLitersPerSecond;
    final riser = sni.probableFlowForFixtureUnits(8).inLitersPerSecond;
    expect(riser, closeTo(0.400, 1e-9));
    final open = _size(_hotel());
    final common = _size(_hotel(common: true));
    final perRiser = _size(_hotel(perRiser: true));
    for (final s in [open, common, perRiser]) {
      expect(s['hm']!.flow.inLitersPerSecond, closeTo(main, 1e-9));
      expect(s['m0']!.flow.inLitersPerSecond, closeTo(riser, 1e-9));
      expect(s['m1']!.flow.inLitersPerSecond, closeTo(riser, 1e-9));
    }
    for (final id in open.keys) {
      expect(
          common[id]!.diameter.inMillimeters, open[id]!.diameter.inMillimeters,
          reason: id);
    }
    // No draw-off through any return edge or the valve.
    for (final id in ['jc', 'ch', 'rj0', 'rj1', 'top0', 'top1', 'r0_1']) {
      expect(common[id]!.flow.inLitersPerSecond, closeTo(0, 1e-12), reason: id);
    }
  });

  test('property: any riser count + edge order keeps the full supply (seeded)',
      () {
    const sni = SniProfile();
    final rnd = math.Random(26);
    for (var trial = 0; trial < 20; trial++) {
      final n = 2 + rnd.nextInt(4);
      final net = _hotel(risers: n, common: true);
      final edges = [...net.edges]..shuffle(math.Random(trial));
      final s = _size(Network(nodes: net.nodes, edges: edges));
      expect(
          s['hm']!.flow.inLitersPerSecond,
          closeTo(
              sni.probableFlowForFixtureUnits(8.0 * n).inLitersPerSecond, 1e-9),
          reason: 'trial $trial, $n risers');
      expect(s['ch']!.flow.inLitersPerSecond, closeTo(0, 1e-12),
          reason: 'trial $trial');
    }
  });

  // Round 26 r2 / r4 — a stub-fed ring main with draw-off AT every ring node
  // (each a 2-UBAP fixture) and a drawn return from a ring node
  // (c -> CV -> H). With [returnDrawn] false the return (CV, cc, ch) is not
  // drawn at all — the r4 reference: a RETURN check valve carries no
  // draw-off, so the ring is fed at F alone.
  Network ring({bool returnDrawn = true}) {
    final nodes = <NetNode>[
      _n('H', 0, 0, role: NodeRole.plant),
      _n('F', 100, 0),
      _n('a', 100, 100, role: NodeRole.fixture),
      _n('b', 200, 100, role: NodeRole.fixture),
      _n('c', 300, 100, role: NodeRole.fixture),
      _n('d', 300, 0, role: NodeRole.fixture),
      if (returnDrawn) _n('CV', 150, -50, c: NodeComponent.checkValve),
    ];
    final edges = <NetEdge>[
      _e('hf', 'H', 'F'),
      _e('fa', 'F', 'a'),
      _e('ab', 'a', 'b'),
      _e('bc', 'b', 'c'),
      _e('cd', 'c', 'd'),
      _e('df', 'd', 'F'),
      if (returnDrawn) ...[_e('cc', 'c', 'CV'), _e('ch', 'CV', 'H')],
    ];
    return Network(nodes: nodes, edges: edges);
  }

  Map<String, EdgeSizing> sizeCal(Network net) => autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.hotWater: FlowRate(0)},
        leafFixtureUnits: const {ServiceType.hotWater: 2.0},
        building: const BuildingLevels([Floor('L1', Length(3.0))]),
        calibrationBySheet: const {'s1': ScaleCalibration(0.01)},
      );

  const sni = SniProfile();
  double curve(double ubap) =>
      sni.probableFlowForFixtureUnits(ubap).inLitersPerSecond;

  test(
      'ring main with draw-off on both legs + a drawn CV return: the ring '
      'splits as if fed at F alone, the return valve carries nothing', () {
    // Round 26 r4 — the reference is the NO-RETURN network (the Round-12
    // principle: a return check valve carries no draw-off). The heater feed
    // hf carries every fixture: curve(4 x 2 UBAP) = 8/10 x 0.5 = 0.400 L/s.
    final withCv = sizeCal(ring());
    final noReturn = sizeCal(ring(returnDrawn: false));
    expect(withCv['hf']!.flow.inLitersPerSecond, closeTo(curve(8), 1e-9));
    expect(curve(8), closeTo(0.400, 1e-12));
    for (final id in ['hf', 'fa', 'ab', 'bc', 'cd', 'df']) {
      expect(withCv[id]!.flow.inLitersPerSecond,
          closeTo(noReturn[id]!.flow.inLitersPerSecond, 1e-9),
          reason: id);
      expect(withCv[id]!.flowFromId, noReturn[id]!.flowFromId, reason: id);
    }
    // A genuine split: the ring legs differ and b-c carries flow.
    expect(withCv['fa']!.flow.inLitersPerSecond,
        isNot(closeTo(withCv['df']!.flow.inLitersPerSecond, 1e-6)));
    expect(withCv['bc']!.flowFromId, isNotNull);
    // The return valve: zero flow, oriented c -> CV -> H.
    expect(withCv['cc']!.flow.inLitersPerSecond, 0);
    expect(withCv['ch']!.flow.inLitersPerSecond, 0);
    expect(withCv['cc']!.flowFromId, 'c');
    expect(withCv['ch']!.flowFromId, 'CV');
  });

  // Round 26 r3 / r4 — a ring of [k] 2-UBAP draw-off points fed at F
  // (F - r0 ... r(k-1) - F) with a drawn return X -> CV -> H. [teeAt] places
  // X: a value i < k-1 inserts a BARE tee X between r_i and r_(i+1) (the
  // junction the Run tool's tee-in creates); null tees the return straight
  // from ring node r_[fixtureTee]. A ring index in [stubs] is a BARE ring
  // node with its fixture f_i on a branch stub (r_i -> f_i) instead of an
  // inline fixture. With [returnDrawn] false the return is not drawn — the
  // r4 reference.
  ({Network net, List<String> ring}) teeRing(int k,
      {int? teeAt,
      int fixtureTee = 0,
      Set<int> stubs = const {},
      bool returnDrawn = true}) {
    final nodes = <NetNode>[
      _n('H', 0, 0, role: NodeRole.plant),
      _n('F', 100, 0),
      if (returnDrawn) _n('CV', 150, -50, c: NodeComponent.checkValve),
    ];
    final ringIds = <String>[];
    final edges = <NetEdge>[_e('hf', 'H', 'F')];
    var prev = 'F';
    for (var i = 0; i < k; i++) {
      // A rectangle-ish loop: out along y = 100, back to y = 0 at the end.
      final x = 100.0 + 100 * i;
      final y = i == k - 1 ? 0.0 : 100.0;
      final stub = stubs.contains(i);
      nodes.add(_n('r$i', x, y, role: stub ? NodeRole.main : NodeRole.fixture));
      if (stub) {
        nodes.add(_n('f$i', x, y + 40, role: NodeRole.fixture));
        edges.add(_e('s$i', 'r$i', 'f$i'));
      }
      final id = 'e$i';
      edges.add(_e(id, prev, 'r$i'));
      ringIds.add(id);
      prev = 'r$i';
      if (teeAt == i) {
        nodes.add(_n('X', x + 50, 100));
        edges.add(_e('ex', 'r$i', 'X'));
        ringIds.add('ex');
        prev = 'X';
      }
    }
    edges.add(_e('ek', prev, 'F'));
    ringIds.add('ek');
    final tee = teeAt == null ? 'r$fixtureTee' : 'X';
    if (returnDrawn) {
      edges
        ..add(_e('xv', tee, 'CV'))
        ..add(_e('vh', 'CV', 'H'));
    }
    return (net: Network(nodes: nodes, edges: edges), ring: ringIds);
  }

  test(
      '(a) ring main with a return teed from a BARE ring tee: the heater '
      'feed carries the full peak, the ring splits as if fed at F alone', () {
    // H -> F, ring F-r0-r1-X-r2-r3-F (X bare between r1 and r2), return
    // X -> CV -> H, 0.01 m/px. r3's valve-free reference routed 0.166 L/s
    // (41.5 % of the peak) from H forward through the RETURN valve
    // (hf 0.2340 + vh 0.1660 = 0.4000) and sized hf one DN small. The
    // correct reference is the same ring fed at F ALONE (no return drawn):
    // hf = curve(8 UBAP) = 0.4000 L/s and every fixture takes 0.4/4 = 0.1.
    // Hardy–Cross on the ring (resistance ∝ length, exponent 1.852) then
    // gives e0 0.2260 / e1 0.1260 / ex = e2 0.0260 / e3 0.0740 / ek 0.1740;
    // continuity: e0 + ek = 0.4 = hf, e1 = e0 - 0.1, e2 + e3 = 0.1 (r2),
    // ek - e3 = 0.1 (r3).
    final withCv = teeRing(4, teeAt: 1);
    final noReturn = teeRing(4, teeAt: 1, returnDrawn: false);
    final s = sizeCal(withCv.net);
    final p = sizeCal(noReturn.net);
    expect(s['hf']!.flow.inLitersPerSecond, closeTo(curve(8), 1e-9));
    for (final id in ['hf', ...withCv.ring]) {
      expect(s[id]!.flow.inLitersPerSecond,
          closeTo(p[id]!.flow.inLitersPerSecond, 1e-9),
          reason: id);
      expect(s[id]!.flowFromId, p[id]!.flowFromId, reason: id);
    }
    const pinned = {
      'e0': 0.2260,
      'e1': 0.1260,
      'ex': 0.0260,
      'e2': 0.0260,
      'e3': 0.0740,
      'ek': 0.1740,
    };
    for (final MapEntry(key: id, value: q) in pinned.entries) {
      expect(s[id]!.flow.inLitersPerSecond, closeTo(q, 1e-4), reason: id);
    }
    double q(String id) => s[id]!.flow.inLitersPerSecond;
    expect(q('e0') + q('ek'), closeTo(q('hf'), 1e-9));
    expect(q('e2') + q('e3'), closeTo(0.1, 1e-9));
    // The return valve: zero draw-off, oriented X -> CV -> H.
    expect(q('xv'), 0);
    expect(q('vh'), 0);
    expect(s['xv']!.flowFromId, 'X');
    expect(s['vh']!.flowFromId, 'CV');
  });

  test(
      '(c) all-stub ring (every ring node bare, fixtures on stubs) + a '
      'bare-tee return: heater feed full peak, valve zero', () {
    // The walk from the valve meets no draw-off node (every ring node is
    // bare), so the ring segments either side of X are deferred as a
    // zero-draw-off return and the ring collapses to the hop-count tree —
    // the documented residual (the walk cannot tell this ring segment from a
    // hotel return riser). The heater feed and the valve are right whatever
    // the walk decides.
    final r = teeRing(4, teeAt: 1, stubs: {0, 1, 2, 3});
    final s = sizeCal(r.net);
    expect(s['hf']!.flow.inLitersPerSecond, closeTo(curve(8), 1e-9));
    expect(s['xv']!.flow.inLitersPerSecond, 0);
    expect(s['vh']!.flow.inLitersPerSecond, 0);
    // Documentation of the residual: ex carries no flow (deferred).
    expect(s['ex']!.flow.inLitersPerSecond, closeTo(0, 1e-12));
  });

  Map<String, EdgeSizing> sizeHotelCal(Network net) => autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.hotWater: FlowRate(0)},
        leafFixtureUnits: const {ServiceType.hotWater: 2.0},
        building: const BuildingLevels([
          Floor('L1', Length(3.0)),
          Floor('L2', Length(3.0)),
          Floor('L3', Length(3.0)),
          Floor('L4', Length(3.0)),
        ]),
        calibrationBySheet: const {'s1': ScaleCalibration(0.05)},
      );

  test(
      '(b) hotel common return teed AT or BEYOND the top fixture: the trunk '
      'carries the full peak, the valve legs nothing', () {
    // Round 26 r4 — the walk from the valve lands on the inline top fixture;
    // the trunk hm is a BRIDGE carrying every fixture: curve(2 risers x 4
    // floors x 2 UBAP) = curve(16). (Round 27 residuals-4: the return CHAIN
    // landing on the top fixture is now grown too, so every riser base also
    // sizes as with no return drawn — round27_check_valve_test.) r3 left the valve in
    // the loop set: hm 0.6533 -> 0.3766 (DN25 -> DN20) with 0.277 L/s of
    // draw-off forward through the return valve.
    final peak = curve(16);
    for (final cal in [false, true]) {
      for (final net in [
        _hotel(common: true, fixtureTee: {0, 1}),
        _hotel(common: true, beyondTee: {0, 1}),
        _hotel(common: true, fixtureTee: {0}, beyondTee: {1}),
      ]) {
        final s = cal ? sizeHotelCal(net) : _size(net);
        expect(s['hm']!.flow.inLitersPerSecond, closeTo(peak, 1e-9),
            reason: 'cal=$cal');
        expect(s['jc']!.flow.inLitersPerSecond, 0, reason: 'cal=$cal');
        expect(s['ch']!.flow.inLitersPerSecond, 0, reason: 'cal=$cal');
        expect(s['jc']!.flowFromId, 'RJ');
        expect(s['ch']!.flowFromId, 'CV');
      }
    }
  });

  test(
      'property: trunk = curve(total UBAP) and every return-valve edge = 0, '
      'any tee placement, inline or stub fixtures, edge order (seeded)', () {
    final rnd = math.Random(264);
    for (var trial = 0; trial < 40; trial++) {
      // Ring: 3..6 draw-off points, tee placement + stub fixtures at random.
      final k = 3 + rnd.nextInt(4);
      final bare = rnd.nextBool();
      final teeAt = bare ? rnd.nextInt(k - 1) : null;
      final fixtureTee = rnd.nextInt(k);
      final stubs = {
        for (var i = 0; i < k; i++)
          if (rnd.nextInt(3) == 0) i,
      };
      final r = teeRing(k, teeAt: teeAt, fixtureTee: fixtureTee, stubs: stubs);
      final s = sizeCal(Network(
          nodes: r.net.nodes,
          edges: [...r.net.edges]..shuffle(math.Random(trial))));
      final why =
          'trial $trial k=$k teeAt=$teeAt fixtureTee=$fixtureTee stubs=$stubs';
      expect(s['hf']!.flow.inLitersPerSecond, closeTo(curve(2.0 * k), 1e-9),
          reason: why);
      for (final id in ['xv', 'vh']) {
        expect(s[id]!.flow.inLitersPerSecond, 0, reason: '$why $id');
      }
      // With every ring node an inline fixture the walk always meets the
      // draw-off, so the ring splits exactly as with no return drawn.
      if (stubs.isEmpty) {
        final p = sizeCal(
            teeRing(k, teeAt: teeAt, fixtureTee: fixtureTee, returnDrawn: false)
                .net);
        for (final id in r.ring) {
          expect(s[id]!.flow.inLitersPerSecond,
              closeTo(p[id]!.flow.inLitersPerSecond, 1e-9),
              reason: '$why $id');
        }
      }

      // Hotel: 2..5 risers, each return top teed from the riser top, a bare
      // branch tee, the top fixture or a bare node beyond it.
      final n = 2 + rnd.nextInt(4);
      final branch = <int>{}, fixture = <int>{}, beyond = <int>{};
      for (var i = 0; i < n; i++) {
        switch (rnd.nextInt(4)) {
          case 1:
            branch.add(i);
          case 2:
            fixture.add(i);
          case 3:
            beyond.add(i);
        }
      }
      final hotel = _hotel(
          risers: n,
          common: true,
          branchTee: branch,
          fixtureTee: fixture,
          beyondTee: beyond);
      final cal = rnd.nextBool();
      final shuffled = Network(
          nodes: hotel.nodes,
          edges: [...hotel.edges]..shuffle(math.Random(100 + trial)));
      final h = cal ? sizeHotelCal(shuffled) : _size(shuffled);
      final hwhy = 'trial $trial risers=$n branch=$branch fixture=$fixture '
          'beyond=$beyond cal=$cal';
      expect(h['hm']!.flow.inLitersPerSecond, closeTo(curve(8.0 * n), 1e-9),
          reason: hwhy);
      for (final id in ['jc', 'ch']) {
        expect(h[id]!.flow.inLitersPerSecond, 0, reason: '$hwhy $id');
      }
      // A return teed from a BARE node at the supply (riser top / branch
      // tee) is still a zero-draw-off tree: the supply sizes exactly as with
      // no return drawn.
      if (fixture.isEmpty && beyond.isEmpty) {
        final open = _size(_hotel(risers: n, branchTee: branch));
        final hu = _size(shuffled);
        for (final id in open.keys) {
          expect(hu[id]!.flow.inLitersPerSecond,
              closeTo(open[id]!.flow.inLitersPerSecond, 1e-9),
              reason: '$hwhy $id');
        }
        for (var i = 0; i < n; i++) {
          expect(hu['top$i']!.flow.inLitersPerSecond, closeTo(0, 1e-12),
              reason: '$hwhy top$i');
        }
      }
    }
  });
}
