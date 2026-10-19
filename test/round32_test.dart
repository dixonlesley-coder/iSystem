/// Round 32 app seed suite (2026-10-18):
///   * binding-1 — the SNI 8153 minimum at the critical node is PATH-derived:
///     98 kPa only when a flush-valve fixture lies on the source -> critical
///     supply path, else 49 kPa (a flush-valve WC on another branch never
///     raises a faucet's floor).
///   * binding-2 — a duplex ejector set's duty is the lowest pump id (the
///     incident-bore criterion was dropped: the legs are mirrored).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_feed.dart' show duplexEjectorStandbys;
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/ejector.dart' show drawnEjectorPumpIds;

NetNode _n(String id, double x, {NodeRole role = NodeRole.main}) =>
    NetNode(id: id, sheetId: 's1', x: x, y: 0, floorIndex: 0, role: role);

NetEdge _e(String id, String a, String b) =>
    NetEdge(id: id, fromId: a, toId: b, service: ServiceType.coldWater);

void main() {
  test('duplex ejector duty is the lowest id (binding-2, bore criterion '
      'dropped)', () {
    NetNode p(String id, NodeComponent c) => NetNode(
      id: id,
      sheetId: 's1',
      x: 0,
      y: 0,
      floorIndex: 0,
      role: c.role,
      component: c,
    );
    NetEdge d(String id, String a, String b) =>
        NetEdge(id: id, fromId: a, toId: b, service: ServiceType.drainage);
    final net = Network(
      nodes: [
        p('PIT', NodeComponent.groundTank),
        p('Z-EJ', NodeComponent.pump),
        p('A-EJ', NodeComponent.pump),
        _n('H', 10),
      ],
      edges: [
        d('p1', 'PIT', 'Z-EJ'),
        d('p2', 'PIT', 'A-EJ'),
        d('h1', 'Z-EJ', 'H'),
        d('h2', 'A-EJ', 'H'),
      ],
    );
    expect(duplexEjectorStandbys(net, drawnEjectorPumpIds(net)), {
      'Z-EJ': 'A-EJ',
    });
  });

  group('SNI minimum residual follows the critical node\'s path', () {
    // S -> J; J -> A (a faucet); J -> B (a flush-valve WC).
    final net = Network(
      nodes: [
        _n('S', 0, role: NodeRole.plant),
        _n('J', 10),
        _n('A', 20, role: NodeRole.fixture),
        _n('B', 30, role: NodeRole.fixture),
      ],
      edges: [_e('sj', 'S', 'J'), _e('ja', 'J', 'A'), _e('jb', 'J', 'B')],
    );

    test('a faucet critical node reads 0.5 kgf/cm² = 49.03 kPa even with a '
        'flush valve on another branch', () {
      final p = sniMinimumResidualAt(
        net: net,
        sourceId: 'S',
        criticalNodeId: 'A',
        flushValveNodeIds: const {'B'},
      );
      // 0.50 kgf/cm² × 98 066.5 Pa per kgf/cm² = 49 033.25 Pa.
      expect(p.pascals, closeTo(49033.25, 1e-6));
    });

    test('a flush-valve critical node reads 1.0 kgf/cm² = 98.07 kPa', () {
      final p = sniMinimumResidualAt(
        net: net,
        sourceId: 'S',
        criticalNodeId: 'B',
        flushValveNodeIds: const {'B'},
      );
      expect(p.pascals, closeTo(98066.5, 1e-6));
    });

    test('an inline flush valve on the path raises the floor', () {
      final p = sniMinimumResidualAt(
        net: net,
        sourceId: 'S',
        criticalNodeId: 'A',
        flushValveNodeIds: const {'J'},
      );
      expect(p.pascals, closeTo(98066.5, 1e-6));
    });
  });
}
