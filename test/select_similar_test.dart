import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx_engine/network/network.dart';

void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  group('selectSimilarEdges (by service)', () {
    test('selects every edge of the same service, none of others', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);

      // Two cold-water runs + one hot-water run.
      n.setTool(DrawTool.drawRun);
      n.setService(ServiceType.coldWater);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(100, 0)); // cold edge 1
      n.placeRunPoint('s1', 0, const Offset(200, 0)); // cold edge 2 (chained)
      n.cancelPending();
      n.setService(ServiceType.hotWater);
      n.placeRunPoint('s1', 0, const Offset(0, 200));
      n.placeRunPoint('s1', 0, const Offset(100, 200)); // hot edge

      final net = c.read(networkControllerProvider).network;
      final cold = net.edges
          .where((e) => e.service == ServiceType.coldWater)
          .map((e) => e.id)
          .toSet();
      final hot = net.edges
          .firstWhere((e) => e.service == ServiceType.hotWater)
          .id;
      expect(cold.length, 2);

      // Seed from one cold edge -> both cold edges, no hot.
      c.read(selectionProvider.notifier).selectSimilarEdges(cold.first);
      final sel = c.read(selectionProvider);
      expect(sel.edgeIds, cold);
      expect(sel.edgeIds.contains(hot), isFalse);
      expect(sel.nodeIds, isEmpty);
      expect(sel.isMulti, isTrue);
    });

    test('a missing seed edge is a no-op (selection unchanged)', () {
      final c = makeContainer();
      c.read(selectionProvider.notifier).selectSimilarEdges('nope');
      expect(c.read(selectionProvider).isEmpty, isTrue);
    });
  });

  group('selectSimilarNodes (by component)', () {
    test('selects every node of the same component kind', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.addComponentNode('s1', 0, const Offset(0, 0), NodeComponent.pump);
      n.addComponentNode('s1', 0, const Offset(50, 0), NodeComponent.pump);
      n.addComponentNode('s1', 0, const Offset(100, 0), NodeComponent.gateValve);

      final net = c.read(networkControllerProvider).network;
      final pumps = net.nodes
          .where((nd) => nd.component == NodeComponent.pump)
          .map((nd) => nd.id)
          .toSet();
      expect(pumps.length, 2);

      c.read(selectionProvider.notifier).selectSimilarNodes(pumps.first);
      final sel = c.read(selectionProvider);
      expect(sel.nodeIds, pumps);
      expect(sel.edgeIds, isEmpty);
    });

    test('plain (component-less) junctions match each other, not equipment', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      // Two plain junctions via a drawn run, plus one pump.
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(100, 0));
      n.cancelPending();
      n.addComponentNode('s1', 0, const Offset(200, 0), NodeComponent.pump);

      final net = c.read(networkControllerProvider).network;
      final plain = net.nodes
          .where((nd) => nd.component == null)
          .map((nd) => nd.id)
          .toSet();
      expect(plain.length, 2);

      c.read(selectionProvider.notifier).selectSimilarNodes(plain.first);
      expect(c.read(selectionProvider).nodeIds, plain);
    });
  });
}
