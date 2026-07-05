import 'package:mechx_engine/network/connectivity.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:mechx_engine/units.dart' show FlowRate;
import 'package:test/test.dart';

void main() {
  group('networkElementDefects', () {
    // A bare distribution main at a degree-1 dead-end (pipe drawn to nowhere)
    // IS a looseEnd; the plant source at the other end (role != main) is not.
    test('a bare main node at a degree-1 dead-end is a looseEnd', () {
      const s = NetNode(
          id: 'S',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 0,
          role: NodeRole.plant);
      const b = NetNode(id: 'B', sheetId: 's1', x: 10, y: 0, floorIndex: 0);
      const edge = NetEdge(
          id: 'e1', fromId: 'S', toId: 'B', service: ServiceType.coldWater);
      const net = Network(nodes: [s, b], edges: [edge]);

      final defects = networkElementDefects(net);
      expect(defects, hasLength(1));
      final d = defects.single;
      expect(d.kind, NetworkElementDefectKind.looseEnd);
      expect(d.nodeId, 'B');
      expect(d.service, ServiceType.coldWater);
    });

    // A degree-1 fixture terminal is a valid end-of-run ⇒ NOT flagged.
    test('a fixture dead-end is NOT flagged', () {
      const s = NetNode(
          id: 'S',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 0,
          role: NodeRole.plant);
      const f = NetNode(
          id: 'F',
          sheetId: 's1',
          x: 10,
          y: 0,
          floorIndex: 0,
          role: NodeRole.fixture,
          fixture: PlumbingFixture.lavatory);
      const edge = NetEdge(
          id: 'e1', fromId: 'S', toId: 'F', service: ServiceType.coldWater);
      const net = Network(nodes: [s, f], edges: [edge]);

      expect(networkElementDefects(net), isEmpty);
    });

    // A degree-1 air terminal (airflow set, e.g. a diffuser) is a valid end even
    // when its role is a bare main ⇒ NOT flagged.
    test('a diffuser/grille dead-end (airflow set) is NOT flagged', () {
      const s = NetNode(
          id: 'S',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 0,
          role: NodeRole.plant);
      const diff = NetNode(
          id: 'D',
          sheetId: 's1',
          x: 10,
          y: 0,
          floorIndex: 0,
          airflow: FlowRate(0.2));
      const edge =
          NetEdge(id: 'e1', fromId: 'S', toId: 'D', service: ServiceType.duct);
      const net = Network(nodes: [s, diff], edges: [edge]);

      expect(networkElementDefects(net), isEmpty);
    });

    // A degree-1 node carrying a real equipment component (a roof tank) is a
    // valid end ⇒ NOT flagged, even though its role reads as main here.
    test('a tank/pump component dead-end is NOT flagged', () {
      const s = NetNode(id: 'S', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
      const tank = NetNode(
          id: 'T',
          sheetId: 's1',
          x: 10,
          y: 0,
          floorIndex: 0,
          component: NodeComponent.roofTank);
      const pump = NetNode(
          id: 'P',
          sheetId: 's1',
          x: 20,
          y: 0,
          floorIndex: 0,
          component: NodeComponent.pump);
      // S is a bare main junction with degree 2 (not a dead-end); T and P are
      // the degree-1 component ends.
      const e1 = NetEdge(
          id: 'e1', fromId: 'T', toId: 'S', service: ServiceType.coldWater);
      const e2 = NetEdge(
          id: 'e2', fromId: 'S', toId: 'P', service: ServiceType.coldWater);
      const net = Network(nodes: [s, tank, pump], edges: [e1, e2]);

      expect(networkElementDefects(net), isEmpty);
    });

    // A node placed on the sheet but incident to no edge (degree 0) IS an
    // orphan, regardless of its role/component.
    test('a degree-0 node is an orphan', () {
      const lonely = NetNode(
          id: 'X',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 0,
          component: NodeComponent.groundTank);
      const net = Network(nodes: [lonely], edges: []);

      final defects = networkElementDefects(net);
      expect(defects, hasLength(1));
      expect(defects.single.kind, NetworkElementDefectKind.orphan);
      expect(defects.single.nodeId, 'X');
      expect(defects.single.service, isNull);
    });

    // A run with a valid termination at BOTH ends (plant source + fixture) has
    // no per-element defects.
    test('a fully-connected run (both ends valid) has no element defects', () {
      const s = NetNode(
          id: 'S',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 0,
          role: NodeRole.plant);
      const mid = NetNode(id: 'M', sheetId: 's1', x: 5, y: 0, floorIndex: 0);
      const f = NetNode(
          id: 'F',
          sheetId: 's1',
          x: 10,
          y: 0,
          floorIndex: 0,
          role: NodeRole.fixture,
          fixture: PlumbingFixture.kitchenSink);
      const e1 = NetEdge(
          id: 'e1', fromId: 'S', toId: 'M', service: ServiceType.coldWater);
      const e2 = NetEdge(
          id: 'e2', fromId: 'M', toId: 'F', service: ServiceType.coldWater);
      const net = Network(nodes: [s, mid, f], edges: [e1, e2]);

      expect(networkElementDefects(net), isEmpty);
    });

    // A dangling drain (gravity service) IS a looseEnd, but a floor-drain
    // terminal on the same graph is NOT — gravity is covered, valid terminals
    // are spared.
    test('gravity: a bare drain dead-end is a looseEnd, a floor-drain is not',
        () {
      const j = NetNode(id: 'J', sheetId: 's1', x: 5, y: 0, floorIndex: 0);
      const dangling =
          NetNode(id: 'A', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
      const drain = NetNode(
          id: 'B',
          sheetId: 's1',
          x: 10,
          y: 0,
          floorIndex: 0,
          component: NodeComponent.floorDrain);
      const e1 = NetEdge(
          id: 'e1', fromId: 'A', toId: 'J', service: ServiceType.drainage);
      const e2 = NetEdge(
          id: 'e2', fromId: 'J', toId: 'B', service: ServiceType.drainage);
      const net = Network(nodes: [j, dangling, drain], edges: [e1, e2]);

      final defects = networkElementDefects(net);
      expect(defects, hasLength(1));
      expect(defects.single.nodeId, 'A');
      expect(defects.single.kind, NetworkElementDefectKind.looseEnd);
      expect(defects.single.service, ServiceType.drainage);
    });

    // Determinism: the result is sorted by node id.
    test('results are sorted by nodeId', () {
      const z = NetNode(id: 'z', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
      const a = NetNode(id: 'a', sheetId: 's1', x: 5, y: 0, floorIndex: 0);
      const net = Network(nodes: [z, a], edges: []);

      final ids = networkElementDefects(net).map((d) => d.nodeId).toList();
      expect(ids, ['a', 'z']);
    });
  });
}
