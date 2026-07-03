/// H3 — the electrical exports route through the SHARED export guard
/// (`runExportGuarded` in `ui/inspector/project_panel.dart`): the zero-length
/// completeness gate blocks-and-warns BEFORE any file dialog, and the two
/// power-one-line exports explain a no-sources refusal via the status pill
/// instead of silently no-oping. (The cancel-⇒-no-pill and success-pill legs
/// live in the guard itself and can't run headless — no OS file picker — so
/// these tests pin the two legs that never reach the picker.)
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/command_store.dart' show reportExportedProvider;
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/ui/electrical/electrical_export.dart';
import 'package:mechx_engine/network/network.dart';

void main() {
  /// Pump a minimal ProviderScope and capture a live [WidgetRef] + its
  /// container (the export helpers take a WidgetRef) — the same harness as
  /// `export_wiring_test.dart`.
  Future<(WidgetRef, ProviderContainer)> harness(WidgetTester tester) async {
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
    return (capturedRef, container);
  }

  testWidgets(
      'an electrical export is blocked by the shared zero-length gate '
      '(loadError raised, nothing written, no success pill)', (tester) async {
    final (ref, container) = await harness(tester);
    container
        .read(electricalProjectProvider.notifier)
        .setProject(sampleElectricalProject());
    // A run on the UNCALIBRATED demo sheet sizes to ZERO length — the shared
    // export gate must fire before any file dialog.
    const net = Network(nodes: [
      NetNode(id: 'na', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
      NetNode(id: 'nb', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
    ], edges: [
      NetEdge(
          id: 'e1', fromId: 'na', toId: 'nb', service: ServiceType.coldWater),
    ]);
    container.read(networkControllerProvider.notifier).loadNetwork(net);
    await tester.pump();
    expect(container.read(loadErrorProvider), isNull);

    await exportElectricalCalcReport(ref);
    await tester.pump();

    final err = container.read(loadErrorProvider);
    expect(err, isNotNull);
    expect(err, contains('zero length'));
    expect(err, contains('electrical calc report'));
    expect(container.read(statusMessageProvider), isNull);
    // A blocked export earns no Report-stage credit.
    expect(container.read(reportExportedProvider), isFalse);
  });

  testWidgets(
      'the power one-line exports explain a no-sources refusal via the status '
      'pill instead of silently no-oping (DXF + PDF)', (tester) async {
    final (ref, container) = await harness(tester);
    // A fresh (empty) project carries no energy sources ⇒ no power one-line.
    expect(container.read(electricalAdvancedProvider).powerOneLine, isNull);

    await exportPowerOneLineDxf(ref);
    await tester.pump();
    expect(container.read(statusMessageProvider), kNoEnergySourcesMessage);
    // A refusal is an explanation, not an error — and never a success.
    expect(container.read(loadErrorProvider), isNull);
    expect(container.read(reportExportedProvider), isFalse);

    container.read(statusMessageProvider.notifier).clear();
    await exportPowerOneLinePdf(ref);
    await tester.pump();
    expect(container.read(statusMessageProvider), kNoEnergySourcesMessage);
    expect(container.read(loadErrorProvider), isNull);
    expect(container.read(reportExportedProvider), isFalse);

    // Cancel the pill's self-clear timer so the test ends timer-clean.
    container.read(statusMessageProvider.notifier).clear();
  });
}
