// Round 67 (2026-10-18) — a SECOND cold-water network (a booster-fed podium
// beside a roof-tank tower) is solved from its own source.
//
//   plumbing-hvac-convergence-17-second-supply-network-mover-unsized
//       the podium booster gets a duty (never the 3.0 kW component default)
//       and its fixtures are pressure-judged
//   plumbing-hvac-convergence-17-phantom-prv-zones-on-booster-fed-podium
//       the downfeed PRV zone table only counts floors the roof tank feeds
//
// The drawing: 20 storeys of 3.5 m. Tower: a roof tank RT on L19 feeds a riser
// R19 .. R6 with one fixture W6 .. W19 per storey. Podium, NOT connected to
// the tower: a ground tank GT -> booster set BS -> riser M0 .. M5 with one
// fixture V0 .. V5 per storey.
//
// First principles. The podium's open ground tank develops no head: its
// zero-head residual at the L5 fixture is roughly -(rho g x lift) less its
// friction, so a booster must add at least the target residual (225 kPa ==
// 22.94 m of water) plus the lift to the L5 fixture (5 x 3.5 m + its fixture
// height) — a head > 22.94 + 17.5 = 40.4 m, and never 0. The tower alone
// gives a zone table that only depends on the tower's tank + its lowest
// fixture (L6): adding a podium the tank never reaches cannot move it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

ProviderContainer _c() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

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

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
      id: id,
      fromId: a,
      toId: b,
      service: ServiceType.coldWater,
      kind: k,
    );

Network _drawing({required bool podium}) => Network(
  nodes: [
    _n('RT', 0, 0, floor: 19, role: NodeRole.plant, c: NodeComponent.roofTank),
    for (var f = 6; f <= 19; f++) ...[
      _n('R$f', 100, 0, floor: f),
      _n(
        'W$f',
        200,
        0,
        floor: f,
        role: NodeRole.fixture,
        fixture: PlumbingFixture.lavatory,
      ),
    ],
    if (podium) ...[
      _n('GT', 0, 400, role: NodeRole.plant, c: NodeComponent.groundTank),
      _n('BS', 50, 400, role: NodeRole.plant, c: NodeComponent.boosterSet),
      for (var f = 0; f <= 5; f++) ...[
        _n('M$f', 100, 400, floor: f),
        _n(
          'V$f',
          200,
          400,
          floor: f,
          role: NodeRole.fixture,
          fixture: PlumbingFixture.lavatory,
        ),
      ],
    ],
  ],
  edges: [
    _e('rt', 'RT', 'R19'),
    for (var f = 19; f > 6; f--)
      _e('r$f', 'R$f', 'R${f - 1}', k: EdgeKind.riser),
    for (var f = 6; f <= 19; f++) _e('w$f', 'R$f', 'W$f'),
    if (podium) ...[
      _e('g', 'GT', 'BS'),
      _e('b', 'BS', 'M0'),
      for (var f = 1; f <= 5; f++)
        _e('m$f', 'M${f - 1}', 'M$f', k: EdgeKind.riser),
      for (var f = 0; f <= 5; f++) _e('v$f', 'M$f', 'V$f'),
    ],
  ],
);

ProviderContainer _solve({required bool podium, required FeedStrategy feed}) {
  final c = _c();
  c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < 20; i++) Floor('L$i', const Length(3.5))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(feedStrategyProvider.notifier).set(feed);
  c
      .read(networkControllerProvider.notifier)
      .loadNetwork(_drawing(podium: podium));
  return c;
}

void main() {
  for (final feed in [FeedStrategy.downfeed, FeedStrategy.upfeed]) {
    test('$feed: the podium booster gets a duty on its own field', () {
      final c = _solve(podium: true, feed: feed);
      expect(c.read(extraSupplySourcesProvider), isNotEmpty);
      final duty = c.read(supplyMoverDutiesProvider)['BS'];
      expect(duty, isNotNull, reason: 'BS sized');
      // target 22.94 m + the 17.5 m lift to L5 at least.
      expect(duty!.head.meters, greaterThan(22.94 + 17.5));
      expect(duty.flow.cubicMetersPerSecond, greaterThan(0));
      // Its MEP way is fed from the solved duty, never the default.
      expect(
        c.read(nodeFedLoadsProvider)['BS']?.source,
        NodeLoadSource.solvedDuty,
      );
      // The podium fixtures are pressure-judged, at the delivered field (the
      // booster running holds the 225 kPa target at its index fixture).
      final residual = c.read(residualByNodeProvider);
      for (var f = 0; f <= 5; f++) {
        expect(residual.containsKey('V$f'), isTrue, reason: 'V$f');
        expect(
          residual['V$f']!.inKiloPascals,
          greaterThan(225 - 0.5),
          reason: 'V$f delivered',
        );
      }
      expect(c.read(heatmapDeliveryNodeIdsProvider), contains('V5'));
    });
  }

  test('downfeed: the PRV zone table ignores the booster-fed podium', () {
    final alone = _solve(podium: false, feed: FeedStrategy.downfeed);
    final mixed = _solve(podium: true, feed: FeedStrategy.downfeed);
    List<(int, int)> spans(ProviderContainer c) => [
      for (final z in c.read(zonesProvider))
        (z.topFloorIndex, z.bottomFloorIndex),
    ];
    expect(spans(alone), isNotEmpty);
    // The tank feeds L19 .. L6 only, so no zone reaches below L6.
    expect(spans(alone).last.$2, 6);
    expect(spans(mixed), spans(alone));
  });
}
