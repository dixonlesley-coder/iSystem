import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx_engine/network/network.dart';

/// E2 — "select similar" used to span the whole building with nothing naming the
/// span, so a DN change meant for one floor silently re-sized every floor. It
/// now defaults to the seed's own sheet+floor, with an explicit all-floors
/// variant (the second context-menu row).
void main() {
  ProviderContainer make() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  /// Two cold-water runs on s1/f0 and one on s2/f1, plus one duct on s1/f0.
  void seed(ProviderContainer c) {
    final n = c.read(networkControllerProvider.notifier);
    n.setTool(DrawTool.drawRun);
    n.setService(ServiceType.coldWater);
    n.placeRunPoint('s1', 0, const Offset(0, 0));
    n.placeRunPoint('s1', 0, const Offset(100, 0));
    n.placeRunPoint('s1', 0, const Offset(200, 0));
    n.cancelPending();
    n.placeRunPoint('s2', 1, const Offset(0, 400));
    n.placeRunPoint('s2', 1, const Offset(100, 400));
    n.cancelPending();
    n.setService(ServiceType.duct);
    n.placeRunPoint('s1', 0, const Offset(0, 200));
    n.placeRunPoint('s1', 0, const Offset(100, 200));
    n.setTool(DrawTool.select);
  }

  List<NetEdge> coldOn(ProviderContainer c, String sheetId) {
    final net = c.read(networkControllerProvider).network;
    return [
      for (final e in net.edges)
        if (e.service == ServiceType.coldWater &&
            net.nodeById(e.fromId)!.sheetId == sheetId)
          e,
    ];
  }

  test('the default match stays on the seed edge\'s own sheet + floor', () {
    final c = make();
    seed(c);
    final seedEdge = coldOn(c, 's1').first;
    expect(coldOn(c, 's2'), hasLength(1), reason: 'the other floor exists');

    c.read(selectionProvider.notifier).selectSimilarEdges(seedEdge.id);
    final picked = c.read(selectionProvider).edgeIds;
    expect(picked, coldOn(c, 's1').map((e) => e.id).toSet());
    expect(picked.contains(coldOn(c, 's2').single.id), isFalse);
    // The other SERVICE on the same floor is still excluded (unchanged rule).
    expect(picked, hasLength(2));
  });

  test('the explicit all-floors variant spans the building', () {
    final c = make();
    seed(c);
    final seedEdge = coldOn(c, 's1').first;
    c
        .read(selectionProvider.notifier)
        .selectSimilarEdges(seedEdge.id, allFloors: true);
    final picked = c.read(selectionProvider).edgeIds;
    expect(picked, hasLength(3));
    expect(picked.contains(coldOn(c, 's2').single.id), isTrue);
  });

  test('nodes scope the same way', () {
    final c = make();
    final n = c.read(networkControllerProvider.notifier);
    n.addComponentNode('s1', 0, const Offset(10, 10), NodeComponent.gateValve);
    n.addComponentNode('s1', 0, const Offset(60, 10), NodeComponent.gateValve);
    n.addComponentNode('s2', 1, const Offset(10, 10), NodeComponent.gateValve);
    final net = c.read(networkControllerProvider).network;
    final seedNode = net.nodes.first;

    c.read(selectionProvider.notifier).selectSimilarNodes(seedNode.id);
    expect(c.read(selectionProvider).nodeIds, hasLength(2));

    c
        .read(selectionProvider.notifier)
        .selectSimilarNodes(seedNode.id, allFloors: true);
    expect(c.read(selectionProvider).nodeIds, hasLength(3));
  });

  test('a RISER (which spans two floors) is only caught by the all-floors '
      'variant', () {
    final c = make();
    final n = c.read(networkControllerProvider.notifier);
    n.setTool(DrawTool.drawRun);
    n.setService(ServiceType.coldWater);
    n.placeRunPoint('s1', 0, const Offset(0, 0));
    n.placeRunPoint('s1', 0, const Offset(100, 0));
    n.setTool(DrawTool.select);
    final flat = c.read(networkControllerProvider).network.edges.single;
    // A riser at the run's end, spanning up to the floor above.
    n.setTool(DrawTool.drawRiser);
    n.placeRiser('s1', 0, const Offset(100, 0), 2);
    n.setTool(DrawTool.select);
    final net = c.read(networkControllerProvider).network;
    final riser =
        net.edges.firstWhere((e) => e.kind == EdgeKind.riser);

    c.read(selectionProvider.notifier).selectSimilarEdges(flat.id);
    expect(c.read(selectionProvider).edgeIds.contains(riser.id), isFalse);

    c
        .read(selectionProvider.notifier)
        .selectSimilarEdges(flat.id, allFloors: true);
    expect(c.read(selectionProvider).edgeIds.contains(riser.id), isTrue);
  });
}
