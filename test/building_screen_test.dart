import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/app_state.dart'
    show occupancyProvider, statusMessageProvider;
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/shell/nav_rail.dart';
import 'package:mechx/ui/widgets/stepped_value_field.dart';
import 'package:mechx_engine/geometry/building.dart' show MountingHeights;
import 'package:mechx_engine/standards/sni.dart' show Occupancy;

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
    // ONE consolidated add control with two direction buttons (the redundant
    // standalone "+ Add level" is gone).
    expect(find.text('+  Add level'), findsNothing);
    expect(find.text('Add on top'), findsOneWidget);
    expect(find.text('Add basement'), findsOneWidget);
  });

  testWidgets('Add on top appends a floor (count defaults to 1)', (tester) async {
    await _openBuilding(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    expect(container.read(projectControllerProvider).floors.length, 3);

    // F8/F10/G7 grew the page (mounting-height inputs, per-level plan lists,
    // effect captions), so the add control can sit below the fold.
    await tester.ensureVisible(find.text('Add on top'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add on top'));
    await tester.pump();
    expect(container.read(projectControllerProvider).floors.length, 4);
    expect(find.text('Level 3'), findsOneWidget);
  });

  testWidgets('the Building page hosts the project design inputs (moved off '
      'the canvas inspector)', (tester) async {
    await _openBuilding(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );

    // The design-input controls now live here (the section header is uppercase).
    expect(find.text('DESIGN INPUTS'), findsOneWidget);
    expect(find.text('Occupancy'), findsOneWidget);
    expect(find.text('Rainfall (storm)'), findsOneWidget);
    expect(find.text('Runoff coefficient'), findsOneWidget);

    // Occupancy segments drive the provider (default is private/Residential).
    expect(container.read(occupancyProvider), Occupancy.private);
    await tester.ensureVisible(find.text('Office / public'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Office / public'));
    await tester.pump();
    expect(container.read(occupancyProvider), Occupancy.public);
  });

  testWidgets('Add basement adds a below-ground level (ground stays 0.0)',
      (tester) async {
    await _openBuilding(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );

    await tester.ensureVisible(find.text('Add basement'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add basement'));
    await tester.pump();

    final s = container.read(projectControllerProvider);
    expect(s.floors.length, 4);
    expect(s.groundIndex, 1);
    expect(find.text('Basement 1'), findsOneWidget);
    // Ground still reads 0.0; the new basement reads negative (default 3.5 m).
    expect(s.building.elevationOf(s.groundIndex).meters, 0.0);
    expect(find.text('elev -3.5 m'), findsOneWidget);
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
    // floor-card height fields). Bump the count to 2, then tap "Add on top".
    final countField = find.byType(SteppedValueField).at(3);
    await tester.ensureVisible(countField);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: countField, matching: find.text('+')));
    await tester.pump();
    await tester.ensureVisible(find.text('Add on top'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add on top'));
    await tester.pump();

    expect(container.read(projectControllerProvider).floors.length, 5);
    expect(find.text('Level 4'), findsOneWidget);
  });

  // ── F8 / F10 / G7 (WORKFLOW-FRICTION) ─────────────────────────────────────

  testWidgets('F8: the mounting heights are editable project inputs',
      (tester) async {
    await _openBuilding(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    expect(container.read(mountingProvider), const MountingHeights());

    // Both fields are on the page, with their effect captions.
    final drop = find.text('Ceiling drop');
    await tester.ensureVisible(drop);
    await tester.pumpAndSettle();
    expect(drop, findsOneWidget);
    expect(find.text('Fixture height'), findsOneWidget);
    expect(find.textContaining('below the slab above'), findsOneWidget);

    // Type a new ceiling drop: 0.30 -> 0.45 m, and the project state carries it.
    // The 6th SteppedValueField: 3 floor-card heights, the Add row's count +
    // height, then the design inputs, whose first row is the ceiling drop. (A
    // finder anchored on the VALUE text can't be reused after the tap — the
    // text is replaced by the editor.)
    final dropField = find.byType(SteppedValueField).at(5);
    await tester.ensureVisible(dropField);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: dropField, matching: find.text('0.30 m')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.descendant(of: dropField, matching: find.byType(EditableText)),
        '0.45');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(container.read(mountingProvider).ceilingDrop.meters,
        closeTo(0.45, 1e-9));
  });

  testWidgets('G7: a committed design input confirms that sizing re-ran',
      (tester) async {
    await _openBuilding(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    expect(container.read(statusMessageProvider), isNull);

    final rainfall = find.text('Rainfall (storm)');
    await tester.ensureVisible(rainfall);
    await tester.pumpAndSettle();
    final field = find.ancestor(
        of: find.text('200 mm/hr'), matching: find.byType(SteppedValueField));
    await tester.tap(find.descendant(of: field, matching: find.text('+')));
    await tester.pump();
    // Debounced: it lands once the value settles, not once per stepper tick.
    expect(container.read(statusMessageProvider), isNull);
    await tester.pump(const Duration(milliseconds: 500));
    expect(container.read(statusMessageProvider), 'Sizing updated');
  });

  testWidgets('G7: the design inputs carry effect captions + a slope direction '
      'hint (the stepper reads inverted by nature)', (tester) async {
    await _openBuilding(tester);
    await tester.ensureVisible(find.text('Runoff coefficient'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Drives gravity sizing'), findsOneWidget);
    expect(find.textContaining('Plus is steeper'), findsOneWidget);
    // The ΔT row names its unit in plain terms (the bare "5 K" said nothing).
    expect(find.textContaining('degrees C lost around the loop'), findsOneWidget);
  });

  testWidgets('F10: a level lists EVERY plan mapped to it, not just the first',
      (tester) async {
    await _openBuilding(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    // Pile all three demo sheets onto the Ground floor (index 0) — the exact
    // state the old first-match-wins card hid.
    final sheets = container.read(sheetsControllerProvider.notifier);
    for (final id in ['s1', 's2', 's3']) {
      sheets.setSheetFloor(id, 0);
    }
    await tester.pumpAndSettle();

    // The count says three, and every name is listed.
    expect(find.text('3 plans'), findsOneWidget);
    expect(find.text('Ground Floor'), findsWidgets);
    expect(find.text('First Floor'), findsWidgets);
    expect(find.text('Roof Plan'), findsWidgets);
    // The two levels left planless say so honestly.
    expect(find.text('none'), findsNWidgets(2));
  });
}
