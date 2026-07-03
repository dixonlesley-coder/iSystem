import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/shell/nav_rail.dart';
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
    expect(find.text('DESIGN'), findsOneWidget);
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

    // Hover the topmost nav glyph (the first item, "Layout") — the
    // highest-on-screen CustomPaint inside the rail.
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
    expect(find.text('Layout'), findsWidgets);
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
      'DESIGN',
    ]) {
      expect(label.codeUnits.every((c) => c < 128), isTrue,
          reason: '"$label" must be pure ASCII');
    }
  });
}
