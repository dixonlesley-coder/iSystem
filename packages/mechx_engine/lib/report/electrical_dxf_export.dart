/// ASCII DXF (R12) export of the electrical single-line — a real CAD-importable
/// drawing deliverable. The electrical mirror of `dxf_export.dart`
/// (`networkToDxf`). Pure: builds a string from the sized system; the app
/// handles file IO. Zero Flutter imports.
///
/// [electricalSldToDxf] renders the SAME professional single-line built in
/// `electrical_sld_drawing.dart` as the PDF — every panel a distribution-board
/// single-line (incomer breaker → busbar → one row per outgoing way with
/// breaker / cable / load / phase / Ib, feeders routed to the sub-panel they
/// supply) — plus a model-space title block + device legend. Panels go on the
/// `panels` layer, feeders on `feeders`, the sheet frame on `frame`.
/// [powerOneLineToDxf] renders the hybrid power one-line (utility / genset / PV
/// / battery) as boxed nodes joined by feeder LINEs. DXF Y is up, so screen Y is
/// negated.
library;

import 'dart:math' as math;

import '../electrical/model.dart';
import '../electrical/panel_results.dart';
import '../electrical/power_oneline.dart';
import 'electrical_sld_drawing.dart';

/// Box footprint (DXF units) for an auto-laid panel / node.
const double _boxW = 200;
const double _boxH = 90;
const double _gapX = 120;
const double _gapY = 80;

class _Dxf {
  final StringBuffer b = StringBuffer();

  void g(int code, Object value) {
    b.writeln(code);
    b.writeln(value);
  }

  void begin() {
    g(0, 'SECTION');
    g(2, 'ENTITIES');
  }

  void end() {
    g(0, 'ENDSEC');
    g(0, 'EOF');
  }

  /// A box (4 LINEs) with top-left at ([x],[y]) in screen space (Y negated).
  /// [color] is an optional ACI override (62) — null = inherit the layer colour.
  void box(String layer, double x, double y, double w, double h, {int? color}) {
    void line(double x1, double y1, double x2, double y2) {
      g(0, 'LINE');
      g(8, layer);
      if (color != null) g(62, color);
      g(10, x1);
      g(20, -y1);
      g(11, x2);
      g(21, -y2);
    }

    line(x, y, x + w, y);
    line(x + w, y, x + w, y + h);
    line(x + w, y + h, x, y + h);
    line(x, y + h, x, y);
  }

  void text(String layer, double x, double y, String value,
      {double size = 12, int? color}) {
    g(0, 'TEXT');
    g(8, layer);
    if (color != null) g(62, color);
    g(10, x);
    g(20, -y);
    g(40, size);
    g(1, value);
  }

  void connector(String layer, double x1, double y1, double x2, double y2,
      {int? color}) {
    g(0, 'LINE');
    g(8, layer);
    if (color != null) g(62, color);
    g(10, x1);
    g(20, -y1);
    g(11, x2);
    g(21, -y2);
  }

  @override
  String toString() => b.toString();
}

/// Render the sized electrical single-line as a DXF document, drawing the SAME
/// professional content as the PDF (`buildElectricalSld`): panel blocks on the
/// `panels` layer, feeder routing on `feeders`, the title block + legend frame
/// on `frame`. The drawing is model-space (DXF Y up, so screen-space y-down is
/// negated).
String electricalSldToDxf({
  required ElectricalProject project,
  required ElectricalSystemResult result,
  bool overview = false,
}) {
  final d = _Dxf()..begin();
  // `overview` = the ZOOMED-OUT building single-line (compact panel tree, normal
  // / essential colour split); default = the per-panel detail single-line.
  final sheet = overview
      ? buildElectricalOverview(project: project, result: result)
      : buildElectricalSld(project: project, result: result);

  // Essential prims are drawn ACI red (1); source MV-chain blue (5); normal
  // inherits the layer colour (null). Detail sheet is all-normal ⇒ unchanged.
  int? colorFor(SldRole r) => switch (r) {
        SldRole.normal => null,
        SldRole.essential => 1,
        SldRole.source => 5,
      };

  // Drawing-space primitives (panels / busbars / ways / feeders). A line that is
  // medium/thick weight is a busbar or feeder → the `feeders` layer; everything
  // else (block outlines, way stubs, breaker boxes, labels) → `panels`.
  for (final p in sheet.prims) {
    switch (p) {
      case SldLine():
        final layer = p.weight == SldWeight.thin ? 'panels' : 'feeders';
        d.connector(layer, p.x1, p.y1, p.x2, p.y2, color: colorFor(p.role));
      case SldRect():
        d.box('panels', p.x, p.y, p.w, p.h, color: colorFor(p.role));
      case SldLabel():
        d.text('panels', p.x, p.y, p.text,
            size: p.size * 1.3, color: colorFor(p.role));
    }
  }

  // ── Model-space title block + legend, laid out below the drawing ────────────
  final frameTop = sheet.maxY + 60;
  final pname = project.name.isEmpty ? 'Untitled project' : project.name;
  d.box('frame', sheet.minX, frameTop, 360, 96);
  d.text('frame', sheet.minX + 8, frameTop + 22, pname, size: 16);
  d.text('frame', sheet.minX + 8, frameTop + 44, 'ELECTRICAL SINGLE-LINE DIAGRAM',
      size: 12);
  d.text('frame', sheet.minX + 8, frameTop + 66, sheet.supplyNote, size: 10);

  if (sheet.legend.isNotEmpty) {
    final lx = sheet.minX + 400;
    d.box('frame', lx, frameTop, 300, math.max(96, 22.0 + sheet.legend.length * 14));
    d.text('frame', lx + 8, frameTop + 16, 'LEGEND', size: 11);
    var row = 0;
    for (final e in sheet.legend) {
      d.text('frame', lx + 8, frameTop + 32 + row * 14, '${e.code}  -  ${e.meaning}',
          size: 9);
      row++;
    }
  }

  d.end();
  return d.toString();
}

/// Render a [PowerOneLine] as a DXF document — each node a labelled box, each
/// edge a LINE. Nodes are auto-laid in insertion order into a grid (no node
/// coordinates exist in the model).
String powerOneLineToDxf(PowerOneLine oneLine) {
  final d = _Dxf()..begin();
  const cols = 3;

  final pos = <String, ({double x, double y})>{};
  for (var i = 0; i < oneLine.nodes.length; i++) {
    final col = i % cols;
    final row = i ~/ cols;
    pos[oneLine.nodes[i].id] =
        (x: col * (_boxW + _gapX), y: row * (_boxH + _gapY));
  }

  ({double x, double y}) centre(String id) {
    final p = pos[id]!;
    return (x: p.x + _boxW / 2, y: p.y + _boxH / 2);
  }

  for (final edge in oneLine.edges) {
    if (!pos.containsKey(edge.from) || !pos.containsKey(edge.to)) continue;
    final a = centre(edge.from);
    final z = centre(edge.to);
    d.connector('oneline', a.x, a.y, z.x, z.y);
    if (edge.label != null) {
      d.text('oneline', (a.x + z.x) / 2, (a.y + z.y) / 2, edge.label!, size: 10);
    }
  }

  for (final node in oneLine.nodes) {
    final at = pos[node.id]!;
    d.box('oneline', at.x, at.y, _boxW, _boxH);
    d.text('oneline', at.x + 8, at.y + 28, node.label, size: 14);
    if (node.sub != null) {
      d.text('oneline', at.x + 8, at.y + 56, node.sub!);
    }
  }

  d.end();
  return d.toString();
}
