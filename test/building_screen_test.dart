import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/shell/nav_rail.dart';

import 'test_util.dart';

/// Opens the dedicated Building page from the nav rail. Seeds the demo sheets
/// first (production launches EMPTY per A1; the plan picker below needs them).
Future<void> _openBuilding(WidgetTester tester) async {
  setDesktopSurface(tester);
  await tester.pumpWidget(const ProviderScope(child: MechXApp()));
  await tester.pump();
  ProviderScope.containerOf(
    tester.element(find.byType(MechXApp)),
    listen: false,
  ).read(sheetsControllerProvider.notifier).loadDemoSheets();
  await tester.pump();
  await tester.tap(find.descendant(
      of: find.byType(NavRail), matching: find.text('Building')));
  await tester.pump();
}

void main() {
  testWidgets('Building page lists the floors + their heights', (tester) async {
    await _openBuilding(tester);

    expect(find.text('Building'), findsWidgets); // title + rail label
    // Floors render (top first) with their floor-to-floor height control.
    expect(find.text('Ground'), findsOneWidget);
    expect(find.text('Level 2'), findsOneWidget);
    expect(find.text('Floor-to-floor height'), findsNWidgets(3));
    expect(find.text('+  Add level'), findsOneWidget);
  });

  testWidgets('Add level appends a floor', (tester) async {
    await _openBuilding(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    expect(container.read(projectControllerProvider).floors.length, 3);

    await tester.tap(find.text('+  Add level'));
    await tester.pump();
    expect(container.read(projectControllerProvider).floors.length, 4);
    expect(find.text('Level 3'), findsOneWidget);
  });

  testWidgets('assigning a floor plan maps that sheet to the level',
      (tester) async {
    await _openBuilding(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );

    // The top card is Level 2 (floor index 2). Open its plan picker.
    await tester.tap(find.text('Change').first);
    await tester.pumpAndSettle();
    expect(find.text('Assign a floor plan'), findsOneWidget);

    // Pick the demo 'Ground Floor' sheet (id s1) for the top level.
    await tester.tap(find.text('Ground Floor').last);
    await tester.pumpAndSettle();
    expect(container.read(sheetsControllerProvider).floorFor('s1', 3), 2);
  });

  testWidgets('the height stepper nudges a floor height', (tester) async {
    await _openBuilding(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    // Ground floor default is 4.0 m; the top card is Level 2 (3.5 m). Tap the
    // first '+' (top card = Level 2) and confirm its height grows by 0.1.
    final before = container.read(projectControllerProvider).floors.last.height.meters;
    await tester.tap(find.text('+').first);
    await tester.pump();
    final after = container.read(projectControllerProvider).floors.last.height.meters;
    expect(after, closeTo(before + 0.1, 1e-9));
  });
}
