import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/rendering.dart' show RenderBox;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/canvas/selection_overlay.dart';
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
  });

  testWidgets('draw palette renders; Run tool activates without error',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    expect(find.text('DRAW'), findsOneWidget);
    expect(find.text('Run'), findsOneWidget);
    expect(find.text('Riser'), findsOneWidget);
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

    // The node palette: grouped (PIPES / NODES) with per-service cards plus the
    // generic Fitting / Terminal endpoints. (DUCTS only appears under HVAC.)
    expect(find.text('PALETTE'), findsOneWidget);
    expect(find.text('PIPES'), findsOneWidget);
    expect(find.text('NODES'), findsOneWidget);
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
}
