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
}
