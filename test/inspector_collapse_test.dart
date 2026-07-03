import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/inspector_store.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/inspector/collapsible_inspector.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx/ui/sheets/sheet_rail.dart';

import 'test_util.dart';

/// Load the bundled Roboto faces so a tofu check is meaningful (a missing glyph
/// renders as a box at the test surface).
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

/// Settle a frame plus the inspector width animation.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('inspector starts expanded by default', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );

    // Default state is EXPANDED (so the screenshot goldens, which never touch
    // this provider, keep the inspector visible).
    expect(container.read(inspectorCollapsedProvider), isFalse);
    expect(find.byType(CollapsibleInspector), findsOneWidget);
    expect(find.byType(ProjectPanel), findsOneWidget);
  });

  testWidgets('tapping the toggle collapses then re-expands the inspector',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );

    double inspectorWidth() =>
        tester.getSize(find.byType(CollapsibleInspector)).width;

    final expandedWidth = inspectorWidth();
    expect(expandedWidth, greaterThan(ProjectPanel.width));

    // The toggle strip carries a semantics button; tap it to collapse.
    await tester.tap(find.bySemanticsLabel('Collapse inspector'));
    await _settle(tester);

    expect(container.read(inspectorCollapsedProvider), isTrue);
    final collapsedWidth = inspectorWidth();
    // Collapsed shrinks to the thin strip — a fraction of the expanded panel.
    expect(collapsedWidth, CollapsibleInspector.collapsedWidth);
    expect(collapsedWidth, lessThan(expandedWidth / 4));
    // The body is clipped off to the right of the thin strip (it stays in the
    // tree but its left edge sits beyond the visible strip, so it is hidden).
    final inspectorLeft =
        tester.getTopLeft(find.byType(CollapsibleInspector)).dx;
    final panelLeft = tester.getTopLeft(find.byType(ProjectPanel)).dx;
    expect(panelLeft,
        greaterThanOrEqualTo(inspectorLeft + CollapsibleInspector.collapsedWidth));

    // Tapping again re-expands.
    await tester.tap(find.bySemanticsLabel('Expand inspector'));
    await _settle(tester);
    expect(container.read(inspectorCollapsedProvider), isFalse);
    expect(inspectorWidth(), expandedWidth);
    expect(find.byType(ProjectPanel), findsOneWidget);
  });

  testWidgets('collapsing widens the canvas region', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );

    final inspectorExpanded =
        tester.getSize(find.byType(CollapsibleInspector)).width;

    container.read(inspectorCollapsedProvider.notifier).set(true);
    await _settle(tester);
    final inspectorCollapsed =
        tester.getSize(find.byType(CollapsibleInspector)).width;

    // The canvas reclaims (expanded − collapsed) width when the inspector
    // collapses — a large chunk of real estate.
    expect(inspectorExpanded - inspectorCollapsed, greaterThan(ProjectPanel.width));
  });

  testWidgets('collapse applies to the electrical-layer inspector too',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    container
        .read(activeDisciplineProvider.notifier)
        .set(DisciplineLayer.electrical);
    await tester.pump();

    // The electrical Loads column is the inspector now; it is still wrapped.
    expect(find.byType(CollapsibleInspector), findsOneWidget);
    expect(find.text('Electrical layer'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Collapse inspector'));
    await _settle(tester);
    expect(container.read(inspectorCollapsedProvider), isTrue);
    // The Loads column is clipped off-screen — the inspector is now the strip.
    expect(
        tester.getSize(find.byType(CollapsibleInspector)).width,
        CollapsibleInspector.collapsedWidth);
  });

  testWidgets('collapse applies on the schematic view', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.schematic);
    await tester.pump();

    expect(find.byType(CollapsibleInspector), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Collapse inspector'));
    await _settle(tester);
    expect(container.read(inspectorCollapsedProvider), isTrue);
    expect(
        tester.getSize(find.byType(CollapsibleInspector)).width,
        CollapsibleInspector.collapsedWidth);
  });

  testWidgets('sheet rail is a slim compact strip', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    // Production launches with NO sheets (A1); seed the three demo sheets so the
    // rail has tiles (1/2/3) to compact.
    seedDemoSheets(ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    ));
    await tester.pump();

    // The rewritten rail is much narrower than the old 232-px wide-card list.
    expect(SheetRail.width, lessThan(120));
    final railSize = tester.getSize(find.byType(SheetRail));
    expect(railSize.width, SheetRail.width);

    // It still lists every demo sheet (functions preserved, just compacted):
    // a numeric index per sheet, plus its (truncated) name.
    expect(find.descendant(of: find.byType(SheetRail), matching: find.text('1')),
        findsOneWidget);
    expect(find.descendant(of: find.byType(SheetRail), matching: find.text('2')),
        findsOneWidget);
    expect(find.descendant(of: find.byType(SheetRail), matching: find.text('3')),
        findsOneWidget);
  });

  testWidgets('tapping a slim rail tile switches the active sheet',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    // Production launches with NO sheets (A1); seed the demo sheets so the rail
    // has a second tile to tap.
    seedDemoSheets(container);
    await tester.pump();
    // Tap the second tile (index "2") — selection follows.
    await tester.tap(
        find.descendant(of: find.byType(SheetRail), matching: find.text('2')));
    await tester.pump();
    expect(container.read(sheetsControllerProvider).currentIndex, 1);
  });
}
