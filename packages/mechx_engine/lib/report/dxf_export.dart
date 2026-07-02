/// Minimal ASCII DXF (R12) export of a drawn network for one sheet/floor — a
/// real CAD-importable drawing deliverable. Pure: builds a string from the
/// network + sizes; the app handles file IO. Zero Flutter imports.
///
/// Runs become LINE entities on a per-service layer, risers a CIRCLE marker at
/// their node, and each sized edge a TEXT label (DN / Ø / W×H). DXF Y is up, so
/// screen Y is negated. With no calibration the coordinates are the drawn
/// sheet pixels (the legacy document); with [networkToDxf]'s `metersPerPixel`
/// set the export is a PROFESSIONAL real-world drawing — millimetre
/// coordinates, a HEADER declaring mm units, a TABLES section with named
/// layers + linetypes, group 370 lineweights, and rotated annotation text
/// (CAD-OUTPUT-UX-REVIEW A2/A6/A7).
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

/// The A6 line-weight band for a sized edge — rectangular ducts band on their
/// larger side, round ducts on Ø, pipes on DN (see `strokeBandFor`).
int _strokeBand(EdgeSizing s) {
  if (s.isRectangular) {
    final side = math.max(s.width!.inMillimeters, s.height!.inMillimeters);
    return strokeBandFor(sizeMm: side, isDuct: true);
  }
  return strokeBandFor(
      sizeMm: s.diameter.inMillimeters, isDuct: s.service.isAir);
}

/// Render the [sheetId]/[floorIndex] slice of [net] as a DXF document.
///
/// With [metersPerPixel] null the output is the legacy ENTITIES-only
/// pixel-space document — byte-identical to before the parameter existed.
/// With the sheet calibration supplied, coordinates are multiplied to
/// MILLIMETRES so every run measures true in CAD, and the document gains a
/// HEADER (`$INSUNITS` 4 = mm, `$MEASUREMENT` 1 = metric), a TABLES section
/// (LTYPE + one LAYER per present service + annotation/frame layers), AIA-style
/// layer names, group 6 linetypes, group 370 lineweights on sized runs, and
/// ANNO-layer labels rotated to their edge bearing (group 50).
String networkToDxf({
  required Network net,
  required Map<String, EdgeSizing> sizing,
  required String sheetId,
  required int floorIndex,
  DrawingChrome? chrome,
  double? metersPerPixel,
}) {
  if (metersPerPixel != null && metersPerPixel > 0) {
    return _professionalDxf(
      net: net,
      sizing: sizing,
      sheetId: sheetId,
      floorIndex: floorIndex,
      chrome: chrome,
      metersPerPixel: metersPerPixel,
    );
  }

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

/// The professional (calibrated) DXF: real-world millimetre model space with
/// full HEADER/TABLES structure. See [networkToDxf].
String _professionalDxf({
  required Network net,
  required Map<String, EdgeSizing> sizing,
  required String sheetId,
  required int floorIndex,
  required DrawingChrome? chrome,
  required double metersPerPixel,
}) {
  final b = StringBuffer();
  void g(int code, Object value) {
    b.writeln(code);
    b.writeln(value);
  }

  bool onFloor(NetNode n) => n.sheetId == sheetId && n.floorIndex == floorIndex;
  final mmPerPx = metersPerPixel * 1000; // world millimetres per sheet pixel

  // ── Pass 1: extent (mm, y-up) + the services present, for TABLES + text ────
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  void include(double x, double y) {
    minX = math.min(minX, x);
    minY = math.min(minY, y);
    maxX = math.max(maxX, x);
    maxY = math.max(maxY, y);
  }

  final services = <ServiceType>{};
  for (final e in net.edges) {
    final a = net.nodeById(e.fromId);
    final c = net.nodeById(e.toId);
    if (a == null || c == null) continue;
    if (e.kind == EdgeKind.run) {
      if (!onFloor(a) || !onFloor(c)) continue;
      include(a.x * mmPerPx, -a.y * mmPerPx);
      include(c.x * mmPerPx, -c.y * mmPerPx);
      services.add(e.service);
    } else {
      for (final n in [a, c]) {
        if (!onFloor(n)) continue;
        include(n.x * mmPerPx, -n.y * mmPerPx);
        services.add(e.service);
      }
    }
  }
  if (!minX.isFinite) {
    minX = 0;
    minY = 0;
    maxX = 1;
    maxY = 1;
  }
  final span = math.max(math.max(maxX - minX, maxY - minY), 1.0);
  // Annotation text height ~ the larger drawing span / 80 — plots at roughly
  // 2.5 mm when the sheet is fitted to the drawing (the drafting norm).
  final textH = span / 80;

  // ── HEADER: millimetre drawing units, metric measurement ────────────────────
  g(0, 'SECTION');
  g(2, 'HEADER');
  g(9, r'$INSUNITS');
  g(70, 4); // 4 = millimetres
  g(9, r'$MEASUREMENT');
  g(70, 1); // 1 = metric
  g(0, 'ENDSEC');

  // ── TABLES: LTYPE + one LAYER per present service + ANNO/FRAME (+ chrome) ──
  final hasChrome = chrome != null && !chrome.isEmpty;
  b.write(dxfTablesSection(layers: [
    for (final s in services)
      (dxfLayerNameFor(s), serviceAciColorFor(s), dxfLinetypeFor(s)),
    (kDxfLayerAnno, 7, 'CONTINUOUS'),
    (kDxfLayerFrame, 7, 'CONTINUOUS'),
    // `dxfChrome` draws on its own toggleable layers — declare them too.
    if (hasChrome) ...const [
      ('title', 7, 'CONTINUOUS'),
      ('legend', 7, 'CONTINUOUS'),
      ('scale', 7, 'CONTINUOUS'),
      ('north', 7, 'CONTINUOUS'),
    ],
  ]));

  g(0, 'SECTION');
  g(2, 'ENTITIES');

  final placedLabels = <LabelBox>[];
  for (final e in net.edges) {
    final a = net.nodeById(e.fromId);
    final c = net.nodeById(e.toId);
    if (a == null || c == null) continue;

    if (e.kind == EdgeKind.run) {
      if (!onFloor(a) || !onFloor(c)) continue;
      final ax = a.x * mmPerPx, ay = -a.y * mmPerPx;
      final cx = c.x * mmPerPx, cy = -c.y * mmPerPx;
      final s = sizing[e.id];
      g(0, 'LINE');
      g(8, dxfLayerNameFor(e.service));
      g(6, dxfLinetypeFor(e.service));
      // A6 lineweight bands for sized runs (unsized keep the layer default).
      if (s != null) g(370, kDxfLineweights[_strokeBand(s)]);
      g(10, ax);
      g(20, ay);
      g(11, cx);
      g(21, cy);
      if (s != null) {
        // A7 label discipline: rotated to the edge bearing on the ANNO layer,
        // offset to the upper side, dropped on unresolvable collision.
        final p = placeEdgeLabel(
            ax: ax,
            ay: ay,
            bx: cx,
            by: cy,
            text: _sizeLabel(e, s),
            textSize: textH,
            placed: placedLabels);
        if (p != null) {
          g(0, 'TEXT');
          g(8, kDxfLayerAnno);
          g(10, p.x);
          g(20, p.y);
          g(40, textH);
          g(1, _sizeLabel(e, s));
          g(50, p.angleDeg.toStringAsFixed(1));
        }
      }
    } else {
      // Riser/drop: a marker circle at whichever endpoint is on this floor
      // (the legacy 8 px marker, scaled to real millimetres).
      for (final n in [a, c]) {
        if (!onFloor(n)) continue;
        g(0, 'CIRCLE');
        g(8, dxfLayerNameFor(e.service));
        g(6, dxfLinetypeFor(e.service));
        g(10, n.x * mmPerPx);
        g(20, -n.y * mmPerPx);
        g(40, 8 * mmPerPx);
      }
    }
  }

  // ── Issuable-document chrome (opt-in), anchored to the mm extent ────────────
  if (hasChrome) {
    b.write(dxfChrome(chrome, minX: minX, minY: minY, maxX: maxX, maxY: maxY));
  }

  g(0, 'ENDSEC');
  g(0, 'EOF');
  return b.toString();
}
