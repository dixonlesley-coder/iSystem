import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx_engine/network/network.dart';

/// I4 — a shaft group that repeats up six floors was six sheet switches and six
/// pastes. `pasteToTargets` fans the clipboard out over several (sheet, floor)
/// destinations in ONE undo step, landing at the clipboard's own plan position
/// so a riser group stacks directly above itself.
void main() {
  ProviderContainer make() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  /// A two-node cold-water run on s1/f0, copied to the clipboard.
  ({String edgeId, Set<String> nodeIds}) seedAndCopy(ProviderContainer c) {
    final n = c.read(networkControllerProvider.notifier);
    n.setTool(DrawTool.drawRun);
    n.setService(ServiceType.coldWater);
    n.placeRunPoint('s1', 0, const Offset(40, 40));
    n.placeRunPoint('s1', 0, const Offset(140, 40));
    n.setTool(DrawTool.select);
    final net = c.read(networkControllerProvider).network;
    final edge = net.edges.single;
    final ids = net.nodes.map((x) => x.id).toSet();
    n.copySelection(ids, {edge.id});
    return (edgeId: edge.id, nodeIds: ids);
  }

  test('an empty clipboard / empty target list is a no-op', () {
    final c = make();
    final n = c.read(networkControllerProvider.notifier);
    expect(
        n.pasteToTargets([(sheetId: 's2', floor: 1)]).nodeIds, isEmpty);
    seedAndCopy(c);
    expect(n.pasteToTargets(const []).nodeIds, isEmpty);
    expect(c.read(networkControllerProvider).network.nodes, hasLength(2));
  });

  test('the block lands once per target, at the SAME plan position', () {
    final c = make();
    seedAndCopy(c);
    final n = c.read(networkControllerProvider.notifier);
    final out = n.pasteToTargets([
      (sheetId: 's2', floor: 1),
      (sheetId: 's3', floor: 2),
      (sheetId: 's4', floor: 3),
    ]);
    expect(out.nodeIds, hasLength(6));
    expect(out.edgeIds, hasLength(3));

    final net = c.read(networkControllerProvider).network;
    expect(net.nodes, hasLength(8)); // 2 original + 3 x 2
    expect(net.edges, hasLength(4));
    for (final target in ['s2', 's3', 's4']) {
      final on = net.nodes.where((x) => x.sheetId == target).toList();
      expect(on, hasLength(2), reason: target);
      // Same x/y as the originals — a riser group must stack, not cascade.
      expect(on.map((x) => x.x).toSet(), {40.0, 140.0});
      expect(on.map((x) => x.y).toSet(), {40.0});
    }
    for (final x in net.nodes.where((x) => x.sheetId == 's3')) {
      expect(x.floorIndex, 2);
    }
    // Every clone carries the source run's service.
    for (final e in net.edges) {
      expect(e.service, ServiceType.coldWater);
    }
    // The whole fan-out is the selection.
    expect(c.read(selectionProvider).nodeIds, out.nodeIds);
  });

  test('the whole fan-out is ONE undo step', () {
    final c = make();
    seedAndCopy(c);
    final before = c.read(networkControllerProvider).network.nodes.length;
    c.read(networkControllerProvider.notifier).pasteToTargets([
      (sheetId: 's2', floor: 1),
      (sheetId: 's3', floor: 2),
    ]);
    expect(c.read(networkControllerProvider).network.nodes, hasLength(6));
    c.read(historyProvider.notifier).undo();
    expect(
        c.read(networkControllerProvider).network.nodes, hasLength(before));
    expect(c.read(historyProvider.notifier).canUndo, isTrue,
        reason: 'the draw steps remain — only ONE entry was consumed');
  });

  test('duplicate targets are collapsed (a floor is never double-pasted)', () {
    final c = make();
    seedAndCopy(c);
    final out = c.read(networkControllerProvider.notifier).pasteToTargets([
      (sheetId: 's2', floor: 1),
      (sheetId: 's2', floor: 1),
    ]);
    expect(out.nodeIds, hasLength(2));
  });

  test('the clipboard is NOT re-based (a following paste still uses the '
      'original block)', () {
    final c = make();
    seedAndCopy(c);
    final n = c.read(networkControllerProvider.notifier);
    n.pasteToTargets([(sheetId: 's2', floor: 1)]);
    final out = n.paste(sheetId: 's1', floorIndex: 0);
    final net = c.read(networkControllerProvider).network;
    final pasted =
        net.nodes.where((x) => out.nodeIds.contains(x.id)).toList();
    // The default paste offset (24, 24) applied to the ORIGINAL 40/140 x's.
    expect(pasted.map((x) => x.x).toSet(), {64.0, 164.0});
  });
}
