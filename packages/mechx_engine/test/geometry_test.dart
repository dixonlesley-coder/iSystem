import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  group('ScaleCalibration', () {
    test('fromReference: 5 m over 200 px → 0.025 m/px', () {
      final cal = ScaleCalibration.fromReference(
        pixelDistance: 200,
        realDistance: const Length(5.0),
      );
      expect(cal.metersPerPixel, closeTo(0.025, 1e-12));
    });

    test('px → length and back round-trips', () {
      const cal = ScaleCalibration(0.025);
      expect(cal.lengthForPixels(200).meters, closeTo(5.0, 1e-12));
      expect(cal.pixelsForLength(const Length(2.5)), closeTo(100.0, 1e-12));
    });

    test('areaForPixels scales by the square of the calibration', () {
      const cal = ScaleCalibration(0.025);
      // 100 px × 100 px = 10 000 px² → (100·0.025)² = 2.5 m × 2.5 m = 6.25 m²
      expect(cal.areaForPixels(10000).squareMeters, closeTo(6.25, 1e-12));
    });
  });

  group('BuildingLevels', () {
    const levels = BuildingLevels([
      Floor('Ground', Length(4.0)),
      Floor('Level 1', Length(3.5)),
      Floor('Level 2', Length(3.5)),
    ]);

    test('elevations accumulate from the base', () {
      expect(levels.elevationOf(0).meters, 0.0);
      expect(levels.elevationOf(1).meters, closeTo(4.0, 1e-12));
      expect(levels.elevationOf(2).meters, closeTo(7.5, 1e-12));
    });

    test('riser length is the absolute elevation delta', () {
      expect(levels.riserLength(0, 2).meters, closeTo(7.5, 1e-12));
      expect(levels.riserLength(2, 0).meters, closeTo(7.5, 1e-12));
      expect(levels.riserLength(1, 1).meters, 0.0);
    });

    test('total height sums floor heights; count is correct', () {
      expect(levels.totalHeight.meters, closeTo(11.0, 1e-12));
      expect(levels.levelCount, 3);
    });
  });
}
