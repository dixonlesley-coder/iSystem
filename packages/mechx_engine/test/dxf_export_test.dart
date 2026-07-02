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
