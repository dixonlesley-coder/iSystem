import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/ui/layout/layer_switcher.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/network/network.dart' show ServiceType;

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

/// The switcher is QUIET at rest — the funnel reveals on hover of its layer
/// entry. Park a mouse pointer over [label]'s segment.
Future<TestGesture> _hover(WidgetTester tester, String label,
    [TestGesture? g]) async {
  final gesture =
      g ?? await tester.createGesture(kind: PointerDeviceKind.mouse);
  if (g == null) {
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
  }
  await gesture.moveTo(tester.getCenter(find.text(label)));
  await tester.pumpAndSettle();
  return gesture;
}

void main() {
  testWidgets('the funnel sits beside the ACTIVE segment, not after Electrical',
      (tester) async {
    setDesktopSurface(tester);
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(_host(c));
    await tester.pump();

    // Quiet at rest: no funnel until the active entry is hovered.
    expect(_funnel(), findsNothing);
    final g = await _hover(tester, 'Plumbing');

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
    await _hover(tester, 'HVAC', g);
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
    await _hover(tester, 'Electrical');
    expect(_funnel(), findsNothing);
  });

  testWidgets('an APPLIED service filter keeps the funnel visible without hover',
      (tester) async {
    setDesktopSurface(tester);
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(_host(c));
    await tester.pump();
    expect(_funnel(), findsNothing);
    c.read(hiddenServicesProvider.notifier).toggle(ServiceType.vent);
    await tester.pumpAndSettle();
    expect(_funnel(), findsOneWidget);
  });

  testWidgets('hover never changes the row width (concealed glyphs keep size)',
      (tester) async {
    setDesktopSurface(tester);
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(_host(c));
    await tester.pump();
    final rest = tester.getSize(find.byType(LayerSwitcher));
    final electricalRest = tester.getCenter(find.text('Electrical'));
    await _hover(tester, 'Fire');
    expect(tester.getSize(find.byType(LayerSwitcher)), rest);
    expect(tester.getCenter(find.text('Electrical')), electricalRest);
  });

  testWidgets('a hidden layer shows its eye and a locked layer its padlock '
      'without hover; keyboard focus reveals the rest', (tester) async {
    setDesktopSurface(tester);
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(_host(c));
    await tester.pump();
    // At rest: no eye, no padlock anywhere.
    expect(find.bySemanticsLabel('Show layer'), findsNothing);
    expect(find.bySemanticsLabel('Hide layer'), findsNothing);
    expect(find.bySemanticsLabel('Lock layer'), findsNothing);
    expect(find.bySemanticsLabel('Unlock layer'), findsNothing);

    c.read(layerVisibilityProvider.notifier).toggle(DisciplineLayer.fire);
    c.read(lockedDisciplinesProvider.notifier).toggle(DisciplineLayer.hvac);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Show layer'), findsOneWidget,
        reason: "a hidden layer keeps its struck eye visible");
    expect(find.bySemanticsLabel('Unlock layer'), findsOneWidget,
        reason: 'a locked layer keeps its padlock visible');

    // Keyboard focus on the Plumbing segment reveals its eye + funnel.
    Focus.of(tester.element(find.text('Plumbing'))).requestFocus();
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Hide layer'), findsOneWidget);
    expect(_funnel(), findsOneWidget);
  });
}
