// Round 29 (2026-10-18) — the app-side findings:
//
//   regression-report-standpipe-head-contradicts-rated-head   the calc
//     report's standpipe line prints the governing hydrant system's
//     friction-inclusive design (the head the fire-pump rating uses).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/document_control_store.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

ProviderContainer _c() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

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
        {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.fireHydrant, kind: k);

/// 8 storeys x 4 m, calibrated at 0.01 m/px when [cal]; GT -> HP -> a 200 m
/// main -> an 8-storey hydrant stack with a hose box per floor.
void _seedTower(ProviderContainer c, {required bool cal}) {
  final p = c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < 8; i++) Floor('L$i', const Length(4))]);
  if (cal) p.setCalibration('s1', const ScaleCalibration(0.01));
  c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
    _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('HP', 50, 0, role: NodeRole.plant, c: NodeComponent.pump),
    for (var f = 0; f < 8; f++) ...[
      _n('S$f', 20050, 0, floor: f),
      _n('HB$f', 20100, 0,
          floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
    ],
  ], edges: [
    _e('g', 'GT', 'HP'),
    _e('h', 'HP', 'S0'),
    for (var f = 0; f < 8; f++) ...[
      _e('b$f', 'S$f', 'HB$f'),
      if (f > 0) _e('r$f', 'S${f - 1}', 'S$f', k: EdgeKind.riser),
    ],
  ]));
}

void main() {
  group('report standpipe line == the rated fire-pump head', () {
    test(
        'calibrated 200 m main: the printed standpipe head carries the sized '
        'index friction (= the rated head), not the 15 m allowance', () {
      final c = _c();
      _seedTower(c, cal: true);
      final printed = c.read(reportStandpipeDesignProvider);
      final rated = c.read(fireRatedPointProvider);
      final allowance = c.read(standpipeDesignProvider);
      final basis = c.read(firePumpBasisByNodeProvider)['HP']!;
      // First principles: head = lift + residual + max(15 m, friction), so
      // the printed head exceeds the allowance basis by exactly friction - 15.
      final f = basis.indexFrictionM!;
      expect(f, greaterThan(15));
      expect(printed.pumpHead.meters, closeTo(rated.head.meters, 1e-9));
      expect(printed.pumpHead.meters - allowance.pumpHead.meters,
          closeTo(f - 15, 1e-6));
      expect(printed.requiredFlow.cubicMetersPerSecond,
          closeTo(rated.flow.cubicMetersPerSecond, 1e-12));
    });

    test('uncalibrated: no friction measured, the allowance design prints',
        () {
      final c = _c();
      _seedTower(c, cal: false);
      expect(c.read(reportStandpipeDesignProvider).pumpHead.meters,
          closeTo(c.read(standpipeDesignProvider).pumpHead.meters, 1e-9));
    });
  });

  test(
      "regression-settings-undo: a signatory literally named 'null' over an "
      'empty field is a real edit (null no longer encodes as the string)', () {
    final c = _c();
    final ctrl = c.read(documentControlProvider.notifier);
    ctrl.setClientName('null');
    expect(c.read(documentControlProvider).clientName, 'null');
    c.read(historyProvider.notifier).undo();
    expect(c.read(documentControlProvider).clientName, isNull);
  });
}
