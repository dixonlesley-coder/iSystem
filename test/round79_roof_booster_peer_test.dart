// Round 79 (2026-10-18) — regression-roof-booster-peer-rated-with-datum-lift.
//
// 10 storeys x 3.5 m, calibrated. Ground room: GA (ground tank, L0) -> PA ->
// X0, a riser X0..X9 with a hydrant box on every floor. Roof: RT (roof tank,
// L9) -> PB -> X9. The Round-78 merge reads the two rooms as ONE root stage
// (peer rooms into one network).
//
// First principles: PA lifts from the L0 datum to the top hose outlet
// (9 x 3.5 + 1.2 = 32.7 m) + the Class I 690 kPa residual (70.34 m) + the
// 15 m allowance => ~118 m. PB draws from a tank AT THE ROOF (nodeElevation
// = 35.0 m above the datum): it never lifts that 35 m, so it develops
// 118 − 35 = ~83 m. At the 500 gpm (31.5 L/s) standpipe flow:
// 0.0315 x 9810 x 83 / 0.7 = 36.6 kW shaft => a 45 kW frame, not PA's 75 kW.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(String id, double x, double y, int floor, {NodeComponent? c}) =>
    NetNode(
      id: id,
      sheetId: 's1',
      x: x,
      y: y,
      floorIndex: floor,
      role: c?.role ?? NodeRole.main,
      component: c,
    );

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: ServiceType.fireHydrant, kind: k);

Network _tower({bool roofRoom = true}) {
  final nodes = <NetNode>[
    _n('GA', 0, 0, 0, c: NodeComponent.groundTank),
    _n('PA', 100, 0, 0, c: NodeComponent.pump),
  ];
  final edges = <NetEdge>[_e('ga', 'GA', 'PA'), _e('pa', 'PA', 'X0')];
  for (var f = 0; f < 10; f++) {
    nodes
      ..add(_n('X$f', 200, 0, f))
      ..add(_n('B$f', 300, 0, f, c: NodeComponent.hydrantBox));
    edges.add(_e('b$f', 'X$f', 'B$f'));
    if (f > 0) edges.add(_e('x$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser));
  }
  if (roofRoom) {
    nodes
      ..add(_n('RT', 0, 200, 9, c: NodeComponent.roofTank))
      ..add(_n('PB', 100, 200, 9, c: NodeComponent.pump));
    edges
      ..add(_e('rt', 'RT', 'PB'))
      ..add(_e('pb', 'PB', 'X9'));
  }
  return Network(nodes: nodes, edges: edges);
}

ProviderContainer _c(Network net) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < 10; i++) Floor('L$i', const Length(3.5))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

void main() {
  test('the roof booster is rated above its own roof tank', () {
    final c = _c(_tower());
    final b = c
        .read(fireSystemBasesProvider)
        .where((x) => x.pumpIds.isNotEmpty)
        .single;
    expect(b.pumpIds, unorderedEquals(['PA', 'PB']));
    final rtZ = nodeElevation(
            c.read(networkControllerProvider).network.nodeById('RT')!,
            c.read(projectControllerProvider).building)
        .meters;
    expect(rtZ, closeTo(35.0, 1e-9)); // the roof: 10 x 3.5 m
    // PA keeps the full system head; PB that head less the 35 m rise.
    expect(b.stageHeads['PA'], isNull);
    expect(b.dutyFor('PA')!.head.meters, closeTo(b.head.meters, 1e-9));
    expect(b.stageHeads['PB']!.meters, closeTo(b.head.meters - rtZ, 1e-9));
    final duties = c.read(equipmentNodeDutiesProvider);
    final pa = duties['PA']!.motor.watts, pb = duties['PB']!.motor.watts;
    // 31.5 L/s x 9810 x (head − 35) / 0.7 shaft, never the full-head frame.
    expect(pb, greaterThanOrEqualTo(
        b.flow.cubicMetersPerSecond * 9810 * (b.head.meters - rtZ) / 0.7));
    expect(pb, lessThanOrEqualTo(45000));
    expect(pa, greaterThan(pb));
  });

  test('a single ground room keeps the full head (no stage entry)', () {
    final c = _c(_tower(roofRoom: false));
    final b = c
        .read(fireSystemBasesProvider)
        .where((x) => x.pumpIds.isNotEmpty)
        .single;
    expect(b.stageHeads, isEmpty);
    expect(b.dutyFor('PA')!.head.meters, closeTo(b.head.meters, 1e-9));
  });
}
