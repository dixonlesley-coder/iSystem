// Round 29 (2026-10-18) — UI-journey findings:
//
//   ui-journeys-3-fault-level-pinned-no-auto   the Supply > Advanced origin
//     fault level is an optional field: a typed value pins, 0 / empty hands it
//     back to the estimate chain (shown as the hint).
//   ui-journeys-3-palette-calibrate-no-sheet   the palette's Start calibration
//     with no plan routes to Import.
//   ui-journeys-3-palette-dup-floor-up-silent  the silent 'Duplicate floor up'
//     is gone.
//   ui-journeys-3-stepper-ignores-electrical   electrical work ticks Draw/Size.
//   ui-journeys-3-feed-shown-three-ways        the inspector feed line follows
//     the drawn feed; an assumed upfeed pump is one story.
//   ui-journeys-3-occupancy-two-vocabularies / -sources-note-drawing-only-
//     false / -electrical-empty-copy-phase   honest copy.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/calibration_store.dart';
import 'package:mechx/store/command_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sample_project.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/ui/inspector/feed_strategy_line.dart';
import 'package:mechx/ui/strings/app_strings.dart';
import 'package:mechx/ui/strings/occupancy_label.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/electrical/electrical_controls.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/standards/sni.dart' show Occupancy;
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

Finder _fieldInput(String label) => find.descendant(
    of: find.ancestor(
        of: find.text(label), matching: find.byType(ElectricalField)),
    matching: find.byType(EditableText));

void main() {
  testWidgets(
      'origin fault level: type 10 pins 10 kA; 0 returns to the estimate, '
      'which a later transformer then raises', (tester) async {
    setDesktopSurface(tester, size: const Size(1440, 900));
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final c = ProviderScope.containerOf(tester.element(find.byType(MechXApp)),
        listen: false);
    c.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
    c
        .read(electricalProjectProvider.notifier)
        .setProject(sampleElectricalProject());
    await tester.pump();
    await tester.tap(find.text('Supply').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('ADVANCED'));
    await tester.tap(find.text('ADVANCED'));
    await tester.pumpAndSettle();

    const label = 'Origin fault level (kA, 0 = auto)';
    // Unpinned: the field is empty and the hint names the estimate in use.
    expect(c.read(electricalProjectProvider).originFaultLevelA, isNull);
    expect(find.textContaining('Auto · 16.0 kA'), findsOneWidget);

    await tester.ensureVisible(find.text(label));
    await tester.enterText(_fieldInput(label), '10');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(c.read(electricalProjectProvider).originFaultLevelA!.amperes,
        10000);

    // 0 = auto (was: silently rejected, the 10 kA pin stayed for good).
    await tester.enterText(_fieldInput(label), '0');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(c.read(electricalProjectProvider).originFaultLevelA, isNull);

    // Back on the estimate chain: a declared 1000 kVA transformer raises the
    // fault the solve uses to 1e6 / (√3 · 400 · 0.04) = 36.08 kA.
    c
        .read(electricalProjectProvider.notifier)
        .setTransformerKva(ApparentPower.kilovoltAmperes(1000));
    await tester.pumpAndSettle();
    expect(find.textContaining('Auto · 36.1 kA'), findsOneWidget);
  });

  testWidgets(
      'palette Start calibration with no plan routes to Import (no invisible '
      'calibration mode)', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final c = ProviderScope.containerOf(tester.element(find.byType(MechXApp)),
        listen: false);
    // Dirty project: Import stops at its unsaved-work guard — the observable
    // proof the command routed to Import (the OS picker cannot run headless).
    c
        .read(projectControllerProvider.notifier)
        .setFloors(const [Floor('Only', Length(3.0))]);
    await tester.pumpAndSettle();
    c.read(commandPaletteOpenProvider.notifier).open();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(find.byType(EditableText), 'Start calibration');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(c.read(calibrationControllerProvider).phase, CalibrationPhase.idle);
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets(
      "palette: the silent 'Duplicate floor up' is gone; 'Duplicate floor "
      "to...' covers it", (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final c = ProviderScope.containerOf(tester.element(find.byType(MechXApp)),
        listen: false);
    c.read(commandPaletteOpenProvider.notifier).open();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(find.byType(EditableText), 'Duplicate floor');
    await tester.pump();
    expect(find.text('Duplicate floor up'), findsNothing);
    expect(find.text('Duplicate floor to…'), findsOneWidget);
  });

  test('stepper: an electrical-only design ticks Draw and Size', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    WorkflowState s() => c.read(workflowStageStateProvider);
    expect(s().done[WorkflowStage.draw], isFalse);
    expect(s().done[WorkflowStage.size], isFalse);
    c
        .read(electricalProjectProvider.notifier)
        .setProject(sampleElectricalProject());
    // No mechanical edge: the boards' ways are the drawn work and their
    // solved result is the sizing.
    expect(c.read(networkControllerProvider).network.edges, isEmpty);
    expect(c.read(electricalResultProvider).panels, isNotEmpty);
    expect(s().done[WorkflowStage.draw], isTrue);
    expect(s().done[WorkflowStage.size], isTrue);
  });

  testWidgets(
      'feed: the meter-fed sample reads Direct mains on the inspector line; on '
      'upfeed the assumed pump is ONE story (no mains-pressure advisory)',
      (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    loadSampleLayoutProjectTo(c.read);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MechXTheme(
        data: MechXThemeData.dark,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: SizedBox(width: 300, child: FeedStrategyLine())),
        ),
      ),
    ));
    expect(c.read(feedStrategyProvider), FeedStrategy.downfeed);
    // Was 'Roof-tank downfeed' beside 'Direct mains: no booster duty'.
    expect(find.text('Direct mains (water meter)'), findsOneWidget);
    expect(
        c.read(designIssuesProvider).any((i) => i.kind == 'mains-fed:coldWater'),
        isTrue);

    c.read(feedStrategyProvider.notifier).set(FeedStrategy.upfeed);
    await tester.pump();
    // The solve sizes an assumed pump (schedule + electrical feed) …
    expect(c.read(pumpDutyProvider), isNotNull);
    // … so the inspector and Review say it is assumed, never 'mains pressure
    // is not modelled'.
    expect(find.text('Upfeed pump (assumed, not drawn)'), findsOneWidget);
    final issues = c.read(designIssuesProvider);
    expect(issues.where((i) => i.kind == 'mains-fed:coldWater'), isEmpty);
    expect(issues.any((i) => i.kind == 'upfeed-pump-assumed:coldWater'),
        isTrue);
  });

  group('copy honesty (EN + ID)', () {
    const en = MechXStringsData(AppLocale.en);
    const id = MechXStringsData(AppLocale.id);
    test('the occupancy label is the Building input word on every surface',
        () {
      expect(en(occupancyLabelKey(Occupancy.private)), 'Residential');
      expect(id(occupancyLabelKey(Occupancy.public)), 'Kantor / publik');
      // The riser notes format the SAME label (was 'Occupancy: Private').
      expect(
          en.format(StringKey.schematicNotesOccupancy,
              {'label': en(occupancyLabelKey(Occupancy.private))}),
          'Occupancy: Residential');
    });

    test("the Sources note no longer claims 'drawing inputs only'; the empty "
        'state no longer points at a Supply phase control', () {
      for (final s in [en, id]) {
        final note = s(StringKey.electricalSourcesNote);
        expect(note.toLowerCase(), isNot(contains('drawing inputs only')));
        expect(note.toLowerCase(), isNot(contains('hanya masukan')));
        expect(s(StringKey.electricalTransformerKvaNote).toLowerCase(),
            anyOf(contains('fault'), contains('gangguan')));
      }
      expect(en(StringKey.electricalEmptyBody), isNot(contains('phase')));
      expect(en(StringKey.electricalEmptyBody), contains('1ph / 3ph'));
      expect(id(StringKey.electricalEmptyBody), isNot(contains('fasa suplai')));
    });
  });
}
