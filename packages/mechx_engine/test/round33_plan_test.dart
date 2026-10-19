/// Round 33 seed suite (2026-10-18) — issued plan fidelity:
///   * engineer-walkthrough-plan-fall-below-own-minimum — a ≤ DN65 drainage
///     run prints the fall it is LAID at (1:50), PDF == DXF, and the
///     min-slope advisory judged at that fall stays silent.
///   * engineer-walkthrough-plan-fixtures-anonymous — every plumbing fixture
///     carries its plan code (WC / LAV) in both formats.
///   * engineer-walkthrough-plan-cl-datum-unstated — the floor-relative CL
///     datum is stated exactly once in the legend notes, PDF == DXF.
library;

import 'dart:convert';

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/dxf_export.dart';
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/sizing/drainage_advisory.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, double y,
        {NodeRole role = NodeRole.main,
        NodeComponent? c,
        PlumbingFixture? fixture}) =>
    NetNode(
        id: id,
        sheetId: 's',
        x: x,
        y: y,
        floorIndex: 0,
        role: c?.role ?? role,
        component: c,
        fixture: fixture);

void main() {
  // A WC and a lavatory draining to a DN100 main, plus their cold supply.
  final net = Network(nodes: [
    _n('WC', 100, 100,
        role: NodeRole.fixture, fixture: PlumbingFixture.waterClosetFlushTank),
    _n('LV', 100, 400,
        role: NodeRole.fixture, fixture: PlumbingFixture.lavatory),
    _n('J', 600, 100),
    _n('J2', 600, 400),
    _n('O', 1200, 100),
  ], edges: const [
    NetEdge(id: 'wc', fromId: 'WC', toId: 'J', service: ServiceType.drainage),
    NetEdge(id: 'lv', fromId: 'LV', toId: 'J2', service: ServiceType.drainage),
    NetEdge(id: 'j2', fromId: 'J2', toId: 'J', service: ServiceType.drainage),
    NetEdge(id: 'm', fromId: 'J', toId: 'O', service: ServiceType.drainage),
  ]);
  final sizing = autoSizeNetwork(net, const SizingContext(),
      leafDemand: const {},
      nodeDrainageUnits: const {'WC': 4, 'LV': 1});
  final notes = planSheetNotes(
    net: net,
    sheetId: 's',
    floorIndex: 0,
    fixtureTags: fixturePlanTags(net, sheetId: 's', floorIndex: 0),
    hasCentrelineLabels: true,
    floorFflM: 16.0,
    floorName: 'Lantai 4',
    gravitySlope: 0.01,
    sizing: sizing,
  );
  final chrome = const DrawingChrome(
          legendServices: [ServiceType.drainage], drawingNumber: 'M-101')
      .withLegendNotes(notes);
  final lengths = {
    for (final e in net.edges) e.id: const Length(3.0),
  };
  String pdf({bool withChrome = true}) => latin1.decode(planToPdf(
        net: net,
        sizing: sizing,
        edgeLengths: lengths,
        sheetId: 's',
        floorIndex: 0,
        projectName: 'P',
        sheetName: 'S',
        dateString: '2026-10-18',
        metersPerPixel: 0.01,
        chrome: withChrome ? chrome : null,
        gravitySlope: 0.01,
      ));
  String dxf({bool withChrome = true}) => networkToDxf(
        net: net,
        sizing: sizing,
        edgeLengths: lengths,
        sheetId: 's',
        floorIndex: 0,
        metersPerPixel: 0.01,
        chrome: withChrome ? chrome : null,
        gravitySlope: 0.01,
      );

  test('a DN40 branch prints its laid 1:50; the DN100 main the project 1:100',
      () {
    expect(sizing['lv']!.diameter.inMillimeters, 40);
    expect(sizing['m']!.diameter.inMillimeters, greaterThanOrEqualTo(75));
    // First principles: ≤ DN65 is laid at no flatter than 2 % = 1:50; a
    // DN75–150 at max(1 %, project 1 %) = 1:100.
    expect(laidGravitySlope(net.edgeById('lv')!, 0.01, 40), 0.02);
    expect(laidGravitySlope(net.edgeById('m')!, 0.01, 100), 0.01);
    for (final text in [pdf(), dxf()]) {
      expect(text, contains('DN40 - 3.0 m - 1:50'));
      expect(text, isNot(contains('DN40 - 3.0 m - 1:100')));
      expect(text, contains('- 3.0 m - 1:100'));
    }
    // The advisory judged at the laid fall never contradicts the drawing.
    expect(
        drainageAdvisories(
            edgeId: 'lv',
            slope: laidGravitySlope(net.edgeById('lv')!, 0.01, 40),
            diameterMm: 40),
        isEmpty);
  });

  test('fixtures carry their plan codes in both formats', () {
    expect(fixturePlanCode(net.nodeById('WC')!), 'WC');
    expect(fixturePlanCode(net.nodeById('LV')!), 'LAV');
    // Without the legend notes: the codes come from the tag placer itself.
    for (final text in [pdf(withChrome: false), dxf(withChrome: false)]) {
      expect(RegExp(r'\bLAV\b').hasMatch(text), isTrue);
      expect(RegExp(r'\bWC\b').hasMatch(text), isTrue);
    }
  });

  test('the CL datum + fixture key + fall rule are stated once, PDF == DXF',
      () {
    expect(notes, [
      'WC water closet - LAV lavatory',
      "CL = pipe centreline above this floor's FFL (Lantai 4 FFL +16.00)",
      'Drain fall: <= DN65 at 1:50 min, DN75-150 at 1:100 min, else 1:100',
    ]);
    final p = pdf(), d = dxf();
    for (final n in notes) {
      final pdfN = pdfWinAnsiText(n);
      expect(pdfN.allMatches(p).length, 1, reason: n);
      expect(dxfText(n).allMatches(d).length, 1, reason: n);
    }
    // No notes without the datum / fixtures / steeper runs.
    expect(
        planSheetNotes(net: const Network(nodes: [], edges: []),
            sheetId: 's', floorIndex: 0),
        isEmpty);
  });
}
