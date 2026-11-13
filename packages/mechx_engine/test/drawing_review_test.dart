// Drawing review (2026-11-13) — the reference-building drawing sets were
// reviewed against docs/DRAFTING-CHECKLIST.md; these pin the cures (D1..D7).
import 'dart:convert';

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/cover_sheet.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/report_blocks.dart';
import 'package:mechx_engine/report/report_pdf.dart';
import 'package:mechx_engine/report/sld_export.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

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
}
