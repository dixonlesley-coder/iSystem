import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/ui/layout/layer_switcher.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';

import 'test_util.dart';

/// J5 — the per-service funnel filters the ACTIVE layer, so it must render
/// BESIDE that layer's segment. It used to trail the whole row (after the
/// Electrical segment), reading as an electrical control while it filtered
/// Plumbing.
Widget _host(ProviderContainer c) => UncontrolledProviderScope(
      container: c,
      child: MediaQuery(
        data: const MediaQueryData(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MechXTheme(
            data: MechXThemeData.dark,
            child: const Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 900,
                height: 120,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: LayerSwitcher(),
                ),
              ),
            ),
          ),
        ),
      ),
    );

/// The funnel toggle, found by the semantic label its tooltip carries.
Finder _funnel() => find.bySemanticsLabel('Filter services');

void main() {
  testWidgets('the funnel sits beside the ACTIVE segment, not after Electrical',
      (tester) async {
    setDesktopSurface(tester);
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(_host(c));
    await tester.pump();

    // Plumbing is active (the first segment) — the funnel must be LEFT of the
    // trailing Electrical segment.
    expect(_funnel(), findsOneWidget);
    final funnelX = tester.getCenter(_funnel().first).dx;
    final plumbingX = tester.getCenter(find.text('Plumbing')).dx;
    final electricalX = tester.getCenter(find.text('Electrical')).dx;
    expect(funnelX, greaterThan(plumbingX));
    expect(funnelX, lessThan(electricalX),
        reason: 'the funnel must not trail the whole row');

    // Make HVAC active: the funnel travels with it (now past Fire).
    c.read(activeDisciplineProvider.notifier).set(DisciplineLayer.hvac);
    await tester.pump();
    final hvacX = tester.getCenter(find.text('HVAC')).dx;
    final fireX = tester.getCenter(find.text('Fire')).dx;
    final movedX = tester.getCenter(_funnel().first).dx;
    expect(movedX, greaterThan(hvacX));
    expect(movedX, greaterThan(fireX));
    expect(movedX, lessThan(tester.getCenter(find.text('Electrical')).dx));
  });

  testWidgets('the ELECTRICAL layer (one bucket, no services) shows no funnel',
      (tester) async {
    setDesktopSurface(tester);
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(activeDisciplineProvider.notifier).set(DisciplineLayer.electrical);
    await tester.pumpWidget(_host(c));
    await tester.pump();
    expect(_funnel(), findsNothing);
  });
}
