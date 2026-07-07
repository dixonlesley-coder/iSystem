/// C3 — the always-open 'Draw' `DisclosureSection` was the single largest
/// block in the inspector and, unlike every other content section, never
/// gated its default on real state: it always opened, burying
/// Sizing/Results/Fire/HVAC below the fold every session. It now
/// default-collapses once the network has real runs/risers (a fresh empty
/// project still opens it — the first-run path needs it), while the user's
/// own manual toggle for the session (`sectionVisibilityProvider`) always
/// wins over the default.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx_engine/network/network.dart';

import 'test_util.dart';

void main() {
  testWidgets(
      'Draw stays open on a fresh empty project, then default-collapses once '
      'the network has runs — with Results rising into view without '
      'scrolling at the golden 1440x900 surface', (tester) async {
    setDesktopSurface(tester, size: const Size(1440, 900));
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedDemoSheets(container);
    await tester.pump();

    // Fresh/empty project (the first-run path): Draw is open by default, so
    // its Ortho toggle is visible with no interaction.
    expect(find.text('Ortho'), findsOneWidget);

    // Draw a minimal real network — one sized cold-water run — the same
    // real-content trigger the Results section itself gates its default on.
    final sheet = container.read(sheetsControllerProvider).current!;
    final net = Network(nodes: [
      NetNode(id: 'na', sheetId: sheet.id, x: 0, y: 0, floorIndex: 0),
      NetNode(id: 'nb', sheetId: sheet.id, x: 200, y: 0, floorIndex: 0),
    ], edges: const [
      NetEdge(
          id: 'e1', fromId: 'na', toId: 'nb', service: ServiceType.coldWater),
    ]);
    container.read(networkControllerProvider.notifier).loadNetwork(net);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Draw now default-collapses: its detail (Ortho) is gone, but the header
    // label survives (a collapsed section is a quiet header, not removed).
    expect(find.text('Ortho'), findsNothing);
    expect(find.text('DRAW'), findsOneWidget);

    // Results rose into view with no manual scroll: at the golden surface
    // its header sits inside the visible 0..900 viewport.
    final resultsTop = tester.getTopLeft(find.text('RESULTS'));
    expect(resultsTop.dy, greaterThanOrEqualTo(0));
    expect(resultsTop.dy, lessThan(900));
  });

  testWidgets(
      'the user\'s manual re-expand of Draw survives a network being drawn '
      '(the session choice always wins over the default)', (tester) async {
    setDesktopSurface(tester, size: const Size(1440, 900));
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedDemoSheets(container);
    await tester.pump();

    final sheet = container.read(sheetsControllerProvider).current!;
    final net = Network(nodes: [
      NetNode(id: 'na', sheetId: sheet.id, x: 0, y: 0, floorIndex: 0),
      NetNode(id: 'nb', sheetId: sheet.id, x: 200, y: 0, floorIndex: 0),
    ], edges: const [
      NetEdge(
          id: 'e1', fromId: 'na', toId: 'nb', service: ServiceType.coldWater),
    ]);
    container.read(networkControllerProvider.notifier).loadNetwork(net);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Default-collapsed now the network exists.
    expect(find.text('Ortho'), findsNothing);

    // The engineer explicitly re-expands it.
    final expand = find.bySemanticsLabel('Expand Draw section');
    await tester.ensureVisible(expand);
    await tester.pump();
    await tester.tap(expand);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Ortho'), findsOneWidget);

    // Drawing another run must not silently re-collapse the section against
    // the user's explicit choice.
    final net2 = Network(nodes: [
      ...net.nodes,
      NetNode(id: 'nc', sheetId: sheet.id, x: 400, y: 0, floorIndex: 0),
    ], edges: [
      ...net.edges,
      const NetEdge(
          id: 'e2', fromId: 'nb', toId: 'nc', service: ServiceType.coldWater),
    ]);
    container.read(networkControllerProvider.notifier).loadNetwork(net2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Ortho'), findsOneWidget);
  });
}
