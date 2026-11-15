// Round 70 (fire-convergence-22-intermediate-zone-room-filling-next-break-
// tank-rated-on-own-zone-only) — a 45 x 4 m tower, three zones:
//
//   GT (L0) -> P1 -> riser t1 -> BT1 (ground tank, L15)        transfer room
//   BT1 -> P2 -> H2; zone 2 off H2 (L15..L29) + riser t2 -> BT2 (roof tank,
//   L30)                                                      zone + fill room
//   BT2 -> P3 -> zone 3 hydrant boxes L30..L44 (one Class I stack)
//
// When zone 3 is on fire P2 must lift the whole zone-3 flow into BT2 and P1
// must lift it into BT1, so (first principles):
//  * zone 3: one Class I stack = 500 gpm = 31.545 L/s;
//  * P2 is rated on max(own zone, fill) flow = 31.545 L/s (max, never the
//    sum: one fire event) at max(its zone head, lift to BT2 + friction);
//  * P1 (transfer) on the zone it ultimately fills, 31.545 L/s;
//  * NFPA 20 Table 4.28(a), 500 gpm ⇒ DN125 suction AND discharge for both
//    P1 and P2 (g, t1, s2, d2 >= DN125 at 31.545 L/s);
//  * whether zone 2 is hose reels (Class II, 100 gpm) or hydrant boxes
//    (Class I) the fill governs — the same P1 / P2 flows.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart' show standpipeFlow;
import 'package:mechx_engine/units.dart';

NetNode _n(String id, double x, int floor, {NodeComponent? c}) => NetNode(
  id: id,
  sheetId: 's1',
  x: x,
  y: 0,
  floorIndex: floor,
  role: c?.role ?? NodeRole.main,
  component: c,
);

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
      id: id,
      fromId: a,
      toId: b,
      service: ServiceType.fireHydrant,
      kind: k,
    );

Network _tower({
  required bool reels,
  NodeComponent bt1 = NodeComponent.groundTank,
  NodeComponent bt2 = NodeComponent.roofTank,
}) {
  final nodes = <NetNode>[
    _n('GT', 0, 0, c: NodeComponent.groundTank),
    _n('P1', 50, 0, c: NodeComponent.pump),
    _n('X0', 100, 0),
    for (var f = 1; f <= 15; f++) _n('X$f', 100, f),
    _n('BT1', 150, 15, c: bt1),
    _n('P2', 200, 15, c: NodeComponent.pump),
    _n('H2', 250, 15),
    for (var f = 16; f <= 29; f++) _n('Z$f', 300, f),
    for (var f = 15; f <= 29; f++)
      _n(
        'O$f',
        350,
        f,
        c: reels ? NodeComponent.hoseReel : NodeComponent.hydrantBox,
      ),
    for (var f = 16; f <= 30; f++) _n('T$f', 400, f),
    _n('BT2', 450, 30, c: bt2),
    _n('P3', 500, 30, c: NodeComponent.pump),
    _n('W30', 550, 30),
    for (var f = 31; f <= 44; f++) _n('W$f', 550, f),
    for (var f = 30; f <= 44; f++)
      _n('B$f', 600, f, c: NodeComponent.hydrantBox),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'P1'),
    _e('t1', 'P1', 'X0'),
    for (var f = 1; f <= 15; f++)
      _e('x$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser),
    _e('i1', 'X15', 'BT1'),
    _e('s2', 'BT1', 'P2'),
    _e('d2', 'P2', 'H2'),
    // Zone 2: a riser off H2 with an outlet per storey.
    _e('o15', 'H2', 'O15'),
    _e('z16', 'H2', 'Z16', k: EdgeKind.riser),
    for (var f = 17; f <= 29; f++)
      _e('z$f', 'Z${f - 1}', 'Z$f', k: EdgeKind.riser),
    for (var f = 16; f <= 29; f++) _e('o$f', 'Z$f', 'O$f'),
    // The fill riser t2 to BT2.
    _e('t2', 'H2', 'T16', k: EdgeKind.riser),
    for (var f = 17; f <= 30; f++)
      _e('t$f', 'T${f - 1}', 'T$f', k: EdgeKind.riser),
    _e('i2', 'T30', 'BT2'),
    // Zone 3.
    _e('s3', 'BT2', 'P3'),
    _e('d3', 'P3', 'W30'),
    for (var f = 31; f <= 44; f++)
      _e('w$f', 'W${f - 1}', 'W$f', k: EdgeKind.riser),
    for (var f = 30; f <= 44; f++) _e('b$f', 'W$f', 'B$f'),
  ];
  return Network(nodes: nodes, edges: edges);
}

ProviderContainer _c(Network net) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < 45; i++) Floor('L$i', const Length(4))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

void main() {
  final q500 = standpipeFlow(1).cubicMetersPerSecond; // 31.545 L/s

  FireSystemBasis basisOf(ProviderContainer c, String pump) => c
      .read(fireSystemBasesProvider)
      .firstWhere((b) => b.pumpIds.contains(pump));

  for (final reels in [true, false]) {
    test('zone 2 ${reels ? 'hose reels' : 'hydrant boxes'}: P1 and P2 '
        'carry the zone-3 fill flow on DN125', () {
      final c = _c(_tower(reels: reels));
      for (final p in ['P1', 'P2', 'P3']) {
        expect(
          basisOf(c, p).flow.cubicMetersPerSecond,
          closeTo(q500, 1e-6),
          reason: '$p rated flow',
        );
      }
      // P2's head covers at least the static lift to BT2 (15 storeys x 4 m).
      expect(basisOf(c, 'P2').head.meters, greaterThanOrEqualTo(60.0));
      final sz = c.read(sizingProvider);
      for (final id in ['g', 't1', 's2', 'd2']) {
        expect(
          sz[id]!.diameter.inMillimeters,
          greaterThanOrEqualTo(125),
          reason: '$id DN',
        );
        expect(
          sz[id]!.flow.cubicMetersPerSecond,
          greaterThanOrEqualTo(q500 - 1e-6),
          reason: '$id flow',
        );
      }
      // Into H2 >= out of it on the fill branch (max, never the sum).
      expect(
        sz['d2']!.flow.cubicMetersPerSecond,
        greaterThanOrEqualTo(sz['t2']!.flow.cubicMetersPerSecond - 1e-9),
      );
    });
  }

  // Round 71 (regression-2 / regression-3) — a break tank typed 'Roof tank'
  // below the top storey (BT2 on L30 of 45, BT1 on L15) read the 180 m roof
  // in `nodeElevation`: P2 was rated to fill a tank 'at the roof' (141.9 m
  // where its own zone governs at ~120.4 m), and a roof-typed BT1 dropped
  // out of the transfer / fill destination test (z > pump z with z = 180 m on
  // the wrong side), rating P1 / P2 at 6.3 L/s on DN50 with a 293 m P1 head.
  // A roof-typed tank below the top storey now sits on its own floor, so
  // every tank-type combination rates the SAME as the ground-typed drawing:
  //  * P1 lifts 60 m to BT1 (15 x 4) + its train friction (~71.7 m);
  //  * P2 = max(own zone 2 head, 60 m lift to BT2 + fill friction) — its
  //    own zone governs (~120.4 m), never a lift to the 180 m roof;
  //  * every pump on 31.545 L/s, the trains on DN125.
  for (final reels in [true, false]) {
    test('zone 2 ${reels ? 'hose reels' : 'hydrant boxes'}: every BT1 / BT2 '
        'tank type rates P1 / P2 / P3 like the ground-typed tower', () {
      Map<String, (double, double)> rate(NodeComponent b1, NodeComponent b2) {
        final c = _c(_tower(reels: reels, bt1: b1, bt2: b2));
        return {
          for (final p in ['P1', 'P2', 'P3'])
            p: (
              basisOf(c, p).flow.cubicMetersPerSecond,
              basisOf(c, p).head.meters,
            ),
        };
      }

      Map<String, (double, double)> sizes(NodeComponent b1, NodeComponent b2) {
        final sz = _c(
          _tower(reels: reels, bt1: b1, bt2: b2),
        ).read(sizingProvider);
        return {
          for (final id in ['g', 't1', 's2', 'd2', 't2', 'i2'])
            id: (
              sz[id]!.diameter.inMillimeters,
              sz[id]!.flow.cubicMetersPerSecond,
            ),
        };
      }

      const g = NodeComponent.groundTank, r = NodeComponent.roofTank;
      final base = rate(g, g);
      final baseSz = sizes(g, g);
      // The ground-typed tower: P1 lifts BT1's 60 m plus train friction;
      // P2's own zone governs above the 60 m lift to BT2.
      // P1: 60 m static lift to BT1 + the sized train friction = 71.67 m.
      expect(base['P1']!.$2, closeTo(71.67, 0.01));
      // P2 with hose reels: its own Class II zone governs (120.33 m; 120.39
      // before backlog D-1 put each reel at its 1.2 m hose-outlet height, a
      // 0.1 m shorter reel leg) over the
      // fill (60 m + friction); with hydrant boxes its Class I zone governs
      // higher still — never a lift to the 180 m roof.
      expect(base['P2']!.$2, greaterThan(60.0 + 11.0));
      if (reels) expect(base['P2']!.$2, closeTo(120.33, 0.01));
      for (final p in ['P1', 'P2', 'P3']) {
        expect(base[p]!.$1, closeTo(q500, 1e-6), reason: '$p flow');
      }
      for (final (b1, b2) in [(g, r), (r, g), (r, r)]) {
        final why = 'BT1 ${b1.name} BT2 ${b2.name}';
        final got = rate(b1, b2);
        for (final p in ['P1', 'P2', 'P3']) {
          expect(got[p]!.$1, closeTo(base[p]!.$1, 1e-9), reason: '$why $p Q');
          expect(got[p]!.$2, closeTo(base[p]!.$2, 1e-6), reason: '$why $p H');
        }
        final sz = sizes(b1, b2);
        for (final id in baseSz.keys) {
          expect(sz[id]!.$1, baseSz[id]!.$1, reason: '$why $id DN');
          expect(
            sz[id]!.$2,
            closeTo(baseSz[id]!.$2, 1e-9),
            reason: '$why $id flow',
          );
        }
        for (final id in ['g', 't1', 's2', 'd2']) {
          expect(sz[id]!.$1, greaterThanOrEqualTo(125), reason: '$why $id');
        }
      }
      // The fill riser to BT2 carries the zone-3 fill on DN100 (t2).
      expect(baseSz['t2']!.$1, 100);
      expect(baseSz['t2']!.$2, closeTo(q500, 1e-6));
    });
  }
}
