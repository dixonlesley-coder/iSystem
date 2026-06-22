/// Tests for the §P5 fire standpipe / hydrant + fire-pump sizing module.
///
/// Design constants are sourced from SNI 03-1745-2000 (standpipe/hydrant) and
/// SNI 03-6570-2001 (fire pump):
///   • Flow: 550 gpm most-remote riser + 250 gpm per additional riser, ≤1250
///     gpm cap (converted to L/min via the US gallon = 3.785411784 L).
///   • Residual: 6.9 bar (690 kPa) Class I/III, 4.5 bar (450 kPa) Class II.
///   • Minimum Class I/III riser diameter: 100 mm.
///
/// Expected values are derived from those constants in-test (no magic numbers)
/// using ρ·g = 1000 × 9.81 = 9810 N/m³ to match hydraulics.dart.
library;

import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// ρ·g for water in the engine's hydraulic kernel (1000 kg/m³ × 9.81 m/s²).
const double rhoG = 1000.0 * 9.81; // 9810 N/m³

/// US liquid gallon in litres (matches the engine's private conversion).
const double gal = 3.785411784;

void main() {
  // ── Constants (SNI 03-1745-2000) ─────────────────────────────────────────────

  group('design constants (SNI 03-1745-2000)', () {
    test('kFirstRiserFlowLpm is 550 gpm', () {
      expect(kFirstRiserFlowLpm, closeTo(550.0 * gal, 1e-9)); // ≈ 2082 L/min
    });

    test('kAdditionalRiserFlowLpm is 250 gpm', () {
      expect(kAdditionalRiserFlowLpm, closeTo(250.0 * gal, 1e-9)); // ≈ 946
    });

    test('kMaxStandpipeFlowLpm is 1250 gpm', () {
      expect(kMaxStandpipeFlowLpm, closeTo(1250.0 * gal, 1e-9)); // ≈ 4732
    });

    test('residual pressures: 690 kPa Class I/III, 450 kPa Class II', () {
      expect(kResidualPressureClassIKpa, equals(690.0));
      expect(kResidualPressureClassIIKpa, equals(450.0));
      expect(residualPressureKpa(StandpipeClass.classI), equals(690.0));
      expect(residualPressureKpa(StandpipeClass.classIII), equals(690.0));
      expect(residualPressureKpa(StandpipeClass.classII), equals(450.0));
    });

    test('minimum Class I/III riser diameter is 100 mm', () {
      expect(kMinRiserDiameterMm, equals(100.0));
    });
  });

  // ── standpipeFlow ──────────────────────────────────────────────────────────

  group('standpipeFlow — flow demand by riser count', () {
    test('1 riser → 550 gpm', () {
      final q = standpipeFlow(1);
      expect(q.inLitersPerMinute, closeTo(550.0 * gal, 1e-9));
    });

    test('2 risers → 800 gpm (550 + 250)', () {
      final q = standpipeFlow(2);
      expect(q.inLitersPerMinute, closeTo(800.0 * gal, 1e-9));
    });

    test('3 risers → 1050 gpm', () {
      final q = standpipeFlow(3);
      expect(q.inLitersPerMinute, closeTo(1050.0 * gal, 1e-9));
    });

    test('4 risers → 1250 gpm (cap; uncapped 1300 → clamped)', () {
      // 550 + 250×3 = 1300 gpm → clamped to the 1250 gpm cap.
      final q = standpipeFlow(4);
      expect(q.inLitersPerMinute, closeTo(1250.0 * gal, 1e-9));
    });

    test('6 risers → 1250 gpm (cap still applies)', () {
      final q = standpipeFlow(6);
      expect(q.inLitersPerMinute, closeTo(1250.0 * gal, 1e-9));
    });

    test('result for 4 and 6 risers is the same (cap)', () {
      expect(
        standpipeFlow(4).cubicMetersPerSecond,
        closeTo(standpipeFlow(6).cubicMetersPerSecond, 1e-12),
      );
    });
  });

  // ── Case A: two risers, 40 m building, Class I ────────────────────────────

  group('designStandpipe — Case A: 2 risers, 40 m, friction 15 m, η = 0.70',
      () {
    late FireStandpipeDesign design;

    // Expected values derived from the SNI constants.
    const qLpm = kFirstRiserFlowLpm + kAdditionalRiserFlowLpm; // 2 risers
    const qM3s = qLpm / 60000.0;
    const residualHead = kResidualPressureClassIKpa * 1000.0 / rhoG; // m
    const expHead = 40.0 + 15.0 + residualHead;
    const expHyd = rhoG * qM3s * expHead;
    const expShaft = expHyd / 0.70;

    setUp(() {
      design = designStandpipe(
        risers: 2,
        buildingHeight: const Length(40),
        frictionAllowance: const Head(15),
        pumpEfficiency: 0.70,
      );
    });

    test('defaults to Class I', () {
      expect(design.standpipeClass, StandpipeClass.classI);
    });

    test('requiredFlow is 800 gpm', () {
      expect(design.requiredFlow.inLitersPerMinute, closeTo(800.0 * gal, 1e-9));
    });

    test('topResidualPressure is 690 kPa (Class I)', () {
      expect(design.topResidualPressure.inKiloPascals, closeTo(690.0, 1e-9));
    });

    test('minRiserDiameter is 100 mm', () {
      expect(design.minRiserDiameter.inMillimeters, closeTo(100.0, 1e-9));
    });

    test('pumpHead = 40 + 15 + 690000/9810', () {
      expect(design.pumpHead.meters, closeTo(expHead, 1e-6));
    });

    test('pumpHydraulicPower = ρ·g·Q·H', () {
      expect(design.pumpHydraulicPower.watts, closeTo(expHyd, 1e-3));
    });

    test('pumpShaftPower = hydraulicPower / 0.70', () {
      expect(design.pumpShaftPower.watts, closeTo(expShaft, 1e-3));
    });

    test('pumpShaftPower > pumpHydraulicPower (efficiency < 1)', () {
      expect(
        design.pumpShaftPower.watts,
        greaterThan(design.pumpHydraulicPower.watts),
      );
    });
  });

  // ── Case B: single riser, Class II ────────────────────────────────────────

  group('designStandpipe — Case B: 1 riser (minimum), 30 m, Class II', () {
    late FireStandpipeDesign design;

    setUp(() {
      design = designStandpipe(
        risers: 1,
        buildingHeight: const Length(30),
        standpipeClass: StandpipeClass.classII,
      );
    });

    test('requiredFlow is 550 gpm', () {
      expect(design.requiredFlow.inLitersPerMinute, closeTo(550.0 * gal, 1e-9));
    });

    test('topResidualPressure is 450 kPa (Class II)', () {
      expect(design.topResidualPressure.inKiloPascals, closeTo(450.0, 1e-9));
    });

    test('pumpHead = 30 + 15 + 450000/9810', () {
      const expHead = 30.0 + 15.0 + 450000.0 / rhoG;
      expect(design.pumpHead.meters, closeTo(expHead, 1e-6));
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
    test('4 risers → requiredFlow = 1250 gpm', () {
      final design = designStandpipe(risers: 4, buildingHeight: const Length(50));
      expect(
        design.requiredFlow.inLitersPerMinute,
        closeTo(1250.0 * gal, 1e-9),
      );
    });

    test('6 risers → requiredFlow still 1250 gpm (cap enforced)', () {
      final design = designStandpipe(risers: 6, buildingHeight: const Length(50));
      expect(
        design.requiredFlow.inLitersPerMinute,
        closeTo(1250.0 * gal, 1e-9),
      );
    });

    test('4-riser and 6-riser designs have identical requiredFlow', () {
      final d4 = designStandpipe(risers: 4, buildingHeight: const Length(50));
      final d6 = designStandpipe(risers: 6, buildingHeight: const Length(50));
      expect(
        d4.requiredFlow.cubicMetersPerSecond,
        closeTo(d6.requiredFlow.cubicMetersPerSecond, 1e-12),
      );
    });
  });

  // ── Parametric sanity ─────────────────────────────────────────────────────

  group('designStandpipe — sanity across configurations', () {
    test('taller building → larger pumpHead', () {
      final low = designStandpipe(risers: 2, buildingHeight: const Length(20));
      final high = designStandpipe(risers: 2, buildingHeight: const Length(60));
      expect(high.pumpHead.meters, greaterThan(low.pumpHead.meters));
    });

    test('more risers (uncapped) → larger hydraulicPower', () {
      final r2 = designStandpipe(risers: 2, buildingHeight: const Length(40));
      final r3 = designStandpipe(risers: 3, buildingHeight: const Length(40));
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

    test('Class I residual (690 kPa) exceeds Class II (450 kPa) → higher head',
        () {
      final classI = designStandpipe(
        risers: 2,
        buildingHeight: const Length(30),
        standpipeClass: StandpipeClass.classI,
      );
      final classII = designStandpipe(
        risers: 2,
        buildingHeight: const Length(30),
        standpipeClass: StandpipeClass.classII,
      );
      expect(classI.pumpHead.meters, greaterThan(classII.pumpHead.meters));
    });
  });
}
