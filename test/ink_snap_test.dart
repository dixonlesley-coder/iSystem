/// Unit tests for the pure raster snap-to-ink engine (B12): RGBA→luminance,
/// centreline snapping on thin and thick strokes, contrast-margin rejection of a
/// grey wash, and empty-radius null.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/canvas/ink_snap.dart';

/// A `w·h` all-white (255) luminance map.
Uint8List _white(int w, int h) => Uint8List(w * h)..fillRange(0, w * h, 255);

void main() {
  group('luminanceFromRgba', () {
    test('black / white / pure red', () {
      final rgba = Uint8List.fromList([
        0, 0, 0, 255, // black
        255, 255, 255, 255, // white
        255, 0, 0, 255, // red → 0.299·255 ≈ 76
      ]);
      final lum = luminanceFromRgba(rgba, 3, 1);
      expect(lum[0], 0);
      expect(lum[1], 255);
      expect(lum[2], 76);
    });

    test('too-short buffer returns a zero map, never throws', () {
      final lum = luminanceFromRgba(Uint8List(2), 3, 1);
      expect(lum.length, 3);
      expect(lum.every((v) => v == 0), isTrue);
    });
  });

  group('findInkSnap', () {
    test('1px line snaps to its centreline', () {
      const w = 21, h = 21;
      final lum = _white(w, h);
      // A one-pixel-wide vertical line at column x=10.
      for (var y = 0; y < h; y++) {
        lum[y * w + 10] = 0;
      }
      final snap = findInkSnap(lum, w, h, 10.4, 10, 5)!;
      expect(snap.x, closeTo(10, 0.05));
      expect(snap.y, closeTo(10, 0.5));
    });

    test('thick 4px line snaps toward the stroke centre', () {
      const w = 25, h = 25;
      final lum = _white(w, h);
      // A 4-px-wide vertical band, columns 9..12.
      for (var y = 0; y < h; y++) {
        for (var x = 9; x <= 12; x++) {
          lum[y * w + x] = 0;
        }
      }
      // Cursor near the left edge of the band.
      final snap = findInkSnap(lum, w, h, 9.2, 12, 6)!;
      // Recentred across the width, off the edge column (9) toward centre (10.5).
      expect(snap.x, greaterThan(9.6));
      expect(snap.x, lessThan(11.5));
      expect(snap.y, closeTo(12, 1.0));
    });

    test('a grey fill below the contrast margin does NOT snap', () {
      const w = 21, h = 21;
      final lum = Uint8List(w * h)..fillRange(0, w * h, 200); // light-grey paper
      // A faint 5×5 patch only 20 below background — inside the margin.
      for (var y = 8; y <= 12; y++) {
        for (var x = 8; x <= 12; x++) {
          lum[y * w + x] = 180;
        }
      }
      expect(findInkSnap(lum, w, h, 10, 10, 6), isNull);
    });

    test('nothing dark within radius yields null', () {
      const w = 21, h = 21;
      final lum = _white(w, h);
      // One dark pixel far away, outside the query radius.
      lum[0] = 0;
      expect(findInkSnap(lum, w, h, 10, 10, 3), isNull);
    });

    test('explicit threshold controls darkness', () {
      const w = 11, h = 11;
      final lum = Uint8List(w * h)..fillRange(0, w * h, 200);
      for (var y = 0; y < h; y++) {
        lum[y * w + 5] = 150; // a mid-grey vertical line
      }
      // With a high threshold the mid-grey reads as ink.
      final hit = findInkSnap(lum, w, h, 5.3, 5, 4, threshold: 170);
      expect(hit, isNotNull);
      expect(hit!.x, closeTo(5, 0.5));
      // With a low threshold it does not.
      expect(findInkSnap(lum, w, h, 5.3, 5, 4, threshold: 120), isNull);
    });

    test('degenerate inputs return null, never throw', () {
      expect(findInkSnap(Uint8List(0), 0, 0, 0, 0, 5), isNull);
      expect(findInkSnap(_white(5, 5), 5, 5, 2, 2, 0), isNull);
      expect(findInkSnap(Uint8List(3), 5, 5, 2, 2, 5), isNull); // short buffer
    });
  });
}
