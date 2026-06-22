import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  const building = BuildingLevels([
    Floor('Ground', Length(4.0)),
    Floor('Level 1', Length(3.5)),
    Floor('Level 2', Length(3.5)),
  ]);

  group('service regime mapping (§7 separate code paths)', () {
    test('pressurized / gravity / air', () {
      expect(ServiceType.coldWater.regime, FlowRegime.pressurized);
      expect(ServiceType.fireSprinkler.regime, FlowRegime.pressurized);
      expect(ServiceType.drainage.regime, FlowRegime.gravity);
      expect(ServiceType.vent.regime, FlowRegime.gravity);
      expect(ServiceType.rainwater.regime, FlowRegime.gravity);
      expect(ServiceType.duct.regime, FlowRegime.air);
    });
  });

  group('edge length from the §10 sources of truth', () {
    const net = Network(
      nodes: const [
        NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's1', x: 300, y: 400, floorIndex: 0), // 500 px
        NetNode(id: 'c', sheetId: 's3', x: 10, y: 10, floorIndex: 2),
      ],
      edges: const [
        NetEdge(id: 'e1', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
        NetEdge(
          id: 'r1',
          fromId: 'a',
          toId: 'c',
          service: ServiceType.coldWater,
          kind: EdgeKind.riser,
        ),
      ],
    );
    const calib = {'s1': ScaleCalibration(0.01)}; // 1 px = 1 cm

    test('run length = pixels × calibration', () {
      expect(runPixelLength(net.edges[0], net), closeTo(500.0, 1e-9));
      final len = edgeLength(net.edges[0], net,
          calibrationBySheet: calib, building: building);
      expect(len.meters, closeTo(5.0, 1e-9)); // 500 px × 0.01
    });

    test('riser length = floor-elevation delta (not drawn distance)', () {
      final len = edgeLength(net.edges[1], net,
          calibrationBySheet: calib, building: building);
      expect(len.meters, closeTo(7.5, 1e-9)); // floors 0→2
      expect(runPixelLength(net.edges[1], net), 0); // riser has no pixel run
    });

    test('uncalibrated run yields zero length (flagged elsewhere)', () {
      final len = edgeLength(net.edges[0], net,
          calibrationBySheet: const {}, building: building);
      expect(len.meters, 0);
    });
  });

  group('connectivity', () {
    const net = Network(
      nodes: const [
        NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's1', x: 1, y: 1, floorIndex: 0),
      ],
      edges: const [
        NetEdge(id: 'e1', fromId: 'a', toId: 'b', service: ServiceType.duct),
      ],
    );

    test('nodeById and edgesAt', () {
      expect(net.nodeById('a')?.sheetId, 's1');
      expect(net.nodeById('z'), isNull);
      expect(net.edgesAt('a').length, 1);
      expect(net.edgesAt('b').single.id, 'e1');
    });
  });
}
