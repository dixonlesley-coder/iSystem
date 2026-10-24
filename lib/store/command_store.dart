/// Command palette + workflow-stepper state (discoverability).
///
/// Two app-shell-local concerns live here, both pure Riverpod over the EXISTING
/// stores (no model change, no persistence):
///  • [commandPaletteOpenProvider] — whether the Ctrl/Cmd+K overlay is shown;
///  • [workflowStageStateProvider] — the done/active state of the five MEP
///    workflow stages (Calibrate · Floors · Draw · Size · Report), derived O(1)
///    from project / network / sizing state for the status-bar stepper.
///
/// The command LIST itself ([buildCommands]) is assembled in the widget layer
/// (it needs a live [WidgetRef] to run intent methods through the controllers),
/// but the pure fuzzy-match scoring used to filter it lives here so it is unit
/// testable without a widget tree.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/units.dart';

import '../ui/strings/app_strings.dart';
import 'design_issues_store.dart' show zeroLengthSizedEdgeCountProvider;
import 'electrical_store.dart'
    show electricalResultProvider, electricalSizingProjectProvider;
import 'network_store.dart';
import 'project_store.dart';
import 'sheets_store.dart';
import 'sizing_store.dart';

/// Whether the Ctrl/Cmd+K command palette overlay is open. Defaults to closed
/// (so a fresh launch and the golden screenshots are unchanged — the overlay
/// renders nothing when idle).
final commandPaletteOpenProvider =
    NotifierProvider<CommandPaletteController, bool>(
  CommandPaletteController.new,
);

class CommandPaletteController extends Notifier<bool> {
  @override
  bool build() => false;

  void open() {
    _closeExportSheet(ref);
    state = true;
  }

  void close() => state = false;
  void toggle() {
    if (!state) _closeExportSheet(ref);
    state = !state;
  }
}

/// Whether the Keyboard-shortcuts reference sheet (F1) is open. Like the
/// palette it is a non-layout overlay that renders nothing when closed, so a
/// fresh launch and the golden screenshots are unchanged.
final shortcutsSheetOpenProvider =
    NotifierProvider<ShortcutsSheetController, bool>(
  ShortcutsSheetController.new,
);

class ShortcutsSheetController extends Notifier<bool> {
  @override
  bool build() => false;

  void open() {
    _closeExportSheet(ref);
    state = true;
  }

  void close() => state = false;
  void toggle() {
    if (!state) _closeExportSheet(ref);
    state = !state;
  }
}

/// Closes the Export sheet when another shell overlay opens, so two scrims can
/// never stack (the same exclusivity the palette and shortcuts sheet share).
void _closeExportSheet(Ref ref) {
  if (ref.read(exportSheetProvider) != null) {
    ref.read(exportSheetProvider.notifier).close();
  }
}

/// The groups of the ONE Export sheet (Ctrl/Cmd+E). [submittal] is the
/// "no particular group" opening: the primary submittal-package action is
/// focused and every group starts collapsed. The others pre-expand + focus
/// that group — how each workspace's own Export button lands on its rows.
enum ExportGroup { submittal, drawings, reports, data, electrical, commercial }

/// Whether the Export sheet is open, and with which group preselected.
/// `null` = closed (the default, so a fresh launch and the goldens render
/// nothing). Transient UI state — never persisted.
final exportSheetProvider =
    NotifierProvider<ExportSheetController, ExportGroup?>(
  ExportSheetController.new,
);

class ExportSheetController extends Notifier<ExportGroup?> {
  @override
  ExportGroup? build() => null;

  /// Open the sheet with [group] pre-expanded (default: the submittal
  /// action focused, groups collapsed). Closes the command palette and the
  /// shortcuts sheet first.
  void open([ExportGroup group = ExportGroup.submittal]) {
    ref.read(commandPaletteOpenProvider.notifier).close();
    ref.read(shortcutsSheetOpenProvider.notifier).close();
    state = group;
  }

  void close() => state = null;

  /// Ctrl/Cmd+E: open on the default group, or close when already open.
  void toggle() => state == null ? open() : close();
}

/// The stable ids of recently-run palette commands, most-recent first, capped
/// at [RecentCommandsController.max]. Session-transient by design (a fresh
/// launch starts empty), so the palette-closed goldens are unaffected — this
/// only hoists frequently used actions toward the top of the list and breaks
/// score ties, never adds or removes a command.
final recentCommandsProvider =
    NotifierProvider<RecentCommandsController, List<String>>(
  RecentCommandsController.new,
);

class RecentCommandsController extends Notifier<List<String>> {
  /// How many recent-command ids to remember.
  static const int max = 8;

  @override
  List<String> build() => const [];

  /// Push [id] to the front of the recency list (dropping any earlier
  /// occurrence), capped at [max]. Empty ids are ignored.
  void record(String id) {
    if (id.isEmpty) return;
    final next = <String>[id, ...state.where((e) => e != id)];
    state = next.length > max ? next.sublist(0, max) : next;
  }
}

/// One stage of the linear MEP workflow shown in the status-bar stepper.
enum WorkflowStage { calibrate, floors, draw, size, report }

extension WorkflowStageInfo on WorkflowStage {
  /// Short label drawn in the stepper, localized via [strings]. A3: the
  /// "floors" stage is labelled "Building" (matching StringKey.navBuilding /
  /// ShellSection.building — the ONE term used everywhere floor/height editing
  /// is reached) rather than "Floors", which never appears in the nav rail.
  String label(MechXStringsData strings) => switch (this) {
        WorkflowStage.calibrate => strings(StringKey.workflowStageCalibrate),
        WorkflowStage.floors => strings(StringKey.workflowStageBuilding),
        WorkflowStage.draw => strings(StringKey.workflowStageDraw),
        WorkflowStage.size => strings(StringKey.workflowStageSize),
        WorkflowStage.report => strings(StringKey.workflowStageReport),
      };
}

/// The per-stage done flags + the first not-yet-done stage (the "active" one).
/// Derived purely from existing state; cheap O(1) `.isNotEmpty`/`.length`
/// checks only (never an O(n) scan per frame).
@immutable
class WorkflowState {
  /// Whether each stage's precondition is satisfied (done), keyed by stage.
  final Map<WorkflowStage, bool> done;

  const WorkflowState(this.done);

  bool isDone(WorkflowStage s) => done[s] ?? false;

  /// The active stage = the first stage in order that is NOT yet done. When all
  /// are done it stays on the last stage (Report) so the stepper still reads as
  /// "you are here" rather than pointing past the end.
  WorkflowStage get active {
    for (final s in WorkflowStage.values) {
      if (!isDone(s)) return s;
    }
    return WorkflowStage.report;
  }
}

/// Whether any deliverable has been EXPORTED this session — the honest input
/// for the stepper's Report stage (previously aliased to `sized`, so Report
/// claimed completion the moment any edge was sized, before any report
/// existed). Session-transient by design: a fresh open starts un-exported.
final reportExportedProvider = NotifierProvider<ReportExportedController, bool>(
    ReportExportedController.new);

class ReportExportedController extends Notifier<bool> {
  @override
  bool build() => false;

  void markExported() => state = true;

  /// Back to un-exported — called when a document is applied (File > New /
  /// Open / recovery), honouring "a fresh open starts un-exported" (Round 12).
  void reset() => state = false;
}

/// Whether the engineer has opened the Building (floors) screen this session —
/// the honest "the user has actually engaged with the floor setup" signal for
/// the stepper's Floors stage. Session-transient by design (a fresh launch
/// starts unvisited), so a cold launch shows Floors as NOT done rather than
/// pre-ticking it off the default 3-floor seed (A2). Latched by the app shell
/// when the Building section is shown.
final buildingVisitedProvider =
    NotifierProvider<BuildingVisitedController, bool>(
  BuildingVisitedController.new,
);

class BuildingVisitedController extends Notifier<bool> {
  @override
  bool build() => false;

  void markVisited() {
    if (!state) state = true;
  }

  /// Round 17 follow-up (ui-journeys-3-new-project-keeps-floors-tick) — a
  /// document swap (File > New / Open) starts unvisited, like a cold launch:
  /// the previous project's Building visit must not tick Floors for this one.
  void reset() {
    if (state) state = false;
  }
}

/// The default floor stack seeded by `ProjectController.build()` — a fresh,
/// untouched building. The stepper's Floors stage is DONE only once the stack
/// has been changed away from this seed (a template applied, a floor
/// added/renamed/re-heighted); kept in sync with `project_store.dart`. Combined
/// with [buildingVisitedProvider] so simply visiting the Building screen also
/// counts (A2).
const List<Floor> _kDefaultFloorStack = [
  Floor('Ground', Length(4.0)),
  Floor('Level 1', Length(3.5)),
  Floor('Level 2', Length(3.5)),
];

/// Live workflow stage state for the status-bar stepper. Done when:
///  • Calibrate — any loaded sheet has a calibration;
///  • Floors    — the engineer has engaged with the levels (visited/edited the
///    Building screen, or changed the stack away from the default seed);
///  • Draw      — the network has at least one edge, OR (Round 29) an
///    electrical board carries at least one way — the welcome card promises
///    'lay out pipes, ducts and panels';
///  • Size      — at least one edge is sized AND a sheet is calibrated (an
///    uncalibrated solve runs on 0.0 m lengths, so it is not a finished step);
///    with NO mechanical edges, an electrical design whose ways are solved
///    (the electrical result sizes every board) completes it too;
///  • Report    — a deliverable (report/drawing/BOM) was exported this session.
final workflowStageStateProvider = Provider<WorkflowState>((ref) {
  final project = ref.watch(projectControllerProvider);
  final sheets = ref.watch(sheetsContentProvider).sheets;
  final edges = ref.watch(sizingNetworkProvider).edges;
  final sizing = ref.watch(sizingProvider);

  // Round 17 follow-up (ui-journeys-3-stepper-size-ticked-on-zero-length) —
  // with drawn work, Calibrate is done only when EVERY sheet carrying a drawn
  // edge is calibrated (one calibrated page beside an uncalibrated page holding
  // the whole network used to tick it); with no edges, any calibrated sheet.
  // The SAME edge-bearing rule the Review's critical 'Sheet not calibrated'
  // uses (a sheet holding any node with an incident edge), so the stepper can
  // never tick Calibrate while Review shows that blocker.
  final net = ref.watch(sizingNetworkProvider);
  final liveSheetIds = {for (final s in sheets) s.id};
  final edgeNodeIds = {
    for (final e in edges) ...[e.fromId, e.toId],
  };
  final drawnSheets = {
    for (final n in net.nodes)
      if (edgeNodeIds.contains(n.id) && liveSheetIds.contains(n.sheetId))
        n.sheetId,
  };
  final calibrated = drawnSheets.isEmpty
      ? sheets.any((s) => project.calibrationFor(s.id) != null)
      : drawnSheets.every((sid) => project.calibrationFor(sid) != null);
  final hasNetwork = edges.isNotEmpty;
  final sized = sizing.isNotEmpty;
  // Round 29 (ui-journeys-3-stepper-ignores-electrical) — electrical work
  // counts: a board with at least one way is drawn work, and with no
  // mechanical edge its solved result is the sizing (the calibrated /
  // zero-length guards stay scoped to the mechanical network).
  final elecProject = ref.watch(electricalSizingProjectProvider);
  final hasElectrical = elecProject.panels.any((p) => p.circuits.isNotEmpty);
  final elecSized = hasElectrical &&
      ref.watch(electricalResultProvider).panels.isNotEmpty;
  // A fresh project ships with the default 3-floor seed, so the old
  // `floors.length > 1` marked Floors DONE before the user touched anything —
  // the map lied on first contact (A2). "Floors" is honest only once the
  // engineer has genuinely engaged with the levels: opened the Building screen
  // this session ([buildingVisitedProvider]) or changed the stack away from the
  // seed (a template, or an added / renamed / re-heighted floor). Drawing a
  // network is deliberately EXCLUDED (A4): §10 makes the floor stack the sole
  // source of truth for every riser's vertical length, so a network existing
  // must never tick Floors done on its own — that let an engineer draw first
  // and get a green Floors checkmark while running on the untouched default
  // heights, unreviewed. Dropping the clause instead sends the "active"
  // pointer back to Floors (a distinct highlighted state, not the done tick)
  // until Building is actually opened, even once drawing has moved ahead.
  final floorsSet = ref.watch(buildingVisitedProvider) ||
      !listEquals(project.floors, _kDefaultFloorStack);

  return WorkflowState({
    WorkflowStage.calibrate: calibrated,
    WorkflowStage.floors: floorsSet,
    WorkflowStage.draw: hasNetwork || hasElectrical,
    // F11 — Size is honest only on a MEASURED network. Without a calibration
    // every horizontal run is 0.0 m (§10 makes the per-sheet scale the sole
    // source of horizontal length), so the sizing that "completed" is running
    // on unmeasured geometry and the BOM prints `unmeasured ×N`. Ticking the
    // stage off `sized` alone told the engineer a step was finished that the
    // deliverable itself contradicts — the same honesty class the Floors tick
    // was fixed for (A2).
    //
    // Round 17 follow-up — and no SIZED run may still be 0.0 m (the export
    // gate's own blocker).
    WorkflowStage.size: hasNetwork
        ? sized &&
            calibrated &&
            ref.watch(zeroLengthSizedEdgeCountProvider) == 0
        : elecSized,
    WorkflowStage.report: ref.watch(reportExportedProvider),
  });
});

/// Pure subsequence fuzzy match: every char of [query] must appear in
/// [candidate] in order (case-insensitive). Empty query matches everything.
/// Returns a score (higher = better) or null when it doesn't match — so the
/// palette can both filter and rank without a second pass.
///
/// Scoring rewards earlier matches, contiguous runs, and word-boundary hits so
/// "er" ranks "Export report" above an incidental mid-word hit.
int? fuzzyScore(String query, String candidate) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return 0;
  final c = candidate.toLowerCase();

  var score = 0;
  var ci = 0; // index into candidate
  var prevMatch = -2; // last matched candidate index (for run bonus)
  for (var qi = 0; qi < q.length; qi++) {
    final ch = q.codeUnitAt(qi);
    var found = -1;
    for (var k = ci; k < c.length; k++) {
      if (c.codeUnitAt(k) == ch) {
        found = k;
        break;
      }
    }
    if (found == -1) return null; // a query char is missing in order
    // Earlier matches score higher.
    score += 100 - found;
    // Contiguous-run bonus.
    if (found == prevMatch + 1) score += 15;
    // Word-boundary bonus (start, or after a space / separator).
    if (found == 0 ||
        c[found - 1] == ' ' ||
        c[found - 1] == '/' ||
        c[found - 1] == '-') {
      score += 10;
    }
    prevMatch = found;
    ci = found + 1;
  }
  return score;
}

/// Whether [candidate] matches [query] under the fuzzy subsequence rule.
bool fuzzyMatches(String query, String candidate) =>
    fuzzyScore(query, candidate) != null;

/// Best fuzzy score of [query] against a command's [title] OR its [subtitle],
/// so the palette filters/ranks on both fields (a query that only appears in
/// the subtitle still surfaces its row). A subtitle-only hit is discounted by
/// [_subtitlePenalty] so a genuine title match always outranks it. Returns null
/// when neither field matches. Pure — unit-testable without a widget tree.
int? commandMatchScore(String query, String title, [String subtitle = '']) {
  final t = fuzzyScore(query, title);
  final s = subtitle.isEmpty ? null : fuzzyScore(query, subtitle);
  if (t == null && s == null) return null;
  final ts = t ?? _noMatch;
  final ss = s == null ? _noMatch : s - _subtitlePenalty;
  return ts >= ss ? ts : ss;
}

const int _noMatch = -1 << 20;
const int _subtitlePenalty = 50;
