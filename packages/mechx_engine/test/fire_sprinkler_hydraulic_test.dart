/// Tests for the sprinkler remote-area hydraulic calc (K-factor + branch
/// friction + minimum-operating-pressure check).
///
/// All expected values are derived by hand from the discharge law `Q = K·√P`
/// (so `P = (Q/K)²`, with Q in L/min and P in bar) and from the engine's own
/// Hazen–Williams primitive for the branch friction (no magic numbers — the
/// branch loss is cross-checked against `headLossHazenWilliams` directly).
library;

import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_sprinkler_hydraulic.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  // ── Discharge law  Q = K·√P  ⇔  P = (Q/K)²  ────────────────────────────────
  group('headPressureForFlow / headFlowForPressure (Q = K·√P)', () {
    // K = 80, Q = 80 L/min → P = (80/80)² = 1 bar.
    test('Q = K → P = 1 bar', () {
      final p = headPressureForFlow(FlowRate.litersPerMinute(80), 80);
      expect(p.inBar, closeTo(1.0, 1e-12));
    });

    // K = 80, Q = 60 L/min → P = (60/80)² = 0.75² = 0.5625 bar.
    test('Q = 60 L/min, K = 80 → P = 0.5625 bar', () {
      final p = headPressureForFlow(FlowRate.litersPerMinute(60), 80);
      expect(p.inBar, closeTo(0.5625, 1e-12));
    });

    // Inverse: at P = 0.5625 bar, K = 80 → Q = 80·√0.5625 = 80·0.75 = 60 L/min.
    test('round-trip: P = 0.5625 bar, K = 80 → Q = 60 L/min', () {
      final q = headFlowForPressure(Pressure.bar(0.5625), 80);
      expect(q.inLitersPerMinute, closeTo(60.0, 1e-9));
    });

    test('headFlowForPressure ∘ headPressureForFlow is identity', () {
      final q0 = FlowRate.litersPerMinute(73.4);
      final p = headPressureForFlow(q0, 80);
      final q1 = headFlowForPressure(p, 80);
      expect(q1.inLitersPerMinute, closeTo(73.4, 1e-9));
    });
  });

  // ── Primary worked example: OH1, K = 80, default 20 m / 25 mm branch ───────
  //
  // OH1 density/area → flowPerSprinkler = 60 L/min (= 1.0 L/s) (see
  // fire_sprinkler_test.dart for that derivation).
  //
  //   remoteHeadPressure = (60/80)² = 0.5625 bar = 56 250 Pa
  //   minOperatingPressure (default) = 0.5 bar = 50 000 Pa
  //   0.5625 bar ≥ 0.5 bar → meetsMinimumPressure = true
  group('remoteAreaHydraulics — OH1, K = 80 (meets minimum)', () {
    late SprinklerDesign design;
    late SprinklerRemoteAreaResult r;

    setUp(() {
      design = designSprinklerSystem(hazard: FireHazardClass.ordinaryHazard1);
      r = remoteAreaHydraulics(design: design);
    });

    test('remote head flow == the density/area per-head share (60 L/min)', () {
      expect(r.remoteHeadFlow.inLitersPerMinute, closeTo(60.0, 1e-9));
    });

    test('remoteHeadPressure = (60/80)² = 0.5625 bar', () {
      expect(r.remoteHeadPressure.inBar, closeTo(0.5625, 1e-9));
    });

    test('default minimum operating pressure is 0.5 bar', () {
      expect(r.minOperatingPressure.inBar, closeTo(0.5, 1e-12));
    });

    test('meets minimum pressure (0.5625 ≥ 0.5 bar)', () {
      expect(r.meetsMinimumPressure, isTrue);
      expect(r.verdict, 'Remote head OK');
    });

    // Branch friction is the engine's own Hazen–Williams loss at 60 L/min over
    // a 20 m, 25 mm, C = 120 branch — cross-checked against the primitive.
    test('branchLineFrictionHead == headLossHazenWilliams at the head flow', () {
      final expected = headLossHazenWilliams(
        flow: FlowRate.litersPerMinute(60),
        length: const Length(20),
        diameter: const Diameter(0.025),
        hazenWilliamsC: 120,
      );
      expect(r.branchLineFrictionHead.meters, closeTo(expected.meters, 1e-12));
      expect(r.branchLineFrictionHead.meters, greaterThan(0));
    });

    // branchBasePressure = remote-head pressure + friction (as pressure).
    test('branchBasePressure = head pressure + friction-as-pressure', () {
      final frictionAsPressure = pressureFromHead(r.branchLineFrictionHead);
      expect(
        r.branchBasePressure.pascals,
        closeTo(
          r.remoteHeadPressure.pascals + frictionAsPressure.pascals,
          1e-6,
        ),
      );
      // Base must exceed the head pressure (friction is positive).
      expect(
        r.branchBasePressure.pascals,
        greaterThan(r.remoteHeadPressure.pascals),
      );
    });
  });

  // ── Under-pressure case: light hazard, K = 80 ──────────────────────────────
  //
  // Light hazard density/area → flowPerSprinkler = 37.8 L/min.
  //   remoteHeadPressure = (37.8/80)² = 0.4725² = 0.22325625 bar ≈ 0.223 bar
  //   minOperatingPressure default = 0.5 bar
  //   0.223 < 0.5 → meetsMinimumPressure = false, verdict 'Remote head under-pressure'
  group('remoteAreaHydraulics — light hazard under-pressure', () {
    late SprinklerRemoteAreaResult r;

    setUp(() {
      final design = designSprinklerSystem(hazard: FireHazardClass.lightHazard);
      r = remoteAreaHydraulics(design: design);
    });

    test('remote head flow == 37.8 L/min', () {
      expect(r.remoteHeadFlow.inLitersPerMinute, closeTo(37.8, 1e-9));
    });

    // (37.8/80)² = 0.4725² = 0.22325625 bar
    test('remoteHeadPressure ≈ 0.2233 bar', () {
      expect(r.remoteHeadPressure.inBar, closeTo(0.4725 * 0.4725, 1e-9));
    });

    test('does NOT meet minimum (0.223 < 0.5 bar)', () {
      expect(r.meetsMinimumPressure, isFalse);
      expect(r.verdict, 'Remote head under-pressure');
    });

    // Raising K lowers the required pressure further (K=160 → P = (37.8/160)²);
    // lowering the minimum threshold can flip the verdict to OK.
    test('a lower minimum threshold flips the verdict to OK', () {
      final design = designSprinklerSystem(hazard: FireHazardClass.lightHazard);
      final relaxed = remoteAreaHydraulics(
        design: design,
        minOperatingPressure: Pressure.bar(0.2),
      );
      expect(relaxed.meetsMinimumPressure, isTrue);
    });
  });

  // ── K-factor sensitivity ───────────────────────────────────────────────────
  group('K-factor sensitivity (OH1, 60 L/min)', () {
    test('doubling K quarters the required pressure', () {
      final design = designSprinklerSystem(hazard: FireHazardClass.ordinaryHazard1);
      final k80 = remoteAreaHydraulics(design: design, kFactor: 80);
      final k160 = remoteAreaHydraulics(design: design, kFactor: 160);
      // P ∝ 1/K² → P(160) = P(80) / 4.
      expect(
        k160.remoteHeadPressure.inBar,
        closeTo(k80.remoteHeadPressure.inBar / 4.0, 1e-9),
      );
    });
  });
}
