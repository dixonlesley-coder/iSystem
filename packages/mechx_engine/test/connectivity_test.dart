import 'package:mechx_engine/network/connectivity.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:test/test.dart';

void main() {
  group('networkConnectivityDefects', () {
    // A coldWater run A–B with no plant: regime is pressurized, so pickRoot would
    // heuristically root it (no plant) even though it has no supply — exactly the
    // unfed case to flag.
    test('a pressurized component with no plant node is flagged noSource', () {
      const a = NetNode(id: 'A', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
      const b = NetNode(
          id: 'B',
          sheetId: 's1',
          x: 10,
          y: 0,
          floorIndex: 0,
          role: NodeRole.fixture);
      const edge = NetEdge(
          id: 'e1', fromId: 'A', toId: 'B', service: ServiceType.coldWater);
      const net = Network(nodes: [a, b], edges: [edge]);

      final defects = networkConnectivityDefects(net);
      expect(defects, hasLength(1));
      final d = defects.single;
      expect(d.kind, NetworkDefectKind.noSource);
      expect(d.service, ServiceType.coldWater);
      expect(d.nodeIds.toSet(), {'A', 'B'});
    });

    // The same run but A is a plant (a pump/tank) ⇒ a valid source ⇒ no defect.
    test('a component containing a plant node is NOT flagged', () {
      const a = NetNode(
          id: 'A',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 0,
          role: NodeRole.plant);
      const b = NetNode(
          id: 'B',
          sheetId: 's1',
          x: 10,
          y: 0,
          floorIndex: 0,
          role: NodeRole.fixture);
      const edge = NetEdge(
          id: 'e1', fromId: 'A', toId: 'B', service: ServiceType.coldWater);
      const net = Network(nodes: [a, b], edges: [edge]);

      expect(networkConnectivityDefects(net), isEmpty);
    });

    // Drainage has no plant, but the helper SKIPS gravity (a drain legitimately
    // has no source) ⇒ zero defects.
    test('a gravity (drainage) source-less component is NOT flagged', () {
      const a = NetNode(id: 'A', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
      const b = NetNode(id: 'B', sheetId: 's1', x: 10, y: 0, floorIndex: 0);
      const edge = NetEdge(
          id: 'e1', fromId: 'A', toId: 'B', service: ServiceType.drainage);
      const net = Network(nodes: [a, b], edges: [edge]);

      expect(networkConnectivityDefects(net), isEmpty);
    });

    // Two SEPARATE coldWater components: one fed ({P(plant),X}), one plant-less
    // ({Y,Z}). The service has a source somewhere ⇒ the plant-less component is a
    // disconnectedIsland, not a whole-service noSource.
    test('a second plant-less coldWater island alongside a fed one is a '
        'disconnectedIsland', () {
      const p = NetNode(
          id: 'P',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 0,
          role: NodeRole.plant);
      const x = NetNode(id: 'X', sheetId: 's1', x: 10, y: 0, floorIndex: 0);
      const y = NetNode(id: 'Y', sheetId: 's1', x: 100, y: 0, floorIndex: 0);
      const z = NetNode(id: 'Z', sheetId: 's1', x: 110, y: 0, floorIndex: 0);
      const fed = NetEdge(
          id: 'e1', fromId: 'P', toId: 'X', service: ServiceType.coldWater);
      const island = NetEdge(
          id: 'e2', fromId: 'Y', toId: 'Z', service: ServiceType.coldWater);
      const net = Network(nodes: [p, x, y, z], edges: [fed, island]);

      final defects = networkConnectivityDefects(net);
      expect(defects, hasLength(1));
      final d = defects.single;
      expect(d.kind, NetworkDefectKind.disconnectedIsland);
      expect(d.nodeIds.toSet(), {'Y', 'Z'});
    });

    // An air service with no source/AHU is flagged (pressurized + air both
    // checked); confirms the regime gate isn't pressurized-only.
    test('a source-less air (supply duct) component is flagged noSource', () {
      const a = NetNode(id: 'A', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
      const b = NetNode(
          id: 'B',
          sheetId: 's1',
          x: 10,
          y: 0,
          floorIndex: 0,
          role: NodeRole.fixture);
      const edge =
          NetEdge(id: 'e1', fromId: 'A', toId: 'B', service: ServiceType.duct);
      const net = Network(nodes: [a, b], edges: [edge]);

      final defects = networkConnectivityDefects(net);
      expect(defects, hasLength(1));
      expect(defects.single.kind, NetworkDefectKind.noSource);
      expect(defects.single.service, ServiceType.duct);
    });
  });
}
