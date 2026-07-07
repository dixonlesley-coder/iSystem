import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/ui/canvas/selection_overlay.dart';
import 'package:mechx/ui/layout/layer_switcher.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/network/network.dart';

import 'test_util.dart';

/// F1 (reference-layer lock) + F4 (per-service view filter): a locked layer's /
/// a hidden service's element still RENDERS but is INERT to canvas clicks. The
/// NetworkSelectionOverlay is pumped in isolation on an identity viewport, so a
/// world coordinate maps 1:1 to a screen tap.
Widget _host(ProviderContainer c, Widget child) => UncontrolledProviderScope(
      container: c,
      child: MediaQuery(
        data: const MediaQueryData(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MechXTheme(
            data: MechXThemeData.dark,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 600,
                height: 400,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  /// A cold-water (plumbing) run on s1/floor 0 with node0 at world (100, 100).
  ProviderContainer boot() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(networkControllerProvider.notifier);
    n.setTool(DrawTool.drawRun);
    n.placeRunPoint('s1', 0, const Offset(100, 100));
    n.placeRunPoint('s1', 0, const Offset(300, 100));
    n.setTool(DrawTool.select);
    return c;
  }

  String node0Of(ProviderContainer c) => c
      .read(networkControllerProvider)
      .network
      .nodes
      .firstWhere((nd) => nd.x == 100 && nd.y == 100)
      .id;

  testWidgets(
      'F1: a locked reference layer is unhittable while another is active; '
      'unlock restores', (tester) async {
    setDesktopSurface(tester);
    final c = boot();
    // Edit HVAC; plumbing is a visible coordination layer.
    c.read(activeDisciplineProvider.notifier).set(DisciplineLayer.hvac);
    await tester.pumpWidget(
        _host(c, const NetworkSelectionOverlay(sheetId: 's1', floorIndex: 0)));
    await tester.pump();
    final node0 = node0Of(c);

    // Baseline: a visible-but-inactive coordination element is STILL hittable
    // (only a LOCK makes it inert — coordination layers stay clickable today).
    await tester.tapAt(const Offset(100, 100));
    await tester.pump();
    expect(c.read(selectionProvider).nodeId, node0);
    c.read(selectionProvider.notifier).clear();
    await tester.pump();

    // Lock plumbing → the same element no longer hit-tests.
    c.read(lockedDisciplinesProvider.notifier).toggle(DisciplineLayer.plumbing);
    await tester.pump();
    await tester.tapAt(const Offset(100, 100));
    await tester.pump();
    expect(c.read(selectionProvider).isEmpty, isTrue,
        reason: "a locked layer's node must not be selectable");

    // Unlock → hittable again.
    c.read(lockedDisciplinesProvider.notifier).toggle(DisciplineLayer.plumbing);
    await tester.pump();
    await tester.tapAt(const Offset(100, 100));
    await tester.pump();
    expect(c.read(selectionProvider).nodeId, node0);
  });

  testWidgets('F4: a hidden service is removed from the canvas hit-test',
      (tester) async {
    setDesktopSurface(tester);
    final c = boot();
    // Plumbing active by default.
    await tester.pumpWidget(
        _host(c, const NetworkSelectionOverlay(sheetId: 's1', floorIndex: 0)));
    await tester.pump();
    final node0 = node0Of(c);

    // Shown → hittable.
    await tester.tapAt(const Offset(100, 100));
    await tester.pump();
    expect(c.read(selectionProvider).nodeId, node0);
    c.read(selectionProvider.notifier).clear();
    await tester.pump();

    // Hide cold water (the run's service) → inert on the canvas.
    c.read(hiddenServicesProvider.notifier).toggle(ServiceType.coldWater);
    await tester.pump();
    await tester.tapAt(const Offset(100, 100));
    await tester.pump();
    expect(c.read(selectionProvider).isEmpty, isTrue,
        reason: 'a hidden service must not hit-test');
  });

  testWidgets('the layer switcher paints the lock + filter chrome (no throw)',
      (tester) async {
    setDesktopSurface(tester);
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(_host(
      c,
      const SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: LayerSwitcher(),
      ),
    ));
    await tester.pump();
    expect(find.byType(LayerSwitcher), findsOneWidget);
    // Locking a reference layer via the store repaints the padlock in its
    // locked state; the switcher must rebuild without error.
    c.read(lockedDisciplinesProvider.notifier).toggle(DisciplineLayer.hvac);
    await tester.pump();
    expect(c.read(lockedDisciplinesProvider), {DisciplineLayer.hvac});
    expect(tester.takeException(), isNull);
  });
}
