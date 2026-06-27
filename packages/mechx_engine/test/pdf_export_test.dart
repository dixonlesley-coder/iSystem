import 'dart:convert';
import 'dart:typed_data';

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/pdf_export.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
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

  Uint8List build() => networkToPdf(
        net: net,
        sizing: sizing,
        sheetId: 's1',
        floorIndex: 0,
        title: 'Ground Floor (cold)',
      );

  test('emits a well-formed single-page PDF', () {
    final bytes = build();
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

  test('draws the on-floor run (line + size label) and the riser marker', () {
    final s = latin1.decode(build());
    expect(s, contains(' l S')); // a stroked line segment
    expect(s, contains('DN50')); // the size label for e0
    expect(s, contains(' c\n')); // a bezier curve (the riser circle marker)
    // Title stamp — the PDF string metacharacters '()' are backslash-escaped.
    expect(s, contains(r'Ground Floor \(cold\)'));
  });

  test('the cross-reference offsets actually point at their objects', () {
    final bytes = build();
    final s = latin1.decode(bytes);
    // startxref → byte offset of the xref table.
    final sx = s.lastIndexOf('startxref');
    final xrefOffset =
        int.parse(s.substring(sx + 'startxref'.length, s.indexOf('%%EOF', sx)).trim());
    expect(s.substring(xrefOffset, xrefOffset + 4), 'xref');
    // Parse the xref entries and confirm object 1 begins with "1 0 obj".
    final lines = s.substring(xrefOffset).split('\n');
    // lines[0] = 'xref', lines[1] = '0 6', lines[2] = free entry, lines[3] = obj1
    final obj1Offset = int.parse(lines[3].substring(0, 10));
    expect(s.substring(obj1Offset).startsWith('1 0 obj'), isTrue);
  });

  test('issuable chrome stamps legend / scale / north / revision block', () {
    final s = latin1.decode(networkToPdf(
      net: net,
      sizing: sizing,
      sheetId: 's1',
      floorIndex: 0,
      title: 'Ground Floor (cold)',
      chrome: const DrawingChrome(
        drawingNumber: 'M-101',
        revisionNumber: 'Rev. A',
        sheetIndex: 1,
        sheetTotal: 4,
        legendServices: [ServiceType.coldWater],
        scaleBarLabel: '1 : 100',
      ),
    ));
    expect(s, contains('(M-101) Tj'));
    expect(s, contains('(Sheet 1 of 4) Tj'));
    expect(s, contains('(LEGEND) Tj'));
    expect(s, contains('(SCALE  1 : 100) Tj'));
    expect(s, contains('(N) Tj'));
  });

  test('null chrome leaves the bytes byte-identical', () {
    expect(build(),
        equals(networkToPdf(
            net: net,
            sizing: sizing,
            sheetId: 's1',
            floorIndex: 0,
            title: 'Ground Floor (cold)',
            chrome: null)));
  });

  test('an empty floor still produces a valid (title-only) page', () {
    final bytes = networkToPdf(
      net: net,
      sizing: const {},
      sheetId: 'nope',
      floorIndex: 9,
      title: 'Empty',
    );
    final s = latin1.decode(bytes);
    expect(s.startsWith('%PDF-1.4'), isTrue);
    expect(s, contains('(Empty) Tj'));
    expect(s.trimRight().endsWith('%%EOF'), isTrue);
  });
}
