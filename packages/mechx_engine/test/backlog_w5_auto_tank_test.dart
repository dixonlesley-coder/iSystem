// Backlog W-5 (2026-11-14) — a domestic tank with no capacity entered is
// AUTO-sized: its share of the daily demand (cold-water fixture units it
// serves among tanks of its role) x its target (ground days / roof
// fraction), rounded up to the standard ladder. Entered capacity wins; fire
// tanks are never auto-sized. Hand arithmetic in comments.
import 'dart:math' as math;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/tank_fill.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'reference/shophouse.dart';

({Map<String, EdgeSizing> sz, Map<String, double> fu}) _size(
    ReferenceBuilding b, Network net) {
  const profile = SniProfile();
  final fu = <String, double>{};
  final sz = autoSizeNetwork(
    net,
    const SizingContext(),
    leafDemand: const {ServiceType.coldWater: FlowRate(0.0002)},
    leafFixtureUnits: const {ServiceType.coldWater: 2.0},
    nodeFixtureUnits: {
      for (final n in net.nodes)
        if (n.fixture != null)
          n.id: profile.fixtureUnitLoad(n.fixture!, occupancy: b.occupancy),
    },
    building: b.building,
    calibrationBySheet: b.calibrations,
    mounting: b.mounting,
    fixtureUnitsOut: fu,
  );
  return (sz: sz, fu: fu);
}

Map<String, AutoTankCapacity> _auto(ReferenceBuilding b, Network net,
    double daily) {
  final r = _size(b, net);
  return autoTankCapacities(
    net: net,
    edgeUnits: r.fu,
    flowFromOf: (id) => r.sz[id]?.flowFromId,
    dailyLitres: daily,
  );
}

void main() {
  test('the standard ladder rounds UP', () {
    expect(standardTankLitres(1), 250);
    expect(standardTankLitres(250), 250);
    expect(standardTankLitres(251), 500);
    expect(standardTankLitres(600), 650);
    expect(standardTankLitres(1100), 1200);
    expect(standardTankLitres(9000), 10000);
    // Above 10 000 L: 5 m3 steps to 100 m3, then 10 m3 steps.
    expect(standardTankLitres(10001), 15000);
    expect(standardTankLitres(42000), 45000);
    expect(standardTankLitres(100000), 100000);
    expect(standardTankLitres(100001), 110000);
    expect(standardTankLitres(123456), 130000);
    expect(const SniProfile().verifyChecklist,
        contains(const SniProfile().tankStorageTargets));
  });

  final shop = buildShophouse();

  test('role targets and the UBAP split across the row', () {
    // 1800 L/day. Ground role GT_A..C: 12.5 UBAP each of 37.5 ⇒ 1/3 ⇒ 600 L
    // x 1.0 = 600 → 650 L. Roof role RT_A..C (each system holds a ground
    // tank): 1/3 ⇒ 600 x 0.20 = 120 → 250 L.
    final a = _auto(shop, shop.network, 1800);
    for (final u in kShopUnits) {
      expect(a['GT_$u']!.roofTarget, isFalse);
      expect(a['GT_$u']!.share, closeTo(1 / 3, 1e-12));
      expect(a['GT_$u']!.litres, 650);
      expect(a['RT_$u']!.roofTarget, isTrue);
      expect(a['RT_$u']!.rawLitres, closeTo(120, 1e-9));
      expect(a['RT_$u']!.litres, 250);
    }
  });

  test('a lone tank takes the ground target; no demand ⇒ nothing', () {
    // Unit A's roof tank alone (no meter, GT, TP): its system's only tank.
    final ids = {for (final n in shop.network.nodes) n.id};
    final keep = {
      for (final id in ids)
        if (id.endsWith('_A') && !{'WM_A', 'GT_A', 'TP_A', 'U0_A', 'U1_A', 'U2_A'}
            .contains(id))
          id,
    };
    final net = Network(nodes: [
      for (final n in shop.network.nodes)
        if (keep.contains(n.id)) n,
    ], edges: [
      for (final e in shop.network.edges)
        if (keep.contains(e.fromId) && keep.contains(e.toId)) e,
    ]);
    // 600 L/day, share 1, 1.0 day ⇒ 600 → 650 L (not the roof fraction).
    final a = _auto(shop, net, 600);
    expect(a['RT_A']!.roofTarget, isFalse);
    expect(a['RT_A']!.share, closeTo(1.0, 1e-12));
    expect(a['RT_A']!.litres, 650);
    expect(_auto(shop, net, 0), isEmpty);
  });

  test('an entered capacity wins and still takes its share', () {
    final net = Network(nodes: [
      for (final n in shop.network.nodes)
        n.id == 'GT_A' ? n.copyWith(tankCapacityLitres: 5000) : n,
    ], edges: shop.network.edges);
    final a = _auto(shop, net, 1800);
    expect(a.containsKey('GT_A'), isFalse);
    // GT_B / GT_C keep 1/3 each (GT_A's units stay in the ground sum).
    expect(a['GT_B']!.share, closeTo(1 / 3, 1e-12));
    expect(a['GT_B']!.litres, 650);
  });

  test('order-independent: shuffled lists and renamed ids', () {
    final ref = _auto(shop, shop.network, 1800);
    final rnd = math.Random(11);
    for (var trial = 0; trial < 4; trial++) {
      String ren(String id) => 'q${trial}_$id';
      final net = Network(nodes: [
        for (final n in shop.network.nodes)
          NetNode(
            id: ren(n.id),
            sheetId: n.sheetId,
            x: n.x,
            y: n.y,
            floorIndex: n.floorIndex,
            role: n.role,
            fixture: n.fixture,
            component: n.component,
            roofAreaM2: n.roofAreaM2,
          ),
      ]..shuffle(rnd), edges: [
        for (final e in shop.network.edges)
          NetEdge(
            id: ren(e.id),
            fromId: ren(e.fromId),
            toId: ren(e.toId),
            service: e.service,
            kind: e.kind,
          ),
      ]..shuffle(rnd));
      final a = _auto(shop, net, 1800);
      for (final e in ref.entries) {
        final b = a[ren(e.key)]!;
        expect(b.litres, e.value.litres, reason: e.key);
        expect(b.share, closeTo(e.value.share, 1e-12), reason: e.key);
      }
    }
  });
}
