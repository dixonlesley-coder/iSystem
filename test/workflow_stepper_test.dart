import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/command_store.dart';
import 'package:mechx/ui/shell/command_palette.dart';
import 'package:mechx/ui/shell/workflow_stepper.dart';

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

void main() {
  setUpAll(_loadFonts);

  testWidgets('status bar renders the five workflow stages', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    expect(find.byType(WorkflowStepper), findsOneWidget);
    for (final label in const [
      'Calibrate',
      'Floors',
      'Draw',
      'Size',
      'Report',
    ]) {
      expect(
        find.descendant(
            of: find.byType(WorkflowStepper), matching: find.text(label)),
        findsOneWidget,
        reason: 'workflow stage "$label"',
      );
    }
  });

  testWidgets('command palette is closed at rest and renders nothing',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    expect(container.read(commandPaletteOpenProvider), isFalse);
    // The overlay is mounted but renders an empty box when closed.
    expect(find.byType(CommandPaletteOverlay), findsOneWidget);
    expect(find.text('No matching commands.'), findsNothing);
  });

  testWidgets('opening the palette shows filterable commands; filter narrows',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    // Open the palette (the Ctrl/Cmd+K intent — exercised directly via the
    // provider to avoid raw-key plumbing in the test surface).
    container.read(commandPaletteOpenProvider.notifier).open();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // A known command near the top of the (scrollable) list is shown.
    expect(find.text('Go to Schematic'), findsOneWidget);

    // Type a filter that should keep only matching commands — the list narrows
    // to a single short result, bringing it on-screen.
    await tester.enterText(find.byType(EditableText), 'schem');
    await tester.pump();
    expect(find.text('Go to Schematic'), findsOneWidget);
    expect(find.text('Go to Layout'), findsNothing);

    // A different filter surfaces the export command (which lives lower in the
    // unfiltered list and would otherwise be scrolled off).
    await tester.enterText(find.byType(EditableText), 'export');
    await tester.pump();
    expect(find.text('Export calculation report'), findsOneWidget);
    expect(find.text('Go to Schematic'), findsNothing);
  });

  testWidgets('Esc closes the open palette', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    container.read(commandPaletteOpenProvider.notifier).open();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(EditableText), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(container.read(commandPaletteOpenProvider), isFalse);
  });
}
