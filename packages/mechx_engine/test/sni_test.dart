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

  group('demand curve interpolation', () {
    test('endpoints clamp', () {
      expect(profile.probableFlowForFixtureUnits(0).cubicMetersPerSecond, 0.0);
      expect(
        profile.probableFlowForFixtureUnits(100000).inLitersPerSecond,
        closeTo(13.0, 1e-9),
      );
    });

    test('exact table point (100 FU → ~3.0 L/s)', () {
      expect(
        profile.probableFlowForFixtureUnits(100).inLitersPerSecond,
        closeTo(3.0, 1e-9),
      );
    });

    test('linear interpolation between points (75 FU)', () {
      // halfway between 50 FU (1.9 L/s) and 100 FU (3.0 L/s) → 2.45 L/s
      expect(
        profile.probableFlowForFixtureUnits(75).inLitersPerSecond,
        closeTo(2.45, 1e-9),
      );
    });

    test('monotonic non-decreasing', () {
      var prev = -1.0;
      for (final fu in [0, 10, 50, 100, 200, 500, 1000]) {
        final q = profile.probableFlowForFixtureUnits(fu.toDouble())
            .cubicMetersPerSecond;
        expect(q, greaterThanOrEqualTo(prev));
        prev = q;
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
