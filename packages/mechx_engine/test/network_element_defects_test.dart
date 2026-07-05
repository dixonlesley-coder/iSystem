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

    // H1: a bare degree-1 end on a GRAVITY service (drainage / vent / rainwater)
    // is a legitimate terminus — a soil-stack outfall, a vent-through-roof, a
    // rainwater discharge — so it is NOT a looseEnd (mirroring the gravity skip
    // in networkConnectivityDefects). The SAME bare end on a pressurized service
    // IS a looseEnd, and a fully-disconnected gravity node is still an orphan.
    test('gravity bare ends are legitimate termini (not looseEnds); a '
        'pressurized bare end still is; a gravity orphan still is', () {
      const j = NetNode(id: 'J', sheetId: 's1', x: 5, y: 0, floorIndex: 0);
      const bareEnd =
          NetNode(id: 'A', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
      const floorDrain = NetNode(
          id: 'B',
          sheetId: 's1',
          x: 10,
          y: 0,
          floorIndex: 0,
          component: NodeComponent.floorDrain);
      const d1 = NetEdge(
          id: 'd1', fromId: 'A', toId: 'J', service: ServiceType.drainage);
      const d2 = NetEdge(
          id: 'd2', fromId: 'J', toId: 'B', service: ServiceType.drainage);
      // Gravity: the bare end 'A' is a legitimate outfall — no defect at all.
      const gravityNet =
          Network(nodes: [j, bareEnd, floorDrain], edges: [d1, d2]);
      expect(networkElementDefects(gravityNet), isEmpty);

      // Pressurized: the identical bare-main degree-1 end IS a looseEnd (a
      // pressure pipe should terminate at a fixture/terminal, not open air).
      const p1 = NetEdge(
          id: 'p1', fromId: 'A', toId: 'J', service: ServiceType.coldWater);
      const p2 = NetEdge(
          id: 'p2', fromId: 'J', toId: 'B', service: ServiceType.coldWater);
      final pressurized = networkElementDefects(
          const Network(nodes: [j, bareEnd, floorDrain], edges: [p1, p2]));
      expect(pressurized, hasLength(1));
      expect(pressurized.single.nodeId, 'A');
      expect(pressurized.single.kind, NetworkElementDefectKind.looseEnd);
      expect(pressurized.single.service, ServiceType.coldWater);

      // A gravity node with NO edges at all is still an orphan.
      const stray = NetNode(id: 'C', sheetId: 's1', x: 50, y: 50, floorIndex: 0);
      final withOrphan = networkElementDefects(
          const Network(nodes: [j, bareEnd, floorDrain, stray], edges: [d1, d2]));
      expect(withOrphan.map((x) => x.nodeId), ['C']);
      expect(withOrphan.single.isOrphan, isTrue);
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
