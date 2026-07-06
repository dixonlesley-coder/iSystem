/// D6 — the Loads palette used to stay fully interactive-looking on the
/// read-only Building-riser / Power-one-line electrical tabs, which have no drop
/// target. It now renders DISABLED there (dimmed + inert, with a one-line hint
/// replacing the 'Loads' header), and interactive only on the Single-line tab.
/// This test asserts the hint appears on the riser tab and that a drag from a
/// palette card is a no-op there.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/electrical/electrical_palette.dart';
import 'package:mechx/ui/widgets/palette_card.dart';

import 'test_util.dart';

void main() {
  testWidgets(
      'the Loads palette is inert on the read-only Building-riser tab: a hint '
      'replaces the header and dragging a card does nothing', (tester) async {
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

    int totalCircuits() => container
        .read(electricalProjectProvider)
        .panels
        .fold<int>(0, (n, p) => n + p.circuits.length);

    // On the Single-line tab the palette is live: the 'LOADS' header shows (the
    // MechXSectionLabel uppercases it) and the read-only hint is absent.
    expect(find.text('LOADS'), findsOneWidget);
    expect(find.text('Read-only view — switch to Single-line to edit'),
        findsNothing);

    // Switch to the read-only Building-riser projection.
    container.read(electricalTabProvider.notifier).set(ElectricalTab.riser);
    await tester.pump();

    // The header is replaced by the read-only hint; the 'LOADS' label is gone.
    expect(find.text('Read-only view — switch to Single-line to edit'),
        findsOneWidget);
    expect(find.text('LOADS'), findsNothing);

    // Dragging a (now inert) palette card is a no-op — no way is added, no throw.
    final before = totalCircuits();
    final card = find.byType(PaletteCard<PaletteLoad>).first;
    expect(card, findsOneWidget);
    // warnIfMissed:false — the card sits behind an IgnorePointer, so the drag
    // pointer intentionally misses it (that is the no-op under test).
    await tester.drag(card, const Offset(-400, 0), warnIfMissed: false);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(totalCircuits(), before,
        reason: 'a drag from a disabled palette card must not add a circuit');
  });
}
