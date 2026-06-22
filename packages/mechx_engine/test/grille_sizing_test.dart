/// Tests for the HVAC grille / diffuser sizing module.
///
/// All expected values are hand-computed; the arithmetic is shown in comments
/// next to each assertion so a reviewer can reproduce them without running code.
library;

import 'package:mechx_engine/sizing/grille_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  // ── recommendedFaceVelocity ────────────────────────────────────────────────

  group('recommendedFaceVelocity', () {
    test('bedroom returns 2.0 m/s', () {
      // Table look-up — bedroom is the quietest category.
      expect(
        recommendedFaceVelocity(GrilleApplication.bedroom).metersPerSecond,
        closeTo(2.0, 1e-9),
      );
    });

    test('livingSpace returns 2.5 m/s', () {
      expect(
        recommendedFaceVelocity(GrilleApplication.livingSpace).metersPerSecond,
        closeTo(2.5, 1e-9),
      );
    });

    test('office returns 3.0 m/s', () {
      expect(
        recommendedFaceVelocity(GrilleApplication.office).metersPerSecond,
        closeTo(3.0, 1e-9),
      );
    });

    test('retail returns 3.5 m/s', () {
      expect(
        recommendedFaceVelocity(GrilleApplication.retail).metersPerSecond,
        closeTo(3.5, 1e-9),
      );
    });

    test('industrial returns 5.0 m/s', () {
      // Industrial is the least noise-sensitive; highest permitted velocity.
      expect(
        recommendedFaceVelocity(GrilleApplication.industrial).metersPerSecond,
        closeTo(5.0, 1e-9),
      );
    });

    test('velocities are strictly ascending with application noise sensitivity', () {
      // bedroom < livingSpace < office < retail < industrial.
      final apps = [
        GrilleApplication.bedroom,
        GrilleApplication.livingSpace,
        GrilleApplication.office,
        GrilleApplication.retail,
        GrilleApplication.industrial,
      ];
      for (var i = 1; i < apps.length; i++) {
        expect(
          recommendedFaceVelocity(apps[i]).metersPerSecond,
          greaterThan(recommendedFaceVelocity(apps[i - 1]).metersPerSecond),
        );
      }
    });
  });

  // ── sizeGrille ─────────────────────────────────────────────────────────────

  group('sizeGrille', () {
    test(
        'Q=0.2 m³/s, v_max=2.0 m/s, freeAreaRatio=0.8 '
        '→ freeArea=0.1 m², grossArea=0.125 m², '
        'squareSide≈353.55 mm, faceVelocity=2.0 m/s', () {
      // HAND CALC:
      //   freeArea      = Q / v_max          = 0.2 / 2.0 = 0.1 m²
      //   grossFaceArea = freeArea / ratio   = 0.1 / 0.8 = 0.125 m²
      //   squareSide    = sqrt(0.125)
      //                 = sqrt(1/8) = 1/(2√2) = 0.353553… m
      //                 = 353.553… mm
      //   faceVelocity  = v_max = 2.0 m/s  (by construction)
      final result = sizeGrille(
        airflow: const FlowRate(0.2),
        maxFaceVelocity: const Velocity(2.0),
      );

      expect(
        result.freeArea.squareMeters,
        closeTo(0.1, 1e-9),
        reason: 'freeArea = 0.2 / 2.0 = 0.1 m²',
      );
      expect(
        result.grossFaceArea.squareMeters,
        closeTo(0.125, 1e-9),
        reason: 'grossFaceArea = 0.1 / 0.8 = 0.125 m²',
      );
      expect(
        result.squareSide.inMillimeters,
        closeTo(353.553, 0.001),
        reason: 'sqrt(0.125) m = 353.553 mm',
      );
      expect(
        result.faceVelocity.metersPerSecond,
        closeTo(2.0, 1e-9),
        reason: 'faceVelocity equals maxFaceVelocity by construction',
      );
    });

    test('freeArea = grossFaceArea × freeAreaRatio', () {
      // Structural invariant: the free-area / gross-area ratio must equal
      // the supplied freeAreaRatio for any valid inputs.
      const ratio = 0.75;
      final result = sizeGrille(
        airflow: const FlowRate(0.5),
        maxFaceVelocity: const Velocity(3.0),
        freeAreaRatio: ratio,
      );
      expect(
        result.freeArea.squareMeters,
        closeTo(result.grossFaceArea.squareMeters * ratio, 1e-12),
      );
    });

    test('squareSide² equals grossFaceArea', () {
      // sqrt(grossFaceArea)² must recover grossFaceArea.
      final result = sizeGrille(
        airflow: const FlowRate(0.3),
        maxFaceVelocity: const Velocity(2.5),
      );
      final sideM = result.squareSide.meters;
      expect(
        sideM * sideM,
        closeTo(result.grossFaceArea.squareMeters, 1e-12),
      );
    });

    test('doubling airflow doubles all areas and keeps faceVelocity the same', () {
      final r1 = sizeGrille(
        airflow: const FlowRate(0.2),
        maxFaceVelocity: const Velocity(2.0),
      );
      final r2 = sizeGrille(
        airflow: const FlowRate(0.4),
        maxFaceVelocity: const Velocity(2.0),
      );
      // HAND CHECK:
      //   r1: freeArea=0.1, gross=0.125
      //   r2: freeArea=0.2, gross=0.250  (exactly 2×)
      expect(
        r2.freeArea.squareMeters,
        closeTo(2.0 * r1.freeArea.squareMeters, 1e-12),
      );
      expect(
        r2.grossFaceArea.squareMeters,
        closeTo(2.0 * r1.grossFaceArea.squareMeters, 1e-12),
      );
      expect(
        r2.faceVelocity.metersPerSecond,
        closeTo(r1.faceVelocity.metersPerSecond, 1e-12),
      );
    });

    test('freeAreaRatio=1.0 gives grossFaceArea == freeArea', () {
      // With no blockage (fully open face) gross area and free area coincide.
      final result = sizeGrille(
        airflow: const FlowRate(0.1),
        maxFaceVelocity: const Velocity(2.0),
        freeAreaRatio: 1.0,
      );
      expect(
        result.grossFaceArea.squareMeters,
        closeTo(result.freeArea.squareMeters, 1e-12),
      );
    });
  });

  // ── standardGrilleFacesMm ─────────────────────────────────────────────────

  group('standardGrilleFacesMm', () {
    test('contains 9 entries', () {
      expect(standardGrilleFacesMm.length, 9);
    });

    test('all dimensions are positive', () {
      for (final face in standardGrilleFacesMm) {
        expect(face.$1, greaterThan(0.0));
        expect(face.$2, greaterThan(0.0));
      }
    });

    test('contains (450.0, 300.0) entry', () {
      expect(standardGrilleFacesMm, contains((450.0, 300.0)));
    });

    test('contains (600.0, 600.0) entry', () {
      expect(standardGrilleFacesMm, contains((600.0, 600.0)));
    });
  });

  // ── selectStandardGrille ──────────────────────────────────────────────────

  group('selectStandardGrille', () {
    test(
        'Q=0.2 m³/s, v_max=2.0 m/s → selects 450×300 mm face '
        'with actual faceVelocity ≈ 1.852 m/s', () {
      // HAND CALC — required gross area:
      //   freeArea_min  = Q / v_max        = 0.2 / 2.0 = 0.100 m²
      //   grossArea_min = freeArea / ratio = 0.100 / 0.8 = 0.125 m²
      //                 = 125 000 mm²
      //
      // Standard faces sorted by gross area (ascending):
      //   (150×150) =  22 500 mm²   gross = 0.022 500 m²  — too small
      //   (200×200) =  40 000 mm²   gross = 0.040 000 m²  — too small
      //   (300×150) =  45 000 mm²   gross = 0.045 000 m²  — too small
      //   (450×150) =  67 500 mm²   gross = 0.067 500 m²  — too small
      //   (300×300) =  90 000 mm²   gross = 0.090 000 m²  — too small
      //   (600×150) =  90 000 mm²   gross = 0.090 000 m²  — too small
      //   (450×300) = 135 000 mm²   gross = 0.135 000 m²  ≥ 0.125  ✓ CHOSEN
      //
      // Actual face velocity at 450×300:
      //   faceVelocity = Q / (grossArea × ratio)
      //                = 0.2 / (0.135 × 0.8)
      //                = 0.2 / 0.108
      //                = 1.851851… m/s  ≤ 2.0 ✓
      //
      // grossFaceArea = 0.135 m²
      // freeArea      = 0.135 × 0.8 = 0.108 m²
      // squareSide    = sqrt(0.135) = 0.367423… m = 367.423… mm
      final result = selectStandardGrille(
        airflow: const FlowRate(0.2),
        maxFaceVelocity: const Velocity(2.0),
      );

      // Gross area must correspond to the 450×300 face.
      expect(
        result.grossFaceArea.squareMeters,
        closeTo(0.135, 1e-9),
        reason: '450 mm × 300 mm = 0.135 m² gross',
      );

      // Free area = gross × ratio.
      expect(
        result.freeArea.squareMeters,
        closeTo(0.108, 1e-9),
        reason: '0.135 × 0.8 = 0.108 m²',
      );

      // Actual face velocity must not exceed the limit.
      expect(
        result.faceVelocity.metersPerSecond,
        lessThanOrEqualTo(2.0),
        reason: 'faceVelocity must not exceed maxFaceVelocity',
      );

      // And it should be close to 1.8519 m/s (0.2 / 0.108).
      expect(
        result.faceVelocity.metersPerSecond,
        closeTo(1.8519, 0.001),
        reason: '0.2 / (0.135 × 0.8) = 1.8519 m/s',
      );

      // squareSide = sqrt(0.135) ≈ 367.423 mm.
      expect(
        result.squareSide.inMillimeters,
        closeTo(367.42, 0.01),
        reason: 'sqrt(0.135) m ≈ 367.423 mm',
      );
    });

    test('result faceVelocity is always ≤ maxFaceVelocity when a face qualifies', () {
      // Use a relaxed limit so many faces qualify; the chosen one must still comply.
      final result = selectStandardGrille(
        airflow: const FlowRate(0.05),
        maxFaceVelocity: const Velocity(5.0),
      );
      expect(
        result.faceVelocity.metersPerSecond,
        lessThanOrEqualTo(5.0),
      );
    });

    test('selects smallest qualifying face (lowest gross area)', () {
      // For Q=0.05, v_max=5.0, ratio=0.8:
      //   grossArea_min = 0.05 / (5.0 × 0.8) = 0.0125 m² = 12 500 mm²
      //   smallest standard face ≥ 12 500 mm²: (150×150)=22 500 mm²  → chosen.
      //   faceVelocity = 0.05 / (0.0225 × 0.8) = 0.05 / 0.018 = 2.778 m/s
      final result = selectStandardGrille(
        airflow: const FlowRate(0.05),
        maxFaceVelocity: const Velocity(5.0),
      );
      expect(
        result.grossFaceArea.squareMeters,
        closeTo(0.0225, 1e-9),
        reason: '150 mm × 150 mm = 0.0225 m²',
      );
    });

    test('falls back to largest face when no standard face qualifies', () {
      // Extremely high flow: Q=10 m³/s, v_max=0.1 m/s
      //   grossArea_min = 10 / (0.1 × 0.8) = 125 m²  — no standard face this big.
      //   Falls back to largest: 600×600 = 0.36 m².
      final result = selectStandardGrille(
        airflow: const FlowRate(10.0),
        maxFaceVelocity: const Velocity(0.1),
      );
      expect(
        result.grossFaceArea.squareMeters,
        closeTo(0.36, 1e-9),
        reason: 'largest face 600×600 mm = 0.36 m²',
      );
      // faceVelocity exceeds limit because no face is large enough.
      expect(
        result.faceVelocity.metersPerSecond,
        greaterThan(0.1),
      );
    });

    test('squareSide² equals grossFaceArea for standard face result', () {
      final result = selectStandardGrille(
        airflow: const FlowRate(0.2),
        maxFaceVelocity: const Velocity(2.0),
      );
      final s = result.squareSide.meters;
      expect(s * s, closeTo(result.grossFaceArea.squareMeters, 1e-12));
    });

    test('freeArea = grossFaceArea × freeAreaRatio', () {
      const ratio = 0.7;
      final result = selectStandardGrille(
        airflow: const FlowRate(0.1),
        maxFaceVelocity: const Velocity(3.0),
        freeAreaRatio: ratio,
      );
      expect(
        result.freeArea.squareMeters,
        closeTo(result.grossFaceArea.squareMeters * ratio, 1e-12),
      );
    });
  });

  // ── Integration: sizeGrille + recommendedFaceVelocity ────────────────────

  group('integration', () {
    test('bedroom grille: Q=0.1 m³/s at recommended velocity', () {
      // HAND CALC:
      //   v_max = recommendedFaceVelocity(bedroom) = 2.0 m/s
      //   freeArea      = 0.1 / 2.0 = 0.05 m²
      //   grossFaceArea = 0.05 / 0.8 = 0.0625 m²
      //   squareSide    = sqrt(0.0625) = 0.25 m = 250.0 mm
      final v = recommendedFaceVelocity(GrilleApplication.bedroom);
      final result = sizeGrille(
        airflow: const FlowRate(0.1),
        maxFaceVelocity: v,
      );
      expect(result.freeArea.squareMeters, closeTo(0.05, 1e-9));
      expect(result.grossFaceArea.squareMeters, closeTo(0.0625, 1e-9));
      expect(result.squareSide.inMillimeters, closeTo(250.0, 1e-6));
      expect(result.faceVelocity.metersPerSecond, closeTo(2.0, 1e-9));
    });

    test('selectStandardGrille with recommendedFaceVelocity(office)', () {
      // v_max = 3.0 m/s, Q = 0.05 m³/s
      //   grossArea_min = 0.05 / (3.0 × 0.8) = 0.020833 m² = 20 833 mm²
      //   Smallest standard face ≥ 20 833 mm²: (150×150) = 22 500 mm² → chosen.
      //   faceVelocity = 0.05 / (0.0225 × 0.8) = 0.05 / 0.018 = 2.7778 m/s ≤ 3.0 ✓
      final v = recommendedFaceVelocity(GrilleApplication.office);
      final result = selectStandardGrille(
        airflow: const FlowRate(0.05),
        maxFaceVelocity: v,
      );
      expect(result.faceVelocity.metersPerSecond, lessThanOrEqualTo(3.0));
      expect(result.faceVelocity.metersPerSecond, closeTo(2.7778, 1e-3));
      expect(
        result.grossFaceArea.squareMeters,
        closeTo(0.0225, 1e-9),
        reason: '150×150 mm = 0.0225 m² is the smallest qualifying face',
      );
    });
  });
}
