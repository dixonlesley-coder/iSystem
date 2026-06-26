/// Tests for the air-velocity band checks (manual-routing sanity guard).
///
/// Expected values are hand-computed; arithmetic shown in comments.
library;

import 'package:mechx_engine/sizing/air_velocity.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  group('checkVelocityBand', () {
    test('inside the band is OK', () {
      final c = checkVelocityBand(const Velocity(5.0),
          min: const Velocity(3.0), max: const Velocity(7.0));
      expect(c.verdict, VelocityBandVerdict.ok);
      expect(c.isWarning, isFalse);
    });

    test('below the min is tooLow', () {
      final c = checkVelocityBand(const Velocity(2.0),
          min: const Velocity(3.0), max: const Velocity(7.0));
      expect(c.verdict, VelocityBandVerdict.tooLow);
      expect(c.isWarning, isTrue);
      expect(c.message, contains('too low'));
    });

    test('above the max is tooHigh', () {
      final c = checkVelocityBand(const Velocity(8.5),
          min: const Velocity(3.0), max: const Velocity(7.0));
      expect(c.verdict, VelocityBandVerdict.tooHigh);
      expect(c.isWarning, isTrue);
      expect(c.message, contains('too high'));
    });

    test('the band edges are inclusive (OK exactly at min and max)', () {
      expect(
        checkVelocityBand(const Velocity(3.0),
                min: const Velocity(3.0), max: const Velocity(7.0))
            .verdict,
        VelocityBandVerdict.ok,
      );
      expect(
        checkVelocityBand(const Velocity(7.0),
                min: const Velocity(3.0), max: const Velocity(7.0))
            .verdict,
        VelocityBandVerdict.ok,
      );
    });

    test('non-positive velocity (no flow / no size) does not warn', () {
      final c = checkVelocityBand(const Velocity(0.0),
          min: const Velocity(3.0), max: const Velocity(7.0));
      expect(c.verdict, VelocityBandVerdict.ok);
      expect(c.isWarning, isFalse);
    });
  });

  group('faceVelocityFor', () {
    test('Q=0.2 m³/s, gross=0.135 m², ratio=0.8 → 1.852 m/s', () {
      // freeArea = 0.135 × 0.8 = 0.108 m²; v = 0.2 / 0.108 = 1.8519 m/s.
      final v = faceVelocityFor(const FlowRate(0.2),
          grossFaceArea: const Area(0.135));
      expect(v.metersPerSecond, closeTo(1.8519, 1e-3));
    });

    test('zero face area gives zero velocity (undefined, no divide)', () {
      final v = faceVelocityFor(const FlowRate(0.2),
          grossFaceArea: const Area(0.0));
      expect(v.metersPerSecond, 0.0);
    });
  });

  group('typed-band helpers', () {
    test('supply duct: 7.0 OK, 8.0 too high, 2.5 too low', () {
      expect(checkSupplyDuctVelocity(const Velocity(7.0)).verdict,
          VelocityBandVerdict.ok);
      expect(checkSupplyDuctVelocity(const Velocity(8.0)).verdict,
          VelocityBandVerdict.tooHigh);
      expect(checkSupplyDuctVelocity(const Velocity(2.5)).verdict,
          VelocityBandVerdict.tooLow);
    });

    test('supply face caps at 3.0; return face tolerates up to 4.0', () {
      // 3.5 m/s is noisy for a SUPPLY diffuser but acceptable for a RETURN.
      expect(checkSupplyFaceVelocity(const Velocity(3.5)).verdict,
          VelocityBandVerdict.tooHigh);
      expect(checkReturnFaceVelocity(const Velocity(3.5)).verdict,
          VelocityBandVerdict.ok);
    });

    test('bands are ordered min < max', () {
      expect(kSupplyDuctVelocityMin.metersPerSecond,
          lessThan(kSupplyDuctVelocityMax.metersPerSecond));
      expect(kSupplyFaceVelocityMin.metersPerSecond,
          lessThan(kSupplyFaceVelocityMax.metersPerSecond));
      expect(kReturnFaceVelocityMin.metersPerSecond,
          lessThan(kReturnFaceVelocityMax.metersPerSecond));
    });
  });
}
