// Drawing review (2026-11-13) — the reference-building drawing sets were
// reviewed against docs/DRAFTING-CHECKLIST.md; these pin the cures (D1..D7).
import 'dart:convert';
import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/cover_sheet.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/report/report_blocks.dart';
import 'package:mechx_engine/report/report_pdf.dart';
import 'package:mechx_engine/report/sld_export.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'reference/office.dart' as office;
import 'reference/reference_building.dart';
import 'reference/tower.dart' as tower;

String _pdfText(List<int> bytes) => latin1.decode(bytes);

void main() {
  group('D1 / D2 / D3 — every issued sheet has its own number', () {
    test('front matter is G-001..G-003, schedules M-601 / E-601', () {
      expect([
        for (var i = 1; i <= 3; i++)
          sheetDrawingNumber(series: DrawingSeries.general, index: i)
      ], [
        'G-001',
        'G-002',
        'G-003'
      ]);
      expect(
          sheetDrawingNumber(series: DrawingSeries.equipmentSchedule), 'M-601');
      expect(sheetDrawingNumber(series: DrawingSeries.panelSchedule), 'E-601');
      // The panel schedules never reuse the SLD's number or title.
      expect(sheetDrawingNumber(series: DrawingSeries.panelSchedule),
          isNot(sheetDrawingNumber(series: DrawingSeries.electricalDetail)));
      expect(drawingSeriesTitle(DrawingSeries.panelSchedule),
          'JADWAL PANEL / PANEL SCHEDULES');
      // A front-matter title IS its sheet name (register == title block).
      expect(
          drawingSeriesTitle(DrawingSeries.general,
              sheetName: kFrontMatterDiagramTitles[1]),
          'DRAWING LIST / DAFTAR GAMBAR');
    });

    test('a front-matter set stamps each page its own drawing number', () {
      final sheets = buildSubmittalFrontMatter(
        projectName: 'P',
        drawings: const [
          DrawingListEntry(number: 'G-001', title: 'COVER SHEET'),
        ],
      );
      final pdf = _pdfText(sldSheetsToPdf(sheets,
          diagramTitles: kFrontMatterDiagramTitles,
          drawingNumbers: const ['G-001', 'G-002', 'G-003'],
          chrome: const DrawingChrome(revisionNumber: 'A')));
      for (final n in ['G-001', 'G-002', 'G-003']) {
        expect(pdf, contains('($n)'), reason: n);
      }
    });

    test('a long Daftar Gambar continues on further pages (>= 7 pt)', () {
      final rows = [
        for (var i = 1; i <= 60; i++)
          DrawingListEntry(
              number: 'M-1${i.toString().padLeft(2, '0')}', title: 'PLAN'),
      ];
      final pages = buildDrawingListSheets(rows);
      expect(pages.length, drawingListPageCount(60));
      expect(pages.length, 3);
      // The running No. continues: page 2 starts at 25.
      expect(pages[1].prims.whereType<SldLabel>().any((l) => l.text == '25'),
          isTrue);
      // Every page keeps the single-page proportions (no shrink to fit).
      for (final p in pages) {
        expect(p.maxY, lessThanOrEqualTo(140 + 25 * 34 + 60 + 1e-9));
      }
    });

    test('the equipment schedule carries the standard title block per page',
        () {
      final pdf = _pdfText(reportBlocksToPdf(
        const [RptParagraph('Pump P-01')],
        docTitle: 'Equipment Schedule',
        projectName: 'P',
        sheetTitleBlock: const ReportSheetTitleBlock(
          projectName: 'P',
          title: 'JADWAL PERALATAN / EQUIPMENT SCHEDULE',
          drawingNumber: 'M-601',
          revision: 'A',
          date: '2026-11-13',
          drawnBy: 'AB',
        ),
      ));
      for (final k in [
        'PROJECT',
        'TITLE',
        'DWG NO',
        'REV',
        'SCALE',
        'DATE',
        'DRAWN',
        'CHECKED',
        'APPROVED',
        'SHEET'
      ]) {
        expect(pdf, contains('($k)'), reason: k);
      }
      expect(pdf, contains('(M-601)'));
      // Cover + one content page => 1 of 2 and 2 of 2.
      expect(pdf, contains('(1 of 2)'));
      expect(pdf, contains('(2 of 2)'));
    });
  });

  group('D7 — the zero-length export guard counts uncalibrated runs only', () {
    const building = BuildingLevels([Floor('L1', Length(4.0))]);
    const a = NetNode(id: 'a', sheetId: 's', x: 10, y: 10, floorIndex: 0);
    const b = NetNode(id: 'b', sheetId: 's', x: 10, y: 10, floorIndex: 0);
    const c = NetNode(id: 'c', sheetId: 's', x: 110, y: 10, floorIndex: 0);
    const net = Network(nodes: [
      a,
      b,
      c
    ], edges: [
      NetEdge(
          id: 'splice', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
      NetEdge(
          id: 'run', fromId: 'b', toId: 'c', service: ServiceType.coldWater),
    ]);
    bool blocks(String id, Map<String, ScaleCalibration> cal) =>
        edgeBlocksExportAsZeroLength(net.edgeById(id)!, net,
            calibrationBySheet: cal, building: building);

    test('a 0 px splice on a calibrated sheet is not counted', () {
      const cal = {'s': ScaleCalibration(0.01)};
      expect(blocks('splice', cal), isFalse);
      expect(blocks('run', cal), isFalse); // 1.0 m: a real length
    });

    test('every run on an uncalibrated sheet is counted', () {
      expect(blocks('splice', const {}), isTrue);
      expect(blocks('run', const {}), isTrue);
    });
  });

  group('D4 / D5 — riser labels: legal slot or key tag, never an overlap', () {
    SldSheet riser(ReferenceBuilding b, {({int lo, int hi})? range}) {
      final net = b.network;
      final sizing = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {},
          calibrationBySheet: b.calibrations,
          building: b.building);
      return buildMechanicalRiserSld(
        network: net,
        sizing: sizing,
        building: b.building,
        edgeLengths: {
          for (final e in net.edges)
            e.id: edgeLength(e, net,
                calibrationBySheet: b.calibrations, building: b.building),
        },
        detailCallouts: true,
        notes: const ['Catatan 1'],
        floorRange: range,
      );
    }

    // Every label box (ascent 0.75, descent 0.22 em) of [s].
    List<(double, double, double, double)> boxes(SldSheet s) => [
          for (final p in s.prims)
            if (p is SldLabel && p.text.trim().isNotEmpty)
              (
                p.x,
                p.y - 0.75 * p.size,
                p.x + mechRiserLabelWidth(p.text, p.size),
                p.y + 0.22 * p.size
              ),
        ];

    for (final (name, build) in [
      ('office', office.buildOffice),
      ('tower', tower.buildTower),
    ]) {
      test('$name: every page places every tag clear (no overlap stamp)', () {
        final b = build();
        final n = b.building.levelCount;
        for (final range in [
          null,
          for (var f = 0; f < n; f++) (lo: f, hi: f),
        ]) {
          final s = riser(b, range: range);
          // Residual (docs/REFERENCE-BUILDINGS.md backlog): the tower's
          // ground plant floor and its top (roof-plant) floors can still
          // force a key tag onto a crossing — stamped honestly.
          final residual = name == 'tower' &&
              (range == null || range.lo == 0 || range.lo >= 27);
          if (!residual) {
            expect(s.overlapCount, 0, reason: '$name $range');
          }
          // A keyed sheet carries its key table; an unkeyed one none.
          final keyed = s.prims.whereType<SldCircle>().isNotEmpty;
          final table = s.prims
              .whereType<SldLabel>()
              .any((l) => l.text == 'KETERANGAN PIPA / PIPE KEY');
          expect(table, keyed, reason: '$name $range');
        }
      });
    }

    test('office: no two placed tags fuse (glyph bodies overlap)', () {
      final s = riser(office.buildOffice());
      final bs = boxes(s);
      var fused = 0;
      for (var i = 0; i < bs.length; i++) {
        for (var j = i + 1; j < bs.length; j++) {
          final a = bs[i], c = bs[j];
          final dx = (a.$3 < c.$3 ? a.$3 : c.$3) - (a.$1 > c.$1 ? a.$1 : c.$1);
          final dy = (a.$4 < c.$4 ? a.$4 : c.$4) - (a.$2 > c.$2 ? a.$2 : c.$2);
          if (dx > 1 && dy > 2) fused++;
        }
      }
      expect(fused, 0);
    });

    test('the plant detail rides below the bands: the sheet is band-wide', () {
      // D4 — no right-margin plant column: the A3 fit keeps >= 7 pt tags.
      final s = riser(office.buildOffice(), range: (lo: 0, hi: 0));
      expect(s.maxX, lessThanOrEqualTo(132 + 840 + 150 + 1e-9));
    });

    test('the key table keys identical texts once', () {
      final prims = <SldPrim>[];
      final bottom = emitMechRiserKeyTable(prims,
          rows: const [
            (key: 1, text: '75-D-PVC - 1.5 m', levels: 'Lantai 2'),
            (key: 2, text: 'CW-R1', levels: '-'),
          ],
          left: 0,
          top: 0,
          maxRight: 1000);
      final texts = prims.whereType<SldLabel>().map((l) => l.text).toList();
      expect(texts, containsAll(['75-D-PVC', '1.5 m', 'CW-R1', 'Lantai 2']));
      expect(prims.whereType<SldLabel>().every((l) => l.size >= 8), isTrue);
      expect(bottom, greaterThan(0));
    });
  });

  group('D5 — plan tags: legal slot or key tag, keyed text in a table', () {
    test('a crowded run keys the tags that find no short clear slot', () {
      const ts = 9.0;
      final layout = PlanLabelLayout();
      // A fan of short runs out of one junction (the fixture-group case).
      for (var k = 0; k < 4; k++) {
        layout.addRun(
            'r$k', 100, 100, 100 + 30.0 * (k.isEven ? 1 : -1), 100 + 14.0 * k);
      }
      // Dense marks everywhere but a small clearing round the junction.
      for (var x = 0.0; x <= 300; x += 14) {
        for (var y = 0.0; y <= 300; y += 14) {
          final dx = x - 100, dy = y - 107;
          if (dx * dx + dy * dy < 60 * 60) continue;
          layout.addBox((minX: x, minY: y, maxX: x + 6, maxY: y + 6));
        }
      }
      final keys = PlanKeyRegistry();
      final placed = [
        for (var k = 0; k < 4; k++)
          placePlanLabel(
              ax: 100,
              ay: 100,
              bx: 100 + 30.0 * (k.isEven ? 1 : -1),
              by: 100 + 14.0 * k,
              text: 'CW-L3 \u00b7 DN15 - 4.1 m - CL +3.70',
              textSize: ts,
              layout: layout,
              ownRunId: 'r$k',
              keys: keys),
      ];
      final keyed = placed.where((p) => p.keyCircle != null).toList();
      expect(keyed, isNotEmpty);
      // Identical texts share ONE key.
      expect(keys.keyOf.length, 1);
      for (final p in placed) {
        final a = p.leaderAnchor, e = p.leaderEnd;
        if (a == null || e == null) continue;
        final len = math.sqrt(math.pow(e.x - a.x, 2) + math.pow(e.y - a.y, 2));
        expect(len, lessThanOrEqualTo(kPlanKeyedLeaderMaxFactor * ts + 1e-6));
      }
      final table = placePlanKeyTable(layout, keys,
          textSize: ts, bounds: (minX: 0, minY: 0, maxX: 1200, maxY: 1200));
      expect(table, isNotNull);
      final texts = table!.texts.map((t) => t.text).toList();
      expect(texts, contains('KETERANGAN PIPA / PIPE KEY'));
      expect(texts, containsAll(['CW-L3 \u00b7 DN15', '4.1 m - CL +3.70']));
      expect(layout.unresolvedCount, 0);
    });
  });
}
