/// Tests for the §7 pressurized water-supply pipe-sizing module.
///
/// Hand-computed expected values are shown inline so that the assertions are
/// self-documenting and reviewable without running the engine.
///
/// Arithmetic summary
/// ──────────────────
/// Flow Q = 0.005 m³/s, maxV = 2.0 m/s.
///
/// DN50 (D = 0.050 m):
///   A  = π × 0.050² / 4 = 0.0019635 m²
///   v  = 0.005 / 0.0019635 = 2.546 m/s  →  > 2.0 m/s  ⟹  rejected
///
/// DN65 (D = 0.065 m):
///   A  = π × 0.065² / 4 = 0.0033183 m²
///   v  = 0.005 / 0.0033183 = 1.507 m/s  →  ≤ 2.0 m/s  ⟹  chosen
///
/// Re = 1.507 × 0.065 / 1.004e-6 ≈ 97 563
///
/// PVC roughness ε = 1.5 × 10⁻⁶ m; ε/D = 1.5e-6 / 0.065 ≈ 2.308 × 10⁻⁵
///
/// Swamee–Jain:
///   denom = log₁₀(ε/D/3.7 + 5.74/Re⁰·⁹)
///         ≈ log₁₀(6.237 × 10⁻⁶ + 1.360 × 10⁻⁴)
///         ≈ −3.847
///   f = 0.25 / 3.847² ≈ 0.0169  →  in (0.01, 0.05) ✓
///
/// Darcy–Weisbach per metre (L = 1 m):
///   h_f = f × (L/D) × v²/(2g)
///       ≈ 0.0169 × 15.385 × 0.1159
///       ≈ 0.0301 m/m  > 0 ✓
///
/// designFlowForFixtureUnits(100):
///   Table anchor at UBAP = 100: 0.00303333 m³/s = 3.033 L/s ≈ 3.03 L/s
///   (t = 0 at the lower-interval bound → no interpolation.)
library;

import 'package:mechx_engine/sizing/water_supply_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  group('standardPipeDiametersMm', () {
    test('contains 12 entries', () {
      expect(standardPipeDiametersMm.length, equals(12));
    });

    test('is sorted ascending', () {
      for (var i = 1; i < standardPipeDiametersMm.length; i++) {
        expect(
          standardPipeDiametersMm[i],
          greaterThan(standardPipeDiametersMm[i - 1]),
        );
      }
    });

    test('smallest is DN15, largest is DN200', () {
      expect(standardPipeDiametersMm.first, equals(15.0));
      expect(standardPipeDiametersMm.last, equals(200.0));
    });
  });

  group('sizeForFlow — diameter selection (Q = 5 L/s, maxV = 2.0 m/s)', () {
    test('selects DN65 (smallest DN whose velocity ≤ 2.0 m/s)', () {
      // DN50 → v ≈ 2.546 m/s > 2.0, rejected.
      // DN65 → v ≈ 1.507 m/s ≤ 2.0, chosen.
      final result = sizeForFlow(
        flow: const FlowRate(0.005),
        maxVelocity: const Velocity(2.0),
      );
      expect(result.diameter.inMillimeters, closeTo(65.0, 0.001));
    });

    test('mean velocity in DN65 is ≈ 1.507 m/s', () {
      // v = 0.005 / (π × 0.065² / 4) = 0.005 / 0.0033183 ≈ 1.507 m/s
      final result = sizeForFlow(
        flow: const FlowRate(0.005),
        maxVelocity: const Velocity(2.0),
      );
      expect(result.velocity.metersPerSecond, closeTo(1.507, 0.005));
    });

    test('velocity is at or below the 2.0 m/s limit', () {
      final result = sizeForFlow(
        flow: const FlowRate(0.005),
        maxVelocity: const Velocity(2.0),
      );
      expect(result.velocity.metersPerSecond, lessThanOrEqualTo(2.0));
    });
  });

  group('sizeForFlow — friction parameters for DN65 at 5 L/s', () {
    test('Reynolds number is positive', () {
      final result = sizeForFlow(
        flow: const FlowRate(0.005),
        maxVelocity: const Velocity(2.0),
      );
      expect(result.reynolds, greaterThan(0));
    });

    test('Swamee–Jain friction factor is in the plausible band (0.01, 0.05)',
        () {
      final result = sizeForFlow(
        flow: const FlowRate(0.005),
        maxVelocity: const Velocity(2.0),
      );
      expect(result.frictionFactor, greaterThan(0.01));
      expect(result.frictionFactor, lessThan(0.05));
    });

    test('head loss per metre is positive', () {
      final result = sizeForFlow(
        flow: const FlowRate(0.005),
        maxVelocity: const Velocity(2.0),
      );
      expect(result.headLossPerMetre.meters, greaterThan(0));
    });
  });

  group('sizeForFlow — defaults (no explicit maxVelocity, PVC material)', () {
    test('uses SNI 2.0 m/s limit when maxVelocity is omitted', () {
      // Tiny flow → almost any diameter qualifies; confirm v ≤ 2.0 m/s.
      final result = sizeForFlow(flow: FlowRate.litersPerSecond(0.1));
      expect(result.velocity.metersPerSecond, lessThanOrEqualTo(2.0));
    });
  });

  group('sizeForFlow — fallback when flow overloads all standard diameters',
      () {
    test('selects DN200 (largest) for an extremely large flow', () {
      // Q = 1 m³/s is above all DN200 capacity at 2 m/s;
      // the function must return DN200 rather than throw.
      final result = sizeForFlow(flow: const FlowRate(1.0));
      expect(result.diameter.inMillimeters, closeTo(200.0, 0.001));
    });
  });

  group('designFlowForFixtureUnits', () {
    test('100 fixture units → ≈ 3.03 L/s (flush-tank demand curve)', () {
      // Table anchor at UBAP = 100: FlowRate(0.00303333) = 3.033 L/s.
      // fixtureUnits == lower-interval bound → t = 0, no interpolation.
      final q = designFlowForFixtureUnits(100);
      expect(q.inLitersPerSecond, closeTo(3.03, 0.05));
    });

    test('0 fixture units → 0 flow', () {
      expect(
        designFlowForFixtureUnits(0).inLitersPerSecond,
        closeTo(0.0, 1e-9),
      );
    });

    test('positive fixture units produce positive flow', () {
      expect(designFlowForFixtureUnits(50).inLitersPerSecond, greaterThan(0));
    });
  });
}
