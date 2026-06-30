/// Side-effecting half of the auto-updater: the network GET of the release
/// feed, the version comparison against the running build, the streamed
/// download + SHA-256 verification, and launching the silent installer. All the
/// pure decision logic it relies on lives in `update_check.dart` (so it stays
/// unit-testable); this file is the thin boundary that touches `http`,
/// `package_info_plus`, the filesystem and `Process`.
///
/// Ported from PanelMaker's `src/main/updater.ts` (electron-updater): check on
/// launch + every 6 h, download in the background, never auto-apply — the user
/// clicks "Restart & update" to launch the installer. Benign failures (offline /
/// no feed yet / 404) resolve to [UpdateUpToDate], never an alarming error.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import 'update_check.dart';

/// Default location of the auto-update feed: the `latest.json` asset uploaded by
/// the release workflow to the latest GitHub Release. `…/releases/latest/`
/// 302-redirects to the newest published tag, so this URL always points at the
/// current release's feed without hard-coding a version. Keep the owner/repo in
/// sync with the release workflow (it writes the URL from `GITHUB_REPOSITORY`).
const String kDefaultFeedUrl =
    'https://github.com/dixonlesley-coder/iSystem/releases/latest/download/latest.json';

/// How long to wait on any single network call before treating it as offline.
const Duration kUpdateTimeout = Duration(seconds: 15);

/// The boundary the updater talks to. The default implementation hits the
/// network / filesystem; tests can substitute a fake to drive the controller
/// without any I/O.
abstract class UpdateBackend {
  /// The running app's version (source of truth = pubspec `version`).
  Future<String> currentVersion();

  /// Fetches + parses the release feed, or `null` when the feed is unreachable
  /// / malformed (caller treats that as "no update").
  Future<LatestRelease?> fetchLatest();

  /// Downloads [release]'s installer to a temp file, reporting 0–100 progress,
  /// verifies its SHA-256 (when the feed supplied one), and returns the path.
  Future<String> download(
    LatestRelease release, {
    void Function(int percent)? onProgress,
  });

  /// Launches the downloaded installer silently and asks the app to exit.
  Future<void> launchInstaller(String path);
}

/// Production [UpdateBackend]: real HTTP, filesystem, and `Process`.
class HttpUpdateBackend implements UpdateBackend {
  final String feedUrl;
  final http.Client _client;

  HttpUpdateBackend({this.feedUrl = kDefaultFeedUrl, http.Client? client})
      : _client = client ?? http.Client();

  @override
  Future<String> currentVersion() async {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  }

  @override
  Future<LatestRelease?> fetchLatest() async {
    final resp =
        await _client.get(Uri.parse(feedUrl)).timeout(kUpdateTimeout);
    if (resp.statusCode == 404) {
      // No release published yet — benign, treat as no update.
      return null;
    }
    if (resp.statusCode != 200) {
      throw HttpException('feed returned HTTP ${resp.statusCode}');
    }
    final decoded = jsonDecode(resp.body);
    if (decoded is! Map<String, dynamic>) return null;
    return parseLatest(decoded);
  }

  @override
  Future<String> download(
    LatestRelease release, {
    void Function(int percent)? onProgress,
  }) async {
    final request = http.Request('GET', Uri.parse(release.url));
    final response = await _client.send(request).timeout(kUpdateTimeout);
    if (response.statusCode != 200) {
      throw HttpException('download returned HTTP ${response.statusCode}');
    }

    final dir = await Directory.systemTemp.createTemp('isystem-update');
    final file = File('${dir.path}${Platform.pathSeparator}'
        'iSystem-${release.version}-setup.exe');
    final sink = file.openWrite();

    final total = response.contentLength ?? 0;
    var received = 0;
    var lastPercent = -1;

    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && onProgress != null) {
          final percent = ((received / total) * 100).clamp(0, 100).round();
          if (percent != lastPercent) {
            lastPercent = percent;
            onProgress(percent);
          }
        }
      }
    } finally {
      await sink.close();
    }

    // Verify the download against the feed's hash, when present. A mismatch is a
    // hard error (corrupt / tampered download) — never launch it.
    final expected = release.sha256;
    if (expected.isNotEmpty) {
      final actual = sha256.convert(await file.readAsBytes()).toString();
      if (actual.toLowerCase() != expected.toLowerCase()) {
        await file.delete().catchError((_) => file);
        throw const FormatException(
            'Downloaded installer failed SHA-256 verification.');
      }
    }
    return file.path;
  }

  @override
  Future<void> launchInstaller(String path) async {
    // Inno Setup honours /SILENT (progress bar, no wizard). We exit(0) right
    // after launching so the running exe is unlocked for replacement; the .iss
    // [Run] entry gated on `Check: WizardSilent` then RELAUNCHES iSystem once the
    // silent install finishes (the app auto-restarts itself). Detach so the
    // installer survives our exit.
    await Process.start(
      path,
      const ['/SILENT'],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }
}

/// Orchestrates a single check (and optional install) over an [UpdateBackend],
/// emitting [UpdateStatus] transitions through [onStatus]. Pure of Riverpod so
/// it can be exercised directly in tests; the provider wraps it.
class UpdateRunner {
  final UpdateBackend backend;

  /// When false (a non-release build), checks short-circuit to
  /// [UpdateDisabled] and never touch the network — mirrors electron-updater's
  /// "auto-update runs in the installed app" behaviour.
  final bool enabled;

  const UpdateRunner(this.backend, {this.enabled = true});

  /// Runs one check; benign failures resolve to [UpdateUpToDate]. Emits
  /// intermediate statuses (checking → available/upToDate/error) via [emit].
  /// Returns the available [LatestRelease] (so the caller can download it
  /// without re-fetching) or `null` when up to date / disabled / errored.
  Future<LatestRelease?> check(void Function(UpdateStatus) emit) async {
    if (!enabled) {
      emit(const UpdateDisabled('Auto-update runs in the installed app.'));
      return null;
    }
    emit(const UpdateChecking());
    try {
      final latest = await backend.fetchLatest();
      if (latest == null) {
        emit(const UpdateUpToDate());
        return null;
      }
      final current = await backend.currentVersion();
      if (compareVersions(latest.version, current) > 0) {
        emit(UpdateAvailable(latest.version));
        return latest;
      }
      emit(const UpdateUpToDate());
      return null;
    } catch (e) {
      // No feed / offline reads as "up to date", not a scary error.
      emit(isBenignUpdateError(e)
          ? const UpdateUpToDate()
          : UpdateError('$e'));
      return null;
    }
  }

  /// Downloads the available [release], verifies it, and emits downloading →
  /// downloaded transitions. Benign network failures fall back to
  /// [UpdateUpToDate]; a hash/HTTP failure surfaces as [UpdateError].
  Future<UpdateStatus> download(
    LatestRelease release,
    void Function(UpdateStatus) emit,
  ) async {
    if (!enabled) {
      const status = UpdateDisabled('Auto-update runs in the installed app.');
      emit(status);
      return status;
    }
    emit(const UpdateDownloading(0));
    try {
      final path = await backend.download(
        release,
        onProgress: (p) => emit(UpdateDownloading(p)),
      );
      final status = UpdateDownloaded(release.version, path);
      emit(status);
      return status;
    } catch (e) {
      final status =
          isBenignUpdateError(e) ? const UpdateUpToDate() : UpdateError('$e');
      emit(status);
      return status;
    }
  }
}

/// Whether auto-update should run in this process. Off outside a release build
/// (debug / profile / tests) so dev + CI never hit the network or surface a
/// banner — exactly like PanelMaker reporting `disabled` when not packaged.
bool get autoUpdateEnabled => kReleaseMode;
