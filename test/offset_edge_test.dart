import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';

void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  // Lay a single horizontal run (0,0)->(100,0) and return (container, edgeId).
  (ProviderContainer, String) seedRun() {
    final c = makeContainer();
    final n = c.read(networkControllerProvider.notifier);
    n.setTool(DrawTool.drawRun);
    n.placeRunPoint('s1', 0, const Offset(0, 0));
    n.placeRunPoint('s1', 0, const Offset(100, 0));
    final edgeId = c.read(networkControllerProvider).network.edges.single.id;
    return (c, edgeId);
  }

  group('offsetEdgeParallel', () {
    test('left offset of a horizontal run goes up (-y), exact distance', () {
      final (c, edgeId) = seedRun();
      final n = c.read(networkControllerProvider.notifier);
      final newId = n.offsetEdgeParallel(edgeId, 30, leftSide: true);
      expect(newId, isNotNull);

      final net = c.read(networkControllerProvider).network;
      final e = net.edgeById(newId!)!;
      final a = net.nodeById(e.fromId)!;
      final b = net.nodeById(e.toId)!;
      // Parallel: same x range, y shifted up by 30 px (left of +x heading).
      expect(a.x, closeTo(0, 1e-9));
      expect(b.x, closeTo(100, 1e-9));
      expect(a.y, closeTo(-30, 1e-9));
      expect(b.y, closeTo(-30, 1e-9));
      // Same service as the source run.
      expect(e.service, net.edgeById(edgeId)!.service);
      // Two new nodes + one new edge.
      expect(net.nodes.length, 4);
      expect(net.edges.length, 2);
    });

    test('right offset goes down (+y)', () {
      final (c, edgeId) = seedRun();
      final n = c.read(networkControllerProvider.notifier);
      final newId = n.offsetEdgeParallel(edgeId, 30, leftSide: false);
      final net = c.read(networkControllerProvider).network;
      final a = net.nodeById(net.edgeById(newId!)!.fromId)!;
      expect(a.y, closeTo(30, 1e-9));
    });

    test('one undo step reverts the whole offset', () {
      final (c, edgeId) = seedRun();
      final n = c.read(networkControllerProvider.notifier);
      n.offsetEdgeParallel(edgeId, 30, leftSide: true);
      expect(c.read(networkControllerProvider).network.edges.length, 2);
      n.undo();
      expect(c.read(networkControllerProvider).network.edges.length, 1);
      expect(c.read(networkControllerProvider).network.nodes.length, 2);
    });

    test('non-positive distance and missing edge are no-ops', () {
      final (c, edgeId) = seedRun();
      final n = c.read(networkControllerProvider.notifier);
      expect(n.offsetEdgeParallel(edgeId, 0, leftSide: true), isNull);
      expect(n.offsetEdgeParallel('nope', 30, leftSide: true), isNull);
      expect(c.read(networkControllerProvider).network.edges.length, 1);
    });
  });
}
