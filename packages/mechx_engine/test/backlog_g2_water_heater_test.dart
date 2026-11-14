// Backlog G-2 (2026-11-13) — the water heater duty by the ASHRAE
// fixture-demand method (`sizing/water_heater.dart`). Hand values:
// recovery = Σ gal/h x 3.785411784 x demand factor; storage = recovery x
// storage factor (up the 50..2000 L ladder); element = recovery x 4.186 x
// (60 − 25) / 3600 / 0.98 (up the 1.5..36 kW ladder).
import 'dart:math' as math;

import 'package:mechx_engine/electrical/load_kind.dart' show LoadKind;
import 'package:mechx_engine/electrical/load_list.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/sizing/water_heater.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  double kw(double lph) => lph * 4.186 * 35 / 3600 / 0.98;

  test('tower: 6 public lavatories (office column) → 40.88 L/h, 100 L, 2 kW',
      () {
    final d = sizeWaterHeater(
      fixtures: List.filled(6, PlumbingFixture.lavatory),
      occupancy: Occupancy.public,
    )!;
    // 6 x 6 gal/h = 36 gal/h = 136.2748 L/h; x 0.30 = 40.8825 L/h.
    expect(d.column, 'office');
    expect(d.hourlyDemandLph, closeTo(36 * 3.785411784, 1e-9));
    expect(d.hourlyDemandLph, closeTo(136.2748, 5e-4));
    expect(d.demandFactor, 0.30);
    expect(d.recoveryLph, closeTo(40.8825, 5e-4));
    // x 2.00 = 81.765 L → the 100 L tank.
    expect(d.storageFactor, 2.00);
    expect(d.storageRequiredL, closeTo(81.7649, 5e-4));
    expect(d.tankL, 100);
    // 40.8825 x 4.186 x 35 / 3600 / 0.98 = 1.69776 kW → 2 kW.
    expect(d.heatingKwRequired, closeTo(kw(d.recoveryLph), 1e-12));
    expect(d.heatingKwRequired, closeTo(1.69776, 5e-5));
    expect(d.elementKw, 2);
    expect(d.elementRecoveryLph, closeTo(48.159, 5e-3));
    expect(d.tankBeyondLadder, isFalse);
    expect(d.elementBeyondLadder, isFalse);
    expect(waterHeaterPhases(d.elementKw), 1);
  });

  test('private (apartment column): 2 LAV + shower + kitchen sink', () {
    // 2 + 2 + 30 + 10 = 44 gal/h = 166.558 L/h; x 0.30 = 49.967 L/h;
    // x 1.25 = 62.459 L → 80 L; 2.0752 kW → 3 kW.
    final d = sizeWaterHeater(fixtures: [
      PlumbingFixture.lavatory,
      PlumbingFixture.shower,
      PlumbingFixture.lavatory,
      PlumbingFixture.kitchenSink,
    ], occupancy: Occupancy.private)!;
    expect(d.column, 'apartment');
    expect(d.recoveryLph, closeTo(44 * 3.785411784 * 0.30, 1e-9));
    expect(d.storageRequiredL, closeTo(62.459, 5e-3));
    expect(d.tankL, 80);
    expect(d.heatingKwRequired, closeTo(2.0752, 5e-4));
    expect(d.elementKw, 3);
  });

  test('no hot-water row ⇒ unrated, never fabricated; none rated ⇒ null', () {
    expect(
        sizeWaterHeater(fixtures: [
          PlumbingFixture.waterClosetFlushValve,
          null,
        ], occupancy: Occupancy.public),
        isNull);
    final d = sizeWaterHeater(fixtures: [
      PlumbingFixture.bathtub, // no office row
      PlumbingFixture.shower,
      null,
    ], occupancy: Occupancy.assembly)!;
    expect(d.unratedFixtures, 2);
    expect(d.fixtures, {PlumbingFixture.shower: 1});
  });

  test('beyond the ladders: the requirement rounded up, flagged — never the '
      'top rung', () {
    final d = sizeWaterHeater(
      fixtures: List.filled(200, PlumbingFixture.shower),
      occupancy: Occupancy.public,
    )!;
    // 6000 gal/h x 3.785 x 0.30 = 6813.7 L/h; x 2 = 13 627.5 L → 13 700 L.
    expect(d.tankBeyondLadder, isTrue);
    expect(d.tankL, 13700);
    expect(d.tankL, greaterThanOrEqualTo(d.storageRequiredL));
    expect(d.elementBeyondLadder, isTrue);
    expect(d.elementKw, greaterThanOrEqualTo(d.heatingKwRequired));
    expect(waterHeaterPhases(d.elementKw), 3);
    expect(waterHeaterPhases(5.5), 1);
    expect(waterHeaterPhases(6), 3);
  });

  test('order-independent: any permutation sizes identically', () {
    final base = [
      PlumbingFixture.lavatory,
      PlumbingFixture.lavatory,
      PlumbingFixture.shower,
      PlumbingFixture.kitchenSink,
      PlumbingFixture.bathtub,
      null,
    ];
    final ref = sizeWaterHeater(fixtures: base, occupancy: Occupancy.private)!;
    final rnd = math.Random(11);
    for (var t = 0; t < 20; t++) {
      final d = sizeWaterHeater(
          fixtures: [...base]..shuffle(rnd), occupancy: Occupancy.private)!;
      expect(d.recoveryLph, ref.recoveryLph);
      expect(d.tankL, ref.tankL);
      expect(d.elementKw, ref.elementKw);
      expect(d.unratedFixtures, ref.unratedFixtures);
    }
  });

  test('one notAnSniClause verify entry (no Review advisory)', () {
    final items = const SniProfile().verifyChecklist;
    final hits = items.where((v) => v.citation.contains('ASHRAE'));
    expect(hits, hasLength(1));
    expect(hits.single.status, VerificationStatus.notAnSniClause);
    expect(identical(waterHeaterVerifyItem.citation, hits.single.citation) ||
        waterHeaterVerifyItem.citation == hits.single.citation, isTrue);
  });

  test('the component and its electrical source', () {
    expect(NodeComponent.waterHeater.role, NodeRole.plant);
    expect(NodeComponent.waterHeater.isElectricalLoad, isTrue);
    expect(MepLoadSource.waterHeater.circuitLoadKind, LoadKind.heating);
    expect(MepLoadSource.waterHeater.isPump, isFalse);
    final c = equipmentToCircuit(
      const MepEquipmentLoad(
        id: 'node-WH',
        name: 'Water heater WH-01',
        source: MepLoadSource.waterHeater,
        mechanicalPower: Power(2000),
        electricalInputPower: Power(2000),
        phases: 1,
        cosPhi: 1.0,
        motorEfficiency: 1.0,
      ),
      panelVoltage: const Voltage(400),
    );
    // 2000 / (231 x 1.0) = 8.658 A on a 400 V board's phase.
    expect(c.flaOverrideA, closeTo(8.658, 5e-4));
    expect(c.loadKind, LoadKind.heating);
    expect(c.motorKw, isNull);
  });

  test('equipment schedule row', () {
    final rows = buildEquipmentScheduleRows(const EquipmentScheduleData(
      projectName: 'p',
      date: 'd',
      waterHeaters: [
        WaterHeaterScheduleItem(
          tag: 'WH-01',
          fixtureCount: 6,
          recoveryLph: 40.8825,
          storageRequiredL: 81.765,
          tankL: 100,
          elementKw: 2,
          phases: 1,
        ),
      ],
    ));
    final r = rows.single;
    expect(r.category, EquipmentCategory.waterHeater);
    expect(r.tag, 'WH-01');
    expect(r.duty, '40.9 L/h recovery, 81.8 L storage required');
    expect(r.size, contains('100 L tank, 2.0 kW element'));
  });
}
