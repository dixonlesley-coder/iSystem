import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/strings/app_strings.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';

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

  test(
      'an occupancy change is its own undo step — Ctrl+Z reverts IT, not the '
      'earlier calibration', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final hist = c.read(historyProvider.notifier);
    c
        .read(projectControllerProvider.notifier)
        .setCalibration('s', const ScaleCalibration(0.01));
    expect(c.read(occupancyProvider), Occupancy.private);
    setOccupancyUndoable(c.read, Occupancy.public);

    hist.undo();
    expect(c.read(occupancyProvider), Occupancy.private);
    expect(c.read(projectControllerProvider).calibrationFor('s'), isNotNull,
        reason: 'the scale survives — the setting was the most recent edit');
    hist.redo();
    expect(c.read(occupancyProvider), Occupancy.public);
  });

  test('every sizing-driving design input lands on the timeline and reverts',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final hist = c.read(historyProvider.notifier);
    final rain0 = c.read(rainfallIntensityProvider);
    final runoff0 = c.read(runoffCoefficientProvider);
    final slope0 = c.read(drainageSlopeProvider);
    final hwT0 = c.read(hotWaterFlowTempProvider);
    final hwDt0 = c.read(hotWaterDeltaTProvider);
    final hazard0 = c.read(fireHazardProvider);
    final cooling0 = c.read(coolingLoadMethodProvider);
    final duct0 = c.read(ductSettingsProvider);

    setRainfallUndoable(c.read, rain0 + 25);
    setRunoffCoefficientUndoable(c.read, 0.6);
    setDrainageSlopeUndoable(c.read, 0.02);
    setHotWaterFlowTempUndoable(c.read, hwT0 + 5);
    setHotWaterDeltaTUndoable(c.read, hwDt0 + 2);
    setFireHazardUndoable(c.read, FireHazardClass.lightHazard);
    setCoolingLoadMethodUndoable(c.read, CoolingLoadMethod.detailed);
    setDuctShapeUndoable(c.read, DuctShape.rectangular);
    setDuctMethodUndoable(c.read, DuctSizingMethod.equalFriction);

    // Nine steps, reverted newest-first.
    for (var i = 0; i < 9; i++) {
      hist.undo();
    }
    expect(hist.canUndo, isFalse);
    expect(c.read(rainfallIntensityProvider), rain0);
    expect(c.read(runoffCoefficientProvider), runoff0);
    expect(c.read(drainageSlopeProvider), slope0);
    expect(c.read(hotWaterFlowTempProvider), hwT0);
    expect(c.read(hotWaterDeltaTProvider), hwDt0);
    expect(c.read(fireHazardProvider), hazard0);
    expect(c.read(coolingLoadMethodProvider), cooling0);
    expect(c.read(ductSettingsProvider).shape, duct0.shape);
    expect(c.read(ductSettingsProvider).method, duct0.method);
  });

  test('a stepper held at its clamp limit records no empty step', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final hist = c.read(historyProvider.notifier);
    setRainfallUndoable(c.read, 600); // the store's upper clamp
    expect(hist.canUndo, isTrue);
    hist.undo();
    setRainfallUndoable(c.read, 600);
    // A further "+" past the clamp stores the same 600 — nothing to undo.
    final recorded = setSettingUndoable<double>(c.read,
        get: () => c.read(rainfallIntensityProvider),
        apply: (v) => c.read(rainfallIntensityProvider.notifier).set(v),
        next: 625,
        label: StringKey.undoLabelRainfall);
    expect(recorded, isFalse);
    hist.undo();
    expect(hist.canUndo, isFalse, reason: 'only the one real 600 step existed');
  });
}
