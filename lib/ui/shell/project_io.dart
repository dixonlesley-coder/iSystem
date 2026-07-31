import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

import '../../data/app_settings.dart';
import '../../data/autosave.dart';
import '../../data/dwg_converter.dart';
import '../../data/dwg_import.dart';
import '../../data/dxf_import.dart';
import '../../data/pdf_import.dart';
import '../../data/project_assets.dart';
import '../../data/project_document.dart';
import '../../data/recovery.dart';
import '../../store/app_state.dart';
import '../../store/electrical_store.dart';
import '../../store/models/sheet.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import '../sheets/pdf_page_picker.dart';
import '../strings/app_strings.dart';
import '../strings/plural.dart';
import 'confirm_discard_dialog.dart';
import 'import_choice_dialog.dart';
import '../inspector/project_panel.dart' show pickExportSave;
import 'nav_rail.dart';

/// Project file I/O shared by the top bar, the global Ctrl/Cmd+S/O hotkeys,
/// the command palette, and the first-launch empty-state actions — lifted out
/// of `_TopBar` so every entry point runs the exact same code.

/// Guard against silently destroying unsaved work: when the live project is
/// dirty, prompt Save / Discard / Cancel before an action that REPLACES it.
/// Returns `true` to PROCEED (clean, discarded, or saved successfully), `false`
/// to ABORT (Cancel/dismiss, or a Save the user backed out of). Uses the
/// FRESH [isProjectDirty] check, not the timer-fed UI hint. Public so every
/// project-replacing (or process-ending — the updater's "Restart & update")
/// entry point runs the exact same guard.
Future<bool> confirmDiscardIfDirty(BuildContext context, WidgetRef ref) async {
  if (!isProjectDirty(ref.read)) return true;
  final choice = await showConfirmDiscardDialog(context);
  switch (choice) {
    case DiscardChoice.save:
      await saveProject(ref);
      // If the user cancelled the OS Save dialog the work is still dirty — don't
      // proceed to destroy it.
      return !isProjectDirty(ref.read);
    case DiscardChoice.discard:
      return true;
    case DiscardChoice.cancel:
    case null:
      return false;
  }
}

/// The directory part of [path], or null when it carries none. Tolerant of
/// either separator (a FilePicker path may use `/` even on Windows).
String? _dirOf(String? path) {
  if (path == null || path.isEmpty) return null;
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  return i > 0 ? path.substring(0, i) : null;
}

/// I1 — the session's last OPEN/IMPORT folder: the sibling of the export
/// surface's `lastExportDirProvider`, seeding every file-CHOOSING dialog so a
/// second import re-opens where the first was picked instead of the OS default.
///
/// Deliberately NOT a new field on the machine-local `AppSettings` (that file is
/// shared this wave): the memory is session-scoped here and FALLS BACK to the
/// persisted `AppSettings.lastOpenPath`'s folder, which gives cross-session
/// continuity without touching the settings schema.
final lastOpenDirProvider =
    NotifierProvider<LastOpenDirController, String?>(LastOpenDirController.new);

class LastOpenDirController extends Notifier<String?> {
  @override
  String? build() => null;

  /// Record the directory of a chosen FILE path (the pickers return file
  /// paths). A path with no directory part is ignored (keeps the prior memory).
  void rememberFile(String path) {
    final dir = _dirOf(path);
    if (dir != null) state = dir;
  }
}

/// The folder an open/import dialog should start in: this session's last picked
/// folder, else the folder of the last project opened/saved on this machine,
/// else null (the OS default).
String? openDialogInitialDirectory(WidgetRef ref) {
  final session = ref.read(lastOpenDirProvider);
  if (session != null && session.isNotEmpty) return session;
  return _dirOf(ref.read(appSettingsProvider).lastOpenPath);
}

/// I1 — the OPEN/IMPORT counterpart of `pickExportSave`: the ONE seam every
/// file-choosing dialog routes through, seeded from
/// [openDialogInitialDirectory] and recording the chosen folder so the next
/// dialog re-opens there. Returns the chosen absolute paths — an empty list on
/// cancel (or a pick that yielded no usable path), never null.
Future<List<String>> pickOpenPaths(
  WidgetRef ref, {
  required List<String> allowedExtensions,
  bool allowMultiple = false,
}) async {
  final result = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: allowedExtensions,
    allowMultiple: allowMultiple,
    initialDirectory: openDialogInitialDirectory(ref),
  );
  if (result == null) return const [];
  final paths = <String>[
    for (final f in result.files)
      if (f.path != null && f.path!.isNotEmpty) f.path!,
  ];
  if (paths.isNotEmpty) {
    ref.read(lastOpenDirProvider.notifier).rememberFile(paths.first);
  }
  return paths;
}

/// I5 — a plan import that failed speaks HUMAN. A raw `FormatException` /
/// `StateError` dump ("FormatException: Unexpected character") tells an engineer
/// nothing actionable; the overwhelmingly common cause is the wrong file for the
/// chosen type (a DWG saved with a `.dxf` name, a scanned/locked PDF), so the
/// message names that cause AND the next action, per file TYPE.
///
/// The raw exception text is NEVER swallowed — it rides the `({detail})`
/// parenthetical. An error that is not a parse/format failure (a missing file, a
/// permissions error) keeps the old generic wording rather than asserting a
/// cause it can't know. Pure, so the mapping is unit-testable.
String importFailureMessage(
  MechXStringsData strings, {
  required String what,
  required Object error,
}) {
  final detail = error is FormatException && error.message.isNotEmpty
      ? error.message
      : '$error';
  final mappable = error is FormatException || error is StateError;
  if (!mappable) {
    return strings.format(StringKey.importFailedGenericTemplate,
        {'what': what, 'detail': detail});
  }
  return switch (what) {
    'DXF' => strings.format(StringKey.importFailedDxfTemplate, {'detail': detail}),
    'DWG' => strings.format(StringKey.importFailedDwgTemplate, {'detail': detail}),
    _ => strings.format(StringKey.importFailedPdfTemplate, {'detail': detail}),
  };
}

/// File → New: after a dirty-guard, replace the live state with a virgin
/// project — [applyDocument] resets every store (including electrical + the undo
/// timeline). The file identity is forgotten so the next Save prompts for a
/// location, and the machine-level language/theme are preserved (a New project
/// keeps the engineer's app-level preference rather than resetting it).
Future<void> newProject(BuildContext context, WidgetRef ref) async {
  if (!await confirmDiscardIfDirty(context, ref)) return;
  // The project we're leaving — its recovery slot must be cleared, or a later
  // launch would offer to restore work the user discarded/replaced here (the
  // prior slot, or the shared untitled slot when it was never saved).
  final priorPath = ref.read(currentProjectPathProvider);
  // The virgin floor stack mirrors ProjectController.build()'s default; the
  // presentation settings echo the CURRENT locale/theme so applyDocument
  // (which restores those from the document) leaves the user's preference put.
  final doc = ProjectDocument(
    projectName: 'Untitled project',
    floors: const [
      Floor('Ground', Length(4.0)),
      Floor('Level 1', Length(3.5)),
      Floor('Level 2', Length(3.5)),
    ],
    calibrations: const {},
    sheets: const [],
    network: const Network(),
    settings: DesignSettings(
      brightness: ref.read(brightnessProvider),
      localeCode: ref.read(localeProvider).name,
    ),
  );
  applyDocument(ref.read, doc);
  ref.read(currentProjectPathProvider.notifier).set(null);
  ref.read(lastSavedSignatureProvider.notifier).set(null);
  ref.read(autosaveMirrorProvider.notifier).clear();
  ref.read(projectDirtyProvider.notifier).set(false);
  ref.read(loadErrorProvider.notifier).clear();
  await clearRecoverySlots([priorPath, null]);
  ref.read(statusMessageProvider.notifier).showStatus('New project');
}

/// A5: after a successful import, take the engineer to where the plan now lives
/// — DESIGN → Layout, with the freshly-added sheet at [sheetIndex] selected — so
/// importing from Projects or Review never leaves a "where did it go?" gap.
/// Idempotent: setting the section / view / selection to a value it already
/// holds is a no-op (importing from the empty Layout card just re-selects the
/// same spot).
void _revealImportedSheet(WidgetRef ref, int sheetIndex) {
  ref.read(shellSectionProvider.notifier).set(ShellSection.design);
  ref.read(workspaceViewProvider.notifier).set(WorkspaceView.plan);
  ref.read(sheetsControllerProvider.notifier).selectSheet(sheetIndex);
}

/// Pick and import a PDF / DXF / DWG floor plan into the sheet rail. Into an
/// EMPTY project the import just loads (today's behaviour). Into a NON-EMPTY
/// project it offers Add-to-project vs Replace-all (A5): ADD appends the new
/// sheets (nothing is destroyed, so no dirty-guard); REPLACE swaps every sheet
/// (guarded like today) and then PRUNES the network of nodes left orphaned on
/// the old sheets — so phantom pipes can't invisibly pad the BOM. On success it
/// REVEALS the plan — DESIGN → Layout with the new sheet selected (A5) — so an
/// import triggered from Projects / Review never lands the engineer nowhere.
///
/// [skipDiscardGuard] bypasses the empty-project unsaved-work guard for the A3
/// template flow, where the only "unsaved work" is the just-applied template the
/// engineer wants to keep; every other caller leaves it false (unchanged).
///
/// Returns `true` when a plan was actually imported (added or replaced), `false`
/// on any cancel/guard-abort/failure — so a caller that forced this dialog open
/// (the templates flow, A2) can tell a genuine cancel from a completed import
/// and react (e.g. surface that the template mutation still happened) instead of
/// assuming success.
Future<bool> importPlan(BuildContext context, WidgetRef ref,
    {bool skipDiscardGuard = false}) async {
  final startedNonEmpty =
      ref.read(sheetsControllerProvider).sheets.isNotEmpty;
  // Into an EMPTY project, Import loads straight through — guard any unsaved
  // work up front (today's behaviour). A NON-EMPTY project decides
  // Add-vs-Replace AFTER the file is chosen; only the Replace branch destroys
  // anything, so its guard runs there.
  if (!startedNonEmpty && !skipDiscardGuard) {
    if (!await confirmDiscardIfDirty(context, ref)) return false;
  }
  if (!context.mounted) return false;
  // I1 — one remembered folder across every open/import dialog.
  final picked =
      await pickOpenPaths(ref, allowedExtensions: const ['pdf', 'dxf', 'dwg']);
  if (picked.isEmpty) return false;
  final path = picked.first;

  final lower = path.toLowerCase();
  final isDxf = lower.endsWith('.dxf');
  final isDwg = lower.endsWith('.dwg');
  final what = isDwg
      ? 'DWG'
      : isDxf
          ? 'DXF'
          : 'PDF';
  // A DWG shells out to the ODA converter (seconds); a PDF/DXF still parses on
  // the UI thread — either way, tell the user we're working.
  ref.read(busyProvider.notifier).set(MechXStringsData(ref.read(localeProvider))(
      isDwg ? StringKey.busyConvertingDwg : StringKey.busyImportingPlan));
  try {
    var sheets = isDwg
        ? await importDwg(path,
            converter: const OdaDwgConverter(), outDir: dwgCacheDir())
        : isDxf
            ? await importDxf(path)
            : await importPdf(path);
    if (sheets.isEmpty) {
      ref
          .read(loadErrorProvider.notifier)
          .set('That $what had no importable geometry.');
      return false;
    }
    // Multi-page PDF: let the user pick which pages to bring in (single-page
    // documents — and every DXF, which is one sheet — import straight through).
    if (sheets.length > 1 && context.mounted) {
      final chosen = await showPdfPagePicker(context, sheets);
      if (chosen == null) return false; // cancelled — keep the current project
      if (chosen.isEmpty) return false;
      sheets = chosen;
    }

    // Into a NON-EMPTY project, ask whether to ADD or REPLACE.
    if (startedNonEmpty) {
      if (!context.mounted) return false;
      final existing = ref.read(sheetsControllerProvider).sheets.length;
      final choice = await showImportChoiceDialog(
        context,
        existingSheets: existing,
        incomingSheets: sheets.length,
      );
      if (choice == null) return false; // cancelled — keep the current project
      if (choice == ImportChoice.add) {
        // ADD destroys nothing (current sheets, calibration and network stay),
        // so no dirty-guard: append the new sheets (fresh unique ids remapped by
        // the store, since filename-derived `stem#i` ids can collide with a live
        // sheet — safe, no node references them yet) and stop.
        final added =
            ref.read(sheetsControllerProvider.notifier).addSheets(sheets);
        ref.read(loadErrorProvider.notifier).clear();
        // A5: jump to the first freshly-added sheet — the appended block starts
        // at index `existing` (the sheet count captured before the add).
        _revealImportedSheet(ref, existing);
        ref.read(statusMessageProvider.notifier).showStatus(
            _importStatusMessage(ref,
                imported: added,
                totalSheets: existing + added,
                fromTemplate: skipDiscardGuard,
                added: true));
        return true;
      }
      // REPLACE destroys the current sheets + orphans drawn work — guard now.
      if (!context.mounted) return false;
      if (!await confirmDiscardIfDirty(context, ref)) return false;
    }

    // Replace-all: an empty project, or the explicit Replace choice.
    ref.read(sheetsControllerProvider.notifier).loadSheets(sheets);
    // Prune nodes orphaned onto sheets that no longer exist (one undo step,
    // byte-identical no-op when nothing is orphaned) so phantom pipes can't
    // invisibly pad the BOM / pressures / reports.
    ref
        .read(networkControllerProvider.notifier)
        .pruneNodesNotOnSheets({for (final s in sheets) s.id});
    ref.read(loadErrorProvider.notifier).clear();
    // A5: reveal the imported plan on DESIGN → Layout at the first sheet.
    _revealImportedSheet(ref, 0);
    final n = sheets.length;
    ref.read(statusMessageProvider.notifier).showStatus(_importStatusMessage(ref,
        imported: n,
        totalSheets: n,
        fromTemplate: skipDiscardGuard,
        added: false));
    return true;
  } catch (e) {
    // Surface the failure instead of silently keeping the old sheets — I5: as a
    // human message naming the likely cause, with the raw text in a
    // parenthetical.
    ref.read(loadErrorProvider.notifier).set(importFailureMessage(
        MechXStringsData(ref.read(localeProvider)),
        what: what,
        error: e));
    return false;
  } finally {
    ref.read(busyProvider.notifier).clear();
  }
}

/// The basename of a file path, tolerant of either separator (a FilePicker path
/// may use `/` even on Windows, where [Platform.pathSeparator] is `\`).
String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;

/// The status confirmation for a completed import.
///
/// F10 — a TEMPLATE forces this import right after seeding a 12-floor building,
/// and the engineer typically has one or two plans to hand: the old
/// "1 sheet imported" said nothing about floors 2-12 being left planless, and
/// the tool that fixes it (assign / duplicate a typical floor's plan) lives on
/// the Building page they were never sent to. When the import came from that
/// forced template flow ([fromTemplate]) and the building has MORE floors than
/// the project now has plans, the confirmation names the shortfall and points
/// at the Building page. Every other import keeps its plain count — a normal
/// Import into a tall building is a deliberate one-plan-at-a-time workflow, not
/// a shortfall to nag about.
String _importStatusMessage(
  WidgetRef ref, {
  required int imported,
  required int totalSheets,
  required bool fromTemplate,
  required bool added,
}) =>
    importStatusMessage(
      MechXStringsData(ref.read(localeProvider)),
      imported: imported,
      totalSheets: totalSheets,
      floors: ref.read(projectControllerProvider).floors.length,
      fromTemplate: fromTemplate,
      added: added,
    );

/// The pure text of [_importStatusMessage] — same rule, no providers, so the
/// F10 shortfall branch is unit-testable without an OS file picker.
String importStatusMessage(
  MechXStringsData strings, {
  required int imported,
  required int totalSheets,
  required int floors,
  required bool fromTemplate,
  required bool added,
}) {
  if (fromTemplate && floors > totalSheets) {
    final plans = pluralCount(totalSheets, strings(StringKey.buildingPlanOne),
        strings(StringKey.buildingPlanMany));
    return strings.format(StringKey.templatePlanShortfallTemplate,
        {'floors': '$floors', 'plans': plans});
  }
  final noun = imported == 1 ? 'sheet' : 'sheets';
  return '$imported $noun ${added ? 'added' : 'imported'}';
}

/// Import ONE plan file at [path] to its [Sheet]s (PDF → a sheet per page, DXF
/// one sheet, DWG one sheet via the ODA converter). Shared by the batch add.
Future<List<Sheet>> _importPlanFile(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.dwg')) {
    return importDwg(path,
        converter: const OdaDwgConverter(), outDir: dwgCacheDir());
  }
  if (lower.endsWith('.dxf')) return importDxf(path);
  return importPdf(path);
}

/// A6: APPEND MULTIPLE plan files (PDF / DXF / DWG) to the current project in one
/// action. Where [importPlan] is single-file with an Add-vs-Replace choice, this
/// is purpose-built for the common Indonesian workflow of one plan file per floor
/// — pick many files at once and append every resulting sheet (fresh unique id
/// via [SheetsController.addSheets]). Destroys nothing (existing sheets,
/// calibration and network stay untouched), so no dirty-guard.
///
/// A multi-page PDF contributes all its pages (Remove unwanted ones from the
/// sheet rail); a file that fails to import is skipped and named, and a partial
/// batch still appends whatever parsed rather than aborting the lot.
Future<void> addSheetsFromFiles(BuildContext context, WidgetRef ref) async {
  final paths = await pickOpenPaths(ref,
      allowedExtensions: const ['pdf', 'dxf', 'dwg'], allowMultiple: true);
  if (paths.isEmpty) return;

  ref.read(busyProvider.notifier).set(
      MechXStringsData(ref.read(localeProvider))(StringKey.busyImportingPlan));
  final imported = <Sheet>[];
  final failures = <String>[];
  try {
    for (final path in paths) {
      try {
        final sheets = await _importPlanFile(path);
        if (sheets.isEmpty) {
          failures.add(_baseName(path));
        } else {
          imported.addAll(sheets);
        }
      } catch (_) {
        // One bad file must not abort the batch — skip it and carry on.
        failures.add(_baseName(path));
      }
    }
  } finally {
    ref.read(busyProvider.notifier).clear();
  }

  if (imported.isEmpty) {
    ref.read(loadErrorProvider.notifier).set(
        'Could not add any sheets — no importable geometry in the selected '
        'file${paths.length == 1 ? '' : 's'}.');
    return;
  }
  final added = ref.read(sheetsControllerProvider.notifier).addSheets(imported);
  if (failures.isEmpty) {
    ref.read(loadErrorProvider.notifier).clear();
  } else {
    // Partial success: surface what was skipped, but keep what landed.
    ref.read(loadErrorProvider.notifier).set(
        'Added $added ${added == 1 ? 'sheet' : 'sheets'}; skipped '
        '${failures.length} (${failures.join(', ')}).');
  }
  ref
      .read(statusMessageProvider.notifier)
      .showStatus('$added ${added == 1 ? 'sheet' : 'sheets'} added');
}

/// Revise a SINGLE sheet's plan IN PLACE (A5): pick a new PDF/DXF/DWG and swap
/// [sheetId]'s source for it, KEEPING the sheet id — so its calibration and the
/// drawn nodes that reference the id survive (the real plan-revision workflow,
/// surfaced from the sheet rail's context menu). A multi-page PDF contributes
/// its first page. No dirty-guard: nothing is destroyed (the id, calibration and
/// network are preserved); only the underlay changes.
Future<void> replaceSheetPlan(
    BuildContext context, WidgetRef ref, String sheetId) async {
  final picked =
      await pickOpenPaths(ref, allowedExtensions: const ['pdf', 'dxf', 'dwg']);
  if (picked.isEmpty) return;
  final path = picked.first;

  final lower = path.toLowerCase();
  final isDxf = lower.endsWith('.dxf');
  final isDwg = lower.endsWith('.dwg');
  final what = isDwg
      ? 'DWG'
      : isDxf
          ? 'DXF'
          : 'PDF';
  ref.read(busyProvider.notifier).set(MechXStringsData(ref.read(localeProvider))(
      isDwg ? StringKey.busyConvertingDwg : StringKey.busyImportingPlan));
  try {
    final sheets = isDwg
        ? await importDwg(path,
            converter: const OdaDwgConverter(), outDir: dwgCacheDir())
        : isDxf
            ? await importDxf(path)
            : await importPdf(path);
    if (sheets.isEmpty) {
      ref
          .read(loadErrorProvider.notifier)
          .set('That $what had no importable geometry.');
      return;
    }
    ref
        .read(sheetsControllerProvider.notifier)
        .replaceSheetSource(sheetId, sheets.first);
    ref.read(loadErrorProvider.notifier).clear();
    ref.read(statusMessageProvider.notifier).showStatus('Plan replaced');
  } catch (e) {
    // I5 — the same human mapping as Import (this is the identical parse path).
    ref.read(loadErrorProvider.notifier).set(importFailureMessage(
        MechXStringsData(ref.read(localeProvider)),
        what: what,
        error: e));
  } finally {
    ref.read(busyProvider.notifier).clear();
  }
}

/// The default project name a virgin project carries — the ONE string F9's
/// adoption guard compares against (a project the engineer has named, or one
/// loaded from a file, is never renamed by a save).
const String kDefaultProjectName = 'Untitled project';

/// F9 — the file STEM of a `.mechx` path (`…/Gedung-BRI.mechx` → `Gedung-BRI`),
/// tolerant of either path separator (a FilePicker path may use `/` even on
/// Windows). Pure, so the naming rule is unit-testable without touching disk.
String projectNameFromPath(String path) {
  final base = _baseName(path);
  final lower = base.toLowerCase();
  final stem = lower.endsWith('.mechx')
      ? base.substring(0, base.length - '.mechx'.length)
      : base;
  return stem.trim();
}

/// F9 — adopt [path]'s file stem as the project name when the project still
/// carries the untouched default. A no-op otherwise (a named project keeps its
/// name) and for a stem that is empty or already the live name, so a repeat save
/// records no undo step. Goes through [ProjectController.setName], so the
/// adoption is ONE ordinary undo entry — part of the save the engineer just
/// performed.
void adoptFileStemAsProjectName(ProviderReader read, String path) {
  if (read(projectControllerProvider).name != kDefaultProjectName) return;
  final stem = projectNameFromPath(path);
  if (stem.isEmpty || stem == kDefaultProjectName) return;
  read(projectControllerProvider.notifier).setName(stem);
}

/// True while a [saveProject] run (including its OS Save dialog) is in flight —
/// a second Ctrl+S meanwhile is a no-op instead of a concurrent write to the
/// same file (the busy pill already tells the user a save is running).
bool _saveInFlight = false;

/// Save the project. Writes IN PLACE to the remembered file when one exists
/// (the document-app Ctrl+S convention); falls back to the OS Save dialog for
/// a brand-new project. [saveAs] forces the dialog (Ctrl+Shift+S / the
/// palette's explicit Save As). The write is ATOMIC (temp + rename, keeping
/// the displaced previous file as `.bak`) so a crash mid-save can never
/// destroy the only copy.
Future<void> saveProject(WidgetRef ref, {bool saveAs = false}) async {
  if (_saveInFlight) return;
  _saveInFlight = true;
  try {
    await _saveProjectLocked(ref, saveAs: saveAs);
  } finally {
    _saveInFlight = false;
  }
}

Future<void> _saveProjectLocked(WidgetRef ref, {required bool saveAs}) async {
  final project = ref.read(projectControllerProvider);
  // The project's identity BEFORE this save — its recovery slot is cleared too
  // (a Save-As changes the slot; the pre-save snapshot lived under the old one).
  final priorPath = ref.read(currentProjectPathProvider);
  var full = saveAs ? null : ref.read(currentProjectPathProvider);
  if (full == null) {
    // I1 — the same remembered-folder seam every export uses. A Save-As on an
    // already-saved project starts beside the file it came from (the better
    // informed location); a brand-new project falls back to the shared memory.
    final path = await pickExportSave(ref,
        dialogTitle: 'Save iSystem project',
        fileName: '${project.name}.mechx',
        ext: 'mechx',
        initialDirectory: _dirOf(priorPath));
    if (path == null) return;
    full = path;
  }
  // F9 — the file the engineer named IS the project's name: saving as
  // `Gedung-BRI.mechx` used to leave every title block, report head and window
  // title reading "Untitled project", because Save seeded the dialog from the
  // name but never adopted the chosen filename back. Adopt the stem, but ONLY
  // while the name is still the untouched default — a project the engineer
  // named keeps its name whatever the file is called. One undo step (part of
  // the save), and it happens BEFORE the document is built so the name lands in
  // the written file and in the clean baseline.
  adoptFileStemAsProjectName(ref.read, full);
  final doc = buildDocument(ref.read);
  // The path-only encoding is the "clean baseline" the autosave loop compares
  // against (autosave never embeds) — so a just-saved project leaves no phantom
  // recovery. The FILE on disk, however, embeds the source plans so it is
  // portable across machines.
  final baseline = doc.encode();
  // Tell the user we're working: embedding gzips every plan, and even without
  // assets the write touches disk.
  ref
      .read(busyProvider.notifier)
      .set(MechXStringsData(ref.read(localeProvider))(StringKey.busySaving));
  try {
    // Embed the source plans OFF the UI thread (the gzip+base64 of every plan is
    // a real window freeze on a large project) so the app stays responsive.
    final assets = await gatherSheetAssetsAsync(doc.sheets);
    final portable = doc.withSheets(doc.sheets, assets: assets);
    // Atomic: a torn write can only ever hit the `.tmp` file; the previous
    // save survives as the target or its `.bak`.
    await atomicWriteString(full, portable.encode());
  } catch (e) {
    if (ref.context.mounted) {
      ref.read(loadErrorProvider.notifier).set('Could not save project: $e');
    }
    return;
  } finally {
    // The widget can be torn down while the save (asset gzip + atomic write, on
    // a real isolate) is in flight — the app quit through Save-then-exit, or a
    // test completes the instant the file lands. Touching a disposed `ref` then
    // throws, so guard every post-await provider access on the still-live tree.
    if (ref.context.mounted) ref.read(busyProvider.notifier).clear();
  }
  // The work is now safely on disk — record it as the clean baseline, remember
  // the home file for the next quick save, and drop any recovery snapshot.
  // Resetting the autosave mirror means work that turns dirty again AFTER this
  // save (even by undoing to a previously-mirrored state) gets a fresh
  // recovery snapshot on the next tick. If the tree was disposed during the
  // write awaits (quit-during-save), the file is safe — skip the UI bookkeeping.
  if (!ref.context.mounted) return;
  ref.read(lastSavedSignatureProvider.notifier).set(baseline);
  ref.read(autosaveMirrorProvider.notifier).clear();
  ref.read(currentProjectPathProvider.notifier).set(full);
  ref.read(projectDirtyProvider.notifier).set(false);
  // Drop the recovery snapshot for the prior identity, the saved file, and the
  // shared untitled slot (a first save promotes from untitled to a named file).
  await clearRecoverySlots([priorPath, full, null]);
  // `clearRecoverySlots` is an async file op — the tree can be disposed while it
  // is in flight (see the `finally` note). The remaining work is in-memory UI
  // bookkeeping that only matters while the app is alive, so drop it if gone.
  if (!ref.context.mounted) return;
  ref.read(recoveryDocProvider.notifier).clear();
  // Remember this file in the machine-local MRU / last-open list, under the
  // name the project carries NOW (F9 may just have adopted the file stem).
  ref
      .read(appSettingsProvider.notifier)
      .recordRecent(full, ref.read(projectControllerProvider).name);
  ref
      .read(statusMessageProvider.notifier)
      .showStatus('Saved ${full.split(Platform.pathSeparator).last}');
}

/// Open a `.mechx` project, replacing the live state. Guards unsaved work first
/// (Open would otherwise silently discard it AND delete the recovery snapshot),
/// so it needs a [BuildContext] to host the confirm dialog.
Future<void> openProject(BuildContext context, WidgetRef ref) async {
  // Opening REPLACES the whole project — guard before touching anything.
  if (!await confirmDiscardIfDirty(context, ref)) return;
  final picked =
      await pickOpenPaths(ref, allowedExtensions: const ['mechx', 'json']);
  if (picked.isEmpty) return;
  await _applyOpenedFile(ref, picked.first);
}

/// Open a KNOWN `.mechx` path — a recent-projects (MRU) / reopen-last entry, no
/// OS picker. Guards unsaved work first; a moved/deleted file surfaces an error
/// and is pruned from the recent list rather than opening onto nothing.
Future<void> openProjectPath(
    BuildContext context, WidgetRef ref, String path) async {
  if (!await confirmDiscardIfDirty(context, ref)) return;
  if (!await File(path).exists()) {
    ref
        .read(loadErrorProvider.notifier)
        .set('That project is no longer there:\n$path');
    ref.read(appSettingsProvider.notifier).removeRecent(path);
    return;
  }
  await _applyOpenedFile(ref, path);
}

/// M2 (Windows-desktop citizenship): the project file to auto-open from the
/// process command-line [args]. Explorer's double-click / "Open with" verb (and
/// the taskbar jump list) launch the exe with the file path as an argument, and
/// `windows/runner` forwards those to this Dart entrypoint — so a returned path
/// is opened at launch. Returns the FIRST argument naming a `.mechx` file
/// (case-insensitive), skipping empty tokens and switches (a leading `-`); null
/// when none applies.
///
/// PURE — it never touches the filesystem or any provider, so the launch
/// decision is unit-testable in isolation; the caller checks the file exists
/// (and that a crash-recovery snapshot doesn't take precedence) before opening.
/// Single-instance forwarding (handing the path to an ALREADY-running iSystem
/// instead of launching a second one) is deliberately OUT of scope.
String? launchProjectPathFromArgs(List<String> args) {
  for (final a in args) {
    if (a.isEmpty || a.startsWith('-')) continue;
    if (a.toLowerCase().endsWith('.mechx')) return a;
  }
  return null;
}

/// M2: open a `.mechx` handed to the app on the command line (Explorer
/// double-click / "Open with" / jump list), routed through the SAME core loader
/// [_applyOpenedFileWith] that File → Open and the recent-projects list use.
/// Called ONCE from `main` at launch against the root [container], so there is no
/// live dirty project to guard and no [BuildContext] — the caller has already
/// ensured no crash-recovery snapshot is pending (recovery takes precedence). A
/// path that no longer exists is silently ignored (the app just opens its normal
/// empty state) rather than surfacing a launch-time error banner.
Future<void> openProjectAtLaunch(
    ProviderContainer container, String path) async {
  if (!await File(path).exists()) return;
  await _applyOpenedFileWith(container.read, path);
}

/// Load the `.mechx` at [path] into the live state (shared by [openProject],
/// [openProjectPath], and the launch/command-line open): rehydrate embedded
/// plans, reset the clean baseline, drop this project's stale recovery slot, and
/// record it in the machine-local MRU.
Future<void> _applyOpenedFile(WidgetRef ref, String path) =>
    _applyOpenedFileWith(ref.read, path);

/// The loader core, expressed against a [ProviderReader] so it runs identically
/// from a widget ([WidgetRef.read] — Open / recent projects) and from the launch
/// root container ([ProviderContainer.read] — the command-line open).
Future<void> _applyOpenedFileWith(ProviderReader read, String path) async {
  // The project we're leaving — its recovery slot must be cleared too, or a
  // later launch would offer to restore the work we just navigated away from.
  final priorPath = read(currentProjectPathProvider);
  read(busyProvider.notifier).set(
      MechXStringsData(read(localeProvider))(StringKey.busyOpeningProject));
  try {
    final source = await File(path).readAsString();
    // Decode + extract any embedded source plans (gunzip + repoint the sheets
    // so a portable project renders even without the original plan files here)
    // TOGETHER off the UI thread — the exact freeze Save already fixed for its
    // symmetric asset-embedding work (see gatherSheetAssetsAsync).
    final doc = await decodeAndRehydrateAsync(source);
    applyDocument(read, doc);
    // The just-loaded state is the clean baseline; capture its canonical
    // encoding so autosave won't immediately mirror it to recovery.
    read(lastSavedSignatureProvider.notifier)
        .set(buildDocument(read).encode());
    // Fresh baseline ⇒ fresh mirror: any later divergence must re-snapshot.
    read(autosaveMirrorProvider.notifier).clear();
    read(currentProjectPathProvider.notifier).set(path);
    read(projectDirtyProvider.notifier).set(false);
    // Drop any stale crash snapshot for THIS file, the project we left, and
    // the untitled slot.
    await clearRecoverySlots([priorPath, path, null]);
    read(recoveryDocProvider.notifier).clear();
    read(loadErrorProvider.notifier).clear();
    read(appSettingsProvider.notifier)
        .recordRecent(path, read(projectControllerProvider).name);
    read(statusMessageProvider.notifier).showStatus('Project opened');
  } on ProjectDocumentException catch (e) {
    // Malformed/incompatible file — surface why, leave the project untouched.
    read(loadErrorProvider.notifier).set(e.message);
  } catch (e) {
    read(loadErrorProvider.notifier).set('Could not open project: $e');
  } finally {
    read(busyProvider.notifier).clear();
  }
}
