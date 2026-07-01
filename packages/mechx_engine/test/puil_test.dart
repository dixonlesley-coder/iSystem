import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart' show VerificationStatus;
import 'package:test/test.dart';

/// Seed tests for the PUIL 2011 (SNI 0225:2011) electrical standards profile.
/// Expected values are checked by hand against the source tables (Supreme Cable
/// catalogue + IEC 60364/60898/60947). The profile is pluggable DATA; these
/// tests pin the values and the provenance honesty surface (§12.6).
void main() {
  const p = PuilProfile();

  group('identity + supply voltages', () {
    test('name/revision are present', () {
      expect(p.name, contains('PUIL'));
      expect(p.revision, contains('SNI 0225:2011'));
    });

    test('nominal voltages: 400 / 220 / 230 V, all unverified', () {
      expect(p.nominalLineVoltage.value.volts, 400.0);
      expect(p.nominalSinglePhaseVoltage.value.volts, 220.0);
      expect(p.nominalPhaseVoltage.value.volts, 230.0);
      expect(p.nominalFrequencyHz.value, 50.0);
      // Nothing verbatim until checked against the official PUIL PDF.
      expect(p.nominalLineVoltage.isUnverified, isTrue);
    });
  });

  group('voltage-drop limits + continuous factor', () {
    test('5 % general, 3 % lighting', () {
      expect(p.maxVoltageDropGeneral.value, 0.05);
      expect(p.maxVoltageDropLighting.value, 0.03);
    });

    test('continuous-load factor = 1.25', () {
      expect(p.continuousLoadFactor.value, 1.25);
    });
  });

  group('standard sections + min sections', () {
    test('16 standard copper sections, 1.5 … 300 mm²', () {
      expect(p.standardSectionsMm2.length, 16);
      expect(p.standardSectionsMm2.first, 1.5);
      expect(p.standardSectionsMm2.last, 300.0);
    });

    test('PUIL final/trunk minimums', () {
      expect(p.minSectionMm2(lighting: true, trunk: false, threePhase: false),
          1.5);
      expect(p.minSectionMm2(lighting: false, trunk: false, threePhase: false),
          2.5);
      expect(p.minSectionMm2(lighting: false, trunk: true, threePhase: true), 4);
      expect(p.minSectionMm2(lighting: false, trunk: true, threePhase: false),
          2.5);
    });
  });

  group('ampacity (KHA)', () {
    test('Cu/PVC method B1 (conduit): 1.5→18, 16→80, 300→500 A', () {
      expect(p.ampacity(1.5).amperes, 18.0);
      expect(p.ampacity(16).amperes, 80.0);
      expect(p.ampacity(300).amperes, 500.0);
    });

    test('Cu/PVC buried (method D) reads the "in ground" column', () {
      expect(
        p.ampacity(1.5, method: CableInstallMethod.buried).amperes,
        24.0, // in-ground beats in-air at small sections (soil heat-sink)
      );
      expect(
        p.ampacity(300, method: CableInstallMethod.buried).amperes,
        465.0, // and crosses below in-air at large sections
      );
    });

    test('Cu/XLPE method B1: 16 mm² → 88 A (higher than PVC 80)', () {
      expect(
        p.ampacity(16, insulation: ConductorInsulation.xlpe).amperes,
        88.0,
      );
    });

    test('aluminium derates copper by ×0.78: 16 mm² PVC = 80×0.78 = 62.4 A', () {
      expect(
        p.ampacity(16, material: ConductorMaterial.aluminum).amperes,
        closeTo(62.4, 1e-9),
      );
    });

    test('wall (C) and tray (E) PVC read the in-air base table', () {
      expect(p.ampacity(50, method: CableInstallMethod.wall).amperes, 160.0);
      expect(p.ampacity(50, method: CableInstallMethod.tray).amperes, 160.0);
    });

    test('unknown section → 0 A', () {
      expect(p.ampacity(2.0).amperes, 0.0);
    });
  });

  group('resistance / reactance', () {
    test('Cu 50 mm² = 0.463 Ω/km; 1.5 mm² = 14.5 Ω/km', () {
      expect(p.conductorResistanceOhmPerKm(50), 0.463);
      expect(p.conductorResistanceOhmPerKm(1.5), 14.5);
    });

    test('aluminium resistance = copper × 1.61', () {
      expect(
        p.conductorResistanceOhmPerKm(50, material: ConductorMaterial.aluminum),
        closeTo(0.463 * 1.61, 1e-12),
      );
    });

    test('reactance ≈ 0.08 Ω/km', () {
      expect(p.conductorReactanceOhmPerKm, 0.08);
    });
  });

  group('derating tables (use DOUBLE keys)', () {
    test('ambient base 30 °C = 1.0; PVC@40 = 0.87; XLPE@40 = 0.91', () {
      expect(p.ambientTempFactors(ConductorInsulation.pvc)[30.0], 1.0);
      expect(p.ambientTempFactors(ConductorInsulation.pvc)[40.0], 0.87);
      expect(p.ambientTempFactors(ConductorInsulation.xlpe)[40.0], 0.91);
    });

    test('grouping 1→1.0, 9→0.5; soil ref 2.5 K·m/W → 1.0', () {
      expect(p.groupingFactors[1.0], 1.0);
      expect(p.groupingFactors[9.0], 0.5);
      expect(p.soilThermalResistivityFactors[2.5], 1.0);
      expect(p.soilThermalResistivityReferenceKmW, 2.5);
    });
  });

  group('protection ladders + curve', () {
    test('MCB 6…63, MCCB 80…1600; combined ascending', () {
      expect(p.mcbRatingsA.first, 6);
      expect(p.mcbRatingsA.last, 63);
      expect(p.mccbRatingsA.first, 80);
      expect(p.mccbRatingsA.last, 1600);
      expect(p.standardBreakerRatingsA.length,
          p.mcbRatingsA.length + p.mccbRatingsA.length);
    });

    test('class: ≤63 A MCB, above MCCB', () {
      expect(p.breakerClassFor(63), BreakerClass.mcb);
      expect(p.breakerClassFor(80), BreakerClass.mccb);
    });

    test('curve: lighting→B, motor→D, else C', () {
      expect(p.recommendedCurve(lighting: true, motor: false), BreakerCurve.b);
      expect(p.recommendedCurve(lighting: false, motor: true), BreakerCurve.d);
      expect(p.recommendedCurve(lighting: false, motor: false), BreakerCurve.c);
    });
  });

  group('protective conductors (IEC 60364-5-54)', () {
    test('PE: S≤16→S, 16<S≤35→16, S>35→ next std ≥ S/2', () {
      expect(p.peConductorSizeMm2(10), 10);
      expect(p.peConductorSizeMm2(16), 16);
      expect(p.peConductorSizeMm2(25), 16);
      expect(p.peConductorSizeMm2(70), 35); // 70/2 = 35
      expect(p.peConductorSizeMm2(240), 120); // 240/2 = 120
    });

    test('neutral: full unless reduced above 16 mm²', () {
      expect(p.neutralConductorSizeMm2(25), 25);
      expect(p.neutralConductorSizeMm2(50, reduced: true), 25); // ≥ max(16,25)
      expect(p.neutralConductorSizeMm2(10, reduced: true), 10); // ≤16 stays full
    });

    test('main earthing clamp 16..50; bonding max(6,PE/2) cap 25', () {
      expect(p.mainEarthingConductorMm2(10), 16);
      expect(p.mainEarthingConductorMm2(70), 50);
      expect(p.mainBondingConductorMm2(10), 6); // max(6,5)=6
      expect(p.mainBondingConductorMm2(50), 25); // 25, capped
      expect(p.mainBondingConductorMm2(120), 25); // 60 → capped 25
    });

    test('max earth-electrode resistance = 5 Ω, now verified (PUIL grounding)',
        () {
      expect(p.maxEarthResistance.value.ohms, 5.0);
      expect(p.maxEarthResistance.isUnverified, isFalse);
    });

    test('the 5 % general voltage drop is verified (PUIL cl. 4.2.3.1)', () {
      expect(p.maxVoltageDropGeneral.value, 0.05);
      expect(p.maxVoltageDropGeneral.isUnverified, isFalse);
      expect(p.maxVoltageDropGeneral.status, VerificationStatus.sniVerbatim);
    });
  });

  group('provenance contract (§12.6)', () {
    test('verifyChecklist holds only unverified items', () {
      expect(p.verifyChecklist, isNotEmpty);
      expect(p.verifyChecklist.every((v) => v.isUnverified), isTrue);
    });

    test('the verify checklist carries no verbatim (promoted) values', () {
      // Promoted items (5 % VD, ≤5 Ω earth) leave the checklist; only the
      // genuine secondary-source / general-practice debt remains here.
      for (final v in p.verifyChecklist) {
        expect(v.status, isNot(VerificationStatus.sniVerbatim));
      }
    });

    test('the ampacity tables are flagged for verification', () {
      expect(
        p.verifyChecklist.any((v) => v.citation.contains('Supreme Cable')),
        isTrue,
      );
    });
  });
}
