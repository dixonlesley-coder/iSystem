/// C2 — the inspector's selection auto-scroll-to-top used to guard on the
/// PREVIOUS selection being empty, so only the very first empty→non-empty pick
/// ever jumped: clicking through several elements in sequence while the panel
/// was scrolled to Results/Fire/HVAC left the Selection editor silently
/// updating out of view. Any CHANGE of selection identity should now scroll
/// the panel back to the top whenever it is actually scrolled away.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/inspector_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart';

import 'test_util.dart';

void main() {
  testWidgets(
      'selecting a DIFFERENT element while the panel is scrolled away jumps '
      'it back to the top', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedDemoSheets(container);
    await tester.pump();

    final sheet = container.read(sheetsControllerProvider).current!;
    final netCtrl = container.read(networkControllerProvider.notifier);
    netCtrl.addFitting(sheet.id, 0, const Offset(120, 120));
    netCtrl.addFitting(sheet.id, 0, const Offset(320, 320));
    await tester.pump();

    final ids =
        container.read(networkControllerProvider).network.nodes.map((n) => n.id).toList();
    expect(ids.length, greaterThanOrEqualTo(2));

    final scrollFinder = find.descendant(
      of: find.byType(ProjectPanel),
      matching: find.byType(SingleChildScrollView),
    );
    expect(scrollFinder, findsOneWidget);
    ScrollController controller() =>
        tester.widget<SingleChildScrollView>(scrollFinder).controller!;

    // Select the first node (the panel is at rest/top; this jump — if any —
    // is a no-op).
    container.read(selectionProvider.notifier).selectNode(ids[0]);
    await tester.pump();

    // Expand the tall Draw palette so the panel genuinely overflows the
    // viewport (two project sections were later removed from the inspector, so a
    // bare 2-fitting network no longer overflows on its own).
    container.read(sectionVisibilityProvider.notifier).set('Draw', true);
    await tester.pump();

    // Scroll the inspector away from the top, as if the engineer had
    // navigated down to read Results/Fire/HVAC.
    await tester.drag(scrollFinder, const Offset(0, -400));
    await tester.pump();
    final scrolledAway = controller().offset;
    expect(scrolledAway, greaterThan(0),
        reason: 'the panel must be genuinely scrolled away for this test');

    // Select a DIFFERENT element while scrolled away — the exact regression:
    // the OLD guard (previous selection must be empty) never fired here.
    container.read(selectionProvider.notifier).selectNode(ids[1]);
    await tester.pump();

    expect(controller().offset, 0,
        reason: 'a selection change should scroll the pinned editor back '
            'into view even when the previous selection was non-empty');
  });
}
