/// Tests for the P5 fire-sprinkler density/area sizing module.
///
/// All expected values are derived by hand from the density/area method and
/// shown in the arithmetic comments. Use `closeTo` throughout because
/// floating-point division and the L/min → m³/s → L/s conversion chain
/// accumulate rounding at the ~1e-12 level; tolerances are 1e-3 or tighter.
///
/// REMINDER: the densities and areas under test are UNVERIFIED PLACEHOLDERS.
/// Results here reflect the placeholder data only. Re-run after the `// VERIFY`
/// values have been confirmed against SNI 03-3989-2000 / SNI 8489.
library;

import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  // ── Ordinary hazard 1 — the primary worked example ──────────────────────────
  //
  // Inputs:
  //   hazard              = ordinaryHazard1
  //   density             = 4.1 L/min/m²   (placeholder; // VERIFY)
  //   designArea          = 140 m²          (placeholder; // VERIFY)
  //   coveragePerSprinkler= 12.0 m²
  //
  // Step-by-step arithmetic:
  //   totalFlowLpm        = 4.1 × 140 = 574.0 L/min
  //   requiredFlow [L/s]  = 574.0 / 60 = 9.5̄6̄ L/s ≈ 9.5667 L/s
  //   sprinklerCount      = ceil(140 / 12) = ceil(11.6̄6̄) = 12
  //   flowPerSprinkler    = 574.0 / 12 = 47.8̄3̄ L/min
  //                       = 47.8̄3̄ / 60 L/s ≈ 0.79722 L/s
  group('ordinaryHazard1 — coverage 12 m²/head', () {
    late SprinklerDesign result;

    setUp(() {
      result = designSprinklerSystem(
        hazard: FireHazardClass.ordinaryHazard1,
        coveragePerSprinklerM2: 12.0,
      );
    });

    test('hazard stored correctly', () {
      expect(result.hazard, equals(FireHazardClass.ordinaryHazard1));
    });

    test('designArea is 140 m²', () {
      expect(result.designAreaValue.squareMeters, closeTo(140.0, 1e-9));
    });

    // totalFlow = 4.1 × 140 = 574.0 L/min  →  574.0 / 60 = 9.5667 L/s
    test('requiredFlow ≈ 9.567 L/s  (574 L/min)', () {
      expect(
        result.requiredFlow.inLitersPerSecond,
        closeTo(574.0 / 60.0, 1e-9),
      );
      expect(result.requiredFlow.inLitersPerSecond, closeTo(9.5667, 1e-3));
    });

    test('requiredFlow.inLitersPerMinute == 574.0', () {
      expect(result.requiredFlow.inLitersPerMinute, closeTo(574.0, 1e-9));
    });

    // count = ceil(140 / 12) = ceil(11.666…) = 12
    test('sprinklerCount == 12', () {
      expect(result.sprinklerCount, equals(12));
    });

    // flowPerSprinkler = 574 / 12 = 47.833… L/min = 47.833… / 60 L/s ≈ 0.7972 L/s
    test('flowPerSprinkler ≈ 0.797 L/s  (47.833 L/min)', () {
      expect(
        result.flowPerSprinkler.inLitersPerSecond,
        closeTo((574.0 / 12.0) / 60.0, 1e-9),
      );
      expect(result.flowPerSprinkler.inLitersPerSecond, closeTo(0.7972, 1e-3));
    });

    test('flowPerSprinkler.inLitersPerMinute ≈ 47.833', () {
      expect(
        result.flowPerSprinkler.inLitersPerMinute,
        closeTo(574.0 / 12.0, 1e-9),
      );
    });
  });

  // ── Light hazard — secondary worked example ──────────────────────────────────
  //
  // Inputs:
  //   hazard              = lightHazard
  //   density             = 2.8 L/min/m²   (placeholder; // VERIFY)
  //   designArea          = 140 m²          (placeholder; // VERIFY)
  //   coveragePerSprinkler= 12.0 m²
  //
  // Step-by-step arithmetic:
  //   totalFlowLpm        = 2.8 × 140 = 392.0 L/min
  //   requiredFlow [L/s]  = 392.0 / 60 = 6.5̄3̄ L/s ≈ 6.5333 L/s
  //   sprinklerCount      = ceil(140 / 12) = ceil(11.6̄6̄) = 12
  //   flowPerSprinkler    = 392.0 / 12 = 32.6̄ L/min
  //                       = 32.6̄ / 60 L/s ≈ 0.54444 L/s
  group('lightHazard — coverage 12 m²/head', () {
    late SprinklerDesign result;

    setUp(() {
      result = designSprinklerSystem(
        hazard: FireHazardClass.lightHazard,
        coveragePerSprinklerM2: 12.0,
      );
    });

    test('hazard stored correctly', () {
      expect(result.hazard, equals(FireHazardClass.lightHazard));
    });

    test('designArea is 140 m²', () {
      expect(result.designAreaValue.squareMeters, closeTo(140.0, 1e-9));
    });

    // totalFlow = 2.8 × 140 = 392.0 L/min  →  392.0 / 60 ≈ 6.5333 L/s
    test('requiredFlow ≈ 6.533 L/s  (392 L/min)', () {
      expect(
        result.requiredFlow.inLitersPerSecond,
        closeTo(392.0 / 60.0, 1e-9),
      );
      expect(result.requiredFlow.inLitersPerSecond, closeTo(6.5333, 1e-3));
    });

    test('requiredFlow.inLitersPerMinute == 392.0', () {
      expect(result.requiredFlow.inLitersPerMinute, closeTo(392.0, 1e-9));
    });

    // count = ceil(140 / 12) = 12 (same design area, same coverage)
    test('sprinklerCount == 12', () {
      expect(result.sprinklerCount, equals(12));
    });

    // flowPerSprinkler = 392.0 / 12 = 32.6̄ L/min  →  32.6̄ / 60 ≈ 0.5444 L/s
    test('flowPerSprinkler ≈ 0.544 L/s  (32.667 L/min)', () {
      expect(
        result.flowPerSprinkler.inLitersPerSecond,
        closeTo((392.0 / 12.0) / 60.0, 1e-9),
      );
      expect(result.flowPerSprinkler.inLitersPerSecond, closeTo(0.5444, 1e-3));
    });
  });

  // ── Extra hazard — verify larger design area and higher density ──────────────
  //
  // Inputs:
  //   hazard              = extraHazard
  //   density             = 8.2 L/min/m²   (placeholder; // VERIFY)
  //   designArea          = 230 m²          (placeholder; // VERIFY)
  //   coveragePerSprinkler= 12.0 m²
  //
  // Step-by-step arithmetic:
  //   totalFlowLpm        = 8.2 × 230 = 1886.0 L/min
  //   requiredFlow [L/s]  = 1886.0 / 60 ≈ 31.4333 L/s
  //   sprinklerCount      = ceil(230 / 12) = ceil(19.1̄6̄) = 20
  //   flowPerSprinkler    = 1886.0 / 20 = 94.3 L/min
  //                       = 94.3 / 60 ≈ 1.5717 L/s
  group('extraHazard — coverage 12 m²/head', () {
    late SprinklerDesign result;

    setUp(() {
      result = designSprinklerSystem(
        hazard: FireHazardClass.extraHazard,
        coveragePerSprinklerM2: 12.0,
      );
    });

    test('designArea is 230 m²', () {
      expect(result.designAreaValue.squareMeters, closeTo(230.0, 1e-9));
    });

    test('requiredFlow ≈ 31.433 L/s  (1886 L/min)', () {
      expect(
        result.requiredFlow.inLitersPerSecond,
        closeTo(1886.0 / 60.0, 1e-9),
      );
    });

    // ceil(230 / 12) = ceil(19.1667) = 20
    test('sprinklerCount == 20', () {
      expect(result.sprinklerCount, equals(20));
    });

    // 1886 / 20 = 94.3 L/min  →  94.3 / 60 ≈ 1.5717 L/s
    test('flowPerSprinkler ≈ 1.572 L/s', () {
      expect(
        result.flowPerSprinkler.inLitersPerSecond,
        closeTo((1886.0 / 20.0) / 60.0, 1e-9),
      );
    });
  });

  // ── ordinaryHazard2 — verify mid-range density ───────────────────────────────
  //
  // density = 6.1, area = 140 m², coverage = 12.0 m²
  // totalFlow = 6.1 × 140 = 854.0 L/min  →  854.0 / 60 ≈ 14.2333 L/s
  // count = 12; perHead = 854.0 / 12 ≈ 71.1667 L/min ≈ 1.1861 L/s
  group('ordinaryHazard2 — coverage 12 m²/head', () {
    late SprinklerDesign result;

    setUp(() {
      result = designSprinklerSystem(
        hazard: FireHazardClass.ordinaryHazard2,
        coveragePerSprinklerM2: 12.0,
      );
    });

    test('requiredFlow ≈ 14.233 L/s', () {
      expect(
        result.requiredFlow.inLitersPerSecond,
        closeTo(854.0 / 60.0, 1e-9),
      );
    });

    test('sprinklerCount == 12', () {
      expect(result.sprinklerCount, equals(12));
    });
  });

  // ── Design data helpers ───────────────────────────────────────────────────────

  group('designDensityLpmPerM2', () {
    test('lightHazard returns 2.8', () {
      expect(designDensityLpmPerM2(FireHazardClass.lightHazard), closeTo(2.8, 1e-12));
    });

    test('ordinaryHazard1 returns 4.1', () {
      expect(designDensityLpmPerM2(FireHazardClass.ordinaryHazard1), closeTo(4.1, 1e-12));
    });

    test('ordinaryHazard2 returns 6.1', () {
      expect(designDensityLpmPerM2(FireHazardClass.ordinaryHazard2), closeTo(6.1, 1e-12));
    });

    test('extraHazard returns 8.2', () {
      expect(designDensityLpmPerM2(FireHazardClass.extraHazard), closeTo(8.2, 1e-12));
    });
  });

  group('designArea', () {
    test('lightHazard returns 140 m²', () {
      expect(designArea(FireHazardClass.lightHazard).squareMeters, closeTo(140.0, 1e-9));
    });

    test('ordinaryHazard1 returns 140 m²', () {
      expect(designArea(FireHazardClass.ordinaryHazard1).squareMeters, closeTo(140.0, 1e-9));
    });

    test('ordinaryHazard2 returns 140 m²', () {
      expect(designArea(FireHazardClass.ordinaryHazard2).squareMeters, closeTo(140.0, 1e-9));
    });

    test('extraHazard returns 230 m²', () {
      expect(designArea(FireHazardClass.extraHazard).squareMeters, closeTo(230.0, 1e-9));
    });
  });

  // ── Coverage sensitivity — different head spacing ─────────────────────────────
  //
  // OH1, coverage = 9.0 m²:
  //   count = ceil(140 / 9) = ceil(15.5̄5̄) = 16
  //   flowPerSprinkler = 574.0 / 16 = 35.875 L/min ≈ 0.59792 L/s
  group('ordinaryHazard1 — coverage 9 m²/head (tighter grid)', () {
    late SprinklerDesign result;

    setUp(() {
      result = designSprinklerSystem(
        hazard: FireHazardClass.ordinaryHazard1,
        coveragePerSprinklerM2: 9.0,
      );
    });

    // ceil(140 / 9) = ceil(15.555…) = 16
    test('sprinklerCount == 16', () {
      expect(result.sprinklerCount, equals(16));
    });

    // requiredFlow unchanged: density × area is independent of head spacing
    test('requiredFlow still ≈ 9.567 L/s', () {
      expect(result.requiredFlow.inLitersPerSecond, closeTo(574.0 / 60.0, 1e-9));
    });

    // flowPerSprinkler = 574.0 / 16 = 35.875 L/min  →  35.875 / 60 ≈ 0.59792 L/s
    test('flowPerSprinkler ≈ 0.598 L/s  (35.875 L/min)', () {
      expect(
        result.flowPerSprinkler.inLitersPerSecond,
        closeTo((574.0 / 16.0) / 60.0, 1e-9),
      );
    });
  });

  // ── FlowRate unit consistency ─────────────────────────────────────────────────

  group('FlowRate unit round-trip consistency (OH1)', () {
    late SprinklerDesign result;

    setUp(() {
      result = designSprinklerSystem(
        hazard: FireHazardClass.ordinaryHazard1,
        coveragePerSprinklerM2: 12.0,
      );
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
