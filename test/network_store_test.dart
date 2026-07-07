import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/rendering.dart' show RenderBox;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/inspector_store.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/canvas/selection_overlay.dart';
import 'package:mechx/ui/widgets/context_menu.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/standards/pipe_products.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

void main() {
  group('NetworkController', () {
    ProviderContainer makeContainer() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('defaults: select tool, empty network', () {
      final c = makeContainer();
      final s = c.read(networkControllerProvider);
      expect(s.tool, DrawTool.select);
      expect(s.isDrawing, isFalse);
      expect(s.network.edges, isEmpty);
    });

    test('drawing a run: first point pends, second makes an edge + chains', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      expect(c.read(networkControllerProvider).pendingPoint, const Offset(0, 0));
      expect(c.read(networkControllerProvider).network.edges, isEmpty);

      n.placeRunPoint('s1', 0, const Offset(100, 0));
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 2);
      expect(net.edges.single.service, ServiceType.coldWater);
      expect(c.read(networkControllerProvider).pendingPoint, const Offset(100, 0));
    });

    test('chaining shares the joining node (polyline)', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(100, 0));
      n.placeRunPoint('s1', 0, const Offset(200, 0));
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 3);
      expect(net.edges.length, 2);
    });

    test('B1: switching sheet mid-run does not plant a phantom cross-sheet node',
        () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      // First click on sheet s1 / floor 0 pends the start there.
      n.placeRunPoint('s1', 0, const Offset(10, 10));
      var s = c.read(networkControllerProvider);
      expect(s.pendingPoint, const Offset(10, 10));
      expect(s.pendingSheetId, 's1');
      expect(s.pendingFloorIndex, 0);

      // The engineer clicks the sheet rail → the next click lands on a DIFFERENT
      // sheet/floor. Pre-fix this committed an edge with a phantom node at the
      // STALE (10,10) offset planted on s2. Now it must refuse the cross-sheet
      // edge and restart the run here.
      n.placeRunPoint('s2', 1, const Offset(200, 200));
      s = c.read(networkControllerProvider);
      expect(s.network.edges, isEmpty, reason: 'no cross-sheet edge committed');
      expect(s.network.nodes, isEmpty, reason: 'no phantom node planted');
      expect(s.pendingPoint, const Offset(200, 200),
          reason: 'the run restarted at this click on the new sheet');
      expect(s.pendingSheetId, 's2');
      expect(s.pendingFloorIndex, 1);

      // A second click on the SAME new sheet now draws a clean run, both nodes on
      // s2 / floor 1 — none at the stale s1 coordinates.
      n.placeRunPoint('s2', 1, const Offset(300, 200));
      final net = c.read(networkControllerProvider).network;
      expect(net.edges.length, 1);
      expect(net.nodes.length, 2);
      expect(net.nodes.every((nd) => nd.sheetId == 's2' && nd.floorIndex == 1),
          isTrue);
      expect(net.nodes.any((nd) => nd.x == 10 && nd.y == 10), isFalse,
          reason: 'the stale start offset never became a node');
    });

    test('snapping reuses a nearby node', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(100, 0)); // nodes a,b
      n.setTool(DrawTool.drawRun); // clear pending
      n.placeRunPoint('s1', 0, const Offset(2, 2)); // ≈ a
      n.placeRunPoint('s1', 0, const Offset(100, 2)); // ≈ b
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 2, reason: 'both endpoints snapped to a and b');
      expect(net.edges.length, 2);
    });

    test('riser adds a riser edge to the floor above', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRiser);
      n.placeRiser('s1', 0, const Offset(50, 50), 3);
      final net = c.read(networkControllerProvider).network;
      expect(net.edges.single.kind, EdgeKind.riser);
      final lower = net.nodeById(net.edges.single.fromId)!;
      final upper = net.nodeById(net.edges.single.toId)!;
      expect(lower.floorIndex, 0);
      expect(upper.floorIndex, 1);
    });

    test('riser on the top floor places DOWNWARD (C6, not a silent no-op)', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRiser);
      // Top floor (index 2 of a 3-floor building): no floor above, so it spans
      // DOWN to floor 1 and reports the direction for a UI status message.
      final result = n.placeRiser('s1', 2, const Offset(0, 0), 3);
      expect(result, RiserPlacement.down);
      final net = c.read(networkControllerProvider).network;
      final riser = net.edges.single;
      expect(riser.kind, EdgeKind.riser);
      final floors = {
        net.nodeById(riser.fromId)!.floorIndex,
        net.nodeById(riser.toId)!.floorIndex,
      };
      expect(floors, {1, 2}, reason: 'spans the top floor down to the one below');
    });

    test('riser on floor 0 spans UP and reports it', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRiser);
      final result = n.placeRiser('s1', 0, const Offset(0, 0), 3);
      expect(result, RiserPlacement.up);
    });

    test('riser in a single-floor building reports none (nothing to span)', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRiser);
      final result = n.placeRiser('s1', 0, const Offset(0, 0), 1);
      expect(result, RiserPlacement.none);
      expect(c.read(networkControllerProvider).network.edges, isEmpty);
    });

    test('undo / redo / clear', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(100, 0));
      expect(n.canUndo, isTrue);
      n.undo();
      expect(c.read(networkControllerProvider).network.edges, isEmpty);
      n.redo();
      expect(c.read(networkControllerProvider).network.edges.length, 1);
      n.clear();
      expect(c.read(networkControllerProvider).network.nodes, isEmpty);
    });

    test('setService changes the active service and clears pending', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.setService(ServiceType.duct);
      expect(c.read(networkControllerProvider).service, ServiceType.duct);
      expect(c.read(networkControllerProvider).pendingPoint, isNull);
    });

    // ── Editing via the select tool ─────────────────────────────────────────

    NetworkController twoRunChain(ProviderContainer c) {
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0)); // n0
      n.placeRunPoint('s1', 0, const Offset(100, 0)); // n1, edge e
      n.placeRunPoint('s1', 0, const Offset(200, 0)); // n2, edge e
      n.setTool(DrawTool.select);
      return n;
    }

    test('deleteNode removes the node and its incident edges', () {
      final c = makeContainer();
      final n = twoRunChain(c);
      final mid = c.read(networkControllerProvider).network.nodes[1].id;
      n.deleteNode(mid);
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 2); // n0, n2 remain
      expect(net.edges, isEmpty); // both edges touched the mid node
    });

    test('deleteEdge removes the edge and prunes isolated junctions', () {
      final c = makeContainer();
      final n = twoRunChain(c);
      final firstEdge = c.read(networkControllerProvider).network.edges.first.id;
      n.deleteEdge(firstEdge);
      final net = c.read(networkControllerProvider).network;
      expect(net.edges.length, 1);
      // The endpoint left isolated by removing the first edge is pruned.
      expect(net.nodes.length, 2);
    });

    test('setNodeRole / setNodeFixture update the node; role change clears type',
        () {
      final c = makeContainer();
      final n = twoRunChain(c);
      final id = c.read(networkControllerProvider.notifier);
      final nodeId = c.read(networkControllerProvider).network.nodes.last.id;
      n.setNodeFixture(nodeId, PlumbingFixture.lavatory);
      var node = c.read(networkControllerProvider).network.nodeById(nodeId)!;
      expect(node.role, NodeRole.fixture);
      expect(node.fixture, PlumbingFixture.lavatory);
      // changing role away from fixture clears the fixture
      id.setNodeRole(nodeId, NodeRole.main);
      node = c.read(networkControllerProvider).network.nodeById(nodeId)!;
      expect(node.role, NodeRole.main);
      expect(node.fixture, isNull);
    });

    test('custom fixture and built-in fixture are mutually exclusive', () {
      final c = makeContainer();
      final n = twoRunChain(c);
      final nodeId = c.read(networkControllerProvider).network.nodes.last.id;

      // Assign a built-in fixture, then a custom one: the built-in is cleared.
      n.setNodeFixture(nodeId, PlumbingFixture.lavatory);
      n.setNodeCustomFixture(nodeId, 'cf-1');
      var node = c.read(networkControllerProvider).network.nodeById(nodeId)!;
      expect(node.role, NodeRole.fixture);
      expect(node.customFixtureId, 'cf-1');
      expect(node.fixture, isNull);

      // Now assign a built-in fixture: the custom one is cleared.
      n.setNodeFixture(nodeId, PlumbingFixture.shower);
      node = c.read(networkControllerProvider).network.nodeById(nodeId)!;
      expect(node.fixture, PlumbingFixture.shower);
      expect(node.customFixtureId, isNull);

      // Clearing the custom fixture (null) reverts to no custom reference and
      // preserves other fields (e.g. roofAreaM2 set below).
      n.setNodeRoofArea(nodeId, 75);
      n.setNodeCustomFixture(nodeId, 'cf-2');
      node = c.read(networkControllerProvider).network.nodeById(nodeId)!;
      expect(node.customFixtureId, 'cf-2');
      expect(node.roofAreaM2, 75); // survives the custom-fixture assignment
      n.setNodeCustomFixture(nodeId, null);
      node = c.read(networkControllerProvider).network.nodeById(nodeId)!;
      expect(node.customFixtureId, isNull);
      expect(node.roofAreaM2, 75);
    });

    test('setNodeRole leaving fixture clears the air-terminal airflow', () {
      final c = makeContainer();
      final n = twoRunChain(c);
      final nodeId = c.read(networkControllerProvider).network.nodes.last.id;
      n.setNodeAirflow(nodeId, FlowRate.litersPerSecond(45));
      var node = c.read(networkControllerProvider).network.nodeById(nodeId)!;
      expect(node.role, NodeRole.fixture);
      expect(node.airflow?.inLitersPerSecond, closeTo(45, 1e-9));
      // Switching to a non-terminal role drops the terminal payload (airflow),
      // mirroring how it drops a plumbing fixture type.
      n.setNodeRole(nodeId, NodeRole.plant);
      node = c.read(networkControllerProvider).network.nodeById(nodeId)!;
      expect(node.role, NodeRole.plant);
      expect(node.airflow, isNull);
    });

    test('setNodeElevation keeps a node air terminal airflow', () {
      final c = makeContainer();
      final n = twoRunChain(c);
      final nodeId = c.read(networkControllerProvider).network.nodes.last.id;
      n.setNodeAirflow(nodeId, FlowRate.litersPerSecond(60));
      n.setNodeElevation(nodeId, const Length(12));
      final node = c.read(networkControllerProvider).network.nodeById(nodeId)!;
      expect(node.elevation?.meters, 12);
      expect(node.airflow?.inLitersPerSecond, closeTo(60, 1e-9),
          reason: 'an elevation edit must not drop the airflow');
    });

    test('setEdgeService re-services an edge', () {
      final c = makeContainer();
      final n = twoRunChain(c);
      final edgeId = c.read(networkControllerProvider).network.edges.first.id;
      n.setEdgeService(edgeId, ServiceType.hotWater);
      final edge = c
          .read(networkControllerProvider)
          .network
          .edges
          .firstWhere((e) => e.id == edgeId);
      expect(edge.service, ServiceType.hotWater);
    });

    test('edits are undoable', () {
      final c = makeContainer();
      final n = twoRunChain(c);
      final mid = c.read(networkControllerProvider).network.nodes[1].id;
      n.deleteNode(mid);
      expect(c.read(networkControllerProvider).network.edges, isEmpty);
      n.undo();
      expect(c.read(networkControllerProvider).network.edges.length, 2);
    });

    test('duplicateFloor copies the floor runs to another sheet/floor', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(100, 0));
      n.placeRunPoint('s1', 0, const Offset(200, 0));
      final before = c.read(networkControllerProvider).network;
      final runsBefore = before.edges.where((e) => e.kind == EdgeKind.run).length;

      n.duplicateFloor(
        fromSheetId: 's1',
        fromFloor: 0,
        toSheetId: 's2',
        toFloor: 1,
      );
      final after = c.read(networkControllerProvider).network;
      // 3 nodes + 2 run edges copied onto s2/floor 1.
      final s2 = after.nodes.where((n) => n.sheetId == 's2').toList();
      expect(s2.length, 3);
      expect(s2.every((node) => node.floorIndex == 1), isTrue);
      expect(after.edges.length, before.edges.length + 2);
      // original untouched
      expect(after.nodes.where((node) => node.sheetId == 's1').length, 3);
      expect(runsBefore, 2);
    });

    test('duplicateFloor is a no-op when the source floor has no content', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.duplicateFloor(
          fromSheetId: 's1', fromFloor: 0, toSheetId: 's2', toFloor: 1);
      expect(c.read(networkControllerProvider).network.nodes, isEmpty);
    });

    test('J4: duplicateFloor also copies free-standing equipment nodes', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      // A run on s1/floor 0 …
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(100, 0));
      n.setTool(DrawTool.select);
      // … PLUS a loose fire extinguisher + hose reel placed before any pipe was
      // routed to them (zero incident edges).
      n.addComponentNode(
          's1', 0, const Offset(40, 60), NodeComponent.fireExtinguisher);
      n.addComponentNode('s1', 0, const Offset(80, 60), NodeComponent.hoseReel);

      final before = c.read(networkControllerProvider).network;
      expect(before.nodes.where((nd) => nd.sheetId == 's1').length, 4);

      n.duplicateFloor(
          fromSheetId: 's1', fromFloor: 0, toSheetId: 's2', toFloor: 1);
      final after = c.read(networkControllerProvider).network;
      final s2 = after.nodes.where((nd) => nd.sheetId == 's2').toList();
      // 2 run-wired nodes + the 2 loose equipment nodes all carried across.
      expect(s2.length, 4);
      expect(s2.every((nd) => nd.floorIndex == 1), isTrue);
      expect(
          s2.where((nd) => nd.component == NodeComponent.fireExtinguisher).length,
          1,
          reason: 'the loose extinguisher was copied, not silently dropped');
      expect(s2.where((nd) => nd.component == NodeComponent.hoseReel).length, 1);
      // The one run edge is copied; the loose nodes add none.
      final s2NodeIds = s2.map((nd) => nd.id).toSet();
      final s2Edges = after.edges.where(
          (e) => s2NodeIds.contains(e.fromId) && s2NodeIds.contains(e.toId));
      expect(s2Edges.length, 1);
    });

    test('J4: duplicateFloor copies loose equipment even with no runs', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addComponentNode(
          's1', 0, const Offset(40, 60), NodeComponent.fireExtinguisher);
      n.duplicateFloor(
          fromSheetId: 's1', fromFloor: 0, toSheetId: 's2', toFloor: 1);
      final after = c.read(networkControllerProvider).network;
      final s2 = after.nodes.where((nd) => nd.sheetId == 's2').toList();
      expect(s2.length, 1);
      expect(s2.single.component, NodeComponent.fireExtinguisher);
      expect(s2.single.floorIndex, 1);
    });

    test('F3: duplicateFloorToTargets is ONE undo step for the whole range',
        () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      // Two runs on s1/floor 0: 3 nodes, 2 run edges.
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(100, 0));
      n.placeRunPoint('s1', 0, const Offset(200, 0));
      n.setTool(DrawTool.select);
      final before = c.read(networkControllerProvider).network;
      final beforeNodes = before.nodes.length; // 3
      final beforeEdges = before.edges.length; // 2

      // Batch-duplicate onto THREE target floors in one action.
      n.duplicateFloorToTargets(
        fromSheetId: 's1',
        fromFloor: 0,
        targets: const [
          (sheetId: 's2', floor: 1),
          (sheetId: 's3', floor: 2),
          (sheetId: 's4', floor: 3),
        ],
      );
      final after = c.read(networkControllerProvider).network;
      // 3 targets × (3 nodes + 2 edges).
      expect(after.nodes.length, beforeNodes + 3 * 3);
      expect(after.edges.length, beforeEdges + 3 * 2);
      for (final s in const ['s2', 's3', 's4']) {
        expect(after.nodes.where((nd) => nd.sheetId == s).length, 3,
            reason: 'each target floor got its own copy of the 3 nodes');
      }

      // ONE undo (via the global timeline) restores the ENTIRE pre-duplicate
      // state — proving the whole range collapsed to a single history entry.
      c.read(historyProvider.notifier).undo();
      final undone = c.read(networkControllerProvider).network;
      expect(undone.nodes.length, beforeNodes);
      expect(undone.edges.length, beforeEdges);
      expect(undone.nodes.where((nd) => nd.sheetId != 's1'), isEmpty,
          reason: "a single undo removed all three floors' copies");
    });

    test('F3: duplicateFloorToTargets skips a source==target pair', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(100, 0));
      n.setTool(DrawTool.select);
      final before = c.read(networkControllerProvider).network.nodes.length;
      // The source pair is a no-op; only s2 receives a copy.
      n.duplicateFloorToTargets(
        fromSheetId: 's1',
        fromFloor: 0,
        targets: const [
          (sheetId: 's1', floor: 0),
          (sheetId: 's2', floor: 1),
        ],
      );
      final after = c.read(networkControllerProvider).network;
      expect(after.nodes.where((nd) => nd.sheetId == 's1').length, before);
      expect(after.nodes.where((nd) => nd.sheetId == 's2').length, before);
    });

    test('node drag moves the node and is a single undo step', () {
      final c = makeContainer();
      final n = twoRunChain(c);
      final id = c.read(networkControllerProvider).network.nodes.first.id;
      // one snapshot, then several live moves (as during a drag)
      n.pushUndoSnapshot();
      n.moveNode(id, 5, 5);
      n.moveNode(id, 40, 40);
      n.moveNode(id, 250, 120);
      final moved = c.read(networkControllerProvider).network.nodeById(id)!;
      expect(moved.x, 250);
      expect(moved.y, 120);
      // a single undo reverts the whole drag back to the original position
      n.undo();
      final reverted = c.read(networkControllerProvider).network.nodeById(id)!;
      expect(reverted.x, 0);
      expect(reverted.y, 0);
    });

    // ── B6/B7: floor-stack + sheet remap keep drawn work in range ────────────

    test('remapNodesForFloorChange (wholesale) clamps nodes above the new top',
        () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(const Network(nodes: [
        NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's1', x: 0, y: 0, floorIndex: 3),
        NetNode(id: 'c', sheetId: 's1', x: 0, y: 0, floorIndex: 5),
      ]));
      // New stack has 2 floors (max index 1): everything above clamps to 1.
      n.remapNodesForFloorChange(levelCount: 2);
      final f = {
        for (final x in c.read(networkControllerProvider).network.nodes)
          x.id: x.floorIndex
      };
      expect(f['a'], 0);
      expect(f['b'], 1);
      expect(f['c'], 1);
      // One undo step reverts the whole remap.
      n.undo();
      expect(
          c.read(networkControllerProvider).network.nodeById('c')!.floorIndex, 5);
    });

    test('remapNodesForFloorChange (removed middle) shifts higher nodes down',
        () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(const Network(nodes: [
        NetNode(id: 'lo', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'mid', sheetId: 's1', x: 0, y: 0, floorIndex: 2),
        NetNode(id: 'hi', sheetId: 's1', x: 0, y: 0, floorIndex: 4),
      ]));
      // Floor index 1 removed; new stack has 4 floors (max index 3).
      n.remapNodesForFloorChange(levelCount: 4, removedIndex: 1);
      final f = {
        for (final x in c.read(networkControllerProvider).network.nodes)
          x.id: x.floorIndex
      };
      expect(f['lo'], 0); // below the removal — untouched
      expect(f['mid'], 1); // above — shifted down one to keep its own floor
      expect(f['hi'], 3);
    });

    test('remapNodesForFloorChange is a no-op when nothing is out of range', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(const Network(nodes: [
        NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's1', x: 0, y: 0, floorIndex: 2),
      ]));
      n.remapNodesForFloorChange(levelCount: 6); // only grew — no change
      expect(n.canUndo, isFalse);
    });

    test('remapSheetFloor shifts only the named sheet\'s nodes, clamped', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(const Network(nodes: [
        NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's1', x: 0, y: 0, floorIndex: 1),
        NetNode(id: 'z', sheetId: 's2', x: 0, y: 0, floorIndex: 0),
      ]));
      // Move s1 up 2 floors in a 3-floor building (max index 2): the riser pair
      // shifts together, clamping at the top.
      n.remapSheetFloor('s1', 2, levelCount: 3);
      final f = {
        for (final x in c.read(networkControllerProvider).network.nodes)
          x.id: x.floorIndex
      };
      expect(f['a'], 2);
      expect(f['b'], 2); // 1+2=3 → clamped to the top floor (index 2)
      expect(f['z'], 0); // other sheet — untouched
    });

    test('remapSheetFloor with a zero delta records nothing', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(const Network(nodes: [
        NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 1),
      ]));
      n.remapSheetFloor('s1', 0, levelCount: 3);
      expect(n.canUndo, isFalse);
    });
  });

  group('drag-drop palette + per-segment material/size', () {
    ProviderContainer makeContainer() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('addSegment drops a default-length run of the active service', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setService(ServiceType.duct);
      n.addSegment('s1', 0, const Offset(200, 200));
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 2);
      expect(net.edges.length, 1);
      expect(net.edges.single.service, ServiceType.duct);
      // The two endpoints straddle the drop point horizontally.
      final xs = net.nodes.map((nd) => nd.x).toList()..sort();
      expect(xs.first, lessThan(200));
      expect(xs.last, greaterThan(200));
      expect(net.nodes.every((nd) => nd.y == 200), isTrue);
    });

    test('addSegment service override wins over the active service', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setService(ServiceType.coldWater);
      n.addSegment('s1', 0, const Offset(0, 0), service: ServiceType.duct);
      expect(c.read(networkControllerProvider).network.edges.single.service,
          ServiceType.duct);
    });

    test('addFitting drops a junction; addTerminal drops a fixture', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addFitting('s1', 0, const Offset(10, 10));
      n.addTerminal('s1', 0, const Offset(20, 20),
          fixture: PlumbingFixture.lavatory);
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 2);
      final fitting = net.nodes.firstWhere((nd) => nd.role == NodeRole.main);
      final terminal =
          net.nodes.firstWhere((nd) => nd.role == NodeRole.fixture);
      expect(fitting.fixture, isNull);
      expect(terminal.fixture, PlumbingFixture.lavatory);
    });

    test('addComponentNode drops equipment with the implied role + label', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addComponentNode('s1', 0, const Offset(5, 5), NodeComponent.pump);
      n.addComponentNode('s1', 0, const Offset(9, 9), NodeComponent.gateValve);
      n.addComponentNode('s1', 0, const Offset(7, 7), NodeComponent.roofDrain);
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 3);
      final pump =
          net.nodes.firstWhere((nd) => nd.component == NodeComponent.pump);
      expect(pump.role, NodeRole.plant); // a pump feeds the solve as plant
      final valve =
          net.nodes.firstWhere((nd) => nd.component == NodeComponent.gateValve);
      expect(valve.role, NodeRole.main);
      final drain =
          net.nodes.firstWhere((nd) => nd.component == NodeComponent.roofDrain);
      expect(drain.role, NodeRole.fixture);

      // setNodeComponent clears it (back to an ordinary node).
      n.setNodeComponent(pump.id, null);
      expect(c.read(networkControllerProvider).network.nodeById(pump.id)!.component,
          isNull);
    });

    test('setNodeFittingType overrides the junction fitting; auto/null clears',
        () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addFitting('s1', 0, const Offset(10, 10));
      final id = c.read(networkControllerProvider).network.nodes.single.id;
      NetNode node() => c.read(networkControllerProvider).network.nodeById(id)!;

      expect(node().fittingType, isNull); // auto by default
      n.setNodeFittingType(id, JunctionFitting.wye);
      expect(node().fittingType, JunctionFitting.wye);
      // Picking Auto clears the override back to geometry-derived (null).
      n.setNodeFittingType(id, JunctionFitting.auto);
      expect(node().fittingType, isNull);
      // Explicit null also clears.
      n.setNodeFittingType(id, JunctionFitting.tee);
      n.setNodeFittingType(id, null);
      expect(node().fittingType, isNull);
    });

    test('setEdgePipeProduct / setEdgeDuctProduct / setEdgeSizeOverride', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addSegment('s1', 0, const Offset(0, 0), service: ServiceType.coldWater);
      final id = c.read(networkControllerProvider).network.edges.single.id;

      n.setEdgePipeProduct(id, PipeProduct.pprPn16);
      expect(c.read(networkControllerProvider).network.edges.single.pipeProduct,
          PipeProduct.pprPn16);

      n.setEdgeSizeOverride(id, Diameter.mm(50));
      expect(
          c
              .read(networkControllerProvider)
              .network
              .edges
              .single
              .sizeOverride
              ?.inMillimeters,
          closeTo(50, 1e-9));

      n.setEdgeDuctProduct(id, DuctProduct.bjls);
      expect(c.read(networkControllerProvider).network.edges.single.ductProduct,
          DuctProduct.bjls);

      // Clearing with null nulls the fields.
      n.setEdgePipeProduct(id, null);
      n.setEdgeSizeOverride(id, null);
      n.setEdgeDuctProduct(id, null);
      final e = c.read(networkControllerProvider).network.edges.single;
      expect(e.pipeProduct, isNull);
      expect(e.sizeOverride, isNull);
      expect(e.ductProduct, isNull);
    });

    test('endNodeDragWithSnap merges a dropped endpoint onto a nearby node', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      // Two separate segments whose near endpoints are close together.
      n.addSegment('s1', 0, const Offset(100, 0), spanPx: 100); // nodes ~ (50,0)-(150,0)
      n.addSegment('s1', 0, const Offset(300, 0), spanPx: 100); // ~ (250,0)-(350,0)
      var net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 4);
      expect(net.edges.length, 2);

      // Drag the right end of segment 1 (x≈150) onto the left end of segment 2
      // (x≈250). Find the node at x≈150 and move it next to x≈250.
      final dragged =
          net.nodes.firstWhere((nd) => (nd.x - 150).abs() < 1e-6);
      final target = net.nodes.firstWhere((nd) => (nd.x - 250).abs() < 1e-6);
      n.pushUndoSnapshot();
      n.moveNode(dragged.id, target.x + 2, target.y); // within snap radius
      n.endNodeDragWithSnap(dragged.id, 14);

      net = c.read(networkControllerProvider).network;
      // The dragged node is gone (merged into the target); edges re-pointed.
      expect(net.nodeById(dragged.id), isNull);
      expect(net.nodes.length, 3);
      expect(net.edges.length, 2); // both edges survive, now sharing a node
      expect(net.edgesAt(target.id).length, 2);
    });

    test('endNodeDragWithSnap is a no-op with nothing nearby', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addSegment('s1', 0, const Offset(0, 0));
      final before = c.read(networkControllerProvider).network.nodes.length;
      final id = c.read(networkControllerProvider).network.nodes.first.id;
      n.endNodeDragWithSnap(id, 14);
      expect(c.read(networkControllerProvider).network.nodes.length, before);
    });

    test('dragging a FREE fixture onto a main taps in (split + branch pipe)', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      // A cold-water main from ~(50,0) to ~(150,0).
      n.addSegment('s1', 0, const Offset(100, 0),
          spanPx: 100, service: ServiceType.coldWater);
      // A free fixture dropped below the main's midpoint.
      n.addTerminal('s1', 0, const Offset(100, 40),
          fixture: PlumbingFixture.lavatory);
      var net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 3); // 2 main + 1 fixture
      expect(net.edges.length, 1);
      final fixture =
          net.nodes.firstWhere((nd) => nd.fixture == PlumbingFixture.lavatory);

      // Drag the fixture up to within the snap radius of the main (y≈0), away
      // from either endpoint (x≈100, the midpoint).
      n.pushUndoSnapshot();
      n.moveNode(fixture.id, 100, 6);
      n.endNodeDragWithSnap(fixture.id, 14);

      net = c.read(networkControllerProvider).network;
      // The fixture survives (it didn't merge); a junction split the main, and a
      // new branch pipe connects the fixture to that junction.
      expect(net.nodeById(fixture.id), isNotNull);
      expect(net.nodes.length, 4); // + the split junction
      expect(net.edges.length, 3); // main split into 2 + the branch
      // The fixture now has exactly one edge — the branch — carrying the main's
      // service.
      final branch = net.edgesAt(fixture.id).single;
      expect(branch.service, ServiceType.coldWater);
    });

    test('one drag + snap-merge is ONE undo step back to the pre-drag network',
        () {
      // G4: the drag pushes its snapshot at onPanStart (pushUndoSnapshot); the
      // drag-end merge must NOT push a second one — the first Ctrl+Z restores
      // the exact pre-drag network, never an unmerged intermediate.
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addSegment('s1', 0, const Offset(100, 0), spanPx: 100); // ~(50)-(150)
      n.addSegment('s1', 0, const Offset(300, 0), spanPx: 100); // ~(250)-(350)
      var net = c.read(networkControllerProvider).network;
      final dragged = net.nodes.firstWhere((nd) => (nd.x - 150).abs() < 1e-6);
      final target = net.nodes.firstWhere((nd) => (nd.x - 250).abs() < 1e-6);

      n.pushUndoSnapshot(); // drag start
      n.moveNode(dragged.id, target.x + 2, target.y); // live drag
      n.endNodeDragWithSnap(dragged.id, 14); // drag end — merge
      expect(c.read(networkControllerProvider).network.nodes.length, 3);

      // ONE undo — straight back to the pre-drag network.
      n.undo();
      net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 4);
      expect(net.edges.length, 2);
      final restored = net.nodeById(dragged.id)!;
      expect(restored.x, closeTo(150, 1e-9));
      expect(restored.y, closeTo(0, 1e-9));
      // And redo re-applies the whole drag+merge as one step.
      n.redo();
      expect(c.read(networkControllerProvider).network.nodes.length, 3);
      expect(c.read(networkControllerProvider).network.nodeById(dragged.id),
          isNull);
    });

    test('one drag + snap is ONE entry on the GLOBAL history timeline', () {
      // The merge path must not record a second timeline entry either, or the
      // global Ctrl+Z would pop a no-op before reverting the drag.
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addSegment('s1', 0, const Offset(100, 0), spanPx: 100);
      n.addSegment('s1', 0, const Offset(300, 0), spanPx: 100);
      var net = c.read(networkControllerProvider).network;
      final dragged = net.nodes.firstWhere((nd) => (nd.x - 150).abs() < 1e-6);
      final target = net.nodes.firstWhere((nd) => (nd.x - 250).abs() < 1e-6);

      n.pushUndoSnapshot();
      n.moveNode(dragged.id, target.x + 2, target.y);
      n.endNodeDragWithSnap(dragged.id, 14);

      // ONE global undo reverts the whole drag (to 4 unmerged nodes at the
      // original positions), not to a half-done intermediate.
      c.read(historyProvider.notifier).undo();
      net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 4);
      expect(net.nodeById(dragged.id)!.x, closeTo(150, 1e-9));
    });

    test('drag + tap-in of a free fixture is ONE undo step', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addSegment('s1', 0, const Offset(100, 0),
          spanPx: 100, service: ServiceType.coldWater);
      n.addTerminal('s1', 0, const Offset(100, 40),
          fixture: PlumbingFixture.lavatory);
      final fixture = c
          .read(networkControllerProvider)
          .network
          .nodes
          .firstWhere((nd) => nd.fixture == PlumbingFixture.lavatory);

      n.pushUndoSnapshot();
      n.moveNode(fixture.id, 100, 6);
      n.endNodeDragWithSnap(fixture.id, 14);
      expect(c.read(networkControllerProvider).network.edges.length, 3);

      // ONE undo restores the free fixture at its pre-drag spot.
      n.undo();
      final net = c.read(networkControllerProvider).network;
      expect(net.edges.length, 1);
      expect(net.nodes.length, 3);
      final restored = net.nodeById(fixture.id)!;
      expect(restored.x, closeTo(100, 1e-9));
      expect(restored.y, closeTo(40, 1e-9));
    });

    test(
        'endNodeDragWithSnap WITHOUT a prior snapshot still records its own '
        'undo step (safe programmatic path)', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addSegment('s1', 0, const Offset(100, 0), spanPx: 100); // ~(50)-(150)
      n.addSegment('s1', 0, const Offset(320, 0), spanPx: 100); // ~(270)-(370)
      final net0 = c.read(networkControllerProvider).network;
      final dragged =
          net0.nodes.firstWhere((nd) => (nd.x - 150).abs() < 1e-6);

      // A silent live move, then the snap — but NO pushUndoSnapshot: the merge
      // must fall back to a full commit so it stays undoable on its own.
      n.moveNode(dragged.id, 268, 0);
      n.endNodeDragWithSnap(dragged.id, 14);
      expect(c.read(networkControllerProvider).network.nodes.length, 3);

      // Undo restores the pre-MERGE state (the unmerged 4-node network).
      n.undo();
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 4);
      expect(net.nodeById(dragged.id), isNotNull);
    });

    test('a drag with no merge does not bleed into the NEXT edit\'s undo', () {
      // pushUndoSnapshot arms the drag-end replace; a plain move (no snap)
      // never commits, so the NEXT ordinary edit must still push its own
      // snapshot — one undo reverts only that edit, a second the drag.
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addFitting('s1', 0, const Offset(10, 10));
      n.addFitting('s1', 0, const Offset(500, 500));
      final net0 = c.read(networkControllerProvider).network;
      final moved = net0.nodes.first;
      final other = net0.nodes.last;

      n.pushUndoSnapshot();
      n.moveNode(moved.id, 60, 60);
      n.endNodeDragWithSnap(moved.id, 14); // nothing nearby — no commit

      n.deleteNode(other.id); // an ordinary edit after the drag
      expect(c.read(networkControllerProvider).network.nodes.length, 1);

      // First undo: only the delete comes back — the drag survives.
      n.undo();
      var net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 2);
      expect(net.nodeById(moved.id)!.x, closeTo(60, 1e-9));
      // Second undo: the drag itself.
      n.undo();
      net = c.read(networkControllerProvider).network;
      expect(net.nodeById(moved.id)!.x, closeTo(10, 1e-9));
    });
  });

  group('drawRunFromNode (pull a mainline out of a node)', () {
    ProviderContainer makeContainer() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('pulls a new run + fresh junction out of a riser', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setService(ServiceType.coldWater);
      n.addComponentNode('s1', 0, const Offset(100, 100), NodeComponent.riser);
      final riser = c.read(networkControllerProvider).network.nodes.single;

      final eid = n.drawRunFromNode(riser.id, const Offset(300, 100));
      expect(eid, isNotNull);
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 2); // riser + the new far junction
      expect(net.edges.length, 1);
      final edge = net.edges.single;
      expect(edge.fromId, riser.id);
      expect(edge.service, ServiceType.coldWater);
      final far = net.nodeById(edge.toId)!;
      expect(far.x, 300);
      expect(far.y, 100);
      expect(far.role, NodeRole.main);
    });

    test('far end snaps onto an existing node within radius (no new node)', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addFitting('s1', 0, const Offset(300, 100));
      n.addComponentNode('s1', 0, const Offset(100, 100), NodeComponent.riser);
      final net0 = c.read(networkControllerProvider).network;
      final fitting =
          net0.nodes.firstWhere((nd) => nd.component == null);
      final riser =
          net0.nodes.firstWhere((nd) => nd.component == NodeComponent.riser);

      n.drawRunFromNode(riser.id, const Offset(302, 101), snapRadius: 14);
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 2); // snapped — no third node
      expect(net.edges.length, 1);
      expect(net.edges.single.toId, fitting.id);
    });

    test('far end taps into a nearby run, splitting it', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      // A run from (200,0) to (400,0).
      n.addSegment('s1', 0, const Offset(300, 0),
          spanPx: 200, service: ServiceType.coldWater);
      n.addComponentNode('s1', 0, const Offset(300, 80), NodeComponent.riser);
      final riser = c.read(networkControllerProvider).network.nodes
          .firstWhere((nd) => nd.component == NodeComponent.riser);

      // Release near the run's midpoint (y≈0), away from either endpoint.
      n.drawRunFromNode(riser.id, const Offset(300, 6), snapRadius: 14);
      final net = c.read(networkControllerProvider).network;
      // run endpoints (2) + riser (1) + the split junction (1)
      expect(net.nodes.length, 4);
      // run split into 2 + the new branch from the riser
      expect(net.edges.length, 3);
      // The riser's single edge ends at the new junction sitting on the main.
      final branch = net.edgesAt(riser.id).single;
      final junction = net.nodeById(branch.toId)!;
      expect(junction.y, closeTo(0, 1e-6));
      expect(junction.x, closeTo(300, 1e-6));
    });

    test('a pulled run inherits the source node\'s existing service', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addSegment('s1', 0, const Offset(0, 0),
          spanPx: 100, service: ServiceType.hotWater);
      final from = c.read(networkControllerProvider).network.edges.single.fromId;
      // Active service is something else — the pulled run must still inherit hot.
      n.setService(ServiceType.coldWater);

      final eid = n.drawRunFromNode(from, const Offset(0, 200));
      final edge = c
          .read(networkControllerProvider)
          .network
          .edges
          .firstWhere((e) => e.id == eid);
      expect(edge.service, ServiceType.hotWater);
    });

    test('releasing back on the source lays nothing', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addComponentNode('s1', 0, const Offset(50, 50), NodeComponent.riser);
      final riser = c.read(networkControllerProvider).network.nodes.single;
      final eid = n.drawRunFromNode(riser.id, const Offset(51, 51), snapRadius: 14);
      expect(eid, isNull);
      expect(c.read(networkControllerProvider).network.edges, isEmpty);
    });
  });

  testWidgets('draw palette renders; Run tool activates without error',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    expect(find.text('DRAW'), findsOneWidget);
    expect(find.text('Run'), findsOneWidget);
    // 'Riser' is both the DRAW tool button and the (renamed) nav-rail item.
    expect(find.text('Riser'), findsWidgets);
    // 'Cold water' appears in both the DRAW chips and the node palette.
    expect(find.text('Cold water'), findsWidgets);

    await tester.ensureVisible(find.text('Run'));
    await tester.tap(find.text('Run'));
    await tester.pump();

    // drawing two points on the canvas must not throw
    await tester.tapAt(const Offset(330, 300));
    await tester.pump();
    await tester.tapAt(const Offset(400, 320));
    await tester.pump();
  });

  testWidgets('palette cards render in the inspector', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    // The node palette: the Riser as the mainline start (you drag a run out of
    // it), plus the generic Fitting / Terminal endpoints. Pipe-segment cards are
    // gone — mains are pulled out of nodes, not dropped as pre-made segments.
    expect(find.text('MAINLINE START'), findsOneWidget);
    expect(find.text('NODES'), findsOneWidget);
    expect(find.text('Riser node'), findsOneWidget);
    expect(find.text('Fitting'), findsOneWidget);
    expect(find.text('Terminal'), findsOneWidget);
  });

  testWidgets('right-clicking a drawn segment opens the size/material menu',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50)); // first-frame fit

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedDemoSheets(container);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50)); // first-frame fit
    final ctrl = container.read(networkControllerProvider.notifier);
    // A horizontal cold-water run across the ground-floor sheet.
    ctrl.setService(ServiceType.coldWater);
    ctrl.setTool(DrawTool.drawRun);
    ctrl.placeRunPoint('s1', 0, const Offset(360, 360));
    ctrl.placeRunPoint('s1', 0, const Offset(1040, 360));
    ctrl.setTool(DrawTool.select);
    await tester.pump();

    final edgeId = container.read(networkControllerProvider).network.edges.first.id;
    final transform =
        container.read(sheetsControllerProvider).viewportFor('s1');
    expect(transform, isNotNull);
    // Mid-segment in the overlay's LOCAL space, then to GLOBAL via its box.
    final localMid = transform!.worldToScreen(const Offset(700, 360));
    final overlayBox = tester.renderObject<RenderBox>(
        find.byType(NetworkSelectionOverlay).first);
    final globalMid = overlayBox.localToGlobal(localMid);

    final gesture =
        await tester.startGesture(globalMid, buttons: kSecondaryButton);
    await gesture.up();
    await tester.pump();

    // The pipe menu offers Set size + Pipe material; selection followed.
    expect(find.text('SET SIZE'), findsOneWidget);
    expect(find.text('PIPE MATERIAL'), findsOneWidget);
    expect(container.read(selectionProvider).edgeId, edgeId);

    // Pick 2" → DN50 (npsLabel(2.0) == '2"', mm 50).
    await tester.tap(find.text('2"   DN50'));
    await tester.pump();

    final edge =
        container.read(networkControllerProvider).network.edges.first;
    expect(edge.sizeOverride?.inMillimeters, closeTo(50, 1e-6));
    // Menu dismissed after the pick.
    expect(find.text('SET SIZE'), findsNothing);
  });

  testWidgets('right-clicking a duct segment shows the sheet-material takeoff',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedDemoSheets(container);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50)); // first-frame fit
    // Calibrate (so length/area are real) and make HVAC the active layer.
    container
        .read(projectControllerProvider.notifier)
        .setCalibration('s1', const ScaleCalibration(0.02));
    container
        .read(activeDisciplineProvider.notifier)
        .set(DisciplineLayer.hvac);

    final ctrl = container.read(networkControllerProvider.notifier);
    ctrl.setService(ServiceType.duct);
    ctrl.setTool(DrawTool.drawRun);
    ctrl.placeRunPoint('s1', 0, const Offset(360, 360));
    ctrl.placeRunPoint('s1', 0, const Offset(1040, 360));
    ctrl.setTool(DrawTool.select);
    // Airflow at the far node so the duct sizes (and so a takeoff exists).
    final far = container
        .read(networkControllerProvider)
        .network
        .nodes
        .reduce((a, b) => a.x > b.x ? a : b);
    ctrl.setNodeAirflow(far.id, FlowRate.litersPerSecond(500));
    await tester.pump();

    final transform =
        container.read(sheetsControllerProvider).viewportFor('s1')!;
    final overlayBox = tester.renderObject<RenderBox>(
        find.byType(NetworkSelectionOverlay).first);
    final globalMid =
        overlayBox.localToGlobal(transform.worldToScreen(const Offset(700, 360)));
    final gesture =
        await tester.startGesture(globalMid, buttons: kSecondaryButton);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 50));

    // The duct menu shows the material picker + the sheet-material takeoff +
    // the ducting-accessories takeoff (covering angle etc).
    expect(find.text('DUCT MATERIAL'), findsOneWidget);
    expect(find.textContaining('Sheet material:'), findsOneWidget);
    // The accessories note shows in both the menu and the inspector selection.
    expect(find.textContaining('Accessories:'), findsWidgets);
    expect(find.textContaining('covering angle'), findsWidgets);
  });

  testWidgets(
      'right-clicking an EQUIPMENT node opens the node menu (select similar / '
      'delete; no fitting rows)', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50)); // first-frame fit

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedDemoSheets(container);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50)); // first-frame fit
    final ctrl = container.read(networkControllerProvider.notifier);
    ctrl.addComponentNode(
        's1', 0, const Offset(700, 360), NodeComponent.gateValve);
    await tester.pump();
    final nodeId =
        container.read(networkControllerProvider).network.nodes.single.id;

    final transform =
        container.read(sheetsControllerProvider).viewportFor('s1')!;
    final overlayBox = tester.renderObject<RenderBox>(
        find.byType(NetworkSelectionOverlay).first);
    final globalPos =
        overlayBox.localToGlobal(transform.worldToScreen(const Offset(700, 360)));
    final gesture =
        await tester.startGesture(globalPos, buttons: kSecondaryButton);
    await gesture.up();
    await tester.pump();

    // The generalized node menu: Select similar + Delete for any node; the
    // fitting rows only belong to a bare junction, and a valve isn't one.
    // (Finders are scoped to the menu — the inspector Selection section can
    // carry look-alike labels.)
    final menu = find.byType(MechXContextMenu);
    expect(menu, findsOneWidget);
    expect(find.descendant(of: menu, matching: find.text('Select similar')),
        findsOneWidget);
    expect(find.descendant(of: menu, matching: find.text('Delete node')),
        findsOneWidget);
    expect(find.descendant(of: menu, matching: find.text('FITTING')),
        findsNothing);
    expect(container.read(selectionProvider).nodeId, nodeId);

    await tester.tap(find.descendant(of: menu, matching: find.text('Delete node')));
    await tester.pump();
    expect(container.read(networkControllerProvider).network.nodes, isEmpty);
    expect(find.byType(MechXContextMenu), findsNothing);
  });

  testWidgets(
      'right-clicking an AIR TERMINAL offers the face-size ladder '
      '(mirrors the inspector picker)', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedDemoSheets(container);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50)); // first-frame fit
    final ctrl = container.read(networkControllerProvider.notifier);
    ctrl.addComponentNode(
        's1', 0, const Offset(700, 360), NodeComponent.supplyDiffuser);
    await tester.pump();
    final nodeId =
        container.read(networkControllerProvider).network.nodes.single.id;

    final transform =
        container.read(sheetsControllerProvider).viewportFor('s1')!;
    final overlayBox = tester.renderObject<RenderBox>(
        find.byType(NetworkSelectionOverlay).first);
    final globalPos =
        overlayBox.localToGlobal(transform.worldToScreen(const Offset(700, 360)));
    final gesture =
        await tester.startGesture(globalPos, buttons: kSecondaryButton);
    await gesture.up();
    await tester.pump();

    final menu = find.byType(MechXContextMenu);
    expect(find.descendant(of: menu, matching: find.text('FACE SIZE')),
        findsOneWidget);
    await tester.tap(find.descendant(of: menu, matching: find.text('600x600')));
    await tester.pump();

    final node =
        container.read(networkControllerProvider).network.nodeById(nodeId)!;
    expect(node.faceWidthMm, 600);
    expect(node.faceHeightMm, 600);
  });

  testWidgets(
      'right-clicking EMPTY canvas opens the canvas menu; Select all / Paste '
      'here work', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedDemoSheets(container);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50)); // first-frame fit
    final ctrl = container.read(networkControllerProvider.notifier);
    ctrl.setService(ServiceType.coldWater);
    ctrl.setTool(DrawTool.drawRun);
    ctrl.placeRunPoint('s1', 0, const Offset(360, 360));
    ctrl.placeRunPoint('s1', 0, const Offset(1040, 360));
    ctrl.setTool(DrawTool.select);
    final net = container.read(networkControllerProvider).network;
    ctrl.copySelection(net.nodes.map((nd) => nd.id).toSet(),
        net.edges.map((e) => e.id).toSet());
    await tester.pump();

    final transform =
        container.read(sheetsControllerProvider).viewportFor('s1')!;
    final overlayBox = tester.renderObject<RenderBox>(
        find.byType(NetworkSelectionOverlay).first);
    // An empty spot well away from the drawn run.
    final globalPos =
        overlayBox.localToGlobal(transform.worldToScreen(const Offset(700, 800)));
    final gesture =
        await tester.startGesture(globalPos, buttons: kSecondaryButton);
    await gesture.up();
    await tester.pump();

    expect(find.text('Paste here'), findsOneWidget);
    expect(find.text('Select all on this floor'), findsOneWidget);
    expect(find.text('Fit view'), findsOneWidget);

    await tester.tap(find.text('Select all on this floor'));
    await tester.pump();
    final sel = container.read(selectionProvider);
    expect(sel.edgeIds.length, 1);
    expect(sel.nodeIds.length, 2);
    expect(find.text('Select all on this floor'), findsNothing);
  });

  testWidgets(
      'double-clicking a node un-collapses the inspector and expands its '
      'sizing section', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedDemoSheets(container);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50)); // first-frame fit
    // Collapse the inspector; double-click must bring it back.
    container.read(inspectorCollapsedProvider.notifier).set(true);
    final ctrl = container.read(networkControllerProvider.notifier);
    ctrl.setService(ServiceType.coldWater);
    ctrl.setTool(DrawTool.drawRun);
    ctrl.placeRunPoint('s1', 0, const Offset(360, 360));
    ctrl.placeRunPoint('s1', 0, const Offset(1040, 360));
    ctrl.setTool(DrawTool.select);
    await tester.pump();

    final nodeId = container
        .read(networkControllerProvider)
        .network
        .nodes
        .firstWhere((nd) => nd.x == 360)
        .id;
    final transform =
        container.read(sheetsControllerProvider).viewportFor('s1')!;
    final overlayBox = tester.renderObject<RenderBox>(
        find.byType(NetworkSelectionOverlay).first);
    final globalPos =
        overlayBox.localToGlobal(transform.worldToScreen(const Offset(360, 360)));

    // Two quick primary taps on the same node (the manual double-click path —
    // the first selects instantly, the second opens).
    await tester.tapAt(globalPos);
    await tester.pump(const Duration(milliseconds: 50));
    expect(container.read(selectionProvider).nodeId, nodeId);
    expect(container.read(inspectorCollapsedProvider), isTrue);

    await tester.tapAt(globalPos);
    await tester.pump();
    expect(container.read(inspectorCollapsedProvider), isFalse);
    // A cold-water node's relevant section is 'Design inputs' (E5 rename of the
    // former 'Sizing' section).
    expect(
        container.read(
            sectionExpandedProvider(const SectionKey('Design inputs', false))),
        isTrue);
  });

  test('node edits preserve customFixtureId + roofAreaM2 (no data loss)', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(networkControllerProvider.notifier);
    n.setService(ServiceType.coldWater);
    n.setTool(DrawTool.drawRun);
    n.placeRunPoint('s1', 0, const Offset(0, 0));
    n.placeRunPoint('s1', 0, const Offset(100, 0));
    final id = c.read(networkControllerProvider).network.nodes.first.id;
    NetNode node() => c.read(networkControllerProvider).network.nodeById(id)!;

    n.setNodeRoofArea(id, 250);
    n.setNodeCustomFixture(id, 'cf-1');
    expect(node().roofAreaM2, 250);
    expect(node().customFixtureId, 'cf-1');

    // An airflow edit must not drop the roof area or custom fixture.
    n.setNodeAirflow(id, FlowRate.litersPerSecond(30));
    expect(node().roofAreaM2, 250, reason: 'airflow edit dropped roofAreaM2');
    expect(node().customFixtureId, 'cf-1',
        reason: 'airflow edit dropped customFixtureId');
    expect(node().airflow!.inLitersPerSecond, 30);

    // An elevation edit must preserve both too.
    n.setNodeElevation(id, const Length(3));
    expect(node().roofAreaM2, 250, reason: 'elevation edit dropped roofAreaM2');
    expect(node().customFixtureId, 'cf-1',
        reason: 'elevation edit dropped customFixtureId');
    expect(node().elevation!.meters, 3);
  });

  group('autoPlaceRoomTerminals (room -> network)', () {
    // A 100x50 px room at 0.1 m/px = 10 m x 5 m = 50 m^2 footprint, default
    // 3 m ceiling, default office room type.
    //   volume        = 50 * 3            = 150 m^3
    //   office ACH     = 6.0
    //   Q              = 150 * 6 / 3600   = 0.25 m^3/s
    //   max per face   = 0.36 (600x600) * 0.8 * 3.0 (office) = 0.864 m^3/s
    //   supply count   = ceil(0.25 / 0.864)                  = 1
    //   each airflow   = 0.25 m^3/s
    //   face: smallest std gross >= 0.25/(0.8*3.0)=0.10417 m^2 -> 450x300 mm
    // So: 1 supply diffuser + 1 return grille, each 0.25 m^3/s, 450x300 mm.
    const room = RoomArea(
      id: 'r0',
      sheetId: 's1',
      floorIndex: 0,
      ax: 100,
      ay: 100,
      bx: 200, // 100 px wide
      by: 150, // 50 px tall
    );

    test('a 50 m2 office room places the sized diffuser + return grille', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(networkControllerProvider.notifier);

      final ids =
          n.autoPlaceRoomTerminals(room: room, metersPerPixel: 0.1);
      expect(ids.length, 1, reason: 'one supply diffuser for 0.25 m^3/s');

      final net = c.read(networkControllerProvider).network;
      final supplies = [
        for (final node in net.nodes)
          if (node.component == NodeComponent.supplyDiffuser) node,
      ];
      final returns = [
        for (final node in net.nodes)
          if (node.component == NodeComponent.returnGrille) node,
      ];

      expect(supplies.length, 1);
      expect(returns.length, 1);
      expect(net.nodes.length, 2);

      // Each supply diffuser carries the per-terminal airflow + chosen face.
      final sup = supplies.single;
      expect(sup.airflow!.cubicMetersPerSecond, closeTo(0.25, 1e-9));
      expect(sup.faceWidthMm, 450);
      expect(sup.faceHeightMm, 300);
      expect(sup.role, NodeRole.fixture);

      // The return grille matches.
      final ret = returns.single;
      expect(ret.airflow!.cubicMetersPerSecond, closeTo(0.25, 1e-9));
      expect(ret.faceWidthMm, 450);
      expect(ret.faceHeightMm, 300);

      // All nodes on the room's sheet/floor and inside the footprint.
      for (final node in net.nodes) {
        expect(node.sheetId, 's1');
        expect(node.floorIndex, 0);
        expect(node.x, inInclusiveRange(100, 200));
        expect(node.y, inInclusiveRange(100, 150));
      }

      // One undo step puts the network back to empty.
      expect(n.canUndo, isTrue);
    });

    test('no scale (null metersPerPixel degenerate) is a no-op', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(networkControllerProvider.notifier);
      // A zero-width room -> degenerate footprint -> sizing null -> no-op.
      const flat = RoomArea(
        id: 'r1',
        sheetId: 's1',
        floorIndex: 0,
        ax: 100,
        ay: 100,
        bx: 100,
        by: 150,
      );
      final ids = n.autoPlaceRoomTerminals(room: flat, metersPerPixel: 0.1);
      expect(ids, isEmpty);
      expect(c.read(networkControllerProvider).network.nodes, isEmpty);
      expect(n.canUndo, isFalse);
    });
  });

  group('pruneNodesNotOnSheets (A5 orphan prune on Replace-all import)', () {
    ProviderContainer makeContainer() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('drops nodes off the live sheets + their edges in ONE undo step', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      final history = c.read(historyProvider.notifier);
      // A run on the (now-gone) old sheet s1, and a run on the surviving s2.
      n.loadNetwork(const Network(
        nodes: [
          NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'b', sheetId: 's1', x: 10, y: 0, floorIndex: 0),
          NetNode(id: 'c', sheetId: 's2', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'd', sheetId: 's2', x: 10, y: 0, floorIndex: 0),
        ],
        edges: [
          NetEdge(id: 'e1', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
          NetEdge(id: 'e2', fromId: 'c', toId: 'd', service: ServiceType.coldWater),
        ],
      ));

      // The new sheet set after a Replace keeps only s2.
      n.pruneNodesNotOnSheets({'s2'});

      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.map((x) => x.id).toSet(), {'c', 'd'});
      expect(net.edges.map((x) => x.id).toSet(), {'e2'});
      // One undo step reverses the whole prune.
      expect(history.canUndo, isTrue);
      history.undo();
      expect(
          c.read(networkControllerProvider).network.nodes.length, 4);
    });

    test('no-op (byte-identical, no undo) when every node is on a live sheet',
        () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(const Network(nodes: [
        NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's2', x: 0, y: 0, floorIndex: 0),
      ]));
      final before = c.read(networkControllerProvider).network;

      n.pruneNodesNotOnSheets({'s1', 's2'});

      expect(c.read(networkControllerProvider).network, same(before));
      expect(n.canUndo, isFalse);
    });

    test('an empty live set prunes every node', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(const Network(nodes: [
        NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
      ]));
      n.pruneNodesNotOnSheets(const {});
      expect(c.read(networkControllerProvider).network.nodes, isEmpty);
      expect(n.canUndo, isTrue);
    });
  });

  group('C1: Run tool tees into an existing pipe', () {
    ProviderContainer makeContainer() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('a run whose endpoint lands ON a main SPLITS it (tees in)', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setService(ServiceType.coldWater);
      // Main run A(0,0)-B(200,0): 2 nodes, 1 edge.
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(200, 0));
      n.setTool(DrawTool.drawRun); // clear pending
      // A new run from (100,80) down to (100,2) — the far end lands on the main
      // midpoint (closest point (100,0), 2 px away < snap radius), so it tees in.
      n.placeRunPoint('s1', 0, const Offset(100, 80)); // fresh start node C
      n.placeRunPoint('s1', 0, const Offset(100, 2)); // tees into the main at J

      final net = c.read(networkControllerProvider).network;
      // A, B, C + the split junction J = 4 nodes.
      expect(net.nodes.length, 4);
      // Main split into A-J + J-B, plus the new branch C-J = 3 edges.
      expect(net.edges.length, 3);
      // The junction sits on the main at (100,0) with degree 3.
      final j = net.nodes.firstWhere(
          (nd) => (nd.x - 100).abs() < 1e-6 && (nd.y).abs() < 1e-6);
      expect(net.edgesAt(j.id).length, 3);
      // Both split halves keep the main's cold-water service.
      for (final e in net.edgesAt(j.id)) {
        expect(e.service, ServiceType.coldWater);
      }
    });

    test('teeing carries the split edge\'s size override to BOTH halves', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setService(ServiceType.coldWater);
      n.addSegment('s1', 0, const Offset(100, 0),
          spanPx: 200, service: ServiceType.coldWater); // ~(0,0)-(200,0)
      final mainId = c.read(networkControllerProvider).network.edges.single.id;
      n.setEdgeSizeOverride(mainId, Diameter.mm(50));

      // Tee a run into the middle of the main.
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(100, 80));
      n.placeRunPoint('s1', 0, const Offset(100, 2));

      final net = c.read(networkControllerProvider).network;
      final sized = net.edges
          .where((e) => e.sizeOverride?.inMillimeters != null)
          .toList();
      // Exactly the two halves of the split main keep the 50 mm override; the
      // new branch run carries none.
      expect(sized.length, 2);
      for (final e in sized) {
        expect(e.sizeOverride!.inMillimeters, closeTo(50, 1e-6));
      }
    });

    test('a run drawn away from any edge does NOT tee (byte-identical path)', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(200, 0)); // main
      n.setTool(DrawTool.drawRun);
      // A parallel run well clear of the main — no split.
      n.placeRunPoint('s1', 0, const Offset(0, 300));
      n.placeRunPoint('s1', 0, const Offset(200, 300));
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 4);
      expect(net.edges.length, 2);
    });

    test('a run does NOT tee into a DIFFERENT-service pipe it crosses', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      // A drainage main D: A(0,0)-B(200,0).
      n.setService(ServiceType.drainage);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(200, 0));
      n.setTool(DrawTool.drawRun);
      // Now draw a COLD-WATER run whose endpoint lands ON the drainage main.
      n.setService(ServiceType.coldWater);
      n.placeRunPoint('s1', 0, const Offset(100, 80));
      n.placeRunPoint('s1', 0, const Offset(100, 2)); // sits on D, wrong service
      final net = c.read(networkControllerProvider).network;
      // The drainage main is NOT split (still one drainage edge, 2 nodes); the
      // cold-water run is its own disconnected pair — 4 nodes, 2 edges total.
      expect(net.nodes.length, 4);
      expect(net.edges.length, 2);
      expect(
          net.edges.where((e) => e.service == ServiceType.drainage).length, 1);
      // The drainage main's endpoints are untouched (no junction inserted on it).
      final drain = net.edges.firstWhere((e) => e.service == ServiceType.drainage);
      expect(net.edgesAt(drain.fromId).length, 1);
      expect(net.edgesAt(drain.toId).length, 1);
    });

    test('a typed-length run (endSnapRadius 0) still tees at its START', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setService(ServiceType.coldWater);
      // A cold-water main A(0,0)-B(200,0).
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(200, 0));
      n.setTool(DrawTool.drawRun);
      // First click STARTS on the main midpoint (100,1) — should tee in; then a
      // TYPED length lands the end exactly (endSnapRadius 0). Before the fix,
      // passing 0 for both radii disconnected the start.
      n.placeRunPoint('s1', 0, const Offset(100, 1)); // start on the main
      n.placeRunPoint('s1', 0, const Offset(100, 120), endSnapRadius: 0);
      final net = c.read(networkControllerProvider).network;
      // The start teed in: the main split at (100,0) → junction degree 3.
      final j = net.nodes.firstWhere(
          (nd) => (nd.x - 100).abs() < 1e-6 && nd.y.abs() < 1e-6);
      expect(net.edgesAt(j.id).length, 3,
          reason: 'the typed run must connect to the main at its start');
      // The end landed EXACTLY at the typed point (no snap-merge): a node at
      // (100,120) exists.
      expect(
          net.nodes.any((nd) => (nd.x - 100).abs() < 1e-6 && (nd.y - 120).abs() < 1e-6),
          isTrue);
    });

    test('a CONNECTED node dragged onto another run tees in (not a plain move)',
        () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      // A main ~(50,0)-(150,0) and a second run ~(50,200)-(150,200).
      n.addSegment('s1', 0, const Offset(100, 0),
          spanPx: 100, service: ServiceType.coldWater);
      n.addSegment('s1', 0, const Offset(100, 200),
          spanPx: 100, service: ServiceType.coldWater);
      var net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 4);
      expect(net.edges.length, 2);
      // Drag the second run's right endpoint (connected) onto the main midpoint.
      final dragged =
          net.nodes.firstWhere((nd) => (nd.x - 150).abs() < 1e-6 && nd.y == 200);
      n.pushUndoSnapshot();
      n.moveNode(dragged.id, 100, 6);
      n.endNodeDragWithSnap(dragged.id, 14);

      net = c.read(networkControllerProvider).network;
      // Main split into 2 (+ junction) + second run (1) + new branch (1) = 4
      // edges; nodes: main(2) + junction(1) + second run(2) = 5.
      expect(net.nodes.length, 5);
      expect(net.edges.length, 4);
      // The dragged node survives and now carries its own run edge PLUS the tee
      // branch (degree 2).
      expect(net.nodeById(dragged.id), isNotNull);
      expect(net.edgesAt(dragged.id).length, 2);

      // One undo reverts the whole tee back to two separate runs.
      n.undo();
      net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 4);
      expect(net.edges.length, 2);
    });
  });

  group('C8: Ctrl+Z mid-chain preserves the run', () {
    ProviderContainer makeContainer() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('undoing a chained segment keeps pendingPoint at the prior anchor', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(100, 0)); // n0-n1
      n.placeRunPoint('s1', 0, const Offset(200, 0)); // n1-n2, pending (200,0)

      n.undo();
      final s = c.read(networkControllerProvider);
      expect(s.network.edges.length, 1, reason: 'the last segment was removed');
      expect(s.tool, DrawTool.drawRun);
      expect(s.pendingPoint, const Offset(100, 0),
          reason: 'the rubber band re-anchors at the previous chain point');

      // Drawing continues from the preserved anchor, sharing the (100,0) node.
      n.placeRunPoint('s1', 0, const Offset(100, 100));
      final net = c.read(networkControllerProvider).network;
      expect(net.edges.length, 2);
      final anchor =
          net.nodes.firstWhere((nd) => nd.x == 100 && nd.y == 0);
      expect(net.edgesAt(anchor.id).length, 2,
          reason: 'the continued segment shares the anchor node');
    });

    test('undoing the FIRST segment leaves the start point as the anchor', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(10, 20));
      n.placeRunPoint('s1', 0, const Offset(110, 20)); // first + only segment
      n.undo();
      final s = c.read(networkControllerProvider);
      expect(s.network.edges, isEmpty);
      // The chain start (10,20) is kept so the engineer can re-draw from it.
      expect(s.pendingPoint, const Offset(10, 20));
    });

    test('a non-draw undo (select tool) clears pending as before', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addFitting('s1', 0, const Offset(0, 0));
      n.addFitting('s1', 0, const Offset(50, 50));
      n.setTool(DrawTool.select);
      n.undo();
      expect(c.read(networkControllerProvider).pendingPoint, isNull);
    });
  });

  group('C2: merge-on-drop (adopt a node / tee into an edge)', () {
    ProviderContainer makeContainer() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('mergeOrAddTerminal adopts a node within radius (no coincident twin)',
        () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addFitting('s1', 0, const Offset(100, 100));
      final jId = c.read(networkControllerProvider).network.nodes.single.id;

      final id = n.mergeOrAddTerminal('s1', 0, const Offset(102, 101),
          fixture: PlumbingFixture.lavatory, snapRadius: 14);
      expect(id, jId, reason: 'adopted the existing node');
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 1, reason: 'no twin created');
      final node = net.nodeById(jId)!;
      expect(node.role, NodeRole.fixture);
      expect(node.fixture, PlumbingFixture.lavatory);
    });

    test('mergeOrAddComponent adopts a node (sets component + role)', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addFitting('s1', 0, const Offset(100, 100));
      final jId = c.read(networkControllerProvider).network.nodes.single.id;
      final id = n.mergeOrAddComponent(
          's1', 0, const Offset(101, 100), NodeComponent.pump,
          snapRadius: 14);
      expect(id, jId);
      final node = c.read(networkControllerProvider).network.nodeById(jId)!;
      expect(node.component, NodeComponent.pump);
      expect(node.role, NodeRole.plant); // the component's implied role
      expect(c.read(networkControllerProvider).network.nodes.length, 1);
    });

    test('mergeOrAddFitting tees into a run when dropped on it', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addSegment('s1', 0, const Offset(100, 0),
          spanPx: 100, service: ServiceType.coldWater); // ~(50,0)-(150,0)
      final id = n.mergeOrAddFitting('s1', 0, const Offset(100, 4),
          snapRadius: 14);
      final net = c.read(networkControllerProvider).network;
      // The main split into two halves meeting at the inserted junction.
      expect(net.nodes.length, 3);
      expect(net.edges.length, 2);
      final j = net.nodeById(id)!;
      expect(j.x, closeTo(100, 1e-6));
      expect(j.y, closeTo(0, 1e-6)); // snapped to the projection on the run
      expect(net.edgesAt(id).length, 2);
    });

    test('mergeOrAddComponent tees an inline valve into a run', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addSegment('s1', 0, const Offset(100, 0),
          spanPx: 100, service: ServiceType.coldWater);
      final id = n.mergeOrAddComponent(
          's1', 0, const Offset(100, 3), NodeComponent.gateValve,
          snapRadius: 14);
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 3);
      expect(net.edges.length, 2);
      final valve = net.nodeById(id)!;
      expect(valve.component, NodeComponent.gateValve);
      expect(net.edgesAt(id).length, 2);
    });

    test('nothing in range drops a FREE node (matches the plain add)', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      final id =
          n.mergeOrAddFitting('s1', 0, const Offset(500, 500), snapRadius: 14);
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.single.id, id);
      expect(net.nodes.single.x, 500);
      expect(net.nodes.single.role, NodeRole.main);
      expect(net.edges, isEmpty);
    });
  });

  group('E1: batch property setters (one undo step)', () {
    ProviderContainer makeContainer() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    Set<String> twoEdges(ProviderContainer c) {
      final n = c.read(networkControllerProvider.notifier);
      n.addSegment('s1', 0, const Offset(0, 0), service: ServiceType.coldWater);
      n.addSegment('s1', 0, const Offset(0, 200),
          service: ServiceType.coldWater);
      return c
          .read(networkControllerProvider)
          .network
          .edges
          .map((e) => e.id)
          .toSet();
    }

    test('setEdgesSizeOverride sets both edges in ONE undo step', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      final h = c.read(historyProvider.notifier);
      final ids = twoEdges(c);
      n.setEdgesSizeOverride(ids, Diameter.mm(80));
      for (final e in c.read(networkControllerProvider).network.edges) {
        expect(e.sizeOverride?.inMillimeters, closeTo(80, 1e-6));
      }
      h.undo(); // one step clears BOTH
      for (final e in c.read(networkControllerProvider).network.edges) {
        expect(e.sizeOverride, isNull);
      }
    });

    test('setEdgesPipeProduct / setEdgesDuctProduct / setEdgesService', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      final ids = twoEdges(c);
      n.setEdgesPipeProduct(ids, PipeProduct.pprPn16);
      for (final e in c.read(networkControllerProvider).network.edges) {
        expect(e.pipeProduct, PipeProduct.pprPn16);
      }
      n.setEdgesService(ids, ServiceType.hotWater);
      for (final e in c.read(networkControllerProvider).network.edges) {
        expect(e.service, ServiceType.hotWater);
      }
      n.setEdgesDuctProduct(ids, DuctProduct.bjls);
      for (final e in c.read(networkControllerProvider).network.edges) {
        expect(e.ductProduct, DuctProduct.bjls);
      }
    });

    test('setNodesFixture / setNodesFaceSize apply to all in one step', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addFitting('s1', 0, const Offset(10, 10));
      n.addFitting('s1', 0, const Offset(50, 50));
      final ids =
          c.read(networkControllerProvider).network.nodes.map((x) => x.id).toSet();

      n.setNodesFixture(ids, PlumbingFixture.waterClosetFlushValve);
      for (final nd in c.read(networkControllerProvider).network.nodes) {
        expect(nd.role, NodeRole.fixture);
        expect(nd.fixture, PlumbingFixture.waterClosetFlushValve);
      }

      n.setNodesFaceSize(ids, 600, 600);
      for (final nd in c.read(networkControllerProvider).network.nodes) {
        expect(nd.faceWidthMm, 600);
        expect(nd.faceHeightMm, 600);
      }
    });

    test('setNodesFixture re-picking the SAME fixture records no undo step', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addFitting('s1', 0, const Offset(10, 10));
      n.addFitting('s1', 0, const Offset(50, 50));
      final ids =
          c.read(networkControllerProvider).network.nodes.map((x) => x.id).toSet();
      n.setNodesFixture(ids, PlumbingFixture.lavatory);
      final after = c.read(networkControllerProvider).network;
      // Re-applying the value the nodes already carry is a no-op — the value
      // guard means no phantom `Network` commit (identical state instance).
      n.setNodesFixture(ids, PlumbingFixture.lavatory);
      expect(c.read(networkControllerProvider).network, same(after));
    });

    test('a batch edit does NOT collapse the multi-selection', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      final ids = twoEdges(c);
      c.read(selectionProvider.notifier).setMulti(const {}, ids);
      n.setEdgesSizeOverride(ids, Diameter.mm(63));
      // The setter never touches selection, so the batch survives the edit.
      expect(c.read(selectionProvider).edgeIds, ids);
    });

    test('an empty id set / no change records nothing', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      twoEdges(c);
      final before = c.read(networkControllerProvider).network;
      n.setEdgesSizeOverride(const {}, Diameter.mm(80));
      expect(c.read(networkControllerProvider).network, same(before));
      // Re-applying the same (null) override is a no-op too.
      n.setEdgesPipeProduct(const {'nope'}, null);
      expect(c.read(networkControllerProvider).network, same(before));
    });
  });

  group('E2: moveMany (group move, one undo step)', () {
    ProviderContainer makeContainer() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('translates every selected node by one delta; one undo reverts', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addFitting('s1', 0, const Offset(10, 10));
      n.addFitting('s1', 0, const Offset(50, 50));
      final net0 = c.read(networkControllerProvider).network;
      final a = net0.nodes.firstWhere((x) => x.x == 10);
      final b = net0.nodes.firstWhere((x) => x.x == 50);

      // The drag-merge pattern: one snapshot, then live group moves.
      n.pushUndoSnapshot();
      n.moveMany({a.id, b.id}, 5, 7);
      n.moveMany({a.id, b.id}, 5, 7); // a second live frame
      var net = c.read(networkControllerProvider).network;
      expect(net.nodeById(a.id)!.x, 20);
      expect(net.nodeById(a.id)!.y, 24);
      expect(net.nodeById(b.id)!.x, 60);
      expect(net.nodeById(b.id)!.y, 64);

      n.undo(); // ONE step back to the pre-drag positions
      net = c.read(networkControllerProvider).network;
      expect(net.nodeById(a.id)!.x, 10);
      expect(net.nodeById(a.id)!.y, 10);
      expect(net.nodeById(b.id)!.x, 50);
    });

    test('a zero delta / empty set is a no-op', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addFitting('s1', 0, const Offset(10, 10));
      final id = c.read(networkControllerProvider).network.nodes.single.id;
      n.moveMany({id}, 0, 0);
      n.moveMany(const {}, 5, 5);
      final nd = c.read(networkControllerProvider).network.nodeById(id)!;
      expect(nd.x, 10);
      expect(nd.y, 10);
    });
  });

  group('E3: paste cascade + pasteNCopies', () {
    ProviderContainer makeContainer() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    void copyASegment(ProviderContainer c) {
      final n = c.read(networkControllerProvider.notifier);
      n.addSegment('s1', 0, const Offset(100, 0), spanPx: 100); // ~(50,0)-(150,0)
      final net = c.read(networkControllerProvider).network;
      n.copySelection(net.nodes.map((nd) => nd.id).toSet(),
          net.edges.map((e) => e.id).toSet());
    }

    test('repeated Ctrl+V CASCADES instead of stacking atop the first', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      copyASegment(c);
      n.paste(sheetId: 's1', floorIndex: 0); // gen 1 (+24,+24)
      n.paste(sheetId: 's1', floorIndex: 0); // gen 2 (from the re-based clip)
      final net = c.read(networkControllerProvider).network;
      // original 2 + two pasted generations of 2 = 6 nodes, 3 edges.
      expect(net.nodes.length, 6);
      expect(net.edges.length, 3);
      // No two nodes are coincident — the second paste did not land atop the
      // first (which the old constant-offset paste did).
      final xs = net.nodes.map((nd) => nd.x).toSet();
      expect(xs.length, 6, reason: 'six distinct x positions ⇒ no stacking');
    });

    test('pasteNCopies arrays N copies in ONE undo step', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      final h = c.read(historyProvider.notifier);
      copyASegment(c);
      final result = n.pasteNCopies(3, const Offset(30, 0),
          sheetId: 's1', floorIndex: 0);
      final net = c.read(networkControllerProvider).network;
      // original (2n,1e) + 3 copies × (2n,1e) = 8 nodes, 4 edges.
      expect(net.nodes.length, 8);
      expect(net.edges.length, 4);
      expect(result.nodeIds.length, 6);
      expect(result.edgeIds.length, 3);
      // The array is selected.
      expect(c.read(selectionProvider).nodeIds, result.nodeIds);
      // Each copy is stepped 30 px further — 8 distinct x positions.
      expect(net.nodes.map((nd) => nd.x).toSet().length, 8);

      h.undo(); // ONE step removes all three copies
      expect(c.read(networkControllerProvider).network.nodes.length, 2);
    });

    test('pasteNCopies with count <= 0 or an empty clipboard is a no-op', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      // Empty clipboard.
      var r = n.pasteNCopies(3, const Offset(30, 0),
          sheetId: 's1', floorIndex: 0);
      expect(r.nodeIds, isEmpty);
      copyASegment(c);
      r = n.pasteNCopies(0, const Offset(30, 0), sheetId: 's1', floorIndex: 0);
      expect(r.nodeIds, isEmpty);
      // Only the copied original exists (nothing arrayed).
      expect(c.read(networkControllerProvider).network.nodes.length, 2);
    });
  });

  group('E5: stampAssembly (drop a saved block)', () {
    ProviderContainer makeContainer() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    /// Draw a two-node run and return its nodes/edges as an assembly SOURCE
    /// (value copies), then clear the network so the stamp lands on a blank
    /// floor — mirrors how a SavedAssembly's stored lists arrive.
    ({List<NetNode> nodes, List<NetEdge> edges}) captureSource(
        ProviderContainer c) {
      final n = c.read(networkControllerProvider.notifier);
      n.addSegment('s1', 0, const Offset(100, 0), spanPx: 100); // ~(50,0)-(150,0)
      final net = c.read(networkControllerProvider).network;
      final src = (
        nodes: [for (final nd in net.nodes) nd.copyWith()],
        edges: [for (final e in net.edges) e.copyWith()],
      );
      // Wipe the network so the stamp is measured against an empty floor.
      n.deleteMany(net.nodes.map((nd) => nd.id).toSet(), {});
      expect(c.read(networkControllerProvider).network.nodes, isEmpty);
      return src;
    }

    test('stamps fresh ids centred at the drop point, one undo step, selected',
        () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      final h = c.read(historyProvider.notifier);
      final src = captureSource(c);
      final srcIds = src.nodes.map((nd) => nd.id).toSet();

      final r = n.stampAssembly(src.nodes, src.edges,
          sheetId: 's1', floorIndex: 0, world: const Offset(400, 300));
      final net = c.read(networkControllerProvider).network;

      expect(net.nodes.length, 2);
      expect(net.edges.length, 1);
      // Fresh ids — none of the source ids reused.
      expect(net.nodes.every((nd) => !srcIds.contains(nd.id)), isTrue);
      // Centroid lands on the drop point (source centroid was (100,0)).
      final cx = net.nodes.map((nd) => nd.x).reduce((a, b) => a + b) / 2;
      final cy = net.nodes.map((nd) => nd.y).reduce((a, b) => a + b) / 2;
      expect(cx, closeTo(400, 1e-6));
      expect(cy, closeTo(300, 1e-6));
      // The stamped elements are the multi-selection.
      expect(c.read(selectionProvider).nodeIds, r.nodeIds);
      expect(r.edgeIds.length, 1);
      // ONE undo step removes the whole stamp.
      h.undo();
      expect(c.read(networkControllerProvider).network.nodes, isEmpty);
    });

    test('does NOT disturb the copy/paste clipboard', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      // Seed a clipboard from a drawn segment.
      n.addSegment('s1', 0, const Offset(700, 700), spanPx: 80);
      final seeded = c.read(networkControllerProvider).network;
      n.copySelection(seeded.nodes.map((nd) => nd.id).toSet(),
          seeded.edges.map((e) => e.id).toSet());
      expect(n.hasClipboard, isTrue);

      // Stamp an unrelated assembly.
      n.stampAssembly(
        [
          const NetNode(
              id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          const NetNode(
              id: 'b', sheetId: 's1', x: 40, y: 0, floorIndex: 0),
        ],
        [
          const NetEdge(
              id: 'e',
              fromId: 'a',
              toId: 'b',
              service: ServiceType.coldWater),
        ],
        sheetId: 's1',
        floorIndex: 0,
        world: const Offset(200, 200),
      );

      // A subsequent paste still reproduces the ORIGINAL clipboard segment,
      // proving stampAssembly left the clipboard alone.
      final before = c.read(networkControllerProvider).network.nodes.length;
      final pasted = n.paste(sheetId: 's1', floorIndex: 0);
      expect(pasted.nodeIds.length, 2);
      expect(c.read(networkControllerProvider).network.nodes.length, before + 2);
    });

    test('empty node list is a no-op', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      final r = n.stampAssembly(const [], const [],
          sheetId: 's1', floorIndex: 0, world: const Offset(0, 0));
      expect(r.nodeIds, isEmpty);
      expect(r.edgeIds, isEmpty);
      expect(c.read(networkControllerProvider).network.nodes, isEmpty);
    });

    test('a multi-floor riser assembly keeps its vertical span when stamped', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      // A saved "shaft riser set": a node on floor 0 and one on floor 1 joined
      // by a riser edge (the classic cross-floor block).
      const src = (
        nodes: [
          NetNode(id: 'lo', sheetId: 's1', x: 100, y: 100, floorIndex: 0),
          NetNode(id: 'hi', sheetId: 's1', x: 100, y: 100, floorIndex: 1),
        ],
        edges: [
          NetEdge(
              id: 'r',
              fromId: 'lo',
              toId: 'hi',
              service: ServiceType.coldWater,
              kind: EdgeKind.riser),
        ],
      );
      // Stamp it starting at floor 2.
      n.stampAssembly(src.nodes, src.edges,
          sheetId: 's1', floorIndex: 2, world: const Offset(400, 400));
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 2);
      // The two floors are PRESERVED relative to the drop floor (2 and 3), not
      // flattened onto floor 2 — else the riser would span one floor (length 0).
      final floors = net.nodes.map((nd) => nd.floorIndex).toSet();
      expect(floors, {2, 3});
      // The cloned edge is still a riser spanning two DIFFERENT floors.
      final e = net.edges.single;
      expect(e.kind, EdgeKind.riser);
      final a = net.nodeById(e.fromId)!;
      final b = net.nodeById(e.toId)!;
      expect(a.floorIndex, isNot(b.floorIndex));
    });
  });

  group('E8: idempotent autoPlaceRoomTerminals', () {
    const room = RoomArea(
      id: 'r0',
      sheetId: 's1',
      floorIndex: 0,
      ax: 100,
      ay: 100,
      bx: 200,
      by: 150,
    );

    test('re-running re-generates the terminals (no doubled airflow)', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(networkControllerProvider.notifier);

      n.autoPlaceRoomTerminals(room: room, metersPerPixel: 0.1);
      var net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 2); // 1 supply + 1 return

      // Second run must NOT stack a second generation.
      n.autoPlaceRoomTerminals(room: room, metersPerPixel: 0.1);
      net = c.read(networkControllerProvider).network;
      final supplies = net.nodes
          .where((nd) => nd.component == NodeComponent.supplyDiffuser)
          .toList();
      final returns = net.nodes
          .where((nd) => nd.component == NodeComponent.returnGrille)
          .toList();
      expect(supplies.length, 1, reason: 'idempotent — not doubled');
      expect(returns.length, 1);
      expect(net.nodes.length, 2);
      // The per-terminal airflow is the single design value, not accumulated.
      expect(supplies.single.airflow!.cubicMetersPerSecond, closeTo(0.25, 1e-9));

      // One undo reverts the SECOND (re-place) commit.
      n.undo();
      expect(c.read(networkControllerProvider).network.nodes.length, 2);
    });

    test('terminals OUTSIDE the room footprint survive a re-place', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(networkControllerProvider.notifier);
      // A supply diffuser well outside the room (500,500) — a different room's.
      n.addComponentNode(
          's1', 0, const Offset(500, 500), NodeComponent.supplyDiffuser);
      n.autoPlaceRoomTerminals(room: room, metersPerPixel: 0.1);
      n.autoPlaceRoomTerminals(room: room, metersPerPixel: 0.1);
      final net = c.read(networkControllerProvider).network;
      // The outside diffuser + this room's 1 supply + 1 return = 3.
      expect(net.nodes.length, 3);
      expect(
          net.nodes.any((nd) => nd.x == 500 && nd.y == 500), isTrue,
          reason: 'the outside terminal is not pruned');
    });
  });
}
