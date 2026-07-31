/// Tests for the shared return/exhaust extract-duct velocity band.
///
/// Expected values are hand-computed; arithmetic shown in comments.
library;

import 'package:mechx_engine/sizing/air_velocity.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  group('checkExtractDuctVelocity', () {
    test('below the min (1.5 < 2.0) is tooLow', () {
      final c = checkExtractDuctVelocity(const Velocity(1.5));
      expect(c.verdict, VelocityBandVerdict.tooLow);
      expect(c.isWarning, isTrue);
      expect(c.message, contains('too low'));
    });

    test('at the min (2.0) is OK — band edges inclusive', () {
      expect(checkExtractDuctVelocity(const Velocity(2.0)).verdict,
          VelocityBandVerdict.ok);
    });

    test('inside the band (4.0) is OK', () {
      final c = checkExtractDuctVelocity(const Velocity(4.0));
      expect(c.verdict, VelocityBandVerdict.ok);
      expect(c.isWarning, isFalse);
    });

    test('at the max (6.0) is OK — band edges inclusive', () {
      expect(checkExtractDuctVelocity(const Velocity(6.0)).verdict,
          VelocityBandVerdict.ok);
    });

    test('above the max (6.5 > 6.0) is tooHigh', () {
      final c = checkExtractDuctVelocity(const Velocity(6.5));
      expect(c.verdict, VelocityBandVerdict.tooHigh);
      expect(c.isWarning, isTrue);
      expect(c.message, contains('too high'));
    });

    test('the two bands are genuinely distinct — 2.5 m/s fails supply '
        '(< 3.0 min) but passes extract (>= 2.0 min)', () {
      expect(checkSupplyDuctVelocity(const Velocity(2.5)).verdict,
          VelocityBandVerdict.tooLow);
      expect(checkExtractDuctVelocity(const Velocity(2.5)).verdict,
          VelocityBandVerdict.ok);
    });

    test('bands are ordered min < max', () {
      expect(kExtractDuctVelocityMin.metersPerSecond,
          lessThan(kExtractDuctVelocityMax.metersPerSecond));
    });
  });
}
