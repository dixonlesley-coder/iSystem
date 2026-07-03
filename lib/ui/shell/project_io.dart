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
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import '../sheets/pdf_page_picker.dart';
import '../strings/app_strings.dart';
import 'confirm_discard_dialog.dart';
import 'import_choice_dialog.dart';

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

/// Pick and import a PDF / DXF / DWG floor plan into the sheet rail. Into an
/// EMPTY project the import just loads (today's behaviour). Into a NON-EMPTY
/// project it offers Add-to-project vs Replace-all (A5): ADD appends the new
/// sheets (nothing is destroyed, so no dirty-guard); REPLACE swaps every sheet
/// (guarded like today) and then PRUNES the network of nodes left orphaned on
/// the old sheets — so phantom pipes can't invisibly pad the BOM.
Future<void> importPlan(BuildContext context, WidgetRef ref) async {
  final startedNonEmpty =
      ref.read(sheetsControllerProvider).sheets.isNotEmpty;
  // Into an EMPTY project, Import loads straight through — guard any unsaved
  // work up front (today's behaviour). A NON-EMPTY project decides
  // Add-vs-Replace AFTER the file is chosen; only the Replace branch destroys
  // anything, so its guard runs there.
  if (!startedNonEmpty) {
    if (!await confirmDiscardIfDirty(context, ref)) return;
  }
  if (!context.mounted) return;
  final result = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['pdf', 'dxf', 'dwg'],
    allowMultiple: false,
  );
  if (result == null || result.files.isEmpty) return;
  final path = result.files.single.path;
  if (path == null || path.isEmpty) return;

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
      return;
    }
    // Multi-page PDF: let the user pick which pages to bring in (single-page
    // documents — and every DXF, which is one sheet — import straight through).
    if (sheets.length > 1 && context.mounted) {
      final chosen = await showPdfPagePicker(context, sheets);
      if (chosen == null) return; // cancelled — keep the current project
      if (chosen.isEmpty) return;
      sheets = chosen;
    }

    // Into a NON-EMPTY project, ask whether to ADD or REPLACE.
    if (startedNonEmpty) {
      if (!context.mounted) return;
      final existing = ref.read(sheetsControllerProvider).sheets.length;
      final choice = await showImportChoiceDialog(
        context,
        existingSheets: existing,
        incomingSheets: sheets.length,
      );
      if (choice == null) return; // cancelled — keep the current project
      if (choice == ImportChoice.add) {
        // ADD destroys nothing (current sheets, calibration and network stay),
        // so no dirty-guard: append the new sheets and stop. Sheet ids are
        // filename-derived (`stem#i`), so a re-import of the same/basename-
        // sharing file would collide with a live id (sharing its calibration +
        // floor mapping and confusing node references). Remap incoming ids to
        // fresh unique ones first — safe, since no node references them yet.
        final sheetsCtrl = ref.read(sheetsControllerProvider.notifier);
        final used =
            ref.read(sheetsControllerProvider).sheets.map((s) => s.id).toSet();
        for (final s in sheets) {
          var id = s.id;
          var n = 1;
          while (used.contains(id)) {
            id = '${s.id}-$n';
            n++;
          }
          used.add(id);
          sheetsCtrl.addSheet(id == s.id ? s : s.copyWith(id: id));
        }
        ref.read(loadErrorProvider.notifier).clear();
        final n = sheets.length;
        ref
            .read(statusMessageProvider.notifier)
            .showStatus('$n ${n == 1 ? 'sheet' : 'sheets'} added');
        return;
      }
      // REPLACE destroys the current sheets + orphans drawn work — guard now.
      if (!context.mounted) return;
      if (!await confirmDiscardIfDirty(context, ref)) return;
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
    final n = sheets.length;
    ref
        .read(statusMessageProvider.notifier)
        .showStatus('$n ${n == 1 ? 'sheet' : 'sheets'} imported');
  } catch (e) {
    // Surface the failure instead of silently keeping the old sheets.
    ref.read(loadErrorProvider.notifier).set('Could not import $what: $e');
  } finally {
    ref.read(busyProvider.notifier).clear();
  }
}

/// Revise a SINGLE sheet's plan IN PLACE (A5): pick a new PDF/DXF/DWG and swap
/// [sheetId]'s source for it, KEEPING the sheet id — so its calibration and the
/// drawn nodes that reference the id survive (the real plan-revision workflow,
/// surfaced from the sheet rail's context menu). A multi-page PDF contributes
/// its first page. No dirty-guard: nothing is destroyed (the id, calibration and
/// network are preserved); only the underlay changes.
Future<void> replaceSheetPlan(
    BuildContext context, WidgetRef ref, String sheetId) async {
  final result = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['pdf', 'dxf', 'dwg'],
    allowMultiple: false,
  );
  if (result == null || result.files.isEmpty) return;
  final path = result.files.single.path;
  if (path == null || path.isEmpty) return;

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
    ref.read(loadErrorProvider.notifier).set('Could not replace plan: $e');
  } finally {
    ref.read(busyProvider.notifier).clear();
  }
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
  final doc = buildDocument(ref.read);
  // The project's identity BEFORE this save — its recovery slot is cleared too
  // (a Save-As changes the slot; the pre-save snapshot lived under the old one).
  final priorPath = ref.read(currentProjectPathProvider);
  var full = saveAs ? null : ref.read(currentProjectPathProvider);
  if (full == null) {
    final path = await FilePicker.saveFile(
      dialogTitle: 'Save iSystem project',
      fileName: '${project.name}.mechx',
      type: FileType.custom,
      allowedExtensions: const ['mechx'],
    );
    if (path == null) return;
    full = path.endsWith('.mechx') ? path : '$path.mechx';
  }
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
    ref.read(loadErrorProvider.notifier).set('Could not save project: $e');
    return;
  } finally {
    ref.read(busyProvider.notifier).clear();
  }
  // The work is now safely on disk — record it as the clean baseline, remember
  // the home file for the next quick save, and drop any recovery snapshot.
  // Resetting the autosave mirror means work that turns dirty again AFTER this
  // save (even by undoing to a previously-mirrored state) gets a fresh
  // recovery snapshot on the next tick.
  ref.read(lastSavedSignatureProvider.notifier).set(baseline);
  ref.read(autosaveMirrorProvider.notifier).clear();
  ref.read(currentProjectPathProvider.notifier).set(full);
  ref.read(projectDirtyProvider.notifier).set(false);
  // Drop the recovery snapshot for the prior identity, the saved file, and the
  // shared untitled slot (a first save promotes from untitled to a named file).
  await clearRecoverySlots([priorPath, full, null]);
  ref.read(recoveryDocProvider.notifier).clear();
  // Remember this file in the machine-local MRU / last-open list.
  ref.read(appSettingsProvider.notifier).recordRecent(full, project.name);
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
  final result = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['mechx', 'json'],
    allowMultiple: false,
  );
  final path = result?.files.single.path;
  if (path == null) return;
  await _applyOpenedFile(ref, path);
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

/// Load the `.mechx` at [path] into the live state (shared by [openProject] and
/// [openProjectPath]): rehydrate embedded plans, reset the clean baseline, drop
/// this project's stale recovery slot, and record it in the machine-local MRU.
Future<void> _applyOpenedFile(WidgetRef ref, String path) async {
  // The project we're leaving — its recovery slot must be cleared too, or a
  // later launch would offer to restore the work we just navigated away from.
  final priorPath = ref.read(currentProjectPathProvider);
  ref.read(busyProvider.notifier).set(
      MechXStringsData(ref.read(localeProvider))(StringKey.busyOpeningProject));
  try {
    final doc = ProjectDocument.decode(await File(path).readAsString());
    // Extract any embedded source plans to local files + repoint the sheets,
    // so a portable project renders even without the original plan files here.
    applyDocument(ref.read, rehydrateAssets(doc));
    // The just-loaded state is the clean baseline; capture its canonical
    // encoding so autosave won't immediately mirror it to recovery.
    ref
        .read(lastSavedSignatureProvider.notifier)
        .set(buildDocument(ref.read).encode());
    // Fresh baseline ⇒ fresh mirror: any later divergence must re-snapshot.
    ref.read(autosaveMirrorProvider.notifier).clear();
    ref.read(currentProjectPathProvider.notifier).set(path);
    ref.read(projectDirtyProvider.notifier).set(false);
    // Drop any stale crash snapshot for THIS file, the project we left, and
    // the untitled slot.
    await clearRecoverySlots([priorPath, path, null]);
    ref.read(recoveryDocProvider.notifier).clear();
    ref.read(loadErrorProvider.notifier).clear();
    ref
        .read(appSettingsProvider.notifier)
        .recordRecent(path, ref.read(projectControllerProvider).name);
    ref.read(statusMessageProvider.notifier).showStatus('Project opened');
  } on ProjectDocumentException catch (e) {
    // Malformed/incompatible file — surface why, leave the project untouched.
    ref.read(loadErrorProvider.notifier).set(e.message);
  } catch (e) {
    ref.read(loadErrorProvider.notifier).set('Could not open project: $e');
  } finally {
    ref.read(busyProvider.notifier).clear();
  }
}
