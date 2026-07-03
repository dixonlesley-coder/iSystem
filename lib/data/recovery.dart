import 'dart:io';

import 'project_document.dart';

/// The per-user app-support base directory for iSystem — the OFFLINE,
/// plugin-free home for machine-local state (app settings + crash-recovery
/// snapshots). On Windows this is `%APPDATA%\iSystem`; elsewhere (and in a
/// bare test/dev env with no `APPDATA`) it falls back to `<systemTemp>/iSystem`.
/// A pure path computation — the directory is created lazily by the writers
/// ([atomicWriteString] makes the parent), never here.
String appSupportDir() {
  final appData = Platform.environment['APPDATA'];
  final base = (appData != null && appData.isNotEmpty)
      ? appData
      : Directory.systemTemp.path;
  return '$base${Platform.pathSeparator}iSystem';
}

/// The directory holding the per-project crash-recovery snapshots (under the
/// app-support dir, no longer the shared global `%TEMP%` slot).
String recoveryDir() => '${appSupportDir()}${Platform.pathSeparator}recovery';

/// A stable (deterministic across launches) 32-bit FNV-1a hash of [s] as
/// zero-padded hex — used to key a project's recovery slot by its file path.
/// Deliberately NOT `String.hashCode` (which is not guaranteed stable across
/// runs), so the slot for a given project file is the same next launch.
String _stableHash(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

/// The recovery snapshot file for the project currently open at [projectPath]:
/// a hash of the path keys a per-project slot, and a null/empty path uses the
/// single shared `untitled` slot (a never-saved project). Each project therefore
/// gets its OWN snapshot instead of every instance clobbering one global file.
String recoverySlotFor(String? projectPath) {
  final key = (projectPath == null || projectPath.isEmpty)
      ? 'untitled'
      : _stableHash(projectPath);
  return '${recoveryDir()}${Platform.pathSeparator}$key.mechx';
}

/// Crash-recovery snapshot file for the CURRENT (untitled) project. The autosave
/// loop writes the current project to a per-project slot ([recoverySlotFor])
/// periodically; on launch, the most-recent snapshot is offered for recovery.
///
/// Kept for the few callers that want a stable default (e.g. the updater's
/// pre-exit backstop): now the app-support `untitled` slot, not `%TEMP%`.
String recoveryFilePath() => recoverySlotFor(null);

/// Atomically replace the file at [path] with [contents]: write to `path.tmp`
/// (flushed), displace any existing target to `path.bak`, then rename the temp
/// into place. A crash mid-write can therefore tear only the `.tmp` file —
/// the previous good copy survives as either the target itself or its `.bak`
/// (which doubles as a backup of the last write). The displace-first order is
/// deliberate: Windows cannot rename over an existing file, so the target must
/// move aside before `tmp → target`.
Future<void> atomicWriteString(String path, String contents) async {
  // Ensure the destination directory exists (the app-support recovery dir may
  // be created on first write); a no-op when it already does.
  await File(path).parent.create(recursive: true);
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
///
/// [sourcePath] (when the project has a home `.mechx` file) is stored in a
/// `<path>.src` sidecar so a Restore can re-link the file identity — the next
/// Ctrl+S saves back to the right file instead of forking a Save-As copy. A
/// null/empty source clears any stale sidecar (an untitled project).
Future<void> writeRecovery(ProjectDocument doc,
    {String? path, String? sourcePath}) async {
  final p = path ?? recoveryFilePath();
  try {
    await atomicWriteString(p, doc.encode());
    final src = File('$p.src');
    if (sourcePath != null && sourcePath.isNotEmpty) {
      await src.writeAsString(sourcePath, flush: true);
    } else if (await src.exists()) {
      await src.delete();
    }
  } catch (_) {
    // best effort — autosave must never throw into the UI.
  }
}

/// The source `.mechx` path a snapshot at [path] belongs to (from its `.src`
/// sidecar), or null when it was an untitled project / the sidecar is absent.
Future<String?> readRecoverySource(String path) async {
  try {
    final f = File('$path.src');
    if (!await f.exists()) return null;
    final s = (await f.readAsString()).trim();
    return s.isEmpty ? null : s;
  } catch (_) {
    return null;
  }
}

/// The most-recently-written recovery snapshot across all per-project slots in
/// [dir] (the app-support recovery dir by default), or null when none exists.
/// Only primary `.mechx` files are considered — the `.bak`/`.tmp`/`.src`
/// siblings are skipped. Never throws (a missing/unreadable dir ⇒ null).
Future<String?> findLatestRecovery({String? dir}) async {
  try {
    final d = Directory(dir ?? recoveryDir());
    if (!await d.exists()) return null;
    String? best;
    DateTime? bestAt;
    await for (final e in d.list(followLinks: false)) {
      if (e is! File || !e.path.endsWith('.mechx')) continue;
      final at = (await e.stat()).modified;
      if (bestAt == null || at.isAfter(bestAt)) {
        best = e.path;
        bestAt = at;
      }
    }
    return best;
  } catch (_) {
    return null;
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
/// including any `.bak`/`.tmp`/`.src` siblings the atomic writer left behind.
Future<void> clearRecovery({String? path}) async {
  final base = path ?? recoveryFilePath();
  for (final p in [base, '$base.bak', '$base.tmp', '$base.src']) {
    try {
      final file = File(p);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // best effort
    }
  }
}

/// Clear the recovery slots for a set of [projectPaths] (each mapped to its
/// per-project [recoverySlotFor] slot, deduplicated). Used by Save/Open, which
/// may need to drop the snapshot for the prior identity, the new file, and the
/// shared `untitled` slot in one go.
Future<void> clearRecoverySlots(Iterable<String?> projectPaths) async {
  final done = <String>{};
  for (final p in projectPaths) {
    final slot = recoverySlotFor(p);
    if (done.add(slot)) await clearRecovery(path: slot);
  }
}
