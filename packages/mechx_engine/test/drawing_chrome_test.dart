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

    test('chrome stamps drawing-number, revision, sheet, legend, scale, north',
        () {
      final s = latin1.decode(networkToPdf(
        net: net,
        sizing: sizing,
        sheetId: 's1',
        floorIndex: 0,
        title: 'T',
        chrome: chrome,
      ));
      // Revision / drawing-number block.
      expect(s, contains('(M-101) Tj'));
      expect(s, contains('(Rev. B) Tj'));
      expect(s, contains('(Sheet 2 of 5) Tj'));
      // Legend.
      expect(s, contains('(LEGEND) Tj'));
      expect(s, contains('(Cold water) Tj'));
      expect(s, contains('(Sprinkler) Tj'));
      // Scale bar label + a north 'N'.
      expect(s, contains('(SCALE  1 : 100) Tj'));
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

    test('chrome adds the sheet counter on the title line + the chrome marks',
        () {
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
      expect(s, contains('Sheet 2 of 5')); // on the sheet-name line
      expect(s, contains('(M-101) Tj'));
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
      // The drawing number + revision are stamped in the title block, alongside
      // the sheet counter. (A single-line is schematic — no north arrow.)
      expect(s, contains('E-201'));
      expect(s, contains('Rev. A'));
      expect(s, contains('(Sheet 1 of 3) Tj'));
      expect(s, contains('ELECTRICAL SINGLE-LINE DIAGRAM'));
      expect(s.trimRight().endsWith('%%EOF'), isTrue);
    });
  });
}
