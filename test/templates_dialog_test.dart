/// A2 (workflow-goldens review): 'New from template' on a project that already
/// has sheets never forces the Import picker — Apply just seeds the building
/// and closes. Covers that regression-safe path (no filesystem I/O, so a
/// standard widget test); the empty-project forced-import branch reaches a
/// real OS FilePicker call and can't be driven headlessly (see the same
/// limitation noted in schematic_export_test.dart), so it is verified by code
/// inspection instead.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/templates.dart';
import 'package:mechx/ui/shell/templates_dialog.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';

import 'test_util.dart';

Widget _host(Widget child) => WidgetsApp(
      color: const Color(0xFF000000),
      pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
          PageRouteBuilder<T>(
        settings: settings,
        pageBuilder: (context, _, _) => builder(context),
      ),
      home: MechXTheme(
        data: MechXThemeData.dark,
        child: child,
      ),
    );

void main() {
  testWidgets(
      'Apply on a project that already has sheets seeds the building and '
      'closes without forcing Import', (tester) async {
    setDesktopSurface(tester);
    late BuildContext dialogContext;
    final rootKey = GlobalKey();
    await tester.pumpWidget(ProviderScope(
      child: _host(Builder(builder: (context) {
        dialogContext = context;
        return SizedBox.expand(key: rootKey);
      })),
    ));
    final c = ProviderScope.containerOf(rootKey.currentContext!);
    // A NON-empty project (sheets already loaded) — hadNoSheets is false, so
    // Apply must never reach the forced-Import branch (which would hit a real
    // FilePicker call this harness can't drive).
    seedDemoSheets(c);
    await tester.pumpAndSettle();

    expect(find.text('Apply a building template'), findsNothing);
    showTemplatesDialog(dialogContext);
    await tester.pumpAndSettle();
    expect(find.text('Apply a building template'), findsOneWidget);

    final template = kBuildingTemplates.first;
    await tester.tap(find.text('Apply').first);
    await tester.pumpAndSettle();

    // The dialog closed on its own (no forced OS picker to cancel/complete).
    expect(find.text('Apply a building template'), findsNothing);
    // The template's floor stack was genuinely applied.
    expect(c.read(projectControllerProvider).floors, template.floors);
  });
}
