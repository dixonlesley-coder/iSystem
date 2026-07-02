import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/pipe_products.dart';
import 'package:mechx_engine/units.dart';

void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  group('Selection set intents', () {
    test('selectNode collapses the sets to that single id', () {
      final c = makeContainer();
      final s = c.read(selectionProvider.notifier);
      s.toggleNode('n1');
      s.toggleNode('n2');
      expect(c.read(selectionProvider).nodeIds, {'n1', 'n2'});
      s.selectNode('n3');
      final sel = c.read(selectionProvider);
      expect(sel.nodeId, 'n3');
      expect(sel.nodeIds, {'n3'});
      expect(sel.edgeIds, isEmpty);
      expect(sel.isMulti, isFalse);
    });

    test('toggleNode adds/removes; primary follows', () {
      final c = makeContainer();
      final s = c.read(selectionProvider.notifier);
      s.toggleNode('n1');
      expect(c.read(selectionProvider).nodeId, 'n1');
      expect(c.read(selectionProvider).isMulti, isFalse);

      s.toggleNode('n2');
      expect(c.read(selectionProvider).nodeIds, {'n1', 'n2'});
      expect(c.read(selectionProvider).nodeId, 'n2');
      expect(c.read(selectionProvider).isMulti, isTrue);

      s.toggleNode('n2'); // remove
      expect(c.read(selectionProvider).nodeIds, {'n1'});
      expect(c.read(selectionProvider).nodeId, 'n1');

      s.toggleNode('n1'); // remove last → empty
      expect(c.read(selectionProvider).isEmpty, isTrue);
      expect(c.read(selectionProvider).hasSelection, isFalse);
    });

    test('toggleEdge mixes with nodes; primary collapses on removal', () {
      final c = makeContainer();
      final s = c.read(selectionProvider.notifier);
      s.toggleNode('n1');
      s.toggleEdge('e1');
      final sel = c.read(selectionProvider);
      expect(sel.nodeIds, {'n1'});
      expect(sel.edgeIds, {'e1'});
      expect(sel.edgeId, 'e1');
      expect(sel.isMulti, isTrue);

      s.toggleEdge('e1'); // remove the edge → primary collapses to remaining node
      expect(c.read(selectionProvider).nodeId, 'n1');
      expect(c.read(selectionProvider).edgeId, isNull);
    });

    test('setMulti sets sets + a primary; empty clears', () {
      final c = makeContainer();
      final s = c.read(selectionProvider.notifier);
      s.setMulti({'n1', 'n2'}, {'e1'});
      expect(c.read(selectionProvider).nodeIds, {'n1', 'n2'});
      expect(c.read(selectionProvider).edgeIds, {'e1'});
      expect(c.read(selectionProvider).nodeId, anyOf('n1', 'n2'));
      s.setMulti({}, {});
      expect(c.read(selectionProvider).isEmpty, isTrue);
    });

    test('clear resets sets', () {
      final c = makeContainer();
      final s = c.read(selectionProvider.notifier);
      s.setMulti({'n1'}, {'e1'});
      s.clear();
      final sel = c.read(selectionProvider);
      expect(sel.nodeIds, isEmpty);
      expect(sel.edgeIds, isEmpty);
      expect(sel.isEmpty, isTrue);
    });

    test('== / hashCode fold in the sets (unordered)', () {
      const a = Selection(nodeId: 'n1', nodeIds: {'n1', 'n2'});
      const b = Selection(nodeId: 'n1', nodeIds: {'n2', 'n1'});
      const d = Selection(nodeId: 'n1', nodeIds: {'n1'});
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(d));
    });
  });

  group('copySelection', () {
    // A small network: n0-n1 (e0), n1-n2 (e1), plus a lone n3.
    NetworkController seed(ProviderContainer c) {
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0)); // n0
      n.placeRunPoint('s1', 0, const Offset(100, 0)); // n1, e0
      n.placeRunPoint('s1', 0, const Offset(200, 0)); // n2, e1
      n.setTool(DrawTool.select);
      return n;
    }

    test('only chosen edges are carried (unselected edges are dropped)', () {
      final c = makeContainer();
      final n = seed(c);
      final net = c.read(networkControllerProvider).network;
      final ids = net.nodes.map((e) => e.id).toList();
      final edges = net.edges.toList();
      // Select n0 and n1 plus ONLY edge e0. e1 (n1-n2) is not selected, so it is
      // not carried — n2 isn't pulled in either.
      n.copySelection({ids[0], ids[1]}, {edges[0].id});
      expect(n.hasClipboard, isTrue);

      final before = c.read(networkControllerProvider).network;
      n.paste(sheetId: 's1', floorIndex: 1);
      final after = c.read(networkControllerProvider).network;
      expect(after.nodes.length - before.nodes.length, 2); // n0, n1 only
      expect(after.edges.length - before.edges.length, 1); // only e0
    });

    test('a selected edge pulls in BOTH its endpoints', () {
      final c = makeContainer();
      final n = seed(c);
      final net = c.read(networkControllerProvider).network;
      final edges = net.edges.toList();
      // Select NO nodes but edge e1 (n1-n2): both endpoints come along.
      n.copySelection({}, {edges[1].id});
      final before = c.read(networkControllerProvider).network;
      n.paste(sheetId: 's1', floorIndex: 1);
      final after = c.read(networkControllerProvider).network;
      expect(after.nodes.length - before.nodes.length, 2); // n1, n2
      expect(after.edges.length - before.edges.length, 1); // e1
    });

    test('empty selection clears the clipboard', () {
      final c = makeContainer();
      final n = seed(c);
      n.copySelection({}, {});
      expect(n.hasClipboard, isFalse);
    });
  });

  group('paste', () {
    test('fresh ids, offset, preserves edges among copied nodes', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(10, 20));
      n.placeRunPoint('s1', 0, const Offset(110, 20));
      n.setTool(DrawTool.select);
      final net0 = c.read(networkControllerProvider).network;
      final ids0 = net0.nodes.map((e) => e.id).toSet();
      n.copySelection(
          net0.nodes.map((e) => e.id).toSet(), {net0.edges.single.id});

      final result =
          n.paste(sheetId: 's2', floorIndex: 0, offsetWorld: const Offset(5, 7));
      final net1 = c.read(networkControllerProvider).network;
      // 2 original + 2 pasted nodes; 1 original + 1 pasted edge.
      expect(net1.nodes.length, 4);
      expect(net1.edges.length, 2);

      final pasted =
          net1.nodes.where((nd) => !ids0.contains(nd.id)).toList();
      expect(pasted, hasLength(2));
      for (final nd in pasted) {
        expect(ids0.contains(nd.id), isFalse); // fresh id
        expect(nd.sheetId, 's2');
      }
      // Offset applied (one pasted node sits at 10+5, 20+7).
      expect(
        pasted.any((nd) => nd.x == 15 && nd.y == 27),
        isTrue,
      );
      // The pasted edge connects two pasted nodes.
      final pastedIds = pasted.map((e) => e.id).toSet();
      final pe = net1.edges.firstWhere((e) => result.edgeIds.contains(e.id));
      expect(pastedIds.contains(pe.fromId), isTrue);
      expect(pastedIds.contains(pe.toId), isTrue);

      // Paste set the new ids as the multi-selection.
      final sel = c.read(selectionProvider);
      expect(sel.nodeIds, pastedIds);
      expect(sel.edgeIds, result.edgeIds);
    });

    test('carries customFixtureId / roofAreaM2 / products', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      // Build a single fixture node + a run edge with a pipe product + override.
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(100, 0));
      n.setTool(DrawTool.select);
      final net0 = c.read(networkControllerProvider).network;
      final a = net0.nodes.first;
      n.setNodeCustomFixture(a.id, 'cf-42');
      n.setNodeRoofArea(a.id, 33.0);
      final edgeId = c.read(networkControllerProvider).network.edges.single.id;
      n.setEdgePipeProduct(edgeId, PipeProduct.pprPn16);
      n.setEdgeSizeOverride(edgeId, Diameter.mm(50));

      final net1 = c.read(networkControllerProvider).network;
      final ids1 = net1.nodes.map((e) => e.id).toSet();
      n.copySelection(
          net1.nodes.map((e) => e.id).toSet(), {net1.edges.single.id});
      n.paste(sheetId: 's1', floorIndex: 1);
      final net2 = c.read(networkControllerProvider).network;

      final pastedNode = net2.nodes.firstWhere(
          (nd) => !ids1.contains(nd.id) && nd.customFixtureId == 'cf-42');
      expect(pastedNode.roofAreaM2, 33.0);
      expect(pastedNode.floorIndex, 1);

      final origEdgeIds = net1.edges.map((e) => e.id).toSet();
      final pastedEdge =
          net2.edges.firstWhere((e) => !origEdgeIds.contains(e.id));
      expect(pastedEdge.pipeProduct, PipeProduct.pprPn16);
      expect(pastedEdge.sizeOverride?.inMillimeters, closeTo(50, 1e-6));
    });

    test('is ONE undo step (history pops it cleanly)', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      final h = c.read(historyProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(100, 0));
      n.setTool(DrawTool.select);
      final net0 = c.read(networkControllerProvider).network;
      n.copySelection(
          net0.nodes.map((e) => e.id).toSet(), {net0.edges.single.id});

      final countBefore = c.read(networkControllerProvider).network.nodes.length;
      n.paste(sheetId: 's1', floorIndex: 1);
      expect(c.read(networkControllerProvider).network.nodes.length,
          countBefore + 2);

      h.undo(); // one step reverts the whole paste
      expect(c.read(networkControllerProvider).network.nodes.length,
          countBefore);
    });
  });

  group('deleteMany', () {
    test('removes nodes + their edges + listed edges in ONE undo step', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      final h = c.read(historyProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0)); // n0
      n.placeRunPoint('s1', 0, const Offset(100, 0)); // n1, e0
      n.placeRunPoint('s1', 0, const Offset(200, 0)); // n2, e1
      n.setTool(DrawTool.select);

      final net0 = c.read(networkControllerProvider).network;
      final ids = net0.nodes.map((e) => e.id).toList();
      final nodesBefore = net0.nodes.length; // 3
      final edgesBefore = net0.edges.length; // 2

      // Delete n0 (drops e0) and explicitly e1.
      n.deleteMany({ids[0]}, {net0.edges.last.id});
      final net1 = c.read(networkControllerProvider).network;
      expect(net1.nodes.length, nodesBefore - 1); // n0 gone
      expect(net1.edges, isEmpty); // both edges gone

      h.undo(); // one step restores everything
      final net2 = c.read(networkControllerProvider).network;
      expect(net2.nodes.length, nodesBefore);
      expect(net2.edges.length, edgesBefore);
    });

    test('no-op when nothing matches', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(100, 0));
      n.setTool(DrawTool.select);
      final before = c.read(networkControllerProvider).network;
      n.deleteMany({'nope'}, {'nope'});
      expect(c.read(networkControllerProvider).network, same(before));
    });
  });

  group('addMulti (Shift+marquee unions)', () {
    test('unions into the current selection instead of replacing', () {
      final c = makeContainer();
      final s = c.read(selectionProvider.notifier);
      s.setMulti({'n1'}, {'e1'});
      s.addMulti({'n2'}, {'e2'});
      final sel = c.read(selectionProvider);
      expect(sel.nodeIds, {'n1', 'n2'});
      expect(sel.edgeIds, {'e1', 'e2'});
    });

    test('empty input is a no-op (an additive gesture never clears)', () {
      final c = makeContainer();
      final s = c.read(selectionProvider.notifier);
      s.setMulti({'n1'}, const {});
      s.addMulti(const {}, const {});
      expect(c.read(selectionProvider).nodeIds, {'n1'});
    });
  });

  group('selectAllOnFloor (Ctrl/Cmd+A)', () {
    test('selects on-floor run edges + nodes filtered to the given services',
        () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      // A cold-water run + a duct run on floor 0, a free fitting, and a
      // cold-water run on floor 1 (must be excluded).
      n.addSegment('s1', 0, const Offset(100, 0),
          service: ServiceType.coldWater);
      n.addSegment('s1', 0, const Offset(100, 200), service: ServiceType.duct);
      n.addFitting('s1', 0, const Offset(500, 500));
      n.addSegment('s1', 1, const Offset(100, 400),
          service: ServiceType.coldWater);
      final net = c.read(networkControllerProvider).network;
      final cwEdge =
          net.edges.firstWhere((e) => e.service == ServiceType.coldWater &&
              net.nodeById(e.fromId)!.floorIndex == 0);
      final ductEdge =
          net.edges.firstWhere((e) => e.service == ServiceType.duct);

      c.read(selectionProvider.notifier).selectAllOnFloor('s1', 0,
          services: {ServiceType.coldWater, ServiceType.hotWater});
      final sel = c.read(selectionProvider);
      // The plumbing run + its endpoints + the FREE fitting (no service ⇒
      // always belongs); the duct run/nodes and floor-1 elements excluded.
      expect(sel.edgeIds, {cwEdge.id});
      expect(sel.nodeIds.length, 3);
      expect(sel.nodeIds.contains(cwEdge.fromId), isTrue);
      expect(sel.nodeIds.contains(cwEdge.toId), isTrue);
      expect(sel.nodeIds.contains(ductEdge.fromId), isFalse);
      expect(
          sel.nodeIds.any((id) =>
              c.read(networkControllerProvider).network.nodeById(id)!.floorIndex ==
              1),
          isFalse);
    });

    test('null services selects everything on the floor; empty floor no-ops',
        () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addSegment('s1', 0, const Offset(100, 0),
          service: ServiceType.coldWater);
      n.addSegment('s1', 0, const Offset(100, 200), service: ServiceType.duct);
      final s = c.read(selectionProvider.notifier);
      s.selectAllOnFloor('s1', 0);
      expect(c.read(selectionProvider).edgeIds.length, 2);
      expect(c.read(selectionProvider).nodeIds.length, 4);

      // An empty floor leaves the selection untouched.
      s.selectAllOnFloor('s1', 7);
      expect(c.read(selectionProvider).edgeIds.length, 2);
    });
  });

  group('pasteAt (canvas-menu Paste here)', () {
    test('pastes the clipboard CENTRED on the given world point', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      // A segment with nodes at ~(50,0) and ~(150,0) — centroid (100, 0).
      n.addSegment('s1', 0, const Offset(100, 0), spanPx: 100);
      final net = c.read(networkControllerProvider).network;
      n.copySelection(net.nodes.map((nd) => nd.id).toSet(),
          net.edges.map((e) => e.id).toSet());

      final pasted = n.pasteAt(
          sheetId: 's1', floorIndex: 0, world: const Offset(400, 300));
      expect(pasted.nodeIds.length, 2);
      expect(pasted.edgeIds.length, 1);
      final after = c.read(networkControllerProvider).network;
      final xs = pasted.nodeIds
          .map((id) => after.nodeById(id)!.x)
          .toList()
        ..sort();
      expect(xs, [closeTo(350, 1e-9), closeTo(450, 1e-9)]);
      for (final id in pasted.nodeIds) {
        expect(after.nodeById(id)!.y, closeTo(300, 1e-9));
      }
    });

    test('empty clipboard pastes nothing', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      final pasted = n.pasteAt(
          sheetId: 's1', floorIndex: 0, world: const Offset(10, 10));
      expect(pasted.nodeIds, isEmpty);
      expect(pasted.edgeIds, isEmpty);
    });
  });

  group('hoverTargetProvider (hover pre-highlight detection)', () {
    test('notifies only on CHANGE; clear resets to null', () {
      final c = makeContainer();
      var notifications = 0;
      c.listen<HoverTarget?>(hoverTargetProvider, (_, _) => notifications++);
      final h = c.read(hoverTargetProvider.notifier);

      h.set((nodeId: 'n1', edgeId: null));
      expect(c.read(hoverTargetProvider), (nodeId: 'n1', edgeId: null));
      expect(notifications, 1);

      // Same target again — per-frame hover churn must NOT notify.
      h.set((nodeId: 'n1', edgeId: null));
      expect(notifications, 1);

      h.set((nodeId: null, edgeId: 'e1'));
      expect(notifications, 2);

      h.clear();
      expect(c.read(hoverTargetProvider), isNull);
      expect(notifications, 3);
      h.clear(); // already null — no notify
      expect(notifications, 3);
    });
  });
}
