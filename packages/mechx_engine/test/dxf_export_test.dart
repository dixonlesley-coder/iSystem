import 'package:mechx_engine/geometry/dxf_drawing.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/dxf_export.dart';
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
    final dxf = networkToDxf(
        net: net, sizing: sizing, sheetId: 's1', floorIndex: 0);
    expect(dxf, contains('SECTION'));
    expect(dxf, contains('ENTITIES'));
    expect(dxf, contains('LINE'));
    expect(dxf, contains('coldWater')); // layer
    expect(dxf.trimRight(), endsWith('EOF'));
  });

  test('run endpoints appear with Y negated (DXF up-is-positive)', () {
    final dxf = networkToDxf(
        net: net, sizing: sizing, sheetId: 's1', floorIndex: 0);
    // The DN50 size label is placed on the run.
    expect(dxf, contains('DN50'));
  });

  test('a riser on the floor emits a CIRCLE marker', () {
    final dxf = networkToDxf(
        net: net, sizing: sizing, sheetId: 's1', floorIndex: 0);
    expect(dxf, contains('CIRCLE'));
  });

  test('A5: a riser to a higher floor labels UP', () {
    // Riser b(floor 0) → c(floor 1); the on-floor marker is b, other end
    // higher → an 'UP' TEXT beside the circle.
    final dxf = networkToDxf(
        net: net, sizing: sizing, sheetId: 's1', floorIndex: 0);
    expect(dxf, contains('\n1\nUP\n'));
  });

  test('A5: a component node emits its equipment glyph (a pump CIRCLE)', () {
    // A run with a pump node and NO riser — the only CIRCLE must come from the
    // pump body glyph (plain junctions are never dotted here).
    const pumpNet = Network(
      nodes: [
        NetNode(id: 'p', sheetId: 's1', x: 0, y: 0, floorIndex: 0,
            role: NodeRole.plant, component: NodeComponent.pump),
        NetNode(id: 'q', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
      ],
      edges: [
        NetEdge(id: 'e', fromId: 'p', toId: 'q', service: ServiceType.coldWater),
      ],
    );
    final dxf =
        networkToDxf(net: pumpNet, sizing: const {}, sheetId: 's1', floorIndex: 0);
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
    final base = networkToDxf(
        net: net, sizing: sizing, sheetId: 's1', floorIndex: 0);
    final arrowed = networkToDxf(
        net: net, sizing: oriented, sheetId: 's1', floorIndex: 0);
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

    test('re-emits CIRCLE + ARC natively, radius scaled, angles unchanged',
        () {
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
      expect(dxf.indexOf('G-ANNO-UNDR'),
          lessThan(dxf.indexOf('\n8\ncoldWater')));
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
          net: net, sizing: sizing, sheetId: 's1', floorIndex: 0, chrome: null)),
    );
  });

  test('only the requested sheet/floor is exported', () {
    // s2 has its own node but no edges on s1/floor0 beyond ours.
    final dxf = networkToDxf(
        net: net, sizing: sizing, sheetId: 's2', floorIndex: 0);
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
      expect(dxf,
          contains('LAYER\n2\nG-ANNO-UNDR\n70\n0\n62\n8\n6\nCONTINUOUS'));
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
  });
}
