/// A5 — the Import "Add vs Replace" chooser shown when a plan is imported into a
/// NON-EMPTY project. Drives the real [showImportChoiceDialog] and asserts each
/// button (and a barrier dismiss) resolves the future to the right choice.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/shell/import_choice_dialog.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';

import 'test_util.dart';

/// The minimal Navigator/Overlay ancestry `showGeneralDialog` needs, under the
/// app's [MechXTheme] (the dialog reads `MechXTheme.of`).
Widget _host(Widget home) => MechXTheme(
      data: MechXThemeData.dark,
      child: WidgetsApp(
        color: const Color(0xFF000000),
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (context, _, _) => builder(context),
        ),
        home: home,
      ),
    );

/// Pumps the host, opens the chooser, and returns a getter for the resolved
/// choice (set once the future completes).
Future<ImportChoice? Function()> _open(
  WidgetTester tester, {
  int existingSheets = 3,
  int incomingSheets = 2,
}) async {
  ImportChoice? result;
  var done = false;
  await tester.pumpWidget(_host(Builder(builder: (context) {
    return GestureDetector(
      onTap: () async {
        result = await showImportChoiceDialog(
          context,
          existingSheets: existingSheets,
          incomingSheets: incomingSheets,
        );
        done = true;
      },
      child: const Text('open', textDirection: TextDirection.ltr),
    );
  })));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return () => done ? result : null;
}

void main() {
  testWidgets('the chooser renders its title + both actions', (tester) async {
    setDesktopSurface(tester);
    await _open(tester);
    expect(find.text('Add or replace sheets?'), findsOneWidget);
    expect(find.text('Add to project'), findsOneWidget);
    expect(find.text('Replace all sheets'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('"Add to project" resolves to ImportChoice.add', (tester) async {
    setDesktopSurface(tester);
    final choice = await _open(tester);
    await tester.tap(find.text('Add to project'));
    await tester.pumpAndSettle();
    expect(choice(), ImportChoice.add);
  });

  testWidgets('"Replace all sheets" resolves to ImportChoice.replace',
      (tester) async {
    setDesktopSurface(tester);
    final choice = await _open(tester);
    await tester.tap(find.text('Replace all sheets'));
    await tester.pumpAndSettle();
    expect(choice(), ImportChoice.replace);
  });

  testWidgets('"Cancel" resolves to null (import kept off)', (tester) async {
    setDesktopSurface(tester);
    final choice = await _open(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(choice(), isNull);
  });

  testWidgets('a barrier tap dismisses to null', (tester) async {
    setDesktopSurface(tester);
    final choice = await _open(tester);
    // Tap the scrim in a corner, clear of the centred card.
    await tester.tapAt(const Offset(6, 6));
    await tester.pumpAndSettle();
    expect(choice(), isNull);
    expect(find.text('Add or replace sheets?'), findsNothing);
  });
}
