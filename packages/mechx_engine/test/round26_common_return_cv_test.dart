/// Round 26 (hot-water-2-common-return-cv-hardy-cross) — several riser
/// returns joined on a common header, then ONE check valve + circulator back
/// to the heater (the usual hotel recirculation). Cutting the valve alone
/// leaves the supply-riser / return-riser ring, which used to fall to
/// Hardy–Cross and route draw-off up the returns. The return side (edges on no
/// shortest root -> draw-off path) is now deferred with the valve, so the
/// supply sizes exactly as with no return drawn and every return carries 0.
library;

import 'dart:math' as math;

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
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.hotWater, kind: k);

/// Heater H -> M -> [risers] supply risers of 4 floors, a 2-UBAP fixture at
/// each floor node. With [common], each riser top runs down a return riser to
/// a shared header RJ -> CV -> H; [perRiser] puts a CV in every return
/// instead (the Round-12 topology, the reference answer).
Network _hotel({int risers = 2, bool common = false, bool perRiser = false}) {
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
      edges.add(_e('b${r}_$f', 'S${r}_$f', 'fx${r}_$f'));
      edges.add(f == 0
          ? _e('m$r', 'M', 'S${r}_0')
          : _e('s${r}_$f', 'S${r}_${f - 1}', 'S${r}_$f', k: EdgeKind.riser));
    }
    if (common || perRiser) {
      for (var f = 0; f < 4; f++) {
        nodes.add(_n('R${r}_$f', x + 20, 0, floor: f));
      }
      edges.add(_e('top$r', 'S${r}_3', 'R${r}_3'));
      for (var f = 3; f >= 1; f--) {
        edges.add(_e('r${r}_$f', 'R${r}_$f', 'R${r}_${f - 1}',
            k: EdgeKind.riser));
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
      expect(common[id]!.diameter.inMillimeters,
          open[id]!.diameter.inMillimeters,
          reason: id);
    }
    // No draw-off through any return edge or the valve.
    for (final id in ['jc', 'ch', 'rj0', 'rj1', 'top0', 'top1', 'r0_1']) {
      expect(common[id]!.flow.inLitersPerSecond, closeTo(0, 1e-12),
          reason: id);
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
      expect(s['hm']!.flow.inLitersPerSecond,
          closeTo(sni.probableFlowForFixtureUnits(8.0 * n).inLitersPerSecond,
              1e-9),
          reason: 'trial $trial, $n risers');
      expect(s['ch']!.flow.inLitersPerSecond, closeTo(0, 1e-12),
          reason: 'trial $trial');
    }
  });
}
