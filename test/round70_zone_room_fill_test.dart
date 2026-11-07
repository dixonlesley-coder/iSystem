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

Network _tower({required bool reels}) {
  final nodes = <NetNode>[
    _n('GT', 0, 0, c: NodeComponent.groundTank),
    _n('P1', 50, 0, c: NodeComponent.pump),
    _n('X0', 100, 0),
    for (var f = 1; f <= 15; f++) _n('X$f', 100, f),
    _n('BT1', 150, 15, c: NodeComponent.groundTank),
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
    _n('BT2', 450, 30, c: NodeComponent.roofTank),
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
        expect(sz[id]!.diameter.inMillimeters, greaterThanOrEqualTo(125),
            reason: '$id DN');
        expect(sz[id]!.flow.cubicMetersPerSecond,
            greaterThanOrEqualTo(q500 - 1e-6),
            reason: '$id flow');
      }
      // Into H2 >= out of it on the fill branch (max, never the sum).
      expect(
        sz['d2']!.flow.cubicMetersPerSecond,
        greaterThanOrEqualTo(sz['t2']!.flow.cubicMetersPerSecond - 1e-9),
      );
    });
  }
}
