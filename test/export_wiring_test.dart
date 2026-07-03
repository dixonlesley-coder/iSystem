/// Wave-2 export WIRING tests — the app-side threading of the D3 document
/// control into the drawing chrome + report heads, the C5 breaking-capacity
/// map from the live fault study, and the B3 riser drawing-set service loop.
/// (The engine-side rendering of each is covered by the engine suites; these
/// pin the APP gathers the right live state.)
library;

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/document_control_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/ui/electrical/electrical_export.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx/ui/schematic/schematic_export.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/calc_report.dart' show buildCalcReportBlocks;
import 'package:mechx_engine/report/electrical_sld_drawing.dart'
    show buildElectricalSld;
import 'package:mechx_engine/report/equipment_schedule.dart'
    show
        buildEquipmentScheduleBlocks,
        buildEquipmentScheduleRows,
        equipmentScheduleToCsv;
import 'package:mechx_engine/report/mep_report.dart'
    show buildMepUnifiedReportBlocks;
import 'package:mechx_engine/report/report_blocks.dart';
import 'package:mechx_engine/report/report_pdf.dart' show reportBlocksToPdf;
import 'package:mechx_engine/report/sld_sheet.dart' show SldLabel;
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/pipe_optimizer.dart';
import 'package:mechx_engine/standards/sni.dart' show Revision;
import 'package:mechx_engine/units.dart';

void main() {
  /// Pump a minimal ProviderScope and capture a live [WidgetRef] + its
  /// container (the same harness as the export-gate test — the export helpers
  /// take a WidgetRef).
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

  String today() => DateTime.now().toIso8601String().split('T').first;

  testWidgets('issuableChrome carries the document-control identity + date',
      (tester) async {
    final (ref, container) = await harness(tester);
    final docCtrl = container.read(documentControlProvider.notifier);
    docCtrl.setDocumentNumber('M-101');
    docCtrl.setRevisionTag('B');
    docCtrl.setClientName('PT Contoh');
    docCtrl.setPreparedBy('AR');
    docCtrl.setCheckedBy('DS');
    docCtrl.setApprovedBy('LW');

    final chrome = issuableChrome(ref, sheetId: 's1', floorIndex: 0);
    expect(chrome.drawingNumber, 'M-101');
    expect(chrome.revisionNumber, 'B');
    expect(chrome.clientName, 'PT Contoh');
    expect(chrome.drawnBy, 'AR');
    expect(chrome.checkedBy, 'DS');
    expect(chrome.approvedBy, 'LW');
    // The app formats today's date (the engine never reads the clock).
    expect(chrome.dateString, today());
  });

  testWidgets(
      'issuableChrome leaves unset document-control fields null (rows omitted)',
      (tester) async {
    final (ref, _) = await harness(tester);
    final chrome = issuableChrome(ref, sheetId: 's1', floorIndex: 0);
    expect(chrome.drawingNumber, isNull);
    expect(chrome.revisionNumber, isNull);
    expect(chrome.clientName, isNull);
    expect(chrome.drawnBy, isNull);
    expect(chrome.checkedBy, isNull);
    expect(chrome.approvedBy, isNull);
    // The date is always stamped — an issued drawing carries its issue date.
    expect(chrome.dateString, today());
  });

  testWidgets('the calc-report data carries the document-control revisions',
      (tester) async {
    final (ref, container) = await harness(tester);
    container
        .read(documentControlProvider.notifier)
        .addRevision('2026-07-01', 'First issue');
    container
        .read(documentControlProvider.notifier)
        .addRevision('2026-07-02', 'Client comments');

    final data = buildMechanicalReportData(ref);
    expect(data.revisions, hasLength(2));
    expect(data.revisions.first.date, '2026-07-01');
    expect(data.revisions.first.description, 'First issue');
    expect(data.revisions.last, isA<Revision>());
    expect(data.revisions.last.date, '2026-07-02');
  });

  testWidgets(
      'breakerIcuKaByPanel maps every solved panel to a positive Icu (kA) '
      'from the fault study', (tester) async {
    final (ref, container) = await harness(tester);
    // A2: the sample switchboard is no longer auto-seeded — load it explicitly
    // so the fault study has panels to map.
    container
        .read(electricalProjectProvider.notifier)
        .setProject(sampleElectricalProject());
    final result = container.read(electricalResultProvider);
    expect(result.order, isNotEmpty,
        reason: 'the sample electrical project must carry panels');

    final map = breakerIcuKaByPanel(ref);
    final fault = container.read(electricalAdvancedProvider).fault;
    for (final id in result.order) {
      final panelFault = fault.panels[id];
      if (panelFault == null) continue; // not studied ⇒ honestly absent
      // Forwarded value = the CHOSEN breaking-capacity rating (incomerKa),
      // NOT the raw prospective fault magnitude.
      expect(map[id], panelFault.incomerKa);
      expect(map[id], greaterThan(0));
    }
    expect(map, isNotEmpty);
  });

  testWidgets(
      'riserSetServices lists the drawn services once, in canonical order',
      (tester) async {
    final (_, container) = await harness(tester);
    // Drainage drawn before cold water — the set order must still be the
    // canonical draw order (cold water first), one sheet per service.
    const net = Network(nodes: [
      NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
      NetNode(id: 'b', sheetId: 's1', x: 10, y: 0, floorIndex: 0),
      NetNode(id: 'c', sheetId: 's1', x: 0, y: 10, floorIndex: 0),
    ], edges: [
      NetEdge(id: 'e1', fromId: 'a', toId: 'b', service: ServiceType.drainage),
      NetEdge(id: 'e2', fromId: 'a', toId: 'c', service: ServiceType.coldWater),
      NetEdge(id: 'e3', fromId: 'b', toId: 'c', service: ServiceType.drainage),
    ]);
    container.read(networkControllerProvider.notifier).loadNetwork(net);
    expect(riserSetServices(net),
        [ServiceType.coldWater, ServiceType.drainage]);
    // A network with no edges yields no per-service sheets.
    expect(riserSetServices(const Network(nodes: [], edges: [])), isEmpty);
  });

  testWidgets(
      'buildLiveRiserSheet carries the B1 canvas-parity extras (equipment '
      'detail suffix + KETERANGAN notes + detail callouts)', (tester) async {
    final (ref, container) = await harness(tester);
    // A roof tank with a REAL stored capacity feeding a ground-floor main —
    // the exported sheet must carry at least what the Auto canvas draws.
    const net = Network(nodes: [
      NetNode(
        id: 'rt',
        sheetId: 's1',
        x: 0,
        y: 0,
        floorIndex: 1,
        role: NodeRole.plant,
        component: NodeComponent.roofTank,
        tankCapacityLitres: 5000,
      ),
      NetNode(id: 'm', sheetId: 's1', x: 0, y: 100, floorIndex: 0),
    ], edges: [
      NetEdge(
          id: 'r1',
          fromId: 'rt',
          toId: 'm',
          service: ServiceType.coldWater,
          kind: EdgeKind.riser),
    ]);
    container.read(networkControllerProvider.notifier).loadNetwork(net);
    final sheet = buildLiveRiserSheet(ref, null);
    final labels =
        sheet.prims.whereType<SldLabel>().map((l) => l.text).join('\n');
    // Equipment detail suffix from the live node value (5000 L => 5 m3).
    expect(labels, contains('Roof tank · 5 m3'));
    // The KETERANGAN system-notes block echoes the live feed strategy.
    expect(labels, contains('KETERANGAN'));
    expect(labels, contains('Feed:'));
    // The H101 detail callouts ride the export (detailCallouts: true).
    expect(labels, contains('DETAIL WATER METER'));
    expect(labels, contains('DETAIL PRV SET'));
    expect(labels, contains('ROOF TANK 5 m3'));
  });

  testWidgets(
      'the riser drawing-set export routes through the shared zero-length '
      'guard (blocks + raises loadError, no success pill)', (tester) async {
    final (ref, container) = await harness(tester);
    // A run on the UNCALIBRATED demo sheet sizes to ZERO length, so the
    // shared export gate must fire before any file dialog.
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

    await exportMechanicalRiserSetPdf(ref, null);
    await tester.pump();

    final err = container.read(loadErrorProvider);
    expect(err, isNotNull);
    expect(err, contains('zero length'));
    expect(err, contains('riser drawing set'));
    expect(container.read(statusMessageProvider), isNull);
  });

  // ── D6/D5: floor-grouped BOM CSV + joined cut-plan columns ─────────────────
  //
  // bomCsvWithCutPlan is a pure seam (no widget needed): a floor-grouped BOM
  // (built with groupByFloor:true) joined with the pipeCutPlan output.
  //
  // BOM (hand-built, already sorted):
  //   coldWater run  floor 0 (human 1) DN25  5.00 m ×1
  //   coldWater run  floor 1 (human 2) DN25  3.00 m ×1
  //   coldWater riser (null floor)      DN50  3.50 m ×1
  //
  // Cut plan for (coldWater, DN25): stock 4.0 m, fullBars 2, one packed bar
  // holding a 1.0 m remainder, requiredM 9.0.
  //   totalBars     = 2 + 1                 = 3
  //   purchasedM    = 3 × 4.0               = 12.0 m
  //   wasteM        = 12.0 − 9.0            = 3.0 m
  //   wastePercent  = 100 × 3.0 / 12.0      = 25.0 %
  // No plan entry for DN50 (a riser-only size — excluded from the chains).
  test(
      'bomCsvWithCutPlan: floor column + cut-plan columns joined per '
      '(service, DN), emitted once, empty when no plan entry', () {
    final bom = [
      BomLine(
        service: ServiceType.coldWater,
        kind: EdgeKind.run,
        diameterMm: 25,
        totalLength: const Length(5.0),
        segmentCount: 1,
        floorIndex: 0,
      ),
      BomLine(
        service: ServiceType.coldWater,
        kind: EdgeKind.run,
        diameterMm: 25,
        totalLength: const Length(3.0),
        segmentCount: 1,
        floorIndex: 1,
      ),
      const BomLine(
        service: ServiceType.coldWater,
        kind: EdgeKind.riser,
        diameterMm: 50,
        totalLength: Length(3.5),
        segmentCount: 1,
      ),
    ];
    final cutPlan = [
      const PipeCutGroup(
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

    final lines = bomCsvWithCutPlan(bom, cutPlan).trim().split('\n');
    expect(
        lines.first,
        'service,kind,floor,nominal_dn_mm,length_m,segments,'
        'stock_length_m,bars_purchased,waste_pct');
    // First DN25 run row carries the plan; the 1-based floor is 1.
    expect(lines[1], 'coldWater,run,1,25,5.00,1,4.0,3,25.0');
    // Second DN25 row (same group) leaves the plan columns EMPTY (sum-safe).
    expect(lines[2], 'coldWater,run,2,25,3.00,1,,,');
    // The riser: null floor → empty, and no plan entry → empty plan columns.
    expect(lines[3], 'coldWater,riser,,50,3.50,1,,,');
  });

  // ── D1: the typeset-PDF report seams (Wave 4) ──────────────────────────────
  //
  // The full export fns pop the OS file picker (no platform in a headless
  // test), so — exactly as the existing seam tests do — these pin the APP
  // GATHER + assembly the export fn runs internally: the live report data +
  // the embedded figure(s) rendered by `reportBlocksToPdf`. A conforming PDF
  // begins with the `%PDF` magic.
  String magic(List<int> bytes) => latin1.decode(bytes.sublist(0, 4));

  testWidgets(
      'the calc-report PDF seam renders %PDF bytes with the riser figure '
      'appended', (tester) async {
    final (ref, container) = await harness(tester);
    // A roof-tank riser so the embedded figure has real prims (mirrors the
    // buildLiveRiserSheet parity test).
    const net = Network(nodes: [
      NetNode(
        id: 'rt',
        sheetId: 's1',
        x: 0,
        y: 0,
        floorIndex: 1,
        role: NodeRole.plant,
        component: NodeComponent.roofTank,
        tankCapacityLitres: 5000,
      ),
      NetNode(id: 'm', sheetId: 's1', x: 0, y: 100, floorIndex: 0),
    ], edges: [
      NetEdge(
          id: 'r1',
          fromId: 'rt',
          toId: 'm',
          service: ServiceType.coldWater,
          kind: EdgeKind.riser),
    ]);
    container.read(networkControllerProvider.notifier).loadNetwork(net);

    final data = buildMechanicalReportData(ref);
    final blocks = [
      ...buildCalcReportBlocks(data),
      RptFigure(buildLiveRiserSheet(ref, null),
          caption: 'Mechanical riser single-line diagram'),
    ];
    // The riser figure is the LAST block (appended after the report body).
    expect(blocks.last, isA<RptFigure>());
    final bytes = reportBlocksToPdf(
      blocks,
      docTitle: 'MEP Calculation Report',
      projectName: 'P',
      standardsLine: '${data.standardsName} (${data.standardsRevision})',
    );
    expect(magic(bytes), '%PDF');
    expect(bytes.length, greaterThan(1000));
  });

  testWidgets(
      'the unified-MEP PDF seam renders %PDF bytes with BOTH single-line '
      'figures appended', (tester) async {
    final (ref, container) = await harness(tester);
    // A2: seed the sample switchboard so the unified report carries an
    // electrical body + single-line figure.
    container
        .read(electricalProjectProvider.notifier)
        .setProject(sampleElectricalProject());
    expect(container.read(electricalResultProvider).order, isNotEmpty,
        reason: 'the sample electrical project must carry panels');

    final mechanical = buildMechanicalReportData(ref);
    final electrical = buildElectricalReportData(ref);
    final blocks = [
      ...buildMepUnifiedReportBlocks(
        mechanical: mechanical,
        electrical: electrical,
        compliance: buildComplianceSummary(ref),
      ),
      const RptHeading(1, 'Drawings'),
      RptFigure(buildLiveRiserSheet(ref, null),
          caption: 'Mechanical riser single-line diagram'),
      RptFigure(
        buildElectricalSld(
          project: container.read(electricalProjectProvider),
          result: container.read(electricalResultProvider),
          breakerIcuKaByPanelId: breakerIcuKaByPanel(ref),
        ),
        caption: 'Electrical single-line diagram',
      ),
    ];
    // Two figures ride the PDF — the mechanical riser + the electrical SLD.
    expect(blocks.whereType<RptFigure>().length, 2);
    final bytes = reportBlocksToPdf(
      blocks,
      docTitle: 'MEP Building-Services Report',
      projectName: 'P',
    );
    expect(magic(bytes), '%PDF');
  });

  testWidgets('the equipment-schedule PDF seam renders %PDF bytes',
      (tester) async {
    final (ref, _) = await harness(tester);
    final data = gatherEquipmentScheduleData(ref);
    final bytes = reportBlocksToPdf(
      buildEquipmentScheduleBlocks(data),
      docTitle: 'Equipment Schedule',
      projectName: 'P',
    );
    expect(magic(bytes), '%PDF');
  });

  // ── D5: the equipment-schedule CSV sibling (Wave 4) ────────────────────────
  testWidgets(
      'the equipment-schedule CSV seam emits the header row + one line per '
      'scheduled item', (tester) async {
    final (ref, container) = await harness(tester);
    // A2: seed the sample switchboard so the schedule has electrical panels.
    container
        .read(electricalProjectProvider.notifier)
        .setProject(sampleElectricalProject());
    expect(container.read(electricalResultProvider).order, isNotEmpty,
        reason: 'the sample electrical project must carry panels');
    final data = gatherEquipmentScheduleData(ref);
    final rows = buildEquipmentScheduleRows(data);
    expect(rows, isNotEmpty,
        reason: 'the sample project schedules at least the electrical panels');

    final csv = equipmentScheduleToCsv(rows);
    expect(csv, isNotEmpty);
    final lines = csv.trim().split('\n');
    expect(lines.first, 'tag,category,service,duty,size,model_spec,qty');
    // Header + one line per scheduled row.
    expect(lines.length, rows.length + 1);
  });
}
