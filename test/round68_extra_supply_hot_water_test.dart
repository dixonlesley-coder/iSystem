// Round 68 (2026-10-18) — plumbing-hvac-convergence-18-extra-supply-network-
// hot-water-unsolved: a second cold-water network (a podium beside the
// roof-tank tower, the Round-67 extra component) solves its HOT water too.
//
// Drawing (20 storeys x 3.5 m, 0.01 m/px): podium GT -> BS -> riser M0..M5,
// a lavatory V0..V5 per storey, heater WH fed M0 -> WH (cold), a 30 m hot
// run WH -> H0, hot riser H0..H5, a shower SH0..SH5 per storey. Tower: RT on
// L19 -> riser R19..R6, a lavatory per storey.
//
// First principles: the hot index shower SH5 needs the target residual
// (225 kPa) at its outlet; its supply passes the heater, so the booster head
// = max(cold critical, cold path to WH + hot critical) — the Round-55 rule
// the primary solve applies. That figure is the podium's own: it can never
// depend on a separate tower drawn beside it, so the booster head beside the
// tower must equal the podium-alone head, and SH5 must be solved (present in
// the residual field and the heatmap delivery set) at 225 kPa.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(
  String id,
  double x,
  double y, {
  int floor = 0,
  NodeRole role = NodeRole.main,
  NodeComponent? c,
  PlumbingFixture? fixture,
}) => NetNode(
  id: id,
  sheetId: 's1',
  x: x,
  y: y,
  floorIndex: floor,
  role: role,
  component: c,
  fixture: fixture,
);

NetEdge _e(
  String id,
  String a,
  String b, {
  EdgeKind k = EdgeKind.run,
  ServiceType s = ServiceType.coldWater,
}) => NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

NetNode _fix(String id, double x, double y, int floor, PlumbingFixture f) =>
    _n(id, x, y, floor: floor, role: NodeRole.fixture, fixture: f);

(List<NetNode>, List<NetEdge>) _podium() => (
  [
    _n('GT', 0, 400, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('BS', 50, 400, role: NodeRole.plant, c: NodeComponent.boosterSet),
    _n('WH', 100, 300, role: NodeRole.plant),
    for (var f = 0; f <= 5; f++) ...[
      _n('M$f', 100, 400, floor: f),
      _fix('V$f', 200, 400, f, PlumbingFixture.lavatory),
      _n('H$f', 3100, 300, floor: f),
      _fix('SH$f', 3200, 300, f, PlumbingFixture.shower),
    ],
  ],
  [
    _e('g', 'GT', 'BS'),
    _e('b', 'BS', 'M0'),
    for (var f = 1; f <= 5; f++)
      _e('m$f', 'M${f - 1}', 'M$f', k: EdgeKind.riser),
    for (var f = 0; f <= 5; f++) _e('v$f', 'M$f', 'V$f'),
    _e('wh', 'M0', 'WH'),
    _e('hr', 'WH', 'H0', s: ServiceType.hotWater),
    for (var f = 1; f <= 5; f++)
      _e('h$f', 'H${f - 1}', 'H$f',
          k: EdgeKind.riser, s: ServiceType.hotWater),
    for (var f = 0; f <= 5; f++)
      _e('sh$f', 'H$f', 'SH$f', s: ServiceType.hotWater),
  ],
);

(List<NetNode>, List<NetEdge>) _tower() => (
  [
    _n('RT', 0, 0, floor: 19, role: NodeRole.plant, c: NodeComponent.roofTank),
    for (var f = 6; f <= 19; f++) ...[
      _n('R$f', 100, 0, floor: f),
      _fix('W$f', 200, 0, f, PlumbingFixture.lavatory),
    ],
  ],
  [
    _e('rt', 'RT', 'R19'),
    for (var f = 19; f > 6; f--)
      _e('r$f', 'R$f', 'R${f - 1}', k: EdgeKind.riser),
    for (var f = 6; f <= 19; f++) _e('w$f', 'R$f', 'W$f'),
  ],
);

ProviderContainer _solve(
    List<(List<NetNode>, List<NetEdge>)> parts, FeedStrategy feed) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < 20; i++) Floor('L$i', const Length(3.5))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(feedStrategyProvider.notifier).set(feed);
  c.read(networkControllerProvider.notifier).loadNetwork(Network(
        nodes: [for (final p in parts) ...p.$1],
        edges: [for (final p in parts) ...p.$2],
      ));
  return c;
}

void main() {
  test('the podium alone: the hot index shower governs the booster', () {
    final alone = _solve([_podium()], FeedStrategy.upfeed);
    final head = alone.read(supplyMoverDutiesProvider)['BS']!.head.meters;
    final res = alone.read(residualByNodeProvider);
    expect(res['SH5']!.inKiloPascals, closeTo(225.0, 0.5));
    // Hot governs: the cold top lavatory sits above the target.
    expect(res['V5']!.inKiloPascals, greaterThan(225.0));
    expect(head, greaterThan(0));
  });

  for (final feed in [FeedStrategy.upfeed, FeedStrategy.downfeed]) {
    test('$feed beside the tower: BS head + hot field == the podium alone',
        () {
      final alone = _solve([_podium()], FeedStrategy.upfeed);
      final aloneHead =
          alone.read(supplyMoverDutiesProvider)['BS']!.head.meters;
      final mixed = _solve([_tower(), _podium()], feed);
      final head = mixed.read(supplyMoverDutiesProvider)['BS']!.head.meters;
      expect(head, closeTo(aloneHead, 1e-6));
      final res = mixed.read(residualByNodeProvider);
      final aloneRes = alone.read(residualByNodeProvider);
      for (final id in ['SH0', 'SH5', 'V5']) {
        expect(res[id], isNotNull, reason: '$id solved');
        expect(res[id]!.inKiloPascals,
            closeTo(aloneRes[id]!.inKiloPascals, 1e-6),
            reason: id);
      }
      expect(res['SH5']!.inKiloPascals, closeTo(225.0, 0.5));
      final delivery = mixed.read(heatmapDeliveryNodeIdsProvider);
      expect(delivery, containsAll(['SH0', 'SH5']));
    });
  }
}
