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
