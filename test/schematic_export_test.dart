/// Tests for `ui/schematic/schematic_export.dart` — the H3 export guard on the
/// SINGLE-sheet riser PDF/DXF exports (their sibling set exports were already
/// guarded) and the F9 honest '(roof tank)' feed line in the exported
/// KETERANGAN system notes.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/command_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/ui/schematic/schematic_export.dart';
import 'package:mechx/ui/shell/export_sheet.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/units.dart';

/// Pumps a minimal tree that hands back a real [WidgetRef] (the export entry
/// points take one) + the scope's container.
Future<(WidgetRef, ProviderContainer)> _pumpRef(WidgetTester tester,
    {List<Override> overrides = const []}) async {
  late WidgetRef capturedRef;
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
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

/// A single horizontal cold-water run on an UNCALIBRATED sheet — it sizes to
/// ZERO length, so the shared export guard must fire.
const _zeroLengthNetwork = Network(
  nodes: [
    NetNode(id: 'na', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
    NetNode(id: 'nb', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
  ],
  edges: [
    NetEdge(id: 'e1', fromId: 'na', toId: 'nb', service: ServiceType.coldWater),
  ],
);

/// A two-floor cold-water riser (§10 elevation delta ⇒ positive length even
/// uncalibrated), optionally carrying a roof tank at the top.
Network _riserNetwork({required bool roofTank}) => Network(
      nodes: [
        const NetNode(id: 'lo', sheetId: 's1', x: 200, y: 0, floorIndex: 0),
        NetNode(
          id: 'hi',
          sheetId: 's1',
          x: 200,
          y: 0,
          floorIndex: 1,
          component: roofTank ? NodeComponent.roofTank : null,
        ),
      ],
      edges: const [
        NetEdge(
          id: 'r1',
          fromId: 'lo',
          toId: 'hi',
          service: ServiceType.coldWater,
          kind: EdgeKind.riser,
        ),
      ],
    );

void main() {
  testWidgets(
      'H3: the single-sheet riser PDF export is guarded — zero-length geometry '
      'raises loadError and writes nothing', (tester) async {
    final (ref, container) = await _pumpRef(tester);
    container
        .read(networkControllerProvider.notifier)
        .loadNetwork(_zeroLengthNetwork);
    await tester.pump();

    // The guard returns BEFORE any FilePicker call (which can't run headlessly
    // — an unguarded export would surface as a 'Could not export' error here).
    await exportMechanicalRiserPdf(ref, null);
    await tester.pump();

    final err = container.read(loadErrorProvider);
    expect(err, isNotNull);
    expect(err, contains('zero length'));
    expect(err, contains('riser single-line (PDF)'));
    expect(container.read(statusMessageProvider), isNull);
  });

  testWidgets(
      'Work item 8: the riser exports are reached through the ONE Export '
      "sheet's Drawings group and run the same guarded functions",
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MechXTheme(
          data: MechXThemeData.dark,
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: Stack(children: [ExportSheetOverlay()]),
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ExportSheetOverlay)),
      listen: false,
    );
    container
        .read(networkControllerProvider.notifier)
        .loadNetwork(_zeroLengthNetwork);
    for (final (sub, name) in const [
      ('PDF (vector)', 'riser single-line (PDF)'),
      ('DXF (CAD)', 'riser single-line (DXF)'),
    ]) {
      container.read(loadErrorProvider.notifier).clear();
      // The Riser toolbar's opener: Drawings pre-expanded.
      container.read(exportSheetProvider.notifier).open(ExportGroup.drawings);
      await tester.pump();
      final row = find.ancestor(
        of: find.text(sub),
        matching: find.ancestor(
            of: find.text('Riser single-line'),
            matching: find.byType(Row)),
      );
      await tester.tap(row.first);
      await tester.pump();
      await tester.pump();
      expect(container.read(exportSheetProvider), isNull);
      expect(container.read(loadErrorProvider), contains(name));
    }
  });

  testWidgets(
      'H3: the single-sheet riser DXF export is guarded the same way',
      (tester) async {
    final (ref, container) = await _pumpRef(tester);
    container
        .read(networkControllerProvider.notifier)
        .loadNetwork(_zeroLengthNetwork);
    await tester.pump();

    await exportMechanicalRiserDxf(ref, null);
    await tester.pump();

    final err = container.read(loadErrorProvider);
    expect(err, isNotNull);
    expect(err, contains('zero length'));
    expect(err, contains('riser single-line (DXF)'));
    expect(container.read(statusMessageProvider), isNull);
  });

  testWidgets(
      "F9: the exported KETERANGAN notes claim '(roof tank)' ONLY when a "
      'roofTank node exists', (tester) async {
    final (ref, container) = await _pumpRef(tester);
    // Default feed strategy is gravity downfeed — the case F9 corrects.
    expect(container.read(feedStrategyProvider), FeedStrategy.downfeed);

    // Tankless downfeed network: the feed note must NOT assert a roof tank.
    container
        .read(networkControllerProvider.notifier)
        .loadNetwork(_riserNetwork(roofTank: false));
    await tester.pump();
    var labels = buildLiveRiserSheet(ref, null)
        .prims
        .whereType<SldLabel>()
        .map((l) => l.text)
        .toList();
    expect(labels, contains('Feed: gravity downfeed'));
    expect(labels.any((t) => t.contains('(roof tank)')), isFalse);

    // With a real roofTank node the honest suffix returns.
    container
        .read(networkControllerProvider.notifier)
        .loadNetwork(_riserNetwork(roofTank: true));
    await tester.pump();
    labels = buildLiveRiserSheet(ref, null)
        .prims
        .whereType<SldLabel>()
        .map((l) => l.text)
        .toList();
    expect(labels, contains('Feed: gravity downfeed (roof tank)'));
  });

  testWidgets(
      'Round 15 r2: the KETERANGAN peak design flow is the BUILDING trunk '
      '(supplyPeakFlowProvider), never an inline booster duty flow',
      (tester) async {
    // A booster duty on 0.5 L/s (its partial flow) beside a 2.1 L/s building
    // trunk: the notes must print the trunk, not the booster.
    final (ref, container) = await _pumpRef(tester, overrides: [
      pumpDutyProvider.overrideWith((ref) => const PumpDuty(
            flow: FlowRate(0.0005),
            head: Head(20),
            hydraulicPower: Power(100),
            shaftPower: Power(150),
            motorInputPower: Power(180),
            selectedMotor: Power(370),
          )),
      supplyPeakFlowProvider.overrideWith((ref) => const FlowRate(0.0021)),
    ]);
    container
        .read(networkControllerProvider.notifier)
        .loadNetwork(_riserNetwork(roofTank: true));
    await tester.pump();
    final labels = buildLiveRiserSheet(ref, null)
        .prims
        .whereType<SldLabel>()
        .map((l) => l.text)
        .toList();
    expect(labels, contains('Peak design flow: 2.1 L/s'));
    expect(labels.any((t) => t.contains('Peak design flow: 0.5')), isFalse);
  });
}
