import 'dart:math' as math;

import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/sizing/fan.dart';
import 'package:mechx_engine/sizing/operating_point.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// Operating-point (system × equipment curve) + NPSH tests.
///
/// Every expected value is hand-computed in SI from the closed-form curve
/// intersection and recorded here as the correctness anchor. The curve
/// coefficients themselves are // VERIFY representative estimates, but the
/// ARITHMETIC composing them is exact and is what these tests pin.
void main() {
  // ── Pump: design point recovery (no system inputs) ──────────────────────────
  //
  // Q_design = 0.02 m³/s, H_design = 30 m, no system inputs.
  // Representative 50/50 split:
  //   H_static = 0.5·30 = 15 m
  //   k        = (0.5·30) / Q² = 15 / 0.0004 = 37500  (head per (m³/s)²)
  // Equipment curve pinned to design with 125 % shutoff:
  //   H_shutoff = 30·1.25 = 37.5 m
  //   a         = (37.5 − 30) / 0.0004 = 7.5 / 0.0004 = 18750
  // Intersection: Q_op = √((37.5 − 15)/(37500 + 18750)) = √(22.5/56250)
  //             = √0.0004 = 0.02 m³/s  → exactly the design flow.
  //   H_op = 15 + 37500·0.0004 = 15 + 15 = 30 m.
  group('computePumpOperatingPoint — default split recovers the design point', () {
    late PumpOperatingPoint op;
    setUpAll(() {
      op = computePumpOperatingPoint(
        designFlow: const FlowRate(0.02),
        designHead: const Head(30),
      );
    });

    test('static head = 15 m (50 % of design)', () {
      expect(op.systemStaticHead.meters, closeTo(15.0, 1e-9));
    });
    test('k = 37500 head per (m³/s)²', () {
      expect(op.systemResistanceK, closeTo(37500.0, 1e-6));
    });
    test('shutoff head = 37.5 m (125 % of design)', () {
      expect(op.equipmentShutoffHead.meters, closeTo(37.5, 1e-9));
    });
    test('droop a = 18750', () {
      expect(op.equipmentDroopA, closeTo(18750.0, 1e-6));
    });
    test('operating flow = 0.02 m³/s (== design)', () {
      expect(op.operatingFlow.cubicMetersPerSecond, closeTo(0.02, 1e-9));
    });
    test('operating head = 30 m (== design)', () {
      expect(op.operatingHead.meters, closeTo(30.0, 1e-9));
    });
    test('flowRatio = 1.0', () {
      expect(op.flowRatio, closeTo(1.0, 1e-9));
    });
    test('stable match', () {
      expect(op.stable, isTrue);
    });
  });

  // ── Pump: explicit system curve (H_static = 10 m, k = 100) ─────────────────
  //
  // Q_design = 0.02 m³/s, H_design = 30 m, H_static = 10 m, k = 100.
  // (k supplied with a static head ⇒ both verbatim.)
  //   H_shutoff = 30·1.25 = 37.5 m
  //   a         = (37.5 − 30)/0.0004 = 18750
  // Q_op = √((37.5 − 10)/(100 + 18750)) = √(27.5/18850)
  //      = √0.00145888... = 0.0381953... m³/s.
  //   In L/s: ×1000 = 38.1953 L/s.
  //   H_op = 10 + 100·Q_op² = 10 + 100·0.00145889 = 10 + 0.145889 = 10.14589 m.
  group('computePumpOperatingPoint — explicit static=10 m, k=100', () {
    late PumpOperatingPoint op;
    setUpAll(() {
      op = computePumpOperatingPoint(
        designFlow: const FlowRate(0.02),
        designHead: const Head(30),
        systemStaticHead: const Head(10),
        systemResistanceK: 100,
      );
    });

    test('static head verbatim = 10 m', () {
      expect(op.systemStaticHead.meters, closeTo(10.0, 1e-12));
    });
    test('k verbatim = 100', () {
      expect(op.systemResistanceK, closeTo(100.0, 1e-12));
    });
    test('operating flow = √(27.5/18850) = 0.0381953 m³/s', () {
      final expected = math.sqrt(27.5 / 18850.0);
      expect(op.operatingFlow.cubicMetersPerSecond, closeTo(expected, 1e-9));
      expect(op.operatingFlow.cubicMetersPerSecond, closeTo(0.03819527, 1e-7));
    });
    test('operating head = 10 + 100·Q_op² ≈ 10.14589 m', () {
      final qop = math.sqrt(27.5 / 18850.0);
      final expected = 10.0 + 100.0 * qop * qop;
      expect(op.operatingHead.meters, closeTo(expected, 1e-9));
      expect(op.operatingHead.meters, closeTo(10.14589, 1e-4));
    });
    test('runs above design flow (k too low for the duty)', () {
      expect(op.operatingFlow.cubicMetersPerSecond, greaterThan(0.02));
      expect(op.flowRatio, greaterThan(1.0));
    });
  });

  // ── Pump: starved system (static head exceeds shutoff) → no real root ───────
  //
  // H_design = 10 m, H_static = 20 m (> shutoff 12.5 m): the pump cannot lift
  // the static head, num = 12.5 − 20 < 0 → Q_op = 0, unstable.
  group('computePumpOperatingPoint — static head exceeds shutoff', () {
    late PumpOperatingPoint op;
    setUpAll(() {
      op = computePumpOperatingPoint(
        designFlow: const FlowRate(0.01),
        designHead: const Head(10),
        systemStaticHead: const Head(20),
        systemResistanceK: 100,
      );
    });
    test('operating flow collapses to 0', () {
      expect(op.operatingFlow.cubicMetersPerSecond, 0.0);
    });
    test('flagged unstable', () {
      expect(op.stable, isFalse);
    });
  });

  // ── NPSH: flooded suction, cavitation margin ────────────────────────────────
  //
  // Q_design = 0.0005 m³/s (0.5 L/s), H_design = 20 m, suction +5 m (flooded),
  // P_atm = 101325 Pa, P_vapour = 2339 Pa, ρ = 1000, g = 9.81.
  //   atmHead = 101325 / (1000·9.81) = 10.32874... m
  //   vapHead =   2339 / (1000·9.81) =  0.238430... m
  //   h_suction_static = +5 m
  //   h_suction_fric   = 0.10·|5| = 0.5 m
  //   NPSH_available = 10.32874 − 0.238430 + 5 − 0.5 = 14.59031 m
  //
  // Default split (no system inputs): k back-solved so Q_op = Q_design = 0.0005.
  // NPSH_required is RE-DERIVED for M12 — it now comes from the SUCTION side
  // (suction-specific-speed correlation), not from 15 % of the total head:
  //   n·√Q_op = 2900·√0.0005 = 2900 × 0.0223606798 = 64.845971...
  //   /N_ss    = 64.845971 / 160 = 0.405287...
  //   ^(4/3)   = 0.2999282... m  → below the 0.5 m conservative floor,
  //   so NPSH_required = kMinNpshRequiredM = 0.5 m.
  //   0.5·1.5 (safety) = 0.75 m < 14.59 m ⇒ no cavitation risk (as before).
  group('computePumpOperatingPoint — NPSH flooded suction', () {
    late PumpOperatingPoint op;
    setUpAll(() {
      op = computePumpOperatingPoint(
        designFlow: const FlowRate(0.0005),
        designHead: const Head(20),
        suctionStaticHead: const Head(5),
      );
    });
    test('NPSH available = 14.59031 m (hand-arithmetic)', () {
      const atm = 101325.0 / (defaultWaterDensity * standardGravity);
      const vap = 2339.0 / (defaultWaterDensity * standardGravity);
      const expected = atm - vap + 5.0 - 0.5;
      expect(op.npshAvailable.meters, closeTo(expected, 1e-9));
      expect(op.npshAvailable.meters, closeTo(14.59031, 1e-4));
    });
    test('NPSH required = the 0.5 m floor at this small flow (M12)', () {
      // (2900·√0.0005 / 160)^(4/3) = 0.29993 m, floored at 0.5 m.
      final correlated =
          math.pow(2900.0 * math.sqrt(0.0005) / 160.0, 4.0 / 3.0).toDouble();
      expect(correlated, closeTo(0.29992823826993853, 1e-12));
      expect(op.npshRequired.meters, closeTo(kMinNpshRequiredM, 1e-12));
    });
    test('no cavitation risk (NPSH_a 14.59 ≥ 1.5·0.5 = 0.75)', () {
      expect(op.cavitationRisk, isFalse);
    });
  });

  // ── NPSH: suction LIFT below vapour-margin → cavitation flagged ─────────────
  //
  // Same duty but suction −9 m (the pump lifts the fluid 9 m):
  //   h_suction_fric = 0.10·9 = 0.9 m
  //   NPSH_available = 10.32874 − 0.238430 − 9 − 0.9 = 0.190310 m
  //   NPSH_required (M12: the 0.5 m suction-side floor at this flow, as above)
  //   → 1.5·0.5 = 0.75 m.
  //   0.19 < 0.75 ⇒ cavitation risk flagged (the genuine high-lift case).
  group('computePumpOperatingPoint — NPSH suction lift → cavitation', () {
    late PumpOperatingPoint op;
    setUpAll(() {
      op = computePumpOperatingPoint(
        designFlow: const FlowRate(0.0005),
        designHead: const Head(20),
        suctionStaticHead: const Head(-9),
      );
    });
    test('NPSH available = 0.19031 m (hand-arithmetic)', () {
      const atm = 101325.0 / (defaultWaterDensity * standardGravity);
      const vap = 2339.0 / (defaultWaterDensity * standardGravity);
      const expected = atm - vap - 9.0 - 0.9;
      expect(op.npshAvailable.meters, closeTo(expected, 1e-9));
      expect(op.npshAvailable.meters, closeTo(0.19031, 1e-4));
    });
    test('cavitation risk flagged (0.19 < 1.5·0.5 = 0.75)', () {
      expect(op.cavitationRisk, isTrue);
    });
  });

  // ── Fan: default back-solve recovers the design point ───────────────────────
  //
  // Q_design = 1.0 m³/s, Δp_design = 250 Pa, no system input.
  //   k = 250 / 1.0² = 250 Pa per (m³/s)²
  //   Δp_shutoff = 250·1.25 = 312.5 Pa
  //   a = (312.5 − 250)/1.0 = 62.5
  //   Q_op = √(312.5 / (250 + 62.5)) = √(312.5/312.5) = √1 = 1.0 → design.
  //   Δp_op = 250·1² = 250 Pa.
  group('computeFanOperatingPoint — default recovers the design point', () {
    late FanOperatingPoint op;
    setUpAll(() {
      op = computeFanOperatingPoint(
        designAirflow: const FlowRate(1.0),
        designPressure: const Pressure(250),
      );
    });
    test('k = 250', () {
      expect(op.systemResistanceK, closeTo(250.0, 1e-9));
    });
    test('shutoff = 312.5 Pa', () {
      expect(op.equipmentShutoffPressure.pascals, closeTo(312.5, 1e-9));
    });
    test('operating flow = 1.0 m³/s (== design)', () {
      expect(op.operatingFlow.cubicMetersPerSecond, closeTo(1.0, 1e-9));
    });
    test('operating pressure = 250 Pa', () {
      expect(op.operatingPressure.pascals, closeTo(250.0, 1e-9));
    });
    test('flowRatio = 1.0 and stable', () {
      expect(op.flowRatio, closeTo(1.0, 1e-9));
      expect(op.stable, isTrue);
    });
  });

  // ── Fan: explicit k = 100 (system softer than the duty) ─────────────────────
  //
  // Q_design = 1.0 m³/s, Δp_design = 250 Pa, k = 100.
  //   Δp_shutoff = 312.5 Pa, a = 62.5.
  //   Q_op = √(312.5 / (100 + 62.5)) = √(312.5/162.5) = √1.923076... = 1.386750...
  //   Δp_op = 100·Q_op² = 100·1.923076 = 192.3076 Pa.
  group('computeFanOperatingPoint — explicit k = 100', () {
    late FanOperatingPoint op;
    setUpAll(() {
      op = computeFanOperatingPoint(
        designAirflow: const FlowRate(1.0),
        designPressure: const Pressure(250),
        systemResistanceK: 100,
      );
    });
    test('operating flow = √(312.5/162.5) ≈ 1.38675 m³/s', () {
      final expected = math.sqrt(312.5 / 162.5);
      expect(op.operatingFlow.cubicMetersPerSecond, closeTo(expected, 1e-9));
      expect(op.operatingFlow.cubicMetersPerSecond, closeTo(1.386750, 1e-5));
    });
    test('operating pressure = 100·Q_op² ≈ 192.3077 Pa', () {
      final qop = math.sqrt(312.5 / 162.5);
      expect(op.operatingPressure.pascals, closeTo(100.0 * qop * qop, 1e-9));
      expect(op.operatingPressure.pascals, closeTo(192.3077, 1e-3));
    });
    test('runs above design flow', () {
      expect(op.operatingFlow.cubicMetersPerSecond, greaterThan(1.0));
    });
  });

  // ── Composition: sizePump threads the operating point only when asked ───────
  group('sizePump operating-point composition', () {
    test('default (no op inputs) leaves operatingPoint null (byte-identical)', () {
      final duty = sizePump(flow: const FlowRate(0.02), head: const Head(30));
      expect(duty.operatingPoint, isNull);
    });
    test('withOperatingPoint: true composes the analysis', () {
      final duty = sizePump(
        flow: const FlowRate(0.02),
        head: const Head(30),
        withOperatingPoint: true,
      );
      expect(duty.operatingPoint, isNotNull);
      // Default split recovers the design point.
      expect(
        duty.operatingPoint!.operatingFlow.cubicMetersPerSecond,
        closeTo(0.02, 1e-9),
      );
    });
    test('supplying a system input alone turns the analysis on', () {
      final duty = sizePump(
        flow: const FlowRate(0.02),
        head: const Head(30),
        systemStaticHead: const Head(10),
      );
      expect(duty.operatingPoint, isNotNull);
      expect(duty.operatingPoint!.systemStaticHead.meters, closeTo(10.0, 1e-9));
    });
  });

  // ── Composition: sizeFan threads the operating point only when asked ────────
  group('sizeFan operating-point composition', () {
    test('default leaves operatingPoint null (byte-identical)', () {
      final duty = sizeFan(
        airflow: const FlowRate(1.0),
        totalStaticPressure: const Pressure(250),
      );
      expect(duty.operatingPoint, isNull);
    });
    test('systemResistanceK turns the analysis on', () {
      final duty = sizeFan(
        airflow: const FlowRate(1.0),
        totalStaticPressure: const Pressure(250),
        systemResistanceK: 100,
      );
      expect(duty.operatingPoint, isNotNull);
      expect(duty.operatingPoint!.systemResistanceK, closeTo(100.0, 1e-9));
    });
  });
}
