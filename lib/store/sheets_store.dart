import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

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

  /// Append every sheet in [incoming] to the current set in ONE action (A6
  /// multi-file add), remapping any id that would collide with a live sheet — or
  /// a sibling earlier in this same batch — to a fresh unique one (`<id>-1`,
  /// `<id>-2`, …). Filename-derived ids (`stem#i`) can otherwise repeat across
  /// files (two `denah.pdf`s) or against an existing sheet, silently sharing its
  /// calibration + floor mapping; a fresh id is safe because no drawn node
  /// references the new sheets yet. Returns how many were appended. Not undoable
  /// — an additive load, like [addSheet] (the autosave signature picks up the
  /// change on its next tick, as with every non-recording sheet mutation).
  int addSheets(Iterable<Sheet> incoming) {
    final list = incoming.toList();
    if (list.isEmpty) return 0;
    final used = state.sheets.map((s) => s.id).toSet();
    final added = <Sheet>[];
    for (final s in list) {
      var id = s.id;
      var n = 1;
      while (used.contains(id)) {
        id = '${s.id}-$n';
        n++;
      }
      used.add(id);
      added.add(id == s.id ? s : s.copyWith(id: id));
    }
    state = state.copyWith(sheets: [...state.sheets, ...added]);
    return added.length;
  }

  /// Rename the sheet with [sheetId] to [name] (A6 rail context menu). The id is
  /// untouched, so calibration and every drawn node stay married to the sheet —
  /// only its display label changes. Trimmed; a no-op for an empty/unchanged
  /// name or an unknown id. Not undoable (a label edit, like [addSheet] /
  /// [replaceSheetSource]).
  void renameSheet(String sheetId, String name) {
    final idx = state.sheets.indexWhere((s) => s.id == sheetId);
    if (idx < 0) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == state.sheets[idx].name) return;
    final sheets = [...state.sheets];
    sheets[idx] = sheets[idx].copyWith(name: trimmed);
    state = state.copyWith(sheets: sheets);
  }

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

  /// Remove the sheet with [sheetId] from the project AND prune every drawn node
  /// that lived on it (plus the edges touching them) — in ONE undo-safe step
  /// (A6 rail context menu). The sheet removal + the node prune are captured as a
  /// SINGLE [UndoDomain.structural] entry via [structuralHistoryProvider] (the
  /// same coordinator [setSheetFloor] uses), so one Ctrl+Z restores the sheet,
  /// its per-sheet viewport/floor entries AND the pruned network together — never
  /// a torn state, and orphaned pipes on the gone sheet can't invisibly pad the
  /// BOM / pressures / reports (the active analogue of the Replace-all prune on
  /// [NetworkController.pruneNodesNotOnSheets]).
  ///
  /// The sheet's CALIBRATION is deliberately left in the project's map: it is
  /// keyed by id, so it is never queried once the sheet is gone, and it comes
  /// back intact on undo (no project-domain capture needed). The current index is
  /// shifted so the selection stays put when an earlier sheet is removed, and
  /// clamped into range. No-op when [sheetId] is unknown.
  void removeSheet(String sheetId) {
    final idx = state.sheets.indexWhere((s) => s.id == sheetId);
    if (idx < 0) return;
    final levelCount = ref.read(projectControllerProvider).building.levelCount;
    // Snapshot the effective floor of every OTHER sheet BEFORE removal — their
    // drawn nodes carry this as their frozen floorIndex. Removing a non-last
    // sheet shifts every later sheet's POSITIONAL-default floor down by one, so
    // their work must be remapped (B7 hazard) or the canvas — which filters on
    // BOTH sheetId AND floorIndex — would silently hide it while it kept feeding
    // sizing at the old elevation. Sheets with an explicit floor override are
    // position-independent (delta 0).
    final oldFloors = <String, int>{
      for (final s in state.sheets)
        if (s.id != sheetId) s.id: state.floorFor(s.id, levelCount),
    };
    // Capture sheets + network as ONE structural snapshot BEFORE mutating.
    ref.read(structuralHistoryProvider.notifier).recordSheetMappingChange();
    // Prune the removed sheet's nodes (+ their edges) WITHOUT a separate network
    // entry — the structural snapshot already holds the pre-removal network, so
    // undo/redo swap both halves atomically (mirrors [remapSheetFloor]'s
    // record:false path used by [setSheetFloor]).
    final net = ref.read(networkControllerProvider).network;
    final orphans = <String>{
      for (final n in net.nodes)
        if (n.sheetId == sheetId) n.id,
    };
    if (orphans.isNotEmpty) {
      final nodes = net.nodes.where((n) => !orphans.contains(n.id)).toList();
      final edges = net.edges
          .where((e) =>
              !orphans.contains(e.fromId) && !orphans.contains(e.toId))
          .toList();
      ref
          .read(networkControllerProvider.notifier)
          .restoreNetwork(Network(nodes: nodes, edges: edges));
    }
    // Drop the sheet and its per-sheet viewport/floor entries.
    final sheets = [...state.sheets]..removeAt(idx);
    final viewports = Map<String, ViewportTransform>.from(state.viewports)
      ..remove(sheetId);
    final sheetFloors = Map<String, int>.from(state.sheetFloors)
      ..remove(sheetId);
    // Keep the selection on the same sheet when an earlier one is removed, then
    // clamp into the shrunken range.
    var current = state.currentIndex;
    if (idx < current) current -= 1;
    if (current >= sheets.length) current = sheets.length - 1;
    if (current < 0) current = 0;
    state = SheetsState(
      sheets: sheets,
      currentIndex: current,
      viewports: viewports,
      sheetFloors: sheetFloors,
    );
    // Now that the list has shrunk, remap each sibling whose effective floor
    // moved by the delta — no separate network entry (the structural snapshot
    // above already holds the pre-removal network, so one Ctrl+Z reverts the
    // sheet removal, the node prune AND every sibling shift together).
    final netCtrl = ref.read(networkControllerProvider.notifier);
    oldFloors.forEach((id, oldFloor) {
      final newFloor = state.floorFor(id, levelCount);
      if (newFloor != oldFloor) {
        netCtrl.remapSheetFloor(id, newFloor - oldFloor,
            levelCount: levelCount, record: false);
      }
    });
  }
}

final sheetsControllerProvider =
    NotifierProvider<SheetsController, SheetsState>(SheetsController.new);
