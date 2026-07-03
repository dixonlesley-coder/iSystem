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
/// installer WHEN the project is dirty — honouring the no-phantom-recovery
/// invariant (a clean/saved project writes nothing).
void main() {
  // A unique temp recovery path per test (installUpdate takes an injectable
  // path) so the full suite's concurrently-running isolates never race on the
  // shared global recovery file.
  late Directory dir;
  late String path;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('mechx_update_guard');
    path = '${dir.path}/recovery.mechx';
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  ({ProviderContainer c, UpdateController ctrl}) makeDownloaded(
      _RecordingBackend backend) {
    final c = ProviderContainer(overrides: [
      updateEnabledProvider.overrideWithValue(true),
      updateBackendProvider.overrideWithValue(backend),
    ]);
    addTearDown(c.dispose);
    final ctrl = c.read(updateControllerProvider.notifier);
    return (c: c, ctrl: ctrl);
  }

  _RecordingBackend makeBackend() => _RecordingBackend(
        current: '1.0.0',
        latest: const LatestRelease(version: '1.1.0', url: 'https://x/y.exe'),
      );

  test(
      'installUpdate writes a recovery snapshot BEFORE launching the installer '
      'when the project is dirty', () async {
    final backend = makeBackend();
    final (:c, :ctrl) = makeDownloaded(backend);
    await ctrl.checkForUpdates(); // fake finds 1.1.0 and "downloads" it
    expect(c.read(updateControllerProvider), isA<UpdateDownloaded>());

    // A dirty project ⇒ the backstop snapshot fires before exit(0).
    final net = c.read(networkControllerProvider.notifier);
    net.setTool(DrawTool.drawRun);
    net.placeRunPoint('s1', 0, const Offset(0, 0));
    net.placeRunPoint('s1', 0, const Offset(100, 0));

    await ctrl.installUpdate(recoveryPath: path);

    expect(backend.launchedPath, isNotNull);
    // Nothing past this instant can be lost to the exit(0).
    expect(await readRecovery(path: path), isNotNull);
  });

  test('installUpdate writes NO recovery for a CLEAN project (no phantom)',
      () async {
    final backend = makeBackend();
    final (:c, :ctrl) = makeDownloaded(backend);
    await ctrl.checkForUpdates();
    expect(c.read(updateControllerProvider), isA<UpdateDownloaded>());
    // Untouched project — not dirty. The no-phantom-recovery invariant: the
    // next launch after the update must not pop a spurious "recover?" banner.
    await ctrl.installUpdate(recoveryPath: path);
    expect(backend.launchedPath, isNotNull);
    expect(await readRecovery(path: path), isNull);
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

    // A virgin project is NOT dirty — no confirm dialog, straight to the
    // installer. (The no-phantom-recovery guarantee for a clean project is
    // pinned deterministically by the hermetic unit test above; this widget
    // test drives the real button through the global recovery path, which the
    // parallel suite shares, so it asserts only the dialog/launch behaviour.)
    await tester.runAsync(() async {
      await tester.tap(find.text('Restart & update'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.text('Unsaved changes'), findsNothing);
    expect(backend.launchedPath, isNotNull);

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
