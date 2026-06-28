/// Tests for rectangular duct sizing (velocity method + equivalent diameter).
library;

import 'package:mechx_engine/sizing/duct_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  group('sizeRectangularByVelocity — Q=1.0 m³/s, vmax=5, aspect 1.5', () {
    late RectangularDuctResult r;
    setUp(() {
      r = sizeRectangularByVelocity(
        airflow: const FlowRate(1.0),
        maxVelocity: const Velocity(5.0),
      );
    });

    // reqArea = 1.0/5 = 0.2 m². H=√(0.2/1.5)=0.365 m→400 mm; W=1.5·H=0.548→600 mm.
    test('rounds each side up to a standard size (600 × 400 mm)', () {
      expect(r.width.inMillimeters, closeTo(600, 1e-9));
      expect(r.height.inMillimeters, closeTo(400, 1e-9));
    });

    test('actual velocity uses the true rectangular area and is ≤ limit', () {
      // 0.6 × 0.4 = 0.24 m²; v = 1.0/0.24 = 4.167 m/s.
      expect(r.actualVelocity.metersPerSecond, closeTo(1.0 / 0.24, 1e-9));
      expect(r.actualVelocity.metersPerSecond, lessThanOrEqualTo(5.0));
    });

    test('equivalent diameter via ASHRAE formula ≈ 0.533 m', () {
      // De = 1.30·(0.24)^0.625 / (1.0)^0.25 ≈ 0.5327 m
      expect(r.equivalentDiameter.meters, closeTo(0.5327, 1e-3));
    });

    test('friction per metre is positive', () {
      expect(r.frictionPerMetrePa, greaterThan(0));
    });
  });

  test('higher aspect ratio widens the duct', () {
    final square = sizeRectangularByVelocity(
        airflow: const FlowRate(1.0),
        maxVelocity: const Velocity(5.0),
        aspectRatio: 1.0);
    final wide = sizeRectangularByVelocity(
        airflow: const FlowRate(1.0),
        maxVelocity: const Velocity(5.0),
        aspectRatio: 3.0);
    expect(wide.width.meters, greaterThanOrEqualTo(square.width.meters));
  });

  group('sizeRectangularByEqualFriction', () {
    test('picks the smallest W×H within the friction target (engine-derived)', () {
      // Q = 500 m³/h = 0.138889 m³/s, target 1.0 Pa/m, aspect 1.5.
      // The method walks ascending H; W = aspect·H rounded up to a standard
      // side; friction is read from the equivalent diameter. We DERIVE the
      // expected qualifying W×H from the engine's own primitives (no magic
      // numbers): the first candidate whose ductFrictionPaPerMetre(De) ≤ 1.0.
      const q = FlowRate(0.138889);
      const target = 1.0;
      const aspect = 1.5;

      double roundUpSide(double mm) =>
          standardDuctSidesMm.firstWhere((s) => s >= mm,
              orElse: () => standardDuctSidesMm.last);

      // Reproduce the selection independently using the engine primitives.
      double? expW, expH;
      double? prevFriction; // friction of the largest non-qualifying candidate
      for (final hMm in standardDuctSidesMm) {
        final h = Length(hMm / 1000.0);
        final w = Length(roundUpSide(aspect * hMm) / 1000.0);
        final de = rectangularEquivalentDiameter(w, h);
        final fr = ductFrictionPaPerMetre(q, de);
        if (fr <= target) {
          expW = w.meters;
          expH = h.meters;
          break;
        }
        prevFriction = fr;
      }
      expect(expW, isNotNull, reason: 'a qualifying W×H must exist');

      final r = sizeRectangularByEqualFriction(
        airflow: q,
        targetPaPerMetre: target,
        aspectRatio: aspect,
      );
      expect(r.width.meters, closeTo(expW!, 1e-12));
      expect(r.height.meters, closeTo(expH!, 1e-12));
      expect(r.frictionPerMetrePa, lessThanOrEqualTo(target));
      expect(r.overCapacity, isFalse);
      // The next-smaller candidate (if any) genuinely exceeded the target —
      // confirms the returned size is the SMALLEST qualifying one.
      if (prevFriction != null) {
        expect(prevFriction, greaterThan(target));
      }
    });

    test('clamps to the largest sides and flags overCapacity when unreachable', () {
      // A very large flow cannot meet 1.0 Pa/m at any standard W×H → CLAMP.
      final r = sizeRectangularByEqualFriction(
        airflow: const FlowRate(20.0),
        aspectRatio: 1.5,
      );
      expect(r.width.inMillimeters, closeTo(standardDuctSidesMm.last, 1e-9));
      expect(r.height.inMillimeters, closeTo(standardDuctSidesMm.last, 1e-9));
      expect(r.overCapacity, isTrue);
      expect(r.frictionPerMetrePa, greaterThan(1.0));
    });
  });
}
