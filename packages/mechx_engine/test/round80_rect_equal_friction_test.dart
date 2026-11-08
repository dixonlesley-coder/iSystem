// Round 80 (2026-10-18) — plumbing-hvac-convergence-29-rect-equal-friction-
// not-minimal. With a velocity cap, a rectangular equal-friction duct is never
// larger in area than the velocity-method section whenever that section
// already meets the friction target.
//
// First principles at Q = 3.0 m3/s, cap 5 m/s, aspect 1.5, target 1 Pa/m:
// required area 3.0 / 5 = 0.60 m2; H = sqrt(0.60 / 1.5) = 632 mm -> 700,
// W = 1.5 x 632 = 949 mm -> 1000 => 1000 x 700 = 0.70 m2 => 4.29 m/s. The
// aspect-tied ladder jumped 900 x 600 (0.54 m2 = 5.56 m/s, rejected) to
// 1200 x 700 (0.84 m2).
library;

import 'dart:math' as math;

import 'package:mechx_engine/sizing/duct_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

double _a(RectangularDuctResult r) => r.width.meters * r.height.meters;

void main() {
  test('3.0 m3/s @ 5 m/s: 1000 x 700, not 1200 x 700', () {
    final r = sizeRectangularByEqualFriction(
        airflow: const FlowRate(3.0),
        targetPaPerMetre: 1.0,
        maxVelocity: const Velocity(5));
    expect(r.width.meters * 1000, closeTo(1000, 1e-6));
    expect(r.height.meters * 1000, closeTo(700, 1e-6));
    expect(r.actualVelocity.metersPerSecond, closeTo(3.0 / 0.70, 1e-9));
    expect(r.frictionPerMetrePa, lessThanOrEqualTo(1.0));
    expect(r.overCapacity, isFalse);
  });

  test('no cap: friction-only ladder unchanged (800 x 500 for 3.0 m3/s)', () {
    final r = sizeRectangularByEqualFriction(
        airflow: const FlowRate(3.0), targetPaPerMetre: 1.0);
    expect(r.width.meters * 1000, closeTo(800, 1e-6));
    expect(r.height.meters * 1000, closeTo(500, 1e-6));
  });

  test('seeded property: never larger than an adequate velocity section; '
      'always meets both constraints', () {
    final rnd = math.Random(80);
    for (var t = 0; t < 400; t++) {
      final q = 0.05 + rnd.nextDouble() * 6.95;
      final cap = 3.0 + rnd.nextDouble() * 5.0;
      final target = 0.5 + rnd.nextDouble() * 1.5;
      final aspect = 1.0 + rnd.nextDouble() * 1.5;
      final ef = sizeRectangularByEqualFriction(
          airflow: FlowRate(q),
          targetPaPerMetre: target,
          aspectRatio: aspect,
          maxVelocity: Velocity(cap));
      final vel = sizeRectangularByVelocity(
          airflow: FlowRate(q),
          maxVelocity: Velocity(cap),
          aspectRatio: aspect);
      final why = 'trial $t q=$q cap=$cap target=$target aspect=$aspect';
      if (!ef.overCapacity) {
        expect(ef.frictionPerMetrePa, lessThanOrEqualTo(target + 1e-9),
            reason: why);
        expect(ef.actualVelocity.metersPerSecond,
            lessThanOrEqualTo(cap + 1e-6),
            reason: why);
      }
      if (!vel.overCapacity && vel.frictionPerMetrePa <= target) {
        expect(_a(ef), lessThanOrEqualTo(_a(vel) + 1e-12), reason: why);
      }
    }
  });
}
