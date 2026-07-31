/// E1 (store half) — the draw/drop snap honours SCOPE.
///
/// `_snap` filtered on sheet + floor only, so a cold-water run latched onto a
/// duct or a drainage node — including one on a service the engineer had HIDDEN
/// or LOCKED, and so could neither see nor unpick. Two filters close it:
///
///   * `avoidServices` — the inert set the caller is scoped away from; a node
///     whose incident edges are ALL on an avoided service is never adopted, and
///     an avoided run is never teed into;
///   * cross-service latching — a draw endpoint never adopts a PLAIN junction
///     whose incident edges are all a different service. Equipment / plant /
///     fixture nodes stay adoptable on purpose (a roof tank feeds cold AND hot
///     water; a WC carries its supply and its drain at one point), and a BARE
///     node (no incident edge) belongs to no service yet.
///
/// The default (empty set) leaves every existing call byte-identical apart from
/// the cross-service junction rule, which is the fix itself.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx_engine/network/network.dart';

ProviderContainer _container() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

/// A DUCT run on floor 0 of sheet s1 from (0,0) to (200,0), plus a bare
/// unconnected fitting at (400,0).
const _ductNet = Network(
  nodes: [
    NetNode(id: 'd0', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
    NetNode(id: 'd1', sheetId: 's1', x: 200, y: 0, floorIndex: 0),
    NetNode(id: 'bare', sheetId: 's1', x: 400, y: 0, floorIndex: 0),
  ],
  edges: [
    NetEdge(id: 'duct', fromId: 'd0', toId: 'd1', service: ServiceType.duct),
  ],
);

void main() {
  group('cross-service latching', () {
    test('a cold-water run does NOT adopt a plain DUCT junction it lands on',
        () {
      final c = _container();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(_ductNet);
      n.setService(ServiceType.coldWater);
      n.setTool(DrawTool.drawRun);

      // Draw a cold-water run that ENDS exactly on the duct's end node.
      n.placeRunPoint('s1', 0, const Offset(200, 120));
      n.placeRunPoint('s1', 0, const Offset(200, 0));

      final net = c.read(networkControllerProvider).network;
      final water =
          net.edges.firstWhere((e) => e.service == ServiceType.coldWater);
      // The far endpoint is a FRESH node, not the duct's 'd1'.
      expect({water.fromId, water.toId}, isNot(contains('d1')));
      // The duct is untouched (never split, never re-pointed).
      final duct = net.edges.firstWhere((e) => e.id == 'duct');
      expect(duct.fromId, 'd0');
      expect(duct.toId, 'd1');
    });

    test('it DOES adopt a bare junction (no incident edge — it belongs to no '
        'service yet)', () {
      final c = _container();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(_ductNet);
      n.setService(ServiceType.coldWater);
      n.setTool(DrawTool.drawRun);

      n.placeRunPoint('s1', 0, const Offset(400, 120));
      n.placeRunPoint('s1', 0, const Offset(400, 0));

      final net = c.read(networkControllerProvider).network;
      final water =
          net.edges.firstWhere((e) => e.service == ServiceType.coldWater);
      expect({water.fromId, water.toId}, contains('bare'));
    });

    test('it DOES adopt an EQUIPMENT node on another service (a tank feeds both '
        'cold and hot water)', () {
      final c = _container();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(const Network(
        nodes: [
          NetNode(
              id: 'tank',
              sheetId: 's1',
              x: 0,
              y: 0,
              floorIndex: 0,
              role: NodeRole.plant,
              component: NodeComponent.roofTank),
          NetNode(id: 'cw', sheetId: 's1', x: 200, y: 0, floorIndex: 0),
        ],
        edges: [
          NetEdge(
              id: 'e', fromId: 'tank', toId: 'cw', service: ServiceType.coldWater),
        ],
      ));
      n.setService(ServiceType.hotWater);
      n.setTool(DrawTool.drawRun);

      n.placeRunPoint('s1', 0, const Offset(0, 120));
      n.placeRunPoint('s1', 0, const Offset(0, 0));

      final net = c.read(networkControllerProvider).network;
      final hot =
          net.edges.firstWhere((e) => e.service == ServiceType.hotWater);
      expect({hot.fromId, hot.toId}, contains('tank'));
    });

    test('a SAME-service junction is still adopted (byte-identical behaviour)',
        () {
      final c = _container();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(const Network(
        nodes: [
          NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'b', sheetId: 's1', x: 200, y: 0, floorIndex: 0),
        ],
        edges: [
          NetEdge(id: 'e', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
        ],
      ));
      n.setService(ServiceType.coldWater);
      n.setTool(DrawTool.drawRun);

      n.placeRunPoint('s1', 0, const Offset(200, 120));
      n.placeRunPoint('s1', 0, const Offset(200, 0));

      final net = c.read(networkControllerProvider).network;
      final added = net.edges.firstWhere((e) => e.id != 'e');
      expect({added.fromId, added.toId}, contains('b'));
    });
  });

  group('avoidServices', () {
    test('a node on an AVOIDED service is not adopted, even same-service', () {
      final c = _container();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(const Network(
        nodes: [
          NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'b', sheetId: 's1', x: 200, y: 0, floorIndex: 0),
        ],
        edges: [
          NetEdge(id: 'e', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
        ],
      ));
      n.setService(ServiceType.coldWater);
      n.setTool(DrawTool.drawRun);

      n.placeRunPoint('s1', 0, const Offset(200, 120));
      n.placeRunPoint('s1', 0, const Offset(200, 0),
          avoidServices: const {ServiceType.coldWater});

      final net = c.read(networkControllerProvider).network;
      final added = net.edges.firstWhere((e) => e.id != 'e');
      expect({added.fromId, added.toId}, isNot(contains('b')));
      // …and the avoided run was never split into a tee either.
      expect(net.edges.where((e) => e.service == ServiceType.coldWater).length,
          2, reason: 'the original run + the new one, no split halves');
    });

    test('an avoided run is never TEED into mid-span', () {
      final c = _container();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(const Network(
        nodes: [
          NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'b', sheetId: 's1', x: 400, y: 0, floorIndex: 0),
        ],
        edges: [
          NetEdge(id: 'e', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
        ],
      ));
      n.setService(ServiceType.coldWater);
      n.setTool(DrawTool.drawRun);

      n.placeRunPoint('s1', 0, const Offset(200, 120));
      n.placeRunPoint('s1', 0, const Offset(200, 0), // mid-span of 'e'
          avoidServices: const {ServiceType.coldWater});

      final net = c.read(networkControllerProvider).network;
      final original = net.edges.firstWhere((e) => e.id == 'e');
      expect(original.toId, 'b', reason: 'the avoided run was not split');
    });

    test('the default (empty set) still tees into a same-service run', () {
      final c = _container();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(const Network(
        nodes: [
          NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'b', sheetId: 's1', x: 400, y: 0, floorIndex: 0),
        ],
        edges: [
          NetEdge(id: 'e', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
        ],
      ));
      n.setService(ServiceType.coldWater);
      n.setTool(DrawTool.drawRun);

      n.placeRunPoint('s1', 0, const Offset(200, 120));
      n.placeRunPoint('s1', 0, const Offset(200, 0));

      final net = c.read(networkControllerProvider).network;
      // 'e' was split at the projection: two halves + the new branch.
      expect(net.edges.where((e) => e.service == ServiceType.coldWater).length, 3);
    });

    test('a palette DROP does not merge onto an avoided-service node', () {
      final c = _container();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(_ductNet);

      final id = n.mergeOrAddFitting('s1', 0, const Offset(200, 0),
          avoidServices: const {ServiceType.duct});
      expect(id, isNot('d1'));
    });

    test('the default (no scope) still adopts the node already there', () {
      final c = _container();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(_ductNet);
      expect(n.mergeOrAddFitting('s1', 0, const Offset(200, 0)), 'd1');
    });

    test('a drag-end merge skips a node on an avoided service', () {
      final c = _container();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(_ductNet);
      // A free cold-water fitting dragged onto the duct's end node.
      n.addFitting('s1', 0, const Offset(500, 0));
      final free = c.read(networkControllerProvider).network.nodes.last;
      n.pushUndoSnapshot();
      n.moveNode(free.id, 200, 0);
      n.endNodeDragWithSnap(free.id, 12,
          avoidServices: const {ServiceType.duct});

      final net = c.read(networkControllerProvider).network;
      expect(net.nodeById(free.id), isNotNull,
          reason: 'not merged away into the avoided duct network');
      expect(net.edges.map((e) => e.id), ['duct'],
          reason: 'and never tapped into the avoided run');
    });
  });
}
