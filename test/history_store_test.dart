import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/units.dart';

void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  test('undo reverts the most-recent edit across domains, in order', () {
    final c = makeContainer();
    final net = c.read(networkControllerProvider.notifier);
    final proj = c.read(projectControllerProvider.notifier);
    final hist = c.read(historyProvider.notifier);

    // 1) draw a run (network), 2) change a floor height (project).
    net.setTool(DrawTool.drawRun);
    net.placeRunPoint('s1', 0, const Offset(0, 0));
    net.placeRunPoint('s1', 0, const Offset(100, 0));
    expect(c.read(networkControllerProvider).network.edges.length, 1);

    proj.setFloorHeight(0, const Length(2.0));
    expect(c.read(projectControllerProvider).floors.first.height.meters, 2.0);

    // A single global undo reverts the PROJECT edit (the most recent), leaving
    // the network drawing intact — the old "network first" order would have
    // wrongly undone the run here.
    hist.undo();
    expect(c.read(projectControllerProvider).floors.first.height.meters, 4.0);
    expect(c.read(networkControllerProvider).network.edges.length, 1);

    // The next undo reverts the network edit.
    hist.undo();
    expect(c.read(networkControllerProvider).network.edges, isEmpty);

    // Redo replays them in forward order: network first, then project.
    hist.redo();
    expect(c.read(networkControllerProvider).network.edges.length, 1);
    hist.redo();
    expect(c.read(projectControllerProvider).floors.first.height.meters, 2.0);
  });

  test('canUndo/canRedo track the timeline; a new action forks redo', () {
    final c = makeContainer();
    final proj = c.read(projectControllerProvider.notifier);
    final hist = c.read(historyProvider.notifier);

    expect(hist.canUndo, isFalse);
    proj.setFloorHeight(0, const Length(2.0));
    expect(hist.canUndo, isTrue);
    expect(hist.canRedo, isFalse);

    hist.undo();
    expect(hist.canUndo, isFalse);
    expect(hist.canRedo, isTrue);

    // A fresh action clears the redo branch.
    proj.setFloorHeight(0, const Length(3.0));
    expect(hist.canRedo, isFalse);
  });

  test('reset clears the timeline', () {
    final c = makeContainer();
    final proj = c.read(projectControllerProvider.notifier);
    final hist = c.read(historyProvider.notifier);
    proj.setFloorHeight(0, const Length(2.0));
    expect(hist.canUndo, isTrue);
    hist.reset();
    expect(hist.canUndo, isFalse);
    expect(hist.canRedo, isFalse);
  });
}
