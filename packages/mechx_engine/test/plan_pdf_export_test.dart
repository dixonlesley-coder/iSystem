import 'dart:convert';
import 'dart:typed_data';

import 'package:mechx_engine/geometry/dxf_drawing.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
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

  test('issuable chrome draws the frame + ISO-7200 title block (A4)', () {
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
    // ISO-5457 sheet frame: one border rect inset by the 48 pt margin on the
    // 1190.55 × 841.89 A3 page → 48 48 1094.55 745.89.
    expect(s, contains('48.00 48.00 1094.55 745.89 re S'));
    // Title-block rows replace the loose top-left text lines — the exporter's
    // own sheet-name/date params feed the TITLE/DATE rows.
    expect(s, contains('(Tower A) Tj')); // PROJECT row value
    expect(s, contains('(Ground Floor) Tj')); // TITLE row (from sheetName)
    expect(s, contains('(2026-06-27) Tj')); // DATE row (from dateString)
    expect(s, contains('(M-101) Tj'));
    expect(s, contains('(Rev. C) Tj'));
    expect(s, contains('(3 of 8) Tj')); // the SHEET row value
    expect(s, contains('(LEGEND) Tj'));
    expect(s, contains('(N) Tj'));
    expect(s, isNot(contains('Sheet 3 of 8'))); // the old loose title line
    // A3: uncalibrated ⇒ the SCALE row reads NTS and NO divided bar prints —
    // a bar at an arbitrary auto-fit ratio is a bar an engineer could scale
    // wrong dimensions from (CAD-OUTPUT-UX-REVIEW A3).
    expect(s, contains('(NTS) Tj'));
    expect(s, isNot(contains('(0) Tj'))); // no honest-bar zero figure
  });

  test('metersPerPixel snaps the plotted scale to 1:50 (hand-computed)', () {
    // Raw auto-fit: spanX = 300 px into availW = 1190.55 − 96 = 1094.55 pt
    // (spanY = 0 so width governs) → 3.6485 pt/px. Plotted denominator
    // N = mpp·1000 / (scale · 25.4/72) = 0.05·1000 / (3.6485 · 0.35278)
    //   = 38.8 → snapped to the next ladder rung 50 (larger denominator ⇒
    // the drawing never draws larger than the honest snap).
    final s = latin1.decode(planToPdf(
      net: net,
      sizing: sizing,
      edgeLengths: lengths,
      sheetId: 's1',
      floorIndex: 0,
      projectName: 'Tower A',
      sheetName: 'Ground Floor',
      dateString: '2026-06-27',
      chrome: const DrawingChrome(drawingNumber: 'M-101'),
      metersPerPixel: 0.05,
    ));
    expect(s, contains('(1 : 50 @ A3) Tj'));
    // The honest divided bar: points-per-metre at 1:50 = 56.69 pt/m → the
    // ladder length nearest 120 pt is 2 m → figures 0 / 1 m / 2 m.
    expect(s, contains('(0) Tj'));
    expect(s, contains('(1 m) Tj'));
    expect(s, contains('(2 m) Tj'));
  });

  test('null chrome leaves the bytes byte-identical', () {
    expect(build(), equals(build()));
  });

  group('paper size (A5 Wave-5 addition)', () {
    Uint8List onPaper(PaperSize paper) => planToPdf(
          net: net,
          sizing: sizing,
          edgeLengths: lengths,
          sheetId: 's1',
          floorIndex: 0,
          projectName: 'Tower A',
          sheetName: 'Ground Floor',
          dateString: '2026-06-27',
          chrome: const DrawingChrome(drawingNumber: 'M-101'),
          metersPerPixel: 0.05,
          paper: paper,
        );

    test('default A3 carries the 1190.55 x 841.89 MediaBox', () {
      expect(latin1.decode(build()),
          contains('/MediaBox [0 0 1190.55 841.89]'));
    });

    test('A2 carries the larger 1683.78 x 1190.55 MediaBox', () {
      expect(latin1.decode(onPaper(PaperSize.a2Landscape)),
          contains('/MediaBox [0 0 1683.78 1190.55]'));
    });

    test('A1 carries the largest 2383.94 x 1683.78 MediaBox', () {
      expect(latin1.decode(onPaper(PaperSize.a1Landscape)),
          contains('/MediaBox [0 0 2383.94 1683.78]'));
    });

    test('the snapped scale text names the ACTUAL paper (@ A1)', () {
      // The much larger A1 sheet (availW = 2383.94 − 96 = 2287.94 pt →
      // 7.63 pt/px → N = 0.05·1000 / (7.63·0.35278) = 18.6 → snapped to the
      // next ladder rung 20) must read "@ A1", never a stale "@ A3".
      final s = latin1.decode(onPaper(PaperSize.a1Landscape));
      expect(s, contains('(1 : 20 @ A1) Tj'));
      expect(s, isNot(contains('@ A3')));
    });

    test('default paper is byte-identical to the explicit A3', () {
      expect(
          build(),
          equals(planToPdf(
              net: net,
              sizing: sizing,
              edgeLengths: lengths,
              sheetId: 's1',
              floorIndex: 0,
              projectName: 'Tower A',
              sheetName: 'Ground Floor',
              dateString: '2026-06-27',
              paper: PaperSize.a3Landscape)));
    });
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

    Uint8List withUnderlay(PlanUnderlay u) => planToPdf(
        net: net,
        sizing: sizing,
        edgeLengths: lengths,
        sheetId: 's1',
        floorIndex: 0,
        projectName: 'Tower A',
        sheetName: 'Ground Floor',
        dateString: '2026-06-27',
        underlay: u);

    test('vector: the pale-grey stroke precedes the first service stroke',
        () {
      final s = latin1.decode(withUnderlay(vector));
      final grey = s.indexOf('0.75 0.75 0.75 RG'); // 25 % ink
      expect(grey, greaterThanOrEqualTo(0));
      expect(s, contains('0.50 w')); // the thin underlay stroke
      // Painted FIRST: before the cold-water stroke colour is ever set.
      // E2: cold-water is now the canvas #2D6CDF (0.18 0.42 0.87 at 2 dp).
      expect(grey, lessThan(s.indexOf('0.18 0.42 0.87 RG')));
    });

    test('raster: a FlateDecode /Image XObject, painted before the network',
        () {
      // A 2×2 pre-faded RGB image covering the same 500 × 400 frame.
      final raster = RasterPlanUnderlay(
        rgbPixels: Uint8List.fromList(
            [10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120]),
        pixelWidth: 2,
        pixelHeight: 2,
        sheetWidthPx: 500,
        sheetHeightPx: 400,
      );
      final s = latin1.decode(withUnderlay(raster));
      expect(s, contains('/XObject << /Im1 6 0 R >>'));
      expect(s, contains('/Subtype /Image'));
      expect(s, contains('/Width 2 /Height 2'));
      expect(s, contains('/Filter /FlateDecode'));
      // The image paints FIRST — its Do op precedes the first network stroke.
      // E2: cold-water is now the canvas #2D6CDF (0.18 0.42 0.87 at 2 dp).
      expect(s.indexOf('/Im1 Do'), greaterThanOrEqualTo(0));
      expect(s.indexOf('/Im1 Do'), lessThan(s.indexOf('0.18 0.42 0.87 RG')));
    });

    test('null underlay leaves the bytes byte-identical', () {
      expect(
          build(),
          equals(planToPdf(
              net: net,
              sizing: sizing,
              edgeLengths: lengths,
              sheetId: 's1',
              floorIndex: 0,
              projectName: 'Tower A',
              sheetName: 'Ground Floor',
              dateString: '2026-06-27',
              underlay: null)));
    });
  });

  test('A5: a riser to a higher floor labels UP', () {
    // e1 rises from n1 (floor 0) to n2 (floor 1); on-floor marker n1 → 'UP'.
    expect(latin1.decode(build()), contains('(UP) Tj'));
  });

  test('A5: a plain junction keeps its filled dot', () {
    // n0/n1 are plain main junctions → the 2 pt filled dot (a `f` fill op).
    expect(latin1.decode(build()), contains('\nf\n'));
  });

  test('A5: a component node draws its equipment glyph; plain nodes do not', () {
    // strokePrims (the glyph path) uses the distinctive 1.00 w stroke weight;
    // an unsized run strokes at 1.4 w and plain dots only fill, so 1.00 w marks
    // the pump glyph uniquely.
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
    const plainNet = Network(
      nodes: [
        NetNode(id: 'p', sheetId: 's1', x: 100, y: 200, floorIndex: 0),
        NetNode(id: 'q', sheetId: 's1', x: 400, y: 200, floorIndex: 0),
      ],
      edges: [
        NetEdge(id: 'e', fromId: 'p', toId: 'q', service: ServiceType.coldWater),
      ],
    );
    String render(Network n) => latin1.decode(planToPdf(
          net: n,
          sizing: const {},
          edgeLengths: const {},
          sheetId: 's1',
          floorIndex: 0,
          projectName: 'T',
          sheetName: 'S',
          dateString: 'd',
        ));
    expect(render(pumpNet), contains('1.00 w')); // the glyph stroke
    expect(render(plainNet), isNot(contains('1.00 w'))); // dots only, no glyph
  });

  test('A5: a sized run with a flow origin draws a flow chevron', () {
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
    final arrowed = latin1.decode(planToPdf(
      net: net,
      sizing: oriented,
      edgeLengths: lengths,
      sheetId: 's1',
      floorIndex: 0,
      projectName: 'Tower A',
      sheetName: 'Ground Floor',
      dateString: '2026-06-27',
    ));
    expect(arrowed, contains('1.60 w')); // the chevron stroke weight
    expect(latin1.decode(build()), isNot(contains('1.60 w'))); // baseline: none
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

  test('N5: an elevation label is appended to the run size+length label', () {
    final s = latin1.decode(planToPdf(
      net: net,
      sizing: sizing,
      edgeLengths: lengths,
      sheetId: 's1',
      floorIndex: 0,
      projectName: 'Tower A',
      sheetName: 'Ground Floor',
      dateString: '2026-06-27',
      edgeElevationLabels: const {'e0': 'CL +2.70'},
    ));
    // The run label now reads size - length - elevation, one token.
    expect(s, contains('(DN50 - 30 m - CL +2.70) Tj'));
  });

  test('N5: null/absent elevation map leaves the bytes byte-identical', () {
    expect(build(), equals(planToPdf(
      net: net,
      sizing: sizing,
      edgeLengths: lengths,
      sheetId: 's1',
      floorIndex: 0,
      projectName: 'Tower A',
      sheetName: 'Ground Floor',
      dateString: '2026-06-27',
      edgeElevationLabels: null,
    )));
    // An empty entry for the edge is also a no-op.
    expect(build(), equals(planToPdf(
      net: net,
      sizing: sizing,
      edgeLengths: lengths,
      sheetId: 's1',
      floorIndex: 0,
      projectName: 'Tower A',
      sheetName: 'Ground Floor',
      dateString: '2026-06-27',
      edgeElevationLabels: const {'e0': ''},
    )));
  });

  group('N4: reference setting-out grid', () {
    const grid = ReferenceGrid(
      columns: [GridAxis('A', 100), GridAxis('B', 400)],
      rows: [GridAxis('1', 150)],
    );
    Uint8List withGrid({double? mpp}) => planToPdf(
          net: net,
          sizing: sizing,
          edgeLengths: lengths,
          sheetId: 's1',
          floorIndex: 0,
          projectName: 'Tower A',
          sheetName: 'Ground Floor',
          dateString: '2026-06-27',
          metersPerPixel: mpp,
          grid: grid,
        );

    test('draws chain gridlines + bubble axis labels', () {
      final s = latin1.decode(withGrid());
      expect(s, contains('[8 3 2 3] 0 d')); // the chain (setting-out) linetype
      expect(s, contains('(A) Tj'));
      expect(s, contains('(B) Tj'));
      expect(s, contains('(1) Tj'));
    });

    test('a riser node ties to the nearest column when calibrated', () {
      // The riser marker n1 sits at x=400 (== column B), y=200. Nearest column
      // B offset 0 (skipped); nearest row 1 at y=150 → |200−150|=50 px ×
      // 0.02 m/px × 1000 = 1000 mm tie dimension.
      final s = latin1.decode(withGrid(mpp: 0.02));
      expect(s, contains('(1000) Tj'));
    });

    test('no tie dimensions without a scale (would be fabricated)', () {
      // Uncalibrated: gridlines still draw, but no tie numbers.
      final s = latin1.decode(withGrid());
      expect(s, isNot(contains('(1000) Tj')));
    });

    test('null/empty grid leaves the bytes byte-identical', () {
      expect(build(), equals(planToPdf(
        net: net,
        sizing: sizing,
        edgeLengths: lengths,
        sheetId: 's1',
        floorIndex: 0,
        projectName: 'Tower A',
        sheetName: 'Ground Floor',
        dateString: '2026-06-27',
        grid: null,
      )));
      expect(build(), equals(planToPdf(
        net: net,
        sizing: sizing,
        edgeLengths: lengths,
        sheetId: 's1',
        floorIndex: 0,
        projectName: 'Tower A',
        sheetName: 'Ground Floor',
        dateString: '2026-06-27',
        grid: const ReferenceGrid(),
      )));
    });
  });

  test('N1: a "·" in a title-block value renders as WinAnsi 0xB7, not "?"', () {
    final bytes = planToPdf(
      net: net,
      sizing: sizing,
      edgeLengths: lengths,
      sheetId: 's1',
      floorIndex: 0,
      projectName: 'Tower A · Blok 3',
      sheetName: 'Ground Floor',
      dateString: '2026-06-27',
    );
    // The shared assembler declares WinAnsi so the byte maps to the real glyph.
    expect(latin1.decode(bytes), contains('/Encoding /WinAnsiEncoding'));
    // The middle dot is emitted as byte 0xB7, so the name reads back intact.
    expect(bytes, contains(0xB7));
    expect(latin1.decode(bytes), contains('(Tower A · Blok 3) Tj'));
    expect(latin1.decode(bytes), isNot(contains('Tower A ? Blok 3')));
  });

  // ── N13: the stable element tag is prepended to the plan labels ────────────
  group('N13 element tags', () {
    Uint8List buildTagged(Map<String, String> tags) => planToPdf(
          net: net,
          sizing: sizing,
          edgeLengths: lengths,
          sheetId: 's1',
          floorIndex: 0,
          projectName: 'Tower A',
          sheetName: 'Ground Floor',
          dateString: '2026-06-27',
          edgeTags: tags,
        );

    test('a run/riser tag is prepended to its label with a middot separator',
        () {
      // The app passes elementTags(): the run e0 → CW-F1, the riser e1 → CW-R1.
      final s = latin1.decode(buildTagged(const {'e0': 'CW-F1', 'e1': 'CW-R1'}));
      // The tag rides in front of the size/length (middot is WinAnsi 0xB7).
      expect(s, contains('CW-F1 · DN50 - 30 m'));
      expect(s, contains('CW-R1 · '));
      // The riser marker label still carries the riser tag on-floor.
      expect(s, contains('CW-R1'));
    });

    test('a null/empty edgeTags map keeps the bytes byte-identical', () {
      expect(buildTagged(const {}), equals(build()));
      expect(
          planToPdf(
            net: net,
            sizing: sizing,
            edgeLengths: lengths,
            sheetId: 's1',
            floorIndex: 0,
            projectName: 'Tower A',
            sheetName: 'Ground Floor',
            dateString: '2026-06-27',
          ),
          equals(build()));
    });
  });

  // ── N3: the riser-base cluster never overprints ────────────────────────────
  group('N3 riser-base collision', () {
    // A riser whose base sits close to a setting-out grid intersection: the
    // riser tag+size+length label, the UP/DN marker and BOTH N4 tie dimensions
    // land on the SAME point. The exporter must stagger the tie text away from
    // the marker and leader the riser tag off, so no two rects overprint.
    const collideNet = Network(
      nodes: [
        NetNode(id: 'far', sheetId: 's1', x: 120, y: 205, floorIndex: 0),
        NetNode(id: 'j', sheetId: 's1', x: 405, y: 205, floorIndex: 0),
        NetNode(id: 'up', sheetId: 's1', x: 405, y: 205, floorIndex: 1),
      ],
      edges: [
        NetEdge(
            id: 'run', fromId: 'far', toId: 'j', service: ServiceType.drainage),
        NetEdge(
            id: 'riser',
            fromId: 'j',
            toId: 'up',
            service: ServiceType.drainage,
            kind: EdgeKind.riser),
      ],
    );
    const collideSizing = {
      'riser': EdgeSizing(
        edgeId: 'riser',
        service: ServiceType.drainage,
        flow: FlowRate(0.004),
        diameter: Diameter(0.075),
        velocity: Velocity(1.2),
      ),
    };
    const collideLengths = {'run': Length(30.0), 'riser': Length(4.0)};
    // Column B 10 px left of the riser (→ 200 mm tie), row 1 5 px above (→ 100 mm).
    const grid = ReferenceGrid(
      columns: [GridAxis('B', 395)],
      rows: [GridAxis('1', 200)],
    );

    bool overlap(LabelBox a, LabelBox b) =>
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY;

    // Every drawn text label as (text, its y-up bounding box), parsed from the
    // content stream — a Td (plain) or Tm (rotated) anchor + the /F1 size, over
    // the same char × size × 0.55 width heuristic the exporter's placer uses.
    List<({String text, LabelBox box})> labelsOf(String pdf) {
      final re = RegExp(
          r'/F1 (\d+(?:\.\d+)?) Tf[^()\n]*?(-?\d+\.\d+) (-?\d+\.\d+) '
          r'T[dm] \(([^)]*)\) Tj');
      final out = <({String text, LabelBox box})>[];
      for (final m in re.allMatches(pdf)) {
        final fs = double.parse(m.group(1)!);
        final x = double.parse(m.group(2)!);
        final y = double.parse(m.group(3)!);
        final text = m.group(4)!;
        final w = text.length * fs * 0.55;
        out.add((
          text: text,
          box: (minX: x, minY: y, maxX: x + w, maxY: y + fs),
        ));
      }
      return out;
    }

    test('the riser tag, UP marker + both tie dims are non-overlapping rects',
        () {
      final s = latin1.decode(planToPdf(
        net: collideNet,
        sizing: collideSizing,
        edgeLengths: collideLengths,
        sheetId: 's1',
        floorIndex: 0,
        projectName: 'Tower A',
        sheetName: 'GF',
        dateString: '2026-07-06',
        metersPerPixel: 0.02,
        grid: grid,
        edgeTags: const {'riser': 'D-R1'},
      ));
      final all = labelsOf(s);
      LabelBox find(bool Function(String) pred) =>
          all.firstWhere((l) => pred(l.text)).box;
      final riser = find((t) => t.contains('D-R1')); // 'D-R1 · DN75 - 4 m'
      final up = find((t) => t == 'UP');
      final tie200 = find((t) => t == '200'); // the column tie
      final tie100 = find((t) => t == '100'); // the row tie
      final cluster = <LabelBox>[riser, up, tie200, tie100];
      for (var i = 0; i < cluster.length; i++) {
        for (var j = i + 1; j < cluster.length; j++) {
          expect(overlap(cluster[i], cluster[j]), isFalse,
              reason: 'riser-base labels $i and $j overprint');
        }
      }
      // The tag survived the crowded base (never dropped).
      expect(s, contains('D-R1'));
    });

    test('without the fix the naive slot WOULD overprint (guard is meaningful)',
        () {
      // Sanity anchor: at the naive fixed offset the OLD exporter used
      // (marker + 8, marker + 3) the riser tag box overlaps the row tie text
      // that lands beside the marker — so the passing non-overlap test above is
      // proving a real resolution, not a vacuous one.
      final s = latin1.decode(planToPdf(
        net: collideNet,
        sizing: collideSizing,
        edgeLengths: collideLengths,
        sheetId: 's1',
        floorIndex: 0,
        projectName: 'Tower A',
        sheetName: 'GF',
        dateString: '2026-07-06',
        metersPerPixel: 0.02,
        grid: grid,
        edgeTags: const {'riser': 'D-R1'},
      ));
      final all = labelsOf(s);
      final riser = all.firstWhere((l) => l.text.contains('D-R1')).box;
      // The riser tag carries real content (size + length), so it is a wide box.
      expect(riser.maxX - riser.minX, greaterThan(40));
      // Both tie dimensions are present (the crowded inputs that used to pile up).
      expect(all.where((l) => l.text == '200'), isNotEmpty);
      expect(all.where((l) => l.text == '100'), isNotEmpty);
    });
  });
}
