/// Minimal ASCII DXF (R12) export of a drawn network for one sheet/floor — a
/// real CAD-importable drawing deliverable. Pure: builds a string from the
/// network + sizes; the app handles file IO. Zero Flutter imports.
///
/// Runs become LINE entities on a per-service layer, risers a CIRCLE marker at
/// their node, and each sized edge a TEXT label (DN / Ø / W×H). DXF Y is up, so
/// screen Y is negated. Coordinates are the drawn sheet pixels.
library;

import 'dart:math' as math;

import '../network/network.dart';
import '../sizing/network_sizing.dart';
import 'drawing_chrome.dart';

String _sizeLabel(NetEdge e, EdgeSizing s) {
  if (s.isRectangular) {
    return '${s.width!.inMillimeters.round()}x${s.height!.inMillimeters.round()}';
  }
  final mm = s.diameter.inMillimeters.round();
  return e.service.isAir ? 'O$mm' : 'DN$mm';
}

/// Render the [sheetId]/[floorIndex] slice of [net] as a DXF document.
String networkToDxf({
  required Network net,
  required Map<String, EdgeSizing> sizing,
  required String sheetId,
  required int floorIndex,
  DrawingChrome? chrome,
}) {
  final b = StringBuffer();
  void g(int code, Object value) {
    b.writeln(code);
    b.writeln(value);
  }

  bool onFloor(NetNode n) => n.sheetId == sheetId && n.floorIndex == floorIndex;

  // Track drawn extent (DXF world units, y = -screenY) so chrome can anchor to
  // the drawing's corners.
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  void include(double x, double y) {
    minX = math.min(minX, x);
    minY = math.min(minY, y);
    maxX = math.max(maxX, x);
    maxY = math.max(maxY, y);
  }

  g(0, 'SECTION');
  g(2, 'ENTITIES');

  for (final e in net.edges) {
    final a = net.nodeById(e.fromId);
    final c = net.nodeById(e.toId);
    if (a == null || c == null) continue;
    final layer = e.service.name;

    if (e.kind == EdgeKind.run) {
      if (!onFloor(a) || !onFloor(c)) continue;
      include(a.x, -a.y);
      include(c.x, -c.y);
      g(0, 'LINE');
      g(8, layer);
      g(10, a.x);
      g(20, -a.y);
      g(11, c.x);
      g(21, -c.y);
      final s = sizing[e.id];
      if (s != null) {
        g(0, 'TEXT');
        g(8, layer);
        g(10, (a.x + c.x) / 2);
        g(20, -(a.y + c.y) / 2);
        g(40, 12);
        g(1, _sizeLabel(e, s));
      }
    } else {
      // Riser/drop: a marker circle at whichever endpoint is on this floor.
      for (final n in [a, c]) {
        if (!onFloor(n)) continue;
        include(n.x, -n.y);
        g(0, 'CIRCLE');
        g(8, layer);
        g(10, n.x);
        g(20, -n.y);
        g(40, 8);
      }
    }
  }

  // ── Issuable-document chrome (opt-in; byte-identical when null/empty) ───────
  if (chrome != null && !chrome.isEmpty) {
    if (!minX.isFinite) {
      minX = 0;
      minY = 0;
      maxX = 1;
      maxY = 1;
    }
    b.write(dxfChrome(chrome, minX: minX, minY: minY, maxX: maxX, maxY: maxY));
  }

  g(0, 'ENDSEC');
  g(0, 'EOF');
  return b.toString();
}
