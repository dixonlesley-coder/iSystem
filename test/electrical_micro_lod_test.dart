/// The electrical single-line canvas's THIRD detail band — the MICRO chip.
///
/// Zoomed far out, the summary card was drawing stats no one can read and an
/// outlet handle no one can grab: a 26-screen-px band would have swallowed a
/// third of the card, and every caption was sub-pixel. The canvas now collapses
/// a board below [kMicroThreshold] to a chip carrying only what survives that
/// zoom — designation, connected kW, and a proportional R/S/T bar — and drops
/// the badges, stats, merged loads node, expand chevron and outlet handle
/// rather than pretending they are usable.
///
/// The geometry is a pure function of the tier ([panelCardWidthLod] /
/// [panelFootprintLod]), so the painted card, the hit-test rect and the feeder
/// endpoints all read the SAME numbers — checked here directly, and smoke-tested
/// through a real feeder at both zooms.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/electrical/electrical_canvas.dart';
import 'package:mechx/ui/electrical/electrical_format.dart';
import 'package:mechx/ui/electrical/panel_geometry.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

ElectricalPanel _board(String id, String tag, double x, double y,
        {String? fedByCircuitId,
        List<ElectricalCircuit> extra = const []}) =>
    ElectricalPanel(
      id: id,
      name: 'Board $tag',
      tag: tag,
      system: ElectricalSystem.threePhase,
      voltage: const Voltage(400),
      sourceType:
          fedByCircuitId == null ? PanelSource.utility : PanelSource.feeder,
      fedByCircuitId: fedByCircuitId,
      x: x,
      y: y,
      circuits: [
        ElectricalCircuit(
          id: '$id-c1',
          name: 'Lighting $tag',
          loadKind: LoadKind.lighting,
          isLighting: true,
          loadW: 1200,
          length: const Length(20),
        ),
        ...extra,
      ],
    );

/// A feeds B — so the canvas has a real feeder polyline to route at every zoom.
ElectricalProject _fixture() => ElectricalProject(
      id: 'micro',
      name: 'Micro LOD',
      panels: [
        _board('a', 'A', 0, 0, extra: const [
          ElectricalCircuit(
            id: 'a-f1',
            name: 'Feeder to B',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'b',
            length: Length(15),
          ),
        ]),
        _board('b', 'B', 500, 0, fedByCircuitId: 'a-f1'),
      ],
    );

Finder _byType(String name) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == name);

void main() {
  // ── Pure geometry ─────────────────────────────────────────────────────────

  test('panelCardWidthLod / panelFootprintLod: the micro tier is a fixed chip, '
      'and the pre-micro bool APIs delegate to it', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(electricalProjectProvider.notifier).setProject(_fixture());
    final result = container.read(electricalResultProvider);
    final panel = result.panels['a']!;

    // Micro is a FIXED chip — independent of the way count, unlike summary
    // (which grows with the ways) and schedule (which grows with the rows).
    expect(panelCardWidthLod(panel, PanelLod.micro), kPanelMicroW);
    expect(panelFootprintLod(panel, PanelLod.micro), kPanelMicroH);

    // Summary / schedule are unchanged by the new tier.
    expect(panelCardWidthLod(panel, PanelLod.summary),
        panelCardWidth(panel.circuits.length));
    expect(panelFootprintLod(panel, PanelLod.summary),
        kPanelChrome + kPanelSummaryBodyH);
    expect(panelCardWidthLod(panel, PanelLod.schedule), panelDetailWidth());
    expect(panelFootprintLod(panel, PanelLod.schedule),
        panelScheduleHeight(panel));

    // The two-tier bool APIs other files still call delegate exactly.
    expect(panelCardWidthAt(panel, true),
        panelCardWidthLod(panel, PanelLod.schedule));
    expect(panelCardWidthAt(panel, false),
        panelCardWidthLod(panel, PanelLod.summary));
    expect(panelFootprint(panel, true),
        panelFootprintLod(panel, PanelLod.schedule));
    expect(panelFootprint(panel, false),
        panelFootprintLod(panel, PanelLod.summary));

    // The micro chip is genuinely smaller than the summary card it replaces —
    // otherwise the tier would buy nothing.
    expect(kPanelMicroW, lessThan(panelCardWidthLod(panel, PanelLod.summary)));
    expect(kPanelMicroH, lessThan(panelFootprintLod(panel, PanelLod.summary)));
  });

  test('panelLodFor maps zoom to exactly three bands, in order', () {
    expect(kMicroThreshold, lessThan(kLodThreshold));
    expect(panelLodFor(0.05), PanelLod.micro);
    expect(panelLodFor(kMicroThreshold - 0.001), PanelLod.micro);
    expect(panelLodFor(kMicroThreshold), PanelLod.summary);
    expect(panelLodFor(kLodThreshold - 0.001), PanelLod.summary);
    expect(panelLodFor(kLodThreshold), PanelLod.schedule);
    expect(panelLodFor(4.0), PanelLod.schedule);
  });

  test('the outlet band keeps at least 26 screen px, capped at a third of the '
      'card', () {
    // Zoomed out the LOGICAL band widens to hold the screen minimum…
    expect(outletBandWidth(280, 0.5) * 0.5, closeTo(kOutletBandScreenPx, 1e-9));
    expect(outletBandWidth(758.4, 0.4) * 0.4,
        closeTo(kOutletBandScreenPx, 1e-9));
    // …but never past a third of the card, so it cannot eat the schedule's
    // way-row tap targets on a narrow board.
    expect(outletBandWidth(280, 0.05), closeTo(280 / 3, 1e-9));
    // Zoomed IN it never shrinks below the screen minimum either.
    expect(outletBandWidth(758.4, 2.0), kOutletBandScreenPx);
  });

  // ── The rendered tiers ────────────────────────────────────────────────────

  testWidgets('below the micro threshold a board renders as a chip (kW visible, '
      'badges + outlet handle gone); at 0.5 the summary card returns',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
    container.read(electricalProjectProvider.notifier).setProject(_fixture());
    await tester.pump();

    final state =
        tester.state<ElectricalCanvasState>(find.byType(ElectricalCanvas));

    // ── SUMMARY band (0.60, then 0.50) ───────────────────────────────────────
    state.collapseToSummary('a');
    await tester.pumpAndSettle();
    expect(panelLodFor(state.currentScale), PanelLod.summary);
    expect(_byType('_PanelSummaryBody'), findsNWidgets(2));
    expect(_byType('_PanelMicroBody'), findsNothing);
    expect(_byType('_OutletHandle'), findsNWidgets(2),
        reason: 'the summary card offers a feeder grab band');
    expect(_byType('_Badge'), findsWidgets);
    expect(tester.takeException(), isNull);

    // One step out from the collapse anchor (kLodThreshold − 0.12) — derived
    // from the constant so retuning the tier boundary never stales this.
    state.zoomOut();
    await tester.pumpAndSettle();
    expect(state.currentScale, closeTo((kLodThreshold - 0.12) / 1.2, 1e-9));
    expect(panelLodFor(state.currentScale), PanelLod.summary);
    expect(_byType('_PanelSummaryBody'), findsNWidgets(2));
    expect(tester.takeException(), isNull,
        reason: 'the feeder polyline routes cleanly at the summary tier');

    // ── MICRO band ───────────────────────────────────────────────────────────
    var guard = 0;
    while (state.currentScale >= kMicroThreshold && guard++ < 20) {
      state.zoomOut();
      await tester.pumpAndSettle();
    }
    expect(state.currentScale, lessThan(kMicroThreshold));
    expect(state.currentScale, greaterThan(0.15),
        reason: 'the loop should stop just below the boundary, ~0.2');
    expect(panelLodFor(state.currentScale), PanelLod.micro);

    expect(_byType('_PanelMicroBody'), findsNWidgets(2));
    expect(_byType('_PanelSummaryBody'), findsNothing);
    // The chip's three surviving facts.
    final connected =
        container.read(electricalResultProvider).panels['a']!.connectedW;
    expect(find.text(fmtKw(connected)), findsWidgets,
        reason: 'the micro chip still states how big the board is');
    expect(find.text('A'), findsWidgets, reason: 'and which board it is');
    expect(_byType('_MicroPhaseBar'), findsNWidgets(2));
    // …and nothing that could not be read or grabbed at this zoom.
    expect(_byType('_Badge'), findsNothing);
    expect(_byType('_OutletHandle'), findsNothing);
    expect(_byType('_ExpandChevron'), findsNothing);
    expect(_byType('_MergedLoadsNode'), findsNothing);
    expect(tester.takeException(), isNull,
        reason: 'the feeder polyline routes cleanly at the micro tier too');

    // A micro chip is still a real object: tap-select works. (The chip carries
    // a double-tap handler too, so the single tap resolves only after the
    // double-tap window closes.)
    await tester.tapAt(tester.getCenter(_byType('_PanelMicroBody').first));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(state.selectedPanelIds, isNotEmpty);

    // Zooming back in restores the summary card (the tier is reversible).
    state.collapseToSummary('a');
    await tester.pumpAndSettle();
    expect(_byType('_PanelSummaryBody'), findsNWidgets(2));
    expect(_byType('_PanelMicroBody'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
