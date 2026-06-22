import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  group('accumulateFlows (branching)', () {
    // Tee: root —e1— a, a —e2— b, a —e3— c. Demands at the two leaves.
    const net = Network(
      nodes: [
        NetNode(id: 'root', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'a', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's1', x: 200, y: -50, floorIndex: 0),
        NetNode(id: 'c', sheetId: 's1', x: 200, y: 50, floorIndex: 0),
      ],
      edges: const [
        NetEdge(id: 'e1', fromId: 'root', toId: 'a', service: ServiceType.duct),
        NetEdge(id: 'e2', fromId: 'a', toId: 'b', service: ServiceType.duct),
        NetEdge(id: 'e3', fromId: 'a', toId: 'c', service: ServiceType.duct),
      ],
    );

    test('each branch carries its own load; the trunk carries the sum', () {
      final flows = accumulateFlows(
        net: net,
        service: ServiceType.duct,
        rootId: 'root',
        terminalDemand: const {
          'b': FlowRate(0.10),
          'c': FlowRate(0.20),
        },
      );
      expect(flows['e2']!.cubicMetersPerSecond, closeTo(0.10, 1e-12)); // branch b
      expect(flows['e3']!.cubicMetersPerSecond, closeTo(0.20, 1e-12)); // branch c
      expect(flows['e1']!.cubicMetersPerSecond, closeTo(0.30, 1e-12)); // trunk
    });

    test('only edges of the requested service are considered', () {
      final flows = accumulateFlows(
        net: net,
        service: ServiceType.coldWater, // none in this net
        rootId: 'root',
        terminalDemand: const {'b': FlowRate(0.1)},
      );
      expect(flows, isEmpty);
    });
  });

  group('sizeEdge dispatches by §7 regime', () {
    const ctx = SizingContext();

    test('pressurized water → DN65 at 5 L/s', () {
      const edge = NetEdge(id: 'e', fromId: 'a', toId: 'b', service: ServiceType.coldWater);
      final s = sizeEdge(edge, const FlowRate(0.005), ctx);
      expect(s.diameter.inMillimeters, 65);
      expect(s.velocity.metersPerSecond, lessThanOrEqualTo(2.0));
    });

    test('air duct → 400 mm at 0.5 m³/s, v ≤ 5', () {
      const edge = NetEdge(id: 'e', fromId: 'a', toId: 'b', service: ServiceType.duct);
      final s = sizeEdge(edge, const FlowRate(0.5), ctx);
      expect(s.diameter.inMillimeters, 400);
      expect(s.velocity.metersPerSecond, lessThanOrEqualTo(5.0));
    });

    test('gravity drainage → DN125 at 4 L/s, slope 0.01', () {
      const edge = NetEdge(id: 'e', fromId: 'a', toId: 'b', service: ServiceType.drainage);
      final s = sizeEdge(edge, const FlowRate(0.004), ctx);
      expect(s.diameter.inMillimeters, 125);
    });
  });

  test('autoSizeNetwork sizes a branching duct tree from leaf demands', () {
    const net = Network(
      nodes: [
        NetNode(id: 'src', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'a', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's1', x: 200, y: -50, floorIndex: 0),
        NetNode(id: 'c', sheetId: 's1', x: 200, y: 50, floorIndex: 0),
      ],
      edges: [
        NetEdge(id: 'e1', fromId: 'src', toId: 'a', service: ServiceType.duct),
        NetEdge(id: 'e2', fromId: 'a', toId: 'b', service: ServiceType.duct),
        NetEdge(id: 'e3', fromId: 'a', toId: 'c', service: ServiceType.duct),
      ],
    );
    final sized = autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {ServiceType.duct: FlowRate(0.1)},
    );
    // 'src' is a leaf → chosen as root; demand applied at the other leaves.
    expect(sized['e1']!.flow.cubicMetersPerSecond, closeTo(0.2, 1e-9)); // trunk
    expect(sized['e2']!.flow.cubicMetersPerSecond, closeTo(0.1, 1e-9));
    expect(sized['e3']!.flow.cubicMetersPerSecond, closeTo(0.1, 1e-9));
    expect(
      sized['e1']!.diameter.meters,
      greaterThanOrEqualTo(sized['e2']!.diameter.meters),
    );
  });

  test('sizeNetwork sizes every edge with an accumulated flow', () {
    const net = Network(
      nodes: [
        NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
      ],
      edges: [
        NetEdge(id: 'e', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
      ],
    );
    final sized = sizeNetwork(
      net,
      const {'e': FlowRate(0.005)},
      const SizingContext(),
    );
    expect(sized['e']!.diameter.inMillimeters, 65);
  });
}
