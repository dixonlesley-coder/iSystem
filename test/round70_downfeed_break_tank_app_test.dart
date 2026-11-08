// Round 70 (plumbing-hvac-convergence-20-downfeed-break-tank-ignored) — the
// standard Indonesian highrise downfeed: GT (L0) -> TP1 -> riser -> BT
// (ground tank, L20, 70 m) -> TP2 -> riser -> RT (roof tank, L39). BT feeds
// a riser with a lavatory on L1..L20, RT one on L21..L39.
//
// First principles: a storage tank is a free water surface — the pressure
// below it restarts from its own elevation. 40 x 3.5 m, fixture height
// 1.1 m:
//  * WB10 static = (70 - 36.1) x 9.80665 = 332 kPa: under the 392 kPa SNI
//    8153 limit, so no over-pressure on L10..L19;
//  * WB1 static = (70 - 4.6) x 9.80665 = 641 kPa: over (from 70 m, never
//    the roof tank's 140 m);
//  * BT's tank-fed zone admits f while 70 - fixture(f) <= 39.96 m
//    (392 kPa of head): fixture(f) >= 30.04 => f >= 9 => zone (20, 9); the
//    floors below take PRV zones.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart' show headFromPressure;
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(
  String id,
  double x,
  int floor, {
  NodeRole role = NodeRole.main,
  NodeComponent? c,
  PlumbingFixture? fx,
}) => NetNode(
  id: id,
  sheetId: 's1',
  x: x,
  y: 0,
  floorIndex: floor,
  role: role,
  component: c,
  fixture: fx,
);

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: ServiceType.coldWater, kind: k);

Network _tower() => Network(
  nodes: [
    _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('TP1', 20, 0, role: NodeRole.plant, c: NodeComponent.pump),
    for (var f = 0; f <= 20; f++) _n('U$f', 40, f),
    _n('BT', 60, 20, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('TP2', 80, 20, role: NodeRole.plant, c: NodeComponent.pump),
    for (var f = 20; f <= 39; f++) _n('V$f', 100, f),
    for (var f = 1; f <= 20; f++) ...[
      _n('L$f', 140, f),
      _n('WB$f', 160, f, role: NodeRole.fixture, fx: PlumbingFixture.lavatory),
    ],
    _n('RT', 200, 39, role: NodeRole.plant, c: NodeComponent.roofTank),
    for (var f = 21; f <= 39; f++) ...[
      _n('R$f', 220, f),
      _n('WR$f', 240, f, role: NodeRole.fixture, fx: PlumbingFixture.lavatory),
    ],
  ],
  edges: [
    _e('g', 'GT', 'TP1'),
    _e('t0', 'TP1', 'U0'),
    for (var f = 1; f <= 20; f++)
      _e('u$f', 'U${f - 1}', 'U$f', k: EdgeKind.riser),
    _e('ub', 'U20', 'BT'),
    _e('b2', 'BT', 'TP2'),
    _e('v0', 'TP2', 'V20'),
    for (var f = 21; f <= 39; f++)
      _e('v$f', 'V${f - 1}', 'V$f', k: EdgeKind.riser),
    _e('vr', 'V39', 'RT'),
    _e('l20', 'BT', 'L20'),
    for (var f = 19; f >= 1; f--)
      _e('l$f', 'L${f + 1}', 'L$f', k: EdgeKind.riser),
    for (var f = 1; f <= 20; f++) _e('w$f', 'L$f', 'WB$f'),
    _e('r39', 'RT', 'R39'),
    for (var f = 38; f >= 21; f--)
      _e('r$f', 'R${f + 1}', 'R$f', k: EdgeKind.riser),
    for (var f = 21; f <= 39; f++) _e('x$f', 'R$f', 'WR$f'),
  ],
);

ProviderContainer _c() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < 40; i++) Floor('L$i', const Length(3.5))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
  c.read(networkControllerProvider.notifier).loadNetwork(_tower());
  return c;
}

void main() {
  test('BT-fed floors are judged from the break tank', () {
    final c = _c();
    final b = c.read(projectControllerProvider).building;
    final m = c.read(projectControllerProvider).mounting;
    double kpa(double h) => h * 9.80665;
    final sol = c.read(downfeedDeliveredProvider)!;
    final wb10 = 70.0 - b.fixtureElevationOf(10, m).meters;
    expect(
      sol.noFlowStaticPressure['WB10']!.inKiloPascals,
      closeTo(kpa(wb10), 0.5),
    );
    final wb1 = 70.0 - b.fixtureElevationOf(1, m).meters;
    expect(
      sol.noFlowStaticPressure['WB1']!.inKiloPascals,
      closeTo(kpa(wb1), 0.5),
    );
    // No over-pressure on L10..L19 (each within 392 kPa from BT's 70 m).
    final over = {
      for (final o in c.read(downfeedOverPressureProvider)) o.nodeId,
    };
    for (var f = 10; f <= 19; f++) {
      expect(over.contains('WB$f'), isFalse, reason: 'WB$f');
    }
    expect(over.contains('WB1'), isTrue);
  });

  test('BT zone table hangs from the 70 m datum', () {
    final c = _c();
    final groups = c.read(downfeedZoneGroupsProvider);
    final bt = groups.firstWhere((g) => g.tankId == 'BT');
    expect(bt.tankElevation!.meters, closeTo(70.0, 1e-9));
    final b = c.read(projectControllerProvider).building;
    final m = c.read(projectControllerProvider).mounting;
    final limitHead = headFromPressure(
      const SniProfile().maxFixtureStaticPressure.value,
    ).meters;
    // The tank-fed zone: from L20 down while 70 - fixture(f) <= limit.
    var bottom = 20;
    for (var f = 19; f >= 1; f--) {
      if (70.0 - b.fixtureElevationOf(f, m).meters > limitHead) break;
      bottom = f;
    }
    expect(bottom, 9);
    expect(bt.zones.first.topFloorIndex, 20);
    expect(bt.zones.first.bottomFloorIndex, bottom);
    // The BT zones cover L1..L20 only; the RT group never reaches below L21.
    expect(bt.zones.last.bottomFloorIndex, 1);
    final rt = groups.firstWhere((g) => g.tankId == 'RT');
    for (final z in rt.zones) {
      expect(z.bottomFloorIndex, greaterThanOrEqualTo(21));
    }
  });
}
