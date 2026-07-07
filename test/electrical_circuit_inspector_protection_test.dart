/// H2/H3 — verifies the circuit editor's new compact read-only "Protection"
/// line (breaker + RCD, matching the board schedule) actually renders for a
/// way that carries a real RCD requirement.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';

import 'test_util.dart';

void main() {
  testWidgets(
      'the circuit editor shows a Protection line with the RCD figure the '
      'board schedule prints for the same way', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    container
        .read(workspaceViewProvider.notifier)
        .set(WorkspaceView.electrical);
    container
        .read(electricalProjectProvider.notifier)
        .setProject(sampleElectricalProject());
    await tester.pump();

    // 'lp1-c3' (Socket outlets on LP-1) is a known RCD-protected way in the
    // sample project: 30 mA, type A (matches the N10 finding's own evidence —
    // "30 mA A" RCDs on LP-1 socket ways).
    container
        .read(electricalInspectorTargetProvider.notifier)
        .editCircuit('lp1', 'lp1-c3');
    await tester.pumpAndSettle();

    expect(find.textContaining('· RCD 30mA A'), findsOneWidget,
        reason: 'the circuit editor must surface the same RCD figure the '
            'board schedule prints for this way (H2)');
  });

  testWidgets(
      'a way with no RCD requirement shows a Protection line with no RCD '
      'token', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    container
        .read(workspaceViewProvider.notifier)
        .set(WorkspaceView.electrical);
    container
        .read(electricalProjectProvider.notifier)
        .setProject(sampleElectricalProject());
    await tester.pump();

    // 'lp1-c1' (Lighting - Level 1) carries no RCD requirement.
    container
        .read(electricalInspectorTargetProvider.notifier)
        .editCircuit('lp1', 'lp1-c1');
    await tester.pumpAndSettle();

    // No RCD TOKEN on the protection line (distinct from the unrelated
    // "Life-safety (no RCD)" toggle label elsewhere in the same editor, which
    // legitimately contains the bare word "RCD").
    expect(find.textContaining('· RCD'), findsNothing);
    // Still shows the breaker + Icu notation (the line isn't dropped
    // entirely) — the schedule notation form, distinct from the panel
    // summary card's own differently-formatted incomer stat ('MCB 25/2P')
    // which may also be present in the widget tree behind the drawer.
    expect(find.textContaining('· Icu'), findsOneWidget);
  });
}
