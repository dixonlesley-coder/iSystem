/// Round 33 seed suite (2026-10-18) — DXF import robustness:
///   * import-robustness-2-1 — the HEADER `$INSUNITS` code is read.
///   * import-robustness-2-2 — an ARC grows the bounds by its EXACT extent
///     (seeded property against a dense sampling of the arc).
///   * import-robustness-2-3 — frozen / off layers are neither drawn nor in
///     the extents (block contents on layer '0' inherit the INSERT's).
///   * import-robustness-2-5 — a file cut inside ENTITIES is `incomplete`.
///   * import-robustness-2-7 — a BLOCKS-only file is not a plan.
///   * import-robustness-2-8 — CR-only line ends tokenise; a binary DXF is
///     recognised.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/dxf_drawing.dart';
import 'package:test/test.dart';

String _line(double x1, double y1, double x2, double y2, {String layer = '0'}) =>
    '0\nLINE\n8\n$layer\n10\n$x1\n20\n$y1\n11\n$x2\n21\n$y2\n';

/// A 40000 x 20000 rectangle (mm).
String get _plan =>
    _line(0, 0, 40000, 0) +
    _line(40000, 0, 40000, 20000) +
    _line(40000, 20000, 0, 20000) +
    _line(0, 20000, 0, 0);

String _doc(String entities,
    {String header = '', String tables = '', String blocks = ''}) {
  final b = StringBuffer();
  if (header.isNotEmpty) b.write('0\nSECTION\n2\nHEADER\n${header}0\nENDSEC\n');
  if (tables.isNotEmpty) b.write('0\nSECTION\n2\nTABLES\n${tables}0\nENDSEC\n');
  if (blocks.isNotEmpty) b.write('0\nSECTION\n2\nBLOCKS\n${blocks}0\nENDSEC\n');
  b.write('0\nSECTION\n2\nENTITIES\n$entities');
  b.write('0\nENDSEC\n0\nEOF\n');
  return b.toString();
}

void main() {
  test(r'$INSUNITS is read from the HEADER', () {
    final mm = parseDxf(_doc(_plan, header: '9\n\$INSUNITS\n70\n4\n'))!;
    expect(mm.insUnits, 4);
    expect(dxfUnitMetres(4), 0.001);
    final m = parseDxf(_doc(_plan, header: '9\n\$INSUNITS\n70\n6\n'))!;
    expect(m.insUnits, 6);
    expect(dxfUnitMetres(6), 1.0);
    expect(dxfUnitMetres(1), 0.0254);
    expect(dxfUnitMetres(0), isNull);
    expect(parseDxf(_doc(_plan))!.insUnits, 0);
  });

  group('arc extent', () {
    test('a large-radius facade arc grows the bounds by its true extent', () {
      // Centre (20000, -80000), r 100000, 78 -> 102 deg. Endpoints at
      // x = 20000 ± 100000·cos 78° = 20000 ± 20791.17; the sweep passes 90°,
      // so the apex y = -80000 + 100000 = 20000. The full-circle box used to
      // make the bounds 200000 x 200000 (the plan ~2 % of the sheet area).
      final d = parseDxf(_doc(
          '${_plan}0\nARC\n8\n0\n10\n20000\n20\n-80000\n40\n100000\n50\n78\n51\n102\n'))!;
      final dx = 100000 * math.cos(78 * math.pi / 180);
      expect(d.bounds.minX, closeTo(20000 - dx, 1e-6));
      expect(d.bounds.maxX, closeTo(20000 + dx, 1e-6));
      expect(d.bounds.minY, 0);
      expect(d.bounds.maxY, closeTo(20000, 1e-6));
    });

    test('seeded property: dxfArcExtent == the sampled arc extent', () {
      final rnd = math.Random(33);
      for (var i = 0; i < 2000; i++) {
        final s = rnd.nextDouble() * 720 - 360;
        final sweep = rnd.nextDouble() * 400;
        final a = DxfArc(
            DxfPoint(rnd.nextDouble() * 100, rnd.nextDouble() * 100),
            1 + rnd.nextDouble() * 50,
            s,
            s + sweep);
        final ext = dxfArcExtent(a);
        // Sample densely along the CCW sweep (capped at one turn).
        final sw = math.min(sweep, 360.0);
        var minX = double.infinity, maxX = -double.infinity;
        var minY = double.infinity, maxY = -double.infinity;
        const n = 4000;
        for (var k = 0; k <= n; k++) {
          final t = (s + sw * k / n) * math.pi / 180;
          final x = a.center.x + a.radius * math.cos(t);
          final y = a.center.y + a.radius * math.sin(t);
          minX = math.min(minX, x);
          maxX = math.max(maxX, x);
          minY = math.min(minY, y);
          maxY = math.max(maxY, y);
        }
        // Exact extent ⊇ samples, and within the sampling error.
        final tol = a.radius * (1 - math.cos(math.pi / n)) + 1e-9;
        expect(ext.minX, lessThanOrEqualTo(minX + 1e-9), reason: '$i');
        expect(ext.maxX, greaterThanOrEqualTo(maxX - 1e-9), reason: '$i');
        expect(ext.minY, lessThanOrEqualTo(minY + 1e-9), reason: '$i');
        expect(ext.maxY, greaterThanOrEqualTo(maxY - 1e-9), reason: '$i');
        expect(minX - ext.minX, lessThanOrEqualTo(tol + 1e-6), reason: '$i');
        expect(ext.maxX - maxX, lessThanOrEqualTo(tol + 1e-6), reason: '$i');
        expect(minY - ext.minY, lessThanOrEqualTo(tol + 1e-6), reason: '$i');
        expect(ext.maxY - maxY, lessThanOrEqualTo(tol + 1e-6), reason: '$i');
      }
    });
  });

  group('frozen / off layers', () {
    const tables = '0\nTABLE\n2\nLAYER\n'
        '0\nLAYER\n2\n0\n70\n0\n62\n7\n'
        '0\nLAYER\n2\nOLD\n70\n1\n62\n-7\n'
        '0\nLAYER\n2\nOFF\n70\n0\n62\n-3\n'
        '0\nLAYER\n2\nWALL\n70\n0\n62\n1\n'
        '0\nENDTAB\n';

    test('a stray line on a frozen layer does not grow the bounds', () {
      final d = parseDxf(_doc(
          _plan + _line(9e6, 9e6, 9e6 + 10, 9e6, layer: 'OLD'),
          tables: tables))!;
      expect(d.bounds.maxX, 40000);
      expect(d.bounds.maxY, 20000);
      expect(d.polylines, hasLength(4));
    });

    test('an OFF layer (negative colour) is hidden; a named visible one is not',
        () {
      final d = parseDxf(_doc(
          _plan +
              _line(-5e6, 0, -5e6 + 1, 0, layer: 'OFF') +
              _line(0, 0, 100, 100, layer: 'WALL'),
          tables: tables))!;
      expect(d.bounds.minX, 0);
      expect(d.polylines, hasLength(5));
    });

    test("block contents on '0' inherit the INSERT's layer", () {
      const blocks = '0\nBLOCK\n2\nDOOR\n10\n0\n20\n0\n'
          '0\nLINE\n8\n0\n10\n0\n20\n0\n11\n900\n21\n0\n'
          '0\nLINE\n8\nOLD\n10\n0\n20\n0\n11\n0\n21\n9e6\n'
          '0\nENDBLK\n';
      final d = parseDxf(_doc(
          '${_plan}0\nINSERT\n8\nWALL\n2\nDOOR\n10\n100\n20\n100\n'
          '0\nINSERT\n8\nOLD\n2\nDOOR\n10\n5e6\n20\n5e6\n',
          tables: tables,
          blocks: blocks))!;
      // The visible INSERT draws its layer-0 line; its OLD-layer line and the
      // whole frozen INSERT are hidden.
      expect(d.polylines, hasLength(5));
      expect(d.bounds.maxX, 40000);
      expect(d.bounds.maxY, 20000);
    });
  });

  test('a file cut inside ENTITIES is incomplete; a whole one is not', () {
    final whole = _doc(_plan);
    expect(parseDxf(whole)!.incomplete, isFalse);
    final cut = whole.substring(0, whole.indexOf('0\nENDSEC\n0\nEOF'));
    final d = parseDxf(cut)!;
    expect(d.incomplete, isTrue);
    expect(d.truncated, isFalse);
  });

  test('a BLOCKS-only symbol library is not a plan', () {
    const lib = '0\nSECTION\n2\nBLOCKS\n'
        '0\nBLOCK\n2\nDOOR\n10\n0\n20\n0\n'
        '0\nLINE\n8\n0\n10\n0\n20\n0\n11\n900\n21\n0\n'
        '0\nENDBLK\n0\nENDSEC\n0\nEOF\n';
    expect(parseDxf(lib), isNull);
    // An unwrapped entity stream (no sections at all) still parses.
    expect(parseDxf(_plan), isNotNull);
  });

  test('CR-only line ends tokenise; a binary DXF is recognised', () {
    final cr = _doc(_plan).replaceAll('\n', '\r');
    final d = parseDxf(cr)!;
    expect(d.polylines, hasLength(4));
    expect(d.bounds.maxX, 40000);
    expect(isBinaryDxf('AutoCAD Binary DXF\r\n\x1a\x00...'), isTrue);
    expect(isBinaryDxf(_doc(_plan)), isFalse);
  });
}
