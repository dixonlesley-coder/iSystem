import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/canvas/network_layer.dart';
import 'package:mechx/ui/electrical/electrical_palette.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx/ui/layout/layout_canvas.dart';
import 'package:mechx/ui/layout/layer_switcher.dart';
import 'package:mechx/ui/shell/nav_rail.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/network/network.dart';

import 'test_util.dart';

/// The unified Layout canvas: the shared PDF with plumbing · HVAC · electrical
/// layers, a working active-layer switcher + visibility toggles + fading.
Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final sans = FontLoader('Roboto')
    ..addFont(bytes('assets/fonts/Roboto-Regular.ttf'))
    ..addFont(bytes('assets/fonts/Roboto-Medium.ttf'));
  await sans.load();
  final mono = FontLoader('Roboto Mono')
    ..addFont(bytes('assets/fonts/RobotoMono-Regular.ttf'));
  await mono.load();
}

ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );

void main() {
  setUpAll(_loadFonts);

  testWidgets('the Layout design view renders the unified canvas + switcher',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    // Default boot is the Layout design view.
    final c = _containerOf(tester);
    expect(c.read(workspaceViewProvider), WorkspaceView.plan);
    expect(find.byType(LayoutCanvas), findsOneWidget);
    expect(find.byType(LayerSwitcher), findsOneWidget);
    // The system layers offered (in the switcher) + the mechanical network.
    expect(find.descendant(
        of: find.byType(LayerSwitcher), matching: find.text('Plumbing')),
        findsOneWidget);
    expect(find.descendant(
        of: find.byType(LayerSwitcher), matching: find.text('HVAC')),
        findsOneWidget);
    expect(find.descendant(
        of: find.byType(LayerSwitcher), matching: find.text('Electrical')),
        findsOneWidget);
    expect(find.byType(NetworkLayer), findsWidgets);
  });

  testWidgets('a mechanical layer is active: the DRAW inspector is shown',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final c = _containerOf(tester);
    expect(c.read(activeDisciplineProvider), DisciplineLayer.plumbing);
    // The mechanical project inspector (with its DRAW section) is the right pane.
    expect(find.byType(ProjectPanel), findsOneWidget);
    expect(find.text('DRAW'), findsOneWidget);
    // The electrical Loads palette is NOT mounted while a mechanical layer edits.
    expect(find.byType(ElectricalPalette), findsNothing);
  });

  testWidgets('DRAW service chips scope to the active discipline', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final c = _containerOf(tester);
    // Plumbing active → plumbing services show (in the DRAW chips AND the node
    // palette), air services do not. Both surfaces scope to the active layer.
    expect(find.text('Cold water'), findsWidgets);
    expect(find.text('Supply air'), findsNothing);

    // Switch the active layer to HVAC → the air services replace the plumbing.
    c.read(activeDisciplineProvider.notifier).set(DisciplineLayer.hvac);
    await tester.pump();
    expect(find.text('Supply air'), findsWidgets);
    expect(find.text('Cold water'), findsNothing);
    // The draw service followed the active discipline (an air service now).
    expect(c.read(networkControllerProvider).service.isAir, isTrue);
  });

  testWidgets('Electrical active: the Loads palette replaces the DRAW inspector',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final c = _containerOf(tester);
    c.read(activeDisciplineProvider.notifier).set(DisciplineLayer.electrical);
    await tester.pump();

    // The electrical Loads palette is the active-layer toolset; the mechanical
    // DRAW inspector is gone.
    expect(find.byType(ElectricalPalette), findsOneWidget);
    expect(find.byType(ProjectPanel), findsNothing);
    expect(find.text('DRAW'), findsNothing);
  });

  testWidgets('placed electrical panel: drawn when its layer is visible, '
      'hidden when toggled off', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final c = _containerOf(tester);
    // Place the sample MDP on the active sheet/floor.
    c.read(electricalProjectProvider.notifier).setPanelLayoutPos(
        'mdp', const LayoutPos(sheetId: 's1', floorIndex: 0, x: 400, y: 300));
    // Electrical active so its marker is crisp + the layer drawn.
    c.read(activeDisciplineProvider.notifier).set(DisciplineLayer.electrical);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('MDP'), findsWidgets);

    // Make a mechanical layer active (electrical becomes a faded layer) — still
    // drawn for coordination.
    c.read(activeDisciplineProvider.notifier).set(DisciplineLayer.plumbing);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('MDP'), findsWidgets);

    // Toggle the electrical layer OFF → its marker is removed entirely.
    c
        .read(layerVisibilityProvider.notifier)
        .toggle(DisciplineLayer.electrical);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('MDP'), findsNothing);
  });

  testWidgets('one shared viewport: the mechanical + electrical layers ride the '
      'same per-sheet transform', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    await tester.pump(); // post-frame fit emits the viewport

    final c = _containerOf(tester);
    final sheet = c.read(sheetsControllerProvider).current!;
    // The unified canvas drives the per-sheet viewport (so the electrical layer,
    // which reads the same provider, shares the pan/zoom).
    expect(c.read(sheetsControllerProvider).viewportFor(sheet.id), isNotNull);
  });

  testWidgets('the rail item is "Layout" and routes to the unified canvas',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    // Navigate away and back via the relabelled rail item.
    final c = _containerOf(tester);
    await tester.tap(find.descendant(
        of: find.byType(NavRail), matching: find.text('Riser SLD')));
    await tester.pump();
    expect(find.byType(LayoutCanvas), findsNothing);

    await tester.tap(find.descendant(
        of: find.byType(NavRail), matching: find.text('Layout')));
    await tester.pump();
    expect(c.read(workspaceViewProvider), WorkspaceView.plan);
    expect(find.byType(LayoutCanvas), findsOneWidget);
  });
}
