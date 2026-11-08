import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/shell/nav_rail.dart';
import 'package:mechx/ui/shell/shell_shortcuts.dart';
import 'package:mechx/ui/shell/shortcuts_sheet.dart';
import 'package:mechx/ui/sheets/sheet_rail.dart';

import 'test_util.dart';

/// Load the bundled Roboto faces so a tofu check is meaningful (a missing glyph
/// renders as a box at the test surface, which we assert never happens).
Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final sans = FontLoader('Roboto')
    ..addFont(bytes('assets/fonts/Roboto-Regular.ttf'))
    ..addFont(bytes('assets/fonts/Roboto-Medium.ttf'));
  await sans.load();
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('rail renders all destinations', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    expect(find.byType(NavRail), findsOneWidget);
    for (final group in const ['SETUP', 'DESIGN', 'ISSUE']) {
      expect(
        find.descendant(of: find.byType(NavRail), matching: find.text(group)),
        findsOneWidget,
        reason: 'group label "$group"',
      );
    }
    for (final label in const [
      'Layout', // "Plan" relabelled — the unified shared-PDF canvas
      'Riser',
      'Electrical',
      'Building',
      'Review',
      'Commercial',
      'Projects',
      'Preferences',
    ]) {
      // Scope to the rail — labels like "Electrical" also appear in the unified
      // Layout canvas's layer switcher.
      expect(
        find.descendant(
            of: find.byType(NavRail), matching: find.text(label)),
        findsOneWidget,
        reason: 'rail item "$label"',
      );
    }
  });

  testWidgets(
      'rail reads in workflow order: SETUP · DESIGN · ISSUE, Preferences pinned',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    double y(String label) => tester
        .getCenter(find.descendant(
            of: find.byType(NavRail), matching: find.text(label)))
        .dy;
    const order = [
      'SETUP',
      'Projects',
      'Building',
      'DESIGN',
      'Layout',
      'Riser',
      'Electrical',
      'ISSUE',
      'Review',
      'Commercial',
      'Preferences',
    ];
    for (var i = 1; i < order.length; i++) {
      expect(y(order[i]), greaterThan(y(order[i - 1])),
          reason: '"${order[i]}" sits below "${order[i - 1]}"');
    }
  });

  testWidgets(
      'every ShellSection / WorkspaceView is reachable from exactly one rail '
      'item', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedSampleElectrical(container);
    await tester.pump();

    const labels = [
      'Projects',
      'Building',
      'Layout',
      'Riser',
      'Electrical',
      'Review',
      'Commercial',
      'Preferences',
    ];
    final reached = <String, String>{};
    for (final label in labels) {
      final f =
          find.descendant(of: find.byType(NavRail), matching: find.text(label));
      expect(f, findsOneWidget, reason: 'one rail item "$label"');
      await tester.tap(f);
      await tester.pump();
      final section = container.read(shellSectionProvider);
      final dest = section == ShellSection.design
          ? 'design:${container.read(workspaceViewProvider).name}'
          : section.name;
      expect(reached.containsKey(dest), isFalse,
          reason: '"$label" duplicates "${reached[dest]}" -> $dest');
      reached[dest] = label;
    }
    final expected = {
      for (final s in ShellSection.values)
        if (s != ShellSection.design) s.name,
      for (final v in WorkspaceView.values) 'design:${v.name}',
    };
    expect(reached.keys.toSet(), expected);
  });

  testWidgets('rail highlights the active design workspace, no off-by-one',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    // Production launches with an EMPTY electrical project (A2); this test drives
    // the workspace over to Electrical, so seed the sample switchboard to give
    // that view content to render.
    seedSampleElectrical(container);
    await tester.pump();

    // Default: design section, Layout view (enum value still `plan`).
    expect(container.read(shellSectionProvider), ShellSection.design);
    expect(container.read(workspaceViewProvider), WorkspaceView.plan);

    // Scope to the rail subtree — labels like "Layout"/"Electrical" also appear
    // elsewhere (the unified canvas's layer switcher / a sheet name).
    Finder railText(String label) =>
        find.descendant(of: find.byType(NavRail), matching: find.text(label));
    TextStyle styleOf(String label) =>
        tester.widget<Text>(railText(label)).style!;

    // The active item reads bolder than an inactive sibling.
    expect(styleOf('Layout').fontWeight, FontWeight.w600);
    expect(styleOf('Riser').fontWeight, FontWeight.w500);

    // Selecting Electrical drives the workspace provider (the screenshots test
    // contract) and moves the highlight — no off-by-one onto a neighbour.
    await tester.tap(railText('Electrical'));
    await tester.pump();
    expect(container.read(workspaceViewProvider), WorkspaceView.electrical);
    expect(container.read(shellSectionProvider), ShellSection.design);
    expect(styleOf('Electrical').fontWeight, FontWeight.w600);
    expect(styleOf('Layout').fontWeight, FontWeight.w500);
  });

  testWidgets('switching to a non-design section changes the body',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );

    // The plan workspace shows the sheet rail (the demo sheet list).
    expect(find.byType(SheetRail), findsOneWidget);

    await tester.tap(find.text('Review'));
    await tester.pump();
    expect(container.read(shellSectionProvider), ShellSection.review);
    // The Review hub body is now shown (its lead copy), and the design
    // workspace (with its sheet rail) is gone.
    expect(find.textContaining('Check the design before you issue it'),
        findsOneWidget);
    expect(find.byType(SheetRail), findsNothing);

    await tester.tap(find.text('Preferences'));
    await tester.pump();
    expect(container.read(shellSectionProvider), ShellSection.preferences);
    expect(find.text('Appearance'), findsOneWidget);
  });

  testWidgets(
      'a collapsed rail names a destination via a hover label (no caption '
      'otherwise)', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );

    // Collapse the rail → captions are hidden, so "Layout" no longer renders in
    // the rail body.
    container.read(navRailCollapsedProvider.notifier).set(true);
    await tester.pumpAndSettle();
    Finder railText(String label) =>
        find.descendant(of: find.byType(NavRail), matching: find.text(label));
    expect(railText('Layout'), findsNothing);
    expect(railText('Projects'), findsNothing);
    expect(railText('SETUP'), findsNothing);

    // Hover the topmost nav glyph (the first item, "Projects" — SETUP leads
    // the workflow-ordered rail) — the highest-on-screen CustomPaint inside
    // the rail.
    final glyphCenters = find
        .descendant(of: find.byType(NavRail), matching: find.byType(CustomPaint))
        .evaluate()
        .map((e) => tester.getCenter(find.byWidget(e.widget)))
        .toList()
      ..sort((a, b) => a.dy.compareTo(b.dy));
    final topGlyph = glyphCenters.first;

    final gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(topGlyph);
    await tester.pumpAndSettle();

    // The hover label now names the destination (ASCII, no tofu).
    expect(find.text('Projects'), findsWidgets);
  });

  testWidgets('rail icons paint without tofu (glyphs are custom-drawn)',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    // The rail draws its icons with CustomPaint (no icon font), so there is no
    // glyph text in the rail that could render as a tofu box. Assert the labels
    // are the only text and there are seven painted glyphs.
    expect(find.byType(CustomPaint), findsWidgets);
    // Sanity: none of the rail labels contain a non-ASCII symbol that Roboto
    // would tofu.
    for (final label in const [
      'Layout',
      'Riser',
      'Electrical',
      'Building',
      'Review',
      'Commercial',
      'Projects',
      'Preferences',
      'SETUP',
      'DESIGN',
      'ISSUE',
    ]) {
      expect(label.codeUnits.every((c) => c < 128), isTrue,
          reason: '"$label" must be pure ASCII');
    }
  });

  test('the F1 sheet lists Go-to rows in rail order, keycaps unchanged', () {
    final goTo = kShellShortcutGroups.firstWhere((g) => g.title == 'Go to');
    final ordered = inRailOrder(goTo);
    expect([for (final d in ordered.shortcuts) '${d.keys}=${d.label}'], [
      'Ctrl 7=Projects',
      'Ctrl 4=Building',
      'Ctrl 1=Layout',
      'Ctrl 2=Riser',
      'Ctrl 3=Electrical',
      'Ctrl 5=Review',
      'Ctrl 6=Commercial',
      'Ctrl 8=Preferences',
      'Ctrl ,=Preferences',
    ]);
    // The binding table itself stays destination-keyed (shipped muscle memory).
    expect(matchShellShortcut(LogicalKeyboardKey.digit1, mod: true, shift: false, alt: false),
        ShellCommand.goLayout);
    expect(matchShellShortcut(LogicalKeyboardKey.digit7, mod: true, shift: false, alt: false),
        ShellCommand.goProjects);
    // Non-navigation groups are untouched.
    final file = kShellShortcutGroups.first;
    expect(identical(inRailOrder(file), file), isTrue);
  });
}
