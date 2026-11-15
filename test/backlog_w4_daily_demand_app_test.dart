// Backlog W-4 (2026-11-14) — the daily-demand inputs end to end: the
// per-person override, the unset-population advisory (only with a capacity
// tank), the water reserve in days (informational, no judge) and the
// `.mechx` round-trip. Hand arithmetic in comments.
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/tank_fill_store.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/tank_fill.dart' show formatReserveDays;
import 'package:mechx_engine/standards/sni.dart';

import '../packages/mechx_engine/test/reference/shophouse.dart';

ProviderContainer _load(Network net, {int? population}) {
  final shop = buildShophouse();
  final c = ProviderContainer();
  c.read(sheetsControllerProvider.notifier).loadSheets(
    [
      for (final s in shop.sheets)
        Sheet(id: s.id, name: s.name, sizePx: const Size(1684, 1190)),
    ],
    sheetFloors: {for (final s in shop.sheets) s.id: s.floorIndex},
  );
  final project = c.read(projectControllerProvider.notifier)
    ..setFloors(shop.building.floors);
  for (final MapEntry(:key, :value) in shop.calibrations.entries) {
    project.setCalibration(key, value);
  }
  c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
  c.read(occupancyProvider.notifier).set(shop.occupancy);
  c.read(populationProvider.notifier).set(population);
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

/// The shophouse with each roof tank at [litres] (refill [hours]).
Network _roofTanks(double litres, {double? hours}) {
  final shop = buildShophouse();
  return Network(nodes: [
    for (final n in shop.network.nodes)
      n.component == NodeComponent.roofTank
          ? n.copyWith(tankCapacityLitres: litres, tankRefillHours: hours)
          : n,
  ], edges: shop.network.edges);
}

List<String> _kinds(ProviderContainer c) =>
    [for (final i in c.read(designIssuesProvider)) i.kind];

void main() {
  test('per-person default by occupancy, override wins, clearing reverts',
      () {
    final c = _load(buildShophouse().network, population: 15);
    addTearDown(c.dispose);
    expect(c.read(demandPerPersonProvider), 120); // private
    expect(c.read(dailyDemandLitresProvider), 1800); // 15 x 120
    c.read(occupancyProvider.notifier).set(Occupancy.public);
    expect(c.read(dailyDemandLitresProvider), 750); // 15 x 50
    c.read(demandPerPersonOverrideProvider.notifier).set(150);
    expect(c.read(dailyDemandLitresProvider), 2250); // 15 x 150
    c.read(demandPerPersonOverrideProvider.notifier).set(null);
    expect(c.read(demandPerPersonProvider), 50);
  });

  test('unset population: no figure; the advisory only with a capacity tank',
      () {
    final none = _load(buildShophouse().network);
    addTearDown(none.dispose);
    expect(none.read(dailyDemandLitresProvider), isNull);
    expect(none.read(waterReserveProvider).days, isNull);
    // No tank has a capacity and none can be auto-sized: no advisory, but
    // each tank warns `tank-capacity-unset` (backlog W-5).
    expect(_kinds(none), isNot(contains('daily-demand-unset')));
    expect(_kinds(none).where((k) => k.startsWith('tank-capacity-unset')),
        hasLength(6));
    final cap = _load(_roofTanks(2000));
    addTearDown(cap.dispose);
    expect(cap.read(waterReserveProvider).storedLitres, 6000);
    expect(cap.read(waterReserveProvider).days, isNull);
    expect(_kinds(cap).where((k) => k == 'daily-demand-unset'), hasLength(1));
  });

  test('reserve: 3 x 2000 L roof tanks (entered) + 3 auto GTs over 1800 '
      'L/day', () {
    final c = _load(_roofTanks(2000), population: 15);
    addTearDown(c.dispose);
    final r = c.read(waterReserveProvider);
    // 15 x 120 = 1800 L/day; entered RT_A..C 3 x 2000 = 6000 L; GT_A..C
    // auto (W-5): 1/3 x 1800 x 1.0 day = 600 → 650 L each = 1950 L. Stored
    // 7950 L; 7950 / 1800 = 4.41667 days.
    expect(r.storedLitres, 7950);
    expect(r.days, closeTo(4.416667, 5e-7));
    expect(r.excludedTankIds, isEmpty);
    // Entered wins: the RTs are not auto-sized.
    expect(c.read(autoTankCapacitiesProvider).keys.toSet(),
        {'GT_A', 'GT_B', 'GT_C'});
    expect(_kinds(c), isNot(contains('daily-demand-unset')));
    // Informational only: no fill-rate judge exists (owner decision).
    expect(_kinds(c).where((k) => k.contains('below-demand')), isEmpty);
  });

  test('a tiny tank refilled slowly is NOT judged (fill rate is out of the '
      'designer\'s control); the reserve just reads what is stored', () {
    final c = _load(_roofTanks(20, hours: 24), population: 15);
    addTearDown(c.dispose);
    // 3 x 20 + 3 x 650 (auto GTs) = 2010 L / 1800 L/day = 1.11667 days.
    final r = c.read(waterReserveProvider);
    expect(r.days, closeTo(1.116667, 5e-7));
    expect(formatReserveDays(r.days!), '1.1 days');
    expect(_kinds(c).where((k) => k.contains('below-demand')), isEmpty);
  });

  test('.mechx: population and the override round-trip; old files load '
      'unset', () {
    const set = DesignSettings(population: 96, demandPerPersonL: 150);
    final back = DesignSettings.fromJson(set.toJson());
    expect(back.population, 96);
    expect(back.demandPerPersonL, 150);
    final def = const DesignSettings().toJson();
    expect(def.containsKey('population'), isFalse);
    expect(def.containsKey('demand_lpd'), isFalse);
    final old = DesignSettings.fromJson(const {});
    expect(old.population, isNull);
    expect(old.demandPerPersonL, isNull);
    final bad = DesignSettings.fromJson(
        const {'population': 'x', 'demand_lpd': -5});
    expect(bad.population, isNull);
    expect(bad.demandPerPersonL, isNull);
  });
}
