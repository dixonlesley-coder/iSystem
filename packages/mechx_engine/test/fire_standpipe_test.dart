/// Tests for the §P5 fire standpipe / hydrant + fire-pump sizing module.
///
/// ─────────────────────────────── IMPORTANT NOTICE ───────────────────────────
/// All design constants used here (flow per riser, residual pressure) are
/// UNVERIFIED PLACEHOLDERS based on general fire-protection practice.
/// They must be validated against SNI 03-1745-2000 (standpipe/hydrant) and
/// SNI 03-6570-2001 (fire pump) before production use.
/// ─────────────────────────────────────────────────────────────────────────────
///
/// Hand-computed arithmetic
/// ────────────────────────
/// Physical constants used throughout (from hydraulics.dart):
///   g   = 9.81 m/s²
///   ρ   = 1000 kg/m³
///   ρ·g = 9 810 N/m³
///
/// ── Case A: risers = 2, buildingHeight = 40 m, frictionAllowance = 15 m,
///            pumpEfficiency = 0.70  ──────────────────────────────────────────
///
///   requiredFlow
///     = 500 + 250 × (2 − 1) = 750 L/min
///     = 750 / 60 000 m³/s   = 0.012 500 m³/s   (12.5 L/s)
///
///   topResidualPressure = 450 kPa = 450 000 Pa   // VERIFY
///
///   residualHead = 450 000 / (1 000 × 9.81)
///               = 450 000 / 9 810
///               = 45.871 56… m
///
///   pumpHead = 40 + 15 + 45.871 56…
///            = 100.871 56… m
///
///   hydraulicPower = ρ · g · Q · H
///                  = 1 000 × 9.81 × 0.012 500 × 100.871 56…
///                  = 9 810 × 0.012 500 × 100.871 56…
///
///   Exact cancellation (the 9 810 in the power formula cancels with the
///   9 810 in headFromPressure, leaving the contribution of the residual-
///   pressure term as simply 450 000 × Q):
///
///     P_hyd = ρ·g·Q·(h_static + h_friction + P_res/(ρ·g))
///           = ρ·g·Q·(55) + Q·P_res
///           = 9 810 × 0.012 500 × 55 + 0.012 500 × 450 000
///           = 6 741.5625 + 5 625.0
///           = 12 366.5625 W
///
///   Re-check with the direct product:
///     9 810 × 0.012 500 = 122.625
///     122.625 × 100.871 56… :
///       122.625 × 100 = 12 262.5
///       residualHead contribution:
///         122.625 × 45.871 56… = 122.625 × (450 000 / 9 810)
///                               = 122.625 × 45.871 56…
///         = (9 810 × 0.012 500) × (450 000 / 9 810)
///         = 0.012 500 × 450 000
///         = 5 625.0
///       frictionAllowance contribution:
///         122.625 × 15 = 1 838.375   [1 837.875 → recheck]
///         122.625 × 15 = 1 839.375
///       staticLift contribution:
///         122.625 × 40 = 4 905.0
///     Sum = 4 905.0 + 1 839.375 + 5 625.0 = 12 369.375 W
///
///   The correct value is 12 369.375 W.
///
///   Verification:
///     122.625 × 55 = 122.625 × 50 + 122.625 × 5
///                  = 6 131.25 + 613.125
///                  = 6 744.375
///     6 744.375 + 5 625.0 = 12 369.375 W  ✓
///
///   shaftPower = 12 369.375 / 0.70 = 17 670.535 714… W
///
/// ── Case B: risers = 1 (single-riser minimum) ─────────────────────────────
///
///   requiredFlow = 500 L/min = 500/60 000 m³/s = 0.008 333… m³/s (8.333 L/s)
///
/// ── Case C: risers = 4 (flow cap applies) ─────────────────────────────────
///
///   Uncapped = 500 + 250 × 3 = 1 250 L/min → exactly at cap → 1 250 L/min
///   requiredFlow = 1 250 / 60 000 = 0.020 833… m³/s (20.833 L/s)
///
/// ── Case D: risers = 6 (above cap) ───────────────────────────────────────
///
///   Uncapped = 500 + 250 × 5 = 1 750 L/min → capped at 1 250 L/min
///   requiredFlow = 1 250 L/min (same as case C)
library;

import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  // ── Constants ──────────────────────────────────────────────────────────────

  group('placeholder constants (// VERIFY against SNI)', () {
    test('kFirstRiserFlowLpm is 500', () {
      expect(kFirstRiserFlowLpm, equals(500.0));
    });

    test('kAdditionalRiserFlowLpm is 250', () {
      expect(kAdditionalRiserFlowLpm, equals(250.0));
    });

    test('kMaxStandpipeFlowLpm is 1250', () {
      expect(kMaxStandpipeFlowLpm, equals(1250.0));
    });

    test('kTopResidualPressureKpa is 450', () {
      expect(kTopResidualPressureKpa, equals(450.0));
    });
  });

  // ── standpipeFlow ──────────────────────────────────────────────────────────

  group('standpipeFlow — flow demand by riser count', () {
    test('1 riser → 500 L/min (8.333 L/s)', () {
      // Q = 500 + 250 × 0 = 500 L/min = 500/60 000 m³/s
      final q = standpipeFlow(1);
      expect(q.inLitersPerSecond, closeTo(500.0 / 60.0, 1e-9));
    });

    test('2 risers → 750 L/min (12.5 L/s)', () {
      // Q = 500 + 250 × 1 = 750 L/min = 750/60 000 m³/s = 0.01250 m³/s
      final q = standpipeFlow(2);
      expect(q.inLitersPerSecond, closeTo(12.5, 1e-9));
    });

    test('3 risers → 1000 L/min (16.667 L/s)', () {
      // Q = 500 + 250 × 2 = 1000 L/min
      final q = standpipeFlow(3);
      expect(q.inLitersPerSecond, closeTo(1000.0 / 60.0, 1e-9));
    });

    test('4 risers → 1250 L/min (cap; 20.833 L/s)', () {
      // Q = 500 + 250 × 3 = 1250 L/min → exactly at cap
      final q = standpipeFlow(4);
      expect(q.inLitersPerSecond, closeTo(1250.0 / 60.0, 1e-9));
    });

    test('6 risers → 1250 L/min (cap still applies)', () {
      // Uncapped: 500 + 250 × 5 = 1750 → clamped to 1250 L/min
      final q = standpipeFlow(6);
      expect(q.inLitersPerSecond, closeTo(1250.0 / 60.0, 1e-9));
    });

    test('result for 4 and 6 risers is the same (cap)', () {
      expect(
        standpipeFlow(4).cubicMetersPerSecond,
        closeTo(standpipeFlow(6).cubicMetersPerSecond, 1e-12),
      );
    });
  });

  // ── Case A: two risers, 40 m building ─────────────────────────────────────

  group(
      'designStandpipe — Case A: 2 risers, 40 m, friction 15 m, η = 0.70',
      () {
    late FireStandpipeDesign design;

    setUp(() {
      design = designStandpipe(
        risers: 2,
        buildingHeight: const Length(40),
        frictionAllowance: const Head(15),
        pumpEfficiency: 0.70,
      );
    });

    // requiredFlow ────────────────────────────────────────────────────────────
    test('requiredFlow is 750 L/min = 12.5 L/s', () {
      // 500 + 250 × 1 = 750 L/min = 12.5 L/s
      expect(design.requiredFlow.inLitersPerSecond, closeTo(12.5, 1e-9));
    });

    // topResidualPressure ─────────────────────────────────────────────────────
    test('topResidualPressure is 450 kPa // VERIFY', () {
      expect(
        design.topResidualPressure.inKiloPascals,
        closeTo(450.0, 1e-9),
      );
    });

    // pumpHead ────────────────────────────────────────────────────────────────
    test('pumpHead ≈ 100.872 m  (40 + 15 + 450000/9810)', () {
      // residualHead = 450 000 / 9 810 = 45.871 56… m
      // pumpHead     = 40 + 15 + 45.871 56… = 100.871 56… m
      expect(design.pumpHead.meters, closeTo(100.8716, 5e-4));
    });

    // pumpHydraulicPower ──────────────────────────────────────────────────────
    test('pumpHydraulicPower ≈ 12 369.375 W', () {
      // P_hyd = ρ·g·Q·H
      //       = 9810 × 0.01250 × 100.87156…
      //       = 122.625 × 100.87156…
      //       = 122.625 × 55 + 0.01250 × 450 000
      //       = 6 744.375 + 5 625.0
      //       = 12 369.375 W
      expect(design.pumpHydraulicPower.watts, closeTo(12369.375, 0.05));
    });

    // pumpShaftPower ──────────────────────────────────────────────────────────
    test('pumpShaftPower ≈ 17 670.536 W  (12369.375 / 0.70)', () {
      // 12 369.375 / 0.70 = 17 670.535 714… W
      expect(design.pumpShaftPower.watts, closeTo(17670.536, 0.05));
    });

    test('pumpShaftPower > pumpHydraulicPower (efficiency < 1)', () {
      expect(
        design.pumpShaftPower.watts,
        greaterThan(design.pumpHydraulicPower.watts),
      );
    });

    test('pumpShaftPower ≈ hydraulicPower / 0.70', () {
      expect(
        design.pumpShaftPower.watts,
        closeTo(design.pumpHydraulicPower.watts / 0.70, 0.01),
      );
    });

    test('pumpHydraulicPower in kW ≈ 12.369 kW', () {
      expect(design.pumpHydraulicPower.inKiloWatts, closeTo(12.369, 0.05));
    });

    test('pumpShaftPower in kW ≈ 17.671 kW', () {
      expect(design.pumpShaftPower.inKiloWatts, closeTo(17.671, 0.05));
    });
  });

  // ── Case B: single riser ──────────────────────────────────────────────────

  group('designStandpipe — Case B: 1 riser (minimum), 30 m building', () {
    late FireStandpipeDesign design;

    setUp(() {
      design = designStandpipe(
        risers: 1,
        buildingHeight: const Length(30),
      );
    });

    test('requiredFlow is 500 L/min = 8.333 L/s', () {
      // Q = 500 L/min = 500/60 L/s = 8.3333… L/s
      expect(design.requiredFlow.inLitersPerSecond, closeTo(500.0 / 60.0, 1e-9));
    });

    test('topResidualPressure is 450 kPa // VERIFY', () {
      expect(design.topResidualPressure.inKiloPascals, closeTo(450.0, 1e-9));
    });

    test('pumpHead = 30 + 15 + 45.872 ≈ 90.872 m', () {
      // residualHead = 450 000 / 9 810 = 45.8716… m
      // pumpHead     = 30 + 15 + 45.8716… = 90.8716… m
      expect(design.pumpHead.meters, closeTo(90.8716, 5e-4));
    });

    test('pumpHydraulicPower is positive', () {
      expect(design.pumpHydraulicPower.watts, greaterThan(0));
    });

    test('pumpShaftPower > pumpHydraulicPower', () {
      expect(
        design.pumpShaftPower.watts,
        greaterThan(design.pumpHydraulicPower.watts),
      );
    });
  });

  // ── Case C / D: flow cap (≥ 4 risers) ────────────────────────────────────

  group('designStandpipe — Case C/D: flow cap (≥ 4 risers)', () {
    test('4 risers → requiredFlow = 1250 L/min (20.833 L/s)', () {
      final design = designStandpipe(
        risers: 4,
        buildingHeight: const Length(50),
      );
      // 500 + 250 × 3 = 1250 L/min → exactly at cap
      expect(
        design.requiredFlow.inLitersPerSecond,
        closeTo(1250.0 / 60.0, 1e-9),
      );
    });

    test('6 risers → requiredFlow still 1250 L/min (cap enforced)', () {
      final design = designStandpipe(
        risers: 6,
        buildingHeight: const Length(50),
      );
      // Uncapped: 1750 L/min → capped to 1250 L/min
      expect(
        design.requiredFlow.inLitersPerSecond,
        closeTo(1250.0 / 60.0, 1e-9),
      );
    });

    test('4-riser and 6-riser designs have identical requiredFlow', () {
      final d4 = designStandpipe(
        risers: 4,
        buildingHeight: const Length(50),
      );
      final d6 = designStandpipe(
        risers: 6,
        buildingHeight: const Length(50),
      );
      expect(
        d4.requiredFlow.cubicMetersPerSecond,
        closeTo(d6.requiredFlow.cubicMetersPerSecond, 1e-12),
      );
    });
  });

  // ── Parametric sanity ─────────────────────────────────────────────────────

  group('designStandpipe — sanity across configurations', () {
    test('taller building → larger pumpHead', () {
      final low = designStandpipe(
        risers: 2,
        buildingHeight: const Length(20),
      );
      final high = designStandpipe(
        risers: 2,
        buildingHeight: const Length(60),
      );
      expect(high.pumpHead.meters, greaterThan(low.pumpHead.meters));
    });

    test('more risers (uncapped) → larger hydraulicPower', () {
      final r2 = designStandpipe(
        risers: 2,
        buildingHeight: const Length(40),
      );
      final r3 = designStandpipe(
        risers: 3,
        buildingHeight: const Length(40),
      );
      expect(
        r3.pumpHydraulicPower.watts,
        greaterThan(r2.pumpHydraulicPower.watts),
      );
    });

    test('higher efficiency → lower shaftPower for same flow and head', () {
      final eta65 = designStandpipe(
        risers: 2,
        buildingHeight: const Length(40),
        pumpEfficiency: 0.65,
      );
      final eta80 = designStandpipe(
        risers: 2,
        buildingHeight: const Length(40),
        pumpEfficiency: 0.80,
      );
      expect(eta80.pumpShaftPower.watts, lessThan(eta65.pumpShaftPower.watts));
    });

    test('topResidualPressure is always 450 kPa // VERIFY', () {
      for (final risers in [1, 2, 4]) {
        final design = designStandpipe(
          risers: risers,
          buildingHeight: const Length(30),
        );
        expect(
          design.topResidualPressure.inKiloPascals,
          closeTo(450.0, 1e-9),
          reason: 'Failed for risers = $risers',
        );
      }
    });
  });
}
