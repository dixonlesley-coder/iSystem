/// Unit tests for the pure DXF-underlay snap index (B12): perpendicular
/// projection, endpoint/intersection precedence, bucket-boundary correctness,
/// DXF→sheet-px mapping, and a 10k-segment query perf smoke.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/canvas/underlay_snap.dart';
import 'package:mechx_engine/geometry/dxf_drawing.dart';

void main() {
  group('UnderlaySnapIndex.query', () {
    test('exact perpendicular projection onto a segment', () {
      final idx = UnderlaySnapIndex.fromSegments(
        const [UnderlaySegment(0, 0, 100, 0)],
      );
      final c = idx.query(50, 10, 20)!;
      expect(c.kind, UnderlaySnapKind.onSegment);
      expect(c.x, closeTo(50, 1e-9));
      expect(c.y, closeTo(0, 1e-9));
      expect(c.distance, closeTo(10, 1e-9));
    });

    test('out of radius yields null', () {
      final idx = UnderlaySnapIndex.fromSegments(
        const [UnderlaySegment(0, 0, 100, 0)],
      );
      expect(idx.query(50, 40, 20), isNull);
    });

    test('endpoint beats nearest-on-segment at equal distance', () {
      // Query beyond the segment end: the clamped nearest point IS the endpoint,
      // so both candidates tie at distance 3 → endpoint wins.
      final idx = UnderlaySnapIndex.fromSegments(
        const [UnderlaySegment(0, 0, 100, 0)],
      );
      final c = idx.query(-3, 0, 20)!;
      expect(c.kind, UnderlaySnapKind.endpoint);
      expect(c.x, closeTo(0, 1e-9));
      expect(c.y, closeTo(0, 1e-9));
      expect(c.distance, closeTo(3, 1e-9));
    });

    test('corner endpoint wins when equidistant to both walls', () {
      // An L: querying from outside the corner ties both walls' clamped nearest
      // point at the shared endpoint (0,0) → endpoint.
      final idx = UnderlaySnapIndex.fromSegments(const [
        UnderlaySegment(0, 0, 100, 0),
        UnderlaySegment(0, 0, 0, 100),
      ]);
      final c = idx.query(-1, -1, 20)!;
      expect(c.kind, UnderlaySnapKind.endpoint);
      expect(c.x, closeTo(0, 1e-9));
      expect(c.y, closeTo(0, 1e-9));
    });

    test('intersection of two crossing segments', () {
      final idx = UnderlaySnapIndex.fromSegments(const [
        UnderlaySegment(0, 0, 100, 0),
        UnderlaySegment(50, -50, 50, 50),
      ]);
      final c = idx.query(50, 0, 20)!;
      expect(c.kind, UnderlaySnapKind.intersection);
      expect(c.x, closeTo(50, 1e-9));
      expect(c.y, closeTo(0, 1e-9));
      expect(c.distance, closeTo(0, 1e-9));
    });

    test('nearer wall still reads as onSegment (intersection only ties)', () {
      final idx = UnderlaySnapIndex.fromSegments(const [
        UnderlaySegment(0, 0, 100, 0),
        UnderlaySegment(50, -50, 50, 50),
      ]);
      final c = idx.query(60, 2, 20)!;
      expect(c.kind, UnderlaySnapKind.onSegment);
      expect(c.x, closeTo(60, 1e-9));
      expect(c.y, closeTo(0, 1e-9));
      expect(c.distance, closeTo(2, 1e-9));
    });

    test('a candidate carries the SOURCE wall it latched onto (for highlight)',
        () {
      final idx = UnderlaySnapIndex.fromSegments(
        const [UnderlaySegment(0, 0, 100, 0)],
      );
      final c = idx.query(50, 10, 20)!;
      expect(c.segment, isNotNull);
      expect(c.segment!.x1, 0);
      expect(c.segment!.x2, 100);
      expect(c.segment2, isNull, reason: 'a single wall snap carries one segment');
    });

    test('an intersection carries BOTH crossing walls', () {
      final idx = UnderlaySnapIndex.fromSegments(const [
        UnderlaySegment(0, 0, 100, 0),
        UnderlaySegment(50, -50, 50, 50),
      ]);
      final c = idx.query(50, 0, 20)!;
      expect(c.kind, UnderlaySnapKind.intersection);
      expect(c.segment, isNotNull);
      expect(c.segment2, isNotNull);
    });

    test('bucket-boundary: nearest point in a cell the cursor is not in', () {
      // Vertical wall at x=100; bucketSize 32 puts it in cell x=3. Cursor at
      // x=95 sits in cell x=2, but its query radius spans into cell x=3.
      final idx = UnderlaySnapIndex.fromSegments(
        const [UnderlaySegment(100, 0, 100, 300)],
        bucketSize: 32,
      );
      final c = idx.query(95, 50, 8)!;
      expect(c.kind, UnderlaySnapKind.onSegment);
      expect(c.x, closeTo(100, 1e-9));
      expect(c.y, closeTo(50, 1e-9));
      expect(c.distance, closeTo(5, 1e-9));

      // Same wall, out of range → null.
      expect(idx.query(80, 50, 8), isNull);
    });

    test('long segment crossing many buckets is reachable at its far end', () {
      final idx = UnderlaySnapIndex.fromSegments(
        const [UnderlaySegment(10, 10, 500, 10)],
        bucketSize: 32,
      );
      final c = idx.query(400, 12, 5)!;
      expect(c.kind, UnderlaySnapKind.onSegment);
      expect(c.x, closeTo(400, 1e-9));
      expect(c.y, closeTo(10, 1e-9));
    });

    test('empty index yields null', () {
      final idx = UnderlaySnapIndex.fromSegments(const []);
      expect(idx.isEmpty, isTrue);
      expect(idx.segmentCount, 0);
      expect(idx.query(0, 0, 100), isNull);
    });
  });

  group('perpendicular foot (B24, anchor supplied)', () {
    final wall = UnderlaySnapIndex.fromSegments(
      const [UnderlaySegment(0, 0, 100, 0)],
    );

    test('anchor drop surfaces a perpendicular foot at the cursor', () {
      // Anchor above the wall at x=30 ⇒ its 90° foot is (30,0). Cursor near it
      // ties the on-segment nearest point, so perpendicular (higher priority)
      // wins the label.
      final c = wall.query(30, 2, 8, anchorX: 30, anchorY: 40)!;
      expect(c.kind, UnderlaySnapKind.perpendicular);
      expect(c.x, closeTo(30, 1e-9));
      expect(c.y, closeTo(0, 1e-9));
      expect(c.distance, closeTo(2, 1e-9));
    });

    test('no anchor ⇒ the same query reads onSegment (byte-identical)', () {
      final c = wall.query(30, 2, 8)!;
      expect(c.kind, UnderlaySnapKind.onSegment);
      expect(c.x, closeTo(30, 1e-9));
      expect(c.y, closeTo(0, 1e-9));
    });

    test('cursor away from the drop stays onSegment, not perpendicular', () {
      // Foot is at (30,0) but the cursor is over x=60 → the perpendicular foot is
      // out of radius and the nearest wall point wins.
      final c = wall.query(60, 2, 8, anchorX: 30, anchorY: 40)!;
      expect(c.kind, UnderlaySnapKind.onSegment);
      expect(c.x, closeTo(60, 1e-9));
    });

    test('foot outside the wall interior is not offered (t clamped)', () {
      // Anchor projects to t<0 (left of the wall) ⇒ no true perpendicular foot;
      // the near-corner query resolves to the endpoint, never perpendicular.
      final c = wall.query(2, 2, 8, anchorX: -20, anchorY: 40)!;
      expect(c.kind, isNot(UnderlaySnapKind.perpendicular));
      expect(c.kind, UnderlaySnapKind.onSegment);
    });
  });

  group('UnderlaySnapIndex.fromDrawing', () {
    // A closed 100×50 rectangle wall loop, world coords Y-up.
    final drawing = const DxfDrawing(
      polylines: [
        DxfPolyline([
          DxfPoint(0, 0),
          DxfPoint(100, 0),
          DxfPoint(100, 50),
          DxfPoint(0, 50),
        ], closed: true),
      ],
      circles: [],
      arcs: [],
      bounds: DxfBounds(0, 0, 100, 50),
    );

    test('maps world → sheet-px and snaps to a mapped wall', () {
      // scale = 200/100 = 2; Y flips (maxY − wy)·2. Bottom wall (world y=0) maps
      // to sheet y=100, spanning (0,100)→(200,100).
      final t = UnderlayTransform.forSheet(drawing.bounds, 200, 100);
      final idx = UnderlaySnapIndex.fromDrawing(drawing, transform: t);
      expect(idx.isEmpty, isFalse);

      final c = idx.query(100, 95, 10)!;
      expect(c.kind, UnderlaySnapKind.onSegment);
      expect(c.x, closeTo(100, 1e-6));
      expect(c.y, closeTo(100, 1e-6));
      expect(c.distance, closeTo(5, 1e-6));
    });

    test('snaps to a mapped corner endpoint', () {
      final t = UnderlayTransform.forSheet(drawing.bounds, 200, 100);
      final idx = UnderlaySnapIndex.fromDrawing(drawing, transform: t);
      // World corner (0,0) → sheet (0,100). Query outside it.
      final c = idx.query(-3, 100, 10)!;
      expect(c.kind, UnderlaySnapKind.endpoint);
      expect(c.x, closeTo(0, 1e-6));
      expect(c.y, closeTo(100, 1e-6));
    });

    test('flattens a circle to chords that snap', () {
      final circleDrawing = const DxfDrawing(
        polylines: [],
        circles: [DxfCircle(DxfPoint(0, 0), 50)],
        arcs: [],
        bounds: DxfBounds(-50, -50, 50, 50),
      );
      // scale = 100/100 = 1; centre maps to sheet (50,50). A point on the +X
      // rim (world (50,0)) maps to sheet (100,50).
      final t = UnderlayTransform.forSheet(circleDrawing.bounds, 100, 100);
      final idx = UnderlaySnapIndex.fromDrawing(circleDrawing, transform: t);
      final c = idx.query(103, 50, 8)!;
      // On (or very near) the rim chord at sheet x≈100.
      expect(c.x, closeTo(100, 1.0));
      expect(c.y, closeTo(50, 1.0));
    });
  });

  group('perf', () {
    test('10k segments: < 5 ms per query', () {
      final rng = math.Random(42);
      final segs = <UnderlaySegment>[];
      for (var i = 0; i < 10000; i++) {
        final x = rng.nextDouble() * 2000;
        final y = rng.nextDouble() * 2000;
        // Short wall-like segments (up to ~60 px).
        final dx = (rng.nextDouble() - 0.5) * 60;
        final dy = (rng.nextDouble() - 0.5) * 60;
        segs.add(UnderlaySegment(x, y, x + dx, y + dy));
      }
      final idx = UnderlaySnapIndex.fromSegments(segs);
      expect(idx.segmentCount, greaterThan(9000));

      // Warm-up.
      for (var i = 0; i < 50; i++) {
        idx.query(rng.nextDouble() * 2000, rng.nextDouble() * 2000, 14);
      }

      const n = 400;
      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        idx.query(rng.nextDouble() * 2000, rng.nextDouble() * 2000, 14);
      }
      sw.stop();
      final perQueryMs = sw.elapsedMicroseconds / n / 1000.0;
      expect(perQueryMs, lessThan(5.0),
          reason: 'avg ${perQueryMs.toStringAsFixed(3)} ms/query');
    });
  });
}
