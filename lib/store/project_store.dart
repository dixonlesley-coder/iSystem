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

  const ProjectState({
    required this.name,
    required this.floors,
    this.calibrations = const {},
  });

  BuildingLevels get building => BuildingLevels(floors);

  ScaleCalibration? calibrationFor(String sheetId) => calibrations[sheetId];

  ProjectState copyWith({
    String? name,
    List<Floor>? floors,
    Map<String, ScaleCalibration>? calibrations,
  }) =>
      ProjectState(
        name: name ?? this.name,
        floors: floors ?? this.floors,
        calibrations: calibrations ?? this.calibrations,
      );
}

class ProjectController extends Notifier<ProjectState> {
  static const double _minHeight = 0.5;
  static const double _maxHeight = 20.0;

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
  }) {
    _undo.clear();
    _redo.clear();
    state = ProjectState(
      name: name,
      floors: floors.isEmpty ? state.floors : floors,
      calibrations: calibrations,
    );
  }

  void addFloor() {
    _snapshot();
    final next = Floor('Level ${state.floors.length}', const Length(3.5));
    state = state.copyWith(floors: [...state.floors, next]);
  }

  /// Replace the whole floor stack in one undo step (used by project
  /// templates / smart defaults to prefill a building's levels). A no-op for an
  /// empty list — a building must always have at least one floor.
  void setFloors(List<Floor> floors) {
    if (floors.isEmpty) return;
    _snapshot();
    state = state.copyWith(floors: List<Floor>.from(floors));
    // Keep drawn work in range so a template with fewer floors than the drawing
    // can't strand nodes above the new top (which the always-on solve would
    // otherwise size at a clamped elevation). One network undo step; a no-op —
    // byte-identical — for an empty network or a stack that only grew.
    ref
        .read(networkControllerProvider.notifier)
        .remapNodesForFloorChange(levelCount: state.floors.length);
  }

  void removeFloor(int index) {
    if (index < 0 || index >= state.floors.length || state.floors.length <= 1) {
      return;
    }
    _snapshot();
    final floors = [...state.floors]..removeAt(index);
    state = state.copyWith(floors: floors);
    // Shift drawn nodes with the stack so removing a MIDDLE floor doesn't
    // silently re-elevate the floors above it (their nodes drop one index to
    // stay on their own physical floor); nodes on/above a removed top clamp
    // into range. One network undo step; no-op for an empty network.
    ref.read(networkControllerProvider.notifier).remapNodesForFloorChange(
          levelCount: state.floors.length,
          removedIndex: index,
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
    state = state.copyWith(calibrations: next);
  }

  /// Copy [fromSheetId]'s calibration onto every other sheet, as ONE undo step
  /// — a per-sheet calibration QoL shortcut (one sheet measured ⇒ apply that
  /// scale to all). [toSheetIds] is the set of sheets to stamp (the caller
  /// passes the live sheet ids, since the sheet list lives in `SheetsState`,
  /// not here); when null it falls back to every sheet that already has a
  /// calibration. No-op if the source sheet is uncalibrated.
  void applyCalibrationToAllSheets(String fromSheetId, {Set<String>? toSheetIds}) {
    final source = state.calibrationFor(fromSheetId);
    if (source == null) return;
    final targets = toSheetIds ?? state.calibrations.keys.toSet();
    _snapshot();
    final next = Map<String, ScaleCalibration>.from(state.calibrations);
    for (final id in targets) {
      if (id == fromSheetId) continue;
      next[id] = source;
    }
    state = state.copyWith(calibrations: next);
  }
}

final projectControllerProvider =
    NotifierProvider<ProjectController, ProjectState>(ProjectController.new);
