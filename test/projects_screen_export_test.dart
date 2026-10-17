import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/document_control_store.dart';
import 'package:mechx/store/inspector_store.dart';
import 'package:mechx/ui/shell/document_control_card.dart';
import 'package:mechx/ui/shell/projects_screen.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/widgets/mechx_button.dart';
import 'package:mechx/ui/widgets/mechx_text_field.dart';

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
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: ProjectsScreen(),
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
      'A6: New project carries the accent, Export submittal package does not',
      (tester) async {
    await _pump(tester);

    expect(_primary(tester, 'New project'), isTrue);
    expect(_primary(tester, 'Export submittal package...'), isFalse);
  });

  testWidgets(
      'A5: a leading Export deliverables group is always visible; the '
      'per-artifact rows are grouped under collapsed Drawings/Reports/Data '
      'disclosures', (tester) async {
    await _pump(tester);

    // The primary group — always visible, never behind a disclosure.
    expect(find.text('Export deliverables'), findsOneWidget);
    expect(find.text('Export submittal package...'), findsOneWidget);
    expect(find.text('Export unified MEP report (MD)'), findsOneWidget);
    expect(find.text('Export unified MEP report (PDF)'), findsOneWidget);

    // The three labelled groups exist (MechXSectionLabel renders UPPERCASE),
    // each header naming its own inventory count (P1) — 3 drawing exports, 2
    // report exports, 2 data exports.
    expect(find.text('DRAWINGS (3)'), findsOneWidget);
    expect(find.text('REPORTS (2)'), findsOneWidget);
    expect(find.text('DATA (2)'), findsOneWidget);
    // ...but default COLLAPSED — their buttons aren't in the tree yet.
    expect(find.text('Export drawing (DXF)'), findsNothing);
    expect(find.text('Export calc report (MD)'), findsNothing);
    expect(find.text('Export equipment schedule (MD)'), findsNothing);

    // Expanding Drawings reveals its three rows plus the two disambiguating
    // subtitles that tell the plain plan-PDF apart from the annotated one.
    await tester.tap(find.text('DRAWINGS (3)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Export drawing (DXF)'), findsOneWidget);
    expect(find.text('Export drawing (PDF)'), findsOneWidget);
    expect(find.text('Export annotated plan (PDF)'), findsOneWidget);
    expect(
        find.textContaining('Plain plan — no calibrated'), findsOneWidget);
    expect(find.textContaining('Annotated plan — includes real'),
        findsOneWidget);
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
