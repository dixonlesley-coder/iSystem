import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx_engine/network/network.dart';

import 'test_util.dart';

void main() {
  testWidgets('project panel shows its sections + a building summary',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    // inspector sections. PROJECT (name + exports) moved to the Projects page;
    // the BUILDING section is now a compact summary that opens the dedicated
    // Building page (the floor editor itself moved off the inspector).
    expect(find.text('PROJECT'), findsNothing);
    expect(find.text('BUILDING'), findsOneWidget);
    expect(find.text('SCALE'), findsOneWidget);
    // The summary readout ("11.0 m · 3 levels") and its Edit affordance.
    expect(find.textContaining('3 levels'), findsOneWidget);

    // The floor editor (rows / Add level) is no longer in the inspector.
    expect(find.text('+  Add level'), findsNothing);
  });

  testWidgets('uncalibrated sheet shows a calibration prompt', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    expect(find.textContaining('Not calibrated'), findsOneWidget);
  });

  testWidgets(
      'the export gate blocks and raises loadError instead of writing when a '
      'sized edge is zero-length', (tester) async {
    setDesktopSurface(tester);

    // A capturing widget that hands us a real WidgetRef so we can invoke the
    // top-level export entry point directly (its guard returns before any
    // FilePicker call, which can't run headlessly).
    late WidgetRef capturedRef;
    await tester.pumpWidget(
      ProviderScope(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Consumer(builder: (context, ref, _) {
            capturedRef = ref;
            return const SizedBox.shrink();
          }),
        ),
      ),
    );
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(Consumer)),
      listen: false,
    );

    // Draw a single cold-water run on the UNCALIBRATED demo sheet s1 — it sizes
    // to ZERO length, so the export gate must fire.
    const nodeA = NetNode(id: 'na', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
    const nodeB = NetNode(id: 'nb', sheetId: 's1', x: 100, y: 0, floorIndex: 0);
    const edge = NetEdge(
        id: 'e1', fromId: 'na', toId: 'nb', service: ServiceType.coldWater);
    container.read(networkControllerProvider.notifier).loadNetwork(
          const Network(nodes: [nodeA, nodeB], edges: [edge]),
        );
    await tester.pump();

    // Pre-conditions: the edge is sized, the guard is hot, no error yet.
    expect(container.read(sizingProvider).containsKey('e1'), isTrue);
    expect(container.read(exportHasZeroLengthEdgesProvider), isTrue);
    expect(container.read(loadErrorProvider), isNull);

    // Invoking the export hits the guard and returns WITHOUT touching the file
    // picker; the dismissible warning banner is raised instead.
    await exportCalcReport(capturedRef);
    await tester.pump();

    final err = container.read(loadErrorProvider);
    expect(err, isNotNull);
    expect(err, contains('zero length'));
    // No success pill on a blocked export.
    expect(container.read(statusMessageProvider), isNull);
  });
}
