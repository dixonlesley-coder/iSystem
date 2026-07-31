/// Audit-wave APP-side wiring pins (R1, R2, R3, X3).
///
/// The engine-side rendering is covered by
/// `packages/mechx_engine/test/report_audit_wave_test.dart`; these pin that the
/// APP threads the right live state into it — the one place a "computed but
/// never surfaced" defect keeps reappearing.
library;

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/autosave.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/ui/electrical/electrical_export.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart' show DrawingSeries;
import 'package:mechx_engine/report/electrical_calc_report.dart'
    show buildElectricalCalcReport;
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/pipe_optimizer.dart';
import 'package:mechx_engine/units.dart';

void main() {
  /// Pump a minimal ProviderScope and capture a live [WidgetRef] + its
  /// container (the export/report helpers take a WidgetRef).
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

  // ── R1 — the issued electrical report reads the COMBINED warning surface ──
  group('R1 — the report gathers electricalAllWarningsProvider', () {
    testWidgets('buildElectricalReportData carries the combined surface',
        (tester) async {
      final (ref, container) = await harness(tester);
      final data = buildElectricalReportData(ref);
      final combined = container.read(electricalAllWarningsProvider);

      // Not the core-only list: the exact provider the Review hub + compliance
      // roll-up read, element for element.
      expect(data.allWarnings, isNotNull);
      expect(data.allWarnings!.length, combined.length);
      for (var i = 0; i < combined.length; i++) {
        expect(identical(data.allWarnings![i], combined[i]), isTrue);
      }
    });

    testWidgets('every combined finding reaches the rendered report',
        (tester) async {
      final (ref, container) = await harness(tester);
      final md = buildElectricalCalcReport(buildElectricalReportData(ref));
      for (final w in container.read(electricalAllWarningsProvider)) {
        expect(md, contains(w.message),
            reason: 'the issued report omitted "${w.code}"');
      }
    });
  });

  // ── R2 — the BOM CSV carries material + the manual-override marker ────────
  //
  // Re-derived from `export_wiring_test.dart`'s D6/D5 fixture (same three BOM
  // lines + the same DN25 cut plan), now with a material on each line:
  //   coldWater run  floor 0 (human 1) DN25 PPR 5.00 m ×1
  //   coldWater run  floor 1 (human 2) DN25 PPR 3.00 m ×1
  //   coldWater riser (null floor)     DN50 PPR 3.50 m ×1
  // Cut plan for (coldWater, DN25): stock 4.0 m, fullBars 2 + one packed bar
  // holding a 1.0 m remainder, requiredM 9.0
  //   totalBars = 3 · purchased = 12.0 m · waste = 3.0 m ⇒ 25.0 %
  group('R2 — bomCsvWithCutPlan columns', () {
    List<BomLine> fixture({bool manual = false}) => [
          BomLine(
            service: ServiceType.coldWater,
            kind: EdgeKind.run,
            diameterMm: 25,
            tag: 'CW-F1',
            material: 'PPR',
            totalLength: const Length(5.0),
            segmentCount: 1,
            floorIndex: 0,
            manual: manual,
          ),
          const BomLine(
            service: ServiceType.coldWater,
            kind: EdgeKind.run,
            diameterMm: 25,
            tag: 'CW-F2',
            material: 'PPR',
            totalLength: Length(3.0),
            segmentCount: 1,
            floorIndex: 1,
          ),
          const BomLine(
            service: ServiceType.coldWater,
            kind: EdgeKind.riser,
            diameterMm: 50,
            tag: 'CW-R1',
            material: 'PPR',
            totalLength: Length(3.5),
            segmentCount: 1,
          ),
        ];

    const cutPlan = [
      PipeCutGroup(
        service: ServiceType.coldWater,
        diameterMm: 25,
        stockLengthM: 4.0,
        plan: StockCutPlan(
          stockLengthM: 4.0,
          fullBars: 2,
          packedBars: [CutBar([1.0])],
          requiredM: 9.0,
        ),
      ),
    ];

    test('the header gains material (and keeps the cut-plan columns)', () {
      final lines = bomCsvWithCutPlan(fixture(), cutPlan).trim().split('\n');
      expect(
          lines.first,
          'service,kind,tag,floor,nominal_size_mm,material,length_m,segments,'
          'stock_length_m,bars_purchased,waste_pct');
      // First DN25 run row carries the plan; the 1-based floor is 1.
      expect(lines[1], 'coldWater,run,CW-F1,1,25,PPR,5.00,1,4.0,3,25.0');
      // Second DN25 row (same group) leaves the plan columns EMPTY (sum-safe).
      expect(lines[2], 'coldWater,run,CW-F2,2,25,PPR,3.00,1,,,');
      // The riser: stack tag, null floor → empty, no plan entry → empty plan.
      expect(lines[3], 'coldWater,riser,CW-R1,,50,PPR,3.50,1,,,');
    });

    test('a manual override adds the trailing `manual` (*) column', () {
      final lines =
          bomCsvWithCutPlan(fixture(manual: true), cutPlan).trim().split('\n');
      // The engine's conditional column sits after `segments`; the cut-plan
      // columns follow it.
      expect(
          lines.first,
          'service,kind,tag,floor,nominal_size_mm,material,length_m,segments,'
          'manual,stock_length_m,bars_purchased,waste_pct');
      expect(lines[1], 'coldWater,run,CW-F1,1,25,PPR,5.00,1,*,4.0,3,25.0');
      expect(lines[2], 'coldWater,run,CW-F2,2,25,PPR,3.00,1,,,,');
    });

    test('the takeoff columns are the ENGINE csv verbatim (one format)', () {
      // Row for row, the app CSV is the engine CSV plus exactly three cells —
      // the guarantee that the two can never drift apart again.
      final bom = fixture();
      final engine = bomToCsv(bom).trim().split('\n');
      final app = bomCsvWithCutPlan(bom, cutPlan).trim().split('\n');
      expect(app.length, engine.length);
      for (var i = 0; i < engine.length; i++) {
        expect(app[i], startsWith('${engine[i]},'));
        expect(app[i].split(',').length, engine[i].split(',').length + 3);
      }
    });
  });

  // ── R3 — a phantom timeline tag is DROPPED, never a silent no-op ──────────
  //
  // The domain snapshot stacks cap at 200 while the timeline holds 1000 tags,
  // so tags can outlive the snapshots behind them. Rather than pushing 200+
  // edits, these construct the SAME state directly: a tag whose owning
  // controller holds nothing to revert.
  group('R3 — phantom undo/redo entries', () {
    testWidgets('undo skips a stale tag and reverts the real edit',
        (tester) async {
      final (_, container) = await harness(tester);
      final net = container.read(networkControllerProvider.notifier);
      final history = container.read(historyProvider.notifier);

      net.addFitting('s1', 0, const Offset(10, 10));
      expect(container.read(networkControllerProvider).network.nodes.length, 1);

      // A tag for a domain that never captured a snapshot — exactly the shape
      // of an over-cap entry.
      history.record(UndoDomain.annotation);
      expect(container.read(annotationHistoryProvider.notifier).canUndo, isFalse);

      history.undo();

      // The genuinely most-recent REVERTIBLE edit was undone (not a no-op),
      // and the stale tag is gone rather than parked on the redo stack.
      expect(container.read(networkControllerProvider).network.nodes, isEmpty);
      expect(history.canUndo, isFalse);
      expect(history.canRedo, isTrue);
    });

    testWidgets('an all-phantom timeline undoes to an honest empty state',
        (tester) async {
      final (_, container) = await harness(tester);
      final history = container.read(historyProvider.notifier);

      history
        ..record(UndoDomain.annotation)
        ..record(UndoDomain.referenceLine);
      expect(history.canUndo, isTrue);

      history.undo();

      // Nothing could be reverted, so nothing pretends it was: the stale tags
      // are dropped and the Undo affordance disables itself instead of
      // advertising an action that does nothing.
      expect(history.canUndo, isFalse);
      expect(history.canRedo, isFalse);
    });

    testWidgets('redo drops a stale tag the same way', (tester) async {
      final (_, container) = await harness(tester);
      final net = container.read(networkControllerProvider.notifier);
      final history = container.read(historyProvider.notifier);

      net.addFitting('s1', 0, const Offset(10, 10));
      history.undo();
      expect(history.canRedo, isTrue);

      // Drop the controller's own stacks WITHOUT touching the timeline (the
      // load path does exactly this) — the queued redo tag is now a phantom.
      net.loadNetwork(const Network());
      expect(net.canRedo, isFalse);

      history.redo();

      expect(container.read(networkControllerProvider).network.nodes, isEmpty);
      expect(history.canRedo, isFalse);
    });
  });

  // ── M13/M14/M15 — the four new design inputs survive Save/Open ────────────
  //
  // Each was a dark engine constant until it became a real setting; a setting
  // the document does not carry is not a setting. `DesignSettings` already had
  // the fields — these pin the AUTOSAVE gather + restore actually use them.
  group('design-input persistence (drainage slope / HW temps / AC basis)', () {
    // Plain `test`s over a bare container: `applyDocument` restores the whole
    // project (rooms, tanks, status pill…), and the widget-test binding rejects
    // the transient timers that starts — the persistence contract needs no
    // widget tree anyway.
    ProviderContainer freshContainer() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('an untouched project encodes the engine defaults', () {
      final s = buildDocument(freshContainer().read).settings;
      expect(s.drainageSlope, 0.01); // 1:100
      expect(s.hotWaterFlowTempC, 60.0);
      expect(s.hotWaterDeltaTK, 5.0);
      expect(s.coolingLoadMethod, 'simple');
    });

    test('edited values round-trip through build -> encode -> apply', () {
      final container = freshContainer();
      container.read(drainageSlopeProvider.notifier).set(0.005); // 1:200
      container.read(hotWaterFlowTempProvider.notifier).set(55.0);
      container.read(hotWaterDeltaTProvider.notifier).set(8.0);
      container
          .read(coolingLoadMethodProvider.notifier)
          .set(CoolingLoadMethod.detailed);

      final doc = buildDocument(container.read);
      expect(doc.settings.drainageSlope, 0.005);
      expect(doc.settings.hotWaterFlowTempC, 55.0);
      expect(doc.settings.hotWaterDeltaTK, 8.0);
      expect(doc.settings.coolingLoadMethod, 'detailed');

      // Re-decode through the real JSON, then apply into a FRESH container —
      // the full Save -> Open path, not just the in-memory object.
      final reopened = ProjectDocument.decode(doc.encode());
      final fresh = freshContainer();
      applyDocument(fresh.read, reopened);

      expect(fresh.read(drainageSlopeProvider), 0.005);
      expect(fresh.read(hotWaterFlowTempProvider), 55.0);
      expect(fresh.read(hotWaterDeltaTProvider), 8.0);
      expect(fresh.read(coolingLoadMethodProvider), CoolingLoadMethod.detailed);
    });

    test('a legacy document without the fields restores the defaults', () {
      final container = freshContainer();
      // Diverge the live state first, then apply a document that never carried
      // the settings — the restore must reset them, not leave the old session's
      // values silently in force.
      container.read(drainageSlopeProvider.notifier).set(0.02);
      container
          .read(coolingLoadMethodProvider.notifier)
          .set(CoolingLoadMethod.detailed);

      // A document from BEFORE these settings existed: the real encode with
      // the four keys stripped out of its settings section.
      final legacy = jsonDecode(buildDocument(freshContainer().read).encode())
          as Map<String, dynamic>;
      (legacy['settings'] as Map<String, dynamic>)
        ..remove('drainageSlope')
        ..remove('hotWaterFlowTempC')
        ..remove('hotWaterDeltaTK')
        ..remove('coolingLoadMethod');
      applyDocument(container.read, ProjectDocument.decode(jsonEncode(legacy)));

      expect(container.read(drainageSlopeProvider), 0.01);
      expect(container.read(hotWaterFlowTempProvider), 60.0);
      expect(container.read(hotWaterDeltaTProvider), 5.0);
      expect(container.read(coolingLoadMethodProvider), CoolingLoadMethod.simple);
    });
  });

  // ── X3 — every single-sheet electrical export stamps SHEET 1 of 1 ─────────
  group('X3 — the electrical export chrome carries a sheet counter', () {
    testWidgets('every drawing series stamps a SHEET row', (tester) async {
      final (ref, _) = await harness(tester);
      for (final series in const [
        DrawingSeries.electricalDetail,
        DrawingSeries.electricalOverview,
        DrawingSeries.electricalRiser,
        DrawingSeries.electricalLayout,
        DrawingSeries.electricalPowerOneLine,
      ]) {
        final chrome = electricalExportChrome(ref, series: series);
        expect(chrome.sheetCounter, '1 of 1',
            reason: 'the $series export must print a SHEET row');
      }
    });
  });
}
