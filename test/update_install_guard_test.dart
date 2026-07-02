import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/data/recovery.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/update/update_check.dart';
import 'package:mechx/update/update_provider.dart';
import 'package:mechx/update/update_service.dart';

import 'test_util.dart';

/// Finding B5 — "Restart & update" was the one exit that bypassed the
/// unsaved-work guard: `launchInstaller` exit(0)s without ever triggering
/// `AppLifecycleListener.onExitRequested`. Now (a) the banner runs the same
/// dirty check + Save/Discard/Cancel dialog Open/Import use, and (b)
/// `installUpdate` writes a final recovery snapshot BEFORE launching the
/// installer, whatever the dialog decided.
void main() {
  setUp(() {
    final f = File(recoveryFilePath());
    if (f.existsSync()) f.deleteSync();
  });
  tearDown(() async => clearRecovery());

  test(
      'installUpdate writes a recovery snapshot BEFORE launching the installer',
      () async {
    final backend = _RecordingBackend(
      current: '1.0.0',
      latest: const LatestRelease(version: '1.1.0', url: 'https://x/y.exe'),
    );
    final c = ProviderContainer(overrides: [
      updateEnabledProvider.overrideWithValue(true),
      updateBackendProvider.overrideWithValue(backend),
    ]);
    addTearDown(c.dispose);

    final ctrl = c.read(updateControllerProvider.notifier);
    await ctrl.checkForUpdates(); // fake finds 1.1.0 and "downloads" it
    expect(c.read(updateControllerProvider), isA<UpdateDownloaded>());

    await ctrl.installUpdate();

    expect(backend.launchedPath, isNotNull);
    // The snapshot existed at the moment the installer was launched — nothing
    // past this instant can be lost to the exit(0).
    expect(backend.recoveryExistedAtLaunch, isTrue);
    final snapshot = await readRecovery();
    expect(snapshot, isNotNull);
  });

  testWidgets(
      'Restart & update guards unsaved work: the dialog interposes and Cancel '
      'aborts the install', (tester) async {
    final backend = _RecordingBackend(
      current: '1.0.0',
      latest: const LatestRelease(version: '1.1.0', url: 'https://x/y.exe'),
    );
    setDesktopSurface(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        updateEnabledProvider.overrideWithValue(true),
        updateBackendProvider.overrideWithValue(backend),
      ],
      child: const MechXApp(),
    ));
    // Let the launch check run (microtask) and the banner appear.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Restart & update'), findsOneWidget);

    // Dirty the project — the guard must interpose before the process exits.
    final c = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    final net = c.read(networkControllerProvider.notifier);
    net.setTool(DrawTool.drawRun);
    net.placeRunPoint('s1', 0, const Offset(0, 0));
    net.placeRunPoint('s1', 0, const Offset(100, 0));
    await tester.pump();

    await tester.tap(find.text('Restart & update'));
    await tester.pumpAndSettle();
    expect(find.text('Unsaved changes'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    // Cancel ABORTS: no installer launched, the session lives on.
    expect(backend.launchedPath, isNull);

    // Unmount so the update controller's 6 h poll timer is disposed inside
    // the test body (fake-async zone hygiene).
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a clean project skips the dialog and launches the installer',
      (tester) async {
    final backend = _RecordingBackend(
      current: '1.0.0',
      latest: const LatestRelease(version: '1.1.0', url: 'https://x/y.exe'),
    );
    setDesktopSurface(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        updateEnabledProvider.overrideWithValue(true),
        updateBackendProvider.overrideWithValue(backend),
      ],
      child: const MechXApp(),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Restart & update'), findsOneWidget);

    // A virgin project is NOT dirty — no dialog, straight to the installer
    // (with the recovery snapshot written first). Real file IO — runAsync.
    await tester.runAsync(() async {
      await tester.tap(find.text('Restart & update'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.text('Unsaved changes'), findsNothing);
    expect(backend.launchedPath, isNotNull);
    expect(backend.recoveryExistedAtLaunch, isTrue);

    await tester.pumpWidget(const SizedBox());
  });
}

/// An [UpdateBackend] double that records whether the recovery snapshot
/// already existed when the installer launch was requested (the B5 ordering
/// contract), and never touches the network / Process.
class _RecordingBackend implements UpdateBackend {
  final String current;
  final LatestRelease? latest;
  String? launchedPath;
  bool? recoveryExistedAtLaunch;

  _RecordingBackend({required this.current, required this.latest});

  @override
  Future<String> currentVersion() async => current;

  @override
  Future<LatestRelease?> fetchLatest() async => latest;

  @override
  Future<String> download(
    LatestRelease release, {
    void Function(int percent)? onProgress,
  }) async {
    onProgress?.call(100);
    return '/tmp/fake-setup.exe';
  }

  @override
  Future<void> launchInstaller(String path) async {
    launchedPath = path;
    recoveryExistedAtLaunch = File(recoveryFilePath()).existsSync();
  }
}
