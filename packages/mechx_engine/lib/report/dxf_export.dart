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
import 'plan_symbols.dart';
import 'sld_sheet.dart';

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
///
/// With [underlay] present (A1) the sheet's parsed floor-plan geometry is
/// re-emitted FIRST on the grey [kDxfLayerUnderlay] layer, transformed into
/// the same frame as the network coordinates (sheet pixels, or millimetres
/// when [metersPerPixel] is set); null keeps the output byte-identical. Only
/// the VECTOR form applies here — a raster underlay in an R12 DXF (a BMP-only
/// IMAGE/IMAGEDEF chain, post-R12) is out of scope, so a PDF-backed sheet
/// exports its DXF underlay-less.
///
/// With [edgeElevationLabels] present (N5) each run's `edge id → label` (e.g.
/// `CL +2.70`) is APPENDED to that run's DN/Ø/W×H size text, so the DXF carries
/// the same centreline height as the plan PDF. With [grid] present (N4, the
/// professional/calibrated path only) a reference setting-out grid is emitted on
/// [kDxfLayerGrid] plus per-riser tie dimensions on the annotation layer. Both
/// null ⇒ byte-identical.
///
/// With [edgeTags] present (N13) each entry's `edge id → stable tag` (the riser
/// stack tag `CW-R1` / a run's `<code>-F<floor>`, from `elementTags`) is
/// PREPENDED to that run's size TEXT and emitted as a tag TEXT beside each riser
/// marker, so the plan DXF carries the SAME element identifier the riser
/// single-line, BOM and calc report use. A missing/empty entry ⇒ unchanged; the
/// default null map ⇒ byte-identical.
String networkToDxf({
  required Network net,
  required Map<String, EdgeSizing> sizing,
  required String sheetId,
  required int floorIndex,
  DrawingChrome? chrome,
  double? metersPerPixel,
  VectorPlanUnderlay? underlay,
  Map<String, String>? edgeElevationLabels,
  ReferenceGrid? grid,
  Map<String, String>? edgeTags,
}) {
  if (metersPerPixel != null && metersPerPixel > 0) {
    return _professionalDxf(
      net: net,
      sizing: sizing,
      sheetId: sheetId,
      floorIndex: floorIndex,
      chrome: chrome,
      metersPerPixel: metersPerPixel,
      underlay: underlay,
      edgeElevationLabels: edgeElevationLabels,
      grid: grid,
      edgeTags: edgeTags,
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

  // A5 helpers: node symbols + flow arrows share the plan-symbol library. The
  // legacy document is pixel-space (x, -y is already y-up), so the glyph prims
  // are MIRRORED about the node's centre-Y and flow arrows read straight off
  // the world coordinates. See plan_symbols.dart.
  ServiceType? domService(NetNode n) {
    for (final e in net.edges) {
      if (e.fromId == n.id || e.toId == n.id) return e.service;
    }
    return null;
  }
  void emitPrims(List<SldPrim> prims, String layer, double centerY) {
    for (final pr in prims) {
      switch (pr) {
        case final SldLine l:
          g(0, 'LINE');
          g(8, layer);
          g(10, l.x1);
          g(20, 2 * centerY - l.y1);
          g(11, l.x2);
          g(21, 2 * centerY - l.y2);
        case final SldCircle cc:
          g(0, 'CIRCLE');
          g(8, layer);
          g(10, cc.cx);
          g(20, 2 * centerY - cc.cy);
          g(40, cc.r);
        case SldRect():
        case SldLabel():
          break; // never produced by the plan-symbol library
      }
    }
  }
  void flowChevron(double ux, double uy, double dxp, double dyp, double len,
      String layer, double arm) {
    final dirx = (dxp - ux) / len, diry = (dyp - uy) / len;
    final perpx = -diry, perpy = dirx;
    final atx = ux + dirx * (len * 2 / 3), aty = uy + diry * (len * 2 / 3);
    final tipx = atx + dirx * (arm * 0.5), tipy = aty + diry * (arm * 0.5);
    final backx = tipx - dirx * arm, backy = tipy - diry * arm;
    final w1x = backx + perpx * (arm * 0.75), w1y = backy + perpy * (arm * 0.75);
    final w2x = backx - perpx * (arm * 0.75), w2y = backy - perpy * (arm * 0.75);
    g(0, 'LINE');
    g(8, layer);
    g(10, w1x);
    g(20, w1y);
    g(11, tipx);
    g(21, tipy);
    g(0, 'LINE');
    g(8, layer);
    g(10, w2x);
    g(20, w2y);
    g(11, tipx);
    g(21, tipy);
  }

  g(0, 'SECTION');
  g(2, 'ENTITIES');

  // A1: the floor-plan underlay is re-emitted FIRST on its grey layer so the
  // network entities land above it; its sheet frame joins the chrome-anchoring
  // extent (legacy world = sheet pixels with Y negated).
  if (underlay != null) {
    include(0, 0);
    include(underlay.sheetWidthPx, -underlay.sheetHeightPx);
    b.write(dxfUnderlayEntities(underlay));
  }

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
        final elev = edgeElevationLabels?[e.id];
        final size = elev != null && elev.isNotEmpty
            ? '${_sizeLabel(e, s)} - $elev'
            : _sizeLabel(e, s);
        // N13: prepend the stable element tag (`CW-F2 - DN50 - CL +2.70`).
        final tag = edgeTags?[e.id];
        final labelText = tag != null && tag.isNotEmpty ? '$tag - $size' : size;
        g(0, 'TEXT');
        g(8, layer);
        g(10, (a.x + c.x) / 2);
        g(20, -(a.y + c.y) / 2);
        g(40, 12);
        g(1, labelText);
      }
      // A5 flow arrow on a sized, oriented, long-enough run.
      if (s != null && s.flowFromId != null) {
        final ax = a.x, ay = -a.y, bx = c.x, by = -c.y;
        final len = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
        if (len > 30) {
          final upIsA = s.flowFromId == a.id;
          flowChevron(upIsA ? ax : bx, upIsA ? ay : by, upIsA ? bx : ax,
              upIsA ? by : ay, len, layer, 5);
        }
      }
    } else {
      // Riser/drop: a marker circle at whichever endpoint is on this floor,
      // now tagged with its UP/DN sense (A5) and its stable element tag (N13).
      final riserTag = edgeTags?[e.id];
      for (final n in [a, c]) {
        if (!onFloor(n)) continue;
        include(n.x, -n.y);
        g(0, 'CIRCLE');
        g(8, layer);
        g(10, n.x);
        g(20, -n.y);
        g(40, 8);
        final other = n.id == a.id ? c : a;
        final sense =
            riserUpDown(hereFloor: n.floorIndex, otherFloor: other.floorIndex);
        if (sense != null) {
          g(0, 'TEXT');
          g(8, layer);
          g(10, n.x + 10);
          g(20, -n.y);
          g(40, 12);
          g(1, sense);
        }
        // N13: the riser stack tag (`CW-R1`) below the marker, so the plan DXF
        // carries the same riser id the riser single-line + BOM do.
        if (riserTag != null && riserTag.isNotEmpty) {
          g(0, 'TEXT');
          g(8, layer);
          g(10, n.x + 10);
          g(20, -n.y - 14);
          g(40, 12);
          g(1, riserTag);
        }
      }
    }
  }

  // A5 node symbols: an equipment glyph for a component node, a drop triangle
  // for a fixture-role node; plain junctions unchanged (this legacy document
  // never dotted them). Layer = the node's dominant service.
  for (final n in net.nodes) {
    if (!onFloor(n)) continue;
    final svc = domService(n);
    if (svc == null) continue;
    final comp = n.component;
    if (comp != null) {
      emitPrims(planComponentPrims(comp, cx: n.x, cy: -n.y, size: 16),
          svc.name, -n.y);
    } else if (n.role == NodeRole.fixture) {
      emitPrims(planFixturePrims(cx: n.x, cy: -n.y, size: 16), svc.name, -n.y);
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
  required VectorPlanUnderlay? underlay,
  required Map<String, String>? edgeElevationLabels,
  required ReferenceGrid? grid,
  required Map<String, String>? edgeTags,
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
  // A1: the underlay's sheet frame joins the extent (millimetre world, Y
  // negated) so the text height + chrome anchor to the whole floor plan.
  if (underlay != null) {
    include(0, 0);
    include(underlay.sheetWidthPx * mmPerPx, -underlay.sheetHeightPx * mmPerPx);
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
    // A1: the grey floor-plan underlay layer, declared only when present.
    if (underlay != null) (kDxfLayerUnderlay, kDxfUnderlayAci, 'CONTINUOUS'),
    // N4: the grey setting-out grid layer (chain linetype), only when present.
    if (grid != null && !grid.isEmpty) (kDxfLayerGrid, 8, 'DASHDOT'),
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

  // A1: the floor-plan underlay is re-emitted FIRST (millimetre frame) so the
  // network entities land above it.
  if (underlay != null) {
    b.write(dxfUnderlayEntities(underlay, unitsPerSheetPx: mmPerPx));
  }

  // N4: the reference setting-out grid — chain column/row LINEs + bubble
  // CIRCLE/TEXT on the grey grid layer, spanning the drawing extent (mm).
  if (grid != null && !grid.isEmpty && maxX.isFinite) {
    final bubbleR = span / 80;
    for (final ax in grid.columns) {
      final gx = ax.position * mmPerPx;
      g(0, 'LINE');
      g(8, kDxfLayerGrid);
      g(10, gx);
      g(20, minY);
      g(11, gx);
      g(21, maxY);
      g(0, 'CIRCLE');
      g(8, kDxfLayerGrid);
      g(10, gx);
      g(20, maxY + bubbleR);
      g(40, bubbleR);
      g(0, 'TEXT');
      g(8, kDxfLayerGrid);
      g(10, gx - bubbleR / 2);
      g(20, maxY + bubbleR / 2);
      g(40, bubbleR);
      g(1, ax.label);
    }
    for (final ay in grid.rows) {
      final gy = -ay.position * mmPerPx;
      g(0, 'LINE');
      g(8, kDxfLayerGrid);
      g(10, minX);
      g(20, gy);
      g(11, maxX);
      g(21, gy);
      g(0, 'CIRCLE');
      g(8, kDxfLayerGrid);
      g(10, minX - bubbleR);
      g(20, gy);
      g(40, bubbleR);
      g(0, 'TEXT');
      g(8, kDxfLayerGrid);
      g(10, minX - bubbleR - bubbleR / 2);
      g(20, gy - bubbleR / 2);
      g(40, bubbleR);
      g(1, ay.label);
    }
  }

  // A5 helpers: node symbols + flow arrows over the plan-symbol library, in the
  // millimetre model space (x, -y is already y-up), so glyph prims are MIRRORED
  // about the node centre-Y and arrows read straight off the mm coordinates.
  ServiceType? domService(NetNode n) {
    for (final e in net.edges) {
      if (e.fromId == n.id || e.toId == n.id) return e.service;
    }
    return null;
  }
  void emitPrims(List<SldPrim> prims, String layer, double centerY) {
    for (final pr in prims) {
      switch (pr) {
        case final SldLine l:
          g(0, 'LINE');
          g(8, layer);
          g(10, l.x1);
          g(20, 2 * centerY - l.y1);
          g(11, l.x2);
          g(21, 2 * centerY - l.y2);
        case final SldCircle cc:
          g(0, 'CIRCLE');
          g(8, layer);
          g(10, cc.cx);
          g(20, 2 * centerY - cc.cy);
          g(40, cc.r);
        case SldRect():
        case SldLabel():
          break; // never produced by the plan-symbol library
      }
    }
  }
  void flowChevron(double ux, double uy, double dxp, double dyp, double len,
      String layer, double arm) {
    final dirx = (dxp - ux) / len, diry = (dyp - uy) / len;
    final perpx = -diry, perpy = dirx;
    final atx = ux + dirx * (len * 2 / 3), aty = uy + diry * (len * 2 / 3);
    final tipx = atx + dirx * (arm * 0.5), tipy = aty + diry * (arm * 0.5);
    final backx = tipx - dirx * arm, backy = tipy - diry * arm;
    final w1x = backx + perpx * (arm * 0.75), w1y = backy + perpy * (arm * 0.75);
    final w2x = backx - perpx * (arm * 0.75), w2y = backy - perpy * (arm * 0.75);
    g(0, 'LINE');
    g(8, layer);
    g(10, w1x);
    g(20, w1y);
    g(11, tipx);
    g(21, tipy);
    g(0, 'LINE');
    g(8, layer);
    g(10, w2x);
    g(20, w2y);
    g(11, tipx);
    g(21, tipy);
  }

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
        // N5: append the centreline-elevation token to the size label.
        final elev = edgeElevationLabels?[e.id];
        final size = elev != null && elev.isNotEmpty
            ? '${_sizeLabel(e, s)} - $elev'
            : _sizeLabel(e, s);
        // N13: prepend the stable element tag (`CW-F2 - DN50 - CL +2.70`).
        final tag = edgeTags?[e.id];
        final labelText = tag != null && tag.isNotEmpty ? '$tag - $size' : size;
        // A7/N3 label discipline: rotated to the edge bearing on the ANNO layer,
        // offset to the upper side; a dense tag ESCAPES + is tied back with a
        // leader (never dropped, never fused) — see `placeEdgeLabelLeadered`.
        final p = placeEdgeLabelLeadered(
            ax: ax,
            ay: ay,
            bx: cx,
            by: cy,
            text: labelText,
            textSize: textH,
            placed: placedLabels);
        g(0, 'TEXT');
        g(8, kDxfLayerAnno);
        g(10, p.x);
        g(20, p.y);
        g(40, textH);
        g(1, labelText);
        g(50, p.angleDeg.toStringAsFixed(1));
        final lead = p.leaderAnchor;
        if (lead != null) {
          g(0, 'LINE');
          g(8, kDxfLayerAnno);
          g(10, lead.x);
          g(20, lead.y);
          g(11, p.x);
          g(21, p.y);
        }
      }
      // A5 flow arrow on a sized, oriented, long-enough run.
      if (s != null && s.flowFromId != null) {
        final len = math.sqrt((cx - ax) * (cx - ax) + (cy - ay) * (cy - ay));
        if (len > 30) {
          final upIsA = s.flowFromId == a.id;
          flowChevron(upIsA ? ax : cx, upIsA ? ay : cy, upIsA ? cx : ax,
              upIsA ? cy : ay, len, dxfLayerNameFor(e.service), 5 * mmPerPx);
        }
      }
    } else {
      // Riser/drop: a marker circle at whichever endpoint is on this floor
      // (the legacy 8 px marker, scaled to real millimetres), now tagged with
      // its UP/DN sense on the ANNO layer (A5) + its stable element tag (N13).
      final riserTag = edgeTags?[e.id];
      for (final n in [a, c]) {
        if (!onFloor(n)) continue;
        g(0, 'CIRCLE');
        g(8, dxfLayerNameFor(e.service));
        g(6, dxfLinetypeFor(e.service));
        g(10, n.x * mmPerPx);
        g(20, -n.y * mmPerPx);
        g(40, 8 * mmPerPx);
        final other = n.id == a.id ? c : a;
        final sense =
            riserUpDown(hereFloor: n.floorIndex, otherFloor: other.floorIndex);
        if (sense != null) {
          g(0, 'TEXT');
          g(8, kDxfLayerAnno);
          g(10, n.x * mmPerPx + 12 * mmPerPx);
          g(20, -n.y * mmPerPx);
          g(40, textH);
          g(1, sense);
        }
        // N13: the riser stack tag (`CW-R1`) below the marker on the ANNO
        // layer, so the plan DXF carries the same riser id the single-line +
        // BOM do.
        if (riserTag != null && riserTag.isNotEmpty) {
          g(0, 'TEXT');
          g(8, kDxfLayerAnno);
          g(10, n.x * mmPerPx + 12 * mmPerPx);
          g(20, -n.y * mmPerPx - textH * 1.4);
          g(40, textH);
          g(1, riserTag);
        }
      }
    }
  }

  // A5 node symbols: an equipment glyph for a component node, a drop triangle
  // for a fixture-role node; plain junctions unchanged. On the node's dominant
  // service layer, glyph box scaled to real millimetres.
  for (final n in net.nodes) {
    if (!onFloor(n)) continue;
    final svc = domService(n);
    if (svc == null) continue;
    final layer = dxfLayerNameFor(svc);
    final cyMm = -n.y * mmPerPx;
    final comp = n.component;
    if (comp != null) {
      emitPrims(
          planComponentPrims(comp,
              cx: n.x * mmPerPx, cy: cyMm, size: 16 * mmPerPx),
          layer,
          cyMm);
    } else if (n.role == NodeRole.fixture) {
      emitPrims(
          planFixturePrims(cx: n.x * mmPerPx, cy: cyMm, size: 16 * mmPerPx),
          layer,
          cyMm);
    }
  }

  // N4: per-riser TIE dimensions — each riser node's offset to its nearest
  // column + row axis, as a LINE + real-millimetre TEXT on the annotation layer
  // (this path is always calibrated, so the dimension is honest).
  if (grid != null && !grid.isEmpty) {
    final riserNodeIds = <String>{};
    for (final e in net.edges) {
      if (e.kind == EdgeKind.run) continue;
      for (final id in [e.fromId, e.toId]) {
        final n = net.nodeById(id);
        if (n != null && onFloor(n)) riserNodeIds.add(id);
      }
    }
    void tieDim(double fromXpx, double fromYpx, double toXpx, double toYpx,
        String label) {
      final ax = fromXpx * mmPerPx, ay = -fromYpx * mmPerPx;
      final bx = toXpx * mmPerPx, by = -toYpx * mmPerPx;
      g(0, 'LINE');
      g(8, kDxfLayerAnno);
      g(10, ax);
      g(20, ay);
      g(11, bx);
      g(21, by);
      g(0, 'TEXT');
      g(8, kDxfLayerAnno);
      g(10, (ax + bx) / 2);
      g(20, (ay + by) / 2);
      g(40, textH * 0.8);
      g(1, label);
    }

    for (final id in riserNodeIds) {
      final n = net.nodeById(id)!;
      final col = nearestAxis(grid.columns, n.x);
      if (col != null) {
        final off = formatTieOffsetMm((n.x - col.position).abs(), metersPerPixel);
        if (off != null) tieDim(col.position, n.y, n.x, n.y, off);
      }
      final row = nearestAxis(grid.rows, n.y);
      if (row != null) {
        final off = formatTieOffsetMm((n.y - row.position).abs(), metersPerPixel);
        if (off != null) tieDim(n.x, row.position, n.x, n.y, off);
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
