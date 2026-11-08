import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/zoning.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

/// wiring-1: the PRV zoner + zone statics run on the PROJECT mounting heights
/// (F8), so an edited ceiling drop / fixture height can never make Review pass
/// an over-limit zone.
///
/// Round 17 (regression-downfeed-prv-setpoint-equals-target) — the PRV holds
/// target + the 30 kPa floor-branch friction margin (`defaultPrvSetpoint`):
/// 225 + 30 = 255 kPa, so the zone budget is 392.266 − 255 = 137.266 kPa,
/// converted to metres with the engine's own `headFromPressure` (derived
/// below, never a magic number).
///
/// Round 22 (pressurized-3-1) — the TOP zone is fed by the roof tank's own
/// head (no PRV): with no tank drawn the source is the roof, so on 20 × 3.0 m
/// (roof 60 m) it admits floor f while 60 − (3f + fixture) ≤ 392.266 kPa / ρg
/// = 39.99 m. The PRV-budget zones below it are what these tests pin.
void main() {
  final budgetM = headFromPressure(Pressure(
          const SniProfile().maxFixtureStaticPressure.value.pascals - 255000))
      .meters;

  ProviderContainer storeys(double h) {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(projectControllerProvider.notifier).setFloors([
      for (var i = 0; i < 20; i++) Floor('L$i', Length(h)),
    ]);
    return c;
  }

  final tankM = headFromPressure(
          const SniProfile().maxFixtureStaticPressure.value)
      .meters;

  test('the zone tables hold the 255 kPa PRV setpoint', () {
    final c = storeys(3.0);
    final statics = c.read(zoneStaticsProvider);
    // The tank-fed top zone holds no PRV; every zone below it does.
    expect(statics.first.viaPrv, isFalse);
    expect(statics.skip(1).every((z) => z.viaPrv), isTrue);
    expect(statics[1].topResidual.pascals, closeTo(255000, 1e-6));
  });

  test('default mounting (3.0 m storeys): 5-floor zones', () {
    final c = storeys(3.0);
    // Tank zone: 60 − (3f + 1.1) ≤ 39.99 ⇔ f ≥ 6.30 ⇒ floors 19..7.
    expect(60 - (3 * 7 + 1.1), lessThanOrEqualTo(tankM));
    expect(60 - (3 * 6 + 1.1), greaterThan(tankM));
    // Span of a PRV zone t..f is (t−f)·3.0 + (3.0 − 0.3 − 1.1) = (t−f)·3.0 +
    // 1.6 ≤ budget (≈ 14.0 m) ⇒ t−f ≤ 4 ⇒ 5 floors: 6-2, 1-0.
    expect(4 * 3.0 + 1.6, lessThanOrEqualTo(budgetM));
    expect(5 * 3.0 + 1.6, greaterThan(budgetM));
    final zones = c.read(zonesProvider);
    expect([for (final z in zones) (z.topFloorIndex, z.bottomFloorIndex)],
        [(19, 7), (6, 2), (1, 0)]);
    expect(c.read(zoneStaticsProvider).every((z) => z.withinLimit), isTrue);
  });

  test('edited mounting heights re-budget the zones; every zone compliant', () {
    final c = storeys(3.0);
    final p = c.read(projectControllerProvider.notifier);
    p.setCeilingDrop(0.05);
    p.setFixtureHeight(0.2);

    // Tank zone: 60 − (3f + 0.2) ≤ 39.99 ⇔ f ≥ 6.60 ⇒ floors 19..7.
    expect(60 - (3 * 7 + 0.2), lessThanOrEqualTo(tankM));
    expect(60 - (3 * 6 + 0.2), greaterThan(tankM));
    // PRV span now (t−f)·3.0 + (3.0 − 0.05 − 0.2) = (t−f)·3.0 + 2.75 ≤
    // budget ⇒ t−f ≤ 3 ⇒ 4 floors per zone: 6-3, 2-0.
    expect(3 * 3.0 + 2.75, lessThanOrEqualTo(budgetM));
    expect(4 * 3.0 + 2.75, greaterThan(budgetM));
    final zones = c.read(zonesProvider);
    expect([for (final z in zones) (z.topFloorIndex, z.bottomFloorIndex)],
        [(19, 7), (6, 3), (2, 0)]);

    final statics = c.read(zoneStaticsProvider);
    expect(statics.every((z) => z.withinLimit), isTrue);
    // The tank zone's lowest fixture: ρg·(60 − (3·7 + 0.2) = 38.8 m).
    expect(statics.first.bottomStatic.pascals,
        closeTo(pressureFromHead(const Head(60 - 21.2)).pascals, 1e-6));
    // Bottom static of PRV zone 6-3 = setpoint + ρg·(3·3.0 + 2.75 = 11.75 m).
    final prv = statics[1].topResidual.pascals;
    expect(prv, closeTo(255000, 1e-6));
    expect(statics[1].bottomStatic.pascals,
        closeTo(prv + pressureFromHead(const Head(11.75)).pascals, 1e-6));

    // The regression: a default-height 5-floor zone 11-7 measured on the REAL
    // heights spans 4·3.0 + 2.75 = 14.75 m ⇒ 255 kPa + ρg·14.75, over the
    // 392.3 kPa SNI 8153 limit.
    final old = downfeedZoneStatics(
      building: c.read(projectControllerProvider).building,
      zones: const [PressureZone(11, 7)],
      prvSetpoint: Pressure(prv),
      maxStatic: const SniProfile().maxFixtureStaticPressure.value,
      mounting: c.read(projectControllerProvider).mounting,
    );
    expect(old.single.bottomStatic.pascals,
        closeTo(prv + pressureFromHead(const Head(14.75)).pascals, 1e-6));
    expect(old.single.withinLimit, isFalse);
  });
}
