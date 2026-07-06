import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sample_project.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx_engine/network/network.dart';

import 'test_util.dart';

ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );

void main() {
  testWidgets(
      'A1: tapping "Load sample project" on the cold-launch Layout empty '
      'state seeds a sheet + a sized cold-water/drainage network, undoably',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final c = _containerOf(tester);
    expect(c.read(sheetsControllerProvider).isEmpty, isTrue);

    // The first-run orientation card pushes the empty-state actions below the
    // fold on the test surface — scroll it into view before tapping.
    await tester.ensureVisible(find.text('Load sample project'));
    await tester.tap(find.text('Load sample project'));
    await tester.pump();

    // The placeholder sheet exists.
    final sheets = c.read(sheetsControllerProvider);
    expect(sheets.sheets, hasLength(1));
    expect(sheets.sheets.single.id, kSampleSheetId);

    // The tiny cold-water + drainage network exists (meter -> lavatory ->
    // drain, the lavatory shared by both services).
    final net = c.read(networkControllerProvider).network;
    expect(net.nodes, hasLength(3));
    expect(net.edges, hasLength(2));
    expect(
      net.edges.map((e) => e.service).toSet(),
      {ServiceType.coldWater, ServiceType.drainage},
    );

    // Sizing ran automatically — sizingProvider is a live derived provider
    // over the network + calibration + floors, nothing here precomputes it.
    final sizes = c.read(sizingProvider);
    expect(sizes.length, 2);

    // The whole seed rode the ordinary undo timeline: undo reverts the
    // most-recent step (the drainage run), exactly like any hand-drawn edit.
    expect(c.read(historyProvider.notifier).canUndo, isTrue);
    c.read(historyProvider.notifier).undo();
    final afterUndo = c.read(networkControllerProvider).network;
    expect(afterUndo.edges, hasLength(1));
    expect(afterUndo.edges.single.service, ServiceType.coldWater);
  });
}
