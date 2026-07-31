/// J2 (superseding D6) — the read-only electrical projections (Building riser /
/// Power one-line) have no drop target, so the inspector column used to show
/// twenty DIMMED, inert Loads cards: a whole column of affordances that do
/// nothing. It now shows the live electrical SYSTEM summary instead — the
/// counterpart of the mechanical Riser's `RiserSystemSummary`.
///
/// This test asserts the swap in both directions (palette on Single-line, the
/// summary and NO palette cards on the riser tab) and that the summary reports
/// the real solved figures.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/electrical/electrical_palette.dart';
import 'package:mechx/ui/electrical/electrical_view.dart';
import 'package:mechx/ui/widgets/palette_card.dart';

import 'test_util.dart';

void main() {
  testWidgets(
      'the read-only Building-riser tab replaces the Loads palette with the '
      'electrical system summary', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
    container
        .read(electricalProjectProvider.notifier)
        .setProject(sampleElectricalProject());
    await tester.pump();

    // On the Single-line tab the palette is the column: the 'LOADS' header
    // shows (MechXSectionLabel uppercases it) and there is no summary.
    expect(find.byType(ElectricalPalette), findsOneWidget);
    expect(find.text('LOADS'), findsOneWidget);
    expect(find.byType(ElectricalSystemSummary), findsNothing);

    // Switch to the read-only Building-riser projection.
    container.read(electricalTabProvider.notifier).set(ElectricalTab.riser);
    await tester.pumpAndSettle();

    // The palette (and every one of its cards) is GONE — not dimmed.
    expect(find.byType(ElectricalPalette), findsNothing);
    expect(find.byType(PaletteCard<PaletteLoad>), findsNothing);
    expect(find.text('LOADS'), findsNothing);

    // The system summary took its place, keyed on the solved model.
    expect(find.byType(ElectricalSystemSummary), findsOneWidget);
    expect(find.text('SYSTEM'), findsOneWidget);
    expect(find.text('Boards'), findsOneWidget);
    expect(find.text('Ways'), findsOneWidget);

    final project = container.read(electricalProjectProvider);
    final ways =
        project.panels.fold<int>(0, (n, p) => n + p.circuits.length);
    Finder inSummary(String text) => find.descendant(
          of: find.byType(ElectricalSystemSummary),
          matching: find.text(text),
        );
    expect(inSummary('${project.panels.length}'), findsOneWidget);
    expect(inSummary('$ways'), findsOneWidget);

    // The essential split reads N of M boards (the sample has no genset-backed
    // board, so it is honestly 0 — the row still states the denominator).
    expect(inSummary('0 of ${project.panels.length} boards'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('an EMPTY electrical project renders no summary on a read-only tab',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
    container.read(electricalTabProvider.notifier).set(ElectricalTab.riser);
    await tester.pumpAndSettle();

    // Data-gated: with no boards there is nothing to summarize, so the column
    // stays empty (the canvas's own empty-state card owns that moment).
    expect(find.text('SYSTEM'), findsNothing);
    expect(find.byType(PaletteCard<PaletteLoad>), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
