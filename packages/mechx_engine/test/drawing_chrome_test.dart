import 'dart:convert';

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/dxf_export.dart';
import 'package:mechx_engine/report/electrical_pdf_export.dart';
import 'package:mechx_engine/report/pdf_export.dart';
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  const net = Network(
    nodes: [
      NetNode(id: 'n0', sheetId: 's1', x: 100, y: 200, floorIndex: 0),
      NetNode(id: 'n1', sheetId: 's1', x: 400, y: 200, floorIndex: 0),
      NetNode(id: 'n2', sheetId: 's1', x: 400, y: 200, floorIndex: 1),
    ],
    edges: [
      NetEdge(id: 'e0', fromId: 'n0', toId: 'n1', service: ServiceType.coldWater),
      NetEdge(
        id: 'e1',
        fromId: 'n1',
        toId: 'n2',
        service: ServiceType.coldWater,
        kind: EdgeKind.riser,
      ),
    ],
  );

  const sizing = {
    'e0': EdgeSizing(
      edgeId: 'e0',
      service: ServiceType.coldWater,
      flow: FlowRate(0.005),
      diameter: Diameter(0.05),
      velocity: Velocity(1.8),
    ),
  };

  // A representative issuable-document chrome.
  const chrome = DrawingChrome(
    drawingNumber: 'M-101',
    revisionNumber: 'Rev. B',
    sheetIndex: 2,
    sheetTotal: 5,
    legendServices: [ServiceType.coldWater, ServiceType.fireSprinkler],
    scaleBarLabel: '1 : 100',
  );

  group('DrawingChrome value object', () {
    test('isEmpty is true only when every stamp is absent', () {
      expect(const DrawingChrome().isEmpty, isTrue);
      expect(const DrawingChrome(drawingNumber: 'X').isEmpty, isFalse);
      expect(
          const DrawingChrome(legendServices: [ServiceType.vent]).isEmpty,
          isFalse);
    });

    test('sheetCounter renders "X of Y" and tolerates a missing part', () {
      expect(chrome.sheetCounter, '2 of 5');
      // index only -> "1 of 1"-style fallback uses the index for the total.
      expect(const DrawingChrome(sheetIndex: 3).sheetCounter, '3 of 3');
      expect(const DrawingChrome(sheetTotal: 4).sheetCounter, '1 of 4');
      expect(const DrawingChrome().sheetCounter, isNull);
    });

    test('isEmpty covers the new title-block fields (additive contract)', () {
      // An all-null chrome stays empty (existing renderers keep byte-identity).
      expect(const DrawingChrome().isEmpty, isTrue);
      // Each new field alone makes it non-empty.
      expect(const DrawingChrome(clientName: 'Acme').isEmpty, isFalse);
      expect(const DrawingChrome(drawingTitle: 'PLAN').isEmpty, isFalse);
      expect(const DrawingChrome(drawnBy: 'AB').isEmpty, isFalse);
      expect(const DrawingChrome(checkedBy: 'CD').isEmpty, isFalse);
      expect(const DrawingChrome(approvedBy: 'EF').isEmpty, isFalse);
      expect(const DrawingChrome(dateString: '2026-07-02').isEmpty, isFalse);
      expect(const DrawingChrome(scaleText: '1 : 100').isEmpty, isFalse);
    });
  });

  group('pdfSheetFrame', () {
    test('draws one thin (0.8 w) border rectangle at the margin', () {
      final f = pdfSheetFrame(pageW: 842, pageH: 595, margin: 24);
      expect(f, contains('0.8 w'));
      // A3 landscape 842x595, margin 24 -> inner 794 x 547 at (24, 24).
      expect(f, contains('24.00 24.00 794.00 547.00 re S'));
    });
  });

  group('pdfTitleBlock', () {
    test('value-gated rows drop; the sign-off block always rules a cell (N20)',
        () {
      // drawingTitle + drawnBy set; clientName / rev / approver intentionally
      // absent. N20: DRAWN/CHECKED/APPROVED are the SAME on every issued sheet —
      // a blank one is a RULED cell for hand sign-off — so all three rows draw
      // (their labels), only the empty VALUE text is omitted; CLIENT/REV (empty,
      // not sign-off) drop entirely.
      const c = DrawingChrome(
        drawingNumber: 'M-101',
        drawingTitle: 'GROUND FLOOR PLUMBING',
        drawnBy: 'AB',
      );
      final tb = pdfTitleBlock(
        c,
        pageW: 842,
        pageH: 595,
        margin: 24,
        projectName: 'Tower A',
      );
      // Present rows: PROJECT, TITLE, DWG NO, DRAWN, CHECKED, APPROVED ->
      // 6 rows * 13pt = 78 (the sign-off trio is always ruled).
      expect(tb.height, closeTo(78.0, 1e-9));
      expect(tb.ops, contains('(PROJECT) Tj'));
      expect(tb.ops, contains('(Tower A) Tj'));
      expect(tb.ops, contains('(TITLE) Tj'));
      expect(tb.ops, contains('(GROUND FLOOR PLUMBING) Tj'));
      // The whole sign-off block rules a cell even when only DRAWN has a name.
      expect(tb.ops, contains('(DRAWN) Tj'));
      expect(tb.ops, contains('(AB) Tj'));
      expect(tb.ops, contains('(CHECKED) Tj'));
      expect(tb.ops, contains('(APPROVED) Tj'));
      // A blank sign-off cell rules but writes NO value text (no empty '() Tj').
      expect(tb.ops, isNot(contains('() Tj')));
      // Value-gated empty rows are still not drawn.
      expect(tb.ops, isNot(contains('(CLIENT) Tj')));
      expect(tb.ops, isNot(contains('(REV) Tj')));
    });

    test('a fully-empty block still draws nothing (byte-identity, N20)', () {
      // No populated row anywhere ⇒ the sign-off trio must NOT force a block, so
      // an exporter with a blank chrome stays byte-identical to before N20.
      final empty = pdfTitleBlock(
        const DrawingChrome(),
        pageW: 842,
        pageH: 595,
        margin: 24,
        projectName: '',
      );
      expect(empty.ops, '');
      expect(empty.height, 0.0);
      // A blank chrome with only a project name draws the full uniform set
      // (PROJECT + the ruled sign-off trio).
      final named = pdfTitleBlock(
        const DrawingChrome(),
        pageW: 842,
        pageH: 595,
        margin: 24,
        projectName: 'Tower A',
      );
      expect(named.ops, contains('(PROJECT) Tj'));
      expect(named.ops, contains('(DRAWN) Tj'));
      expect(named.ops, contains('(CHECKED) Tj'));
      expect(named.ops, contains('(APPROVED) Tj'));
    });

    test('scaleTextOverride wins over chrome.scaleText; empty -> no rows', () {
      const c = DrawingChrome(scaleText: '1 : 50');
      final tb = pdfTitleBlock(
        c,
        pageW: 842,
        pageH: 595,
        margin: 24,
        projectName: 'P',
        scaleTextOverride: '1 : 100',
      );
      expect(tb.ops, contains('(SCALE) Tj'));
      expect(tb.ops, contains('(1 : 100) Tj'));
      expect(tb.ops, isNot(contains('(1 : 50) Tj')));

      // With a blank project name and no other rows, nothing is drawn.
      final empty = pdfTitleBlock(
        const DrawingChrome(),
        pageW: 842,
        pageH: 595,
        margin: 24,
        projectName: '',
      );
      expect(empty.ops, '');
      expect(empty.height, 0.0);
    });
  });

  group('pdfScaleBarReal', () {
    test('empty when pointsPerMeter is not finite/positive', () {
      expect(
          pdfScaleBarReal(pointsPerMeter: 0, centerX: 100, baseY: 20), '');
      expect(
          pdfScaleBarReal(pointsPerMeter: -5, centerX: 100, baseY: 20), '');
      expect(
          pdfScaleBarReal(
              pointsPerMeter: double.infinity, centerX: 100, baseY: 20),
          '');
      expect(
          pdfScaleBarReal(
              pointsPerMeter: double.nan, centerX: 100, baseY: 20),
          '');
    });

    test('at 12 pt/m the 10 m bar is nearest 120 pt (0 / 5 m / 10 m)', () {
      // Ladder drawn widths: 1->12, 2->24, 5->60, 10->120 (exact), 20->240.
      // The 10 m bar (120 pt) is nearest the 120 pt target; mid = 5 m.
      final s = pdfScaleBarReal(pointsPerMeter: 12, centerX: 200, baseY: 30);
      expect(s, contains('(0) Tj'));
      expect(s, contains('(5 m) Tj'));
      expect(s, contains('(10 m) Tj'));
    });

    test('at 2 pt/m the 50 m bar is nearest 120 pt (0 / 25 m / 50 m)', () {
      // Ladder drawn widths: 20->40, 50->100 (err 20), 100->200 (err 80).
      // The 50 m bar (100 pt) is nearest the 120 pt target; mid = 25 m.
      final s = pdfScaleBarReal(pointsPerMeter: 2, centerX: 200, baseY: 30);
      expect(s, contains('(0) Tj'));
      expect(s, contains('(25 m) Tj'));
      expect(s, contains('(50 m) Tj'));
    });
  });

  group('DXF service tables', () {
    test('layer / colour / line-type / dash are total over ServiceType', () {
      for (final s in ServiceType.values) {
        expect(dxfLayerNameFor(s), isNotEmpty);
        expect(serviceAciColorFor(s), inInclusiveRange(1, 255));
        final lt = dxfLinetypeFor(s);
        expect(const ['CONTINUOUS', 'DASHED', 'DASHDOT'], contains(lt));
        // Dash pattern must be consistent with the line-type name.
        final dash = serviceDashPatternPdf(s);
        if (lt == 'CONTINUOUS') {
          expect(dash, isNull);
        } else {
          expect(dash, isNotNull);
        }
      }
    });

    test('dash + line-type tables match the documented services', () {
      expect(serviceDashPatternPdf(ServiceType.vent), const [6, 4]);
      expect(serviceDashPatternPdf(ServiceType.returnAir), const [6, 4]);
      expect(
          serviceDashPatternPdf(ServiceType.fireSprinkler), const [10, 3, 2, 3]);
      expect(
          serviceDashPatternPdf(ServiceType.fireHydrant), const [10, 3, 2, 3]);
      expect(serviceDashPatternPdf(ServiceType.coldWater), isNull);
      expect(dxfLinetypeFor(ServiceType.vent), 'DASHED');
      expect(dxfLinetypeFor(ServiceType.fireHydrant), 'DASHDOT');
      expect(dxfLinetypeFor(ServiceType.coldWater), 'CONTINUOUS');
    });

    test('dxfTablesSection defines the LTYPE + LAYER records', () {
      final tables = dxfTablesForServices(
          const [ServiceType.coldWater, ServiceType.vent]);
      expect(tables, contains('SECTION'));
      expect(tables, contains('TABLES'));
      expect(tables, contains('LTYPE'));
      expect(tables, contains('CONTINUOUS'));
      expect(tables, contains('DASHED'));
      expect(tables, contains('DASHDOT'));
      expect(tables, contains('LAYER'));
      expect(tables, contains('P-DOM-CWS')); // coldWater layer
      expect(tables, contains('P-SAN-VENT')); // vent layer
      expect(tables, contains(kDxfLayerAnno));
      expect(tables, contains(kDxfLayerFrame));
      expect(tables.trimRight(), endsWith('ENDSEC'));
    });
  });

  group('dxfTitleBlock', () {
    test('renders present rows as TEXT on the frame layer', () {
      final tb = dxfTitleBlock(
        const DrawingChrome(drawingNumber: 'M-101', drawingTitle: 'PLAN'),
        minX: 0,
        minY: -300,
        maxX: 400,
        maxY: 0,
        projectName: 'Tower A',
      );
      expect(tb, contains('M-101'));
      expect(tb, contains('PLAN'));
      expect(tb, contains('Tower A'));
      expect(tb, contains(kDxfLayerFrame));
      // No rows -> empty string.
      final empty = dxfTitleBlock(
        const DrawingChrome(),
        minX: 0,
        minY: -300,
        maxX: 400,
        maxY: 0,
        projectName: '',
      );
      expect(empty, '');
    });
  });

  group('plain network PDF chrome', () {
    test('null chrome is byte-identical to no chrome', () {
      final a = networkToPdf(
          net: net, sizing: sizing, sheetId: 's1', floorIndex: 0, title: 'T');
      final b = networkToPdf(
          net: net,
          sizing: sizing,
          sheetId: 's1',
          floorIndex: 0,
          title: 'T',
          chrome: null);
      expect(a, equals(b));
    });

    test('chrome stamps title block, sheet row, legend, NTS scale, north', () {
      // A4 (CAD-OUTPUT-UX-REVIEW): the loose revision-block corner text is
      // replaced by the ISO-7200 title block, whose rows carry the same data
      // (the SHEET value cell is '2 of 5', not 'Sheet 2 of 5'); the
      // uncalibrated divided scale bar is gone (A3) — the SCALE row reads
      // NTS instead.
      final s = latin1.decode(networkToPdf(
        net: net,
        sizing: sizing,
        sheetId: 's1',
        floorIndex: 0,
        title: 'T',
        chrome: chrome,
      ));
      // Title-block rows.
      expect(s, contains('(M-101) Tj'));
      expect(s, contains('(Rev. B) Tj'));
      expect(s, contains('(2 of 5) Tj'));
      expect(s, contains('(NTS) Tj'));
      // Legend.
      expect(s, contains('(LEGEND) Tj'));
      expect(s, contains('(Cold water) Tj'));
      expect(s, contains('(Sprinkler) Tj'));
      // No divided bar at an arbitrary auto-fit ratio; the north 'N' stays.
      expect(s, isNot(contains('(SCALE  1 : 100) Tj')));
      expect(s, contains('(N) Tj'));
      // Still a valid PDF (chrome inserted before xref).
      expect(s.startsWith('%PDF-1.4'), isTrue);
      expect(s.trimRight().endsWith('%%EOF'), isTrue);
    });

    test('the xref offsets stay accurate after chrome insertion', () {
      final s = latin1.decode(networkToPdf(
        net: net,
        sizing: sizing,
        sheetId: 's1',
        floorIndex: 0,
        chrome: chrome,
      ));
      final sx = s.lastIndexOf('startxref');
      final xrefOffset = int.parse(
          s.substring(sx + 'startxref'.length, s.indexOf('%%EOF', sx)).trim());
      expect(s.substring(xrefOffset, xrefOffset + 4), 'xref');
      final lines = s.substring(xrefOffset).split('\n');
      final obj1Offset = int.parse(lines[3].substring(0, 10));
      expect(s.substring(obj1Offset).startsWith('1 0 obj'), isTrue);
      // The /Length of the content stream must match the actual stream bytes.
      final lenMatch = RegExp(r'<< /Length (\d+) >>\nstream\n').firstMatch(s)!;
      final declared = int.parse(lenMatch.group(1)!);
      final streamStart = lenMatch.end;
      final streamEnd = s.indexOf('\nendstream', streamStart);
      expect(streamEnd - streamStart, declared);
    });
  });

  group('annotated plan PDF chrome', () {
    test('null chrome is byte-identical', () {
      final a = planToPdf(
        net: net,
        sizing: sizing,
        edgeLengths: const {'e0': Length(30), 'e1': Length(3.5)},
        sheetId: 's1',
        floorIndex: 0,
        projectName: 'P',
        sheetName: 'GF',
        dateString: '2026-06-27',
      );
      final b = planToPdf(
        net: net,
        sizing: sizing,
        edgeLengths: const {'e0': Length(30), 'e1': Length(3.5)},
        sheetId: 's1',
        floorIndex: 0,
        projectName: 'P',
        sheetName: 'GF',
        dateString: '2026-06-27',
        chrome: null,
      );
      expect(a, equals(b));
    });

    test('chrome adds the title block (sheet row) + the chrome marks', () {
      // A4 (CAD-OUTPUT-UX-REVIEW): the loose two-line top-left title is
      // replaced by the ISO-7200 title block; the exporter's own
      // sheet-name/date params feed the TITLE/DATE rows.
      final s = latin1.decode(planToPdf(
        net: net,
        sizing: sizing,
        edgeLengths: const {'e0': Length(30), 'e1': Length(3.5)},
        sheetId: 's1',
        floorIndex: 0,
        projectName: 'P',
        sheetName: 'GF',
        dateString: '2026-06-27',
        chrome: chrome,
      ));
      expect(s, contains('(2 of 5) Tj')); // the SHEET row value
      expect(s, contains('(M-101) Tj'));
      expect(s, contains('(P) Tj')); // PROJECT row
      expect(s, contains('(GF) Tj')); // TITLE row (from sheetName)
      expect(s, contains('(2026-06-27) Tj')); // DATE row (from dateString)
      expect(s, contains('(LEGEND) Tj'));
      expect(s, contains('(N) Tj'));
    });
  });

  group('DXF chrome', () {
    test('null chrome is byte-identical', () {
      final a = networkToDxf(
          net: net, sizing: sizing, sheetId: 's1', floorIndex: 0);
      final b = networkToDxf(
          net: net, sizing: sizing, sheetId: 's1', floorIndex: 0, chrome: null);
      expect(a, equals(b));
    });

    test('chrome emits TEXT on the title/legend/scale/north layers', () {
      final dxf = networkToDxf(
        net: net,
        sizing: sizing,
        sheetId: 's1',
        floorIndex: 0,
        chrome: chrome,
      );
      // New chrome layers.
      expect(dxf, contains('title'));
      expect(dxf, contains('legend'));
      expect(dxf, contains('scale'));
      expect(dxf, contains('north'));
      // Chrome TEXT content.
      expect(dxf, contains('M-101'));
      expect(dxf, contains('Sheet 2 of 5'));
      expect(dxf, contains('Cold water'));
      expect(dxf, contains('SCALE  1 : 100'));
      // Still a valid skeleton.
      expect(dxf.trimRight(), endsWith('EOF'));
    });
  });

  group('electrical SLD PDF chrome', () {
    const profile = PuilProfile();
    const project = ElectricalProject(
      id: 'p1',
      name: 'Test',
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          circuits: [
            ElectricalCircuit(
              id: 'c1',
              name: 'Lighting',
              loadKind: LoadKind.lighting,
              isLighting: true,
              loadW: 1500,
              length: Length(18),
            ),
          ],
        ),
      ],
    );

    test('null chrome is byte-identical', () {
      final result = computeSystem(profile, project);
      final a = electricalSldToPdf(project: project, result: result);
      final b =
          electricalSldToPdf(project: project, result: result, chrome: null);
      expect(a, equals(b));
    });

    test('chrome stamps the revision block + sheet counter', () {
      final result = computeSystem(profile, project);
      final s = latin1.decode(electricalSldToPdf(
        project: project,
        result: result,
        chrome: const DrawingChrome(
          drawingNumber: 'E-201',
          revisionNumber: 'Rev. A',
          sheetIndex: 1,
          sheetTotal: 3,
        ),
      ));
      // N20: the SLD now stamps the SAME shared drawing_chrome tabular block the
      // plan exporters use — DWG NO / REV / SHEET as labelled rows (the SHEET
      // value cell is '1 of 3', not 'Sheet 1 of 3'), the diagram title as the
      // TITLE row. (A single-line is schematic — no north arrow.)
      expect(s, contains('E-201'));
      expect(s, contains('Rev. A'));
      expect(s, contains('(SHEET) Tj'));
      expect(s, contains('(1 of 3) Tj'));
      expect(s, contains('ELECTRICAL SINGLE-LINE DIAGRAM'));
      expect(s.trimRight().endsWith('%%EOF'), isTrue);
    });
  });

  group('sheetDrawingNumber (N19)', () {
    test('a blank base derives the per-series/per-index code', () {
      // The exact bands the issued set uses (matching the sample harness).
      expect(
          sheetDrawingNumber(series: DrawingSeries.mechanicalPlan, index: 1),
          'M-101');
      expect(
          sheetDrawingNumber(series: DrawingSeries.mechanicalPlan, index: 2),
          'M-102');
      expect(sheetDrawingNumber(series: DrawingSeries.mechanicalRiser),
          'M-201');
      expect(sheetDrawingNumber(series: DrawingSeries.electricalDetail),
          'E-201');
      expect(sheetDrawingNumber(series: DrawingSeries.electricalOverview),
          'E-301');
      expect(sheetDrawingNumber(series: DrawingSeries.electricalRiser),
          'E-401');
      expect(sheetDrawingNumber(series: DrawingSeries.electricalPowerOneLine),
          'E-501');
    });

    test('every plan sheet gets a DISTINCT number (the N19 fix)', () {
      // Three plans on a blank base ⇒ three different numbers, never one number
      // on every sheet.
      final nums = [
        for (var i = 1; i <= 3; i++)
          sheetDrawingNumber(series: DrawingSeries.mechanicalPlan, index: i),
      ];
      expect(nums, ['M-101', 'M-102', 'M-103']);
      expect(nums.toSet().length, 3);
    });

    test('a non-empty base is the verbatim override (trimmed)', () {
      expect(
          sheetDrawingNumber(
              base: 'ME-2024-001', series: DrawingSeries.mechanicalPlan),
          'ME-2024-001');
      // Whitespace-only counts as blank ⇒ still derives.
      expect(
          sheetDrawingNumber(base: '   ', series: DrawingSeries.electricalRiser),
          'E-401');
      expect(
          sheetDrawingNumber(
              base: '  E-9  ', series: DrawingSeries.electricalDetail),
          'E-9');
    });

    test('an index past the band is padded, never bleeding to the next band',
        () {
      expect(
          sheetDrawingNumber(series: DrawingSeries.mechanicalPlan, index: 12),
          'M-112');
      // Stays within the M-1xx discipline band even past 99.
      expect(
          sheetDrawingNumber(series: DrawingSeries.mechanicalPlan, index: 100),
          'M-1100');
      // A non-positive index clamps to 1 (defensive).
      expect(
          sheetDrawingNumber(series: DrawingSeries.mechanicalRiser, index: 0),
          'M-201');
    });
  });
}
