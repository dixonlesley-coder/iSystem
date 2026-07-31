import 'dart:math' as math;

import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_sprinkler_hydraulic.dart';
import 'package:mechx_engine/sizing/operating_point.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// MODULE-AUDIT-REVIEW findings M8 / M19 / M12.
///
/// Every expectation below is hand-derived from first principles in the comment
/// that precedes it — the arithmetic is the spec, not the current output.
void main() {
  // ══════════════════════════════════════════════════════════════════════════
  // M8 — the light-hazard remote head is governed by the MINIMUM OPERATING
  //      PRESSURE, not by the density share (and that is a PASS, not a FAIL).
  // ══════════════════════════════════════════════════════════════════════════
  //
  // Light hazard (SNI 03-3989-2000 Ringan), density/area method:
  //   density       = 2.25 L/min/m²
  //   design area   = 84 m²
  //   total flow    = 2.25 × 84            = 189 L/min
  //   head coverage = 20 m²/head
  //   head count    = ceil(84 / 20) = ceil(4.2) = 5 heads
  //   density share = 189 / 5              = 37.8 L/min/head
  //
  // Density-share pressure through a K = 80 head:
  //   P = (Q/K)² = (37.8 / 80)² = 0.4725² = 0.22325625 bar
  //             = 22 325.625 Pa
  // which is BELOW the 0.5 bar minimum operating pressure — structurally, for
  // every light-hazard project. A head cannot discharge below its minimum, so
  // the demand is re-derived AT the floor:
  //   Q_head = K·√P_min = 80 × √0.5 = 80 × 0.70710678118654752
  //          = 56.568542494923804 L/min/head
  //   design-area demand = 56.568542... × 5 = 282.84271247461902 L/min
  //                      (vs the 189 L/min density figure)
  group('M8 — light hazard: demand governed by the head minimum pressure', () {
    late SprinklerRemoteAreaResult r;
    late SprinklerDesign design;
    setUpAll(() {
      design = designSprinklerSystem(hazard: FireHazardClass.lightHazard);
      r = remoteAreaHydraulics(design: design);
    });

    test('the density/area split is 37.8 L/min across 5 heads', () {
      expect(design.sprinklerCount, 5);
      expect(design.flowPerSprinkler.inLitersPerMinute, closeTo(37.8, 1e-9));
      expect(r.densityShareFlow.inLitersPerMinute, closeTo(37.8, 1e-9));
    });

    test('the density share alone would need only 0.2233 bar', () {
      // (37.8/80)² = 0.22325625 bar — the pressure the OLD code compared and
      // failed. It is still recoverable from the un-uplifted share.
      final p = headPressureForFlow(r.densityShareFlow, r.kFactor);
      expect(p.inBar, closeTo(0.22325625, 1e-12));
      expect(p.inBar, lessThan(kDefaultMinHeadPressureBar));
    });

    test('flagged as governed by the minimum pressure', () {
      expect(r.governedByMinimumPressure, isTrue);
    });

    test('per-head flow uplifted to K·√P_min = 56.5685 L/min', () {
      const expected = 80.0 * math.sqrt2 / 2.0; // 80·√0.5
      expect(expected, closeTo(56.568542494923804, 1e-12));
      expect(r.remoteHeadFlow.inLitersPerMinute, closeTo(expected, 1e-9));
      // Strictly greater than the density share it replaces.
      expect(
        r.remoteHeadFlow.inLitersPerMinute,
        greaterThan(r.densityShareFlow.inLitersPerMinute),
      );
    });

    test('remote-head pressure sits exactly on the 0.5 bar floor', () {
      expect(r.remoteHeadPressure.inBar, closeTo(0.5, 1e-12));
      expect(r.minOperatingPressure.inBar, closeTo(0.5, 1e-12));
    });

    test('remote-area demand rises to 282.8427 L/min (5 × 56.5685)', () {
      const expected = 5 * 80.0 * math.sqrt2 / 2.0;
      expect(expected, closeTo(282.84271247461902, 1e-9));
      expect(r.remoteAreaDemand.inLitersPerMinute, closeTo(expected, 1e-9));
      // …above the density/area figure of 189 L/min, which is the whole point:
      // the supply must deliver the uplifted demand.
      expect(
        r.remoteAreaDemand.inLitersPerMinute,
        greaterThan(design.requiredFlow.inLitersPerMinute),
      );
      expect(design.requiredFlow.inLitersPerMinute, closeTo(189.0, 1e-9));
    });

    test('the verdict is a PASS with the governing note, not a failure', () {
      expect(r.meetsMinimumPressure, isTrue);
      expect(
        r.verdict,
        'Remote head OK - demand governed by head minimum pressure, '
        'not density',
      );
      // ASCII only — the report/canvas fonts carry no fancy glyphs.
      expect(r.verdict.codeUnits.every((c) => c < 128), isTrue);
    });

    test('branch friction + base pressure are taken at the UPLIFTED flow', () {
      // The friction must reflect what the branch actually carries.
      final expectedFriction = headLossHazenWilliams(
        flow: r.remoteHeadFlow,
        length: const Length(20),
        diameter: const Diameter(0.025),
        hazenWilliamsC: kSprinklerBranchHazenC,
      );
      expect(
        r.branchLineFrictionHead.meters,
        closeTo(expectedFriction.meters, 1e-12),
      );
      // …and it is strictly more than the friction at the density share.
      final densityFriction = headLossHazenWilliams(
        flow: r.densityShareFlow,
        length: const Length(20),
        diameter: const Diameter(0.025),
        hazenWilliamsC: kSprinklerBranchHazenC,
      );
      expect(
        r.branchLineFrictionHead.meters,
        greaterThan(densityFriction.meters),
      );
      // branchBase = head pressure (0.5 bar = 50 000 Pa) + friction as pressure.
      expect(
        r.branchBasePressure.pascals,
        closeTo(50000.0 + pressureFromHead(expectedFriction).pascals, 1e-9),
      );
    });
  });

  // ── M8 — the density-governed case must be BYTE-IDENTICAL ──────────────────
  //
  // Ordinary hazard 1 (Sedang Kelompok I):
  //   density = 5.0 L/min/m², area = 72 m² ⇒ total = 360 L/min
  //   coverage 12 m²/head ⇒ count = ceil(72/12) = 6 heads
  //   share = 360/6 = 60 L/min/head
  //   P = (60/80)² = 0.75² = 0.5625 bar ≥ 0.5 bar ⇒ NO uplift.
  //   remote-area demand = 60 × 6 = 360 L/min = design.requiredFlow.
  group('M8 — ordinary hazard 1 is density-governed (byte-identical pin)', () {
    late SprinklerRemoteAreaResult r;
    setUpAll(() {
      r = remoteAreaHydraulics(
        design: designSprinklerSystem(hazard: FireHazardClass.ordinaryHazard1),
      );
    });

    test('not governed by the minimum pressure', () {
      expect(r.governedByMinimumPressure, isFalse);
    });
    test('per-head flow stays the 60 L/min density share', () {
      expect(r.remoteHeadFlow.inLitersPerMinute, closeTo(60.0, 1e-9));
      expect(r.densityShareFlow.inLitersPerMinute, closeTo(60.0, 1e-9));
    });
    test('remote-head pressure stays 0.5625 bar', () {
      expect(r.remoteHeadPressure.inBar, closeTo(0.5625, 1e-12));
    });
    test('remote-area demand equals the density/area required flow', () {
      expect(r.remoteAreaDemand.inLitersPerMinute, closeTo(360.0, 1e-9));
      expect(
        r.remoteAreaDemand.cubicMetersPerSecond,
        closeTo(r.design.requiredFlow.cubicMetersPerSecond, 1e-15),
      );
    });
    test('verdict is the plain pass', () {
      expect(r.meetsMinimumPressure, isTrue);
      expect(r.verdict, 'Remote head OK');
    });
  });

  // ── M8 — a raised floor still uplifts, and a relaxed floor never does ───────
  //
  // OH1 share = 60 L/min. At a 0.7 bar floor: 0.5625 < 0.7 ⇒ uplift to
  //   Q = 80·√0.7 = 80 × 0.83666002653407556 = 66.932802122726045 L/min
  //   demand = × 6 = 401.59681273635627 L/min.
  group('M8 — the floor is a real lever, in both directions', () {
    test('OH1 at a 0.7 bar floor uplifts to 66.9328 L/min', () {
      final r = remoteAreaHydraulics(
        design: designSprinklerSystem(hazard: FireHazardClass.ordinaryHazard1),
        minOperatingPressure: Pressure.bar(0.7),
      );
      const expected = 80.0 * 0.8366600265340756;
      expect(r.governedByMinimumPressure, isTrue);
      expect(r.remoteHeadFlow.inLitersPerMinute, closeTo(expected, 1e-9));
      expect(
        r.remoteAreaDemand.inLitersPerMinute,
        closeTo(expected * 6, 1e-8),
      );
    });

    test('light hazard at a 0.2 bar floor is density-governed again', () {
      // 0.22325625 bar ≥ 0.2 bar ⇒ no uplift, demand back to 189 L/min.
      final r = remoteAreaHydraulics(
        design: designSprinklerSystem(hazard: FireHazardClass.lightHazard),
        minOperatingPressure: Pressure.bar(0.2),
      );
      expect(r.governedByMinimumPressure, isFalse);
      expect(r.remoteHeadFlow.inLitersPerMinute, closeTo(37.8, 1e-9));
      expect(r.remoteAreaDemand.inLitersPerMinute, closeTo(189.0, 1e-9));
    });

    test('a larger K head clears the floor on density alone', () {
      // K = 160: P = (37.8/160)² = 0.23625² = 0.0558140625 bar — still under
      // 0.5, so the uplift then delivers 160·√0.5 = 113.13708 L/min/head.
      final r = remoteAreaHydraulics(
        design: designSprinklerSystem(hazard: FireHazardClass.lightHazard),
        kFactor: 160,
      );
      expect(r.governedByMinimumPressure, isTrue);
      expect(
        r.remoteHeadFlow.inLitersPerMinute,
        closeTo(160.0 * math.sqrt2 / 2.0, 1e-9),
      );
      expect(
        r.remoteHeadFlow.inLitersPerMinute,
        closeTo(113.13708498984761, 1e-9),
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // M19 — the fire-pump verdict names the MOTOR FRAME limit, not the curve.
  // ══════════════════════════════════════════════════════════════════════════
  //
  // Rated 100 L/s @ 50 m (the healthy case):
  //   overload point = 150 L/s @ 32.5 m
  //   shaft = ρ·g·Q·H/η = 1000·9.81·0.15·32.5 / 0.70 = 47823.75/0.70
  //         = 68 319.642857 W = 68.32 kW ⇒ the 75 kW standard frame covers it.
  group('M19 — motor within the standard frame range', () {
    late FirePumpRatingResult r;
    setUpAll(() {
      r = checkFirePumpRating(
        ratedFlow: FlowRate.litersPerSecond(100),
        ratedHead: const Head(50),
      );
    });
    test('governing shaft ≈ 68.32 kW (hand-arithmetic)', () {
      const expected =
          defaultWaterDensity * standardGravity * 0.15 * 32.5 / 0.70;
      expect(expected, closeTo(68319.642857, 1e-4));
      expect(r.overload.shaftPower.watts, closeTo(expected, 1e-6));
    });
    test('not flagged, and the verdict speaks of the MOTOR', () {
      expect(r.oversized, isFalse);
      expect(r.verdict, 'Motor within standard frame range');
    });
  });

  // Rated 1250 gpm ≈ 78.87 L/s @ 80 m (the saturating case):
  //   overload = 150 % flow @ 65 % head = 0.1183 m³/s @ 52 m
  //   shaft(overload) = 1000·9.81·0.118305·52/0.70 = 60 355.0.../0.70 ≈ 86.2 kW
  //   shaft(rated)    = 1000·9.81·0.078870·80/0.70 ≈ 88.4 kW  ← governs
  //   88.4 kW > the largest standard 75 kW frame ⇒ the ladder saturates.
  group('M19 — motor above the standard frame range', () {
    late FirePumpRatingResult r;
    setUpAll(() {
      r = checkFirePumpRating(
        ratedFlow: FlowRate.litersPerSecond(78.87),
        ratedHead: const Head(80),
      );
    });
    test('the standard ladder saturated at 75 kW below the duty', () {
      expect(r.oversized, isTrue);
      expect(r.selectedMotor.inKiloWatts, closeTo(75.0, 1e-9));
      expect(r.rated.shaftPower.inKiloWatts, greaterThan(75.0));
    });
    test('verdict names the true condition + the action (ASCII)', () {
      expect(
        r.verdict,
        'Motor above standard frame range - specify a custom motor or '
        'duty pairs',
      );
      expect(r.verdict.contains('curve'), isFalse);
      expect(r.verdict.codeUnits.every((c) => c < 128), isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // M12 (a)+(b) — the shallow-crossing test is real, not `2 < 0.05`.
  // ══════════════════════════════════════════════════════════════════════════
  //
  // The measure (see the module doc):
  //   S = H_op / (2·(H_shutoff − H_static))       [flow swing per head swing]
  // is flagged unstable above kOperatingPointFlowSensitivityLimit = 5.
  group('M12 — pump crossing conditioning', () {
    // STABLE: the default 50/50 split at Q = 0.01 m³/s, H = 40 m.
    //   H_static  = 20 m,  k = 20/1e-4 = 200 000
    //   H_shutoff = 40·1.25 = 50 m,  a = 10/1e-4 = 100 000
    //   Q_op = √((50−20)/300000) = √1e-4 = 0.01 m³/s  (== design)
    //   H_op = 20 + 200000·1e-4 = 40 m
    //   S    = 40 / (2·(50 − 20)) = 40/60 = 0.6667  ≤ 5  ⇒ STABLE
    test('default split: S = 0.6667 ⇒ stable', () {
      final op = computePumpOperatingPoint(
        designFlow: const FlowRate(0.01),
        designHead: const Head(40),
      );
      expect(op.operatingFlow.cubicMetersPerSecond, closeTo(0.01, 1e-12));
      expect(op.operatingHead.meters, closeTo(40.0, 1e-9));
      final s = op.operatingHead.meters /
          (2 * (op.equipmentShutoffHead.meters - op.systemStaticHead.meters));
      expect(s, closeTo(40.0 / 60.0, 1e-12));
      expect(s, lessThan(kOperatingPointFlowSensitivityLimit));
      expect(op.stable, isTrue);
    });

    // UNSTABLE: a nearly-all-static system just under the shutoff head —
    // Q = 0.01 m³/s, H_design = 40 m, H_static = 49 m, k = 10 000.
    //   H_shutoff = 50 m,  a = (50−40)/1e-4 = 100 000
    //   margin = 50 − 49 = 1 m,  den = 10 000 + 100 000 = 110 000
    //   Q_op = √(1/110000) = 0.0030151134... m³/s
    //   H_op = 49 + 10000·(1/110000) = 49 + 1/11 = 49.0909090909 m
    //   S    = 49.0909090909 / (2·1) = 24.545454...  > 5  ⇒ UNSTABLE
    // Physically: the pump is working within 1 m of its shutoff head, so a
    // 1 % head disturbance swings the flow ~24 % — the duty hunts.
    test('near-shutoff static head: S = 24.545 ⇒ unstable', () {
      final op = computePumpOperatingPoint(
        designFlow: const FlowRate(0.01),
        designHead: const Head(40),
        systemStaticHead: const Head(49),
        systemResistanceK: 10000,
      );
      expect(op.equipmentShutoffHead.meters, closeTo(50.0, 1e-12));
      expect(
        op.operatingFlow.cubicMetersPerSecond,
        closeTo(math.sqrt(1.0 / 110000.0), 1e-12),
      );
      expect(op.operatingHead.meters, closeTo(49.0 + 1.0 / 11.0, 1e-12));
      final s = op.operatingHead.meters /
          (2 * (op.equipmentShutoffHead.meters - op.systemStaticHead.meters));
      expect(s, closeTo(270.0 / 11.0, 1e-9)); // 24.5454...
      expect(s, greaterThan(kOperatingPointFlowSensitivityLimit));
      expect(op.stable, isFalse);
      // …and it is NOT the pre-existing no-real-root branch: real, positive flow.
      expect(op.operatingFlow.cubicMetersPerSecond, greaterThan(0));
    });
  });

  group('M12 — fan crossing conditioning', () {
    // STABLE: an ordinary duct system, Q = 1.0 m³/s @ 300 Pa, no fixed
    // differential.
    //   k = 300/1 = 300,  Δp_shutoff = 375 Pa,  a = 75
    //   Q_op = √(375/375) = 1.0 m³/s,  Δp_op = 300 Pa
    //   S = 300 / (2·375) = 0.4  ⇒ STABLE.
    // (An ordinary duct fan always lands at S = k/(2(k+a)) < 0.5 — the modelled
    // curves cannot cross shallowly without a fixed differential.)
    test('ordinary duct system: S = 0.4 ⇒ stable', () {
      final op = computeFanOperatingPoint(
        designAirflow: const FlowRate(1.0),
        designPressure: const Pressure(300),
      );
      expect(op.systemStaticPressure.pascals, 0.0);
      expect(op.operatingFlow.cubicMetersPerSecond, closeTo(1.0, 1e-12));
      expect(op.operatingPressure.pascals, closeTo(300.0, 1e-9));
      final s = op.operatingPressure.pascals /
          (2 *
              (op.equipmentShutoffPressure.pascals -
                  op.systemStaticPressure.pascals));
      expect(s, closeTo(0.4, 1e-12));
      expect(op.stable, isTrue);
    });

    // UNSTABLE: a stairwell-pressurisation fan holding a fixed 360 Pa while its
    // own shutoff is 375 Pa — Q = 1.0 m³/s @ 300 Pa design, k = 40.
    //   Δp_shutoff = 375 Pa,  a = (375−300)/1 = 75
    //   margin = 375 − 360 = 15 Pa,  den = 40 + 75 = 115
    //   Q_op = √(15/115) = √(3/23) = 0.36115756... m³/s
    //   Δp_op = 360 + 40·(3/23) = 360 + 120/23 = 8400/23 = 365.217391 Pa
    //   S = 365.217391 / (2·15) = 280/23 = 12.1739  > 5  ⇒ UNSTABLE.
    test('fixed differential near shutoff: S = 12.174 ⇒ unstable', () {
      final op = computeFanOperatingPoint(
        designAirflow: const FlowRate(1.0),
        designPressure: const Pressure(300),
        systemStaticPressure: const Pressure(360),
        systemResistanceK: 40,
      );
      expect(op.equipmentShutoffPressure.pascals, closeTo(375.0, 1e-12));
      expect(
        op.operatingFlow.cubicMetersPerSecond,
        closeTo(math.sqrt(3.0 / 23.0), 1e-12),
      );
      expect(op.operatingPressure.pascals, closeTo(8400.0 / 23.0, 1e-9));
      final s = op.operatingPressure.pascals /
          (2 *
              (op.equipmentShutoffPressure.pascals -
                  op.systemStaticPressure.pascals));
      expect(s, closeTo(280.0 / 23.0, 1e-9));
      expect(s, greaterThan(kOperatingPointFlowSensitivityLimit));
      expect(op.stable, isFalse);
      expect(op.operatingFlow.cubicMetersPerSecond, greaterThan(0));
    });

    test('the default zero differential leaves the legacy path unchanged', () {
      // k back-solve, shutoff, droop, Q_op and Δp_op are all identical to the
      // pre-M12 no-static formulation.
      final op = computeFanOperatingPoint(
        designAirflow: const FlowRate(1.0),
        designPressure: const Pressure(250),
        systemResistanceK: 100,
      );
      expect(op.systemResistanceK, closeTo(100.0, 1e-12));
      expect(op.equipmentShutoffPressure.pascals, closeTo(312.5, 1e-12));
      expect(op.equipmentDroopA, closeTo(62.5, 1e-12));
      expect(
        op.operatingFlow.cubicMetersPerSecond,
        closeTo(math.sqrt(312.5 / 162.5), 1e-12),
      );
      expect(op.operatingPressure.pascals, closeTo(100.0 * 312.5 / 162.5, 1e-9));
      expect(op.stable, isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // M12 (c) — NPSH_required comes from the SUCTION side, not from 15 % of the
  //           total system head.
  // ══════════════════════════════════════════════════════════════════════════
  //
  // Correlation:  NPSH_r = (n·√Q_op / N_ss)^(4/3),  n = 2900 rpm, N_ss = 160,
  // floored at 0.5 m.
  //
  // The regression case the audit named — a FLOODED-SUCTION 60 m-head pump at
  // Q = 0.01 m³/s (10 L/s), suction static 0 m:
  //   NPSH_a = (101325 − 2339)/(1000·9.81) = 98986/9810 = 10.0903160 m
  //   n·√Q   = 2900 × 0.1 = 290 ;  290/160 = 1.8125
  //   NPSH_r = 1.8125^(4/3) = 2.2098902 m  (floor 0.5 m not binding)
  //   1.5 × 2.2098902 = 3.3148352 m  <  10.0903160 m  ⇒  NO cavitation risk.
  // Under the OLD rule NPSH_r was 0.15 × 60 = 9 m and 1.5 × 9 = 13.5 m > 10.09,
  // so a perfectly good flooded-suction installation was flagged.
  group('M12 — flooded-suction 60 m pump is no longer flagged', () {
    late PumpOperatingPoint op;
    setUpAll(() {
      op = computePumpOperatingPoint(
        designFlow: const FlowRate(0.01),
        designHead: const Head(60),
      );
    });
    test('NPSH available = 10.09032 m (hand-arithmetic)', () {
      const expected = (101325.0 - 2339.0) / (defaultWaterDensity * standardGravity);
      expect(expected, closeTo(10.0903160, 1e-6));
      expect(op.npshAvailable.meters, closeTo(expected, 1e-12));
    });
    test('NPSH required = (2900·√0.01/160)^(4/3) = 2.2098902 m', () {
      final expected = math.pow(2900.0 * 0.1 / 160.0, 4.0 / 3.0).toDouble();
      expect(expected, closeTo(2.209890154236345, 1e-12));
      expect(op.npshRequired.meters, closeTo(expected, 1e-12));
      // Independent of the total head, which is the whole fix: the same flow at
      // half the head asks for exactly the same NPSH_r.
      final half = computePumpOperatingPoint(
        designFlow: const FlowRate(0.01),
        designHead: const Head(30),
      );
      expect(half.npshRequired.meters, closeTo(expected, 1e-12));
    });
    test('no cavitation risk (10.09 >= 1.5 x 2.2098902 = 3.3148352)', () {
      expect(op.cavitationRisk, isFalse);
      expect(
        op.npshAvailable.meters,
        greaterThan(kNpshSafetyMargin * op.npshRequired.meters),
      );
    });
  });

  // The same pump on a GENUINE high-lift suction (7 m below the centreline):
  //   h_suction_fric = 0.10 × 7 = 0.7 m
  //   NPSH_a = 10.0903160 − 7 − 0.7 = 2.3903160 m
  //   NPSH_r = 2.2098902 m ⇒ 1.5 × NPSH_r = 3.3148352 m > 2.3903160 ⇒ RISK.
  group('M12 — genuine high-lift suction still flags cavitation', () {
    late PumpOperatingPoint op;
    setUpAll(() {
      op = computePumpOperatingPoint(
        designFlow: const FlowRate(0.01),
        designHead: const Head(60),
        suctionStaticHead: const Head(-7),
      );
    });
    test('NPSH available = 2.39032 m (hand-arithmetic)', () {
      const expected =
          (101325.0 - 2339.0) / (defaultWaterDensity * standardGravity) -
              7.0 -
              0.7;
      expect(expected, closeTo(2.3903160, 1e-6));
      expect(op.npshAvailable.meters, closeTo(expected, 1e-12));
    });
    test('cavitation risk flagged (2.3903160 < 3.3148352)', () {
      expect(op.cavitationRisk, isTrue);
    });
  });

  group('M12 — NPSH_required guards', () {
    test('the conservative floor holds for a very small pump', () {
      // Q = 0.0005 m³/s: 2900·√0.0005 = 64.8459...; /160 = 0.405287...;
      // ^(4/3) = 0.2999282 m — below the 0.5 m floor, so 0.5 m is reported.
      final raw =
          math.pow(2900.0 * math.sqrt(0.0005) / 160.0, 4.0 / 3.0).toDouble();
      expect(raw, lessThan(kMinNpshRequiredM));
      final op = computePumpOperatingPoint(
        designFlow: const FlowRate(0.0005),
        designHead: const Head(20),
      );
      expect(op.npshRequired.meters, closeTo(kMinNpshRequiredM, 1e-12));
    });

    test('no operating flow ⇒ NPSH_r 0 and no cavitation claim', () {
      // Static head above shutoff ⇒ no real root ⇒ Q_op = 0.
      final op = computePumpOperatingPoint(
        designFlow: const FlowRate(0.01),
        designHead: const Head(10),
        systemStaticHead: const Head(20),
        systemResistanceK: 100,
      );
      expect(op.operatingFlow.cubicMetersPerSecond, 0.0);
      expect(op.stable, isFalse);
      expect(op.npshRequired.meters, 0.0);
      expect(op.cavitationRisk, isFalse);
    });
  });
}
