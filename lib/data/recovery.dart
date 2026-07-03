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

/// Atomically replace the file at [path] with [contents]: write to `path.tmp`
/// (flushed), displace any existing target to `path.bak`, then rename the temp
/// into place. A crash mid-write can therefore tear only the `.tmp` file —
/// the previous good copy survives as either the target itself or its `.bak`
/// (which doubles as a backup of the last write). The displace-first order is
/// deliberate: Windows cannot rename over an existing file, so the target must
/// move aside before `tmp → target`.
Future<void> atomicWriteString(String path, String contents) async {
  final tmp = File('$path.tmp');
  await tmp.writeAsString(contents, flush: true);
  final target = File(path);
  final bak = File('$path.bak');
  final displaced = await target.exists();
  if (displaced) {
    if (await bak.exists()) await bak.delete();
    await target.rename('$path.bak');
  }
  try {
    await tmp.rename(path);
  } catch (e) {
    // The rename-into-place failed (disk full / permission) AFTER the original
    // was displaced to `.bak` — restore it so the file is never left missing,
    // then rethrow so the caller surfaces the failure. If the process instead
    // DIES in this window, the good copy still sits in `.bak`, which
    // [readRecoveryStatus] and the open path fall back to.
    if (displaced && !await target.exists() && await bak.exists()) {
      await bak.rename(path);
    }
    rethrow;
  }
}

/// Write [doc] to the recovery file (best effort; IO errors are swallowed so a
/// transient disk issue never interrupts editing). Atomic (temp + rename), so
/// a crash DURING an autosave tick can never tear the only snapshot.
Future<void> writeRecovery(ProjectDocument doc, {String? path}) async {
  try {
    await atomicWriteString(path ?? recoveryFilePath(), doc.encode());
  } catch (_) {
    // best effort — autosave must never throw into the UI.
  }
}

/// The launch-time state of the recovery snapshot. `unreadable` means a file
/// EXISTS but could not be decoded (torn by an interrupted write / corrupt) —
/// deliberately distinct from `absent` (a clean exit), so the shell can say
/// "a snapshot exists but can't be restored" instead of silently showing
/// nothing.
enum RecoveryReadStatus { absent, ok, unreadable }

/// [readRecoveryStatus]'s result: the status plus the decoded document (only
/// non-null when the status is [RecoveryReadStatus.ok]).
typedef RecoveryRead = ({RecoveryReadStatus status, ProjectDocument? doc});

/// Read the recovery snapshot, distinguishing "no file" (clean previous exit)
/// from "file present but unreadable" (torn snapshot — must be SURFACED, never
/// silently swallowed as if the last session exited cleanly).
///
/// Falls back to `<path>.bak` when the primary is absent or torn: a crash in
/// the atomic writer's narrow displace→rename window leaves the last good copy
/// there, so the guarantee the writer advertises is actually delivered. A
/// readable `.bak` beats reporting nothing / unreadable.
Future<RecoveryRead> readRecoveryStatus({String? path}) async {
  final base = path ?? recoveryFilePath();
  final primary = await _tryReadSnapshot(base);
  if (primary.status == RecoveryReadStatus.ok) return primary;
  final backup = await _tryReadSnapshot('$base.bak');
  if (backup.status == RecoveryReadStatus.ok) return backup;
  // No usable backup: report the primary's own status (unreadable outranks
  // absent, so a torn primary is still surfaced rather than hidden).
  return primary;
}

/// Read + decode ONE snapshot file into an [absent]/[ok]/[unreadable] result.
Future<RecoveryRead> _tryReadSnapshot(String path) async {
  final file = File(path);
  try {
    if (!await file.exists()) {
      return (status: RecoveryReadStatus.absent, doc: null);
    }
  } catch (_) {
    // Can't even stat the location — treat as absent (nothing to offer).
    return (status: RecoveryReadStatus.absent, doc: null);
  }
  try {
    return (
      status: RecoveryReadStatus.ok,
      doc: ProjectDocument.decode(await file.readAsString()),
    );
  } catch (_) {
    return (status: RecoveryReadStatus.unreadable, doc: null);
  }
}

/// Read the recovery snapshot, or null if absent / unreadable. Callers that
/// need to tell those two states apart use [readRecoveryStatus].
Future<ProjectDocument?> readRecovery({String? path}) async =>
    (await readRecoveryStatus(path: path)).doc;

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

/// Delete the recovery snapshot (after an explicit Save, restore, or dismiss),
/// including any `.bak`/`.tmp` siblings the atomic writer left behind.
Future<void> clearRecovery({String? path}) async {
  final base = path ?? recoveryFilePath();
  for (final p in [base, '$base.bak', '$base.tmp']) {
    try {
      final file = File(p);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // best effort
    }
  }
}
