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
Network _hotel(
    {int risers = 2,
    bool common = false,
    bool perRiser = false,
    Set<int> branchTee = const {}}) {
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
      edges.add(
          _e('top$r', branchTee.contains(r) ? 'T$r' : 'S${r}_3', 'R${r}_3'));
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

  // Round 26 r2 — a stub-fed ring main with draw-off AT every ring node (each a 2-UBAP fixture) and a
  // drawn return from a ring node (c -> CV -> H). The valve's upstream node
  // is ON the ring, so no edge is a return pipe: the ring segment b-c (off
  // every hop-shortest path) must NOT be deferred as a 'return', and the ring
  // keeps the Hardy–Cross split — exactly as if the valve were a plain node.
  Network ring({bool valve = true}) {
    final nodes = <NetNode>[
      _n('H', 0, 0, role: NodeRole.plant),
      _n('F', 100, 0),
      _n('a', 100, 100, role: NodeRole.fixture),
      _n('b', 200, 100, role: NodeRole.fixture),
      _n('c', 300, 100, role: NodeRole.fixture),
      _n('d', 300, 0, role: NodeRole.fixture),
      _n('CV', 150, -50, c: valve ? NodeComponent.checkValve : null),
    ];
    final edges = <NetEdge>[
      _e('hf', 'H', 'F'),
      _e('fa', 'F', 'a'),
      _e('ab', 'a', 'b'),
      _e('bc', 'b', 'c'),
      _e('cd', 'c', 'd'),
      _e('df', 'd', 'F'),
      _e('cc', 'c', 'CV'),
      _e('ch', 'CV', 'H'),
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

  test(
      'ring main with draw-off on both legs + a drawn CV return keeps '
      'Hardy–Cross (no hop-count tree)', () {
    final withCv = sizeCal(ring());
    final plain = sizeCal(ring(valve: false));
    for (final id in ['fa', 'ab', 'bc', 'cd', 'df']) {
      expect(withCv[id]!.flow.inLitersPerSecond,
          closeTo(plain[id]!.flow.inLitersPerSecond, 1e-9),
          reason: id);
    }
    // A genuine split: the ring legs differ and b-c carries flow (it is not a
    // deferred zero-draw-off 'return').
    expect(withCv['fa']!.flow.inLitersPerSecond,
        isNot(closeTo(withCv['df']!.flow.inLitersPerSecond, 1e-6)));
    expect(withCv['bc']!.flowFromId, isNotNull);
  });

  // Round 26 r3 — a ring of [k] 2-UBAP fixture nodes r0..r(k-1) fed at F
  // (F - r0 ... r(k-1) - F) with a drawn return X -> CV -> H. [teeAt] places
  // X: a value i < k-1 inserts a BARE tee X between r_i and r_(i+1) (the
  // junction the Run tool's tee-in creates); null tees the return straight
  // from fixture r_[fixtureTee]. With [valve] false the CV is a plain node —
  // the Hardy–Cross reference.
  ({Network net, List<String> ring}) teeRing(int k,
      {int? teeAt, int fixtureTee = 0, bool valve = true}) {
    final nodes = <NetNode>[
      _n('H', 0, 0, role: NodeRole.plant),
      _n('F', 100, 0),
      _n('CV', 150, -50, c: valve ? NodeComponent.checkValve : null),
    ];
    final ringIds = <String>[];
    final edges = <NetEdge>[_e('hf', 'H', 'F')];
    var prev = 'F';
    for (var i = 0; i < k; i++) {
      // A rectangle-ish loop: out along y = 100, back to y = 0 at the end.
      final x = 100.0 + 100 * i;
      nodes.add(_n('r$i', x, i == k - 1 ? 0 : 100, role: NodeRole.fixture));
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
    edges
      ..add(_e('xv', tee, 'CV'))
      ..add(_e('vh', 'CV', 'H'));
    return (net: Network(nodes: nodes, edges: edges), ring: ringIds);
  }

  test(
      'ring main with a return teed from a BARE ring tee keeps Hardy–Cross '
      '(probe topology)', () {
    // H -> F, ring F-a-b-X-c-d-F, X bare between b and c, return X -> CV -> H
    // (k = 4 fixtures, tee after the second). Reference (CV a plain node, the
    // Hardy–Cross split at 0.01 m/px): fa 0.1249 / ab 0.0249 / bx 0.0751 /
    // xc 0.0884 / cd 0.0116 / df 0.1116 — the valve used to collapse it to a
    // hop-count tree (bx = xc = 0, flowFromId null): X is bare and off every
    // hop-shortest path, so the walk from the valve deferred both ring
    // segments as zero-draw-off 'returns'.
    final withCv = teeRing(4, teeAt: 1);
    final plain = teeRing(4, teeAt: 1, valve: false);
    final s = sizeCal(withCv.net);
    final p = sizeCal(plain.net);
    for (final id in withCv.ring) {
      expect(s[id]!.flow.inLitersPerSecond,
          closeTo(p[id]!.flow.inLitersPerSecond, 1e-9),
          reason: id);
    }
    // Both sides of the tee carry real flow (not deferred zero 'returns').
    for (final id in ['ex', 'e2']) {
      expect(s[id]!.flow.inLitersPerSecond, greaterThan(0.01), reason: id);
      expect(s[id]!.flowFromId, isNotNull, reason: id);
    }
    // A valve that cuts no loop is solved as if it were not drawn (the
    // Round-13 rule): the heater feed and the valve leg match too.
    for (final id in ['hf', 'xv', 'vh']) {
      expect(s[id]!.flow.inLitersPerSecond,
          closeTo(p[id]!.flow.inLitersPerSecond, 1e-9),
          reason: id);
    }
  });

  test(
      'property: a ring return teed anywhere (bare tee or fixture) keeps the '
      'Hardy–Cross split; a hotel return teed anywhere keeps its tree cut '
      '(seeded)', () {
    final rnd = math.Random(263);
    const sni = SniProfile();
    for (var trial = 0; trial < 30; trial++) {
      // Ring: 3..6 fixtures, tee placement drawn at random.
      final k = 3 + rnd.nextInt(4);
      final bare = rnd.nextBool();
      final teeAt = bare ? rnd.nextInt(k - 1) : null;
      final fixtureTee = rnd.nextInt(k);
      final r = teeRing(k, teeAt: teeAt, fixtureTee: fixtureTee);
      final ref =
          teeRing(k, teeAt: teeAt, fixtureTee: fixtureTee, valve: false);
      final s = sizeCal(Network(
          nodes: r.net.nodes,
          edges: [...r.net.edges]..shuffle(math.Random(trial))));
      final p = sizeCal(ref.net);
      final why = 'trial $trial k=$k teeAt=$teeAt fixtureTee=$fixtureTee';
      for (final id in r.ring) {
        expect(s[id]!.flow.inLitersPerSecond,
            closeTo(p[id]!.flow.inLitersPerSecond, 1e-9),
            reason: '$why $id');
      }

      // Hotel: 2..5 risers, each return top teed from the riser top or a
      // bare tee on the top branch — the return is still a zero-draw-off
      // tree and the supply sizes exactly as with no return drawn.
      final n = 2 + rnd.nextInt(4);
      final tees = {
        for (var i = 0; i < n; i++)
          if (rnd.nextBool()) i,
      };
      final open = _size(_hotel(risers: n, branchTee: tees));
      final hotel = _hotel(risers: n, common: true, branchTee: tees);
      final h = _size(Network(
          nodes: hotel.nodes,
          edges: [...hotel.edges]..shuffle(math.Random(100 + trial))));
      final hwhy = 'trial $trial risers=$n tees=$tees';
      expect(
          h['hm']!.flow.inLitersPerSecond,
          closeTo(
              sni.probableFlowForFixtureUnits(8.0 * n).inLitersPerSecond, 1e-9),
          reason: hwhy);
      for (final id in open.keys) {
        expect(h[id]!.flow.inLitersPerSecond,
            closeTo(open[id]!.flow.inLitersPerSecond, 1e-9),
            reason: '$hwhy $id');
      }
      for (var i = 0; i < n; i++) {
        expect(h['top$i']!.flow.inLitersPerSecond, closeTo(0, 1e-12),
            reason: '$hwhy top$i');
      }
      expect(h['ch']!.flow.inLitersPerSecond, closeTo(0, 1e-12), reason: hwhy);
    }
  });
}
