import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/document_control_store.dart';
import 'package:mechx/store/inspector_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx/ui/widgets/mechx_text_field.dart';
import 'package:mechx_engine/network/network.dart';

import 'test_util.dart';

/// Pumps the app with the demo sheets seeded (production launches EMPTY per
/// A1; these inspector tests exercise the sheet-bearing Layout state).
Future<void> _pumpAppWithDemoSheets(WidgetTester tester) async {
  setDesktopSurface(tester);
  await tester.pumpWidget(const ProviderScope(child: MechXApp()));
  await tester.pump();
  ProviderScope.containerOf(
    tester.element(find.byType(MechXApp)),
    listen: false,
  ).read(sheetsControllerProvider.notifier).loadDemoSheets();
  await tester.pump();
}

void main() {
  testWidgets('project panel shows its sections + a building summary',
      (tester) async {
    await _pumpAppWithDemoSheets(tester);

    // inspector sections. PROJECT (name + exports) moved to the Projects page;
    // the BUILDING section is now a compact summary that opens the dedicated
    // Building page (the floor editor itself moved off the inspector).
    expect(find.text('PROJECT'), findsNothing);
    expect(find.text('BUILDING'), findsOneWidget);
    expect(find.text('SCALE'), findsOneWidget);
    // The summary readout ("11.0 m · 3 levels") and its Edit affordance.
    expect(find.textContaining('3 levels'), findsOneWidget);

    // The floor editor (rows / Add level) is no longer in the inspector.
    expect(find.text('+  Add level'), findsNothing);
  });

  testWidgets('uncalibrated sheet shows a calibration prompt', (tester) async {
    await _pumpAppWithDemoSheets(tester);
    expect(find.textContaining('Not calibrated'), findsOneWidget);
  });

  testWidgets(
      'the export gate blocks and raises loadError instead of writing when a '
      'sized edge is zero-length', (tester) async {
    setDesktopSurface(tester);

    // A capturing widget that hands us a real WidgetRef so we can invoke the
    // top-level export entry point directly (its guard returns before any
    // FilePicker call, which can't run headlessly).
    late WidgetRef capturedRef;
    await tester.pumpWidget(
      ProviderScope(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Consumer(builder: (context, ref, _) {
            capturedRef = ref;
            return const SizedBox.shrink();
          }),
        ),
      ),
    );
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(Consumer)),
      listen: false,
    );

    // Draw a single cold-water run on the UNCALIBRATED demo sheet s1 — it sizes
    // to ZERO length, so the export gate must fire.
    const nodeA = NetNode(id: 'na', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
    const nodeB = NetNode(id: 'nb', sheetId: 's1', x: 100, y: 0, floorIndex: 0);
    const edge = NetEdge(
        id: 'e1', fromId: 'na', toId: 'nb', service: ServiceType.coldWater);
    container.read(networkControllerProvider.notifier).loadNetwork(
          const Network(nodes: [nodeA, nodeB], edges: [edge]),
        );
    await tester.pump();

    // Pre-conditions: the edge is sized, the guard is hot, no error yet.
    expect(container.read(sizingProvider).containsKey('e1'), isTrue);
    expect(container.read(exportHasZeroLengthEdgesProvider), isTrue);
    expect(container.read(loadErrorProvider), isNull);

    // Invoking the export hits the guard and returns WITHOUT touching the file
    // picker; the dismissible warning banner is raised instead.
    await exportCalcReport(capturedRef);
    await tester.pump();

    final err = container.read(loadErrorProvider);
    expect(err, isNotNull);
    expect(err, contains('zero length'));
    // No success pill on a blocked export.
    expect(container.read(statusMessageProvider), isNull);
  });

  testWidgets(
      'document control section is collapsed by default and commits edits '
      'to the store', (tester) async {
    await _pumpAppWithDemoSheets(tester);

    // Collapsed by default: the header shows, the fields do not — a blank
    // launch stays canvas-focused (only the small header row is new).
    expect(find.text('DOCUMENT CONTROL'), findsOneWidget);
    expect(find.text('Document no.'), findsNothing);

    final container = ProviderScope.containerOf(
      tester.element(find.text('DOCUMENT CONTROL')),
      listen: false,
    );
    container
        .read(sectionVisibilityProvider.notifier)
        .toggle('Document control', false);
    await tester.pumpAndSettle();
    expect(find.text('Document no.'), findsOneWidget);

    // The six identity fields then the two add-revision fields, in build
    // order. Typing commits straight into the store (the setter normalizes).
    final fields = find.byType(MechXTextField);
    expect(fields, findsNWidgets(8));
    await tester.enterText(fields.at(0), 'M-101');
    await tester.enterText(fields.at(1), 'B');
    await tester.enterText(fields.at(2), 'PT Contoh');
    expect(container.read(documentControlProvider).documentNumber, 'M-101');
    expect(container.read(documentControlProvider).revisionTag, 'B');
    expect(container.read(documentControlProvider).clientName, 'PT Contoh');

    // An emptied field clears back to null (absent ⇒ row omitted downstream).
    await tester.enterText(fields.at(1), '');
    expect(container.read(documentControlProvider).revisionTag, isNull);

    // Add a revision row through the editor: date + description + Add.
    await tester.enterText(fields.at(6), '2026-07-02');
    await tester.enterText(fields.at(7), 'Issued for review');
    await tester.ensureVisible(find.text('Add revision'));
    await tester.tap(find.text('Add revision'));
    await tester.pumpAndSettle();

    final revisions = container.read(documentControlProvider).revisions;
    expect(revisions, hasLength(1));
    expect(revisions.single.date, '2026-07-02');
    expect(revisions.single.description, 'Issued for review');
    // The row renders (date · description) with a remove glyph beside it.
    expect(find.text('2026-07-02 · Issued for review'), findsOneWidget);
  });

  testWidgets(
      'Tanks master-detail expands exactly one editor at a time (H6)',
      (tester) async {
    await _pumpAppWithDemoSheets(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );

    // Two tanks on the demo sheet, named so the compact rows are distinct.
    final tanks = container.read(tankAreasProvider.notifier);
    tanks.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 200);
    tanks.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 200);
    final ids =
        container.read(tankAreasProvider).map((t) => t.id).toList();
    tanks.setName(ids[0], 'Alpha');
    tanks.setName(ids[1], 'Beta');
    await tester.pump();

    // The section renders two compact rows; NO editor is open yet, so the
    // per-item 'Depth' stepper label is absent (collapsed master-detail).
    expect(find.textContaining('Alpha ·'), findsOneWidget);
    expect(find.textContaining('Beta ·'), findsOneWidget);
    expect(find.text('Depth'), findsNothing);

    // Expand Alpha → exactly one editor (one 'Depth' stepper) appears.
    await tester.ensureVisible(find.textContaining('Alpha ·'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Alpha ·'));
    await tester.pumpAndSettle();
    expect(find.text('Depth'), findsOneWidget);

    // Expand Beta → Alpha collapses; still exactly ONE editor open.
    await tester.ensureVisible(find.textContaining('Beta ·'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Beta ·'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Depth'), findsOneWidget);

    // Tapping the open row again collapses it — back to none.
    await tester.ensureVisible(find.textContaining('Beta ·'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Beta ·'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Depth'), findsNothing);
  });
}
