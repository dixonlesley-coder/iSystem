/// Wave-2 export WIRING tests — the app-side threading of the D3 document
/// control into the drawing chrome + report heads, the C5 breaking-capacity
/// map from the live fault study, and the B3 riser drawing-set service loop.
/// (The engine-side rendering of each is covered by the engine suites; these
/// pin the APP gathers the right live state.)
library;

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
import 'package:mechx_engine/standards/sni.dart' show Revision;

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
}
