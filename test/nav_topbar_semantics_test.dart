// L4 (a11y): the nav rail destinations and the top-bar actions must expose
// accessible names to a screen reader. The nav items carry their visible
// caption when expanded and an explicit `semanticLabel` when collapsed (icon-
// only); the top-bar Open/Save/Import buttons are labelled MechXButtons, the
// theme toggle and command-palette hint carry their own Semantics labels. This
// guards that labelling — Semantics is layout/paint-transparent, so goldens are
// unaffected.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/ui/sheets/sheet_rail.dart';
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

void main() {
  setUpAll(_loadFonts);

  testWidgets('the nav rail exposes an accessible name for each destination',
      (tester) async {
    final handle = tester.ensureSemantics();
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    // Every rail destination is announced by its name (EN defaults).
    for (final name in const [
      'Layout',
      'Building',
      'Review',
      'Commercial',
      'Projects',
      'Preferences',
    ]) {
      expect(find.bySemanticsLabel(name), findsWidgets, reason: name);
    }
    handle.dispose();
  });

  testWidgets('collapsed nav-rail items keep their accessible name',
      (tester) async {
    final handle = tester.ensureSemantics();
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NavRail)),
      listen: false,
    );
    // Collapse the rail to icon-only — the captions cross-fade out, so the label
    // now comes from the explicit `semanticLabel` (L4), not the visible Text.
    container.read(navRailCollapsedProvider.notifier).toggle();
    await tester.pump();

    expect(find.bySemanticsLabel('Review'), findsWidgets);
    expect(find.bySemanticsLabel('Projects'), findsWidgets);
    handle.dispose();
  });

  testWidgets('the top bar exposes accessible names for its actions',
      (tester) async {
    final handle = tester.ensureSemantics();
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    // The primary file actions (labelled MechXButtons).
    expect(find.bySemanticsLabel('Open'), findsWidgets);
    expect(find.bySemanticsLabel('Save'), findsWidgets);
    expect(find.bySemanticsLabel('Export'), findsWidgets);
    // The command-palette hint carries its own Semantics label.
    expect(find.bySemanticsLabel('Open command palette'), findsWidgets);
    // Work item 9: the zoom pill, the Import-plan button and the theme toggle
    // are gone from the top bar (zoom -> ZoomControls, Import -> the sheet
    // rail's '+' tile, theme -> Preferences / the palette).
    expect(find.byKey(const ValueKey('zoom-pill')), findsNothing);
    expect(find.bySemanticsLabel(RegExp('Switch to (light|dark)')),
        findsNothing);
    handle.dispose();
  });

  testWidgets("the sheet rail's trailing '+' tile is announced as Import plan",
      (tester) async {
    final handle = tester.ensureSemantics();
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedDemoSheets(container);
    await tester.pump();

    final tile = find.byKey(const ValueKey('sheet-rail-import'));
    expect(tile, findsOneWidget);
    expect(
      find.descendant(
          of: find.byType(SheetRail),
          matching: find.bySemanticsLabel('Import plan')),
      findsOneWidget,
    );
    handle.dispose();
  });
}
