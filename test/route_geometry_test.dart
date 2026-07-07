import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/route_geometry.dart';
import 'package:mechx_engine/network/network.dart';

/// True when segment a->b is axis-aligned or a clean 45 diagonal.
bool isAxis45(Offset a, Offset b) {
  final dx = (b.dx - a.dx).abs();
  final dy = (b.dy - a.dy).abs();
  const tol = 1e-9;
  return dx < tol || dy < tol || (dx - dy).abs() < tol;
}

Offset posOf(Network net, String id) {
  final n = net.nodeById(id)!;
  return Offset(n.x, n.y);
}

int degreeOf(Network net, String id) =>
    net.edges.where((e) => e.fromId == id || e.toId == id).length;

void main() {
  // ── B17 pure route geometry ────────────────────────────────────────────────
  group('orthoRoute (B17)', () {
    test('horizontal-first L: two axis legs via the (end.x, start.y) corner',
        () {
      final r = orthoRoute(const Offset(0, 0), const Offset(100, 40),
          kind: OrthoRouteKind.horizontalFirst);
      expect(r, [const Offset(0, 0), const Offset(100, 0), const Offset(100, 40)]);
      for (var i = 0; i < r.length - 1; i++) {
        expect(isAxis45(r[i], r[i + 1]), isTrue);
      }
    });

    test('vertical-first L: corner at (start.x, end.y)', () {
      final r = orthoRoute(const Offset(0, 0), const Offset(100, 40),
          kind: OrthoRouteKind.verticalFirst);
      expect(r, [const Offset(0, 0), const Offset(0, 40), const Offset(100, 40)]);
    });

    test('straight axis run collapses to a single 2-point segment', () {
      expect(orthoRoute(const Offset(0, 0), const Offset(100, 0)).length, 2);
      expect(orthoRoute(const Offset(0, 0), const Offset(0, 80)).length, 2);
    });

    test('exact 45 diagonal collapses to a single segment (no zero-length bend)',
        () {
      expect(orthoRoute(const Offset(0, 0), const Offset(50, 50)).length, 2);
      expect(orthoRoute(const Offset(0, 0), const Offset(-30, 30)).length, 2);
    });

    test('diagonal Z (horizontal longer): 45 knee then axis, both aligned', () {
      final r = orthoRoute(const Offset(0, 0), const Offset(100, 40),
          kind: OrthoRouteKind.diagonalZ);
      expect(r, [const Offset(0, 0), const Offset(40, 40), const Offset(100, 40)]);
      expect(isAxis45(r[0], r[1]), isTrue); // exact 45 leg
      expect(isAxis45(r[1], r[2]), isTrue); // axis leg
    });

    test('diagonal Z (vertical longer): knee reaches end.x then runs vertical',
        () {
      final r = orthoRoute(const Offset(0, 0), const Offset(40, 100),
          kind: OrthoRouteKind.diagonalZ);
      expect(r, [const Offset(0, 0), const Offset(40, 40), const Offset(40, 100)]);
      expect(isAxis45(r[0], r[1]), isTrue);
      expect(isAxis45(r[1], r[2]), isTrue);
    });

    test('diagonal Z preserves 45-multiples for negative offsets', () {
      final r = orthoRoute(const Offset(0, 0), const Offset(-100, -40),
          kind: OrthoRouteKind.diagonalZ);
      expect(r, [const Offset(0, 0), const Offset(-40, -40), const Offset(-100, -40)]);
      expect(isAxis45(r[0], r[1]), isTrue);
      expect(isAxis45(r[1], r[2]), isTrue);
    });

    test('autoRouteKind: Z only when BOTH offsets exceed the threshold', () {
      expect(
          autoRouteKind(const Offset(0, 0), const Offset(200, 200),
              threshold: 40),
          OrthoRouteKind.diagonalZ);
      expect(
          autoRouteKind(const Offset(0, 0), const Offset(200, 10),
              threshold: 40, legFirstHorizontal: true),
          OrthoRouteKind.horizontalFirst);
      expect(
          autoRouteKind(const Offset(0, 0), const Offset(200, 10),
              threshold: 40, legFirstHorizontal: false),
          OrthoRouteKind.verticalFirst);
    });
  });

  group('lineIntersectionParams', () {
    test('perpendicular lines: exact params, sB off-segment allowed', () {
      final p = lineIntersectionParams(const Offset(0, 0), const Offset(1, 0),
          const Offset(2, 3), const Offset(0, 1));
      expect(p, isNotNull);
      expect(p!.$1, closeTo(2, 1e-12)); // tA
      expect(p.$2, closeTo(-3, 1e-12)); // sB
    });

    test('parallel lines return null', () {
      expect(
          lineIntersectionParams(const Offset(0, 0), const Offset(1, 0),
              const Offset(0, 5), const Offset(2, 0)),
          isNull);
    });
  });

  // ── store intents (B17 commit, B18, B19, B20, B22) ─────────────────────────
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  NetworkController seed(ProviderContainer c, Network net) {
    final n = c.read(networkControllerProvider.notifier);
    n.loadNetwork(net); // resets undo, advances the id counter past loaded ids
    return n;
  }

  const cw = ServiceType.coldWater;

  group('commitRoute (B17 commit)', () {
    test('lays a polyline of axis legs in ONE undo step; clears pending', () {
      final c = makeContainer();
      final n = seed(c, const Network());
      final end = n.commitRoute('s1', 0,
          const [Offset(0, 0), Offset(100, 0), Offset(100, 40)], cw);
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 3);
      expect(net.edges.length, 2);
      expect(net.edges.every((e) => e.service == cw), isTrue);
      for (final e in net.edges) {
        expect(isAxis45(posOf(net, e.fromId), posOf(net, e.toId)), isTrue);
      }
      // Route ends on the returned node; pending cleared (a finished draw).
      expect(net.nodeById(end!), isNotNull);
      expect(c.read(networkControllerProvider).pendingPoint, isNull);
      // One undo reverts the whole route.
      expect(n.canUndo, isTrue);
      n.undo();
      expect(c.read(networkControllerProvider).network.edges, isEmpty);
    });

    test('the START tees into an existing same-service run (splits it)', () {
      final c = makeContainer();
      final n = seed(
          c,
          const Network(nodes: [
            NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
            NetNode(id: 'b', sheetId: 's1', x: 200, y: 0, floorIndex: 0),
          ], edges: [
            NetEdge(id: 'e1', fromId: 'a', toId: 'b', service: cw),
          ]));
      n.commitRoute(
          's1', 0, const [Offset(100, 0), Offset(100, -50)], cw);
      final net = c.read(networkControllerProvider).network;
      // a-J, J-b (split) + J->end = 3 edges; a,b,J,end = 4 nodes.
      expect(net.edges.length, 3);
      expect(net.nodes.length, 4);
    });

    test('the END auto-elbows onto an off-ray node (composes B13)', () {
      final c = makeContainer();
      final n = seed(
          c,
          const Network(nodes: [
            NetNode(id: 't', sheetId: 's1', x: 108, y: 40, floorIndex: 0),
          ]));
      // Vertical last leg (100,0)->(100,40); target 't' sits 8px off it.
      n.commitRoute('s1', 0,
          const [Offset(0, 0), Offset(100, 0), Offset(100, 40)], cw,
          ortho: true);
      final net = c.read(networkControllerProvider).network;
      // The run reaches 't', every leg stays axis/45.
      expect(net.edges.any((e) => e.fromId == 't' || e.toId == 't'), isTrue);
      for (final e in net.edges) {
        expect(isAxis45(posOf(net, e.fromId), posOf(net, e.toId)), isTrue,
            reason: '${e.fromId}->${e.toId}');
      }
    });
  });

  group('trimExtendEdge (B18)', () {
    Network cross() => const Network(nodes: [
          NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'm', sheetId: 's1', x: 50, y: 0, floorIndex: 0),
          NetNode(id: 'q0', sheetId: 's1', x: 100, y: -50, floorIndex: 0),
          NetNode(id: 'q1', sheetId: 's1', x: 100, y: 50, floorIndex: 0),
        ], edges: [
          NetEdge(id: 'e1', fromId: 'a', toId: 'm', service: cw),
          NetEdge(id: 'b1', fromId: 'q0', toId: 'q1', service: cw),
        ]);

    test('extends the endpoint to a mid-span crossing and TEES the boundary',
        () {
      final c = makeContainer();
      final n = seed(c, cross());
      final ok = n.trimExtendEdge('e1', 'm', 'b1');
      expect(ok, isTrue);
      final net = c.read(networkControllerProvider).network;
      expect(posOf(net, 'm'), const Offset(100, 0)); // moved to the crossing
      expect(net.edges.length, 3); // e1 + two boundary halves
      expect(degreeOf(net, 'm'), 3); // a real tee junction
      expect(n.canUndo, isTrue);
    });

    test('parallel boundary refuses (no mutation, no undo entry)', () {
      final c = makeContainer();
      final n = seed(
          c,
          const Network(nodes: [
            NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
            NetNode(id: 'm', sheetId: 's1', x: 50, y: 0, floorIndex: 0),
            NetNode(id: 'q0', sheetId: 's1', x: 0, y: 30, floorIndex: 0),
            NetNode(id: 'q1', sheetId: 's1', x: 200, y: 30, floorIndex: 0),
          ], edges: [
            NetEdge(id: 'e1', fromId: 'a', toId: 'm', service: cw),
            NetEdge(id: 'b1', fromId: 'q0', toId: 'q1', service: cw),
          ]));
      expect(n.trimExtendEdge('e1', 'm', 'b1'), isFalse);
      expect(n.canUndo, isFalse);
      expect(posOf(c.read(networkControllerProvider).network, 'm'),
          const Offset(50, 0));
    });

    test('a crossing off the boundary SEGMENT refuses', () {
      final c = makeContainer();
      final n = seed(
          c,
          const Network(nodes: [
            NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
            NetNode(id: 'm', sheetId: 's1', x: 50, y: 0, floorIndex: 0),
            // Boundary vertical at x=100 but spanning y in [20,50] — never y=0.
            NetNode(id: 'q0', sheetId: 's1', x: 100, y: 20, floorIndex: 0),
            NetNode(id: 'q1', sheetId: 's1', x: 100, y: 50, floorIndex: 0),
          ], edges: [
            NetEdge(id: 'e1', fromId: 'a', toId: 'm', service: cw),
            NetEdge(id: 'b1', fromId: 'q0', toId: 'q1', service: cw),
          ]));
      expect(n.trimExtendEdge('e1', 'm', 'b1'), isFalse);
      expect(n.canUndo, isFalse);
    });

    test('a crossing at a boundary END node MERGES the two nodes', () {
      final c = makeContainer();
      final n = seed(
          c,
          const Network(nodes: [
            NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
            NetNode(id: 'm', sheetId: 's1', x: 40, y: 0, floorIndex: 0),
            NetNode(id: 'q0', sheetId: 's1', x: 50, y: 0, floorIndex: 0),
            NetNode(id: 'q1', sheetId: 's1', x: 50, y: 50, floorIndex: 0),
          ], edges: [
            NetEdge(id: 'e1', fromId: 'a', toId: 'm', service: cw),
            NetEdge(id: 'b1', fromId: 'q0', toId: 'q1', service: cw),
          ]));
      expect(n.trimExtendEdge('e1', 'm', 'b1'), isTrue);
      final net = c.read(networkControllerProvider).network;
      expect(net.nodeById('m'), isNull); // merged away into q0
      expect(net.nodes.length, 3);
      expect(net.edges.length, 2);
      expect(degreeOf(net, 'q0'), 2); // a-q0 run + q0-q1 boundary
    });
  });

  group('joinCorner (B19)', () {
    Network corner() => const Network(nodes: [
          NetNode(id: 'aa', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'ea', sheetId: 's1', x: 50, y: 0, floorIndex: 0),
          NetNode(id: 'ab', sheetId: 's1', x: 100, y: 100, floorIndex: 0),
          NetNode(id: 'eb', sheetId: 's1', x: 100, y: 50, floorIndex: 0),
        ], edges: [
          NetEdge(id: 'ea1', fromId: 'aa', toId: 'ea', service: cw),
          NetEdge(id: 'eb1', fromId: 'ab', toId: 'eb', service: cw),
        ]);

    test('extends both ends to a clean bend, merging the nodes (bearings exact)',
        () {
      final c = makeContainer();
      final n = seed(c, corner());
      expect(n.joinCorner('ea', 'eb'), isTrue);
      final net = c.read(networkControllerProvider).network;
      expect(net.nodeById('eb'), isNull); // merged into ea
      expect(net.nodes.length, 3);
      expect(net.edges.length, 2);
      expect(posOf(net, 'ea'), const Offset(100, 0)); // the corner
      expect(degreeOf(net, 'ea'), 2); // a bend junction
      for (final e in net.edges) {
        expect(isAxis45(posOf(net, e.fromId), posOf(net, e.toId)), isTrue);
      }
    });

    test('parallel ends refuse', () {
      final c = makeContainer();
      final n = seed(
          c,
          const Network(nodes: [
            NetNode(id: 'aa', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
            NetNode(id: 'ea', sheetId: 's1', x: 50, y: 0, floorIndex: 0),
            NetNode(id: 'ab', sheetId: 's1', x: 0, y: 20, floorIndex: 0),
            NetNode(id: 'eb', sheetId: 's1', x: 50, y: 20, floorIndex: 0),
          ], edges: [
            NetEdge(id: 'ea1', fromId: 'aa', toId: 'ea', service: cw),
            NetEdge(id: 'eb1', fromId: 'ab', toId: 'eb', service: cw),
          ]));
      expect(n.joinCorner('ea', 'eb'), isFalse);
      expect(n.canUndo, isFalse);
    });

    test('an absurdly-far (near-parallel) intersection refuses', () {
      final c = makeContainer();
      final n = seed(
          c,
          const Network(nodes: [
            NetNode(id: 'aa', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
            NetNode(id: 'ea', sheetId: 's1', x: 50, y: 0, floorIndex: 0),
            NetNode(id: 'ab', sheetId: 's1', x: 0, y: 10, floorIndex: 0),
            NetNode(id: 'eb', sheetId: 's1', x: 50, y: 10.1, floorIndex: 0),
          ], edges: [
            NetEdge(id: 'ea1', fromId: 'aa', toId: 'ea', service: cw),
            NetEdge(id: 'eb1', fromId: 'ab', toId: 'eb', service: cw),
          ]));
      expect(n.joinCorner('ea', 'eb'), isFalse);
    });

    test('different services refuse', () {
      final c = makeContainer();
      final n = seed(
          c,
          const Network(nodes: [
            NetNode(id: 'aa', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
            NetNode(id: 'ea', sheetId: 's1', x: 50, y: 0, floorIndex: 0),
            NetNode(id: 'ab', sheetId: 's1', x: 100, y: 100, floorIndex: 0),
            NetNode(id: 'eb', sheetId: 's1', x: 100, y: 50, floorIndex: 0),
          ], edges: [
            NetEdge(id: 'ea1', fromId: 'aa', toId: 'ea', service: cw),
            NetEdge(
                id: 'eb1',
                fromId: 'ab',
                toId: 'eb',
                service: ServiceType.drainage),
          ]));
      expect(n.joinCorner('ea', 'eb'), isFalse);
    });

    test('a non-degree-1 end refuses', () {
      final c = makeContainer();
      final n = seed(
          c,
          const Network(nodes: [
            NetNode(id: 'aa', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
            NetNode(id: 'ea', sheetId: 's1', x: 50, y: 0, floorIndex: 0),
            NetNode(id: 'x', sheetId: 's1', x: 50, y: 20, floorIndex: 0),
            NetNode(id: 'ab', sheetId: 's1', x: 100, y: 100, floorIndex: 0),
            NetNode(id: 'eb', sheetId: 's1', x: 100, y: 50, floorIndex: 0),
          ], edges: [
            NetEdge(id: 'ea1', fromId: 'aa', toId: 'ea', service: cw),
            NetEdge(id: 'ea2', fromId: 'ea', toId: 'x', service: cw), // ea deg 2
            NetEdge(id: 'eb1', fromId: 'ab', toId: 'eb', service: cw),
          ]));
      expect(n.joinCorner('ea', 'eb'), isFalse);
    });
  });

  group('dragSegment (B20)', () {
    Network chain() => const Network(nodes: [
          NetNode(id: 'p0', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'p1', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
          NetNode(id: 'p2', sheetId: 's1', x: 200, y: 0, floorIndex: 0),
        ], edges: [
          NetEdge(id: 'e1', fromId: 'p0', toId: 'p1', service: cw),
          NetEdge(id: 'e2', fromId: 'p1', toId: 'p2', service: cw),
        ]);

    test('translates both endpoints along the normal; neighbour far end stays',
        () {
      final c = makeContainer();
      final n = seed(c, chain());
      n.pushUndoSnapshot(); // one undo step per drag session
      n.dragSegment('e1', const Offset(0, 30));
      final net = c.read(networkControllerProvider).network;
      expect(posOf(net, 'p0'), const Offset(0, 30));
      expect(posOf(net, 'p1'), const Offset(100, 30));
      expect(posOf(net, 'p2'), const Offset(200, 0)); // neighbour far end fixed
      // One undo restores the whole pre-drag geometry.
      n.undo();
      final back = c.read(networkControllerProvider).network;
      expect(posOf(back, 'p0'), const Offset(0, 0));
      expect(posOf(back, 'p1'), const Offset(100, 0));
    });

    test('only the NORMAL component of the drag applies (parallel push ignored)',
        () {
      final c = makeContainer();
      final n = seed(c, chain());
      n.pushUndoSnapshot();
      n.dragSegment('e1', const Offset(50, 30)); // 50 is along the segment
      final net = c.read(networkControllerProvider).network;
      expect(posOf(net, 'p0'), const Offset(0, 30)); // x unchanged
      expect(posOf(net, 'p1'), const Offset(100, 30));
    });

    test('a riser edge is a no-op', () {
      final c = makeContainer();
      final n = seed(
          c,
          const Network(nodes: [
            NetNode(id: 'lo', sheetId: 's1', x: 10, y: 10, floorIndex: 0),
            NetNode(id: 'hi', sheetId: 's1', x: 10, y: 10, floorIndex: 1),
          ], edges: [
            NetEdge(
                id: 'r1',
                fromId: 'lo',
                toId: 'hi',
                service: cw,
                kind: EdgeKind.riser),
          ]));
      n.dragSegment('r1', const Offset(0, 30));
      expect(posOf(c.read(networkControllerProvider).network, 'lo'),
          const Offset(10, 10));
    });
  });

  group('setRunLength (B22)', () {
    Network tee() => const Network(nodes: [
          NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'b', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
          NetNode(id: 'c', sheetId: 's1', x: 0, y: 100, floorIndex: 0),
        ], edges: [
          NetEdge(id: 'e1', fromId: 'a', toId: 'b', service: cw), // b free
          NetEdge(id: 'e2', fromId: 'a', toId: 'c', service: cw), // a deg-2
        ]);

    test('moves the unique free end along the bearing to the exact length', () {
      final c = makeContainer();
      final n = seed(c, tee());
      // 0.05 m/px -> 10 m == 200 px from the anchor at a(0,0) along +x.
      expect(n.setRunLength('e1', 10, 0.05), isTrue);
      final net = c.read(networkControllerProvider).network;
      expect(posOf(net, 'b'), const Offset(200, 0));
      expect(n.canUndo, isTrue);
    });

    test('honours moveEndId to move the picked (connected) end instead', () {
      final c = makeContainer();
      final n = seed(c, tee());
      expect(n.setRunLength('e1', 10, 0.05, moveEndId: 'a'), isTrue);
      final net = c.read(networkControllerProvider).network;
      // Anchor is now b(100,0); bearing a<-b is -x; 200px -> (-100,0).
      expect(posOf(net, 'a'), const Offset(-100, 0));
    });

    test('ambiguous (both ends free, no moveEndId) refuses', () {
      final c = makeContainer();
      final n = seed(
          c,
          const Network(nodes: [
            NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
            NetNode(id: 'b', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
          ], edges: [
            NetEdge(id: 'e1', fromId: 'a', toId: 'b', service: cw),
          ]));
      expect(n.setRunLength('e1', 10, 0.05), isFalse);
      expect(n.canUndo, isFalse);
    });

    test('non-positive length or scale refuses', () {
      final c = makeContainer();
      final n = seed(c, tee());
      expect(n.setRunLength('e1', 0, 0.05), isFalse);
      expect(n.setRunLength('e1', 10, 0), isFalse);
      expect(n.canUndo, isFalse);
    });

    test('a riser refuses (its length is the elevation delta)', () {
      final c = makeContainer();
      final n = seed(
          c,
          const Network(nodes: [
            NetNode(id: 'lo', sheetId: 's1', x: 10, y: 10, floorIndex: 0),
            NetNode(id: 'hi', sheetId: 's1', x: 10, y: 10, floorIndex: 1),
          ], edges: [
            NetEdge(
                id: 'r1',
                fromId: 'lo',
                toId: 'hi',
                service: cw,
                kind: EdgeKind.riser),
          ]));
      expect(n.setRunLength('r1', 10, 0.05), isFalse);
    });
  });
}
