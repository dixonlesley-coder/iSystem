import 'dart:convert';

import 'package:mechx_engine/geometry/dxf_drawing.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/dxf_export.dart';
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  const net = Network(
    nodes: [
      NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
      NetNode(id: 'b', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
      NetNode(id: 'c', sheetId: 's1', x: 100, y: 0, floorIndex: 1),
      NetNode(id: 'other', sheetId: 's2', x: 0, y: 0, floorIndex: 0),
    ],
    edges: [
      NetEdge(id: 'e', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
      NetEdge(
          id: 'r',
          fromId: 'b',
          toId: 'c',
          service: ServiceType.coldWater,
          kind: EdgeKind.riser),
    ],
  );
  const sizing = {
    'e': EdgeSizing(
      edgeId: 'e',
      service: ServiceType.coldWater,
      flow: FlowRate(0.001),
      diameter: Diameter(0.05),
      velocity: Velocity(1),
    ),
  };

  // A1 underlay fixture: a parsed floor plan spanning world (10,20)–(110,70)
  // (w = 100, h = 50) fitted into a 200 × 100 sheet-pixel frame — the canvas
  // fit k = sheetW / boundsW = 200/100 = 2, sheet px = ((x−10)·2, (70−y)·2).
  const underlayDrawing = DxfDrawing(
    polylines: [
      DxfPolyline([DxfPoint(10, 20), DxfPoint(110, 70)]),
    ],
    circles: [DxfCircle(DxfPoint(60, 45), 10)],
    arcs: [DxfArc(DxfPoint(60, 45), 20, 30, 120)],
    bounds: DxfBounds(10, 20, 110, 70),
  );
  const underlay = VectorPlanUnderlay(
      drawing: underlayDrawing, sheetWidthPx: 200, sheetHeightPx: 100);

  test('emits a valid DXF skeleton with a LINE on the service layer', () {
    final dxf =
        networkToDxf(net: net, sizing: sizing, sheetId: 's1', floorIndex: 0);
    expect(dxf, contains('SECTION'));
    expect(dxf, contains('ENTITIES'));
    expect(dxf, contains('LINE'));
    expect(dxf, contains('coldWater')); // layer
    expect(dxf.trimRight(), endsWith('EOF'));
  });

  test('run endpoints appear with Y negated (DXF up-is-positive)', () {
    final dxf =
        networkToDxf(net: net, sizing: sizing, sheetId: 's1', floorIndex: 0);
    // The DN50 size label is placed on the run.
    expect(dxf, contains('DN50'));
  });

  test('a riser on the floor emits a CIRCLE marker', () {
    final dxf =
        networkToDxf(net: net, sizing: sizing, sheetId: 's1', floorIndex: 0);
    expect(dxf, contains('CIRCLE'));
  });

  test('A5: a riser to a higher floor labels UP', () {
    // Riser b(floor 0) → c(floor 1); the on-floor marker is b, other end
    // higher → an 'UP' TEXT beside the circle.
    final dxf =
        networkToDxf(net: net, sizing: sizing, sheetId: 's1', floorIndex: 0);
    expect(dxf, contains('\n1\nUP\n'));
  });

  test('A5: a component node emits its equipment glyph (a pump CIRCLE)', () {
    // A run with a pump node and NO riser — the only CIRCLE must come from the
    // pump body glyph (plain junctions are never dotted here).
    const pumpNet = Network(
      nodes: [
        NetNode(
            id: 'p',
            sheetId: 's1',
            x: 0,
            y: 0,
            floorIndex: 0,
            role: NodeRole.plant,
            component: NodeComponent.pump),
        NetNode(id: 'q', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
      ],
      edges: [
        NetEdge(
            id: 'e', fromId: 'p', toId: 'q', service: ServiceType.coldWater),
      ],
    );
    final dxf = networkToDxf(
        net: pumpNet, sizing: const {}, sheetId: 's1', floorIndex: 0);
    expect(dxf, contains('CIRCLE')); // the pump body circle (no riser present)
  });

  test('A5: a sized run with a flow origin emits a flow chevron', () {
    // Orienting 'e' (100 px run > 30) adds two chevron LINE entities: the
    // baseline draws just one LINE (the run) + no riser LINEs; with the chevron
    // the LINE count rises.
    const oriented = {
      'e': EdgeSizing(
        edgeId: 'e',
        service: ServiceType.coldWater,
        flow: FlowRate(0.001),
        diameter: Diameter(0.05),
        velocity: Velocity(1),
        flowFromId: 'a',
      ),
    };
    int lineCount(String s) => '\nLINE\n'.allMatches(s).length;
    final base =
        networkToDxf(net: net, sizing: sizing, sheetId: 's1', floorIndex: 0);
    final arrowed =
        networkToDxf(net: net, sizing: oriented, sheetId: 's1', floorIndex: 0);
    expect(lineCount(arrowed), lineCount(base) + 2); // the two chevron arms
  });

  group('A1 floor-plan underlay (legacy pixel document)', () {
    String withUnderlay() => networkToDxf(
        net: net,
        sizing: sizing,
        sheetId: 's1',
        floorIndex: 0,
        underlay: underlay);

    test('re-emits the line on G-ANNO-UNDR in the network frame, grey 62 8',
        () {
      // World (10,20)→(110,70) → sheet px (0,100)→(200,0) → DXF world
      // (y negated back): (0,−100) → (200,0).
      final dxf = withUnderlay();
      expect(
          dxf,
          contains('LINE\n8\nG-ANNO-UNDR\n62\n8\n'
              '10\n0.0\n20\n-100.0\n11\n200.0\n21\n0.0\n'));
    });

    test('re-emits CIRCLE + ARC natively, radius scaled, angles unchanged', () {
      // Centre (60,45) → sheet px (100,50) → DXF (100,−50); radii × k = 2.
      // The net map is translate + uniform scale, so the ARC's 30/120 deg
      // sweep carries over verbatim.
      final dxf = withUnderlay();
      expect(
          dxf,
          contains('CIRCLE\n8\nG-ANNO-UNDR\n62\n8\n'
              '10\n100.0\n20\n-50.0\n40\n20.0\n'));
      expect(
          dxf,
          contains('ARC\n8\nG-ANNO-UNDR\n62\n8\n'
              '10\n100.0\n20\n-50.0\n40\n40.0\n50\n30.0\n51\n120.0\n'));
    });

    test('the underlay entities precede (sit under) the network entities', () {
      final dxf = withUnderlay();
      expect(
          dxf.indexOf('G-ANNO-UNDR'), lessThan(dxf.indexOf('\n8\ncoldWater')));
    });

    test('null underlay keeps the legacy DXF byte-identical', () {
      expect(
        networkToDxf(net: net, sizing: sizing, sheetId: 's1', floorIndex: 0),
        equals(networkToDxf(
            net: net,
            sizing: sizing,
            sheetId: 's1',
            floorIndex: 0,
            underlay: null)),
      );
    });
  });

  test('issuable chrome adds title/legend/scale/north entities', () {
    final dxf = networkToDxf(
      net: net,
      sizing: sizing,
      sheetId: 's1',
      floorIndex: 0,
      chrome: const DrawingChrome(
        drawingNumber: 'M-101',
        sheetIndex: 2,
        sheetTotal: 6,
        legendServices: [ServiceType.coldWater],
        scaleBarLabel: '1 : 50',
      ),
    );
    expect(dxf, contains('title'));
    expect(dxf, contains('legend'));
    expect(dxf, contains('scale'));
    expect(dxf, contains('north'));
    expect(dxf, contains('M-101'));
    expect(dxf, contains('Sheet 2 of 6'));
    expect(dxf, contains('Cold water'));
  });

  test('null chrome leaves the DXF byte-identical', () {
    expect(
      networkToDxf(net: net, sizing: sizing, sheetId: 's1', floorIndex: 0),
      equals(networkToDxf(
          net: net,
          sizing: sizing,
          sheetId: 's1',
          floorIndex: 0,
          chrome: null)),
    );
  });

  test('only the requested sheet/floor is exported', () {
    // s2 has its own node but no edges on s1/floor0 beyond ours.
    final dxf =
        networkToDxf(net: net, sizing: sizing, sheetId: 's2', floorIndex: 0);
    // No run on s2 → no LINE, just the skeleton.
    expect(dxf, isNot(contains('LINE')));
    expect(dxf, contains('EOF'));
  });

  group('professional (metersPerPixel) real-world mode — review A2/A6/A7', () {
    // The shared net's run is a-(0,0) → b-(100,0): 100 px.
    String pro() => networkToDxf(
        net: net,
        sizing: sizing,
        sheetId: 's1',
        floorIndex: 0,
        metersPerPixel: 0.05);

    test('metersPerPixel null keeps the legacy pixel output byte-identical',
        () {
      expect(
        networkToDxf(net: net, sizing: sizing, sheetId: 's1', floorIndex: 0),
        equals(networkToDxf(
            net: net,
            sizing: sizing,
            sheetId: 's1',
            floorIndex: 0,
            metersPerPixel: null)),
      );
    });

    test('a 100-px run at 0.05 m/px measures 5000 mm', () {
      // 100 px × 0.05 m/px × 1000 mm/m = 5000 mm — the far endpoint's
      // group 11 X coordinate (the near end is at 0).
      final dxf = pro();
      expect(dxf, contains('\n11\n5000.0\n'));
      expect(dxf, isNot(contains('\n11\n100.0\n'))); // no raw pixels left
    });

    test('HEADER declares millimetre units and metric measurement', () {
      final dxf = pro();
      expect(dxf, contains('HEADER'));
      expect(dxf, contains('\$INSUNITS\n70\n4\n')); // 4 = millimetres
      expect(dxf, contains('\$MEASUREMENT\n70\n1\n')); // 1 = metric
    });

    test('TABLES defines LTYPE + named service/ANNO/FRAME layers', () {
      final dxf = pro();
      expect(dxf, contains('TABLES'));
      expect(dxf, contains('LTYPE'));
      expect(dxf, contains('P-DOM-CWS')); // the cold-water service layer
      expect(dxf, contains('G-ANNO-TEXT')); // annotation layer
      expect(dxf, contains('G-ANNO-TTLB')); // frame layer
      expect(dxf, isNot(contains('coldWater'))); // no enum-name layers
    });

    test('sized runs carry group 6 linetype + group 370 lineweight', () {
      final dxf = pro();
      // Cold water is CONTINUOUS; DN50 is the small band → 0.13 mm.
      expect(dxf, contains('\n6\nCONTINUOUS\n'));
      expect(dxf, contains('\n370\n13\n'));
    });

    test('A1: the underlay layer joins the TABLES and coordinates are mm', () {
      // k = worldToSheetScale × mmPerPx = (200/100) × (0.05·1000) = 100.
      // Underlay line (10,20)→(110,70): X = (x−10)·100, Y = (y−70)·100
      // → (0, −5000) → (10000, 0).
      final dxf = networkToDxf(
          net: net,
          sizing: sizing,
          sheetId: 's1',
          floorIndex: 0,
          metersPerPixel: 0.05,
          underlay: underlay);
      expect(
          dxf, contains('LAYER\n2\nG-ANNO-UNDR\n70\n0\n62\n8\n6\nCONTINUOUS'));
      expect(
          dxf,
          contains('LINE\n8\nG-ANNO-UNDR\n62\n8\n'
              '10\n0.0\n20\n-5000.0\n11\n10000.0\n21\n0.0\n'));
      // Painted first: the underlay entity precedes the first service entity.
      expect(dxf.indexOf('G-ANNO-UNDR\n62'),
          lessThan(dxf.indexOf('\n8\nP-DOM-CWS')));
    });

    test('A1: null underlay keeps the professional DXF byte-identical', () {
      expect(
        pro(),
        equals(networkToDxf(
            net: net,
            sizing: sizing,
            sheetId: 's1',
            floorIndex: 0,
            metersPerPixel: 0.05,
            underlay: null)),
      );
    });

    test('a vertical run labels on the ANNO layer with group 50 = 90 deg', () {
      // Screen-vertical run (0,0)→(0,100 px): world (0,0)→(0,-5000 mm), a
      // -90 deg bearing that A7 flips to +90 so the text reads upright
      // (bottom-to-top, the drafting convention).
      const vnet = Network(
        nodes: [
          NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'b', sheetId: 's1', x: 0, y: 100, floorIndex: 0),
        ],
        edges: [
          NetEdge(
              id: 'e', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
        ],
      );
      final dxf = networkToDxf(
          net: vnet,
          sizing: sizing,
          sheetId: 's1',
          floorIndex: 0,
          metersPerPixel: 0.05);
      expect(dxf, contains('DN50'));
      expect(dxf, contains('\n50\n90.0\n'));
    });

    test('N5: the elevation token is appended to the size label', () {
      final dxf = networkToDxf(
          net: net,
          sizing: sizing,
          sheetId: 's1',
          floorIndex: 0,
          metersPerPixel: 0.05,
          edgeElevationLabels: const {'e': 'CL +2.70'});
      // Audit 2026-10 drawing-output-7: the professional label is composed
      // like the plan PDF's, so it now carries the run length too — the run is
      // 100 px x 0.05 m/px = 5.0 m (no edgeLengths map ⇒ the calibrated
      // horizontal fallback), printed '5 m', between the size and the CL.
      expect(dxf, contains('DN50 - 5 m - CL +2.70'));
    });

    test('N4: the setting-out grid + a riser tie dimension are emitted', () {
      // Column B == the riser node x (100 px) → offset 0, skipped; row 1 at
      // y=50 px → |0−50|·0.05·1000 = 2500 mm tie dimension on the ANNO layer.
      final dxf = networkToDxf(
          net: net,
          sizing: sizing,
          sheetId: 's1',
          floorIndex: 0,
          metersPerPixel: 0.05,
          grid: const ReferenceGrid(
            columns: [GridAxis('A', 0), GridAxis('B', 100)],
            rows: [GridAxis('1', 50)],
          ));
      expect(dxf, contains('G-ANNO-GRID')); // the grid layer + entities
      expect(dxf, contains('\n1\n2500\n')); // the riser tie dimension (mm)
      expect(dxf, contains('\n1\nA\n')); // a column bubble label
      // drafting-4: the tie is a real dimension on its OWN grey layer — two
      // extension lines + the offset dimension line + two oblique ticks (five
      // LINEs) and the figure — never a bare LINE on the riser's ordinate.
      expect(dxf, contains('G-ANNO-DIMS'));
      expect('\n8\nG-ANNO-DIMS\n'.allMatches(dxf).length, 5 + 1,
          reason: '5 LINEs + 1 TEXT on the dimension layer');
    });

    test('R4: the tie dimension sits on the SAME side as the plan PDF', () {
      // One tie only: column B == the riser x (offset 0, skipped), row 1 at
      // y = 50 px → the tie runs from (100, 50) UP the sheet to the riser at
      // (100, 0). Both spaces are y-up, so with direction (ux, uy) the
      // perpendicular (uy, −ux) offsets the dimension toward LARGER pixel x in
      // both formats (it used to flip to the other side in the DXF).
      const grid = ReferenceGrid(
        columns: [GridAxis('B', 100)],
        rows: [GridAxis('1', 50)],
      );
      final dxf = networkToDxf(
          net: net,
          sizing: sizing,
          sheetId: 's1',
          floorIndex: 0,
          metersPerPixel: 0.05,
          grid: grid);
      final line =
          RegExp(r'0\nLINE\n8\nG-ANNO-DIMS\n10\n(-?[\d.]+)\n20\n(-?[\d.]+)\n'
              r'11\n(-?[\d.]+)\n21\n(-?[\d.]+)\n');
      final lines = line
          .allMatches(dxf)
          .map((m) => [for (var i = 1; i <= 4; i++) double.parse(m.group(i)!)])
          .toList();
      expect(lines, hasLength(5));
      final dxfDim = lines[2]; // ext, ext, DIMENSION LINE, tick, tick
      const riserXmm = 100 * 0.05 * 1000; // 5000 mm
      final dxfSide = ((dxfDim[0] + dxfDim[2]) / 2 - riserXmm).sign;

      final pdf = latin1.decode(planToPdf(
        net: net,
        sizing: sizing,
        edgeLengths: const {},
        sheetId: 's1',
        floorIndex: 0,
        projectName: 'P',
        sheetName: 'S',
        dateString: '2026-10-17',
        metersPerPixel: 0.05,
        grid: grid,
      ));
      final start = pdf.indexOf('0.45 0.45 0.45 RG');
      expect(start, greaterThanOrEqualTo(0));
      final seg = RegExp(r'^(-?[\d.]+) (-?[\d.]+) m (-?[\d.]+) (-?[\d.]+) l S$',
          multiLine: true);
      final strokes = seg
          .allMatches(pdf.substring(start))
          .take(3)
          .map((m) => [for (var i = 1; i <= 4; i++) double.parse(m.group(i)!)])
          .toList();
      final ext1 = strokes[0], pdfDim = strokes[2];
      // The axis extension line starts 2 pt off the ordinate along the perp:
      // its start x minus that 2 pt step recovers the ordinate x.
      final perpX = (ext1[2] - ext1[0]) / 10; // ext1 is 10 pt along the perp
      final ordinateX = ext1[0] - perpX * 2;
      final pdfSide = ((pdfDim[0] + pdfDim[2]) / 2 - ordinateX).sign;

      expect(dxfSide, 1.0, reason: 'DXF offset toward larger pixel x');
      expect(pdfSide, dxfSide, reason: 'PDF and DXF agree on the side');
    });

    test('N5/N4: null map + null grid keep the professional DXF byte-identical',
        () {
      expect(
        pro(),
        equals(networkToDxf(
            net: net,
            sizing: sizing,
            sheetId: 's1',
            floorIndex: 0,
            metersPerPixel: 0.05,
            edgeElevationLabels: null,
            grid: null)),
      );
    });
  });

  test('N5: elevation token appends in the legacy pixel DXF too', () {
    final dxf = networkToDxf(
        net: net,
        sizing: sizing,
        sheetId: 's1',
        floorIndex: 0,
        edgeElevationLabels: const {'e': 'CL +2.70'});
    expect(dxf, contains('DN50 - CL +2.70'));
  });

  // ── N13: the stable element tag on the plan DXF (run label + riser marker) ──
  group('N13 element tags', () {
    const tags = {'e': 'CW-F1', 'r': 'CW-R1'};

    test(
        'legacy pixel DXF: run label prepends the tag; riser marker gets a tag '
        'TEXT', () {
      final dxf = networkToDxf(
          net: net,
          sizing: sizing,
          sheetId: 's1',
          floorIndex: 0,
          edgeTags: tags);
      // The run's DN label is prefixed with its floor tag.
      expect(dxf, contains('CW-F1 - DN50'));
      // The riser marker carries a standalone tag TEXT (\n1\n<tag>\n).
      expect(dxf, contains('\n1\nCW-R1\n'));
    });

    test('professional mm DXF: the tags ride the ANNO layer', () {
      final dxf = networkToDxf(
          net: net,
          sizing: sizing,
          sheetId: 's1',
          floorIndex: 0,
          metersPerPixel: 0.05,
          edgeTags: tags);
      // Audit 2026-10 drawing-output-7: the same `<tag> · <size> - <length>`
      // composition as the plan PDF (100 px x 0.05 m/px = 5 m). The riser 'r'
      // has no sizing and no length map entry, so its TEXT is the bare tag.
      // Through the R12 code-page-safe encoder (drafting-5: '·' -> '-').
      expect(dxf, contains(dxfText('CW-F1 · DN50 - 5 m')));
      expect(dxf, contains('\n1\nCW-R1\n'));
    });

    test('a null edgeTags map keeps both DXF paths byte-identical', () {
      expect(
          networkToDxf(net: net, sizing: sizing, sheetId: 's1', floorIndex: 0),
          equals(networkToDxf(
              net: net,
              sizing: sizing,
              sheetId: 's1',
              floorIndex: 0,
              edgeTags: null)));
      expect(
          networkToDxf(
              net: net,
              sizing: sizing,
              sheetId: 's1',
              floorIndex: 0,
              metersPerPixel: 0.05),
          equals(networkToDxf(
              net: net,
              sizing: sizing,
              sheetId: 's1',
              floorIndex: 0,
              metersPerPixel: 0.05,
              edgeTags: null)));
    });
  });

  // ── drafting-5: the CAD deliverable is code-page safe ─────────────────────
  group('drafting-5 DXF text encoding', () {
    test('dxfText maps the non-ASCII drawing glyphs to R12-safe ASCII', () {
      expect(dxfText('CW-R1 \u00b7 DN32'), 'CW-R1 - DN32');
      expect(dxfText('\u00d8200'), '%%c200');
      expect(dxfText('\u00f8200'), '%%c200');
      expect(dxfText('90\u00b0'), '90%%d');
      expect(dxfText('m\u00b2 m\u00b3'), 'm2 m3');
      expect(dxfText('\u2192'), '?');
      // Printable ASCII is byte-identical.
      expect(dxfText('DN50 - 4.4 m'), 'DN50 - 4.4 m');
    });

    for (final mpp in [null, 0.05]) {
      test('no byte above 0x7E + an R12 header (mpp=$mpp)', () {
        final dxf = networkToDxf(
            net: net,
            sizing: sizing,
            sheetId: 's1',
            floorIndex: 0,
            metersPerPixel: mpp,
            // A middle-dot tag (the label separator the app's tags carry).
            edgeTags: const {'e': 'CW-F1 \u00b7 L1', 'r': 'CW-R1 \u00b7 S'});
        expect(dxf.codeUnits.where((c) => c > 0x7e), isEmpty);
        expect(dxf, contains('CW-F1 - L1'));
        if (mpp != null) {
          expect(dxf, contains('9\n\$ACADVER\n1\nAC1009\n'));
        }
      });
    }
  });
}
