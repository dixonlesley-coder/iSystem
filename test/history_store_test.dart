import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/autosave.dart';
import 'package:mechx/store/app_state.dart';
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

  test(
      'record() flips the dirty flag eagerly (no autosave tick needed), and '
      'undo/redo re-check the real signature', () {
    final c = makeContainer();
    final proj = c.read(projectControllerProvider.notifier);
    final hist = c.read(historyProvider.notifier);

    // Virgin launch: clean. No autosave loop runs in this test — every flip
    // below is the history timeline's own doing.
    expect(c.read(projectDirtyProvider), isFalse);

    // A recorded mutation raises the flag IMMEDIATELY (B9: the edited dot
    // must not lag the 15 s autosave tick).
    proj.setFloorHeight(0, const Length(2.0));
    expect(c.read(projectDirtyProvider), isTrue);

    // Undo returns the work to the untouched virgin default — the immediate
    // signature re-check lowers the flag without waiting for a tick.
    hist.undo();
    expect(isProjectDirty(c.read), isFalse); // ground truth
    expect(c.read(projectDirtyProvider), isFalse);

    // Redo diverges again — the re-check raises it.
    hist.redo();
    expect(isProjectDirty(c.read), isTrue);
    expect(c.read(projectDirtyProvider), isTrue);
  });
}
