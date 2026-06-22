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
}
