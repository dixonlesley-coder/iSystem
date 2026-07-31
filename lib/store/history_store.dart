import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart' show Network;

import '../data/autosave.dart';
import '../ui/strings/app_strings.dart';
import 'annotation_store.dart';
import 'app_state.dart';
import 'electrical_store.dart';
import 'network_store.dart';
import 'project_store.dart';
import 'reference_line_store.dart';
import 'sheets_store.dart';

/// Which domain controller owns a recorded action. Each domain keeps its own
/// snapshot stack; this enum is the global timeline's record of *which* domain
/// acted, so undo/redo can revert the genuinely most-recent edit regardless of
/// domain (the previous "all network, then all project" ordering was wrong).
///
/// [annotation] (B3) covers the three annotation lists — measurements, tanks and
/// rooms — which share ONE snapshot stack in the [annotationHistoryProvider]
/// coordinator, so a room/tank/measurement add, edit or delete is undoable as
/// the genuinely most-recent cross-domain edit (mirrors the proven [electrical]
/// wiring).
///
/// [structural] covers the COMPOUND floor-stack / sheet-mapping edits that touch
/// TWO domains at once — a floor add-to-stack or removal (project floors + the
/// node floor-index remap) and a sheet→floor re-mapping (the mapping + the
/// node remap). Each such edit changes both the floor/sheet state AND the drawn
/// nodes, so it is recorded as ONE entry whose undo/redo restores BOTH together
/// via the [structuralHistoryProvider] coordinator — never a torn intermediate
/// where the nodes moved but the floors didn't (or vice-versa). This replaces
/// the old sheet-only undo domain, which recorded the mapping and the node
/// remap as two separate entries (a single Ctrl+Z reverted only one half).
///
/// [referenceLine] (B12) covers the traced reference-line list — a single flat
/// list, so (unlike [annotation]) it keeps its own local snapshot stack right
/// in [ReferenceLineController] (mirrors [electrical]'s local-stack pattern)
/// rather than a shared cross-list coordinator.
///
/// [settings] (D3) covers the project-wide DESIGN SETTINGS that live in
/// `app_state.dart` as bare `Notifier`s (feed strategy first) — flipping one
/// silently rewrites the whole pressure solve, the riser tags, the PRV zones and
/// the pump duty, from either of two workspaces, and used to sit OUTSIDE the
/// timeline entirely (the reflexive Ctrl+Z reverted an unrelated drawing edit
/// instead). Those controllers hold a single scalar with no snapshot stack of
/// their own, so instead of a captured state this domain records a REGISTERED
/// REVERT pair ([SettingsUndoEntry]) in the [settingsHistoryProvider]
/// coordinator: the forward call registers how to undo and redo itself, and the
/// timeline just runs them (mirrors the annotation/structural coordinators,
/// whose stacks also live outside the controllers they revert).
enum UndoDomain {
  network,
  project,
  electrical,
  annotation,
  structural,
  referenceLine,
  settings,
}

/// A single, global undo/redo timeline across every domain. Domain controllers
/// call [HistoryController.record] from their forward mutations; undo/redo here
/// pop the timeline and drive the owning controller's local revert. The state
/// is a monotonically increasing revision so widgets can rebuild on change.
class HistoryController extends Notifier<int> {
  final List<UndoDomain> _past = [];
  final List<UndoDomain> _future = [];

  @override
  int build() => 0;

  bool get canUndo => _past.isNotEmpty;
  bool get canRedo => _future.isNotEmpty;

  /// Record that [domain] just performed a forward (undoable) action. Clears the
  /// redo timeline — a new action forks history.
  void record(UndoDomain domain) {
    _past.add(domain);
    _future.clear();
    if (_past.length > 1000) _past.removeAt(0);
    // Eager "edited" flip (B9): the dirty dot must not lag the 15 s autosave
    // tick. A recorded mutation always diverges from the clean baseline, so a
    // boolean set is enough — no document encode on the hot mutation path.
    ref.read(projectDirtyProvider.notifier).set(true);
    state++;
  }

  /// Undo the most recent action across all domains.
  ///
  /// R3 — a popped tag whose owning controller has nothing left to revert is a
  /// PHANTOM: the domain stacks cap at 200 snapshots while this timeline holds
  /// 1000 tags, so past 200 same-domain edits the oldest tags outlive the
  /// snapshots behind them. Undo used to pop such a tag, revert NOTHING, and
  /// report success (Ctrl+Z did nothing, and the tag moved to the redo stack,
  /// where Redo no-op'd in turn). Now the stale tag is DROPPED and the next one
  /// is tried, until a real revert happens or the timeline is exhausted — so
  /// Undo either changes something or is honestly a no-op with an empty
  /// timeline. The caps themselves are unchanged (they bound memory).
  void undo() {
    var reverted = false;
    while (_past.isNotEmpty) {
      final domain = _past.removeLast();
      if (!_canRevert(domain, redo: false)) continue; // phantom — drop it
      _revert(domain, redo: false);
      _future.add(domain);
      reverted = true;
      break;
    }
    // Even a fully-phantom pass changed the timeline (the stale tags were
    // dropped, so `canUndo` now reads false), so publish a revision either way
    // and let the Undo affordance disable itself.
    if (reverted) _refreshDirty();
    state++;
  }

  /// Redo the most recently undone action. Mirrors [undo]'s phantom handling.
  void redo() {
    var reverted = false;
    while (_future.isNotEmpty) {
      final domain = _future.removeLast();
      if (!_canRevert(domain, redo: true)) continue; // phantom — drop it
      _revert(domain, redo: true);
      _past.add(domain);
      reverted = true;
      break;
    }
    if (reverted) _refreshDirty();
    state++;
  }

  /// Whether [domain]'s owning controller actually holds a snapshot to step to.
  /// Read-only — never mutates a stack.
  bool _canRevert(UndoDomain domain, {required bool redo}) {
    switch (domain) {
      case UndoDomain.network:
        final c = ref.read(networkControllerProvider.notifier);
        return redo ? c.canRedo : c.canUndo;
      case UndoDomain.project:
        final c = ref.read(projectControllerProvider.notifier);
        return redo ? c.canRedo : c.canUndo;
      case UndoDomain.electrical:
        final c = ref.read(electricalProjectProvider.notifier);
        return redo ? c.canRedo : c.canUndo;
      case UndoDomain.annotation:
        final c = ref.read(annotationHistoryProvider.notifier);
        return redo ? c.canRedo : c.canUndo;
      case UndoDomain.structural:
        final c = ref.read(structuralHistoryProvider.notifier);
        return redo ? c.canRedo : c.canUndo;
      case UndoDomain.referenceLine:
        final c = ref.read(referenceLinesProvider.notifier);
        return redo ? c.canRedo : c.canUndo;
      case UndoDomain.settings:
        final c = ref.read(settingsHistoryProvider.notifier);
        return redo ? c.canRedo : c.canUndo;
    }
  }

  /// One immediate signature re-check after undo/redo: stepping the timeline
  /// may have returned the work to (or away from) the clean baseline, which a
  /// boolean flip can't know — recompute from the real encode so the edited
  /// dot tracks reality instead of waiting for the next autosave tick.
  void _refreshDirty() =>
      ref.read(projectDirtyProvider.notifier).set(isProjectDirty(ref.read));

  void _revert(UndoDomain domain, {required bool redo}) {
    switch (domain) {
      case UndoDomain.network:
        final c = ref.read(networkControllerProvider.notifier);
        redo ? c.redo() : c.undo();
      case UndoDomain.project:
        final c = ref.read(projectControllerProvider.notifier);
        redo ? c.redo() : c.undo();
      case UndoDomain.electrical:
        final c = ref.read(electricalProjectProvider.notifier);
        redo ? c.redo() : c.undo();
      case UndoDomain.annotation:
        final c = ref.read(annotationHistoryProvider.notifier);
        redo ? c.redo() : c.undo();
      case UndoDomain.structural:
        final c = ref.read(structuralHistoryProvider.notifier);
        redo ? c.redo() : c.undo();
      case UndoDomain.referenceLine:
        final c = ref.read(referenceLinesProvider.notifier);
        redo ? c.redo() : c.undo();
      case UndoDomain.settings:
        final c = ref.read(settingsHistoryProvider.notifier);
        redo ? c.redo() : c.undo();
    }
  }

  /// Drop the whole timeline — call when a document is opened/restored (a fresh
  /// baseline, like each domain controller clears its own stacks on load). Also
  /// clears the annotation coordinator's shared stack (its stack lives outside
  /// the three annotation controllers, so it can't clear itself from their
  /// load-path `set(...)`); done here, once, BEFORE those loads run.
  void reset() {
    _past.clear();
    _future.clear();
    ref.read(annotationHistoryProvider.notifier).reset();
    ref.read(structuralHistoryProvider.notifier).reset();
    ref.read(settingsHistoryProvider.notifier).reset();
    state++;
  }
}

final historyProvider =
    NotifierProvider<HistoryController, int>(HistoryController.new);

/// An immutable snapshot of the state a COMPOUND floor/sheet edit touches — the
/// [ProjectState] (for a floor-stack change), the [SheetsState] (for a
/// sheet→floor mapping change), and always the drawn [Network] (both kinds
/// remap node floor indices). Only the domain the edit actually changed is
/// captured (the other of project/sheets stays null and is left untouched on
/// restore), exactly mirroring the old per-domain granularity — a floor-stack
/// edit restored project+network, a mapping edit restored sheets+network — but
/// now as ONE atomic entry instead of two separate ones.
class StructuralSnapshot {
  final ProjectState? project;
  final SheetsState? sheets;
  final Network network;
  const StructuralSnapshot({
    this.project,
    this.sheets,
    required this.network,
  });
}

/// The shared undo coordinator for the compound floor-stack / sheet-mapping
/// edits (B6/B7). The project / sheets / network controllers each hold their
/// own state, but a SINGLE snapshot stack lives here: [ProjectController.setFloors]
/// / [ProjectController.removeFloor] call [recordFloorStackChange] and
/// [SheetsController.setSheetFloor] calls [recordSheetMappingChange] BEFORE they
/// mutate — each captures the touched state + the network and records ONE
/// [UndoDomain.structural] on the global timeline. The compound edit then
/// performs the floor/sheet mutation AND the node remap WITHOUT either recording
/// its own project/network/sheets entry, so a single Ctrl+Z restores both halves
/// atomically (never the stranded "nodes remapped but floors didn't" state that
/// two separate entries produced). Mirrors [AnnotationHistoryController].
///
/// The restore goes through each controller's NON-recording setter
/// ([ProjectController.restoreState] / [SheetsController.restoreState] /
/// [NetworkController.restoreNetwork]), so it never re-enters the timeline. The
/// document-load path never records (it uses the controllers' `load*` setters,
/// not the compound edits), and this coordinator's stacks are dropped by
/// [HistoryController.reset] in the same breath the global timeline is reset.
final structuralHistoryProvider =
    NotifierProvider<StructuralHistoryController, int>(
  StructuralHistoryController.new,
);

class StructuralHistoryController extends Notifier<int> {
  final List<StructuralSnapshot> _undo = [];
  final List<StructuralSnapshot> _redo = [];

  @override
  int build() => 0;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  StructuralSnapshot _capture({
    required bool project,
    required bool sheets,
  }) =>
      StructuralSnapshot(
        project: project ? ref.read(projectControllerProvider) : null,
        sheets: sheets ? ref.read(sheetsControllerProvider) : null,
        network: ref.read(networkControllerProvider).network,
      );

  /// Re-capture the CURRENT live state for the SAME domains a stored snapshot
  /// holds, so undo/redo can swap forward/back symmetrically.
  StructuralSnapshot _captureLike(StructuralSnapshot s) =>
      _capture(project: s.project != null, sheets: s.sheets != null);

  void _restore(StructuralSnapshot s) {
    // Restore through the controllers' NON-recording setters so restoring never
    // re-enters undo/redo, and never disturbs those controllers' own local
    // (project/network) snapshot stacks. A null domain was not touched by the
    // edit, so it is left exactly as it is now.
    if (s.project != null) {
      ref.read(projectControllerProvider.notifier).restoreState(s.project!);
    }
    if (s.sheets != null) {
      ref.read(sheetsControllerProvider.notifier).restoreState(s.sheets!);
    }
    ref.read(networkControllerProvider.notifier).restoreNetwork(s.network);
  }

  void _record({required bool project, required bool sheets}) {
    _undo.add(_capture(project: project, sheets: sheets));
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
    ref.read(historyProvider.notifier).record(UndoDomain.structural);
    state++;
  }

  /// Snapshot the CURRENT (pre-mutation) project floors + network and record one
  /// [UndoDomain.structural] entry — called by a floor-stack edit BEFORE it
  /// changes the floors and remaps node floor indices.
  void recordFloorStackChange() => _record(project: true, sheets: false);

  /// Snapshot the CURRENT (pre-mutation) sheet mapping + network and record one
  /// [UndoDomain.structural] entry — called by a sheet→floor re-mapping BEFORE
  /// it changes the mapping and remaps the sheet's node floor indices.
  void recordSheetMappingChange() => _record(project: false, sheets: true);

  /// Revert the most recent compound edit (floors/mapping AND node indices) in
  /// one step. Driven by the global [historyProvider], not widgets directly.
  void undo() {
    if (_undo.isEmpty) return;
    final snap = _undo.removeLast();
    _redo.add(_captureLike(snap));
    _restore(snap);
    state++;
  }

  /// Replay the most recently undone compound edit (see [undo]).
  void redo() {
    if (_redo.isEmpty) return;
    final snap = _redo.removeLast();
    _undo.add(_captureLike(snap));
    _restore(snap);
    state++;
  }

  /// Drop both stacks — called from [HistoryController.reset] when a document is
  /// opened/restored (a fresh baseline). The shared stack lives here rather than
  /// in the three controllers, so it is cleared here, once.
  void reset() {
    _undo.clear();
    _redo.clear();
    state++;
  }
}

/// D3 — ONE reversible design-settings change, expressed as the pair of calls
/// that move it back and forward. The settings controllers in `app_state.dart`
/// hold a single scalar and keep no snapshot stack, so instead of capturing a
/// state this domain captures the two closures; the coordinator runs them.
///
/// [label] names WHAT moved (the feed strategy, the drainage fall…) so the
/// caller can narrate the change in the status bar with the same words the undo
/// timeline holds. The closures MUST write through the owning controller's
/// plain setter — never back through a recording wrapper — or undo would record
/// itself.
class SettingsUndoEntry {
  final String label;
  final void Function() undo;
  final void Function() redo;
  const SettingsUndoEntry({
    required this.label,
    required this.undo,
    required this.redo,
  });
}

/// The undo coordinator for the project-wide design settings (D3). Mirrors
/// [StructuralHistoryController]'s shape — a local stack plus ONE
/// [UndoDomain.settings] entry on the global timeline per change — but stores
/// registered revert callbacks rather than captured state, because the settings
/// controllers own nothing to snapshot.
final settingsHistoryProvider =
    NotifierProvider<SettingsHistoryController, int>(
  SettingsHistoryController.new,
);

class SettingsHistoryController extends Notifier<int> {
  final List<SettingsUndoEntry> _undo = [];
  final List<SettingsUndoEntry> _redo = [];

  @override
  int build() => 0;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// The label of the change a Ctrl+Z would revert (null when there is none) —
  /// so an affordance can say what it is about to undo.
  String? get pendingUndoLabel => _undo.isEmpty ? null : _undo.last.label;

  /// Register [entry] and record ONE [UndoDomain.settings] on the global
  /// timeline. Call this BEFORE (or immediately after) performing the forward
  /// change — the entry carries both directions, so ordering only matters to the
  /// caller's own closures.
  void record(SettingsUndoEntry entry) {
    _undo.add(entry);
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
    ref.read(historyProvider.notifier).record(UndoDomain.settings);
    state++;
  }

  /// Run the most recent entry's revert. Driven by [historyProvider], not
  /// widgets directly.
  void undo() {
    if (_undo.isEmpty) return;
    final entry = _undo.removeLast();
    entry.undo();
    _redo.add(entry);
    state++;
  }

  /// Re-apply the most recently undone settings change.
  void redo() {
    if (_redo.isEmpty) return;
    final entry = _redo.removeLast();
    entry.redo();
    _undo.add(entry);
    state++;
  }

  /// Drop both stacks — a freshly opened/restored document is a new baseline
  /// (called from [HistoryController.reset], like the other coordinators).
  void reset() {
    _undo.clear();
    _redo.clear();
    state++;
  }
}

/// D3 — flip the water FEED STRATEGY as a first-class, undoable, self-narrating
/// edit: it rewrites the whole pressure solve, the riser tags, the PRV zones and
/// the pump duty, so it must sit on the same timeline as a drawing edit and say
/// so. Every entry point that changes the strategy should call THIS instead of
/// `feedStrategyProvider.notifier.set(...)` (the bare setter stays the
/// non-recording write the undo/redo closures below use).
///
/// A no-op — recording nothing, saying nothing — when the strategy is already
/// [next], so re-selecting the live option never pushes an empty undo step.
void setFeedStrategyUndoable(ProviderReader read, FeedStrategy next) {
  final previous = read(feedStrategyProvider);
  if (previous == next) return;
  final strings = MechXStringsData(read(localeProvider));
  final mode = strings(next == FeedStrategy.upfeed
      ? StringKey.settingsFeedUpfeed
      : StringKey.settingsFeedDownfeed);
  void apply(FeedStrategy s) => read(feedStrategyProvider.notifier).set(s);
  apply(next);
  read(settingsHistoryProvider.notifier).record(SettingsUndoEntry(
    label: mode,
    undo: () => apply(previous),
    redo: () => apply(next),
  ));
  // Name what moved: the flip is invisible on the canvas until the next solve
  // lands, and the engineer's reflex (Ctrl+Z) now genuinely reverts THIS.
  read(statusMessageProvider.notifier).showStatus(strings
      .format(StringKey.settingsFeedStrategyChanged, {'mode': mode}));
}
