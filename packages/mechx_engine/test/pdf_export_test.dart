import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';

import 'package:mechx_engine/geometry/dxf_drawing.dart';
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

  test('issuable chrome draws the frame + ISO-7200 title block (A4)', () {
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
    // ISO-5457 sheet frame: one border rect inset by the 48 pt margin on the
    // 1190.55 × 841.89 A3 page → 48 48 1094.55 745.89.
    expect(s, contains('48.00 48.00 1094.55 745.89 re S'));
    // Title-block rows (label + value cells) replace the loose corner text.
    expect(s, contains('(PROJECT) Tj'));
    expect(s, contains(r'(Ground Floor \(cold\)) Tj'));
    expect(s, contains('(M-101) Tj'));
    expect(s, contains('(Rev. A) Tj'));
    expect(s, contains('(1 of 4) Tj')); // the SHEET row value
    expect(s, contains('(LEGEND) Tj'));
    expect(s, contains('(N) Tj'));
    // A3: uncalibrated ⇒ the SCALE row reads NTS and NO divided bar prints —
    // a bar at an arbitrary auto-fit ratio is a bar an engineer could scale
    // wrong dimensions from (CAD-OUTPUT-UX-REVIEW A3).
    expect(s, contains('(NTS) Tj'));
    expect(s, isNot(contains('(SCALE  1 : 100) Tj')));
    expect(s, isNot(contains('(0) Tj'))); // no honest-bar zero figure either
  });

  test('metersPerPixel snaps the plotted scale to 1:50 (hand-computed)', () {
    // Raw auto-fit: spanX = 300 px into availW = 1190.55 − 96 = 1094.55 pt
    // (spanY = 0 so width governs) → 3.6485 pt/px. Plotted denominator
    // N = mpp·1000 / (scale · 25.4/72) = 0.05·1000 / (3.6485 · 0.35278)
    //   = 38.8 → snapped to the next ladder rung 50 (larger denominator ⇒
    // the drawing never draws larger than the honest snap).
    final s = latin1.decode(networkToPdf(
      net: net,
      sizing: sizing,
      sheetId: 's1',
      floorIndex: 0,
      title: 'Ground Floor (cold)',
      chrome: const DrawingChrome(drawingNumber: 'M-101'),
      metersPerPixel: 0.05,
    ));
    expect(s, contains('(1 : 50 @ A3) Tj'));
    // The honest divided bar: points-per-metre at 1:50 = (0.05·1000·72 /
    // (50·25.4)) / 0.05 = 56.69 pt/m → the ladder length nearest 120 pt is
    // 2 m (113.4 pt) → figures 0 / 1 m / 2 m.
    expect(s, contains('(0) Tj'));
    expect(s, contains('(1 m) Tj'));
    expect(s, contains('(2 m) Tj'));
  });

  group('paper size (A5 Wave-5 addition)', () {
    // A3 (default) MediaBox from the historical constants.
    test('default A3 carries the 1190.55 x 841.89 MediaBox', () {
      final s = latin1.decode(build());
      expect(s, contains('/MediaBox [0 0 1190.55 841.89]'));
    });

    test('A2 carries the larger 1683.78 x 1190.55 MediaBox', () {
      final s = latin1.decode(networkToPdf(
        net: net,
        sizing: sizing,
        sheetId: 's1',
        floorIndex: 0,
        title: 'Ground Floor (cold)',
        paper: PaperSize.a2Landscape,
      ));
      expect(s, contains('/MediaBox [0 0 1683.78 1190.55]'));
    });

    test('A1 carries the largest 2383.94 x 1683.78 MediaBox', () {
      final s = latin1.decode(networkToPdf(
        net: net,
        sizing: sizing,
        sheetId: 's1',
        floorIndex: 0,
        title: 'Ground Floor (cold)',
        paper: PaperSize.a1Landscape,
      ));
      expect(s, contains('/MediaBox [0 0 2383.94 1683.78]'));
    });

    test('the snapped scale text names the ACTUAL paper (@ A2)', () {
      // The larger A2 sheet still snaps the same 300-px run — the raw fit at
      // A2 is bigger (availW = 1683.78 − 96 = 1587.78 pt → 5.29 pt/px →
      // N = 0.05·1000 / (5.29·0.35278) = 26.8 → snapped to 50) — so the SCALE
      // row must read "@ A2", never a stale "@ A3".
      final s = latin1.decode(networkToPdf(
        net: net,
        sizing: sizing,
        sheetId: 's1',
        floorIndex: 0,
        title: 'Ground Floor (cold)',
        chrome: const DrawingChrome(drawingNumber: 'M-101'),
        metersPerPixel: 0.05,
        paper: PaperSize.a2Landscape,
      ));
      expect(s, contains('(1 : 50 @ A2) Tj'));
      expect(s, isNot(contains('@ A3')));
    });

    test('default paper is byte-identical to the explicit A3', () {
      expect(
          build(),
          equals(networkToPdf(
              net: net,
              sizing: sizing,
              sheetId: 's1',
              floorIndex: 0,
              title: 'Ground Floor (cold)',
              paper: PaperSize.a3Landscape)));
    });
  });

  test('A6: the DN50 run strokes at the small band 1.0 w', () {
    // DN50 → pipe band small (DN <= 50) → kPdfStrokeWidths[0] = 1.0.
    final s = latin1.decode(build());
    expect(s, contains('1.00 w'));
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

  test('A5: a riser to a higher floor labels UP', () {
    // e1 rises from n1 (floor 0) to n2 (floor 1); the on-floor marker is n1,
    // whose other endpoint is higher → 'UP'.
    final s = latin1.decode(build());
    expect(s, contains('(UP) Tj'));
  });

  test('A5: a component node draws its equipment glyph (a pump circle)', () {
    // A run with a pump node and NO riser — so the only bezier curve in the
    // stream must come from the pump body circle (this exporter never dots a
    // plain junction), proving the equipment glyph is drawn.
    const pumpNet = Network(
      nodes: [
        NetNode(id: 'p', sheetId: 's1', x: 100, y: 200, floorIndex: 0,
            role: NodeRole.plant, component: NodeComponent.pump),
        NetNode(id: 'q', sheetId: 's1', x: 400, y: 200, floorIndex: 0),
      ],
      edges: [
        NetEdge(id: 'e', fromId: 'p', toId: 'q', service: ServiceType.coldWater),
      ],
    );
    final s = latin1.decode(networkToPdf(
        net: pumpNet, sizing: const {}, sheetId: 's1', floorIndex: 0,
        title: 'Pump'));
    expect(s, contains(' c\n')); // a bezier curve → the pump body circle
  });

  test('A5: a sized run with a flow origin draws a flow chevron', () {
    // e0 gets a flowFromId (n0 upstream); its 300-px run is far longer than the
    // 30-pt threshold, so a chevron is stroked at the distinctive 1.60 w.
    const oriented = {
      'e0': EdgeSizing(
        edgeId: 'e0',
        service: ServiceType.coldWater,
        flow: FlowRate(0.005),
        diameter: Diameter(0.05),
        velocity: Velocity(1.8),
        flowFromId: 'n0',
      ),
    };
    final withArrow = latin1.decode(networkToPdf(
        net: net, sizing: oriented, sheetId: 's1', floorIndex: 0, title: 'x'));
    expect(withArrow, contains('1.60 w')); // the chevron stroke weight
    // The baseline (flowFromId null) draws no chevron.
    expect(latin1.decode(build()), isNot(contains('1.60 w')));
  });

  group('A1 floor-plan underlay', () {
    // Vector fixture: a plan spanning world (0,0)–(100,80) fitted into a
    // 500 × 400 sheet-pixel frame → k = 500/100 = 5 (the canvas fit).
    const vector = VectorPlanUnderlay(
      drawing: DxfDrawing(
        polylines: [
          DxfPolyline([DxfPoint(0, 0), DxfPoint(100, 80)]),
        ],
        circles: [],
        arcs: [],
        bounds: DxfBounds(0, 0, 100, 80),
      ),
      sheetWidthPx: 500,
      sheetHeightPx: 400,
    );

    // Raster fixture: a 2×2 RGB image covering the same 500 × 400 frame.
    final rgb = Uint8List.fromList(
        [10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120]);
    final raster = RasterPlanUnderlay(
      rgbPixels: rgb,
      pixelWidth: 2,
      pixelHeight: 2,
      sheetWidthPx: 500,
      sheetHeightPx: 400,
    );

    Uint8List withUnderlay(PlanUnderlay u) => networkToPdf(
        net: net,
        sizing: sizing,
        sheetId: 's1',
        floorIndex: 0,
        title: 'Ground Floor (cold)',
        underlay: u);

    test('vector: the pale-grey stroke precedes the first service stroke',
        () {
      final s = latin1.decode(withUnderlay(vector));
      final grey = s.indexOf('0.75 0.75 0.75 RG'); // 25 % ink
      expect(grey, greaterThanOrEqualTo(0));
      expect(s, contains('0.50 w')); // the thin underlay stroke
      // Painted FIRST: before the cold-water stroke colour is ever set.
      expect(grey, lessThan(s.indexOf('0.13 0.45 0.85 RG')));
    });

    test('raster: a FlateDecode /Image XObject, painted before the network',
        () {
      final bytes = withUnderlay(raster);
      final s = latin1.decode(bytes);
      expect(s, contains('/XObject << /Im1 6 0 R >>'));
      expect(s, contains('/Subtype /Image'));
      expect(s, contains('/Width 2 /Height 2'));
      expect(s, contains('/ColorSpace /DeviceRGB'));
      expect(s, contains('/Filter /FlateDecode'));
      // The image paints FIRST — its Do op precedes the first network stroke.
      expect(s.indexOf('/Im1 Do'), greaterThanOrEqualTo(0));
      expect(s.indexOf('/Im1 Do'), lessThan(s.indexOf('0.13 0.45 0.85 RG')));
    });

    test('raster: the image stream is the zlib-deflated RGB rows (verbatim)',
        () {
      final bytes = withUnderlay(raster);
      final s = latin1.decode(bytes); // latin1 is byte-1:1, indices match
      final dictIdx = s.indexOf('/Subtype /Image');
      final n = int.parse(RegExp(r'/Length (\d+) >>')
          .firstMatch(s.substring(dictIdx))!
          .group(1)!);
      final streamStart = s.indexOf('stream\n', dictIdx) + 'stream\n'.length;
      final deflated = bytes.sublist(streamStart, streamStart + n);
      // FlateDecode = zlib-wrapped DEFLATE; the engine embedded the app's
      // pre-faded pixels verbatim, so the round-trip is exact.
      expect(zlib.decode(deflated), equals(rgb));
    });

    test('raster: the xref offsets still point at their objects (incl. 6)',
        () {
      final bytes = withUnderlay(raster);
      final s = latin1.decode(bytes);
      final sx = s.lastIndexOf('startxref');
      final xrefOffset = int.parse(
          s.substring(sx + 'startxref'.length, s.indexOf('%%EOF', sx)).trim());
      expect(s.substring(xrefOffset, xrefOffset + 4), 'xref');
      final lines = s.substring(xrefOffset).split('\n');
      // lines[0]='xref', [1]='0 7', [2]=free, [3..8]=objects 1..6.
      final obj1Offset = int.parse(lines[3].substring(0, 10));
      expect(s.substring(obj1Offset).startsWith('1 0 obj'), isTrue);
      final obj6Offset = int.parse(lines[8].substring(0, 10));
      expect(s.substring(obj6Offset).startsWith('6 0 obj'), isTrue);
    });

    test('null underlay leaves the bytes byte-identical', () {
      expect(
          build(),
          equals(networkToPdf(
              net: net,
              sizing: sizing,
              sheetId: 's1',
              floorIndex: 0,
              title: 'Ground Floor (cold)',
              underlay: null)));
    });
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

  group('A7 placeEdgeLabel (label rotation / offset / greedy collision)', () {
    // All cases: text 'DN50' (4 chars) at size 10 → estimated width
    // w = 4 × 10 × 0.55 = 22, perpendicular offset 0.7 × 10 = 7.

    test('horizontal edge: upright, offset 7 above, centred', () {
      final placed = <LabelBox>[];
      final p = placeEdgeLabel(
          ax: 0, ay: 0, bx: 100, by: 0,
          text: 'DN50', textSize: 10, placed: placed)!;
      // Baseline centre = midpoint (50,0) + 7 × upper-perp (0,1) = (50,7);
      // anchor = centre − w/2 along the bearing → (50−11, 7) = (39, 7).
      expect(p.angleDeg, closeTo(0, 1e-9));
      expect(p.x, closeTo(39, 1e-9));
      expect(p.y, closeTo(7, 1e-9));
      expect(placed, hasLength(1)); // the box was recorded
    });

    test('vertical edge: rotated +90 (reads bottom-to-top)', () {
      final placed = <LabelBox>[];
      final p = placeEdgeLabel(
          ax: 0, ay: 0, bx: 0, by: 100,
          text: 'DN50', textSize: 10, placed: placed)!;
      // Bearing +90 deg; upper-perp = (−1, 0) → baseline centre (−7, 50);
      // anchor slides w/2 = 11 back along the bearing (0,1) → (−7, 39).
      expect(p.angleDeg, closeTo(90, 1e-9));
      expect(p.x, closeTo(-7, 1e-9));
      expect(p.y, closeTo(39, 1e-9));
    });

    test('a steep down-left edge flips 180 to read upright', () {
      final placed = <LabelBox>[];
      final p = placeEdgeLabel(
          ax: 0, ay: 0, bx: -100, by: -100,
          text: 'DN50', textSize: 10, placed: placed)!;
      // atan2(−100, −100) = −135 deg → past −90 → flipped by +180 → +45.
      expect(p.angleDeg, closeTo(45, 1e-9));
    });

    test('collision tries the lower side, then slides to the quarter point',
        () {
      final placed = <LabelBox>[];
      // Three identical edges: mid-upper, then mid-lower (baseline displaced
      // −(0.7·10 + 10) = −17 so the box clears the line), then quarter-point
      // upper (anchor 25 − 11 = 14).
      final p1 = placeEdgeLabel(
          ax: 0, ay: 0, bx: 100, by: 0,
          text: 'DN50', textSize: 10, placed: placed)!;
      final p2 = placeEdgeLabel(
          ax: 0, ay: 0, bx: 100, by: 0,
          text: 'DN50', textSize: 10, placed: placed)!;
      final p3 = placeEdgeLabel(
          ax: 0, ay: 0, bx: 100, by: 0,
          text: 'DN50', textSize: 10, placed: placed)!;
      expect(p1.y, closeTo(7, 1e-9));
      expect(p2.y, closeTo(-17, 1e-9));
      expect(p2.x, closeTo(39, 1e-9));
      expect(p3.x, closeTo(14, 1e-9));
      expect(p3.y, closeTo(7, 1e-9));
      expect(placed, hasLength(3));
    });

    test('drops the label (null) when every candidate collides', () {
      final placed = <LabelBox>[
        (minX: -1000.0, minY: -1000.0, maxX: 1000.0, maxY: 1000.0),
      ];
      final p = placeEdgeLabel(
          ax: 0, ay: 0, bx: 100, by: 0,
          text: 'DN50', textSize: 10, placed: placed);
      expect(p, isNull);
      expect(placed, hasLength(1)); // nothing was recorded
    });
  });
}
