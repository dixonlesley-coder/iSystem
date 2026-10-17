import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/command_store.dart';
import 'package:mechx/store/document_control_store.dart';
import 'package:mechx/store/inspector_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/ui/shell/document_control_card.dart';
import 'package:mechx/ui/shell/export_sheet.dart';
import 'package:mechx/ui/shell/projects_screen.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/widgets/mechx_button.dart';
import 'package:mechx/ui/widgets/mechx_text_field.dart';
import 'package:mechx_engine/network/network.dart';

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

Future<void> _pump(WidgetTester tester) async {
  setDesktopSurface(tester);
  await tester.pumpWidget(
    ProviderScope(
      child: MechXTheme(
        data: MechXThemeData.dark,
        // The Export sheet overlay rides beside the page (the app shell hosts
        // it at top level), so the 'All exports...' link has a sheet to open.
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(children: [ProjectsScreen(), ExportSheetOverlay()]),
        ),
      ),
    ),
  );
  await tester.pump();
}

bool _primary(WidgetTester tester, String label) =>
    tester.widget<MechXButton>(find.widgetWithText(MechXButton, label)).primary;

void main() {
  setUpAll(_loadFonts);

  testWidgets(
      'A6: New project carries the page accent; the quiet All exports... link '
      'replaces the export buttons', (tester) async {
    await _pump(tester);

    expect(_primary(tester, 'New project'), isTrue);
    expect(_primary(tester, 'All exports...'), isFalse);
  });

  testWidgets(
      'Work item 4: one-sentence lead; the template prefill is a quiet button '
      'inside the Project card, not its own card', (tester) async {
    await _pump(tester);

    expect(
        find.text('Name your project, pick a building template, and issue '
            'its drawings.'),
        findsOneWidget);
    expect(_primary(tester, 'Apply building template...'), isFalse);
    // The old standalone card + its paragraph are gone.
    expect(find.text('Apply a building template'), findsNothing);
    expect(find.text('Choose template...'), findsNothing);
  });

  testWidgets(
      'Work item 8: the deliverables buttons + Drawings/Reports/Data '
      'disclosures are gone; All exports... opens the ONE Export sheet and its '
      'rows run the same guarded export functions', (tester) async {
    await _pump(tester);

    expect(find.text('Export deliverables'), findsNothing);
    expect(find.text('Export unified MEP report (MD)'), findsNothing);
    expect(find.text('DRAWINGS (3)'), findsNothing);
    expect(find.text('REPORTS (2)'), findsNothing);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectsScreen)),
      listen: false,
    );
    // A zero-length run: every guarded export refuses BEFORE any file dialog
    // and names itself in loadError — proof the row ran that export.
    container.read(networkControllerProvider.notifier).loadNetwork(
          const Network(
            nodes: [
              NetNode(id: 'na', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
              NetNode(id: 'nb', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
            ],
            edges: [
              NetEdge(
                  id: 'e1',
                  fromId: 'na',
                  toId: 'nb',
                  service: ServiceType.coldWater),
            ],
          ),
        );
    await tester.pump();

    await tester.tap(find.text('All exports...'));
    await tester.pump();
    expect(container.read(exportSheetProvider), ExportGroup.submittal);
    // Default opening: groups collapsed, counted.
    expect(find.text('DRAWINGS (7)'), findsOneWidget);
    expect(find.text('Export annotated plan (PDF)'), findsNothing);

    await tester.tap(find.text('DRAWINGS (7)'));
    await tester.pump();
    // The two near-identical plan PDFs keep their clarifying subtitles.
    expect(find.textContaining('Plain plan — no calibrated'), findsOneWidget);
    expect(find.textContaining('Annotated plan — includes real'),
        findsOneWidget);
    await tester.tap(find.text('Export annotated plan (PDF)'));
    await tester.pump();
    await tester.pump();

    expect(container.read(exportSheetProvider), isNull,
        reason: 'running an export closes the sheet');
    final err = container.read(loadErrorProvider);
    expect(err, isNotNull);
    expect(err, contains('annotated plan PDF'));
  });

  testWidgets(
      'Document control: the always-visible Drawing no. / Revision / Client '
      'row, then a collapsed Sign-off and revisions disclosure that commits '
      'DRAWN/CHECKED/APPROVED + revision rows to the store', (tester) async {
    await _pump(tester);

    expect(find.text('Document control'), findsOneWidget);
    expect(
        find.text('Stamped on every exported drawing and report title block.'),
        findsOneWidget);
    expect(find.textContaining('Layout inspector'), findsNothing);
    expect(find.text('Drawing no.'), findsOneWidget);
    // Collapsed by default: header only.
    expect(find.text('SIGN-OFF AND REVISIONS'), findsOneWidget);
    expect(find.text('Prepared by'), findsNothing);
    // The default building's standpipe fire pump (FP-01) is tagged
    // mechanical equipment, so the collapsed model/spec disclosure shows with
    // its live count (the same gate the old inspector section used).
    expect(find.textContaining('EQUIPMENT MODEL/SPEC ('), findsOneWidget);
    expect(find.text('FP-01 · Fire standpipe pump'), findsNothing);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectsScreen)),
      listen: false,
    );
    container
        .read(sectionVisibilityProvider.notifier)
        .set(kSignOffSectionKey, true);
    await tester.pumpAndSettle();
    expect(find.text('Prepared by'), findsOneWidget);
    expect(find.text('Checked by'), findsOneWidget);
    expect(find.text('Approved by'), findsOneWidget);

    final fields = find.descendant(
        of: find.byType(DocumentControlCard),
        matching: find.byType(MechXTextField));
    // DRAWN / CHECKED / APPROVED, then the two add-revision fields.
    expect(fields, findsNWidgets(5));
    await tester.enterText(fields.at(0), 'AB');
    await tester.enterText(fields.at(2), 'CD');
    expect(container.read(documentControlProvider).preparedBy, 'AB');
    expect(container.read(documentControlProvider).approvedBy, 'CD');

    await tester.enterText(fields.at(3), '2026-10-17');
    await tester.enterText(fields.at(4), 'Issued for review');
    await tester.ensureVisible(find.text('Add revision'));
    await tester.tap(find.text('Add revision'));
    await tester.pumpAndSettle();
    final revisions = container.read(documentControlProvider).revisions;
    expect(revisions, hasLength(1));
    expect(revisions.single.description, 'Issued for review');
    expect(find.text('2026-10-17 · Issued for review'), findsOneWidget);

    // Expanding the equipment disclosure lists the tagged rows.
    container
        .read(sectionVisibilityProvider.notifier)
        .set(kEquipmentSpecSectionKey, true);
    await tester.pumpAndSettle();
    expect(find.text('FP-01 · Fire standpipe pump'), findsOneWidget);
  });
}
