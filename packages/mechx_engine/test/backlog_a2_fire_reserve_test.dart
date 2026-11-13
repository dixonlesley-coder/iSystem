// Backlog A-2 (2026-11-13) — the fire-water reserve V = Q_rated x t.
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_water_reserve.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  test('office: 31.5451 L/s x 30 min = 56 781 L (standpipe + LH sprinkler)',
      () {
    final r = fireWaterReserve(
      ratedFlow: FlowRate.litersPerSecond(31.5451),
      standpipe: true,
      sprinkler: true,
      hazard: FireHazardClass.lightHazard,
    )!;
    expect(r.durationMin, 30);
    // 31.5451 x 1800 = 56 781.2 L.
    expect(r.volumeLitres, closeTo(31.5451 * 1800, 1e-6));
    expect(r.volumeLitres.round(), 56781);
  });

  test('tower: 47.3176 L/s x 30 min = 85 172 L', () {
    final r = fireWaterReserve(
      ratedFlow: FlowRate.litersPerSecond(47.3176),
      standpipe: true,
      sprinkler: true,
      hazard: FireHazardClass.lightHazard,
    )!;
    expect(r.volumeLitres.round(), 85172); // 47.3176 x 1800 = 85 171.7
  });

  test('the longest applicable duration governs; nothing drawn ⇒ null', () {
    FireWaterReserve? at(FireHazardClass h, {bool st = false}) =>
        fireWaterReserve(
            ratedFlow: FlowRate.litersPerSecond(10),
            standpipe: st,
            sprinkler: true,
            hazard: h);
    expect(at(FireHazardClass.ordinaryHazard1)!.durationMin, 60);
    expect(at(FireHazardClass.ordinaryHazard2, st: true)!.durationMin, 60);
    expect(at(FireHazardClass.extraHazard)!.durationMin, 90);
    expect(
        fireWaterReserve(
            ratedFlow: FlowRate.litersPerSecond(10),
            standpipe: false,
            sprinkler: false,
            hazard: FireHazardClass.lightHazard),
        isNull);
    expect(
        fireWaterReserve(
            ratedFlow: const FlowRate(0),
            standpipe: true,
            sprinkler: false,
            hazard: FireHazardClass.lightHazard),
        isNull);
  });

  test('judge: unset / undersized / ok, never a fabricated capacity', () {
    expect(judgeFireTank(capacityLitres: null, requiredLitres: 56781),
        FireTankVerdict.unset);
    expect(judgeFireTank(capacityLitres: 50000, requiredLitres: 56781),
        FireTankVerdict.undersized);
    expect(judgeFireTank(capacityLitres: 60000, requiredLitres: 56781),
        FireTankVerdict.ok);
    expect(judgeFireTank(capacityLitres: 56781, requiredLitres: 56781),
        FireTankVerdict.ok);
  });
}
