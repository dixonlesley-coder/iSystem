/// C1 — the standalone electrical workspace's Supply (formerly Service &
/// Earthing + Sources) / Advanced-study editors are no longer floating
/// _AnimatedDrawerShell overlays beside a static Loads column; they route through
/// electricalInspectorTargetProvider and render INLINE in the shared inspector
/// column (falling back to the palette when nothing is targeted). This test
/// drives the toolbar buttons and asserts the shared target + that the inline
/// body renders.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/command_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/electrical/electrical_palette.dart';

import 'test_util.dart';

void main() {
  testWidgets(
      'Supply / Advanced open inline (shared target), Close falls '
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

    // ONE Supply button (the former Service & Earthing + Sources buttons are
    // merged) → the shared target is the Supply section, rendered inline (the
    // palette yields to it), and NO floating drawer scrim exists.
    expect(find.text('Service & Earthing'), findsNothing);
    expect(find.text('Sources'), findsNothing);
    await tester.tap(find.text('Supply').first);
    await tester.pumpAndSettle();
    expect(container.read(electricalInspectorTargetProvider),
        isA<ElectricalSupplyTarget>());
    expect(find.byType(ElectricalPalette), findsNothing);

    // The four disclosures, in decision order.
    for (final h in ['UTILITY', 'EARTHING', 'BACKUP & ON-SITE', 'ADVANCED']) {
      expect(find.text(h), findsOneWidget, reason: h);
    }
    // Utility + Earthing expanded: every former Service / Sources field is
    // still present.
    expect(find.text('Source'), findsOneWidget);
    expect(find.text('Connection capacity (VA)'), findsOneWidget);
    expect(find.text('Transformer (kVA, 0 = auto)'), findsOneWidget);
    expect(find.text('Dual transformer (split bus)'), findsOneWidget);
    expect(find.text('Earthing system'), findsOneWidget);
    // The sample carries no sources → Backup & on-site starts collapsed.
    expect(find.text('Genset present'), findsNothing);
    // Advanced is COLLAPSED by default.
    expect(find.text('Origin fault level (kA, 0 = auto)'), findsNothing);
    expect(find.text('Busbar clearing time (s, 0 = auto)'), findsNothing);
    expect(find.text('MEP equipment feed'), findsNothing);

    // Expanding the two closed sections discloses the rest.
    await tester.ensureVisible(find.text('BACKUP & ON-SITE'));
    await tester.tap(find.text('BACKUP & ON-SITE'));
    await tester.pumpAndSettle();
    expect(find.text('Genset present'), findsOneWidget);
    expect(find.text('Capacitor bank (kvar, 0 = none)'), findsOneWidget);
    expect(find.text('Solar PV present'), findsOneWidget);
    expect(find.text('Battery present'), findsOneWidget);
    await tester.ensureVisible(find.text('ADVANCED'));
    await tester.tap(find.text('ADVANCED'));
    await tester.pumpAndSettle();
    expect(find.text('Origin fault level (kA, 0 = auto)'), findsOneWidget);
    expect(find.text('Busbar clearing time (s, 0 = auto)'), findsOneWidget);
    expect(find.text('MEP equipment feed'), findsOneWidget);

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

  testWidgets(
      'palette: the former Service & Earthing / Sources titles still find '
      'the merged Supply command', (tester) async {
    setDesktopSurface(tester, size: const Size(1440, 900));
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    for (final query in ['Service & Earthing', 'Sources']) {
      container.read(electricalInspectorTargetProvider.notifier).clear();
      container.read(commandPaletteOpenProvider.notifier).open();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.enterText(find.byType(EditableText), query);
      await tester.pump();
      expect(find.text('Edit electrical supply'), findsOneWidget,
          reason: query);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(container.read(workspaceViewProvider), WorkspaceView.electrical);
      expect(container.read(electricalInspectorTargetProvider),
          isA<ElectricalSupplyTarget>(),
          reason: query);
    }
  });
}
