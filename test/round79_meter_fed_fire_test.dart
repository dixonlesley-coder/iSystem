// Round 79 (2026-10-18) — fire-convergence-30-meter-fed-fire-system-phantom-
// pump-or-false-dry.
//
// A 2-storey kindergarten (3.5 m storeys): WM (water meter, degree 1) -> J
// -> riser R0-R1 with a hose reel on each floor, on the fireHydrant
// service. The meter is the MAINS entry: the system is wet from the mains.
// The verdict, the assumed pump duty and the MDP way must not depend on
// whether a fire-department inlet (FDC) is also teed at J:
//   (a) no FDC  — assumed fire pump at the meter (the Round-50 policy),
//       info `fire-pump-assumed:fireHydrant`, never `no-source`;
//   (b) + FDC   — the SAME: never 'dry' / `brigade-fed` (that was the
//       65.57 m inlet reading — 4.7 m lift + 450 kPa / 9.81 + 15 m — for a
//       system the mains already fills).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/connectivity.dart';
import 'package:mechx_engine/network/network.dart';
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
        id: id, fromId: a, toId: b, service: ServiceType.fireHydrant, kind: k);

Network _kg({required bool fdc}) => Network(nodes: [
      _n('WM', 0, 0, c: NodeComponent.waterMeter),
      _n('J', 100, 0),
      _n('R0', 200, 0),
      _n('R1', 200, 1),
      _n('H0', 300, 0, c: NodeComponent.hoseReel),
      _n('H1', 300, 1, c: NodeComponent.hoseReel),
      if (fdc) _n('FDC', 100, 0, c: NodeComponent.fireDeptConnection),
    ], edges: [
      _e('wm', 'WM', 'J'),
      _e('jr', 'J', 'R0'),
      _e('r', 'R0', 'R1', k: EdgeKind.riser),
      _e('h0', 'R0', 'H0'),
      _e('h1', 'R1', 'H1'),
      if (fdc) _e('fd', 'FDC', 'J'),
    ]);

ProviderContainer _c(Network net) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < 2; i++) Floor('L$i', const Length(3.5))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

void main() {
  test('engine: a meter-fed fire network is mains-fed, with or without FDC',
      () {
    for (final fdc in [false, true]) {
      final d = networkConnectivityDefects(_kg(fdc: fdc));
      expect(d.where((x) => x.service == ServiceType.fireHydrant).map((x) => x.kind),
          [NetworkDefectKind.mainsFed],
          reason: 'fdc $fdc');
    }
  });

  test('an FDC never flips a meter-fed system to dry', () {
    final a = _c(_kg(fdc: false));
    final b = _c(_kg(fdc: true));
    final ba = a.read(fireSystemBasesProvider).single;
    final bb = b.read(fireSystemBasesProvider).single;
    expect(ba.dry, isFalse);
    expect(bb.dry, isFalse);
    expect(ba.duty, isNotNull);
    expect(bb.duty!.selectedMotor.watts, ba.duty!.selectedMotor.watts);
    expect(bb.duty!.head.meters, closeTo(ba.duty!.head.meters, 1e-9));
    // The same life-safety way on the MDP, either way.
    expect(b.read(firePumpDutyProvider)?.selectedMotor.watts,
        a.read(firePumpDutyProvider)?.selectedMotor.watts);
    for (final c in [a, b]) {
      final kinds = c.read(designIssuesProvider).map((i) => i.kind).toList();
      expect(kinds, contains('fire-pump-assumed:fireHydrant'));
      expect(kinds.where((k) => k.startsWith('no-source:')), isEmpty);
      expect(kinds.where((k) => k.startsWith('brigade-fed:')), isEmpty);
    }
    expect(a.read(mepDutyBindingProvider), isNotNull);
  });

  test('an FDC-only system (no meter) stays dry / brigade-fed', () {
    final net = Network(nodes: [
      _n('FDC', 0, 0, c: NodeComponent.fireDeptConnection),
      _n('J', 100, 0),
      _n('R0', 200, 0),
      _n('R1', 200, 1),
      _n('H0', 300, 0, c: NodeComponent.hoseReel),
      _n('H1', 300, 1, c: NodeComponent.hoseReel),
    ], edges: [
      _e('fd', 'FDC', 'J'),
      _e('jr', 'J', 'R0'),
      _e('r', 'R0', 'R1', k: EdgeKind.riser),
      _e('h0', 'R0', 'H0'),
      _e('h1', 'R1', 'H1'),
    ]);
    final c = _c(net);
    expect(c.read(fireSystemBasesProvider).single.dry, isTrue);
    expect(c.read(designIssuesProvider).map((i) => i.kind),
        contains('brigade-fed:FDC'));
  });
}
