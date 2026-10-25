/// Round 34 (fire-hvac-drawings-legend-lacks-symbols) — the plan legend keys
/// every component glyph drawn on the sheet (glyph + label) in the PDF and
/// the DXF, inside the reserved legend box; no symbols ⇒ byte-identical.
library;

import 'dart:convert';

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/dxf_export.dart';
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  final net = Network(nodes: [
    const NetNode(id: 'A', sheetId: 's', x: 0, y: 0, floorIndex: 0),
    NetNode(
        id: 'U',
        sheetId: 's',
        x: 200,
        y: 0,
        floorIndex: 0,
        role: NodeComponent.ahu.role,
        component: NodeComponent.ahu),
    NetNode(
        id: 'S',
        sheetId: 's',
        x: 400,
        y: 0,
        floorIndex: 0,
        role: NodeComponent.sprinklerHead.role,
        component: NodeComponent.sprinklerHead),
    NetNode(
        id: 'X',
        sheetId: 'other',
        x: 400,
        y: 0,
        floorIndex: 0,
        role: NodeComponent.pump.role,
        component: NodeComponent.pump),
  ], edges: const [
    NetEdge(id: 'au', fromId: 'A', toId: 'U', service: ServiceType.duct),
    NetEdge(
        id: 'as', fromId: 'A', toId: 'S', service: ServiceType.fireSprinkler),
  ]);

  test('planLegendSymbols: each on-floor component once, enum order', () {
    final symbols = planLegendSymbols(net, sheetId: 's', floorIndex: 0);
    // NodeComponent declares sprinklerHead before ahu.
    expect(symbols, [NodeComponent.sprinklerHead, NodeComponent.ahu]);
  });

  test('the legend box grows by one 13 pt row per symbol', () {
    const base = DrawingChrome(legendServices: [ServiceType.duct]);
    final withSym = base.withLegendSymbols(
        const [NodeComponent.sprinklerHead, NodeComponent.ahu]);
    expect(identical(base.withLegendSymbols(const []), base), isTrue);
    final b0 = pdfLegendBox(base, originX: 0, originY: 0)!;
    final b1 = pdfLegendBox(withSym, originX: 0, originY: 0)!;
    expect(b1.maxY - b0.maxY, closeTo(2 * 13.0, 1e-9));
    // An otherwise-empty chrome with only symbols is not empty.
    expect(
        const DrawingChrome(legendSymbols: [NodeComponent.ahu]).isEmpty, isFalse);
  });

  test('glyph + label in the PDF and the DXF legend', () {
    final chrome = const DrawingChrome(
            legendServices: [ServiceType.duct, ServiceType.fireSprinkler],
            drawingNumber: 'M-102')
        .withLegendSymbols(planLegendSymbols(net, sheetId: 's', floorIndex: 0));
    final lengths = {for (final e in net.edges) e.id: const Length(2)};
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
      chrome: chrome,
    ));
    final dxf = networkToDxf(
      net: net,
      sizing: const {},
      edgeLengths: lengths,
      sheetId: 's',
      floorIndex: 0,
      metersPerPixel: 0.01,
      chrome: chrome,
    );
    for (final text in [pdf, dxf]) {
      expect(text, contains('Sprinkler head'));
      expect(text, contains('AHU'));
    }
    // The sprinkler glyph is a circle: the DXF legend carries a CIRCLE on the
    // legend layer.
    expect(RegExp('CIRCLE\\s*\\n\\s*8\\s*\\n$kDxfLayerLegend').hasMatch(dxf),
        isTrue);
  });
}
