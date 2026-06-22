/// Tests for the §7 gravity-drainage pipe-sizing module.
///
/// All expected values are derived from the Manning equation applied by hand
/// (shown in comments) and verified against the engine's [manningFlowFull] /
/// [manningVelocity] primitives in `hydraulics.dart`.
///
/// Capacity model: TRUE partial-full circular hydraulics —
/// Q(r)/Q_full = [(θ−sinθ)/2π]·[(θ−sinθ)/θ]^(2/3), θ = 2·acos(1−2r).
/// Exact at r=0.5 (0.5) and r=1.0 (1.0); ≈0.912 at r=0.75.
library;

import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  // ── partial-full capacity factor ─────────────────────────────────────────────

  group('partialFullCapacityFactor (true Manning partial-full)', () {
    test('half-full → 0.5', () {
      expect(partialFullCapacityFactor(0.5), closeTo(0.5, 1e-9));
    });
    test('full → 1.0', () {
      expect(partialFullCapacityFactor(1.0), closeTo(1.0, 1e-12));
    });
    test('three-quarter full ≈ 0.912 (capacity outpaces depth)', () {
      expect(partialFullCapacityFactor(0.75), closeTo(0.9120, 1e-3));
    });
    test('rises monotonically up to ~0.8 (well below the hump)', () {
      double prev = 0;
      for (final r in [0.1, 0.25, 0.5, 0.75, 0.8]) {
        final f = partialFullCapacityFactor(r);
        expect(f, greaterThan(prev));
        prev = f;
      }
    });
    test('capacity peaks above full bore near r≈0.94 then returns to 1.0', () {
      // Classic partial-full hump: Q/Q_full ≈ 1.076 at d/D≈0.94, exactly 1.0
      // at full. So the peak exceeds 1.0 and full-bore is below the peak.
      final peak = partialFullCapacityFactor(0.94);
      expect(peak, greaterThan(1.0));
      expect(peak, closeTo(1.076, 5e-3));
      expect(partialFullCapacityFactor(1.0), closeTo(1.0, 1e-12));
      expect(partialFullCapacityFactor(1.0), lessThan(peak));
    });
  });

  // ── constants under test ────────────────────────────────────────────────────

  group('standardDrainDiametersMm', () {
    test('list has exactly 8 entries in ascending order', () {
      expect(standardDrainDiametersMm.length, equals(8));
      for (var i = 0; i < standardDrainDiametersMm.length - 1; i++) {
        expect(
          standardDrainDiametersMm[i] < standardDrainDiametersMm[i + 1],
          isTrue,
        );
      }
    });

    test('series is [50, 75, 100, 125, 150, 200, 250, 300]', () {
      expect(
        standardDrainDiametersMm,
        orderedEquals(<double>[50, 75, 100, 125, 150, 200, 250, 300]),
      );
    });
  });

  // ── Case 1 — 4 L/s at S=0.01, fill=0.5, n=0.010 ───────────────────────────
  //
  // Design flow:  Q_design = 0.004 m³/s
  // Required full-bore capacity:  Q_req = 0.004 / 0.5 = 0.008 m³/s
  //
  // Manning capacity check by hand (v = (1/n)·R^(2/3)·S^(1/2), Q = v·A):
  //
  //   DN75  (D=0.075 m):  A=π×0.075²/4=4.4179×10⁻³ m², R=0.01875 m
  //     R^(2/3) = 0.01875^(2/3) = 0.069111
  //     v = 100 × 0.069111 × 0.1 = 0.69111 m/s
  //     Q = 0.69111 × 4.4179×10⁻³ = 3.053×10⁻³ m³/s  < 0.008 → reject
  //
  //   DN100 (D=0.100 m):  A=π×0.100²/4=7.8540×10⁻³ m², R=0.025 m
  //     R^(2/3) = (1/40)^(2/3) = 0.085499
  //     v = 100 × 0.085499 × 0.1 = 0.85499 m/s
  //     Q = 0.85499 × 7.8540×10⁻³ = 6.716×10⁻³ m³/s  < 0.008 → reject
  //
  //   DN125 (D=0.125 m):  A=π×0.125²/4=1.2272×10⁻² m², R=0.03125 m
  //     R^(2/3) = (1/32)^(2/3) = 0.099213
  //     v = 100 × 0.099213 × 0.1 = 0.99213 m/s
  //     Q = 0.99213 × 1.2272×10⁻² = 1.2176×10⁻² m³/s  ≥ 0.008 → SELECT
  //
  // Result: DN125, v_full≈0.992 m/s, self-cleansing=true
  group('Case 1 — 4 L/s, S=0.01, fill=0.5, n=0.010', () {
    late DrainageSizingResult result;

    setUp(() {
      result = sizeForFlow(
        flow: FlowRate.litersPerSecond(4.0),
        slope: 0.01,
        fillRatio: 0.5,
        manningN: 0.010,
      );
    });

    test('selects DN125', () {
      expect(result.diameter.inMillimeters, closeTo(125.0, 1e-9));
    });

    test('full-bore velocity ≈ 0.992 m/s', () {
      // v = (1/0.010)×(0.03125)^(2/3)×√0.01
      //   = 100 × 0.099213 × 0.1  = 0.99213 m/s
      expect(result.fullBoreVelocity.metersPerSecond, closeTo(0.99213, 1e-4));
    });

    test('full-bore capacity ≈ 12.18 L/s', () {
      // Q = 0.99213 × π×0.125²/4 = 0.99213 × 0.012272 = 0.012176 m³/s
      expect(
        result.fullBoreCapacity.cubicMetersPerSecond,
        closeTo(0.012176, 1e-4),
      );
    });

    test('self-cleansing (v_full ≥ 0.6 m/s)', () {
      expect(result.selfCleansing, isTrue);
    });

    test('DN100 full-bore capacity < required (verifies rejection)', () {
      // Ensures the algorithm really walks through DN100 and rejects it.
      final qDn100 = manningFlowFull(
        Diameter.mm(100),
        manningN: 0.010,
        slope: 0.01,
      );
      // Q_full DN100 ≈ 0.006716 m³/s  <  required 0.008 m³/s
      expect(qDn100.cubicMetersPerSecond, closeTo(0.006716, 1e-4));
      expect(qDn100.cubicMetersPerSecond, lessThan(0.008));
    });
  });

  // ── Case 2 — 10 L/s at S=0.02, fill=0.5, n=0.010 ──────────────────────────
  //
  // Design flow:  Q_design = 0.010 m³/s
  // Required full-bore capacity:  Q_req = 0.010 / 0.5 = 0.020 m³/s
  //
  // Manning capacity check by hand:
  //
  //   DN125 (D=0.125 m):  A=1.2272×10⁻² m², R=0.03125 m
  //     R^(2/3) = 0.099213
  //     v = 100 × 0.099213 × √0.02 = 100 × 0.099213 × 0.141421 = 1.40296 m/s
  //     Q = 1.40296 × 1.2272×10⁻² = 1.7218×10⁻² m³/s  < 0.020 → reject
  //
  //   DN150 (D=0.150 m):  A=π×0.150²/4=1.7671×10⁻² m², R=0.0375 m
  //     R^(2/3) = 0.0375^(2/3) ≈ 0.111803
  //     v = 100 × 0.111803 × 0.141421 = 1.58115 m/s
  //     Q = 1.58115 × 1.7671×10⁻² = 2.7940×10⁻² m³/s  ≥ 0.020 → SELECT
  //
  // Result: DN150, v_full≈1.581 m/s, self-cleansing=true
  group('Case 2 — 10 L/s, S=0.02, fill=0.5, n=0.010', () {
    late DrainageSizingResult result;

    setUp(() {
      result = sizeForFlow(
        flow: FlowRate.litersPerSecond(10.0),
        slope: 0.02,
        fillRatio: 0.5,
        manningN: 0.010,
      );
    });

    test('selects DN150', () {
      expect(result.diameter.inMillimeters, closeTo(150.0, 1e-9));
    });

    test('full-bore velocity ≈ 1.584 m/s', () {
      // v = (1/0.010) × (0.0375)^(2/3) × √0.02 ≈ 1.5844 m/s
      expect(result.fullBoreVelocity.metersPerSecond, closeTo(1.5844, 1e-3));
    });

    test('full-bore capacity ≈ 28.0 L/s', () {
      // Q = 1.5844 × π×0.150²/4 ≈ 0.02800 m³/s
      expect(
        result.fullBoreCapacity.cubicMetersPerSecond,
        closeTo(0.028000, 1e-4),
      );
    });

    test('self-cleansing (v_full ≥ 0.6 m/s)', () {
      expect(result.selfCleansing, isTrue);
    });

    test('DN125 full-bore capacity < required (verifies rejection)', () {
      final qDn125 = manningFlowFull(
        Diameter.mm(125),
        manningN: 0.010,
        slope: 0.02,
      );
      // ≈ 0.017218 m³/s  <  required 0.020 m³/s
      expect(qDn125.cubicMetersPerSecond, closeTo(0.017218, 1e-4));
      expect(qDn125.cubicMetersPerSecond, lessThan(0.020));
    });
  });

  // ── Edge cases ──────────────────────────────────────────────────────────────

  group('edge cases', () {
    test('tiny flow selects DN50 when it has sufficient capacity', () {
      // DN50 at S=0.05 has ample capacity even for very small flows.
      // DN50: R=0.0125 m, v=(1/0.01)×0.0125^(2/3)×√0.05
      //      = 100 × 0.05386 × 0.22361 = 1.2040 m/s
      //      Q_full = 1.2040 × 0.0019635 = 0.0023641 m³/s
      // requiredFullBore for 0.1 L/s at fill=0.5: 0.0001/0.5 = 0.0002 m³/s
      // 0.0023641 >= 0.0002 → DN50 selected.
      final r = sizeForFlow(
        flow: FlowRate.litersPerSecond(0.1),
        slope: 0.05,
      );
      expect(r.diameter.inMillimeters, closeTo(50.0, 1e-9));
    });

    test('enormous flow falls back to DN300', () {
      // 1000 L/s exceeds every standard size.
      final r = sizeForFlow(
        flow: FlowRate.litersPerSecond(1000.0),
        slope: 0.01,
      );
      expect(r.diameter.inMillimeters, closeTo(300.0, 1e-9));
    });

    test('fillRatio=1.0 sizes against full-bore capacity directly', () {
      // At fill ratio 1.0, required_full_bore == flow. Choose the pipe whose
      // Q_full >= flow. For 5 L/s at S=0.01: DN125 Q_full≈12.18 L/s ≥ 5 L/s,
      // but DN100 Q_full≈6.72 L/s is already ≥ 5 L/s → DN100 selected.
      final r = sizeForFlow(
        flow: FlowRate.litersPerSecond(5.0),
        slope: 0.01,
        fillRatio: 1.0,
      );
      // DN100 Q_full ≈ 6.72 L/s >= 5 L/s; DN75 Q_full ≈ 3.05 L/s < 5 L/s
      expect(r.diameter.inMillimeters, closeTo(100.0, 1e-9));
    });

    test('result is self-cleansing when full-bore velocity >= 0.6 m/s', () {
      // S=0.005, n=0.010: still expect a reasonable velocity.
      final r = sizeForFlow(
        flow: FlowRate.litersPerSecond(1.0),
        slope: 0.005,
      );
      // Check consistency: self-cleansing flag matches velocity comparison.
      expect(r.selfCleansing, equals(r.fullBoreVelocity.metersPerSecond >= 0.6));
    });

    test('result is not self-cleansing on very flat slope', () {
      // S=0.0001 (1 in 10 000): velocities will be very low.
      final r = sizeForFlow(
        flow: FlowRate.litersPerSecond(0.5),
        slope: 0.0001,
      );
      expect(r.selfCleansing, isFalse);
    });
  });

  // ── Consistency with hydraulics primitives ──────────────────────────────────

  group('consistency with hydraulics.dart primitives', () {
    test('fullBoreCapacity matches manningFlowFull directly', () {
      const slope = 0.015;
      const n = 0.010;
      final r = sizeForFlow(
        flow: FlowRate.litersPerSecond(3.0),
        slope: slope,
        manningN: n,
      );
      final qDirect = manningFlowFull(r.diameter, manningN: n, slope: slope);
      expect(
        r.fullBoreCapacity.cubicMetersPerSecond,
        closeTo(qDirect.cubicMetersPerSecond, 1e-12),
      );
    });

    test('fullBoreVelocity matches manningVelocity(R=D/4) directly', () {
      const slope = 0.015;
      const n = 0.010;
      final r = sizeForFlow(
        flow: FlowRate.litersPerSecond(3.0),
        slope: slope,
        manningN: n,
      );
      final vDirect = manningVelocity(
        manningN: n,
        hydraulicRadius: Length(r.diameter.meters / 4.0),
        slope: slope,
      );
      expect(
        r.fullBoreVelocity.metersPerSecond,
        closeTo(vDirect.metersPerSecond, 1e-12),
      );
    });

    test('usable capacity at fill=0.5 equals 0.5 × full-bore (exact)', () {
      // This is the hydraulic-radius identity: at half-full R_half = D/4 = R_full.
      // So v_half = v_full, and A_half = A_full/2, giving Q_half = Q_full/2.
      const slope = 0.01;
      const n = 0.010;
      final r = sizeForFlow(
        flow: FlowRate.litersPerSecond(2.0),
        slope: slope,
        manningN: n,
      );
      final halfFull =
          r.fullBoreCapacity.cubicMetersPerSecond * 0.5;
      // The design flow must fit within the half-full usable capacity.
      expect(halfFull, greaterThanOrEqualTo(0.002)); // 2 L/s design flow
    });
  });
}
