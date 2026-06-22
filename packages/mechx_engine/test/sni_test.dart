import 'package:mechx_engine/standards/sni.dart';
import 'package:test/test.dart';

/// Locks in the SNI 8153:2015 supply values seeded from research, and the
/// provenance contract (which values are verified vs still flagged).
void main() {
  const profile = SniProfile();

  group('seeded pressures (SNI 8153:2015)', () {
    test('min pressure at fixture outlet = 0.50 kgf/cm² ≈ 49.03 kPa, verified', () {
      final v = profile.minResidualPressureFaucet;
      expect(v.value.inKiloPascals, closeTo(49.033, 1e-3));
      expect(v.verified, isTrue);
    });

    test('min pressure at flush valve = 1 kgf/cm² ≈ 98.07 kPa, verified', () {
      final v = profile.minResidualPressureFlushValve;
      expect(v.value.inKiloPascals, closeTo(98.0665, 1e-3));
      expect(v.verified, isTrue);
    });

    test('mandatory relief threshold = 5 kgf/cm² ≈ 490.3 kPa, verified', () {
      final v = profile.mandatoryPressureReliefThreshold;
      expect(v.value.inKiloPascals, closeTo(490.33, 1e-2));
      expect(v.verified, isTrue);
    });

    test('max fixture pressure ≈ 4 kgf/cm² ≈ 392.3 kPa, still flagged', () {
      final v = profile.maxFixtureStaticPressure;
      expect(v.value.inKiloPascals, closeTo(392.27, 1e-2));
      expect(v.verified, isFalse, reason: 'design guidance, secondary source only');
    });
  });

  group('seeded velocities', () {
    test('supply velocity max = 2.0 m/s, flagged (secondary)', () {
      final v = profile.maxSupplyVelocity;
      expect(v.value.metersPerSecond, 2.0);
      expect(v.verified, isFalse);
    });

    test('drain velocity is general-practice, not an SNI clause', () {
      expect(profile.maxDrainVelocity.verified, isFalse);
    });
  });

  group('demand method', () {
    test('UBAP + Hunter curve, method verified', () {
      expect(profile.demandMethod.verified, isTrue);
      expect(profile.demandMethod.value, contains('UBAP'));
    });
  });

  group('UBAP fixture-unit loads (Tabel 3)', () {
    test('flush-valve WC depends on occupancy', () {
      expect(
        profile.fixtureUnitLoad(PlumbingFixture.waterClosetFlushValve),
        6.0, // private (default)
      );
      expect(
        profile.fixtureUnitLoad(PlumbingFixture.waterClosetFlushValve,
            occupancy: Occupancy.public),
        10.0,
      );
    });

    test('flush-tank WC: assembly higher than private', () {
      expect(profile.fixtureUnitLoad(PlumbingFixture.waterClosetFlushTank), 2.5);
      expect(
        profile.fixtureUnitLoad(PlumbingFixture.waterClosetFlushTank,
            occupancy: Occupancy.assembly),
        3.5,
      );
    });

    test('lavatory / shower / bathtub fixed loads', () {
      expect(profile.fixtureUnitLoad(PlumbingFixture.lavatory), 1.0);
      expect(profile.fixtureUnitLoad(PlumbingFixture.shower), 2.0);
      expect(profile.fixtureUnitLoad(PlumbingFixture.bathtub), 4.0);
    });

    test('every fixture has a positive load for every occupancy', () {
      for (final f in PlumbingFixture.values) {
        for (final o in Occupancy.values) {
          expect(profile.fixtureUnitLoad(f, occupancy: o), greaterThan(0));
        }
      }
    });
  });

  group('demand curve (Gambar 1, two branches)', () {
    test('endpoints clamp to the curve ends', () {
      expect(profile.probableFlowForFixtureUnits(0).cubicMetersPerSecond, 0.0);
      expect(
        profile.probableFlowForFixtureUnits(100000).inLitersPerSecond,
        closeTo(27.233, 1e-2), // clamps to 3000 UBAP → 1634 L/min
      );
    });

    test('flush-tank read-off (100 UBAP → ~3.03 L/s)', () {
      expect(
        profile.probableFlowForFixtureUnits(100).inLitersPerSecond,
        closeTo(3.0333, 1e-3),
      );
    });

    test('flush-valve read-off (100 UBAP → ~4.03 L/s)', () {
      expect(
        profile
            .probableFlowForFixtureUnits(100, system: FlushSystem.flushValve)
            .inLitersPerSecond,
        closeTo(4.0333, 1e-3),
      );
    });

    test('linear interpolation between points (75 UBAP, tank → 2.43 L/s)', () {
      expect(
        profile.probableFlowForFixtureUnits(75).inLitersPerSecond,
        closeTo(2.4333, 1e-3),
      );
    });

    test('flush-valve demands more than flush-tank at low UBAP', () {
      final valve = profile
          .probableFlowForFixtureUnits(50, system: FlushSystem.flushValve)
          .cubicMetersPerSecond;
      final tank = profile.probableFlowForFixtureUnits(50).cubicMetersPerSecond;
      expect(valve, greaterThan(tank));
    });

    test('branches converge above ~1000 UBAP', () {
      final valve = profile
          .probableFlowForFixtureUnits(1000, system: FlushSystem.flushValve)
          .cubicMetersPerSecond;
      final tank =
          profile.probableFlowForFixtureUnits(1000).cubicMetersPerSecond;
      expect(valve, closeTo(tank, 1e-12));
    });

    test('both branches are monotonic non-decreasing', () {
      for (final system in FlushSystem.values) {
        var prev = -1.0;
        for (final fu in [0, 10, 50, 100, 200, 500, 1000, 2000, 3000]) {
          final q = profile
              .probableFlowForFixtureUnits(fu.toDouble(), system: system)
              .cubicMetersPerSecond;
          expect(q, greaterThanOrEqualTo(prev));
          prev = q;
        }
      }
    });
  });

  group('verify checklist (provenance contract)', () {
    test('contains only unverified items, most-critical first', () {
      final list = profile.verifyChecklist;
      expect(list, isNotEmpty);
      expect(list.every((v) => v.isUnverified), isTrue);
      // verified pressures must NOT appear
      expect(
        list.any((v) => v.citation.contains('flush valve')),
        isFalse,
      );
    });
  });

  group('material properties', () {
    test('Hazen–Williams C and roughness are defined for every material', () {
      for (final m in PipeMaterial.values) {
        expect(profile.hazenWilliamsC(m), greaterThan(0));
        expect(profile.absoluteRoughness(m).meters, greaterThan(0));
      }
    });
  });
}
