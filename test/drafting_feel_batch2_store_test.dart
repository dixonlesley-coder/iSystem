import 'dart:ui' show Rect;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/route_geometry.dart';
import 'package:mechx/store/selection_scope.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/store/smart_input_store.dart';
import 'package:mechx/ui/canvas/floor_index.dart';
import 'package:mechx/ui/canvas/selection_overlay.dart'
    show segmentIntersectsRect;
import 'package:mechx/ui/canvas/snapping.dart';
import 'package:mechx_engine/network/network.dart';

/// Drafting-feel batch 2 — the STORE / pure halves of the Layout-canvas
/// fixes (H2 chained ortho routes, M1 start resolution, H4 chain bookkeeping,
/// the shared E1/H3 acceptance rule, M3 last-tool memory, L2 subtract, M7
/// crossing geometry, P2/P9/P10 index identity, P14 auto-pan release). The
/// widget halves live in `drafting_feel_batch2_test.dart`.
void main() {
  const cw = ServiceType.coldWater;

  ProviderContainer make() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  Offset pos(Network n, String id) {
    final node = n.nodeById(id)!;
    return Offset(node.x, node.y);
  }

  group('H2 — an ortho route keeps the run chain alive', () {
    test('Run tool: each routed click chains on; undo re-anchors at the '
        'route START (not on a removed bend)', () {
      final c = make();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0)); // the start click
      // Click 2: an L route (0,0)->(100,0)->(100,50).
      n.commitRoute('s1', 0,
          orthoRoute(const Offset(0, 0), const Offset(100, 50),
              kind: OrthoRouteKind.horizontalFirst),
          cw);
      var d = c.read(networkControllerProvider);
      expect(d.pendingPoint, const Offset(100, 50),
          reason: 'the chain continues from the route end');
      expect(d.network.edges.length, 2);
      expect(n.chainSegmentCount, 1);
      // Click 3 routes on from there and CONNECTS to the previous route end.
      n.commitRoute('s1', 0,
          orthoRoute(const Offset(100, 50), const Offset(200, 50)), cw);
      d = c.read(networkControllerProvider);
      expect(d.network.edges.length, 3);
      expect(d.pendingPoint, const Offset(200, 50));
      expect(n.chainSegmentCount, 2);
      final joint = d.network.nodes
          .where((x) => x.x == 100 && x.y == 50)
          .single;
      expect(d.network.edgesAt(joint.id).length, 2,
          reason: 'route 2 starts ON route 1\'s end node');
      // Undo the second route: back to the first route's end.
      n.undo();
      expect(c.read(networkControllerProvider).pendingPoint,
          const Offset(100, 50));
      // Undo the L route: its bend (100,0) is gone, the chain re-anchors at
      // the START of the route, (0,0).
      n.undo();
      d = c.read(networkControllerProvider);
      expect(d.network.edges, isEmpty);
      expect(d.pendingPoint, const Offset(0, 0));
      expect(n.chainSegmentCount, 0);
    });

    test('a programmatic route outside the Run tool still finishes', () {
      final c = make();
      final n = c.read(networkControllerProvider.notifier);
      n.commitRoute('s1', 0, const [Offset(0, 0), Offset(50, 0)], cw);
      expect(c.read(networkControllerProvider).pendingPoint, isNull);
    });
  });

  group('M1 — the run START resolves at the first click', () {
    test('a start a few px off a node starts ON the node: no micro-jog', () {
      final c = make();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(const Network(nodes: [
        NetNode(id: 'x', sheetId: 's1', x: 100, y: 100, floorIndex: 0),
        NetNode(id: 'y', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
      ], edges: [
        NetEdge(id: 'e0', fromId: 'x', toId: 'y', service: cw),
      ]));
      n.setService(cw);
      n.setTool(DrawTool.drawRun);
      const raw = Offset(104, 107); // ~8 px off node x
      n.placeRunPoint('s1', 0, raw);
      final pending = c.read(networkControllerProvider).pendingPoint!;
      expect(pending, const Offset(100, 100),
          reason: 'the pending start is the snapped node, not the raw click');
      // The overlay ortho-snaps the second click against that pending start.
      n.placeRunPoint('s1', 0, orthoSnap(pending, const Offset(400, 110)),
          ortho: true);
      final net = c.read(networkControllerProvider).network;
      expect(net.edges.length, 2);
      final e = net.edges.last;
      expect(e.fromId, 'x', reason: 'the run leaves the node itself');
      final a = pos(net, e.fromId), b = pos(net, e.toId);
      expect(b.dy, a.dy, reason: 'a straight horizontal run, no jog');
      // No node was minted at the raw click.
      expect(net.nodes.any((x) => x.x == 104 && x.y == 107), isFalse);
    });

    test('a start on a same-service run lands on its projection (tee)', () {
      final c = make();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(const Network(nodes: [
        NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's1', x: 200, y: 0, floorIndex: 0),
      ], edges: [
        NetEdge(id: 'e1', fromId: 'a', toId: 'b', service: cw),
      ]));
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(90, 6));
      expect(c.read(networkControllerProvider).pendingPoint,
          const Offset(90, 0));
      // Nothing was split yet (resolution only).
      expect(c.read(networkControllerProvider).network.edges.length, 1);
    });
  });

  group('H4 — chain bookkeeping', () {
    test('chainSegmentCount follows placements and undo', () {
      final c = make();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      expect(n.chainSegmentCount, 0);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      expect(n.chainSegmentCount, 0);
      n.placeRunPoint('s1', 0, const Offset(100, 0));
      n.placeRunPoint('s1', 0, const Offset(200, 0));
      expect(n.chainSegmentCount, 2);
      expect(c.read(historyProvider.notifier).nextUndoDomain,
          UndoDomain.network);
      c.read(historyProvider.notifier).undo();
      expect(n.chainSegmentCount, 1);
      expect(c.read(networkControllerProvider).pendingPoint,
          const Offset(100, 0));
      n.cancelPending();
      expect(n.chainSegmentCount, 0, reason: 'no pending ⇒ no chain');
    });

    test('arming a draw tool drops the pick-first selection', () {
      final c = make();
      c.read(selectionProvider.notifier).setMulti(const {'n1'}, const {'e1'});
      c.read(networkControllerProvider.notifier).setTool(DrawTool.drawRun);
      expect(c.read(selectionProvider).isEmpty, isTrue);
      // Back to Select keeps whatever is selected then.
      c.read(selectionProvider.notifier).selectNode('n1');
      c.read(networkControllerProvider.notifier).setTool(DrawTool.select);
      expect(c.read(selectionProvider).nodeId, 'n1');
    });
  });

  group('M3 — every arming path records the repeatable tool', () {
    test('setTool records run / riser', () {
      final c = make();
      expect(c.read(lastCanvasToolProvider), isNull);
      c.read(networkControllerProvider.notifier).setTool(DrawTool.drawRiser);
      expect(c.read(lastCanvasToolProvider), CanvasToolKind.riser);
      c.read(networkControllerProvider.notifier).setTool(DrawTool.select);
      expect(c.read(lastCanvasToolProvider), CanvasToolKind.riser);
      c.read(networkControllerProvider.notifier).setTool(DrawTool.drawRun);
      expect(c.read(lastCanvasToolProvider), CanvasToolKind.run);
    });
  });

  group('P14 — leaving the Run tool releases the auto-pan probe', () {
    test('setTool clears a latched probe (outside any build)', () {
      final c = make();
      c.read(networkControllerProvider.notifier).setTool(DrawTool.drawRun);
      c.read(canvasAutoPanProbeProvider.notifier).set(const Offset(3, 4));
      c.read(networkControllerProvider.notifier).setTool(DrawTool.select);
      expect(c.read(canvasAutoPanProbeProvider), isNull);
    });
  });

  group('H3 — the ONE endpoint acceptance rule', () {
    const ductEdge =
        NetEdge(id: 'd', fromId: 'p', toId: 'q', service: ServiceType.duct);
    const junction = NetNode(id: 'p', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
    test('a plain junction of another service is not adoptable', () {
      expect(drawEndpointAdoptable(junction, const [ductEdge], drawService: cw),
          isFalse);
      expect(
          drawEndpointAdoptable(junction, const [ductEdge],
              drawService: ServiceType.duct),
          isTrue);
      // Equipment stays adoptable across services.
      const tank = NetNode(
          id: 'p',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 0,
          role: NodeRole.plant,
          component: NodeComponent.roofTank);
      expect(drawEndpointAdoptable(tank, const [ductEdge], drawService: cw),
          isTrue);
      // A node wholly on an avoided service is never adoptable.
      expect(
          drawEndpointAdoptable(junction, const [ductEdge],
              avoidServices: {ServiceType.duct}),
          isFalse);
      // A free node is always adoptable.
      expect(drawEndpointAdoptable(junction, const [], drawService: cw), isTrue);
    });

    test('a tee only into a same-service, non-avoided run', () {
      expect(drawTeeAccepts(ductEdge, cw), isFalse);
      expect(drawTeeAccepts(ductEdge, ServiceType.duct), isTrue);
      expect(
          drawTeeAccepts(ductEdge, ServiceType.duct,
              avoidServices: {ServiceType.duct}),
          isFalse);
      expect(
          drawTeeAccepts(
              const NetEdge(
                  id: 'r',
                  fromId: 'p',
                  toId: 'q',
                  service: cw,
                  kind: EdgeKind.riser),
              cw),
          isFalse);
    });
  });

  group('L2 — removeMulti subtracts from the selection', () {
    test('removes the captured ids; the primary falls back', () {
      final c = make();
      final sel = c.read(selectionProvider.notifier);
      sel.setMulti(const {'a', 'b'}, const {'e1', 'e2'});
      sel.removeMulti(const {'a'}, const {'e2'});
      final s = c.read(selectionProvider);
      expect(s.nodeIds, {'b'});
      expect(s.edgeIds, {'e1'});
      expect(s.nodeIds.contains(s.nodeId) || s.edgeIds.contains(s.edgeId),
          isTrue);
      sel.removeMulti(const {'b'}, const {'e1'});
      expect(c.read(selectionProvider).isEmpty, isTrue);
    });
  });

  group('M7 — segmentIntersectsRect', () {
    const r = Rect.fromLTRB(10, 10, 20, 20);
    test('a segment cutting through with both ends outside touches', () {
      expect(segmentIntersectsRect(const Offset(0, 15), const Offset(30, 15), r),
          isTrue);
      expect(segmentIntersectsRect(const Offset(15, 0), const Offset(15, 30), r),
          isTrue);
      // Diagonal through a corner region.
      expect(segmentIntersectsRect(const Offset(0, 0), const Offset(30, 30), r),
          isTrue);
    });
    test('a segment passing beside the box does not', () {
      expect(segmentIntersectsRect(const Offset(0, 25), const Offset(30, 25), r),
          isFalse);
      expect(segmentIntersectsRect(const Offset(0, 0), const Offset(30, 5), r),
          isFalse);
    });
    test('an endpoint inside touches', () {
      expect(segmentIntersectsRect(const Offset(15, 15), const Offset(50, 50), r),
          isTrue);
    });
  });

  group('P2/P9/P10 — per-floor index + indexed incidence', () {
    const net = Network(nodes: [
      NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
      NetNode(id: 'b', sheetId: 's1', x: 10, y: 0, floorIndex: 0),
      NetNode(id: 'c', sheetId: 's2', x: 0, y: 0, floorIndex: 1),
    ], edges: [
      NetEdge(id: 'e1', fromId: 'a', toId: 'b', service: cw),
      NetEdge(
          id: 'r1', fromId: 'b', toId: 'c', service: cw, kind: EdgeKind.riser),
    ]);
    test('memoised per Network instance + floor; a new network rebuilds', () {
      final i0 = floorIndexOf(net, 's1', 0);
      expect(identical(i0, floorIndexOf(net, 's1', 0)), isTrue,
          reason: 'a pointer move on the same network reuses the index');
      expect(i0.nodes.map((n) => n.id), ['a', 'b']);
      expect(i0.runs.map((e) => e.edge.id), ['e1']);
      expect(i0.risers.map((e) => e.edge.id), ['r1']);
      expect(i0.edges.map((e) => e.edge.id), ['e1', 'r1']);
      final i1 = floorIndexOf(net, 's2', 1);
      expect(i1.nodes.map((n) => n.id), ['c']);
      expect(i1.runs, isEmpty);
      expect(i1.risers.map((e) => e.edge.id), ['r1']);
      final copy = Network(nodes: [...net.nodes], edges: [...net.edges]);
      expect(identical(floorIndexOf(copy, 's1', 0), i0), isFalse);
    });

    test('nodeInScope reads the indexed incidence', () {
      expect(nodeInScope(net, 'a', 's1', {cw}), isFalse,
          reason: 'every incident edge inert');
      expect(nodeInScope(net, 'a', 's1', {ServiceType.duct}), isTrue);
    });
  });

  group('review fixes (Fable, batch 3)', () {
    test('a chained click that snaps onto a node continues FROM the node, so '
        'a typed length measures from it', () {
      final c = make();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(const Network(nodes: [
        NetNode(id: 'N', sheetId: 's1', x: 500, y: 500, floorIndex: 0),
      ]));
      n.setService(cw);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(100, 500));
      n.placeRunPoint('s1', 0, const Offset(492, 500)); // snaps onto N
      final d = c.read(networkControllerProvider);
      expect(d.network.edges.single.toId, 'N');
      expect(d.pendingPoint, const Offset(500, 500));
      // The smart bar's exact-length path: 300 px from the pending point.
      n.placeRunPoint('s1', 0, d.pendingPoint! + const Offset(300, 0),
          endSnapRadius: 0);
      final e = c.read(networkControllerProvider).network.edges.last;
      expect(e.fromId, 'N');
      final net = c.read(networkControllerProvider).network;
      expect((pos(net, e.toId) - pos(net, 'N')).distance, closeTo(300, 1e-9));
    });

    test('undoing a segment that TEED into a run re-anchors at the previous '
        'point, not the far end of the split run', () {
      final c = make();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(const Network(nodes: [
        NetNode(id: 'X', sheetId: 's1', x: 0, y: 500, floorIndex: 0),
        NetNode(id: 'Y', sheetId: 's1', x: 1000, y: 500, floorIndex: 0),
      ], edges: [
        NetEdge(id: 'run', fromId: 'X', toId: 'Y', service: cw),
      ]));
      n.setService(cw);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(500, 100));
      n.placeRunPoint('s1', 0, const Offset(500, 505)); // tees into the run
      expect(c.read(networkControllerProvider).network.edges.length, 3);
      c.read(historyProvider.notifier).undo();
      final d = c.read(networkControllerProvider);
      expect(d.network.edges.length, 1);
      expect(d.pendingPoint, const Offset(500, 100));
      expect(n.chainSegmentCount, 0);
    });
  });
}
