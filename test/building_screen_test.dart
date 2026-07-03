import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/shell/nav_rail.dart';
import 'package:mechx/ui/widgets/stepped_value_field.dart';

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

  // ── D4: type-in floor height + bulk "Add N levels @ H m" ──────────────────

  testWidgets('the height field accepts a typed value (D4)', (tester) async {
    await _openBuilding(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );

    // The FIRST SteppedValueField is the top card (Level 2) height. Click its
    // value to type-in, enter 4.2, commit with Enter.
    final topHeight = find.byType(SteppedValueField).first;
    await tester.tap(
        find.descendant(of: topHeight, matching: find.text('3.5 m')));
    await tester.pump();
    final editor =
        find.descendant(of: topHeight, matching: find.byType(EditableText));
    await tester.enterText(editor, '4.2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(container.read(projectControllerProvider).floors.last.height.meters,
        closeTo(4.2, 1e-9));
  });

  testWidgets('Add N levels appends N floors in one step (D4)', (tester) async {
    await _openBuilding(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    expect(container.read(projectControllerProvider).floors.length, 3);

    // The Add row's count stepper is the 4th SteppedValueField (after the 3
    // floor-card height fields). Bump the count to 2, then tap "Add levels".
    final countField = find.byType(SteppedValueField).at(3);
    await tester.tap(find.descendant(of: countField, matching: find.text('+')));
    await tester.pump();
    await tester.tap(find.text('Add levels'));
    await tester.pump();

    expect(container.read(projectControllerProvider).floors.length, 5);
    expect(find.text('Level 4'), findsOneWidget);
  });
}
