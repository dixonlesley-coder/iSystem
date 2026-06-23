/// PURE update-check logic — no Flutter imports (only `dart:io` exception types,
/// which are framework-free), so every branch is unit-testable under `dart test`
/// / `flutter test` without a network, a window, or a Windows runner.
///
/// Ported from PanelMaker's `updaterErrors.ts` (`isBenignUpdateError`) and the
/// `UpdateStatus` union in `ipc-contract.ts`. The side-effecting parts (HTTP,
/// `Process`, `package_info_plus`) live in `update_service.dart`; this file only
/// compares versions, parses the release feed, and classifies errors.
library;

import 'dart:async' show TimeoutException;
import 'dart:io';

/// Compares two semantic-version strings, returning <0, 0 or >0 like
/// [Comparable.compareTo] (`compareVersions(a, b) < 0` ⇒ a is older than b).
///
/// Minimal semver: compares the dot-separated numeric `major.minor.patch`
/// release core **numerically** (so `0.2.10 > 0.2.7`, which a string compare
/// gets wrong). A leading `v` is tolerated. **Build metadata** (`+...`) is
/// ignored per SemVer §10. A **pre-release** suffix (`-...`) is ignored for the
/// release core but, when the cores tie, a version WITH a pre-release sorts
/// BELOW one without (SemVer §11) so `1.0.0-rc.1 < 1.0.0`.
int compareVersions(String a, String b) {
  final pa = _SemVer.parse(a);
  final pb = _SemVer.parse(b);
  for (var i = 0; i < 3; i++) {
    final cmp = pa.core[i].compareTo(pb.core[i]);
    if (cmp != 0) return cmp;
  }
  // Release cores tie. A pre-release is lower precedence than a normal release.
  if (pa.preRelease == pb.preRelease) return 0;
  if (pa.preRelease == null) return 1; // a is the full release ⇒ newer
  if (pb.preRelease == null) return -1; // b is the full release ⇒ newer
  // Both pre-release: a lexical compare is good enough for our needs.
  return pa.preRelease!.compareTo(pb.preRelease!);
}

class _SemVer {
  final List<int> core; // exactly 3 entries: major, minor, patch
  final String? preRelease;
  const _SemVer(this.core, this.preRelease);

  static _SemVer parse(String raw) {
    var s = raw.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    // Strip build metadata (everything after the first '+').
    final plus = s.indexOf('+');
    if (plus >= 0) s = s.substring(0, plus);
    // Split off the pre-release (everything after the first '-').
    String? pre;
    final dash = s.indexOf('-');
    if (dash >= 0) {
      pre = s.substring(dash + 1);
      s = s.substring(0, dash);
    }
    final parts = s.split('.');
    final core = <int>[0, 0, 0];
    for (var i = 0; i < 3; i++) {
      if (i < parts.length) {
        core[i] = int.tryParse(parts[i].trim()) ?? 0;
      }
    }
    return _SemVer(core, pre);
  }
}

/// A parsed entry from the auto-update feed (`latest.json` or a GitHub Releases
/// API object). Immutable, no Flutter deps.
class LatestRelease {
  /// The release version, e.g. `1.2.0` (the leading `v` is stripped on parse).
  final String version;

  /// Direct download URL of the Windows installer `.exe`.
  final String url;

  /// Lower-case hex SHA-256 of the installer, used to verify the download
  /// before launching it. May be empty when the feed omits it.
  final String sha256;

  /// Optional human-readable release notes.
  final String notes;

  const LatestRelease({
    required this.version,
    required this.url,
    this.sha256 = '',
    this.notes = '',
  });

  @override
  String toString() => 'LatestRelease($version, $url)';
}

/// Parses our own `latest.json` shape (`{version,url,sha256,notes}`, written by
/// the release workflow). Returns `null` when the required `version`/`url` are
/// missing or not strings, so callers can treat a malformed feed as "no update"
/// rather than crashing. Tolerant of a leading `v` and of absent sha256/notes.
LatestRelease? parseLatest(Map<String, dynamic> json) {
  final rawVersion = json['version'];
  final rawUrl = json['url'];
  if (rawVersion is! String || rawVersion.trim().isEmpty) return null;
  if (rawUrl is! String || rawUrl.trim().isEmpty) return null;

  var version = rawVersion.trim();
  if (version.startsWith('v') || version.startsWith('V')) {
    version = version.substring(1);
  }
  final sha = json['sha256'];
  final notes = json['notes'];
  return LatestRelease(
    version: version,
    url: rawUrl.trim(),
    sha256: sha is String ? sha.trim().toLowerCase() : '',
    notes: notes is String ? notes : '',
  );
}

/// True for routine update-check failures that are NOT worth alarming the user
/// with a red error: no release/feed published yet (a 404 / "not found"), or the
/// machine is simply offline (DNS / connection failures, timeouts). These are
/// the expected state before a release exists or when working offline, so the UI
/// stays quiet (reported as "up to date") instead of surfacing a stack trace.
///
/// Ported from PanelMaker's `isBenignUpdateError`, but classifies Dart's typed
/// I/O exceptions (`SocketException`, `TimeoutException`, `HttpException`) as
/// well as message substrings.
bool isBenignUpdateError(Object error) {
  // Offline / DNS / connection-reset all surface as a SocketException in Dart.
  if (error is SocketException) return true;
  // A slow or unreachable host trips our request timeout.
  if (error is TimeoutException) return true;
  // dart:io's HttpException covers malformed/aborted HTTP responses.
  if (error is HttpException) return true;

  final m = error.toString().toLowerCase();
  return m.contains('socketexception') ||
      m.contains('timeoutexception') ||
      m.contains('timed out') ||
      m.contains('404') ||
      m.contains('not found') ||
      m.contains('no published versions') ||
      m.contains('unable to find latest version') ||
      m.contains('failed host lookup') ||
      m.contains('handshakeexception') ||
      m.contains('enotfound') ||
      m.contains('etimedout') ||
      m.contains('eai_again') ||
      m.contains('econnrefused') ||
      m.contains('econnreset') ||
      m.contains('connection closed') ||
      m.contains('connection refused') ||
      m.contains('connection reset') ||
      m.contains('network is unreachable') ||
      m.contains('getaddrinfo');
}

/// The state machine the UI renders. Mirrors PanelMaker's `UpdateStatus` union:
/// idle / checking / available / downloading / downloaded / upToDate / error /
/// disabled. A `sealed` class makes the renderer's switch exhaustive.
sealed class UpdateStatus {
  const UpdateStatus();
}

/// No check has run yet (the initial state).
class UpdateIdle extends UpdateStatus {
  const UpdateIdle();
}

/// A check is in flight.
class UpdateChecking extends UpdateStatus {
  const UpdateChecking();
}

/// A newer release exists (not yet downloading).
class UpdateAvailable extends UpdateStatus {
  final String version;
  const UpdateAvailable(this.version);
}

/// The installer is downloading; [percent] is 0–100.
class UpdateDownloading extends UpdateStatus {
  final int percent;
  const UpdateDownloading(this.percent);
}

/// The installer finished downloading to [path] and is ready to launch.
class UpdateDownloaded extends UpdateStatus {
  final String version;
  final String path;
  const UpdateDownloaded(this.version, this.path);
}

/// The installed version is the latest (also the benign "offline / no feed yet"
/// resting state — never an alarming error).
class UpdateUpToDate extends UpdateStatus {
  const UpdateUpToDate();
}

/// A genuine, non-benign failure worth showing the user.
class UpdateError extends UpdateStatus {
  final String message;
  const UpdateError(this.message);
}

/// Auto-update is off (a non-release / debug build, where checks are disabled).
class UpdateDisabled extends UpdateStatus {
  final String reason;
  const UpdateDisabled(this.reason);
}
