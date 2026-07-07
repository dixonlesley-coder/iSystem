/// D4 — the per-sheet/floor rail used to render on the Riser workspace even
/// though nothing there reads the current-sheet selection (Auto/Edit always
/// render the WHOLE building across every floor): the same "not sheet-based"
/// reasoning that already omits the rail for Electrical now applies to Riser
/// too, so clicking a floor tile stops being confusing dead chrome. Layout
/// (the sheet-based canvas) keeps the rail.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/sheets/sheet_rail.dart';

import 'test_util.dart';

void main() {
  testWidgets(
      'the sheet rail is hidden on Riser but still shown on Layout',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedDemoSheets(container);
    await tester.pump();

    // Layout (the default, sheet-based view) keeps the rail.
    expect(find.byType(SheetRail), findsOneWidget);

    // Riser (schematic) always shows every floor regardless of the selected
    // sheet — the rail has no effect there, so it is omitted (mirroring the
    // Electrical workspace's existing "not sheet-based" omission).
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.schematic);
    await tester.pump();
    expect(find.byType(SheetRail), findsNothing);

    // Switching back to Layout restores it.
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.plan);
    await tester.pump();
    expect(find.byType(SheetRail), findsOneWidget);
  });
}
