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
  });

  // ── Primary worked example: rated 100 L/s @ 50 m, η = 0.70 ─────────────────
  //
  //   churn   : Q = 0,          H = 1.40 × 50 = 70 m
  //   rated   : Q = 0.100 m³/s, H = 50 m
  //   overload: Q = 1.50 × 0.100 = 0.150 m³/s, H = 0.65 × 50 = 32.5 m
  //
  //   rated  hydraulic = 9810 × 0.100 × 50   = 49 050 W ; shaft = /0.7 = 70 071.4 W
  //   overld hydraulic = 9810 × 0.150 × 32.5 = 47 823.75 W ; shaft = /0.7 = 68 319.6 W
  //   churn  hydraulic = 0 (no flow) ; shaft = 0
  //   governing shaft = max = rated 70 071.4 W ≈ 70.07 kW → motor 75 kW
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

    // shaft = 9810 × 0.150 × 32.5 / 0.7
    test('overload shaft power = ρ·g·Q·H / 0.70', () {
      const expShaft = rhoG * 0.150 * 32.5 / 0.70;
      expect(r.overload.shaftPower.watts, closeTo(expShaft, 1e-3));
    });

    // At exactly the limiting ratios the rated point (Q·H = 5.0) governs over
    // the overload point (Q·H = 0.15 × 32.5 = 4.875), so the motor is sized on
    // the rated shaft ≈ 70.07 kW → smallest standard frame ≥ that is 75 kW.
    test('motor selected on governing (rated) shaft → 75 kW', () {
      expect(r.selectedMotor.inKiloWatts, closeTo(75.0, 1e-9));
      expect(r.oversized, isFalse);
      // M19 — the verdict names the MOTOR FRAME (the condition the flag really
      // reads), not the pump curve, which is compliant by construction here.
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
  //   overload shaft = 9810 × (1.5×0.07887) × (0.65×80) / 0.7
  //                  = 9810 × 0.118305 × 52 / 0.7 ≈ 86 200 W ≈ 86.2 kW
  //   governing = rated ≈ 88.4 kW > largest standard frame 75 kW → oversized.
  group('checkFirePumpRating — oversized (tall building, 1250 gpm @ 80 m)', () {
    late FirePumpRatingResult r;

    setUp(() {
      r = checkFirePumpRating(
        ratedFlow: FlowRate.litersPerSecond(78.87),
        ratedHead: const Head(80),
      );
    });

    test('governing shaft exceeds the 75 kW frame → oversized', () {
      expect(r.selectedMotor.inKiloWatts, closeTo(75.0, 1e-9)); // saturated
      expect(r.oversized, isTrue);
      // M19 — reworded to name the true condition (the standard MOTOR ladder
      // saturated) and the action, instead of blaming the pump curve.
      expect(
        r.verdict,
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
