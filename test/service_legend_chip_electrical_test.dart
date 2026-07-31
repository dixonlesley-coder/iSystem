/// J4 — the Layout canvas's legend chip used to render NOTHING when the active
/// discipline was Electrical (`servicesFor(electrical)` is empty by design),
/// even though the canvas paints R / S / T phase colours, a feeder accent and
/// an essential-supply red there. It now keys those; and for EVERY discipline
/// it names the visible-but-GHOSTED reference layers in a muted second group,
/// so the faded geometry on screen is attributable.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/ui/layout/service_legend_chip.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';

Widget _host() => const ProviderScope(
      child: MechXTheme(
        data: MechXThemeData.dark,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: ServiceLegendChip(),
          ),
        ),
      ),
    );

ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(
      tester.element(find.byType(ServiceLegendChip)),
      listen: false,
    );

void main() {
  testWidgets('the ELECTRICAL layer keys R/S/T, feeder and essential supply',
      (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();

    // Plumbing (the default active layer) keys its services, not phases.
    expect(find.text('Phase R'), findsNothing);
    expect(find.text('Cold water'), findsOneWidget);

    _containerOf(tester)
        .read(activeDisciplineProvider.notifier)
        .set(DisciplineLayer.electrical);
    await tester.pumpAndSettle();

    expect(find.text('Phase R'), findsOneWidget);
    expect(find.text('Phase S'), findsOneWidget);
    expect(find.text('Phase T'), findsOneWidget);
    expect(find.text('Feeder'), findsOneWidget);
    expect(find.text('Essential supply'), findsOneWidget);
    // The mechanical services are no longer keyed — they aren't the active
    // layer's colours.
    expect(find.text('Cold water'), findsNothing);
  });

  testWidgets(
      'the visible-but-ghosted disciplines are named in a muted second group '
      '(and disappear as they are hidden)', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();

    // All four layers start visible; Plumbing is active, so the other three
    // are ghosted reference layers.
    expect(find.text('REFERENCE LAYERS'), findsOneWidget);
    expect(find.text('Fire'), findsOneWidget);
    expect(find.text('HVAC'), findsOneWidget);
    expect(find.text('Electrical'), findsOneWidget);
    // The ACTIVE layer is never listed as a reference layer.
    expect(find.text('Plumbing'), findsNothing);

    final container = _containerOf(tester);
    for (final l in [
      DisciplineLayer.fire,
      DisciplineLayer.hvac,
      DisciplineLayer.electrical,
    ]) {
      container.read(layerVisibilityProvider.notifier).toggle(l);
    }
    await tester.pumpAndSettle();

    // With nothing else visible the muted group is gone entirely — the chip
    // keys only what is actually on screen.
    expect(find.text('REFERENCE LAYERS'), findsNothing);
    expect(find.text('Fire'), findsNothing);
    // …but the active layer's own key stays.
    expect(find.text('Cold water'), findsOneWidget);
  });

  testWidgets('collapsing the chip hides every row but keeps the header',
      (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();
    expect(find.text('Cold water'), findsOneWidget);

    _containerOf(tester).read(serviceLegendExpandedProvider.notifier).toggle();
    await tester.pumpAndSettle();

    expect(find.text('Cold water'), findsNothing);
    expect(find.text('REFERENCE LAYERS'), findsNothing);
    expect(find.text('LEGEND'), findsOneWidget);
  });
}
