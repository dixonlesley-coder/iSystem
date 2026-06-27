import 'dart:convert';
import 'dart:typed_data';

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  // Two nodes on floor 0 joined by a 30 m cold-water run, plus a riser up to a
  // node on floor 1 with a 3.5 m elevation delta.
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

  // Ø0.05 m -> DN50 for the run.
  const sizing = {
    'e0': EdgeSizing(
      edgeId: 'e0',
      service: ServiceType.coldWater,
      flow: FlowRate(0.005),
      diameter: Diameter(0.05),
      velocity: Velocity(1.8),
    ),
  };

  // Lengths the app would pass from edgeLength(): 30 m run, 3.5 m riser.
  const lengths = {
    'e0': Length(30.0),
    'e1': Length(3.5),
  };

  Uint8List build() => planToPdf(
        net: net,
        sizing: sizing,
        edgeLengths: lengths,
        sheetId: 's1',
        floorIndex: 0,
        projectName: 'Tower A',
        sheetName: 'Ground Floor',
        dateString: '2026-06-27',
      );

  test('emits a well-formed single-page PDF', () {
    final bytes = build();
    expect(bytes, isNotEmpty);
    final s = latin1.decode(bytes);
    expect(s.startsWith('%PDF-1.4'), isTrue);
    expect(s.trimRight().endsWith('%%EOF'), isTrue);
    expect(s, contains('/Type /Catalog'));
    expect(s, contains('/Type /Page'));
    expect(s, contains('/BaseFont /Helvetica'));
    expect(s, contains('stream'));
    expect(s, contains('endstream'));
    expect(s, contains('trailer'));
  });

  test('draws run line with size+length label and riser marker', () {
    final s = latin1.decode(build());
    expect(s, contains(' l S')); // a stroked line segment (the run)
    expect(s, contains('DN50')); // the run size label
    expect(s, contains('30 m')); // the run length
    expect(s, contains('3.5 m')); // the riser length (on-floor end)
    expect(s, contains(' c\n')); // a bezier curve (riser circle / node dots)
    // Title block: project name then sheet + date.
    expect(s, contains('(Tower A) Tj'));
    expect(s, contains('Ground Floor'));
    expect(s, contains('2026-06-27'));
  });

  test('the cross-reference offsets actually point at their objects', () {
    final bytes = build();
    final s = latin1.decode(bytes);
    final sx = s.lastIndexOf('startxref');
    final xrefOffset = int.parse(
        s.substring(sx + 'startxref'.length, s.indexOf('%%EOF', sx)).trim());
    expect(s.substring(xrefOffset, xrefOffset + 4), 'xref');
    final lines = s.substring(xrefOffset).split('\n');
    // lines[0] = 'xref', lines[1] = '0 6', lines[2] = free entry, lines[3] = obj1
    final obj1Offset = int.parse(lines[3].substring(0, 10));
    expect(s.substring(obj1Offset).startsWith('1 0 obj'), isTrue);
  });

  test('issuable chrome adds the sheet counter + legend/scale/north', () {
    final s = latin1.decode(planToPdf(
      net: net,
      sizing: sizing,
      edgeLengths: lengths,
      sheetId: 's1',
      floorIndex: 0,
      projectName: 'Tower A',
      sheetName: 'Ground Floor',
      dateString: '2026-06-27',
      chrome: const DrawingChrome(
        drawingNumber: 'M-101',
        revisionNumber: 'Rev. C',
        sheetIndex: 3,
        sheetTotal: 8,
        legendServices: [ServiceType.coldWater],
      ),
    ));
    expect(s, contains('Sheet 3 of 8')); // on the sheet-name title line
    expect(s, contains('(M-101) Tj'));
    expect(s, contains('(LEGEND) Tj'));
    expect(s, contains('(N) Tj'));
  });

  test('null chrome leaves the bytes byte-identical', () {
    expect(build(), equals(build()));
  });

  test('an empty floor still produces a valid (title-only) page', () {
    final bytes = planToPdf(
      net: const Network(),
      sizing: const {},
      edgeLengths: const {},
      sheetId: 'nope',
      floorIndex: 9,
      projectName: 'Empty Project',
      sheetName: 'Nothing',
      dateString: '2026-01-01',
    );
    expect(bytes, isNotEmpty);
    final s = latin1.decode(bytes);
    expect(s.startsWith('%PDF-1.4'), isTrue);
    expect(s, contains('(Empty Project) Tj'));
    expect(s.trimRight().endsWith('%%EOF'), isTrue);
  });
}
