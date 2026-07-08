import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/ui/canvas/segment_palette.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/network/network.dart';

/// The Drains palette group (Roof drain / Floor drain / Cleanout) belongs to the
/// GRAVITY drainage family, so it must appear only when a drainage-type service
/// is the active draw service — not while a cold/hot-water run is selected. A
/// fresh container is already the Layout view + plumbing layer, so only the draw
/// service varies here. Section headers render UPPERCASE (`MechXSectionLabel`).
Widget _host(ProviderContainer c) => UncontrolledProviderScope(
      container: c,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(400, 2400)),
          child: MechXTheme(
            data: MechXThemeData.dark,
            // Draggable palette cards need an Overlay ancestor for drag feedback.
            child: Overlay(initialEntries: [
              OverlayEntry(
                builder: (_) => Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 340,
                    height: 2400,
                    child: SingleChildScrollView(child: const SegmentPalette()),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );

void main() {
  testWidgets('cold water (pressurized) hides the Drains group; water Plant stays',
      (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // Default draw service is cold water.
    await tester.pumpWidget(_host(c));
    await tester.pump();

    expect(find.text('DRAINS'), findsNothing,
        reason: 'drains are not a pressurized-water node');
    expect(find.text('PLANT'), findsOneWidget,
        reason: 'water plant still shows for the plumbing layer');
  });

  testWidgets('selecting a drainage service reveals the Drains group',
      (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(networkControllerProvider.notifier).setService(ServiceType.drainage);
    await tester.pumpWidget(_host(c));
    await tester.pump();

    expect(find.text('DRAINS'), findsOneWidget);
    expect(find.text('Roof drain'), findsOneWidget,
        reason: 'the group defaults expanded, so its cards show');
  });

  testWidgets('the Water outlets group mirrors Drains — shown for water only',
      (tester) async {
    // Cold water (pressurized) shows Water outlets, hides Drains.
    final c1 = ProviderContainer();
    addTearDown(c1.dispose);
    await tester.pumpWidget(_host(c1));
    await tester.pump();
    expect(find.text('WATER OUTLETS'), findsOneWidget);
    expect(find.text('Water outlet'), findsOneWidget,
        reason: 'the single-item group defaults expanded');
    expect(find.text('DRAINS'), findsNothing);

    // Drainage (gravity) is the mirror: Drains shown, Water outlets hidden.
    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    c2.read(networkControllerProvider.notifier).setService(ServiceType.drainage);
    await tester.pumpWidget(_host(c2));
    await tester.pump();
    expect(find.text('WATER OUTLETS'), findsNothing);
    expect(find.text('DRAINS'), findsOneWidget);
  });

  testWidgets('rainwater + vent also show Drains; hot water hides them',
      (tester) async {
    for (final (service, shown) in <(ServiceType, bool)>[
      (ServiceType.rainwater, true),
      (ServiceType.vent, true),
      (ServiceType.hotWater, false),
    ]) {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(networkControllerProvider.notifier).setService(service);
      await tester.pumpWidget(_host(c));
      await tester.pump();
      expect(find.text('DRAINS'), shown ? findsOneWidget : findsNothing,
          reason: 'service $service should ${shown ? '' : 'not '}show drains');
    }
  });
}
