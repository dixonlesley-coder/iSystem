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
}
