import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/autosave.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
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

  test(
      'the load path records nothing: reset drops the structural stack and the '
      'load setters never record a structural step (no phantom step)', () {
    final c = makeContainer();
    final proj = c.read(projectControllerProvider.notifier);
    final hist = c.read(historyProvider.notifier);
    final structural = c.read(structuralHistoryProvider.notifier);

    // A compound floor edit records exactly one structural step.
    proj.removeFloor(1);
    expect(structural.canUndo, isTrue);
    expect(hist.canUndo, isTrue);

    // Opening/restoring a document resets the global timeline (applyDocument
    // calls historyProvider.reset()), which drops the structural coordinator's
    // stack too — so no phantom structural undo survives into the fresh doc.
    hist.reset();
    expect(structural.canUndo, isFalse);
    expect(structural.canRedo, isFalse);
    expect(hist.canUndo, isFalse);

    // The controllers' own load setters (the applyDocument path) never record a
    // structural step of their own.
    proj.load(
      name: 'Opened',
      floors: const [Floor('G', Length(3)), Floor('L1', Length(3))],
      calibrations: const {},
    );
    c.read(sheetsControllerProvider.notifier).loadSheets(const []);
    c.read(networkControllerProvider.notifier).loadNetwork(const Network());
    expect(structural.canUndo, isFalse);
    expect(hist.canUndo, isFalse);
  });

  test(
      'a compound floor edit interleaves correctly with an unrelated network '
      'draw on the global timeline', () {
    final c = makeContainer();
    final net = c.read(networkControllerProvider.notifier);
    final proj = c.read(projectControllerProvider.notifier);
    final hist = c.read(historyProvider.notifier);

    // 1) draw a run (network domain).
    net.setTool(DrawTool.drawRun);
    net.placeRunPoint('s1', 0, const Offset(0, 0));
    net.placeRunPoint('s1', 0, const Offset(100, 0));
    expect(c.read(networkControllerProvider).network.edges.length, 1);

    // 2) remove a floor (structural domain — the genuinely most-recent edit).
    proj.removeFloor(1);
    expect(c.read(projectControllerProvider).floors.length, 2);

    // The first undo reverts the FLOOR removal FULLY (stack restored), leaving
    // the drawn run intact — the compound edit is one atomic step, so it never
    // half-reverts to a stranded intermediate before the draw is reached.
    hist.undo();
    expect(c.read(projectControllerProvider).floors.length, 3);
    expect(c.read(networkControllerProvider).network.edges.length, 1);

    // The second undo reverts the network draw.
    hist.undo();
    expect(c.read(networkControllerProvider).network.edges, isEmpty);

    // Redo replays them forward: the draw first, then the floor removal.
    hist.redo();
    expect(c.read(networkControllerProvider).network.edges.length, 1);
    hist.redo();
    expect(c.read(projectControllerProvider).floors.length, 2);
  });
}
