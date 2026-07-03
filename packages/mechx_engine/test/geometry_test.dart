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

    test('floorHeightOf returns each level height', () {
      expect(levels.floorHeightOf(0).meters, closeTo(4.0, 1e-12));
      expect(levels.floorHeightOf(2).meters, closeTo(3.5, 1e-12));
    });

    test('ceiling elevation = floor surface + height − ceilingDrop (0.3)', () {
      // ground ceiling = 0 + 4.0 − 0.3 = 3.7; level-2 = 7.5 + 3.5 − 0.3 = 10.7
      expect(levels.ceilingElevationOf(0).meters, closeTo(3.7, 1e-12));
      expect(levels.ceilingElevationOf(2).meters, closeTo(10.7, 1e-12));
    });

    test('fixture elevation = floor surface + fixtureHeight (1.1)', () {
      expect(levels.fixtureElevationOf(0).meters, closeTo(1.1, 1e-12));
      expect(levels.fixtureElevationOf(1).meters, closeTo(5.1, 1e-12)); // 4+1.1
    });

    test('custom mounting heights override the defaults', () {
      const m = MountingHeights(
        ceilingDrop: Length(0.5),
        fixtureHeight: Length(0.9),
      );
      expect(levels.ceilingElevationOf(0, m).meters, closeTo(3.5, 1e-12));
      expect(levels.fixtureElevationOf(0, m).meters, closeTo(0.9, 1e-12));
    });

    test('roof elevation aliases total height', () {
      expect(levels.roofElevation.meters, closeTo(11.0, 1e-12));
    });

    test('an out-of-range floor index CLAMPS instead of throwing (§10 safety)',
        () {
      // A node stranded above the top floor (or below the base) — e.g. left
      // over after a floor was removed — must never crash the always-on solve
      // with a RangeError. Every elevation accessor clamps to the nearest real
      // floor (top for over-range, base for negative) and returns normally.
      expect(() => levels.elevationOf(1000), returnsNormally);
      expect(() => levels.floorHeightOf(1000), returnsNormally);
      expect(() => levels.ceilingElevationOf(1000), returnsNormally);
      expect(() => levels.fixtureElevationOf(1000), returnsNormally);
      expect(() => levels.elevationOf(-5), returnsNormally);

      // Over-range resolves to the TOP floor (index 2); under-range to the base.
      expect(levels.elevationOf(99).meters,
          closeTo(levels.elevationOf(2).meters, 1e-12));
      expect(levels.elevationOf(-3).meters,
          closeTo(levels.elevationOf(0).meters, 1e-12));
      expect(levels.floorHeightOf(99).meters,
          closeTo(levels.floorHeightOf(2).meters, 1e-12));
      expect(levels.ceilingElevationOf(99).meters,
          closeTo(levels.ceilingElevationOf(2).meters, 1e-12));
      expect(levels.fixtureElevationOf(99).meters,
          closeTo(levels.fixtureElevationOf(2).meters, 1e-12));
    });
  });
}
