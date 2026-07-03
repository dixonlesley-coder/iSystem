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

    test('riser is a no-op on the top floor', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRiser);
      n.placeRiser('s1', 2, const Offset(0, 0), 3); // floors 0..2
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

    test('duplicateFloor is a no-op when the source floor has no runs', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.duplicateFloor(
          fromSheetId: 's1', fromFloor: 0, toSheetId: 's2', toFloor: 1);
      expect(c.read(networkControllerProvider).network.nodes, isEmpty);
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
    // A cold-water node's relevant section is Sizing.
    expect(
        container.read(
            sectionExpandedProvider(const SectionKey('Sizing', false))),
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
}
