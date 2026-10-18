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
void main() {
  final budgetM = headFromPressure(Pressure(
          const SniProfile().maxFixtureStaticPressure.value.pascals - 255000))
      .meters;

  ProviderContainer storeys(double h) {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(projectControllerProvider.notifier).setFloors([
      for (var i = 0; i < 12; i++) Floor('L$i', Length(h)),
    ]);
    return c;
  }

  test('the zone tables hold the 255 kPa PRV setpoint', () {
    final c = storeys(3.0);
    expect(c.read(zoneStaticsProvider).first.topResidual.pascals,
        closeTo(255000, 1e-6));
  });

  test('default mounting (3.0 m storeys): 5-floor zones', () {
    final c = storeys(3.0);
    // Span of a zone t..f is (t−f)·3.0 + (3.0 − 0.3 − 1.1) = (t−f)·3.0 + 1.6
    // ≤ budget (≈ 14.0 m) ⇒ t−f ≤ 4 ⇒ 5 floors: 11-7, 6-2, 1-0.
    expect(4 * 3.0 + 1.6, lessThanOrEqualTo(budgetM));
    expect(5 * 3.0 + 1.6, greaterThan(budgetM));
    final zones = c.read(zonesProvider);
    expect([for (final z in zones) (z.topFloorIndex, z.bottomFloorIndex)],
        [(11, 7), (6, 2), (1, 0)]);
    expect(c.read(zoneStaticsProvider).every((z) => z.withinLimit), isTrue);
  });

  test('edited mounting heights re-budget the zones; every zone compliant', () {
    final c = storeys(3.0);
    final p = c.read(projectControllerProvider.notifier);
    p.setCeilingDrop(0.05);
    p.setFixtureHeight(0.2);

    // Span now (t−f)·3.0 + (3.0 − 0.05 − 0.2) = (t−f)·3.0 + 2.75 ≤ budget
    // ⇒ t−f ≤ 3 ⇒ 4 floors per zone: 11-8, 7-4, 3-0.
    expect(3 * 3.0 + 2.75, lessThanOrEqualTo(budgetM));
    expect(4 * 3.0 + 2.75, greaterThan(budgetM));
    final zones = c.read(zonesProvider);
    expect([for (final z in zones) (z.topFloorIndex, z.bottomFloorIndex)],
        [(11, 8), (7, 4), (3, 0)]);

    final statics = c.read(zoneStaticsProvider);
    expect(statics.every((z) => z.withinLimit), isTrue);
    // Bottom static of zone 11-8 = PRV setpoint + ρg·(3·3.0 + 2.75 = 11.75 m).
    final prv = statics.first.topResidual.pascals;
    expect(prv, closeTo(255000, 1e-6));
    expect(statics.first.bottomStatic.pascals,
        closeTo(prv + pressureFromHead(const Head(11.75)).pascals, 1e-6));

    // The regression: the old default-height zone 11-7 measured on the REAL
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
