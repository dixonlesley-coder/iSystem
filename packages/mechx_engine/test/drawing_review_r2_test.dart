// Drawing review round 2 (2026-11-13) — the cures R1 (enlarged DETAIL sheets
// for dense plan areas) and R2 (riser column re-spacing + the exact 7 pt
// paginator floor), pinned on their pure rules.
import 'dart:convert';

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/dxf_export.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/plan_detail.dart';
import 'package:mechx_engine/report/plan_detail_sheet.dart';
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/report/riser_pagination.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  group('R1 — detail clusters', () {
    test('seeds within 2 x link join; elements one hop away widen the box',
        () {
      final r = planDetailClusterRects(
        seeds: const [(x: 0, y: 0), (x: 15, y: 0), (x: 200, y: 200)],
        elements: const [(x: -8, y: 5), (x: -30, y: 0), (x: 205, y: 195)],
        linkPx: 10,
        marginPx: 2,
      );
      expect(r, hasLength(2));
      // First cluster: seeds 0 and 15 (gap 15 <= 20), element (-8, 5)
      // within 10 of seed 0; (-30, 0) is 30 away — not swallowed.
      expect(r[0], (minX: -10.0, minY: -2.0, maxX: 17.0, maxY: 7.0));
      expect(r[1], (minX: 198.0, minY: 193.0, maxX: 207.0, maxY: 202.0));
    });

    test('overlapping boxes merge with an earlier pass; touching ones stay',
        () {
      final r = planDetailClusterRects(
        seeds: const [(x: 5, y: 5)],
        elements: const [],
        linkPx: 1,
        marginPx: 1,
        existing: const [
          (minX: 0.0, minY: 0.0, maxX: 4.5, maxY: 4.5),
          (minX: 10.0, minY: 0.0, maxX: 20.0, maxY: 10.0),
        ],
      );
      // (4..6) overlaps the first box; the second (from x = 10) only stands
      // apart.
      expect(r, [
        (minX: 0.0, minY: 0.0, maxX: 6.0, maxY: 6.0),
        (minX: 10.0, minY: 0.0, maxX: 20.0, maxY: 10.0),
      ]);
    });

    test('letters run A..Z, AA', () {
      expect(planDetailLetter(0), 'A');
      expect(planDetailLetter(25), 'Z');
      expect(planDetailLetter(26), 'AA');
    });
  });

  group('R1 — scale pick + packing', () {
    const area = (minX: 0.0, minY: 0.0, maxX: 400.0, maxY: 200.0);
    test('one 3 x 2 m toilet core plots at 1:20 (1:10 does not fit)', () {
      // 1:10 ⇒ 300 + 36 = 336 wide, 200 + 36 + 16 caption = 252 > 200 tall.
      // 1:20 ⇒ 186 x 136 (+16) — fits.
      final p = planDetailPack(sizesM: const [(w: 3, h: 2)], area: area);
      expect(p.n, 20);
      final f = p.frames.single;
      expect(f.maxX - f.minX, closeTo(3000 / 20 + 2 * kPlanDetailFramePadMm, 1e-9));
      // Centred in its row.
      expect(f.minX, closeTo((400 - (f.maxX - f.minX)) / 2, 1e-9));
    });

    test('three cores share one scale; a fourth wraps to a second row', () {
      final three = planDetailPack(
          sizesM: const [(w: 3, h: 2), (w: 3, h: 2), (w: 3, h: 2)],
          area: area);
      // 1:20 needs 3 x 186 + 2 x 8 = 574 > 400; 1:25 needs 3 x 156 + 16 =
      // 484; 1:50 needs 3 x 96 + 16 = 304 — fits.
      expect(three.n, 50);
      expect(three.frames.map((f) => f.minY).toSet(), hasLength(1));
      final four = planDetailPack(
          sizesM: const [(w: 6, h: 1), (w: 6, h: 1), (w: 6, h: 1), (w: 6, h: 1)],
          area: area);
      expect(four.frames.map((f) => f.minY).toSet().length, greaterThan(1));
    });

    test('nothing fits at 1:50 ⇒ the first coarser plan rung that does', () {
      final p = planDetailPack(sizesM: const [(w: 30, h: 5)], area: area);
      // 1:50 ⇒ 636 wide; 1:100 ⇒ 336 x 86 (+16) — fits.
      expect(p.n, 100);
    });

    test('the scale bar spans 30..80 paper mm at a round length', () {
      final b = planDetailScaleBar(n: 20, x0: 0, y0: 0, textMm: 2.5);
      // 1:20: 0.25 m → 12.5 mm, 0.5 m → 25 mm, 1 m → 50 mm (first >= 30).
      expect(b.lines.first.x2, closeTo(50, 1e-9));
      expect(b.texts.map((t) => t.text), ['0', '1 m']);
    });
  });

  group('R1 — a dense plan issues a detail instead of the overlap stamp', () {
    // A fan of short runs out of one junction (a toilet group) on a sheet
    // whose calibration plots it at 1:100 — the classic overlap case.
    Network fan() {
      const s = 's1';
      final nodes = <NetNode>[
        const NetNode(id: 'J', sheetId: s, x: 500, y: 500, floorIndex: 0),
        const NetNode(id: 'FAR', sheetId: s, x: 4000, y: 500, floorIndex: 0),
      ];
      final edges = <NetEdge>[
        const NetEdge(
            id: 'main', fromId: 'FAR', toId: 'J', service: ServiceType.coldWater),
      ];
      for (var i = 0; i < 16; i++) {
        nodes.add(NetNode(
            id: 'F$i',
            sheetId: s,
            x: 470 + 30.0 * (i % 4),
            y: 505 + 30.0 * (i ~/ 4),
            floorIndex: 0,
            role: NodeRole.fixture));
        edges.add(NetEdge(
            id: 'b$i', fromId: 'J', toId: 'F$i', service: ServiceType.coldWater));
      }
      return Network(nodes: nodes, edges: edges);
    }

    const mpp = 0.01; // 1 px = 10 mm
    final net = fan();
    final lengths = <String, Length>{
      for (final e in net.edges) e.id: const Length(0.4),
    };
    const chrome = DrawingChrome(drawingNumber: 'M-101', drawingTitle: 'PLAN - L1');
    List<PlanDetailCallout> details() => planSheetDetails(
          net: net,
          sizing: const {},
          edgeLengths: lengths,
          sheetId: 's1',
          floorIndex: 0,
          projectName: 'P',
          sheetName: 'L1',
          dateString: '2026-11-13',
          detailSheetRef: 'M-501',
          chrome: chrome,
          metersPerPixel: mpp,
        );

    test('the cluster is boxed and the plan prints no stamp', () {
      final d = details();
      expect(d, isNotEmpty);
      expect(d.first.caption, 'DETAIL A - LIHAT M-501');
      expect(d.first.containsPx(500, 500), isTrue);
      expect(d.first.containsPx(4000, 500), isFalse);
      final pdf = latin1.decode(planToPdf(
          net: net,
          sizing: const {},
          edgeLengths: lengths,
          sheetId: 's1',
          floorIndex: 0,
          projectName: 'P',
          sheetName: 'L1',
          dateString: '2026-11-13',
          chrome: chrome,
          metersPerPixel: mpp,
          details: d));
      expect(pdf, isNot(contains('PERHATIAN')));
      expect(pdf, contains('DETAIL A - LIHAT M-501'));
      final dxf = networkToDxf(
          net: net,
          sizing: const {},
          sheetId: 's1',
          floorIndex: 0,
          chrome: chrome,
          metersPerPixel: mpp,
          projectName: 'P',
          details: d,
          sheetPlot: planSheetPlot(
              net: net,
              sheetId: 's1',
              floorIndex: 0,
              projectName: 'P',
              sheetName: 'L1',
              dateString: '2026-11-13',
              chrome: chrome,
              metersPerPixel: mpp));
      expect(dxf, contains('DETAIL A - LIHAT M-501'));
      expect(dxf, isNot(contains('PERHATIAN')));
    });

    test('the detail sheet: own scale, every label clear, PDF == DXF text',
        () {
      final d = details();
      const dChrome = DrawingChrome(
          drawingNumber: 'M-501', drawingTitle: 'DETAIL - L1');
      final pdf = latin1.decode(planDetailSheetToPdf(
          net: net,
          sizing: const {},
          edgeLengths: lengths,
          sheetId: 's1',
          floorIndex: 0,
          projectName: 'P',
          sheetName: 'L1',
          dateString: '2026-11-13',
          metersPerPixel: mpp,
          details: d,
          chrome: dChrome));
      expect(pdf, isNot(contains('PERHATIAN')));
      expect(pdf, contains('(DETAIL A)'));
      expect(pdf, matches(RegExp(r'\(SKALA 1 : (10|20|25|50)\)')));
      expect(pdf, contains('(AS SHOWN)'));
      final dxf = planDetailSheetToDxf(
          net: net,
          sizing: const {},
          edgeLengths: lengths,
          sheetId: 's1',
          floorIndex: 0,
          projectName: 'P',
          sheetName: 'L1',
          dateString: '2026-11-13',
          metersPerPixel: mpp,
          details: d,
          chrome: dChrome);
      expect(dxf, contains('DETAIL A'));
      expect(dxf, contains('AS SHOWN'));
      expect(dxf, isNot(contains('PERHATIAN')));
      // A run's label keeps its REAL length (0.4 m), not the enlarged one.
      expect(pdf, contains('0.4 m'));
    });

    test('a sparse plan needs no detail (byte-identical plan)', () {
      const sparse = Network(nodes: [
        NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's1', x: 1000, y: 0, floorIndex: 0),
      ], edges: [
        NetEdge(id: 'e', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
      ]);
      expect(
          planSheetDetails(
              net: sparse,
              sizing: const {},
              edgeLengths: const {},
              sheetId: 's1',
              floorIndex: 0,
              projectName: 'P',
              sheetName: 'L1',
              dateString: 'd',
              detailSheetRef: 'M-501',
              chrome: chrome,
              metersPerPixel: mpp),
          isEmpty);
    });

    test('the detail series is M-5nn, titled DETAIL - <floor>', () {
      expect(
          sheetDrawingNumber(series: DrawingSeries.mechanicalDetail, index: 4),
          'M-504');
      expect(
          drawingSeriesTitle(DrawingSeries.mechanicalDetail,
              sheetName: 'Lantai 4'),
          'DETAIL - Lantai 4');
    });
  });

  group('R2 — riser column re-spacing', () {
    test('dense columns open to the minimum pitch; empty width pays for it',
        () {
      // Five columns 4 apart at the left, one far right, band 0..600.
      final bp = riserColumnRespace([10, 14, 18, 22, 26, 500],
          lo: 0, hi: 600, minPitch: 60);
      final xs = [for (final p in bp) p.$2];
      for (var i = 0; i + 1 < 5; i++) {
        expect(xs[i + 1] - xs[i], greaterThanOrEqualTo(60 - 1e-6));
      }
      // Order kept, inside the band.
      for (var i = 0; i + 1 < xs.length; i++) {
        expect(xs[i + 1], greaterThan(xs[i]));
      }
      expect(xs.first, greaterThanOrEqualTo(0));
      expect(xs.last, lessThanOrEqualTo(600 + 1e-6));
    });

    test('coincident columns stay coincident (a riser keeps one column)', () {
      final bp = riserColumnRespace([100, 100.2, 300, 300], lo: 0, hi: 1000,
          minPitch: 60);
      expect(bp, hasLength(2));
      expect(riserRespaceAt(bp, 100.2), closeTo(riserRespaceAt(bp, 100), 0.5));
    });

    test('too many columns for the width share it evenly', () {
      final bp = riserColumnRespace([for (var i = 0; i < 11; i++) i * 1.0],
          lo: 0, hi: 100, minPitch: 60);
      final xs = [for (final p in bp) p.$2];
      for (var i = 0; i + 1 < xs.length; i++) {
        expect(xs[i + 1] - xs[i], closeTo(10, 1e-9));
      }
    });

    test('sparse columns are left as they are', () {
      final bp = riserColumnRespace([100, 300, 500], lo: 0, hi: 600,
          minPitch: 60);
      for (final (a, b) in bp) {
        expect(b, closeTo(a, 1e-6));
      }
    });
  });

  group('R2 — the paginator floor is exact', () {
    test('a page below 7 pt sheds its extras to a continuation sheet', () {
      // A fake builder: the lowest floor's page with the extras is too tall
      // to print at 7 pt; without them it prints at 7.
      SldSheet sheet(double h) => SldSheet(
          prims: const [SldLabel(0, 10, 'X', size: 8)],
          minX: 0,
          minY: 0,
          maxX: 600,
          maxY: h,
          legend: const [],
          supplyNote: '');
      final pages = paginatedRiserSheets(
        build: (r) => sheet(r == null || r.lo == 0 ? 9000 : 300),
        buildWithoutExtras: (r) => sheet(300),
        buildExtrasOnly: () => sheet(200),
        levelCount: 2,
      );
      // The floors on one page without the extras + the extras sheet, every
      // page at the 7 pt floor (none flagged).
      expect(pages, hasLength(2));
      expect(pages.every((p) => p.belowMinLabelPt == null), isTrue);
      // Without the callbacks the same page is issued flagged (honest).
      final old = paginatedRiserSheets(
        build: (r) => sheet(r == null || r.lo == 0 ? 9000 : 300),
        levelCount: 2,
      );
      expect(old.any((p) => p.belowMinLabelPt != null), isTrue);
    });
  });
}
