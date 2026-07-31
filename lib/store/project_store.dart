import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/units.dart';

import 'history_store.dart';
import 'network_store.dart';

/// Editable project: name, the building's [floors] (the source of truth for
/// riser/vertical length, §10), and per-sheet [calibrations] (px → real length,
/// §10 horizontal length). Sizing reads elevations + calibration from here.
@immutable
class ProjectState {
  final String name;
  final List<Floor> floors; // lowest first
  final Map<String, ScaleCalibration> calibrations; // by sheet id

  /// J1 — sheet ids whose calibration is STALE: the sheet's plan source was
  /// swapped (`SheetsController.replaceSheetSource`, the "Replace plan…"
  /// revision workflow) while an existing calibration survived — it may no
  /// longer match the revised plan's DPI/plot scale/title block. Cleared by
  /// re-calibrating ([ProjectController.setCalibration]) or the explicit
  /// "Scale confirmed" action ([ProjectController.confirmCalibration]).
  /// Additive; tolerant round-trip in `.mechx` (absent ⇒ empty).
  final Set<String> staleCalibrations;

  /// Index of the GROUND floor in [floors] — the elevation datum (its surface
  /// reads 0.0; basements below it are negative, upper floors positive). Default
  /// 0 (the lowest floor is ground) ⇒ elevations measured from the bottom, as
  /// before basements existed. Kept in `[0, floors.length)`; round-trips
  /// additively in `.mechx` (absent ⇒ 0, byte-identical).
  final int groundIndex;

  /// F8 — the project's mounting-height assumptions (how far a distribution main
  /// hangs below the slab above; how high a fixture connection sits above its
  /// own floor). They turn a node's floor + role into a TRUE elevation (§10), so
  /// they shape every riser length and static lift — a real per-project input,
  /// not a hard-coded engine constant. Defaults to the engine's own
  /// `MountingHeights()` (0.3 / 1.1 m) ⇒ an untouched project is unchanged, and
  /// they round-trip additively in `.mechx`.
  final MountingHeights mounting;

  const ProjectState({
    required this.name,
    required this.floors,
    this.calibrations = const {},
    this.staleCalibrations = const {},
    this.groundIndex = 0,
    this.mounting = const MountingHeights(),
  });

  BuildingLevels get building =>
      BuildingLevels(floors, groundIndex: groundIndex);

  ScaleCalibration? calibrationFor(String sheetId) => calibrations[sheetId];

  /// J1 — whether [sheetId]'s calibration needs re-verification since its
  /// plan was last replaced.
  bool isCalibrationStale(String sheetId) =>
      staleCalibrations.contains(sheetId);

  /// Sheet ids in [candidates] that carry NO calibration yet (optionally
  /// excluding the source sheet). The SAFE default target set for "apply scale
  /// to all sheets" (D2) — stamping these overwrites nothing.
  Set<String> uncalibratedAmong(Iterable<String> candidates, {String? exclude}) {
    final out = <String>{};
    for (final id in candidates) {
      if (id == exclude) continue;
      if (!calibrations.containsKey(id)) out.add(id);
    }
    return out;
  }

  /// Sheet ids in [candidates] that already carry a calibration DIFFERENT from
  /// [fromSheetId]'s (so overwriting them with the source scale needs an
  /// explicit confirm, D2). Empty when the source is uncalibrated.
  Set<String> differentlyCalibratedFrom(
      String fromSheetId, Iterable<String> candidates) {
    final source = calibrationFor(fromSheetId);
    if (source == null) return const {};
    final out = <String>{};
    for (final id in candidates) {
      if (id == fromSheetId) continue;
      final c = calibrations[id];
      if (c != null && c != source) out.add(id);
    }
    return out;
  }

  ProjectState copyWith({
    String? name,
    List<Floor>? floors,
    Map<String, ScaleCalibration>? calibrations,
    Set<String>? staleCalibrations,
    int? groundIndex,
    MountingHeights? mounting,
  }) =>
      ProjectState(
        name: name ?? this.name,
        floors: floors ?? this.floors,
        calibrations: calibrations ?? this.calibrations,
        staleCalibrations: staleCalibrations ?? this.staleCalibrations,
        groundIndex: groundIndex ?? this.groundIndex,
        mounting: mounting ?? this.mounting,
      );
}

class ProjectController extends Notifier<ProjectState> {
  static const double _minHeight = 0.5;
  static const double _maxHeight = 20.0;
  // F8 — sane bounds for the two mounting heights (a main can hang from flush
  // with the slab to 1.5 m below it; a fixture connection sits between the
  // floor and head height). They bound typing, not physics.
  static const double _minCeilingDrop = 0.0;
  static const double _maxCeilingDrop = 1.5;
  static const double _minFixtureHeight = 0.0;
  static const double _maxFixtureHeight = 2.5;

  final List<ProjectState> _undo = [];
  final List<ProjectState> _redo = [];

  @override
  ProjectState build() => const ProjectState(
        name: 'Untitled project',
        floors: [
          Floor('Ground', Length(4.0)),
          Floor('Level 1', Length(3.5)),
          Floor('Level 2', Length(3.5)),
        ],
      );

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Snapshot the current state before a mutation so it can be undone, and
  /// record the action on the global timeline (so a unified undo reverts the
  /// most-recent edit across domains, not all project edits first).
  void _snapshot() {
    _undo.add(state);
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
    ref.read(historyProvider.notifier).record(UndoDomain.project);
  }

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(state);
    state = _undo.removeLast();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(state);
    state = _redo.removeLast();
  }

  /// Restore a captured [ProjectState] WITHOUT recording undo or touching the
  /// local snapshot stacks — the [StructuralHistoryController]'s restore path for
  /// the compound floor-stack edits ([setFloors]/[removeFloor]). Not for widgets.
  void restoreState(ProjectState snapshot) => state = snapshot;

  void setName(String name) {
    if (name == state.name) return;
    _snapshot();
    state = state.copyWith(name: name);
  }

  /// Replace the whole project (used when opening a saved document). Clears
  /// history — an opened document is a fresh baseline.
  void load({
    required String name,
    required List<Floor> floors,
    required Map<String, ScaleCalibration> calibrations,
    Set<String> staleCalibrations = const {},
    int groundIndex = 0,
    MountingHeights mounting = const MountingHeights(),
  }) {
    _undo.clear();
    _redo.clear();
    final f = floors.isEmpty ? state.floors : floors;
    state = ProjectState(
      name: name,
      floors: f,
      calibrations: calibrations,
      staleCalibrations: staleCalibrations,
      groundIndex: groundIndex.clamp(0, f.length - 1),
      // F8 — absent on an older document ⇒ the engine defaults, so an opened
      // pre-F8 project keeps exactly the elevations it was designed with.
      mounting: mounting,
    );
  }

  /// F8 — set how far a horizontal distribution main hangs below the slab above
  /// (m). Clamped to a sane build range; one undo step, like any other project
  /// input. A no-op when the value is unchanged (so a stepper held at its limit
  /// doesn't pile up empty undo entries).
  void setCeilingDrop(double meters) {
    final m = meters.clamp(_minCeilingDrop, _maxCeilingDrop).toDouble();
    if (m == state.mounting.ceilingDrop.meters) return;
    _snapshot();
    state =
        state.copyWith(mounting: state.mounting.copyWith(ceilingDrop: Length(m)));
  }

  /// F8 — set the height of a fixture connection above its own floor surface
  /// (m). Clamped; one undo step; no-op when unchanged.
  void setFixtureHeight(double meters) {
    final m = meters.clamp(_minFixtureHeight, _maxFixtureHeight).toDouble();
    if (m == state.mounting.fixtureHeight.meters) return;
    _snapshot();
    state = state.copyWith(
        mounting: state.mounting.copyWith(fixtureHeight: Length(m)));
  }

  void addFloor() {
    _snapshot();
    final next = Floor('Level ${state.floors.length}', const Length(3.5));
    state = state.copyWith(floors: [...state.floors, next]);
  }

  /// Add [count] typical levels on TOP of the stack in ONE structural undo step
  /// (the consolidated "Add on top"). The ground datum is unchanged and no drawn
  /// node moves — the stack only grows upward. New levels are numbered from the
  /// current top-above-ground ("Level N"). No-op for count <= 0.
  void addFloorsOnTop(int count, double heightM) {
    if (count <= 0) return;
    final h = Length(heightM.clamp(_minHeight, _maxHeight).toDouble());
    // Level number above ground: Ground is "Level 0", so the next number is the
    // count of floors from ground up (== floors.length − groundIndex). With no
    // basement this is floors.length (byte-identical to the old bulk-add name).
    final base = state.floors.length - state.groundIndex;
    final added = [
      for (var k = 0; k < count; k++) Floor('Level ${base + k}', h),
    ];
    ref.read(structuralHistoryProvider.notifier).recordFloorStackChange();
    state = state.copyWith(floors: [...state.floors, ...added]);
    ref.read(networkControllerProvider.notifier).remapNodesForFloorChange(
          levelCount: state.floors.length,
          record: false,
        );
  }

  /// Add [count] BASEMENT levels below the ground floor in ONE structural undo
  /// step: [count] new floors are inserted at the BOTTOM of the stack, the
  /// ground datum shifts up by [count] (so the ground keeps reading elevation
  /// 0.0 and the new levels read NEGATIVE), and every drawn node shifts up
  /// [count] floors to stay on its own physical level. Named "Basement N",
  /// counting DOWN from the ground (the deepest gets the largest N). No-op for
  /// count <= 0.
  void addBasement(int count, double heightM) {
    if (count <= 0) return;
    final h = Length(heightM.clamp(_minHeight, _maxHeight).toDouble());
    final existing = state.groundIndex; // basements already below ground
    // Lowest first: the deepest new basement (largest number) leads the list.
    final added = [
      for (var k = 0; k < count; k++)
        Floor('Basement ${existing + count - k}', h),
    ];
    ref.read(structuralHistoryProvider.notifier).recordFloorStackChange();
    state = state.copyWith(
      floors: [...added, ...state.floors],
      groundIndex: state.groundIndex + count,
    );
    ref.read(networkControllerProvider.notifier).remapNodesForFloorChange(
          levelCount: state.floors.length,
          insertedIndex: 0,
          insertedCount: count,
          record: false,
        );
  }

  /// Replace the whole floor stack in ONE undo step (used by project templates /
  /// smart defaults to prefill a building's levels). A no-op for an empty list —
  /// a building must always have at least one floor.
  ///
  /// The floor swap AND the drawn-node floor-index remap are recorded as a
  /// SINGLE [UndoDomain.structural] entry (via [structuralHistoryProvider]) so
  /// one Ctrl+Z restores BOTH the stack and every node's floor together — never
  /// the torn state where nodes are remapped against a still-changed stack. The
  /// remap keeps drawn work in range (a template with fewer floors than the
  /// drawing can't strand nodes above the new top); it is byte-identical for an
  /// empty network or a stack that only grew.
  void setFloors(List<Floor> floors) {
    if (floors.isEmpty) return;
    ref.read(structuralHistoryProvider.notifier).recordFloorStackChange();
    // A wholesale replace (template / sample / opened doc) is a fresh building —
    // reset the ground datum to the bottom (no basements). Callers that keep a
    // basement stack use [addFloorsOnTop] / [addBasement] instead.
    state = state.copyWith(floors: List<Floor>.from(floors), groundIndex: 0);
    ref.read(networkControllerProvider.notifier).remapNodesForFloorChange(
          levelCount: state.floors.length,
          record: false,
        );
  }

  /// Remove the floor at [index] in ONE undo step. The floor removal AND the
  /// drawn-node remap are a SINGLE [UndoDomain.structural] entry (see
  /// [setFloors]), so one Ctrl+Z restores the stack, every node's floor AND the
  /// work deleted with the floor together. Removing a MIDDLE floor shifts higher
  /// nodes down one index to keep their own physical floor (no silent
  /// re-elevation). Byte-identical remap for an empty network.
  ///
  /// C2 — the work drawn ON the removed floor is DELETED with it (nodes + every
  /// edge touching them; see [NetworkController.remapNodesForFloorChange]). It
  /// used to keep its index while the floor above slid down into that slot, so
  /// two floors' drawn work silently FUSED at the wrong elevation — in range, so
  /// no orphan check fired and nothing warned. Callers should count the affected
  /// elements with [NetworkController.elementsOnFloor] and CONFIRM before
  /// calling this (the Building page does).
  void removeFloor(int index) {
    if (index < 0 || index >= state.floors.length || state.floors.length <= 1) {
      return;
    }
    ref.read(structuralHistoryProvider.notifier).recordFloorStackChange();
    final floors = [...state.floors]..removeAt(index);
    // Removing a BELOW-ground floor slides the datum down one slot so the same
    // physical floor stays "ground"; removing ground-or-above leaves the datum
    // pinned (then clamped into the shrunk range).
    final nextGround = (index < state.groundIndex
            ? state.groundIndex - 1
            : state.groundIndex)
        .clamp(0, floors.length - 1);
    state = state.copyWith(floors: floors, groundIndex: nextGround);
    ref.read(networkControllerProvider.notifier).remapNodesForFloorChange(
          levelCount: state.floors.length,
          removedIndex: index,
          record: false,
        );
  }

  void renameFloor(int index, String name) {
    if (index < 0 || index >= state.floors.length) return;
    _snapshot();
    final floors = [...state.floors];
    floors[index] = floors[index].copyWith(name: name);
    state = state.copyWith(floors: floors);
  }

  void setFloorHeight(int index, Length height) {
    if (index < 0 || index >= state.floors.length) return;
    _snapshot();
    final clamped =
        height.meters.clamp(_minHeight, _maxHeight).toDouble();
    final floors = [...state.floors];
    floors[index] = floors[index].copyWith(height: Length(clamped));
    state = state.copyWith(floors: floors);
  }

  /// Adjust a floor's height by [deltaMeters] (clamped to a sane range).
  void nudgeFloorHeight(int index, double deltaMeters) {
    if (index < 0 || index >= state.floors.length) return;
    setFloorHeight(index, Length(state.floors[index].height.meters + deltaMeters));
  }

  void setCalibration(String sheetId, ScaleCalibration calibration) {
    _snapshot();
    final next = Map<String, ScaleCalibration>.from(state.calibrations)
      ..[sheetId] = calibration;
    // J1: an explicit (re-)calibration IS the re-verification — clear any
    // stale flag the sheet was carrying.
    final nextStale = state.staleCalibrations.contains(sheetId)
        ? (Set<String>.from(state.staleCalibrations)..remove(sheetId))
        : state.staleCalibrations;
    state = state.copyWith(calibrations: next, staleCalibrations: nextStale);
  }

  /// J1 — flag [sheetId]'s calibration STALE: its plan source was just
  /// replaced (`SheetsController.replaceSheetSource`) while an existing
  /// calibration survived (calibration is keyed by sheet id, so it silently
  /// carries over to the revised plan). A no-op when the sheet has no
  /// calibration yet (already surfaced as "not calibrated") or is already
  /// flagged. Not undoable — a bookkeeping flag alongside the (also
  /// not-undoable) source swap itself.
  void markCalibrationStale(String sheetId) {
    if (!state.calibrations.containsKey(sheetId)) return;
    if (state.staleCalibrations.contains(sheetId)) return;
    state = state.copyWith(
        staleCalibrations: {...state.staleCalibrations, sheetId});
  }

  /// J1 — clear [sheetId]'s stale-calibration flag WITHOUT changing its
  /// scale: the "Scale confirmed" action for an engineer who checked the
  /// replaced plan and confirmed the old scale still holds. Not undoable,
  /// like [markCalibrationStale].
  void confirmCalibration(String sheetId) {
    if (!state.staleCalibrations.contains(sheetId)) return;
    final next = Set<String>.from(state.staleCalibrations)..remove(sheetId);
    state = state.copyWith(staleCalibrations: next);
  }

  /// Copy [fromSheetId]'s calibration onto the [toSheetIds] sheets, as ONE undo
  /// step — a per-sheet calibration QoL shortcut (one sheet measured ⇒ apply
  /// that scale to others). [toSheetIds] is the set of sheets to stamp (the
  /// caller passes the live sheet ids, since the sheet list lives in
  /// `SheetsState`, not here); when null it falls back to every sheet that
  /// already has a calibration.
  ///
  /// Returns the number of OTHER sheets whose scale actually changed (so the UI
  /// can report "Scale applied to N sheets", D2). No-op — returning 0, recording
  /// nothing — when the source is uncalibrated or nothing would change (so the
  /// caller can default to the safe uncalibrated-only target set and confirm
  /// before overwriting a differing scale; see [uncalibratedAmong] /
  /// [differentlyCalibratedFrom]).
  int applyCalibrationToAllSheets(String fromSheetId, {Set<String>? toSheetIds}) {
    final source = state.calibrationFor(fromSheetId);
    if (source == null) return 0;
    final targets = toSheetIds ?? state.calibrations.keys.toSet();
    final next = Map<String, ScaleCalibration>.from(state.calibrations);
    // J1: a freshly-stamped calibration is a re-verification too — clear any
    // stale flag on a sheet this actually changes.
    final nextStale = Set<String>.from(state.staleCalibrations);
    var changed = 0;
    for (final id in targets) {
      if (id == fromSheetId) continue;
      if (next[id] == source) continue; // already this scale — no change
      next[id] = source;
      nextStale.remove(id);
      changed++;
    }
    if (changed == 0) return 0;
    _snapshot();
    state = state.copyWith(calibrations: next, staleCalibrations: nextStale);
    return changed;
  }
}

final projectControllerProvider =
    NotifierProvider<ProjectController, ProjectState>(ProjectController.new);

/// F8 — the project's live [MountingHeights], as a provider every consumer can
/// watch instead of constructing `const MountingHeights()` at the call site.
/// Derived (read-only): the project state owns the value; this is the ONE place
/// a widget/store reads it from, so the role-aware node elevations, the riser
/// lengths and the report's design-basis rows can never disagree.
final mountingProvider = Provider<MountingHeights>(
    (ref) => ref.watch(projectControllerProvider).mounting);
