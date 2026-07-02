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

/// Project file I/O shared by the top bar, the global Ctrl/Cmd+S/O hotkeys,
/// the command palette, and the first-launch empty-state actions — lifted out
/// of `_TopBar` so every entry point runs the exact same code.

/// Pick and import a PDF / DXF / DWG floor plan into the sheet rail.
Future<void> importPlan(BuildContext context, WidgetRef ref) async {
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
  final portable = doc.withSheets(doc.sheets, assets: gatherSheetAssets(doc.sheets));
  try {
    await File(full).writeAsString(portable.encode());
  } catch (e) {
    ref.read(loadErrorProvider.notifier).set('Could not save project: $e');
    return;
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

/// Open a `.mechx` project, replacing the live state.
Future<void> openProject(WidgetRef ref) async {
  final result = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['mechx', 'json'],
    allowMultiple: false,
  );
  final path = result?.files.single.path;
  if (path == null) return;
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
  }
}
