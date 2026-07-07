import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/reference_line_store.dart';
import 'package:mechx/ui/canvas/dxf_sheet_page.dart';
import 'package:mechx/ui/canvas/snapping.dart';
import 'package:mechx/ui/canvas/underlay_snap_service.dart';
import 'package:mechx_engine/geometry/dxf_drawing.dart';

/// A DXF drawing in a 0..100 world box with ONE horizontal wall at world y=80
/// (from x=20 to x=80). With sizePx 100×100 the transform is scale 1, sy=100-wy,
/// so the wall's left endpoint (20,80) lands at sheet-px (20,20).
DxfDrawing _wallDrawing() => const DxfDrawing(
      polylines: [
        DxfPolyline([DxfPoint(20, 80), DxfPoint(80, 80)]),
      ],
      circles: [],
      arcs: [],
      bounds: DxfBounds(0, 0, 100, 100),
    );

/// A 100×100 white luminance map with a dark vertical stripe at sheet-x≈20.
Uint8List _stripeAt(int col, int w, int h) {
  final lum = Uint8List(w * h)..fillRange(0, w * h, 255);
  for (var y = 0; y < h; y++) {
    for (var dx = -1; dx <= 1; dx++) {
      final x = col + dx;
      if (x >= 0 && x < w) lum[y * w + x] = 0;
    }
  }
  return lum;
}

void main() {
  group('UnderlaySnapService.snap', () {
    const pdfSheet = Sheet(
        id: 'pdf1', name: 'p', pdfPath: '/x.pdf', sizePx: Size(100, 100));
    const dxfSheet = Sheet(
        id: 'dxf1', name: 'd', dxfPath: '/wall.dxf', sizePx: Size(100, 100));

    test('toggle gating: enabled=false ⇒ no snap even with a line in range', () {
      final svc = UnderlaySnapService();
      final lines = [
        const ReferenceLine(
            id: 'r1', sheetId: 'pdf1', x1: 10, y1: 20, x2: 30, y2: 20),
      ];
      expect(
        svc.snap(pdfSheet, lines, const Offset(20, 22), 8, enabled: false),
        isNull,
      );
      final hit =
          svc.snap(pdfSheet, lines, const Offset(20, 22), 8, enabled: true);
      expect(hit, isNotNull);
      expect(hit!.source, UnderlaySource.referenceLine);
    });

    test('ink LOSES to a reference line (both in range)', () {
      final svc = UnderlaySnapService();
      // Ink stripe at sheet-x=20; reference line horizontal at y=20.
      svc.primeInkForTest('pdf1', _stripeAt(20, 100, 100), 100, 100, 1.0);
      final lines = [
        const ReferenceLine(
            id: 'r1', sheetId: 'pdf1', x1: 10, y1: 20, x2: 30, y2: 20),
      ];
      final hit =
          svc.snap(pdfSheet, lines, const Offset(20, 22), 8, enabled: true);
      expect(hit, isNotNull);
      // Reference line is checked before ink ⇒ it wins.
      expect(hit!.source, UnderlaySource.referenceLine);
    });

    test('ink alone snaps when there is no reference line', () {
      final svc = UnderlaySnapService();
      svc.primeInkForTest('pdf1', _stripeAt(20, 100, 100), 100, 100, 1.0);
      final hit = svc.snap(pdfSheet, const [], const Offset(21, 40), 8,
          enabled: true);
      expect(hit, isNotNull);
      expect(hit!.source, UnderlaySource.ink);
      // Snapped onto the stripe centreline (≈ x=20).
      expect(hit.point.dx, closeTo(20, 2));
    });

    test('DXF vector BEATS a reference line at the same place', () {
      DxfSheetPage.cacheForTest('/wall.dxf', _wallDrawing());
      final svc = UnderlaySnapService();
      final lines = [
        // A reference line coincident with the wall endpoint region.
        const ReferenceLine(
            id: 'r1', sheetId: 'dxf1', x1: 15, y1: 22, x2: 25, y2: 22),
      ];
      final hit =
          svc.snap(dxfSheet, lines, const Offset(21, 21), 8, enabled: true);
      expect(hit, isNotNull);
      expect(hit!.source, UnderlaySource.vector);
      // The wall endpoint at sheet-px (20,20).
      expect(hit.point.dx, closeTo(20, 1));
      expect(hit.point.dy, closeTo(20, 1));
    });

    test('invalidateAll drops the primed ink cache (no cross-project bleed)', () {
      final svc = UnderlaySnapService();
      svc.primeInkForTest('pdf1', _stripeAt(20, 100, 100), 100, 100, 1.0);
      // Before: the primed ink map snaps onto the stripe.
      final before = svc.snap(pdfSheet, const [], const Offset(21, 40), 8,
          enabled: true);
      expect(before, isNotNull);
      expect(before!.source, UnderlaySource.ink);

      svc.invalidateAll();

      // After: the cache is gone; the sheet's pdfPath ('/x.pdf') can't render, so
      // no ink source is available and the snap falls through to null.
      final after = svc.snap(pdfSheet, const [], const Offset(21, 40), 8,
          enabled: true);
      expect(after, isNull);
    });

    test('invalidateAll drops the DXF vector index', () {
      DxfSheetPage.cacheForTest('/wall.dxf', _wallDrawing());
      final svc = UnderlaySnapService();
      final hit = svc.snap(dxfSheet, const [], const Offset(21, 21), 8,
          enabled: true);
      expect(hit, isNotNull);
      expect(hit!.source, UnderlaySource.vector);

      // Simulate the source path being reused by a NEW project with different
      // (empty) geometry: invalidate, then re-cache the same path as empty.
      svc.invalidateAll();
      DxfSheetPage.cacheForTest('/wall.dxf', const DxfDrawing(
        polylines: [],
        circles: [],
        arcs: [],
        bounds: DxfBounds(0, 0, 100, 100),
      ));
      // The stale (populated) index was dropped ⇒ the empty re-parse wins ⇒ no snap.
      expect(
        svc.snap(dxfSheet, const [], const Offset(21, 21), 8, enabled: true),
        isNull,
      );
    });

    test('nothing in range ⇒ null', () {
      final svc = UnderlaySnapService();
      final lines = [
        const ReferenceLine(
            id: 'r1', sheetId: 'pdf1', x1: 10, y1: 20, x2: 30, y2: 20),
      ];
      expect(
        svc.snap(pdfSheet, lines, const Offset(90, 90), 8, enabled: true),
        isNull,
      );
    });
  });

  group('UnderlaySnapService.snap — SnapKind marker vocabulary (B24)', () {
    const dxfSheet = Sheet(
        id: 'dxf1', name: 'd', dxfPath: '/wall.dxf', sizePx: Size(100, 100));
    const pdfSheet = Sheet(
        id: 'pdf1', name: 'p', pdfPath: '/x.pdf', sizePx: Size(100, 100));

    test('DXF corner reads as SnapKind.endpoint', () {
      DxfSheetPage.cacheForTest('/wall.dxf', _wallDrawing());
      final svc = UnderlaySnapService();
      // The wall spans sheet (20,20)→(80,20); query outside the left corner.
      final hit = svc.snap(dxfSheet, const [], const Offset(18, 18), 8,
          enabled: true);
      expect(hit, isNotNull);
      expect(hit!.source, UnderlaySource.vector);
      expect(hit.kind, SnapKind.endpoint);
      expect(hit.point.dx, closeTo(20, 1e-6));
      expect(hit.point.dy, closeTo(20, 1e-6));
    });

    test('nearest point on a DXF wall reads as SnapKind.refline', () {
      DxfSheetPage.cacheForTest('/wall.dxf', _wallDrawing());
      final svc = UnderlaySnapService();
      final hit = svc.snap(dxfSheet, const [], const Offset(50, 22), 8,
          enabled: true);
      expect(hit, isNotNull);
      expect(hit!.source, UnderlaySource.vector);
      expect(hit.kind, SnapKind.refline);
    });

    test('reference-line nearest point reads as SnapKind.refline', () {
      final svc = UnderlaySnapService();
      final lines = [
        const ReferenceLine(
            id: 'r1', sheetId: 'pdf1', x1: 10, y1: 20, x2: 30, y2: 20),
      ];
      final hit =
          svc.snap(pdfSheet, lines, const Offset(20, 22), 8, enabled: true);
      expect(hit, isNotNull);
      expect(hit!.source, UnderlaySource.referenceLine);
      expect(hit.kind, SnapKind.refline);
    });

    test('PDF ink reads as SnapKind.ink', () {
      final svc = UnderlaySnapService();
      svc.primeInkForTest('pdf1', _stripeAt(20, 100, 100), 100, 100, 1.0);
      final hit = svc.snap(pdfSheet, const [], const Offset(21, 40), 8,
          enabled: true);
      expect(hit, isNotNull);
      expect(hit!.source, UnderlaySource.ink);
      expect(hit.kind, SnapKind.ink);
    });

    test('anchor enables a perpendicular-foot snap on the DXF wall', () {
      DxfSheetPage.cacheForTest('/wall.dxf', _wallDrawing());
      final svc = UnderlaySnapService();
      // Anchor at sheet (50,40) drops perpendicular to the wall foot (50,20);
      // the cursor near it snaps there tagged perpendicular.
      final hit = svc.snap(dxfSheet, const [], const Offset(50, 22), 8,
          enabled: true, anchor: const Offset(50, 40));
      expect(hit, isNotNull);
      expect(hit!.kind, SnapKind.perpendicular);
      expect(hit.point.dx, closeTo(50, 1e-6));
      expect(hit.point.dy, closeTo(20, 1e-6));

      // No anchor ⇒ the same query is a plain on-line refline hit.
      final plain = svc.snap(dxfSheet, const [], const Offset(50, 22), 8,
          enabled: true);
      expect(plain!.kind, SnapKind.refline);
    });
  });
}
