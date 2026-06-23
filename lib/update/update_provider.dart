/// Riverpod wiring for the auto-updater. Holds the [UpdateStatus] the banner
/// renders, runs an initial check on first read + a 6-hourly poll, and drives
/// the download/install when the user accepts. Disabled (and silent) outside a
/// release build, so dev / CI / tests never reach the network.
///
/// Mirrors PanelMaker's `src/main/updater.ts` lifecycle (launch check + 6 h
/// interval, autoDownload, "Restart & update" → quitAndInstall) but in-process.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'update_check.dart';
import 'update_service.dart';

/// Poll the feed every 6 hours (same cadence as electron-updater's default).
const Duration kUpdatePollInterval = Duration(hours: 6);

/// Overridable backend seam — tests inject a fake; the app uses HTTP. Kept as a
/// provider so `UpdateController` reads it rather than constructing one, which
/// makes the whole controller testable without the network.
final updateBackendProvider = Provider<UpdateBackend>(
  (ref) => HttpUpdateBackend(),
);

/// Whether the updater is live in this build. Overridable in tests so the
/// state-machine transitions can be exercised; defaults to release-only.
final updateEnabledProvider = Provider<bool>((ref) => autoUpdateEnabled);

final updateControllerProvider =
    NotifierProvider<UpdateController, UpdateStatus>(UpdateController.new);

class UpdateController extends Notifier<UpdateStatus> {
  Timer? _timer;
  LatestRelease? _pendingRelease;
  UpdateRunner? _runner;

  UpdateRunner get _resolvedRunner => _runner ??= UpdateRunner(
        ref.read(updateBackendProvider),
        enabled: ref.read(updateEnabledProvider),
      );

  @override
  UpdateStatus build() {
    final enabled = ref.read(updateEnabledProvider);
    if (!enabled) {
      // Don't schedule any timer or network call in a disabled build.
      return const UpdateDisabled('Auto-update runs in the installed app.');
    }

    // Initial check shortly after launch, then poll every 6 h. Fire-and-forget;
    // all failures are handled inside checkForUpdates (benign → upToDate).
    Future.microtask(checkForUpdates);
    _timer = Timer.periodic(kUpdatePollInterval, (_) => checkForUpdates());
    ref.onDispose(() => _timer?.cancel());
    return const UpdateIdle();
  }

  /// Manual or scheduled check. Auto-downloads in the background when an update
  /// is found (electron-updater's `autoDownload = true`), so the banner can
  /// offer "Restart & update" without a second user gesture.
  Future<void> checkForUpdates() async {
    final latest = await _resolvedRunner.check(_emit);
    if (latest != null) {
      // Stash the release the check found and start downloading immediately.
      _pendingRelease = latest;
      await _resolvedRunner.download(latest, _emit);
    }
  }

  /// Launches the downloaded installer ("Restart & update"). No-op unless an
  /// installer has actually been downloaded for this session.
  Future<void> installUpdate() async {
    final s = state;
    if (s is! UpdateDownloaded) return;
    await _resolvedRunner.backend.launchInstaller(s.path);
  }

  /// The release a check found, if any — exposed so a re-download can be
  /// retried without re-fetching.
  LatestRelease? get pendingRelease => _pendingRelease;

  void _emit(UpdateStatus status) {
    // The controller can be disposed mid-flight (window close); guard the write.
    state = status;
  }
}
