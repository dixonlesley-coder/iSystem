/// Tests for the storm / rainwater sizing module.
library;

import 'package:mechx_engine/sizing/storm_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  group('rainwaterDesignFlow', () {
    test('200 mm/hr over 100 m² → 5.556 L/s', () {
      // Q = 200 × 100 / (1000 × 3600) = 20000 / 3.6e6 = 0.0055556 m³/s
      final q = rainwaterDesignFlow(intensityMmPerHr: 200, roofAreaM2: 100);
      expect(q.cubicMetersPerSecond, closeTo(200 * 100 / 3.6e6, 1e-12));
      expect(q.inLitersPerSecond, closeTo(5.5556, 1e-3));
    });

    test('runoffCoefficient defaults to 1.0 (byte-identical to before)', () {
      // No coefficient passed ⇒ C = 1.0 ⇒ identical to the historic formula.
      final q = rainwaterDesignFlow(intensityMmPerHr: 200, roofAreaM2: 100);
      expect(q.cubicMetersPerSecond, closeTo(200 * 100 / 3.6e6, 1e-12));
    });

    test('runoffCoefficient=0.5 halves the flow vs C=1.0', () {
      // Q(C) = C × intensity × area / 3.6e6, so C=0.5 is exactly half of C=1.0.
      final full =
          rainwaterDesignFlow(intensityMmPerHr: 200, roofAreaM2: 100);
      final half = rainwaterDesignFlow(
        intensityMmPerHr: 200,
        roofAreaM2: 100,
        runoffCoefficient: 0.5,
      );
      // C=0.5: 0.5 × 200 × 100 / 3.6e6 = 0.0027778 m³/s = 2.7778 L/s.
      expect(half.cubicMetersPerSecond,
          closeTo(0.5 * 200 * 100 / 3.6e6, 1e-12));
      expect(half.cubicMetersPerSecond,
          closeTo(0.5 * full.cubicMetersPerSecond, 1e-12));
      expect(half.inLitersPerSecond, closeTo(2.7778, 1e-3));
    });

    test('runoffCoefficient scales the flow linearly', () {
      final c09 = rainwaterDesignFlow(
          intensityMmPerHr: 250, roofAreaM2: 80, runoffCoefficient: 0.9);
      final c10 = rainwaterDesignFlow(
          intensityMmPerHr: 250, roofAreaM2: 80, runoffCoefficient: 1.0);
      expect(c09.cubicMetersPerSecond,
          closeTo(0.9 * c10.cubicMetersPerSecond, 1e-12));
    });

    test('scales linearly with area and intensity', () {
      final base = rainwaterDesignFlow(intensityMmPerHr: 100, roofAreaM2: 50);
      final twiceArea =
          rainwaterDesignFlow(intensityMmPerHr: 100, roofAreaM2: 100);
      final twiceRain =
          rainwaterDesignFlow(intensityMmPerHr: 200, roofAreaM2: 50);
      expect(twiceArea.cubicMetersPerSecond,
          closeTo(2 * base.cubicMetersPerSecond, 1e-12));
      expect(twiceRain.cubicMetersPerSecond,
          closeTo(2 * base.cubicMetersPerSecond, 1e-12));
    });
  });

  group('sizeRainwaterDownpipe', () {
    test('5.556 L/s needs DN100 (75 mm caps at 5.0 L/s)', () {
      final q = rainwaterDesignFlow(intensityMmPerHr: 200, roofAreaM2: 100);
      final r = sizeRainwaterDownpipe(q);
      expect(r.diameter.inMillimeters, 100);
      expect(r.overCapacity, isFalse);
      expect(r.capacityLps, 10.5);
    });

    test('tiny flow → smallest pipe (DN50)', () {
      final r = sizeRainwaterDownpipe(const FlowRate(0.0005)); // 0.5 L/s
      expect(r.diameter.inMillimeters, 50);
    });

    test('huge flow → largest pipe flagged over capacity', () {
      final r = sizeRainwaterDownpipe(const FlowRate(0.5)); // 500 L/s
      expect(r.diameter.inMillimeters, 200);
      expect(r.overCapacity, isTrue);
    });

    test('capacity is monotonic with diameter (table sanity)', () {
      var prevCap = 0.0;
      var prevDia = 0.0;
      for (final (cap, mm) in standardDownpipeCapacities) {
        expect(cap, greaterThan(prevCap));
        expect(mm, greaterThan(prevDia));
        prevCap = cap;
        prevDia = mm;
      }
    });
  });
}
