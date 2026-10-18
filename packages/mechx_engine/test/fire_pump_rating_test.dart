/// Tests for the fire-pump NFPA 20 rating-curve check.
///
/// Expected values are hand-derived from the acceptance ratios (churn 140 %,
/// overload 65 % head at 150 % flow) and the engine's own power primitives
/// (ρ·g = 1000 × 9.81 = 9810 N/m³, shaft = hydraulic / η). No magic numbers —
/// each power is reconstructed from `ρ·g·Q·H / η`.
library;

import 'package:mechx_engine/sizing/fire_pump_rating.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// ρ·g for water in the engine's hydraulic kernel.
const double rhoG = 1000.0 * 9.81; // 9810 N/m³

void main() {
  // ── Acceptance constants ──────────────────────────────────────────────────
  group('acceptance-curve constants (NFPA 20 limits)', () {
    test('churn ≤ 140 %, overload ≥ 65 % @ 150 % flow', () {
      expect(kChurnHeadRatio, 1.40);
      expect(kOverloadHeadRatio, 0.65);
      expect(kOverloadFlowRatio, 1.50);
    });

    test('jockey flow fraction is 1 %', () {
      expect(kJockeyFlowFraction, 0.01);
    });

    test('overload efficiency derate is 0.85 (// VERIFY representative)', () {
      expect(kOverloadEfficiencyFactor, 0.85);
    });
  });

  // ── Primary worked example: rated 100 L/s @ 50 m, η = 0.70 ─────────────────
  //
  //   churn   : Q = 0,          H = 1.40 × 50 = 70 m
  //   rated   : Q = 0.100 m³/s, H = 50 m
  //   overload: Q = 1.50 × 0.100 = 0.150 m³/s, H = 0.65 × 50 = 32.5 m
  //
  //   rated  hydraulic = 9810 × 0.100 × 50   = 49 050 W ; shaft = /0.7 = 70 071.4 W
  //   overld hydraulic = 9810 × 0.150 × 32.5 = 47 823.75 W ;
  //          η_overload = 0.70 × 0.85 (kOverloadEfficiencyFactor) = 0.595
  //          shaft = 47 823.75 / 0.595 = 80 376.05 W
  //   churn  hydraulic = 0 (no flow) ; shaft = 0
  //   governing shaft = max = OVERLOAD 80 376.05 W ≈ 80.38 kW → the next IEC
  //   frame above 75 kW is 90 kW (Round 21: the ladder runs to 315 kW), so
  //   the motor is SELECTED at 90 kW, not clamped.
  //   (Audit 2026-10 fire-4: with one constant η the overload shaft was
  //   0.975 × rated = 68.32 kW and could never govern; the pump runs past its
  //   best-efficiency point at 150 % flow, so its η is derated.)
  group('checkFirePumpRating — rated 100 L/s @ 50 m', () {
    late FirePumpRatingResult r;
    final ratedFlow = FlowRate.litersPerSecond(100); // 0.100 m³/s
    const ratedHead = Head(50);

    setUp(() {
      r = checkFirePumpRating(ratedFlow: ratedFlow, ratedHead: ratedHead);
    });

    test('churn head = 140 % of rated = 70 m, zero flow', () {
      expect(r.churn.head.meters, closeTo(70.0, 1e-9));
      expect(r.churn.flow.cubicMetersPerSecond, closeTo(0.0, 1e-12));
      expect(r.churn.shaftPower.watts, closeTo(0.0, 1e-9)); // no flow → no power
    });

    test('rated point = 100 L/s @ 50 m', () {
      expect(r.rated.flow.inLitersPerSecond, closeTo(100.0, 1e-9));
      expect(r.rated.head.meters, closeTo(50.0, 1e-9));
    });

    // shaft = ρ·g·Q·H / η = 9810 × 0.1 × 50 / 0.7
    test('rated shaft power = ρ·g·Q·H / 0.70', () {
      const expShaft = rhoG * 0.100 * 50.0 / 0.70;
      expect(r.rated.shaftPower.watts, closeTo(expShaft, 1e-3));
    });

    test('overload point = 150 L/s @ 32.5 m (65 % head)', () {
      expect(r.overload.flow.inLitersPerSecond, closeTo(150.0, 1e-9));
      expect(r.overload.head.meters, closeTo(32.5, 1e-9));
    });

    // shaft = 9810 × 0.150 × 32.5 / (0.70 × 0.85)
    test('overload shaft power = ρ·g·Q·H / (0.70 × 0.85)', () {
      const expShaft = rhoG * 0.150 * 32.5 / (0.70 * 0.85);
      expect(expShaft, closeTo(80376.0504, 1e-3));
      expect(r.overload.shaftPower.watts, closeTo(expShaft, 1e-3));
    });

    // Q·H/η: rated 0.1 × 50 / 0.70 = 7.143 vs overload 0.15 × 32.5 / 0.595
    // = 8.193 ⇒ the OVERLOAD point governs at ≈ 80.38 kW; 75 < 80.38 ≤ 90
    // ⇒ selectMotor picks the 90 kW IEC frame (Round 21 ladder) — in range.
    test('motor selected on governing (overload) shaft → 90 kW frame', () {
      expect(r.overload.shaftPower.watts,
          greaterThan(r.rated.shaftPower.watts));
      expect(r.selectedMotor.inKiloWatts, closeTo(90.0, 1e-9));
      expect(r.oversized, isFalse);
      expect(r.verdict, 'Motor within standard frame range');
    });

    // Jockey: 1 % of 100 L/s = 1 L/s; head = churn 70 m + 5 m margin = 75 m.
    test('jockey flow = 1 % of rated (1 L/s), head = churn + 5 m', () {
      expect(r.jockeyFlow.inLitersPerSecond, closeTo(1.0, 1e-9));
      expect(r.jockeyHead.meters, closeTo(75.0, 1e-9));
    });

    test('designation defaults to duty, standby recommended', () {
      expect(r.designation, PumpDesignation.duty);
      expect(r.standbyRecommended, isTrue);
    });
  });

  // ── Designation override ───────────────────────────────────────────────────
  group('checkFirePumpRating — designation', () {
    test('standby designation propagates', () {
      final r = checkFirePumpRating(
        ratedFlow: FlowRate.litersPerSecond(50),
        ratedHead: const Head(40),
        designation: PumpDesignation.standby,
        standbyRecommended: false,
      );
      expect(r.designation, PumpDesignation.standby);
      expect(r.standbyRecommended, isFalse);
    });
  });

  // ── Oversized boundary: tall building, max standpipe flow ──────────────────
  //
  // 1250 gpm ≈ 78.87 L/s rated @ 80 m head, η = 0.70.
  //   rated shaft = 9810 × 0.07887 × 80 / 0.7 ≈ 88 411 W ≈ 88.4 kW
  //   overload shaft = 9810 × (1.5×0.07887) × (0.65×80) / (0.7 × 0.85)
  //                  = 9810 × 0.118305 × 52 / 0.595 ≈ 101 428 W ≈ 101.4 kW
  //   governing = overload ≈ 101.4 kW → 90 < 101.4 ≤ 110 ⇒ the 110 kW IEC
  //   frame (Round 21 ladder) — no longer clamped.
  group('checkFirePumpRating — tall building, 1250 gpm @ 80 m', () {
    late FirePumpRatingResult r;

    setUp(() {
      r = checkFirePumpRating(
        ratedFlow: FlowRate.litersPerSecond(78.87),
        ratedHead: const Head(80),
      );
    });

    test('governing shaft 101.4 kW → the 110 kW frame, in range', () {
      expect(r.selectedMotor.inKiloWatts, closeTo(110.0, 1e-9));
      expect(r.oversized, isFalse);
    });

    // Oversized boundary moved to the top of the IEC ladder (315 kW):
    // rated 250 L/s @ 100 m ⇒ overload shaft = 9810 × 0.375 × 65 / 0.595
    // = 401 890 W ≈ 401.9 kW > 315 kW ⇒ selectMotor clamps and flags it.
    test('a governing shaft above 315 kW clamps → oversized', () {
      final big = checkFirePumpRating(
        ratedFlow: FlowRate.litersPerSecond(250),
        ratedHead: const Head(100),
      );
      expect(big.overload.shaftPower.watts,
          closeTo(rhoG * 0.375 * 65 / 0.595, 1e-3));
      expect(big.selectedMotor.inKiloWatts, closeTo(315.0, 1e-9));
      expect(big.oversized, isTrue);
      // M19 — reworded to name the true condition (the standard MOTOR ladder
      // saturated) and the action, instead of blaming the pump curve.
      expect(
        big.verdict,
        'Motor above standard frame range - specify a custom motor or '
        'duty pairs',
      );
    });

    test('jockey flow = 1 % of ~78.87 L/s ≈ 0.789 L/s', () {
      expect(r.jockeyFlow.inLitersPerSecond, closeTo(0.7887, 1e-6));
    });
  });

  // ── Curve monotonicity sanity ──────────────────────────────────────────────
  group('checkFirePumpRating — sanity', () {
    test('churn head > rated head > overload head', () {
      final r = checkFirePumpRating(
        ratedFlow: FlowRate.litersPerSecond(60),
        ratedHead: const Head(45),
      );
      expect(r.churn.head.meters, greaterThan(r.rated.head.meters));
      expect(r.rated.head.meters, greaterThan(r.overload.head.meters));
    });

    test('overload flow > rated flow > churn flow', () {
      final r = checkFirePumpRating(
        ratedFlow: FlowRate.litersPerSecond(60),
        ratedHead: const Head(45),
      );
      expect(
        r.overload.flow.cubicMetersPerSecond,
        greaterThan(r.rated.flow.cubicMetersPerSecond),
      );
      expect(
        r.rated.flow.cubicMetersPerSecond,
        greaterThan(r.churn.flow.cubicMetersPerSecond),
      );
    });
  });
}
