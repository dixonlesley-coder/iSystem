/// A5 — the sheet-rail per-tile right-click context menu that surfaces the
/// "Replace plan…" plan-revision action. Verifies a secondary-tap on a tile
/// opens the menu (the picker it then launches is exercised via the store's
/// `replaceSheetSource` in sheets_store_test).
library;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/sheets/sheet_rail.dart';
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
        child: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(height: 700, child: child),
        ),
      ),
    );

void main() {
  testWidgets('right-clicking a sheet tile opens the "Replace plan…" menu',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: SizedBox()));
    await tester.pumpWidget(ProviderScope(child: _host(const SheetRail())));
    final c = ProviderScope.containerOf(tester.element(find.byType(SheetRail)));
    seedDemoSheets(c);
    await tester.pumpAndSettle();

    // No menu at rest.
    expect(find.text('Replace plan…'), findsNothing);

    // Secondary-tap the first tile (its full name is the Text data).
    await tester.tap(find.text('Ground Floor'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('Replace plan…'), findsOneWidget);
    // E4: the per-sheet menu also offers duplicating the floor's runs.
    expect(find.text('Duplicate to…'), findsOneWidget);

    // Tapping the dismiss barrier closes it again.
    await tester.tapAt(const Offset(600, 400));
    await tester.pumpAndSettle();
    expect(find.text('Replace plan…'), findsNothing);
    expect(find.text('Duplicate to…'), findsNothing);
  });
}
