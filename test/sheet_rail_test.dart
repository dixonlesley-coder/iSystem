/// A5/A6 — the sheet-rail per-tile right-click context menu (Rename / Assign
/// floor / Calibrate / Replace plan / Duplicate to / Remove) and the rail's ONE
/// add affordance (the '+' tile, whose menu gates the A6 multi-file append). Verifies a secondary-tap opens the menu with the
/// expected rows and that Remove drops the tile; the store effects
/// (add/rename/remove) are exercised in `sheets_store_test`.
library;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/sheets/sheet_rail.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';

import 'test_util.dart';

Finder _inRail(Finder matching) =>
    find.descendant(of: find.byType(SheetRail), matching: matching);

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
    // A6: the new per-sheet actions.
    expect(find.text('Rename…'), findsOneWidget);
    expect(find.text('Assign floor…'), findsOneWidget);
    expect(find.text('Calibrate…'), findsOneWidget);
    expect(find.text('Remove sheet'), findsOneWidget);

    // Tapping the dismiss barrier closes it again.
    await tester.tapAt(const Offset(600, 400));
    await tester.pumpAndSettle();
    expect(find.text('Replace plan…'), findsNothing);
    expect(find.text('Duplicate to…'), findsNothing);
  });

  testWidgets('ONE add affordance: the "+" tile; its menu offers the A6 '
      'multi-file append only for a real project', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(ProviderScope(child: _host(const SheetRail())));
    final c = ProviderScope.containerOf(tester.element(find.byType(SheetRail)));
    final plus = find.byKey(const ValueKey('sheet-rail-import'));

    // Demo sheets are placeholders: the tile is the only add control, and its
    // menu offers Import plan only (goldens stay byte-identical).
    seedDemoSheets(c);
    await tester.pumpAndSettle();
    expect(plus, findsOneWidget);
    expect(_inRail(find.text('Add')), findsNothing);
    await tester.tap(plus, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Import plan…'), findsOneWidget);
    expect(find.text('Add sheets from files…'), findsNothing);
    await tester.tapAt(const Offset(600, 400));
    await tester.pumpAndSettle();

    // A real (DXF-backed) sheet: STILL one add control (no footer button), and
    // the tile's menu now carries the multi-file append.
    c.read(sheetsControllerProvider.notifier).loadSheets(
      const [Sheet(id: 'r', name: 'RealPlan', dxfPath: '/nope.dxf')],
    );
    await tester.pumpAndSettle();
    expect(plus, findsOneWidget);
    expect(_inRail(find.text('Add')), findsNothing);
    expect(_inRail(find.text('+')), findsNothing);
    await tester.tap(plus, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Import plan…'), findsOneWidget);
    expect(find.text('Add sheets from files…'), findsOneWidget);
    await tester.tapAt(const Offset(600, 400));
    await tester.pumpAndSettle();
    expect(find.text('Add sheets from files…'), findsNothing);
  });

  testWidgets('the Remove row removes the sheet from the rail (A6)',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(ProviderScope(child: _host(const SheetRail())));
    final c = ProviderScope.containerOf(tester.element(find.byType(SheetRail)));
    c.read(sheetsControllerProvider.notifier).loadSheets(
      const [
        Sheet(id: 'a', name: 'PlanA', dxfPath: '/a.dxf'),
        Sheet(id: 'b', name: 'PlanB', dxfPath: '/b.dxf'),
      ],
    );
    await tester.pumpAndSettle();

    await tester.tap(_inRail(find.text('PlanB')), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove sheet'));
    await tester.pump();

    expect(c.read(sheetsControllerProvider).sheets.map((s) => s.id), ['a']);
    expect(_inRail(find.text('PlanB')), findsNothing);
  });
}
