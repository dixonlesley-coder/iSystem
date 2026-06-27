import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/smart_input_store.dart';

void main() {
  group('parseDrawingInput', () {
    test('plain length parses, no angle', () {
      final r = parseDrawingInput('3000');
      expect(r.ok, isTrue);
      expect(r.lengthMm, 3000);
      expect(r.angleDeg, isNull);
      expect(r.error, isNull);
    });

    test('length + angle parses both', () {
      final r = parseDrawingInput('3000 90');
      expect(r.ok, isTrue);
      expect(r.lengthMm, 3000);
      expect(r.angleDeg, 90);
    });

    test('empty is a no-op (not an error, not usable)', () {
      final r = parseDrawingInput('   ');
      expect(r.ok, isFalse);
      expect(r.error, isNull);
      expect(r.lengthMm, isNull);
    });

    test('non-numeric length is a friendly error', () {
      final r = parseDrawingInput('abc');
      expect(r.ok, isFalse);
      expect(r.error, isNotNull);
    });

    test('zero / negative length is rejected', () {
      expect(parseDrawingInput('0').error, isNotNull);
      expect(parseDrawingInput('-5').error, isNotNull);
    });

    test('non-numeric angle is rejected', () {
      expect(parseDrawingInput('3000 x').error, isNotNull);
    });
  });

  group('polarRunTarget', () {
    const pending = Offset(100, 100);

    test('angle 0 goes East (+x)', () {
      final t = polarRunTarget(pending, 50, angleDeg: 0);
      expect(t.dx, closeTo(150, 1e-9));
      expect(t.dy, closeTo(100, 1e-9));
    });

    test('angle 90 goes North (up = -y) since screen Y is down', () {
      final t = polarRunTarget(pending, 50, angleDeg: 90);
      expect(t.dx, closeTo(100, 1e-9));
      expect(t.dy, closeTo(50, 1e-9));
    });

    test('direct-distance entry follows the hover direction at exact length', () {
      // Hover down-right; target must be exactly 50 px along that unit vector.
      final t = polarRunTarget(pending, 50, hover: const Offset(200, 200));
      final d = (t - pending).distance;
      expect(d, closeTo(50, 1e-9));
      // 45° down-right => equal +x/+y components.
      expect(t.dx, closeTo(100 + 50 / math.sqrt2, 1e-9));
      expect(t.dy, closeTo(100 + 50 / math.sqrt2, 1e-9));
    });

    test('no hover and no angle falls back to East', () {
      final t = polarRunTarget(pending, 30);
      expect(t.dx, closeTo(130, 1e-9));
      expect(t.dy, closeTo(100, 1e-9));
    });

    test('hover coincident with pending falls back to East', () {
      final t = polarRunTarget(pending, 30, hover: pending);
      expect(t.dx, closeTo(130, 1e-9));
      expect(t.dy, closeTo(100, 1e-9));
    });
  });
}
