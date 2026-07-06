/// C1 — the standalone electrical workspace's Service & Earthing / Sources /
/// Advanced-study editors are no longer floating _AnimatedDrawerShell overlays
/// beside a static Loads column; they route through
/// electricalInspectorTargetProvider and render INLINE in the shared inspector
/// column (falling back to the palette when nothing is targeted). This test
/// drives the toolbar buttons and asserts the shared target + that the inline
/// body renders.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/electrical/electrical_palette.dart';

import 'test_util.dart';

void main() {
  testWidgets(
      'Service / Sources / Advanced open inline (shared target), Close falls '
      'back to the palette', (tester) async {
    setDesktopSurface(tester, size: const Size(1440, 900));
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

    // Nothing targeted → the Loads palette shows.
    expect(container.read(electricalInspectorTargetProvider), isNull);
    expect(find.byType(ElectricalPalette), findsOneWidget);

    // Service & Earthing → the shared target is the Service section, rendered
    // inline (the palette yields to it), and NO floating drawer scrim exists.
    await tester.tap(find.text('Service & Earthing').first);
    await tester.pump();
    expect(container.read(electricalInspectorTargetProvider),
        isA<ElectricalServiceTarget>());
    expect(find.byType(ElectricalPalette), findsNothing);
    // The earthing note field only exists in the Service body.
    expect(find.text('MEP equipment feed'), findsOneWidget);

    // Sources → target swaps to the Sources section.
    await tester.tap(find.text('Sources').first);
    await tester.pump();
    expect(container.read(electricalInspectorTargetProvider),
        isA<ElectricalSourcesTarget>());

    // The Issues button toggles the Advanced section on/off (shared target).
    await tester.tap(find.textContaining('Electrical issues').first);
    await tester.pump();
    expect(container.read(electricalInspectorTargetProvider),
        isA<ElectricalAdvancedTarget>());

    // Close the inline editor → back to the palette.
    await tester.tap(find.text('Close').first);
    await tester.pump();
    expect(container.read(electricalInspectorTargetProvider), isNull);
    expect(find.byType(ElectricalPalette), findsOneWidget);
  });
}
