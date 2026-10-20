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
import 'dart:math' as math;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/dxf_export.dart';
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/sizing/drainage_advisory.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/custom_fixture.dart';
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
      leafDemand: const {}, nodeDrainageUnits: const {'WC': 4, 'LV': 1});
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

  test('a hand-overridden drainage RISER keeps the project fall (one rule)',
      () {
    // Round 33 r2 — the override path reads the SAME laidGravitySlope the
    // auto-sizer does: a DN50 run is steepened to its 2 % floor, a DN50
    // riser keeps the project 1 %. Manning full bore, R = D/4, n = 0.010:
    //   v = (1/n) R^(2/3) S^(1/2).
    const ctx = SizingContext(drainageSlope: 0.01, drainageManningN: 0.010);
    const runE =
        NetEdge(id: 'r', fromId: 'a', toId: 'b', service: ServiceType.drainage);
    const riserE = NetEdge(
        id: 'k',
        fromId: 'c',
        toId: 'd',
        service: ServiceType.drainage,
        kind: EdgeKind.riser);
    EdgeSizing base(String id) => EdgeSizing(
        edgeId: id,
        service: ServiceType.drainage,
        flow: const FlowRate(0.001),
        diameter: Diameter.mm(40),
        velocity: const Velocity(0));
    double v(double s) =>
        (1 / 0.010) * math.pow(0.05 / 4, 2 / 3) * math.sqrt(s);
    final run =
        applySizeOverride(base('r'), Diameter.mm(50), ctx: ctx, edge: runE);
    final riser =
        applySizeOverride(base('k'), Diameter.mm(50), ctx: ctx, edge: riserE);
    expect(run.velocity.metersPerSecond, closeTo(v(0.02), 1e-9));
    expect(riser.velocity.metersPerSecond, closeTo(v(0.01), 1e-9));
    expect(laidGravitySlope(riserE, 0.01, 50), 0.01);
  });

  test('a project fall flatter than a run floor is SAID, not silent', () {
    // Round 33 r2 — 1:250 typed; DN40 floor 2 % ⇒ laid at 1:50, and the
    // Review info names both figures. A DN100 at 1:250 floors at 1 % ⇒
    // 1:100. A project 1:40 (2.5 %) meets every floor ⇒ nothing.
    const runE =
        NetEdge(id: 'r', fromId: 'a', toId: 'b', service: ServiceType.drainage);
    final a =
        laidSteeperAdvisory(edge: runE, projectSlope: 0.004, diameterMm: 40);
    expect(a, isNotNull);
    expect(a!.kind, DrainageAdvisoryKind.laidSteeperThanProject);
    expect(a.message, contains('1:250'));
    expect(a.message, contains('DN40'));
    expect(a.message, contains('laid (and printed) at 1:50'));
    final b =
        laidSteeperAdvisory(edge: runE, projectSlope: 0.004, diameterMm: 100);
    expect(b!.message, contains('at 1:100'));
    expect(laidSteeperAdvisory(edge: runE, projectSlope: 0.025, diameterMm: 40),
        isNull);
    // A riser / vent keeps the project slope ⇒ nothing to say.
    const riserE = NetEdge(
        id: 'k',
        fromId: 'c',
        toId: 'd',
        service: ServiceType.drainage,
        kind: EdgeKind.riser);
    expect(
        laidSteeperAdvisory(edge: riserE, projectSlope: 0.004, diameterMm: 40),
        isNull);
    const ventE =
        NetEdge(id: 'v', fromId: 'a', toId: 'b', service: ServiceType.vent);
    expect(
        laidSteeperAdvisory(edge: ventE, projectSlope: 0.004, diameterMm: 40),
        isNull);
  });

  test('a custom-library fixture prints its short name, not nothing', () {
    // Round 33 r2 — the node carries only a customFixtureId; the library
    // resolves it. Non-ASCII is dropped, long names cut at a word break.
    const lib = [
      CustomFixture(id: 'cf1', name: 'Ablution tap'),
      CustomFixture(id: 'cf2', name: 'Wudhu basin (stainless) row'),
      CustomFixture(id: 'cf3', name: '\u00b7\u00b7'),
    ];
    final byId = {for (final f in lib) f.id: f};
    NetNode cf(String id, String cfId) => NetNode(
        id: id,
        sheetId: 's',
        x: 0,
        y: 0,
        floorIndex: 0,
        role: NodeRole.fixture,
        customFixtureId: cfId);
    expect(customFixturePlanCode(lib[0]), 'Ablution tap');
    expect(customFixturePlanCode(lib[1]), 'Wudhu basin');
    expect(customFixturePlanCode(lib[2]), isNull);
    expect(
        fixturePlanCode(cf('a', 'cf1'), customFixtures: byId), 'Ablution tap');
    // Without the library (or an unknown id) the built-in rule applies.
    expect(fixturePlanCode(cf('a', 'cf1')), isNull);
    final net2 = Network(nodes: [cf('a', 'cf1'), cf('b', 'nope')], edges: []);
    expect(customFixturePlanTags(net2, lib), {'a': 'Ablution tap'});
    // Self-describing: the legend keys only the built-in codes.
    final notes = planSheetNotes(
        net: net2,
        sheetId: 's',
        floorIndex: 0,
        fixtureTags: const {'a': 'Ablution tap', 'w': 'WC'});
    expect(notes, ['WC water closet']);
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
        planSheetNotes(
            net: const Network(nodes: [], edges: []),
            sheetId: 's',
            floorIndex: 0),
        isEmpty);
  });
}
