/// Round 34 (fire-hvac-drawings-air-terminals-and-heads-carry-no-data) — the
/// issued plan tags each air terminal with its airflow + face size, codes
/// hydrant boxes / hose reels, and states the sprinkler head basis once, in
/// both formats through the one placer (PDF == DXF).
library;

import 'dart:convert';

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/dxf_export.dart';
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x,
        {NodeComponent? c,
        FlowRate? q,
        double? w,
        double? h,
        String sheet = 's'}) =>
    NetNode(
        id: id,
        sheetId: sheet,
        x: x,
        y: 100,
        floorIndex: 0,
        role: c?.role ?? NodeRole.main,
        component: c,
        airflow: q,
        faceWidthMm: w,
        faceHeightMm: h);

void main() {
  test('airTerminalPlanTag: L/s from the SI airflow, face W x H when set', () {
    // 0.2 m3/s × 1000 = 200 L/s; face 450 × 450 mm.
    expect(
        airTerminalPlanTag(_n('d', 0,
            c: NodeComponent.supplyDiffuser,
            q: const FlowRate(0.2),
            w: 450,
            h: 450)),
        '200 L/s 450x450');
    expect(
        airTerminalPlanTag(
            _n('g', 0, c: NodeComponent.exhaustGrille, q: const FlowRate(0.05))),
        '50 L/s');
    // Below 10 L/s one decimal (0.0075 m3/s = 7.5 L/s).
    expect(
        airTerminalPlanTag(
            _n('x', 0, c: NodeComponent.returnGrille, q: const FlowRate(0.0075))),
        '7.5 L/s');
    // Nothing honest to print: no airflow, or not an air terminal.
    expect(airTerminalPlanTag(_n('e', 0, c: NodeComponent.supplyDiffuser)),
        isNull);
    expect(airTerminalPlanTag(_n('p', 0, c: NodeComponent.ahu)), isNull);
  });

  test('hydrant boxes / hose reels carry a keyed plan code', () {
    expect(fixturePlanCode(_n('h', 0, c: NodeComponent.hydrantBox)), 'HYD');
    expect(fixturePlanCode(_n('r', 0, c: NodeComponent.hoseReel)), 'HR');
    expect(kFixturePlanCodeNames['HYD'], 'hydrant box');
    expect(kFixturePlanCodeNames['HR'], 'hose reel');
  });

  final net = Network(nodes: [
    _n('A', 0),
    _n('D', 400,
        c: NodeComponent.supplyDiffuser,
        q: const FlowRate(0.2),
        w: 450,
        h: 450),
    _n('S', 800, c: NodeComponent.sprinklerHead),
    _n('B', 1200, c: NodeComponent.hydrantBox),
  ], edges: const [
    NetEdge(id: 'ad', fromId: 'A', toId: 'D', service: ServiceType.duct),
    NetEdge(id: 'as', fromId: 'A', toId: 'S', service: ServiceType.fireSprinkler),
    NetEdge(id: 'ab', fromId: 'A', toId: 'B', service: ServiceType.fireHydrant),
  ]);

  test('the tags print in BOTH formats (one placer)', () {
    final lengths = {for (final e in net.edges) e.id: const Length(4)};
    final pdf = latin1.decode(planToPdf(
      net: net,
      sizing: const {},
      edgeLengths: lengths,
      sheetId: 's',
      floorIndex: 0,
      projectName: 'P',
      sheetName: 'L2',
      dateString: '2026-10-18',
      metersPerPixel: 0.01,
    ));
    final dxf = networkToDxf(
      net: net,
      sizing: const {},
      edgeLengths: lengths,
      sheetId: 's',
      floorIndex: 0,
      metersPerPixel: 0.01,
    );
    for (final text in [pdf, dxf]) {
      expect(text.contains('200 L/s 450x450'), isTrue);
      expect(RegExp(r'\bHYD\b').hasMatch(text), isTrue);
    }
  });

  test('the sprinkler head basis is a sheet note only where heads are drawn',
      () {
    final notes = planSheetNotes(
      net: net,
      sheetId: 's',
      floorIndex: 0,
      fixtureTags: fixturePlanTags(net, sheetId: 's', floorIndex: 0),
      sprinklerKFactor: 80,
      sprinklerHazard: 'light hazard',
    );
    expect(notes, [
      'HYD hydrant box',
      'Sprinkler heads: K 80 (L/min/bar^0.5), light hazard - VERIFY head model',
    ]);
    // Another sheet (no heads drawn on it) states nothing.
    expect(
        planSheetNotes(
            net: net, sheetId: 'other', floorIndex: 0, sprinklerKFactor: 80),
        isEmpty);
  });
}
