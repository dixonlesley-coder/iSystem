import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/canvas/viewport.dart';
import 'history_store.dart';
import 'models/sheet.dart';
import 'network_store.dart';
import 'project_store.dart';

/// Immutable sheet-navigation state: the loaded [sheets], the [currentIndex],
/// and a per-sheet [viewports] map so each sheet's pan/zoom is restored when
/// you switch back to it (§4 viewport restore). Disk persistence of this state
/// lands with the project-file / drift layer.
@immutable
class SheetsState {
  final List<Sheet> sheets;
  final int currentIndex;
  final Map<String, ViewportTransform> viewports;

  /// Explicit sheet → building-floor mapping. When a sheet isn't listed, its
  /// floor defaults to its position in [sheets] (one plan per floor).
  final Map<String, int> sheetFloors;

  const SheetsState({
    this.sheets = const [],
    this.currentIndex = 0,
    this.viewports = const {},
    this.sheetFloors = const {},
  });

  bool get isEmpty => sheets.isEmpty;

  Sheet? get current =>
      sheets.isEmpty ? null : sheets[currentIndex.clamp(0, sheets.length - 1)];

  /// Stored viewport for [sheetId], or `null` if it hasn't been framed yet
  /// (the canvas will fit-to-view on first show).
  ViewportTransform? viewportFor(String sheetId) => viewports[sheetId];

  /// The building floor a sheet maps to: an explicit override, else the sheet's
  /// positional index — both clamped to the building's [levelCount].
  int floorFor(String sheetId, int levelCount) {
    final pos = sheets.indexWhere((s) => s.id == sheetId);
    final base = sheetFloors[sheetId] ?? (pos < 0 ? 0 : pos);
    return base.clamp(0, levelCount - 1);
  }

  SheetsState copyWith({
    List<Sheet>? sheets,
    int? currentIndex,
    Map<String, ViewportTransform>? viewports,
    Map<String, int>? sheetFloors,
  }) =>
      SheetsState(
        sheets: sheets ?? this.sheets,
        currentIndex: currentIndex ?? this.currentIndex,
        viewports: viewports ?? this.viewports,
        sheetFloors: sheetFloors ?? this.sheetFloors,
      );
}

/// The P0 placeholder demo sheets. Production launches EMPTY (A1) — work drawn
/// on placeholder paper is a dead end that Import then discards, and the Layout
/// empty-state card (Import plan… / New from template…) is only reachable when
/// no sheet exists. Kept public so tests and the golden screenshot suite can
/// seed a deterministic multi-sheet project explicitly
/// ([SheetsController.loadDemoSheets]).
const List<Sheet> kDemoSheets = [
  Sheet(id: 's1', name: 'Ground Floor', sizePx: Size(1684, 1190)),
  Sheet(id: 's2', name: 'First Floor', sizePx: Size(1684, 1190)),
  Sheet(id: 's3', name: 'Roof Plan', sizePx: Size(1190, 1684)),
];

class SheetsController extends Notifier<SheetsState> {
  @override
  SheetsState build() => const SheetsState();

  /// Seed the [kDemoSheets] placeholder project — a test/golden hook only (a
  /// real project starts empty and gets its sheets from Import / Open).
  void loadDemoSheets() => loadSheets(kDemoSheets);

  void loadSheets(
    List<Sheet> sheets, {
    Map<String, ViewportTransform> viewports = const {},
    Map<String, int> sheetFloors = const {},
  }) {
    state = SheetsState(
      sheets: sheets,
      currentIndex: 0,
      viewports: viewports,
      sheetFloors: sheetFloors,
    );
  }

  /// Restore a captured [SheetsState] WITHOUT recording undo — the
  /// [StructuralHistoryController]'s restore path for the compound sheet→floor
  /// re-mapping ([setSheetFloor]). Not for widgets.
  void restoreState(SheetsState snapshot) => state = snapshot;

  /// Map [sheetId] to building floor [floorIndex] (explicit override), in ONE
  /// undo step. The mapping change AND the drawn-node remap are recorded as a
  /// SINGLE [UndoDomain.structural] entry (via [structuralHistoryProvider]) so
  /// one Ctrl+Z restores BOTH the mapping and every affected node's floor
  /// together — never the torn state where the nodes moved but the mapping
  /// didn't (or vice-versa).
  ///
  /// B7: the work drawn on the sheet MOVES WITH the mapping — its nodes'
  /// (frozen-at-creation) `floorIndex` shifts by the same amount the effective
  /// floor moved. Without this the canvas — which filters on BOTH sheetId AND
  /// floorIndex — would hide everything drawn on the sheet while it kept feeding
  /// sizing at the old elevation.
  void setSheetFloor(String sheetId, int floorIndex) {
    if (state.sheetFloors[sheetId] == floorIndex) return;
    // Effective floor BEFORE the change (positional default or a prior
    // override, clamped to the live building) — the floorIndex the sheet's
    // drawn nodes currently carry.
    final levelCount = ref.read(projectControllerProvider).building.levelCount;
    final oldFloor = state.floorFor(sheetId, levelCount);
    ref.read(structuralHistoryProvider.notifier).recordSheetMappingChange();
    final next = Map<String, int>.from(state.sheetFloors)
      ..[sheetId] = floorIndex;
    state = state.copyWith(sheetFloors: next);
    // Shift the sheet's nodes by the effective-floor delta WITHOUT a separate
    // network entry (the structural snapshot already captured the network) —
    // no-op when the effective floor is unchanged or the sheet has no nodes.
    final newFloor = state.floorFor(sheetId, levelCount);
    ref.read(networkControllerProvider.notifier).remapSheetFloor(
          sheetId,
          newFloor - oldFloor,
          levelCount: levelCount,
          record: false,
        );
  }

  void selectSheet(int index) {
    if (index < 0 || index >= state.sheets.length || index == state.currentIndex) {
      return;
    }
    state = state.copyWith(currentIndex: index);
  }

  void selectSheetById(String id) {
    final i = state.sheets.indexWhere((s) => s.id == id);
    if (i != -1) selectSheet(i);
  }

  /// Persist a sheet's pan/zoom so it restores on return.
  void setViewport(String sheetId, ViewportTransform transform) {
    if (state.viewports[sheetId] == transform) return;
    final next = Map<String, ViewportTransform>.from(state.viewports)
      ..[sheetId] = transform;
    state = state.copyWith(viewports: next);
  }

  void addSheet(Sheet sheet) =>
      state = state.copyWith(sheets: [...state.sheets, sheet]);

  /// Swap the SOURCE of the sheet with [sheetId] — its pdf/dxf/dwg path, page
  /// index and natural size — for [source]'s, KEEPING the existing id and
  /// display name (the plan-revision workflow, A5). Calibration and drawn nodes
  /// reference a sheet by its id, so revising the source in place preserves both
  /// (they re-marry to the new plan). The source fields are taken WHOLESALE from
  /// [source], so a PDF→DXF swap clears the stale pdfPath. No-op when [sheetId]
  /// is gone or the source is already identical. Not undoable — a source swap,
  /// like [loadSheets].
  void replaceSheetSource(String sheetId, Sheet source) {
    final idx = state.sheets.indexWhere((s) => s.id == sheetId);
    if (idx < 0) return;
    final old = state.sheets[idx];
    final replaced = Sheet(
      id: old.id,
      name: old.name,
      pdfPath: source.pdfPath,
      dxfPath: source.dxfPath,
      dwgPath: source.dwgPath,
      pageIndex: source.pageIndex,
      sizePx: source.sizePx,
    );
    if (replaced == old) return;
    final sheets = [...state.sheets];
    sheets[idx] = replaced;
    state = state.copyWith(sheets: sheets);
  }
}

final sheetsControllerProvider =
    NotifierProvider<SheetsController, SheetsState>(SheetsController.new);
