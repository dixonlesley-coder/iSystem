import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';

/// D3 (WORKFLOW-FRICTION) — flipping the water feed strategy silently rewrites
/// the whole pressure solve, the riser tags, the PRV zones and the pump duty,
/// from either of two workspaces, and used to sit OUTSIDE the undo timeline: the
/// reflexive Ctrl+Z reverted an unrelated drawing edit instead. The change is
/// now a first-class [UndoDomain.settings] entry that names itself.
void main() {
  test('a feed-strategy flip lands on the global timeline and reverts', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final hist = c.read(historyProvider.notifier);
    expect(c.read(feedStrategyProvider), FeedStrategy.downfeed);
    expect(hist.canUndo, isFalse);

    setFeedStrategyUndoable(c.read, FeedStrategy.upfeed);
    expect(c.read(feedStrategyProvider), FeedStrategy.upfeed);
    expect(hist.canUndo, isTrue);
    // …and it says what moved, rather than changing the solve in silence.
    expect(c.read(statusMessageProvider), contains('upfeed pump'));

    hist.undo();
    expect(c.read(feedStrategyProvider), FeedStrategy.downfeed);
    expect(hist.canUndo, isFalse);
    expect(hist.canRedo, isTrue);

    hist.redo();
    expect(c.read(feedStrategyProvider), FeedStrategy.upfeed);
  });

  test('the reflexive Ctrl+Z reverts the SETTING, not the last drawing edit',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final net = c.read(networkControllerProvider.notifier);
    final hist = c.read(historyProvider.notifier);

    // A drawing edit, then the settings flip: undo must take the flip first.
    net.addFitting('s1', 0, const Offset(10, 10));
    final drawn = c.read(networkControllerProvider).network.nodes.length;
    expect(drawn, 1);
    setFeedStrategyUndoable(c.read, FeedStrategy.upfeed);

    hist.undo();
    expect(c.read(feedStrategyProvider), FeedStrategy.downfeed);
    // The drawn node is STILL there — the setting was the most recent edit.
    expect(c.read(networkControllerProvider).network.nodes.length, drawn);

    // The next undo takes the drawing edit.
    hist.undo();
    expect(c.read(networkControllerProvider).network.nodes, isEmpty);
  });

  test('re-selecting the live strategy records nothing and says nothing', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final hist = c.read(historyProvider.notifier);
    setFeedStrategyUndoable(c.read, FeedStrategy.downfeed); // already downfeed
    expect(hist.canUndo, isFalse);
    expect(c.read(statusMessageProvider), isNull);
  });

  test('the coordinator is generic: any registered revert pair works', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final settings = c.read(settingsHistoryProvider.notifier);
    final hist = c.read(historyProvider.notifier);
    var value = 1;

    settings.record(SettingsUndoEntry(
      label: 'test setting',
      undo: () => value = 1,
      redo: () => value = 2,
    ));
    value = 2;
    expect(settings.pendingUndoLabel, 'test setting');

    hist.undo();
    expect(value, 1);
    hist.redo();
    expect(value, 2);

    // A fresh document baseline drops the stack (like every other domain).
    hist.reset();
    expect(settings.canUndo, isFalse);
    expect(settings.canRedo, isFalse);
    expect(settings.pendingUndoLabel, isNull);
  });

  test('an exhausted settings tag is dropped as a phantom, not a silent no-op',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final settings = c.read(settingsHistoryProvider.notifier);
    final hist = c.read(historyProvider.notifier);
    final net = c.read(networkControllerProvider.notifier);

    net.addFitting('s1', 0, const Offset(10, 10));
    settings.record(SettingsUndoEntry(label: 'x', undo: () {}, redo: () {}));
    // Drain the settings stack behind the timeline's back (the phantom case the
    // 200-vs-1000 cap difference produces in real use).
    settings.reset();

    hist.undo();
    // The stale tag was dropped and the NETWORK edit reverted instead.
    expect(c.read(networkControllerProvider).network.nodes, isEmpty);
  });
}
