import 'dart:io';

import 'project_document.dart';

/// Crash-recovery snapshot file. The autosave loop writes the current project
/// here periodically; on launch, if it exists, the previous session ended
/// without a clean exit and the work can be recovered.
///
/// Lives in the OS temp dir so it needs no extra plugin and is naturally
/// scratch storage. (A future build can move it under the app-support dir.)
String recoveryFilePath() =>
    '${Directory.systemTemp.path}/mechx_recovery.mechx';

/// Write [doc] to the recovery file (best effort; IO errors are swallowed so a
/// transient disk issue never interrupts editing).
Future<void> writeRecovery(ProjectDocument doc, {String? path}) async {
  try {
    await File(path ?? recoveryFilePath()).writeAsString(doc.encode());
  } catch (_) {
    // best effort — autosave must never throw into the UI.
  }
}

/// Read the recovery snapshot, or null if absent / unreadable.
Future<ProjectDocument?> readRecovery({String? path}) async {
  final file = File(path ?? recoveryFilePath());
  if (!await file.exists()) return null;
  try {
    return ProjectDocument.decode(await file.readAsString());
  } catch (_) {
    return null;
  }
}

/// Best-effort last-modified time of the recovery snapshot, read alongside
/// [readRecovery] at launch so the UI can tell the engineer *when* the work
/// was autosaved (not just that some work exists). Null when the file is
/// missing or its mtime can't be read — the banner degrades to a generic
/// "earlier" phrasing rather than throwing.
Future<DateTime?> recoverySnapshotMtime({String? path}) async {
  try {
    final file = File(path ?? recoveryFilePath());
    if (!await file.exists()) return null;
    return (await file.stat()).modified;
  } catch (_) {
    return null;
  }
}

/// Delete the recovery snapshot (after an explicit Save, restore, or dismiss).
Future<void> clearRecovery({String? path}) async {
  try {
    final file = File(path ?? recoveryFilePath());
    if (await file.exists()) await file.delete();
  } catch (_) {
    // best effort
  }
}
