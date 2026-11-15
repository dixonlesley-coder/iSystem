// Backlog W-2 (2026-11-14) — the mains head at a water meter must lift the
// ground tank's fill to the tank inlet, pass the meter feed's friction at
// that flow and leave the float valve its residual (`mainsPressureCheck`).
// Judge-only: the feed's size never changes. Hand arithmetic in comments.
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/tank_fill.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'reference/shophouse.dart';

void main() {
  final shop = buildShophouse();
  // Unit A's ground tank holds 6000 L (default 4 h refill).
  final net = Network(nodes: [
    for (final n in shop.network.nodes)
      n.id == 'GT_A' ? n.copyWith(tankCapacityLitres: 6000) : n,
  ], edges: shop.network.edges);
  const profile = SniProfile();
  final sizing = autoSizeNetwork(
    net,
    const SizingContext(),
    leafDemand: const {ServiceType.coldWater: FlowRate(0.0002)},
    leafFixtureUnits: const {ServiceType.coldWater: 2.0},
    nodeFixtureUnits: {
      for (final n in net.nodes)
        if (n.fixture != null)
          n.id: profile.fixtureUnitLoad(n.fixture!, occupancy: shop.occupancy),
    },
    building: shop.building,
    calibrationBySheet: shop.calibrations,
    mounting: shop.mounting,
  );
  double lengthOf(NetEdge e) => edgeLength(e, net,
          calibrationBySheet: shop.calibrations,
          building: shop.building,
          mounting: shop.mounting)
      .meters;
  double elevationOf(NetNode n) =>
      nodeElevation(n, shop.building, shop.mounting).meters;
  final sized = {
    for (final e in sizing.entries)
      e.key: (flow: e.value.flow, diameter: e.value.diameter),
  };

  test('one meter feed per unit, meter → ground tank', () {
    final feeds = meterFeedsToGroundTanks(net);
    expect([for (final f in feeds) '${f.meterId}>${f.tankId}:${f.edgeIds}'], [
      for (final u in kShopUnits) 'WM_$u>GT_$u:[e_cw_WM_${u}_GT_$u]',
    ]);
  });

  MainsPressureCheck check(double availableM, String unit) =>
      mainsPressureCheck(
        net: net,
        feed: meterFeedsToGroundTanks(net)
            .firstWhere((f) => f.meterId == 'WM_$unit'),
        sized: sized,
        available: Head(availableM),
        lengthOf: lengthOf,
        elevationOf: elevationOf,
      )!;

  test('pass: 10 m available >= 4.860 m required', () {
    final c = check(kDefaultMainsHeadM, 'A');
    // Lift: GT on the Lantai 1 slab 0.0 − meter at floor + 0.5 (backlog
    // D-3) = −0.5 m. Flow: 6000 L / (4 h x 3600) = 0.416667 L/s on DN20
    // over 3.0 + 0.5 = 3.5 m. Hazen–Williams C150: hf = 10.67 x 3.5 x
    // (4.16667e-4)^1.852 / (150^1.852 x 0.02^4.8704) = 0.36027 m (0.10293
    // m/m). Inlet residual 5.0 m. Required = −0.5 + 0.36027 + 5.0 =
    // 4.86027 m <= 10 m.
    expect(c.flow.inLitersPerSecond, closeTo(0.416667, 1e-6));
    expect(c.fillBasis, isTrue);
    expect(c.liftM, closeTo(-0.5, 1e-9));
    expect(c.frictionM, closeTo(0.36027, 5e-5));
    expect(c.inletResidualM, kTankInletResidualHeadM);
    expect(c.required.meters, closeTo(4.86027, 5e-5));
    expect(c.ok, isTrue);
  });

  test('fail: 4.0 m available < 4.860 m required; the size never moves', () {
    final c = check(4.0, 'A');
    expect(c.ok, isFalse);
    expect(c.required.meters, closeTo(4.86027, 5e-5));
    // Judge-only: the feed stays DN20 at the fill flow.
    expect(sizing['e_cw_WM_A_GT_A']!.diameter.inMillimeters, 20);
  });

  test('no capacity: the feed is judged at the flow it was sized on', () {
    final c = check(kDefaultMainsHeadM, 'B');
    // GT_B has no capacity: the F2 basis 12.5 UBAP = 0.56389 L/s on DN20.
    // hf = 10.67 x 3.5 x (5.6389e-4)^1.852 / (150^1.852 x 0.02^4.8704) =
    // 0.63091 m (0.18026 m/m); required = −0.5 + 0.63091 + 5.0 = 5.13091.
    expect(c.fillBasis, isFalse);
    expect(c.flow.inLitersPerSecond, closeTo(0.56389, 5e-5));
    expect(c.frictionM, closeTo(0.63091, 5e-4));
    expect(c.required.meters, closeTo(5.13091, 5e-4));
    expect(c.ok, isTrue);
  });
}
