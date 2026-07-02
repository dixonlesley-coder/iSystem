import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/autosave.dart';
import '../../data/dwg_converter.dart';
import '../../data/dwg_import.dart';
import '../../data/dxf_import.dart';
import '../../data/pdf_import.dart';
import '../../data/project_assets.dart';
import '../../data/project_document.dart';
import '../../data/recovery.dart';
import '../../store/app_state.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import '../sheets/pdf_page_picker.dart';
import '../strings/app_strings.dart';
import 'confirm_discard_dialog.dart';

/// Project file I/O shared by the top bar, the global Ctrl/Cmd+S/O hotkeys,
/// the command palette, and the first-launch empty-state actions — lifted out
/// of `_TopBar` so every entry point runs the exact same code.

/// Guard against silently destroying unsaved work: when the live project is
/// dirty, prompt Save / Discard / Cancel before an action that REPLACES it.
/// Returns `true` to PROCEED (clean, discarded, or saved successfully), `false`
/// to ABORT (Cancel/dismiss, or a Save the user backed out of). Uses the
/// FRESH [isProjectDirty] check, not the timer-fed UI hint.
Future<bool> _confirmDiscardIfDirty(BuildContext context, WidgetRef ref) async {
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

/// Pick and import a PDF / DXF / DWG floor plan into the sheet rail.
Future<void> importPlan(BuildContext context, WidgetRef ref) async {
  // Importing REPLACES the current sheets, orphaning drawn nodes — guard first.
  if (!await _confirmDiscardIfDirty(context, ref)) return;
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
    ref.read(sheetsControllerProvider.notifier).loadSheets(sheets);
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

/// Save the project. Writes IN PLACE to the remembered file when one exists
/// (the document-app Ctrl+S convention); falls back to the OS Save dialog for
/// a brand-new project. [saveAs] forces the dialog (Ctrl+Shift+S / the
/// palette's explicit Save As).
Future<void> saveProject(WidgetRef ref, {bool saveAs = false}) async {
  final project = ref.read(projectControllerProvider);
  final doc = buildDocument(ref.read);
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
    await File(full).writeAsString(portable.encode());
  } catch (e) {
    ref.read(loadErrorProvider.notifier).set('Could not save project: $e');
    return;
  } finally {
    ref.read(busyProvider.notifier).clear();
  }
  // The work is now safely on disk — record it as the clean baseline, remember
  // the home file for the next quick save, and drop any recovery snapshot.
  ref.read(lastSavedSignatureProvider.notifier).set(baseline);
  ref.read(currentProjectPathProvider.notifier).set(full);
  ref.read(projectDirtyProvider.notifier).set(false);
  await clearRecovery();
  ref.read(recoveryDocProvider.notifier).clear();
  ref
      .read(statusMessageProvider.notifier)
      .showStatus('Saved ${full.split(Platform.pathSeparator).last}');
}

/// Open a `.mechx` project, replacing the live state. Guards unsaved work first
/// (Open would otherwise silently discard it AND delete the recovery snapshot),
/// so it needs a [BuildContext] to host the confirm dialog.
Future<void> openProject(BuildContext context, WidgetRef ref) async {
  // Opening REPLACES the whole project — guard before touching anything.
  if (!await _confirmDiscardIfDirty(context, ref)) return;
  final result = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['mechx', 'json'],
    allowMultiple: false,
  );
  final path = result?.files.single.path;
  if (path == null) return;
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
    ref.read(currentProjectPathProvider.notifier).set(path);
    ref.read(projectDirtyProvider.notifier).set(false);
    await clearRecovery();
    ref.read(recoveryDocProvider.notifier).clear();
    ref.read(loadErrorProvider.notifier).clear();
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
