/// Tests for the P5 fire-sprinkler density/area sizing module.
///
/// All expected values are derived by hand from the density/area method and
/// shown in the arithmetic comments. Use `closeTo` throughout because
/// floating-point division and the L/min → m³/s → L/s conversion chain
/// accumulate rounding at the ~1e-12 level; tolerances are 1e-3 or tighter.
///
/// Design data is sourced from SNI 03-3989-2000 (Ringan 2.25 mm/min @ 84 m²;
/// Sedang 5 mm/min @ 72/144 m²; Berat representative 10 mm/min @ 260 m²) with
/// SNI §6 head coverage maxima (Ringan 20, Sedang 12, Berat 9 m²/head).
library;

import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:test/test.dart';

void main() {
  // ── Ordinary hazard 1 (Sedang Kel. I) — the primary worked example ──────────
  //
  // Inputs:
  //   hazard              = ordinaryHazard1
  //   density             = 5.0 L/min/m²   (SNI Sedang)
  //   designArea          = 72 m²           (SNI Sedang Kel. I)
  //   coveragePerSprinkler= 12.0 m² (SNI Sedang max → default)
  //
  // Step-by-step arithmetic:
  //   totalFlowLpm        = 5.0 × 72 = 360.0 L/min
  //   requiredFlow [L/s]  = 360.0 / 60 = 6.0 L/s
  //   sprinklerCount      = ceil(72 / 12) = 6
  //   flowPerSprinkler    = 360.0 / 6 = 60.0 L/min = 1.0 L/s
  group('ordinaryHazard1 — default coverage 12 m²/head', () {
    late SprinklerDesign result;

    setUp(() {
      result = designSprinklerSystem(hazard: FireHazardClass.ordinaryHazard1);
    });

    test('hazard stored correctly', () {
      expect(result.hazard, equals(FireHazardClass.ordinaryHazard1));
    });

    test('designArea is 72 m²', () {
      expect(result.designAreaValue.squareMeters, closeTo(72.0, 1e-9));
    });

    // totalFlow = 5.0 × 72 = 360.0 L/min → 360.0 / 60 = 6.0 L/s
    test('requiredFlow == 6.0 L/s  (360 L/min)', () {
      expect(result.requiredFlow.inLitersPerSecond, closeTo(6.0, 1e-9));
    });

    test('requiredFlow.inLitersPerMinute == 360.0', () {
      expect(result.requiredFlow.inLitersPerMinute, closeTo(360.0, 1e-9));
    });

    // count = ceil(72 / 12) = 6
    test('sprinklerCount == 6', () {
      expect(result.sprinklerCount, equals(6));
    });

    // flowPerSprinkler = 360 / 6 = 60.0 L/min = 1.0 L/s
    test('flowPerSprinkler == 1.0 L/s  (60 L/min)', () {
      expect(result.flowPerSprinkler.inLitersPerSecond, closeTo(1.0, 1e-9));
      expect(result.flowPerSprinkler.inLitersPerMinute, closeTo(60.0, 1e-9));
    });
  });

  // ── Light hazard (Ringan) — secondary worked example ────────────────────────
  //
  // Inputs:
  //   hazard              = lightHazard
  //   density             = 2.25 L/min/m²  (SNI Ringan)
  //   designArea          = 84 m²           (SNI Ringan)
  //   coveragePerSprinkler= 20.0 m² (SNI Ringan max → default)
  //
  // Step-by-step arithmetic:
  //   totalFlowLpm        = 2.25 × 84 = 189.0 L/min
  //   requiredFlow [L/s]  = 189.0 / 60 = 3.15 L/s
  //   sprinklerCount      = ceil(84 / 20) = ceil(4.2) = 5
  //   flowPerSprinkler    = 189.0 / 5 = 37.8 L/min = 0.63 L/s
  group('lightHazard — default coverage 20 m²/head', () {
    late SprinklerDesign result;

    setUp(() {
      result = designSprinklerSystem(hazard: FireHazardClass.lightHazard);
    });

    test('designArea is 84 m²', () {
      expect(result.designAreaValue.squareMeters, closeTo(84.0, 1e-9));
    });

    // totalFlow = 2.25 × 84 = 189.0 L/min → 189.0 / 60 = 3.15 L/s
    test('requiredFlow == 3.15 L/s  (189 L/min)', () {
      expect(result.requiredFlow.inLitersPerSecond, closeTo(3.15, 1e-9));
      expect(result.requiredFlow.inLitersPerMinute, closeTo(189.0, 1e-9));
    });

    // count = ceil(84 / 20) = 5
    test('sprinklerCount == 5', () {
      expect(result.sprinklerCount, equals(5));
    });

    // flowPerSprinkler = 189.0 / 5 = 37.8 L/min → 0.63 L/s
    test('flowPerSprinkler == 0.63 L/s  (37.8 L/min)', () {
      expect(result.flowPerSprinkler.inLitersPerSecond, closeTo(0.63, 1e-9));
    });
  });

  // ── Extra hazard (Berat) — larger area and higher density ────────────────────
  //
  // Inputs:
  //   hazard              = extraHazard
  //   density             = 10.0 L/min/m²  (Berat representative; // VERIFY)
  //   designArea          = 260 m²          (Berat representative; // VERIFY)
  //   coveragePerSprinkler= 9.0 m² (SNI Berat max → default)
  //
  // Step-by-step arithmetic:
  //   totalFlowLpm        = 10.0 × 260 = 2600.0 L/min
  //   requiredFlow [L/s]  = 2600.0 / 60 ≈ 43.3333 L/s
  //   sprinklerCount      = ceil(260 / 9) = ceil(28.888) = 29
  //   flowPerSprinkler    = 2600.0 / 29 ≈ 89.655 L/min ≈ 1.4943 L/s
  group('extraHazard — default coverage 9 m²/head', () {
    late SprinklerDesign result;

    setUp(() {
      result = designSprinklerSystem(hazard: FireHazardClass.extraHazard);
    });

    test('designArea is 260 m²', () {
      expect(result.designAreaValue.squareMeters, closeTo(260.0, 1e-9));
    });

    test('requiredFlow ≈ 43.333 L/s  (2600 L/min)', () {
      expect(
        result.requiredFlow.inLitersPerSecond,
        closeTo(2600.0 / 60.0, 1e-9),
      );
    });

    // ceil(260 / 9) = ceil(28.888) = 29
    test('sprinklerCount == 29', () {
      expect(result.sprinklerCount, equals(29));
    });

    // 2600 / 29 ≈ 89.655 L/min → / 60 ≈ 1.4943 L/s
    test('flowPerSprinkler ≈ 1.494 L/s', () {
      expect(
        result.flowPerSprinkler.inLitersPerSecond,
        closeTo((2600.0 / 29.0) / 60.0, 1e-9),
      );
    });
  });

  // ── ordinaryHazard2 (Sedang Kel. II/III) — larger Sedang area ────────────────
  //
  // density = 5.0, area = 144 m², coverage = 12.0 m²
  // totalFlow = 5.0 × 144 = 720.0 L/min → 720.0 / 60 = 12.0 L/s
  // count = ceil(144 / 12) = 12; perHead = 720 / 12 = 60 L/min = 1.0 L/s
  group('ordinaryHazard2 — default coverage 12 m²/head', () {
    late SprinklerDesign result;

    setUp(() {
      result = designSprinklerSystem(hazard: FireHazardClass.ordinaryHazard2);
    });

    test('requiredFlow == 12.0 L/s', () {
      expect(result.requiredFlow.inLitersPerSecond, closeTo(12.0, 1e-9));
    });

    test('sprinklerCount == 12', () {
      expect(result.sprinklerCount, equals(12));
    });
  });

  // ── Design data helpers ───────────────────────────────────────────────────────

  group('designDensityLpmPerM2', () {
    test('lightHazard returns 2.25', () {
      expect(designDensityLpmPerM2(FireHazardClass.lightHazard),
          closeTo(2.25, 1e-12));
    });

    test('ordinaryHazard1 returns 5.0', () {
      expect(designDensityLpmPerM2(FireHazardClass.ordinaryHazard1),
          closeTo(5.0, 1e-12));
    });

    test('ordinaryHazard2 returns 5.0', () {
      expect(designDensityLpmPerM2(FireHazardClass.ordinaryHazard2),
          closeTo(5.0, 1e-12));
    });

    test('extraHazard returns 10.0', () {
      expect(designDensityLpmPerM2(FireHazardClass.extraHazard),
          closeTo(10.0, 1e-12));
    });
  });

  group('designArea', () {
    test('lightHazard returns 84 m²', () {
      expect(designArea(FireHazardClass.lightHazard).squareMeters,
          closeTo(84.0, 1e-9));
    });

    test('ordinaryHazard1 returns 72 m²', () {
      expect(designArea(FireHazardClass.ordinaryHazard1).squareMeters,
          closeTo(72.0, 1e-9));
    });

    test('ordinaryHazard2 returns 144 m²', () {
      expect(designArea(FireHazardClass.ordinaryHazard2).squareMeters,
          closeTo(144.0, 1e-9));
    });

    test('extraHazard returns 260 m²', () {
      expect(designArea(FireHazardClass.extraHazard).squareMeters,
          closeTo(260.0, 1e-9));
    });
  });

  group('maxCoveragePerSprinklerM2 (SNI 03-3989-2000 §6)', () {
    test('Ringan 20, Sedang 12, Berat 9', () {
      expect(maxCoveragePerSprinklerM2(FireHazardClass.lightHazard),
          closeTo(20.0, 1e-12));
      expect(maxCoveragePerSprinklerM2(FireHazardClass.ordinaryHazard1),
          closeTo(12.0, 1e-12));
      expect(maxCoveragePerSprinklerM2(FireHazardClass.ordinaryHazard2),
          closeTo(12.0, 1e-12));
      expect(maxCoveragePerSprinklerM2(FireHazardClass.extraHazard),
          closeTo(9.0, 1e-12));
    });
  });

  // ── Coverage sensitivity — explicit head spacing override ─────────────────────
  //
  // OH1 (Sedang I), explicit coverage = 9.0 m²:
  //   count = ceil(72 / 9) = 8
  //   requiredFlow unchanged: density × area is independent of head spacing
  //   flowPerSprinkler = 360.0 / 8 = 45.0 L/min = 0.75 L/s
  group('ordinaryHazard1 — explicit coverage 9 m²/head (tighter grid)', () {
    late SprinklerDesign result;

    setUp(() {
      result = designSprinklerSystem(
        hazard: FireHazardClass.ordinaryHazard1,
        coveragePerSprinklerM2: 9.0,
      );
    });

    // ceil(72 / 9) = 8
    test('sprinklerCount == 8', () {
      expect(result.sprinklerCount, equals(8));
    });

    // requiredFlow unchanged
    test('requiredFlow still 6.0 L/s', () {
      expect(result.requiredFlow.inLitersPerSecond, closeTo(6.0, 1e-9));
    });

    // flowPerSprinkler = 360.0 / 8 = 45.0 L/min → 0.75 L/s
    test('flowPerSprinkler == 0.75 L/s  (45 L/min)', () {
      expect(result.flowPerSprinkler.inLitersPerSecond, closeTo(0.75, 1e-9));
    });
  });

  // ── FlowRate unit consistency ─────────────────────────────────────────────────

  group('FlowRate unit round-trip consistency (OH1)', () {
    late SprinklerDesign result;

    setUp(() {
      result = designSprinklerSystem(hazard: FireHazardClass.ordinaryHazard1);
    });

    test('inLitersPerMinute × (1/60) == inLitersPerSecond', () {
      expect(
        result.requiredFlow.inLitersPerMinute / 60.0,
        closeTo(result.requiredFlow.inLitersPerSecond, 1e-12),
      );
    });

    test('flowPerSprinkler × count ≈ requiredFlow (conservation)', () {
      final double reconstructedLps =
          result.flowPerSprinkler.inLitersPerSecond * result.sprinklerCount;
      expect(
        reconstructedLps,
        closeTo(result.requiredFlow.inLitersPerSecond, 1e-9),
      );
    });
  });
}
