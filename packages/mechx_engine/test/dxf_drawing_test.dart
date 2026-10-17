import 'package:mechx_engine/geometry/dxf_drawing.dart';
import 'package:test/test.dart';

/// Build a minimal DXF wrapping [entities] (already a code/value text block) in
/// an ENTITIES section.
String _doc(String entities, {String blocks = ''}) {
  final b = StringBuffer();
  if (blocks.isNotEmpty) {
    b.writeln('0\nSECTION\n2\nBLOCKS');
    b.write(blocks);
    b.writeln('0\nENDSEC');
  }
  b.writeln('0\nSECTION\n2\nENTITIES');
  b.write(entities);
  b.writeln('0\nENDSEC\n0\nEOF');
  return b.toString();
}

void main() {
  group('parseDxf — primitives', () {
    test('a single LINE becomes a 2-point polyline + correct bounds', () {
      final d = parseDxf(_doc('0\nLINE\n8\n0\n10\n0\n20\n0\n11\n100\n21\n50\n'));
      expect(d, isNotNull);
      expect(d!.polylines, hasLength(1));
      final p = d.polylines.single;
      expect(p.points.first.x, 0);
      expect(p.points.first.y, 0);
      expect(p.points.last.x, 100);
      expect(p.points.last.y, 50);
      expect(d.bounds.minX, 0);
      expect(d.bounds.maxX, 100);
      expect(d.bounds.maxY, 50);
      expect(d.bounds.width, 100);
      expect(d.bounds.height, 50);
    });

    test('LWPOLYLINE reads all vertices + the closed flag', () {
      final d = parseDxf(_doc(
        '0\nLWPOLYLINE\n8\n0\n90\n3\n70\n1\n'
        '10\n0\n20\n0\n10\n10\n20\n0\n10\n10\n20\n10\n',
      ));
      expect(d!.polylines, hasLength(1));
      final p = d.polylines.single;
      expect(p.points, hasLength(3));
      expect(p.closed, isTrue);
      expect(d.bounds.maxX, 10);
      expect(d.bounds.maxY, 10);
    });

    test('old-style POLYLINE/VERTEX run is read until SEQEND', () {
      final d = parseDxf(_doc(
        '0\nPOLYLINE\n8\n0\n70\n0\n'
        '0\nVERTEX\n10\n0\n20\n0\n'
        '0\nVERTEX\n10\n20\n20\n0\n'
        '0\nVERTEX\n10\n20\n20\n20\n'
        '0\nSEQEND\n',
      ));
      expect(d!.polylines, hasLength(1));
      expect(d.polylines.single.points, hasLength(3));
      expect(d.polylines.single.closed, isFalse);
      expect(d.bounds.maxX, 20);
    });

    test('CIRCLE + ARC are kept as primitives with their bounds', () {
      final d = parseDxf(_doc(
        '0\nCIRCLE\n10\n50\n20\n50\n40\n10\n'
        '0\nARC\n10\n0\n20\n0\n40\n5\n50\n0\n51\n90\n',
      ));
      expect(d!.circles, hasLength(1));
      expect(d.arcs, hasLength(1));
      expect(d.circles.single.radius, 10);
      expect(d.arcs.single.startDeg, 0);
      expect(d.arcs.single.endDeg, 90);
      // circle spans 40..60, arc spans -5..5 → overall -5..60.
      expect(d.bounds.minX, -5);
      expect(d.bounds.maxX, 60);
    });
  });

  group('parseDxf — INSERT / BLOCKS', () {
    test('INSERT translates a block to its insertion point', () {
      // Block "win": a unit square at the origin (base 0,0).
      const block = '0\nBLOCK\n2\nwin\n10\n0\n20\n0\n'
          '0\nLINE\n10\n0\n20\n0\n11\n1\n21\n0\n'
          '0\nENDBLK\n';
      final d = parseDxf(_doc(
        '0\nINSERT\n2\nwin\n10\n100\n20\n200\n',
        blocks: block,
      ));
      expect(d, isNotNull);
      final p = d!.polylines.single;
      // (0,0)->(1,0) shifted by the insert point (100,200).
      expect(p.points.first.x, 100);
      expect(p.points.first.y, 200);
      expect(p.points.last.x, 101);
      expect(p.points.last.y, 200);
    });

    test('INSERT scale + rotation transform the block geometry', () {
      const block = '0\nBLOCK\n2\nbar\n10\n0\n20\n0\n'
          '0\nLINE\n10\n0\n20\n0\n11\n1\n21\n0\n'
          '0\nENDBLK\n';
      // Scale ×2, rotate 90°: the unit X segment becomes a length-2 +Y segment.
      final d = parseDxf(_doc(
        '0\nINSERT\n2\nbar\n10\n0\n20\n0\n41\n2\n42\n2\n50\n90\n',
        blocks: block,
      ));
      final p = d!.polylines.single;
      expect(p.points.first.x, closeTo(0, 1e-9));
      expect(p.points.first.y, closeTo(0, 1e-9));
      expect(p.points.last.x, closeTo(0, 1e-9));
      expect(p.points.last.y, closeTo(2, 1e-9));
    });

    test('a missing block reference is skipped, not fatal', () {
      final d = parseDxf(_doc(
        '0\nLINE\n10\n0\n20\n0\n11\n5\n21\n0\n'
        '0\nINSERT\n2\nnope\n10\n0\n20\n0\n',
      ));
      expect(d!.polylines, hasLength(1)); // only the real LINE
    });
  });

  group('parseDxf — robustness', () {
    test('an entity-less document returns null (no drawable geometry)', () {
      expect(parseDxf(_doc('')), isNull);
      expect(parseDxf(''), isNull);
      expect(parseDxf('garbage\nnot a dxf\n'), isNull);
    });

    test('CRLF line endings parse the same as LF', () {
      final lf = _doc('0\nLINE\n10\n0\n20\n0\n11\n10\n21\n0\n');
      final crlf = lf.replaceAll('\n', '\r\n');
      final d = parseDxf(crlf);
      expect(d, isNotNull);
      expect(d!.polylines.single.points.last.x, 10);
    });

    test('unrecognised entities (TEXT) are skipped without dropping LINEs', () {
      final d = parseDxf(_doc(
        '0\nTEXT\n10\n0\n20\n0\n40\n2.5\n1\nhello\n'
        '0\nLINE\n10\n0\n20\n0\n11\n3\n21\n4\n',
      ));
      expect(d!.polylines, hasLength(1));
      expect(d.bounds.maxX, 3);
      expect(d.bounds.maxY, 4);
    });
  });

  // Normalise an angle into [0, 360) for quadrant comparisons.
  double norm(double deg) => ((deg % 360) + 360) % 360;

  group('parseDxf — mirrored INSERT arcs', () {
    // Block DOOR: a quarter swing in the upper-right quadrant, 0 -> 90 CCW.
    const door = '0\nBLOCK\n2\nDOOR\n10\n0\n20\n0\n'
        '0\nARC\n10\n0\n20\n0\n40\n1\n50\n0\n51\n90\n'
        '0\nENDBLK\n';

    test('41=-1 mirrors the swing into the upper-LEFT quadrant (90 -> 180)', () {
      // Mirror about the Y axis maps the start point (1,0) to (-1,0) at 180°
      // and the end point (0,1) to itself at 90°; a mirror reverses the sweep,
      // so the CCW arc runs 90 -> 180 (start = 180-90, end = 180-0).
      final d = parseDxf(_doc(
        '0\nINSERT\n2\nDOOR\n10\n0\n20\n0\n41\n-1\n42\n1\n',
        blocks: door,
      ));
      final a = d!.arcs.single;
      expect(norm(a.startDeg), closeTo(90, 1e-9));
      expect(norm(a.endDeg), closeTo(180, 1e-9));
      expect(a.radius, closeTo(1, 1e-12));
    });

    test('a plain 50=90 rotation still yields 90 -> 180', () {
      final d = parseDxf(_doc(
        '0\nINSERT\n2\nDOOR\n10\n0\n20\n0\n50\n90\n',
        blocks: door,
      ));
      final a = d!.arcs.single;
      expect(norm(a.startDeg), closeTo(90, 1e-9));
      expect(norm(a.endDeg), closeTo(180, 1e-9));
    });
  });

  group('parseDxf — OCS extrusion (230 = -1)', () {
    test('a flipped ARC lands at mirrored X with the mirrored sweep', () {
      // OCS (0,0,-1): world X = -OCS X. Centre (5,0) -> (-5,0); the OCS arc
      // 0 -> 90 maps to 180 -> 90 and, reversed to stay CCW, 90 -> 180.
      final d = parseDxf(_doc(
        '0\nARC\n10\n5\n20\n0\n40\n1\n210\n0\n220\n0\n230\n-1\n50\n0\n51\n90\n',
      ));
      final a = d!.arcs.single;
      expect(a.center.x, closeTo(-5, 1e-12));
      expect(a.center.y, closeTo(0, 1e-12));
      expect(norm(a.startDeg), closeTo(90, 1e-9));
      expect(norm(a.endDeg), closeTo(180, 1e-9));
    });

    test('a flipped CIRCLE centre is X-negated', () {
      final d = parseDxf(_doc('0\nCIRCLE\n10\n7\n20\n3\n40\n2\n230\n-1\n'));
      expect(d!.circles.single.center.x, closeTo(-7, 1e-12));
      expect(d.circles.single.center.y, closeTo(3, 1e-12));
    });

    test('a flipped LWPOLYLINE has x-negated points + matching bounds', () {
      final d = parseDxf(_doc(
        '0\nLWPOLYLINE\n90\n2\n70\n0\n230\n-1\n'
        '10\n10\n20\n0\n10\n30\n20\n5\n',
      ));
      final p = d!.polylines.single;
      expect(p.points.first.x, -10);
      expect(p.points.last.x, -30);
      expect(p.points.last.y, 5);
      expect(d.bounds.minX, -30);
      expect(d.bounds.maxX, -10);
    });

    test('a default (0,0,1) extrusion is unchanged', () {
      final d = parseDxf(_doc('0\nCIRCLE\n10\n7\n20\n3\n40\n2\n230\n1\n'));
      expect(d!.circles.single.center.x, 7);
    });
  });

  group('parseDxf — paper space (67 = 1)', () {
    test('a paper-space LINE is dropped; bounds are model space only', () {
      final d = parseDxf(_doc(
        '0\nLINE\n10\n700000\n20\n9200000\n11\n750000\n21\n9230000\n'
        '0\nLINE\n67\n1\n10\n0\n20\n0\n11\n420\n21\n297\n',
      ));
      expect(d!.polylines, hasLength(1));
      expect(d.bounds.minX, 700000);
      expect(d.bounds.minY, 9200000);
      expect(d.bounds.maxX, 750000);
      expect(d.bounds.maxY, 9230000);
    });

    const box = '0\nBLOCK\n2\nbox\n10\n0\n20\n0\n'
        '0\nLINE\n67\n1\n10\n0\n20\n0\n11\n1\n21\n0\n'
        '0\nENDBLK\n';

    test('a paper-space INSERT emits nothing', () {
      final d = parseDxf(_doc(
        '0\nLINE\n10\n0\n20\n0\n11\n5\n21\n0\n'
        '0\nINSERT\n67\n1\n2\nbox\n10\n100\n20\n100\n',
        blocks: box,
      ));
      expect(d!.polylines, hasLength(1));
      expect(d.bounds.maxX, 5);
    });

    test('a 67=1 entity INSIDE a model-space INSERT is still drawn', () {
      final d = parseDxf(_doc(
        '0\nINSERT\n2\nbox\n10\n100\n20\n100\n',
        blocks: box,
      ));
      expect(d!.polylines, hasLength(1));
      expect(d.polylines.single.points.first.x, 100);
    });
  });

  group('parseDxf — runaway INSERT nesting', () {
    test('a self-inserting block parses fast and keeps its own geometry', () {
      final self = StringBuffer('0\nBLOCK\n2\nB\n10\n0\n20\n0\n'
          '0\nLINE\n10\n0\n20\n0\n11\n1\n21\n0\n');
      for (var i = 0; i < 20; i++) {
        self.write('0\nINSERT\n2\nB\n10\n0\n20\n0\n');
      }
      self.write('0\nENDBLK\n');
      final sw = Stopwatch()..start();
      final d = parseDxf(_doc(
        '0\nINSERT\n2\nB\n10\n0\n20\n0\n',
        blocks: self.toString(),
      ));
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(100));
      // The cycle is broken at the first re-entry: B's own LINE, once.
      expect(d!.polylines, hasLength(1));
    });

    test('a geometry-free non-cyclic fan-out is bounded by the INSERT budget',
        () {
      // A inserts B ×1000, B inserts C ×1000, C holds one LINE: 1e6 instances
      // would be emitted unbounded; the 100k INSERT budget caps the work.
      String fan(String name, String child, int n) {
        final b = StringBuffer('0\nBLOCK\n2\n$name\n10\n0\n20\n0\n');
        for (var i = 0; i < n; i++) {
          b.write('0\nINSERT\n2\n$child\n10\n$i\n20\n0\n');
        }
        b.write('0\nENDBLK\n');
        return b.toString();
      }

      final blocks = fan('A', 'B', 1000) +
          fan('B', 'C', 1000) +
          '0\nBLOCK\n2\nC\n10\n0\n20\n0\n'
              '0\nLINE\n10\n0\n20\n0\n11\n1\n21\n0\n0\nENDBLK\n';
      final sw = Stopwatch()..start();
      final d = parseDxf(_doc('0\nINSERT\n2\nA\n10\n0\n20\n0\n',
          blocks: blocks));
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(10000));
      // Depth-first: A (1), then each B is followed by its 1000 C's — 1001
      // instances per B group. 99999 left after A = 99 full groups (99099)
      // + 900 more (the 100th B and 899 of its C's). One LINE per C:
      // 99·1000 + 899 = 99899.
      expect(d!.polylines.length, 99 * 1000 + 899);
    });
  });

  group('parseDxf — INSERT arrays (70/71/44/45)', () {
    const dot = '0\nBLOCK\n2\ndot\n10\n0\n20\n0\n'
        '0\nCIRCLE\n10\n0\n20\n0\n40\n1\n'
        '0\nENDBLK\n';

    test('a 3 x 4 array yields 12 circles at the grid centres', () {
      final d = parseDxf(_doc(
        '0\nINSERT\n2\ndot\n10\n5\n20\n7\n70\n3\n71\n4\n44\n10\n45\n10\n',
        blocks: dot,
      ));
      expect(d!.circles, hasLength(12));
      final centres = {
        for (final c in d.circles) '${c.center.x},${c.center.y}',
      };
      for (var r = 0; r < 4; r++) {
        for (var c = 0; c < 3; c++) {
          expect(centres, contains('${5.0 + 10 * c},${7.0 + 10 * r}'));
        }
      }
      expect(d.bounds.minX, 4);
      expect(d.bounds.maxX, 26); // 5 + 20 + 1
      expect(d.bounds.maxY, 38); // 7 + 30 + 1
    });

    test('array spacing follows the INSERT rotation', () {
      // 50=90: the column axis is world +Y, so column 1 sits at (0, 10).
      final d = parseDxf(_doc(
        '0\nINSERT\n2\ndot\n10\n0\n20\n0\n50\n90\n70\n2\n44\n10\n',
        blocks: dot,
      ));
      expect(d!.circles, hasLength(2));
      final second = d.circles[1].center;
      expect(second.x, closeTo(0, 1e-9));
      expect(second.y, closeTo(10, 1e-9));
    });

    test('a plain INSERT (no 70/71) is a single instance', () {
      final d = parseDxf(_doc(
        '0\nINSERT\n2\ndot\n10\n5\n20\n7\n',
        blocks: dot,
      ));
      expect(d!.circles, hasLength(1));
      expect(d.circles.single.center.x, 5);
      expect(d.circles.single.center.y, 7);
    });
  });
}
