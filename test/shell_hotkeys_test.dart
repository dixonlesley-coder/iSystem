import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/data/autosave.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/command_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/project_store.dart';
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
      // Generous poll: the save runs on a real Isolate + filesystem, which can
      // take many seconds when the full suite saturates the CPU with a dozen
      // concurrent test isolates each spawning their own save isolate. The
      // window is deliberately wide (up to ~20 s) because it never slows the
      // pass path — the loop exits the instant the file lands — and a too-tight
      // ceiling was the one observed load-dependent flake in the whole suite.
      for (var i = 0; i < 400 && !File(path).existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    expect(File(path).existsSync(), isTrue,
        reason: 'Ctrl+S must reach saveProject with no canvas focused');
  });

  testWidgets('Ctrl+N starts a new project from any screen', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final c = _containerOf(tester);

    // A clean project with a remembered home file: Ctrl+N must forget the file
    // (the next Save prompts for a location) without any confirm dialog.
    c.read(currentProjectPathProvider.notifier).set('/tmp/never-written.mechx');
    c.read(projectControllerProvider.notifier).setName('Tower B');
    // Record the renamed state as the clean baseline, so the fresh dirty check
    // in newProject's guard passes without an (unanswerable) confirm dialog.
    c.read(lastSavedSignatureProvider.notifier).set(buildDocument(c.read).encode());
    c.read(projectDirtyProvider.notifier).set(false);
    c.read(shellSectionProvider.notifier).set(ShellSection.review);
    await tester.pump();

    await tester.runAsync(() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      // newProject clears the recovery slots on the real filesystem.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(c.read(currentProjectPathProvider), isNull);
    expect(c.read(projectControllerProvider).name, 'Untitled project');
  });

  testWidgets('Ctrl+1..8 jump to the nav destinations in rail order',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final c = _containerOf(tester);

    await _pressCtrl(tester, LogicalKeyboardKey.digit5);
    expect(c.read(shellSectionProvider), ShellSection.review);

    await _pressCtrl(tester, LogicalKeyboardKey.digit2);
    expect(c.read(shellSectionProvider), ShellSection.design);
    expect(c.read(workspaceViewProvider), WorkspaceView.schematic);

    await _pressCtrl(tester, LogicalKeyboardKey.digit1);
    expect(c.read(workspaceViewProvider), WorkspaceView.plan);

    // Ctrl+, is the second way to Preferences (the macOS convention).
    await _pressCtrl(tester, LogicalKeyboardKey.comma);
    expect(c.read(shellSectionProvider), ShellSection.preferences);
  });

  testWidgets('F1 opens the keyboard-shortcuts sheet and Esc closes it — on a '
      'hub screen, where nothing holds focus', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final c = _containerOf(tester);

    c.read(shellSectionProvider.notifier).set(ShellSection.projects);
    await tester.pump();
    expect(c.read(shortcutsSheetOpenProvider), isFalse);
    expect(find.text('Keyboard shortcuts'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await tester.pump();
    expect(c.read(shortcutsSheetOpenProvider), isTrue);
    // The sheet documents the global bindings AND the canvas ones (its title
    // plus its own F1 row both read "Keyboard shortcuts").
    expect(find.text('Keyboard shortcuts'), findsWidgets);
    expect(find.text('Ctrl N'), findsOneWidget);
    expect(find.text('Ctrl Shift S'), findsOneWidget);
    expect(find.text('Hold Space'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(c.read(shortcutsSheetOpenProvider), isFalse);
  });

  testWidgets('the two overlays never stack: F1 closes the palette, Ctrl+K '
      'closes the sheet', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final c = _containerOf(tester);

    await _pressCtrl(tester, LogicalKeyboardKey.keyK);
    expect(c.read(commandPaletteOpenProvider), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await tester.pump();
    expect(c.read(commandPaletteOpenProvider), isFalse);
    expect(c.read(shortcutsSheetOpenProvider), isTrue);

    await _pressCtrl(tester, LogicalKeyboardKey.keyK);
    expect(c.read(shortcutsSheetOpenProvider), isFalse);
    expect(c.read(commandPaletteOpenProvider), isTrue);
  });

  testWidgets('Ctrl+Z undoes from a hub screen, but stands down while a text '
      'field is focused', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final c = _containerOf(tester);

    // One undoable edit on the project (a rename), recorded on the global
    // timeline — with no canvas anywhere near the focus.
    c.read(shellSectionProvider.notifier).set(ShellSection.projects);
    await tester.pump();
    c.read(projectControllerProvider.notifier).setName('Menara Satu');
    await tester.pump();
    expect(c.read(projectControllerProvider).name, 'Menara Satu');

    // While the project-name FIELD holds focus the combo belongs to the field.
    tester
        .widget<EditableText>(find.byType(EditableText).first)
        .focusNode
        .requestFocus();
    await tester.pump();
    await _pressCtrl(tester, LogicalKeyboardKey.keyZ);
    expect(c.read(projectControllerProvider).name, 'Menara Satu',
        reason: 'Ctrl+Z inside a text field must not touch the project');

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await _pressCtrl(tester, LogicalKeyboardKey.keyZ);
    expect(c.read(projectControllerProvider).name, isNot('Menara Satu'),
        reason: 'Ctrl+Z with nothing focused must reach the global timeline');
  });
}
