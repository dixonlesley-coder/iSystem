import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/shell/projects_screen.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/widgets/mechx_button.dart';

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

    // The three labelled groups exist (MechXSectionLabel renders UPPERCASE)...
    expect(find.text('DRAWINGS'), findsOneWidget);
    expect(find.text('REPORTS'), findsOneWidget);
    expect(find.text('DATA'), findsOneWidget);
    // ...but default COLLAPSED — their buttons aren't in the tree yet.
    expect(find.text('Export drawing (DXF)'), findsNothing);
    expect(find.text('Export calc report (MD)'), findsNothing);
    expect(find.text('Export equipment schedule (MD)'), findsNothing);

    // Expanding Drawings reveals its three rows plus the two disambiguating
    // subtitles that tell the plain plan-PDF apart from the annotated one.
    await tester.tap(find.text('DRAWINGS'));
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
}
