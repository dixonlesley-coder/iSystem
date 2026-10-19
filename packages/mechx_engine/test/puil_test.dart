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
    test('Cu/PVC method B1 (conduit): 1.5→15.5, 16→68, 300→394 A', () {
      // Re-derived Round 11: conduit is IEC 60364-5-52 Table B.52.4 column B1
      // (3 loaded conductors) — no longer the Supreme "in air" (method E)
      // catalogue figures 18 / 80 / 500 A, which overrated conduit 18–27 %.
      expect(p.ampacity(1.5).amperes, 15.5);
      expect(p.ampacity(16).amperes, 68.0);
      expect(p.ampacity(300).amperes, 394.0);
    });

    test('Cu/PVC buried (method D) reads the IEC D1 3-loaded column', () {
      // Re-derived 2026-10 (audit elec-core-5): D is IEC 60364-5-52 Table
      // B.52.4 column D1 (in duct in ground, 2.5 K·m/W, 3 loaded) — the SAME
      // basis as the XLPE D column — not the direct-in-ground catalogue
      // figures (1.5 = 24, 300 = 465) that read above 90 °C XLPE.
      expect(
        p.ampacity(1.5, method: CableInstallMethod.buried).amperes,
        18.0,
      );
      expect(
        p.ampacity(300, method: CableInstallMethod.buried).amperes,
        316.0,
      );
    });

    test('Cu/XLPE method B1: 16 mm² → 88 A (higher than PVC 68)', () {
      expect(
        p.ampacity(16, insulation: ConductorInsulation.xlpe).amperes,
        88.0,
      );
    });

    test('aluminium derates copper by ×0.78: 16 mm² PVC = 68×0.78 = 53.04 A',
        () {
      expect(
        p.ampacity(16, material: ConductorMaterial.aluminum).amperes,
        closeTo(53.04, 1e-9),
      );
    });

    test('wall (C) reads B.52.4 column C; tray (E) the in-air base table', () {
      // Round 11: 50 mm² PVC — C (clipped direct) 144 A, E (free air) 160 A.
      expect(p.ampacity(50, method: CableInstallMethod.wall).amperes, 144.0);
      expect(p.ampacity(50, method: CableInstallMethod.tray).amperes, 160.0);
    });

    // Round 11 property: for EVERY standard section, PVC ranks by installation
    // method exactly as the physics does — conduit (B1) ≤ wall (C) ≤ free air
    // (E) — and a 70 °C PVC conductor never out-rates a 90 °C XLPE one on the
    // same method. (The old single PVC table read B1 == C == E.)
    test('property: PVC conduit ≤ wall ≤ air, and PVC ≤ XLPE per method', () {
      for (final csa in p.standardSectionsMm2) {
        double a(CableInstallMethod m, ConductorInsulation ins) =>
            p.ampacity(csa, method: m, insulation: ins).amperes;
        final pvcB1 = a(CableInstallMethod.conduit, ConductorInsulation.pvc);
        final pvcC = a(CableInstallMethod.wall, ConductorInsulation.pvc);
        final pvcE = a(CableInstallMethod.air, ConductorInsulation.pvc);
        expect(pvcB1, greaterThan(0), reason: '$csa mm² tabulated');
        expect(pvcB1, lessThan(pvcC), reason: '$csa mm² B1 < C');
        expect(pvcC, lessThan(pvcE), reason: '$csa mm² C < E');
        for (final m in CableInstallMethod.values) {
          expect(a(m, ConductorInsulation.pvc),
              lessThanOrEqualTo(a(m, ConductorInsulation.xlpe)),
              reason: '$csa mm² $m PVC ≤ XLPE');
        }
      }
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
    test('MCB 6…63, MCCB 80…1600, ACB 2000…4000; combined ascending', () {
      expect(p.mcbRatingsA.first, 6);
      expect(p.mcbRatingsA.last, 63);
      expect(p.mccbRatingsA.first, 80);
      expect(p.mccbRatingsA.last, 1600);
      // Round 23 — the ACB frames above the MCCB ladder (a 1600 kVA service's
      // 1 600 000 / (√3 · 400) = 2309 A FLC takes the 2500 A ACB).
      expect(p.acbRatingsA, [2000, 2500, 3200, 4000]);
      expect(p.standardBreakerRatingsA.length,
          p.mcbRatingsA.length + p.mccbRatingsA.length + p.acbRatingsA.length);
      final l = p.standardBreakerRatingsA;
      for (var i = 1; i < l.length; i++) {
        expect(l[i], greaterThan(l[i - 1]));
      }
    });

    test('class: ≤63 A MCB, ≤1600 A MCCB, above ACB', () {
      expect(p.breakerClassFor(63), BreakerClass.mcb);
      expect(p.breakerClassFor(80), BreakerClass.mccb);
      expect(p.breakerClassFor(1600), BreakerClass.mccb);
      expect(p.breakerClassFor(2000), BreakerClass.acb);
      expect(p.breakerClassFor(2000).code, 'ACB');
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
