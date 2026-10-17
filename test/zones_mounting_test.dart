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
void main() {
  ProviderContainer twelveStoreys() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(projectControllerProvider.notifier).setFloors([
      for (var i = 0; i < 12; i++) Floor('L$i', const Length(3.5)),
    ]);
    return c;
  }

  test('default mounting: 5-floor zones (byte-identical to before)', () {
    final c = twelveStoreys();
    // Budget = 392.266 − 225 = 167.27 kPa → 17.06 m. Span of a zone t..f is
    // (t−f)·3.5 + (3.5 − 0.3 − 1.1) = (t−f)·3.5 + 2.1 ⇒ t−f ≤ 4 ⇒ 5 floors.
    final zones = c.read(zonesProvider);
    expect(zones.first.topFloorIndex, 11);
    expect(zones.first.bottomFloorIndex, 7);
    expect(c.read(zoneStaticsProvider).every((z) => z.withinLimit), isTrue);
  });

  test('edited mounting heights re-budget the zones; every zone compliant', () {
    final c = twelveStoreys();
    final p = c.read(projectControllerProvider.notifier);
    p.setCeilingDrop(0.05);
    p.setFixtureHeight(0.2);

    // Span now (t−f)·3.5 + (3.5 − 0.05 − 0.2) = (t−f)·3.5 + 3.25 ≤ 17.06
    // ⇒ t−f ≤ 3 ⇒ 4 floors per zone: 11-8, 7-4, 3-0.
    final zones = c.read(zonesProvider);
    expect([for (final z in zones) (z.topFloorIndex, z.bottomFloorIndex)],
        [(11, 8), (7, 4), (3, 0)]);

    final statics = c.read(zoneStaticsProvider);
    expect(statics.every((z) => z.withinLimit), isTrue);
    // Bottom static of zone 11-8 = PRV setpoint + ρg·(3·3.5 + 3.25 = 13.75 m).
    final prv = statics.first.topResidual.pascals;
    expect(statics.first.bottomStatic.pascals,
        closeTo(prv + pressureFromHead(const Head(13.75)).pascals, 1e-6));

    // The regression: the old default-height zone 11-7 measured on the REAL
    // heights spans 4·3.5 + 3.25 = 17.25 m ⇒ 225 + 169.2 = 394.2 kPa, over the
    // 392.3 kPa SNI 8153 limit.
    final old = downfeedZoneStatics(
      building: c.read(projectControllerProvider).building,
      zones: const [PressureZone(11, 7)],
      prvSetpoint: Pressure(prv),
      maxStatic: const SniProfile().maxFixtureStaticPressure.value,
      mounting: c.read(projectControllerProvider).mounting,
    );
    expect(old.single.bottomStatic.inKiloPascals, closeTo(394.2, 0.1));
    expect(old.single.withinLimit, isFalse);
  });
}
