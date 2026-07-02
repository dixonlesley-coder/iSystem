import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/data/autosave.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final sans = FontLoader('Roboto')
    ..addFont(bytes('assets/fonts/Roboto-Regular.ttf'))
    ..addFont(bytes('assets/fonts/Roboto-Medium.ttf'));
  await sans.load();
  final mono = FontLoader('Roboto Mono')
    ..addFont(bytes('assets/fonts/RobotoMono-Regular.ttf'));
  await mono.load();
}

const _doc = ProjectDocument(
  projectName: 'Tower B',
  floors: [Floor('G', Length(3.5))],
  calibrations: {'s1': ScaleCalibration(0.02)},
  sheets: [Sheet(id: 's1', name: 'P', sizePx: Size(100, 100))],
  network: Network(
    nodes: [NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0)],
  ),
);

void main() {
  setUpAll(_loadFonts);

  ProviderContainer containerFor(WidgetTester tester) =>
      ProviderScope.containerOf(
        tester.element(find.byType(MechXApp)),
        listen: false,
      );

  testWidgets(
      'banner names the recovered project and gives a relative autosave time '
      '(not the old bare "unsaved work?" prompt)', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final container = containerFor(tester);

    final savedAt = DateTime.now().subtract(const Duration(minutes: 5));
    container
        .read(recoveryDocProvider.notifier)
        .set((doc: _doc, savedAt: savedAt));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('recovery-banner')), findsOneWidget);
    expect(find.textContaining('Tower B'), findsOneWidget);
    expect(find.textContaining('5 min ago'), findsOneWidget);
  });

  testWidgets(
      'an unreadable mtime degrades to a generic "earlier" instead of a bogus time',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final container = containerFor(tester);

    container
        .read(recoveryDocProvider.notifier)
        .set((doc: _doc, savedAt: null));
    await tester.pumpAndSettle();

    expect(find.textContaining('earlier'), findsOneWidget);
  });

  testWidgets(
      'discard is two-step: the first tap only arms confirmation and does NOT '
      'clear the recovery snapshot', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final container = containerFor(tester);

    container
        .read(recoveryDocProvider.notifier)
        .set((doc: _doc, savedAt: null));
    await tester.pumpAndSettle();

    expect(find.text('Discard snapshot'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('recovery-discard')));
    await tester.pump();

    // Still armed, not yet cleared — the snapshot survives the first tap.
    expect(container.read(recoveryDocProvider), isNotNull);
    expect(find.text('Discard - sure?'), findsOneWidget);
    expect(find.byKey(const ValueKey('recovery-banner')), findsOneWidget);
  });

  testWidgets(
      'an unreadable (torn) snapshot is surfaced distinctly: the banner says '
      'it cannot be read and offers no Restore', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final container = containerFor(tester);

    // A null doc = the recovery FILE exists but could not be decoded (torn by
    // an interrupted write) — must never masquerade as a clean exit.
    container
        .read(recoveryDocProvider.notifier)
        .set((doc: null, savedAt: null));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('recovery-banner')), findsOneWidget);
    expect(find.textContaining('could not be read'), findsOneWidget);
    // Nothing restorable — only the (two-step) discard remains.
    expect(find.text('Restore'), findsNothing);
    expect(find.text('Discard snapshot'), findsOneWidget);
  });

  testWidgets('the second, confirming tap clears the recovery snapshot',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final container = containerFor(tester);

    container
        .read(recoveryDocProvider.notifier)
        .set((doc: _doc, savedAt: null));
    await tester.pumpAndSettle();

    // Arm, then confirm. The confirming tap runs real dart:io (clearRecovery),
    // so drive it via runAsync — the fake-async pump zone never resolves a
    // real Future backed by the OS event loop.
    await tester.tap(find.byKey(const ValueKey('recovery-discard')));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('recovery-discard')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(container.read(recoveryDocProvider), isNull);
  });
}
