// M1 (b): the shell must lay out without RenderFlex overflow at the app's
// native minimum window size (1024x700 logical, enforced by the Windows runner's
// WM_GETMINMAXINFO handler). The prior suite only ever exercised >= 1280x832, so
// nothing verified the fixed-px chrome (nav rail + sheet rail + inspector +
// top/status bars) at the real floor. Pump the whole app at 1024x700 in the
// worst-case surfaces (design workspace, Review, Commercial) and assert no
// overflow exception is thrown.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/shell/nav_rail.dart';

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

/// The Windows runner's minimum logical window size (kMinWindowLogicalWidth x
/// kMinWindowLogicalHeight). Kept in sync with win32_window.cpp by hand.
const Size _kMinWindow = Size(1024, 700);

void main() {
  setUpAll(_loadFonts);

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    setDesktopSurface(tester, size: _kMinWindow);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedDemoSheets(container);
    await tester.pump();
    return container;
  }

  testWidgets('design workspace lays out with no overflow at 1024x700',
      (tester) async {
    final container = await pumpApp(tester);
    // The design workspace (nav rail + sheet rail + canvas + inspector +
    // top/status bars) is on screen by default (ShellSection.design).
    expect(find.byType(NavRail), findsOneWidget);
    expect(container.read(shellSectionProvider), ShellSection.design);
    expect(tester.takeException(), isNull);
  });

  testWidgets('electrical + riser workspaces lay out with no overflow at '
      '1024x700', (tester) async {
    final container = await pumpApp(tester);
    // The electrical + riser (schematic) workspaces have their own top-bar /
    // toolbar chrome — exercise both at the floor.
    container
        .read(workspaceViewProvider.notifier)
        .set(WorkspaceView.electrical);
    await tester.pump();
    expect(tester.takeException(), isNull);
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.schematic);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Review hub lays out with no overflow at 1024x700',
      (tester) async {
    final container = await pumpApp(tester);
    container.read(shellSectionProvider.notifier).set(ShellSection.review);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Commercial hub lays out with no overflow at 1024x700',
      (tester) async {
    final container = await pumpApp(tester);
    container.read(shellSectionProvider.notifier).set(ShellSection.commercial);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
