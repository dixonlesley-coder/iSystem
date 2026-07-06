import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

/// F2 — multi-selection ROTATE / MIRROR transforms on [NetworkController].
/// Rotate 90 CW/CCW and mirror H/V about the selection's bounding-box centre,
/// applied to the selected nodes' coordinates (edges follow their endpoints),
/// in ONE undo step. Right-angle turns / axial mirrors are exact by
/// construction (no trig), so the assertions use plain `==` on the integer-
/// valued seed coordinates.
void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  // An L-shaped 3-node path on one floor: A(0,0)-B(100,0)-C(100,100).
  // Bounding box [0,100]x[0,100] ⇒ centre (50,50).
  Network lPath() => const Network(
        nodes: [
          NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'b', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
          NetNode(id: 'c', sheetId: 's1', x: 100, y: 100, floorIndex: 0),
        ],
        edges: [
          NetEdge(
              id: 'ab', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
          NetEdge(
              id: 'bc', fromId: 'b', toId: 'c', service: ServiceType.coldWater),
        ],
      );

  NetNode node(ProviderContainer c, String id) =>
      c.read(networkControllerProvider).network.nodeById(id)!;

  double dist(NetNode p, NetNode q) =>
      math.sqrt(math.pow(p.x - q.x, 2) + math.pow(p.y - q.y, 2));

  group('rotateSelection', () {
    test('90 CW maps each node about the bbox centre; edges follow endpoints',
        () {
      final c = makeContainer();
      final ctrl = c.read(networkControllerProvider.notifier);
      ctrl.loadNetwork(lPath());
      ctrl.rotateSelection({'a', 'b', 'c'}, {'ab', 'bc'}, clockwise: true);

      // CW in screen space (y down): (dx,dy) -> (-dy, dx) about (50,50).
      expect((node(c, 'a').x, node(c, 'a').y), (100.0, 0.0));
      expect((node(c, 'b').x, node(c, 'b').y), (100.0, 100.0));
      expect((node(c, 'c').x, node(c, 'c').y), (0.0, 100.0));
    });

    test('preserves every edge length and the relative angle (rigid motion)',
        () {
      final c = makeContainer();
      final ctrl = c.read(networkControllerProvider.notifier);
      ctrl.loadNetwork(lPath());
      final abBefore = dist(node(c, 'a'), node(c, 'b'));
      final bcBefore = dist(node(c, 'b'), node(c, 'c'));

      ctrl.rotateSelection({'a', 'b', 'c'}, {'ab', 'bc'}, clockwise: true);

      // Endpoint-to-endpoint pixel lengths are unchanged (edges followed).
      expect(dist(node(c, 'a'), node(c, 'b')), closeTo(abBefore, 1e-9));
      expect(dist(node(c, 'b'), node(c, 'c')), closeTo(bcBefore, 1e-9));
      // The corner at B stays a right angle (segment vectors stay orthogonal).
      final a = node(c, 'a'), b = node(c, 'b'), cc = node(c, 'c');
      final dot = (a.x - b.x) * (cc.x - b.x) + (a.y - b.y) * (cc.y - b.y);
      expect(dot, closeTo(0, 1e-9));
    });

    test('90 CCW is the opposite mapping of CW', () {
      final c = makeContainer();
      final ctrl = c.read(networkControllerProvider.notifier);
      ctrl.loadNetwork(lPath());
      ctrl.rotateSelection({'a', 'b', 'c'}, {'ab', 'bc'}, clockwise: false);

      // CCW: (dx,dy) -> (dy, -dx) about (50,50).
      expect((node(c, 'a').x, node(c, 'a').y), (0.0, 100.0));
      expect((node(c, 'b').x, node(c, 'b').y), (0.0, 0.0));
      expect((node(c, 'c').x, node(c, 'c').y), (100.0, 0.0));
    });

    test('an EDGE-only selection still turns both endpoints of every edge', () {
      final c = makeContainer();
      final ctrl = c.read(networkControllerProvider.notifier);
      ctrl.loadNetwork(lPath());
      // select-similar yields edges only — the effective node set must expand
      // to their endpoints so nothing is left behind.
      ctrl.rotateSelection(const {}, {'ab', 'bc'}, clockwise: true);
      expect((node(c, 'a').x, node(c, 'a').y), (100.0, 0.0));
      expect((node(c, 'b').x, node(c, 'b').y), (100.0, 100.0));
      expect((node(c, 'c').x, node(c, 'c').y), (0.0, 100.0));
    });

    test('leaves node elevation + floor index untouched (riser stays a riser)',
        () {
      final c = makeContainer();
      final ctrl = c.read(networkControllerProvider.notifier);
      // A riser (a,b share plan x,y across floors) plus a horizontal run to c.
      ctrl.loadNetwork(const Network(
        nodes: [
          NetNode(
              id: 'a',
              sheetId: 's1',
              x: 0,
              y: 0,
              floorIndex: 0,
              elevation: Length(0)),
          NetNode(
              id: 'b',
              sheetId: 's1',
              x: 0,
              y: 0,
              floorIndex: 2,
              elevation: Length(7)),
          NetNode(id: 'c', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
        ],
        edges: [
          NetEdge(
              id: 'r',
              fromId: 'a',
              toId: 'b',
              service: ServiceType.coldWater,
              kind: EdgeKind.riser),
          NetEdge(
              id: 'e', fromId: 'a', toId: 'c', service: ServiceType.coldWater),
        ],
      ));
      ctrl.rotateSelection({'a', 'b', 'c'}, {'r', 'e'}, clockwise: true);

      expect(node(c, 'a').floorIndex, 0);
      expect(node(c, 'b').floorIndex, 2);
      expect(node(c, 'a').elevation, const Length(0));
      expect(node(c, 'b').elevation, const Length(7));
      // a and b still share one plan position (the riser is still vertical).
      expect((node(c, 'a').x, node(c, 'a').y),
          (node(c, 'b').x, node(c, 'b').y));
    });

    test('is ONE undo step — history pops it back to the pre-rotate positions',
        () {
      final c = makeContainer();
      final ctrl = c.read(networkControllerProvider.notifier);
      ctrl.loadNetwork(lPath());
      ctrl.rotateSelection({'a', 'b', 'c'}, {'ab', 'bc'}, clockwise: true);
      expect((node(c, 'a').x, node(c, 'a').y), (100.0, 0.0));

      c.read(historyProvider.notifier).undo();
      expect((node(c, 'a').x, node(c, 'a').y), (0.0, 0.0));
      expect((node(c, 'b').x, node(c, 'b').y), (100.0, 0.0));
      expect((node(c, 'c').x, node(c, 'c').y), (100.0, 100.0));
    });

    test('no-op (no commit) for fewer than two nodes', () {
      final c = makeContainer();
      final ctrl = c.read(networkControllerProvider.notifier);
      ctrl.loadNetwork(lPath()); // loadNetwork clears the undo stack
      ctrl.rotateSelection({'a'}, const {}, clockwise: true);
      expect(ctrl.canUndo, isFalse); // nothing committed
      expect((node(c, 'a').x, node(c, 'a').y), (0.0, 0.0));
    });

    test('no-op (no commit) when every selected node sits on one point', () {
      final c = makeContainer();
      final ctrl = c.read(networkControllerProvider.notifier);
      ctrl.loadNetwork(const Network(nodes: [
        NetNode(id: 'a', sheetId: 's1', x: 5, y: 5, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's1', x: 5, y: 5, floorIndex: 1),
      ]));
      ctrl.rotateSelection({'a', 'b'}, const {}, clockwise: true);
      expect(ctrl.canUndo, isFalse);
      expect((node(c, 'a').x, node(c, 'a').y), (5.0, 5.0));
    });
  });

  group('mirrorSelection', () {
    test('horizontal flips left/right across the vertical centre line', () {
      final c = makeContainer();
      final ctrl = c.read(networkControllerProvider.notifier);
      ctrl.loadNetwork(lPath());
      ctrl.mirrorSelection({'a', 'b', 'c'}, {'ab', 'bc'}, horizontal: true);
      // x -> 2·50 - x, y unchanged.
      expect((node(c, 'a').x, node(c, 'a').y), (100.0, 0.0));
      expect((node(c, 'b').x, node(c, 'b').y), (0.0, 0.0));
      expect((node(c, 'c').x, node(c, 'c').y), (0.0, 100.0));
    });

    test('vertical flips top/bottom across the horizontal centre line', () {
      final c = makeContainer();
      final ctrl = c.read(networkControllerProvider.notifier);
      ctrl.loadNetwork(lPath());
      ctrl.mirrorSelection({'a', 'b', 'c'}, {'ab', 'bc'}, horizontal: false);
      // y -> 2·50 - y, x unchanged.
      expect((node(c, 'a').x, node(c, 'a').y), (0.0, 100.0));
      expect((node(c, 'b').x, node(c, 'b').y), (100.0, 100.0));
      expect((node(c, 'c').x, node(c, 'c').y), (100.0, 0.0));
    });

    test('mirroring the same axis twice is an exact identity (H)', () {
      final c = makeContainer();
      final ctrl = c.read(networkControllerProvider.notifier);
      ctrl.loadNetwork(lPath());
      ctrl.mirrorSelection({'a', 'b', 'c'}, {'ab', 'bc'}, horizontal: true);
      ctrl.mirrorSelection({'a', 'b', 'c'}, {'ab', 'bc'}, horizontal: true);
      expect((node(c, 'a').x, node(c, 'a').y), (0.0, 0.0));
      expect((node(c, 'b').x, node(c, 'b').y), (100.0, 0.0));
      expect((node(c, 'c').x, node(c, 'c').y), (100.0, 100.0));
    });

    test('mirroring the same axis twice is an exact identity (V)', () {
      final c = makeContainer();
      final ctrl = c.read(networkControllerProvider.notifier);
      ctrl.loadNetwork(lPath());
      ctrl.mirrorSelection({'a', 'b', 'c'}, {'ab', 'bc'}, horizontal: false);
      ctrl.mirrorSelection({'a', 'b', 'c'}, {'ab', 'bc'}, horizontal: false);
      expect((node(c, 'a').x, node(c, 'a').y), (0.0, 0.0));
      expect((node(c, 'b').x, node(c, 'b').y), (100.0, 0.0));
      expect((node(c, 'c').x, node(c, 'c').y), (100.0, 100.0));
    });

    test('preserves edge lengths (a reflection is an isometry)', () {
      final c = makeContainer();
      final ctrl = c.read(networkControllerProvider.notifier);
      ctrl.loadNetwork(lPath());
      final abBefore = dist(node(c, 'a'), node(c, 'b'));
      final bcBefore = dist(node(c, 'b'), node(c, 'c'));
      ctrl.mirrorSelection({'a', 'b', 'c'}, {'ab', 'bc'}, horizontal: true);
      expect(dist(node(c, 'a'), node(c, 'b')), closeTo(abBefore, 1e-9));
      expect(dist(node(c, 'b'), node(c, 'c')), closeTo(bcBefore, 1e-9));
    });

    test('is ONE undo step', () {
      final c = makeContainer();
      final ctrl = c.read(networkControllerProvider.notifier);
      ctrl.loadNetwork(lPath());
      ctrl.mirrorSelection({'a', 'b', 'c'}, {'ab', 'bc'}, horizontal: true);
      expect((node(c, 'a').x, node(c, 'a').y), (100.0, 0.0));
      c.read(historyProvider.notifier).undo();
      expect((node(c, 'a').x, node(c, 'a').y), (0.0, 0.0));
    });
  });
}
