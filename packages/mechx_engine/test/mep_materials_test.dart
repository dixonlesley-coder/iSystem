import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/standards/pipe_products.dart';
import 'package:mechx_engine/standards/sni.dart' show VerificationStatus;
import 'package:test/test.dart';

/// Seed tests for the MEP pipe + duct **products** catalog. Expected values are
/// hand-derived against the catalog's documented engineering sources (PPR/PVC
/// manufacturer catalogues, Crane TP-410 roughness bands, the SMACNA gauge
/// schedule, ISO 6708 NPS→DN). The catalog is pluggable DATA; these tests pin
/// the values and the provenance honesty surface (§12.6).
void main() {
  group('pipe products — HW-C / roughness', () {
    test('plastics are smooth (HW-C 150); cast iron is rougher', () {
      // Smooth plastics → 150 (matches sni.dart pvc/hdpe).
      expect(hazenWilliamsCFor(PipeProduct.pprPn16), 150);
      expect(hazenWilliamsCFor(PipeProduct.pvcAw), 150);
      expect(hazenWilliamsCFor(PipeProduct.hdpe), 150);
      // Cast iron lower than plastic, and its HW-C is strictly less.
      expect(hazenWilliamsCFor(PipeProduct.castIron), 110);
      expect(
        hazenWilliamsCFor(PipeProduct.castIron),
        lessThan(hazenWilliamsCFor(PipeProduct.pvcAw)),
      );
    });

    test('roughness: smooth plastic 0.0015 mm; cast iron 0.25 mm (rougher)', () {
      // ε in SI metres; display getter is mm.
      expect(roughnessFor(PipeProduct.pprPn16).inMillimeters, closeTo(0.0015, 1e-9));
      expect(roughnessFor(PipeProduct.acousticPvc).inMillimeters, closeTo(0.0015, 1e-9));
      expect(roughnessFor(PipeProduct.castIron).inMillimeters, closeTo(0.25, 1e-9));
      // Cast iron is the rougher product.
      expect(
        roughnessFor(PipeProduct.castIron).meters,
        greaterThan(roughnessFor(PipeProduct.pvcAw).meters),
      );
    });
  });

  group('pipe products — pressure (PN) ratings', () {
    test('PPR PN10/16/20 → 10/16/20 bar exactly', () {
      // PN is bar: 1 bar = 1e5 Pa, so 16 bar = 1.6e6 Pa.
      expect(pressureRatingFor(PipeProduct.pprPn10)!.inBar, closeTo(10.0, 1e-9));
      expect(pressureRatingFor(PipeProduct.pprPn16)!.inBar, closeTo(16.0, 1e-9));
      expect(pressureRatingFor(PipeProduct.pprPn20)!.inBar, closeTo(20.0, 1e-9));
    });

    test('PVC AW is pressure-rated (~9.8 bar); PVC D drainage has no PN', () {
      // AW ≈ 10 kgf/cm² = 980 665 Pa = 9.806 65 bar.
      final aw = pressureRatingFor(PipeProduct.pvcAw);
      expect(aw, isNotNull);
      expect(aw!.inBar, closeTo(9.80665, 1e-4));
      // Drainage / lower-pressure grades carry no working PN.
      expect(pressureRatingFor(PipeProduct.pvcD), isNull);
      expect(pressureRatingFor(PipeProduct.pvcJis), isNull);
      expect(pressureRatingFor(PipeProduct.castIron), isNull);
      expect(pressureRatingFor(PipeProduct.acousticPvc), isNull);
    });

    test('regime hints: AW pressurized, D gravity (drainage)', () {
      expect(regimeFor(PipeProduct.pvcAw), PipeRegime.pressurized);
      expect(regimeFor(PipeProduct.pvcD), PipeRegime.gravity);
      expect(regimeFor(PipeProduct.castIron), PipeRegime.gravity);
    });
  });

  group('pipe products — NPS ladder + inch↔mm', () {
    test('ladder spans ½″…12″ and is strictly increasing', () {
      expect(npsInches.first, 0.5);
      expect(npsInches.last, 12.0);
      for (var i = 1; i < npsInches.length; i++) {
        expect(npsInches[i], greaterThan(npsInches[i - 1]));
      }
    });

    test('npsToMm uses the ISO 6708 DN designators (1″→25, not 25.4)', () {
      // The whole point: NPS is a rounded designator, not 25.4×inches.
      expect(npsToMm(0.5), 15.0); // ½″  → DN15
      expect(npsToMm(1.0), 25.0); // 1″  → DN25
      expect(npsToMm(2.0), 50.0); // 2″  → DN50
      expect(npsToMm(4.0), 100.0); // 4″ → DN100
      expect(npsToMm(12.0), 300.0); // 12″→ DN300
      // Off-ladder large size: DN = 25 × NPS (e.g. 14″ → 350).
      expect(npsToMm(14.0), 350.0);
    });

    test('mmToNps round-trips a couple of tabled sizes', () {
      // 1″ → DN25 → back to 1″.
      expect(mmToNps(npsToMm(1.0)), 1.0);
      // 4″ → DN100 → back to 4″.
      expect(mmToNps(npsToMm(4.0)), 4.0);
      // Exact DN designator resolves to the tabled NPS.
      expect(mmToNps(50.0), 2.0); // DN50 → 2″
    });
  });

  group('duct products — BJLS automatic gauge', () {
    test('small / medium / large ducts get stepped sheet thickness', () {
      // Small duct (≤450 mm) → 0.50 mm.
      expect(bjlsThicknessMm(300.0), 0.50);
      // Medium duct (≤1200 mm) → 0.70 mm.
      expect(bjlsThicknessMm(1000.0), 0.70);
      // Large duct (>2100 mm) → 1.20 mm.
      expect(bjlsThicknessMm(2500.0), 1.20);
    });

    test('the step boundaries are inclusive upper bounds', () {
      // Exactly on a break-point → that step's thickness (inclusive).
      expect(bjlsThicknessMm(450.0), 0.50); // ≤450 → 0.50
      expect(bjlsThicknessMm(450.1), 0.60); // just over → next step
      expect(bjlsThicknessMm(750.0), 0.60); // ≤750 → 0.60
      expect(bjlsThicknessMm(750.1), 0.70);
      expect(bjlsThicknessMm(1200.0), 0.70);
      expect(bjlsThicknessMm(1800.0), 0.80);
      expect(bjlsThicknessMm(2100.0), 1.00); // ≤2100 → 1.00
      expect(bjlsThicknessMm(2100.1), 1.20); // over the top → 1.20
    });

    test('thickness is monotonic non-decreasing with duct size', () {
      var prev = 0.0;
      for (final side in <double>[200, 450, 600, 900, 1500, 2000, 3000]) {
        final t = bjlsThicknessMm(side);
        expect(t, greaterThanOrEqualTo(prev));
        prev = t;
      }
    });
  });

  group('duct products — PU panel', () {
    test('PU is a fixed panel thickness (default 20 mm), not size-derived', () {
      expect(puPanelThicknessMm(), 20.0);
      // Size does not enter — caller overrides the panel grade explicitly.
      expect(puPanelThicknessMm(panelThicknessMm: 25.0), 25.0);
    });
  });

  group('verify checklists (provenance contract)', () {
    test('pipe checklist is non-empty and every entry is unverified', () {
      expect(pipeProductsVerifyChecklist, isNotEmpty);
      for (final v in pipeProductsVerifyChecklist) {
        expect(v.isUnverified, isTrue);
        expect(v.verified, isFalse);
        // Nothing is verbatim until checked against the official PDF.
        expect(v.status, isNot(VerificationStatus.sniVerbatim));
      }
      // One entry per product + the NPS→DN mapping.
      expect(
        pipeProductsVerifyChecklist.length,
        PipeProduct.values.length + 1,
      );
      // The NPS mapping is deliberately general practice, not an SNI clause.
      expect(
        pipeProductsVerifyChecklist
            .where((v) => v.status == VerificationStatus.notAnSniClause),
        isNotEmpty,
      );
    });

    test('duct checklist is non-empty and every entry is unverified', () {
      expect(ductProductsVerifyChecklist, isNotEmpty);
      for (final v in ductProductsVerifyChecklist) {
        expect(v.isUnverified, isTrue);
        expect(v.status, isNot(VerificationStatus.sniVerbatim));
      }
    });
  });
}
