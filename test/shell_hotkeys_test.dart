import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/command_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/shell/nav_rail.dart';

import 'test_util.dart';

/// Finding I1 — the shell hotkeys (Ctrl/Cmd+K / S / Shift+S / O) used to live
/// on a bubble-phase Focus that only ever saw key events when a canvas held
/// focus: on Projects/Review/Commercial/Building/Preferences (and the Riser
/// view) they silently died. They are now registered focus-independently on
/// [HardwareKeyboard], so they work on every screen — and were REMOVED from
/// the bubble listener so one press can never dispatch twice.
Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final sans = FontLoader('Roboto')
    ..addFont(bytes('assets/fonts/Roboto-Regular.ttf'))
    ..addFont(bytes('assets/fonts/Roboto-Medium.ttf'));
  await sans.load();
}

ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );

Future<void> _pressCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  setUpAll(_loadFonts);

  testWidgets(
      'Ctrl+K opens the command palette on the Projects hub, where nothing '
      'holds focus (the empirically-proven dead spot)', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final c = _containerOf(tester);

    c.read(shellSectionProvider.notifier).set(ShellSection.projects);
    await tester.pump();
    expect(c.read(commandPaletteOpenProvider), isFalse);

    await _pressCtrl(tester, LogicalKeyboardKey.keyK);
    expect(c.read(commandPaletteOpenProvider), isTrue);
  });

  testWidgets(
      'Ctrl+K works on every hub screen and the Riser view', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final c = _containerOf(tester);

    for (final section in [
      ShellSection.review,
      ShellSection.commercial,
      ShellSection.building,
      ShellSection.preferences,
    ]) {
      c.read(shellSectionProvider.notifier).set(section);
      await tester.pump();
      await _pressCtrl(tester, LogicalKeyboardKey.keyK); // open
      expect(c.read(commandPaletteOpenProvider), isTrue,
          reason: 'Ctrl+K must open the palette on $section');
      await _pressCtrl(tester, LogicalKeyboardKey.keyK); // close again
      expect(c.read(commandPaletteOpenProvider), isFalse);
    }

    // The Riser (schematic) view inside the design workspace.
    c.read(shellSectionProvider.notifier).set(ShellSection.design);
    c.read(workspaceViewProvider.notifier).set(WorkspaceView.schematic);
    await tester.pump();
    await _pressCtrl(tester, LogicalKeyboardKey.keyK);
    expect(c.read(commandPaletteOpenProvider), isTrue);
  });

  testWidgets(
      'Ctrl+K toggles exactly ONCE per press on the Layout canvas (the combo '
      'was removed from the bubble listener - no double dispatch)',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final c = _containerOf(tester);
    expect(c.read(workspaceViewProvider), WorkspaceView.plan);

    // Were the combo still ALSO handled by the bubble Focus, one press would
    // toggle twice and the palette would never appear open.
    await _pressCtrl(tester, LogicalKeyboardKey.keyK);
    expect(c.read(commandPaletteOpenProvider), isTrue);
    await _pressCtrl(tester, LogicalKeyboardKey.keyK);
    expect(c.read(commandPaletteOpenProvider), isFalse);
  });

  testWidgets('Ctrl+S saves in place from the Projects hub', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final c = _containerOf(tester);

    final dir = Directory.systemTemp.createTempSync('mechx_hotkey_save');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/hotkey.mechx';
    // A remembered home file, so Ctrl+S saves in place (no OS dialog).
    c.read(currentProjectPathProvider.notifier).set(path);

    c.read(shellSectionProvider.notifier).set(ShellSection.projects);
    await tester.pump();

    // The save touches the real filesystem (and Isolate.run) — drive it in
    // the real-async zone and poll for the write to land.
    await tester.runAsync(() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      for (var i = 0; i < 40 && !File(path).existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    expect(File(path).existsSync(), isTrue,
        reason: 'Ctrl+S must reach saveProject with no canvas focused');
  });
}
