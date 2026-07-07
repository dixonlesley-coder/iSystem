import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/canvas/snapping.dart';

void main() {
  const from = Offset.zero;

  test('near-horizontal snaps to horizontal (dy ≈ 0)', () {
    final r = orthoSnap(from, const Offset(100, 8));
    expect(r.dy, closeTo(0, 1e-9));
    expect(r.dx, greaterThan(0));
  });

  test('near-vertical snaps to vertical (dx ≈ 0)', () {
    final r = orthoSnap(from, const Offset(8, 100));
    expect(r.dx, closeTo(0, 1e-9));
    expect(r.dy, greaterThan(0));
  });

  test('near-diagonal snaps to 45° (|dx| ≈ |dy|)', () {
    final r = orthoSnap(from, const Offset(100, 90));
    expect(r.dx.abs(), closeTo(r.dy.abs(), 1e-9));
  });

  test('length is preserved', () {
    final r = orthoSnap(from, const Offset(100, 12));
    expect(r.distance, closeTo(const Offset(100, 12).distance, 1e-9));
  });

  test('zero-length segment is returned unchanged', () {
    expect(orthoSnap(const Offset(5, 5), const Offset(5, 5)),
        const Offset(5, 5));
  });

  group('nearestAlignment (B23)', () {
    test('vertical guide: shares a node x, keeps probe y', () {
      final g = nearestAlignment(
          const [Offset(100, 10)], const Offset(103, 200), 14)!;
      expect(g.horizontal, isFalse);
      expect(g.point, const Offset(100, 200));
      expect(g.node, const Offset(100, 10));
      expect(g.delta, closeTo(3, 1e-9));
      expect(g.kind, SnapKind.align);
    });

    test('horizontal guide: shares a node y, keeps probe x', () {
      final g = nearestAlignment(
          const [Offset(10, 100)], const Offset(200, 103), 14)!;
      expect(g.horizontal, isTrue);
      expect(g.point, const Offset(200, 100));
      expect(g.node, const Offset(10, 100));
      expect(g.delta, closeTo(3, 1e-9));
    });

    test('nearest-axis-first: nearer y wins over farther x', () {
      // Node A within 5 on x; node B within 3 on y → the horizontal guide wins.
      final g = nearestAlignment(
          const [Offset(100, 10), Offset(10, 100)], const Offset(105, 103), 14)!;
      expect(g.horizontal, isTrue);
      expect(g.node, const Offset(10, 100));
      expect(g.point, const Offset(105, 100));
    });

    test('tie between axes prefers the vertical guide', () {
      final g = nearestAlignment(
          const [Offset(100, 10), Offset(10, 100)], const Offset(104, 104), 14)!;
      expect(g.horizontal, isFalse);
      expect(g.point, const Offset(100, 104));
    });

    test('out of tolerance on both axes ⇒ null', () {
      expect(
          nearestAlignment(const [Offset(100, 10)], const Offset(120, 200), 14),
          isNull);
    });

    test('empty nodes / non-positive tolerance ⇒ null', () {
      expect(nearestAlignment(const [], const Offset(0, 0), 14), isNull);
      expect(nearestAlignment(const [Offset(0, 0)], const Offset(0, 0), 0),
          isNull);
    });
  });

  group('nearestRunMidpoint (B24)', () {
    test('snaps to the midpoint of a run within radius', () {
      final m = nearestRunMidpoint(
          const [(Offset(0, 0), Offset(100, 0))], const Offset(52, 3), 14)!;
      expect(m.point, const Offset(50, 0));
      expect(m.distance, closeTo(math.sqrt(13), 1e-9));
      expect(m.kind, SnapKind.midpoint);
    });

    test('picks the nearest midpoint among several runs', () {
      final m = nearestRunMidpoint(const [
        (Offset(0, 0), Offset(100, 0)), // mid (50,0)
        (Offset(0, 0), Offset(0, 100)), // mid (0,50)
      ], const Offset(49, 2), 14)!;
      expect(m.point, const Offset(50, 0));
    });

    test('degenerate run is skipped', () {
      expect(
          nearestRunMidpoint(
              const [(Offset(10, 10), Offset(10, 10))], const Offset(10, 10), 5),
          isNull);
    });

    test('out of radius ⇒ null', () {
      expect(
          nearestRunMidpoint(
              const [(Offset(0, 0), Offset(100, 0))], const Offset(50, 40), 14),
          isNull);
    });
  });

  group('parallelTrackProjection (B25)', () {
    test('projects onto the parallel on the probe side (+)', () {
      final t = parallelTrackProjection(
          const Offset(0, 0), const Offset(100, 0), 10, const Offset(50, 3))!;
      expect(t.point, const Offset(50, 10));
      expect(t.base, const Offset(0, 10));
      expect(t.side, 1);
    });

    test('flips to the other side for a probe on the far side (−)', () {
      final t = parallelTrackProjection(
          const Offset(0, 0), const Offset(100, 0), 10, const Offset(50, -3))!;
      expect(t.point, const Offset(50, -10));
      expect(t.side, -1);
    });

    test('diagonal segment: exact projection onto the offset parallel', () {
      final s = math.sqrt(2);
      final t = parallelTrackProjection(
          const Offset(0, 0), const Offset(10, 10), s, const Offset(-1, 1))!;
      expect(t.point.dx, closeTo(-1, 1e-9));
      expect(t.point.dy, closeTo(1, 1e-9));
      // The locked point sits exactly `offset` from the segment's line.
      // Line through origin dir (1,1)/√2, normal (-1,1)/√2: |(-1)(-1)+(1)(1)|/√2 = √2.
      final dist = ((-t.point.dx) + t.point.dy).abs() / s;
      expect(dist, closeTo(s, 1e-9));
    });

    test('degenerate segment ⇒ null', () {
      expect(
          parallelTrackProjection(
              const Offset(5, 5), const Offset(5, 5), 10, const Offset(0, 0)),
          isNull);
    });
  });
}
