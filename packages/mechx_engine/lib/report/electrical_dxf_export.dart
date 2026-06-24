/// Minimal ASCII DXF (R12) export of the electrical single-line — a real
/// CAD-importable drawing deliverable. The electrical mirror of
/// `dxf_export.dart` (`networkToDxf`). Pure: builds a string from the sized
/// system; the app handles file IO. Zero Flutter imports.
///
/// [electricalSldToDxf] draws each panel as a labelled box (its schematic
/// canvas position when placed, else an auto-laid column), wires feeders as LINE
/// entities parent→child, and labels each box with its name + incomer rating.
/// [powerOneLineToDxf] renders the hybrid power one-line (utility / genset / PV
/// / battery) as boxed nodes joined by feeder LINEs. DXF Y is up, so screen Y is
/// negated.
library;

import '../electrical/model.dart';
import '../electrical/panel_results.dart';
import '../electrical/power_oneline.dart';

/// Box footprint (DXF units) for an auto-laid panel / node.
const double _boxW = 200;
const double _boxH = 90;
const double _gapX = 120;
const double _gapY = 80;

String _n(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

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
  void box(String layer, double x, double y, double w, double h) {
    void line(double x1, double y1, double x2, double y2) {
      g(0, 'LINE');
      g(8, layer);
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

  void text(String layer, double x, double y, String value, {double size = 12}) {
    g(0, 'TEXT');
    g(8, layer);
    g(10, x);
    g(20, -y);
    g(40, size);
    g(1, value);
  }

  void connector(String layer, double x1, double y1, double x2, double y2) {
    g(0, 'LINE');
    g(8, layer);
    g(10, x1);
    g(20, -y1);
    g(11, x2);
    g(21, -y2);
  }

  @override
  String toString() => b.toString();
}

/// Render the sized electrical single-line as a DXF document. Panels are boxes
/// on the `panels` layer (at their schematic [ElectricalPanel.x]/[y] when
/// placed, else auto-laid in root-first order); feeders are LINEs on the
/// `feeders` layer between a parent panel and the sub-panel it feeds.
String electricalSldToDxf({
  required ElectricalProject project,
  required ElectricalSystemResult result,
}) {
  final d = _Dxf()..begin();
  final modelById = {for (final p in project.panels) p.id: p};

  // Resolve each panel's box top-left. Placed panels use their canvas position;
  // unplaced panels stack in a single auto-laid column (root-first order).
  final pos = <String, ({double x, double y})>{};
  var autoRow = 0;
  for (final id in result.order) {
    final model = modelById[id];
    if (model?.x != null && model?.y != null) {
      pos[id] = (x: model!.x!, y: model.y!);
    } else {
      pos[id] = (x: 0, y: autoRow * (_boxH + _gapY));
      autoRow++;
    }
  }

  // Feeders: a parent panel's circuit that feeds a sub-panel → a LINE between
  // the two box centres.
  ({double x, double y}) centre(String id) {
    final p = pos[id]!;
    return (x: p.x + _boxW / 2, y: p.y + _boxH / 2);
  }

  for (final parent in project.panels) {
    for (final c in parent.circuits) {
      final child = c.feedsPanelId;
      if (child == null) continue;
      if (!pos.containsKey(parent.id) || !pos.containsKey(child)) continue;
      final a = centre(parent.id);
      final z = centre(child);
      d.connector('feeders', a.x, a.y, z.x, z.y);
    }
  }

  // Panel boxes + labels (drawn after feeders so the boxes read on top).
  for (final id in result.order) {
    final p = result.panels[id];
    if (p == null) continue;
    final at = pos[id]!;
    d.box('panels', at.x, at.y, _boxW, _boxH);
    final tag = p.tag != null && p.tag!.isNotEmpty ? ' [${p.tag}]' : '';
    d.text('panels', at.x + 8, at.y + 24, '${p.name}$tag', size: 14);
    d.text('panels', at.x + 8, at.y + 48,
        'In ${_n(p.incomer.breaker.ratingA.amperes)} A · ${p.system.label}');
    d.text('panels', at.x + 8, at.y + 70,
        'bus ${_n(p.busbar.csaMm2)} mm²');
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
