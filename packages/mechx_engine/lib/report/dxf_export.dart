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
import '../units.dart';
import 'drawing_chrome.dart';
import 'plan_symbols.dart';
import 'sld_sheet.dart';

String _sizeLabel(NetEdge e, EdgeSizing s) {
  if (s.isRectangular) {
    return '${s.width!.inMillimeters.round()}x${s.height!.inMillimeters.round()}';
  }
  final mm = s.diameter.inMillimeters.round();
  // R5: the real diameter sign — WinAnsi 0xD8 in the PDF (pass-through in
  // `_pdfText`), `%%c` in the DXF (via `dxfText`). The live canvas keeps its
  // own ASCII `O` (Roboto lacks the glyph).
  return e.service.isAir ? '\u00D8$mm' : 'DN$mm';
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
///
/// With [nodeTags] present (G1) each `node id → equipment tag` (`P-01` …, from
/// `equipmentNodeTags`) is emitted as a TEXT beside that equipment glyph. With
/// [gravitySlope] present (G5) each gravity run's size TEXT gains the laid fall
/// `1:N` from that real `SizingContext.drainageSlope`. Both null ⇒
/// byte-identical.
///
/// On the professional (calibrated) path every sized run/riser label is
/// composed by the SAME `composePlanEdgeLabel` the annotated plan PDF uses —
/// `<tag> · <size> - <length> - <CL> - <fall>` — so the two formats of one
/// sheet carry identical take-off data (audit 2026-10 drawing-output-7).
/// [edgeLengths] supplies the real §10 lengths (the same map the caller passes
/// to `planToPdf`); a RUN absent from it falls back to its calibrated
/// horizontal length (pixel length × [metersPerPixel]), while a riser needs
/// the elevation delta and so prints a length only from the map.
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
  Map<String, String>? nodeTags,
  double? gravitySlope,
  Map<String, Length>? edgeLengths,
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
      nodeTags: nodeTags,
      gravitySlope: gravitySlope,
      edgeLengths: edgeLengths,
    );
  }

  final b = StringBuffer();
  void g(int code, Object value) {
    b.writeln(code);
    // drafting-5: every string value is code-page-safe ASCII (no raw `·`).
    b.writeln(value is String ? dxfText(value) : value);
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
        // G5: the laid fall (`1:100`) for a gravity RUN, from the real ctx
        // gradient (never hardcoded).
        final slope = (e.service.regime == FlowRegime.gravity &&
                gravitySlope != null)
            ? gravitySlopeLabel(gravitySlope)
            : null;
        final size = [
          _sizeLabel(e, s),
          if (elev != null && elev.isNotEmpty) elev,
          if (slope != null) slope,
        ].join(' - ');
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
    // G1: the stable equipment tag (`P-01` …) as TEXT beside the glyph.
    final eqTag = nodeTags?[n.id];
    if (eqTag != null && eqTag.isNotEmpty) {
      g(0, 'TEXT');
      g(8, svc.name);
      g(10, n.x + 12);
      g(20, -n.y - 14);
      g(40, 12);
      g(1, eqTag);
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
  required Map<String, String>? nodeTags,
  required double? gravitySlope,
  required Map<String, Length>? edgeLengths,
}) {
  final b = StringBuffer();
  void g(int code, Object value) {
    b.writeln(code);
    // drafting-5: every string value is code-page-safe ASCII (no raw `·`).
    b.writeln(value is String ? dxfText(value) : value);
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
  // N4 (audit 2026-10 drawing-output-3/-4): every setting-out axis joins the
  // extent, so column lines span every row axis (and vice versa) instead of
  // stopping at the network's own extent, and the chrome anchored to this
  // extent is placed OUTSIDE the grid rather than over it. Only when there is
  // drawn content to grid (as the grid itself is only drawn then); no grid ⇒
  // byte-identical.
  final hasGrid = grid != null && !grid.isEmpty && minX.isFinite;
  if (hasGrid) {
    for (final ax in grid.columns) {
      include(ax.position * mmPerPx, maxY);
    }
    for (final ay in grid.rows) {
      include(minX, -ay.position * mmPerPx);
    }
  }
  if (!minX.isFinite) {
    minX = 0;
    minY = 0;
    maxX = 1;
    maxY = 1;
  }
  final span = math.max(math.max(maxX - minX, maxY - minY), 1.0);
  // drafting-6: annotation text is kMinPlotTextMm (2.5 mm) on PAPER at the
  // standard scale this extent plots at on A3 (the ladder the plan PDF snaps
  // to), e.g. 250 mm model height at 1 : 100. Only when no ladder scale fits
  // (a plan too large even for 1 : 1000) does it fall back to the span/80
  // estimate.
  final plotN = a3PlottedScaleDenominatorFor(maxX - minX, maxY - minY);
  final textH = plotN != null ? kMinPlotTextMm * plotN : span / 80;

  // ── HEADER: millimetre drawing units, metric measurement ────────────────────
  g(0, 'SECTION');
  g(2, 'HEADER');
  // drafting-5: declare the R12 format the file is written in.
  g(9, r'$ACADVER');
  g(1, 'AC1009');
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
    // drafting-4: the tie dimensions' own layer (grey), with the grid.
    if (grid != null && !grid.isEmpty) (kDxfLayerDims, 8, 'CONTINUOUS'),
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
    final bubbleR = textH;
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

  // R5: ONE placement model with the plan PDF — the shared `placePlanLabel`
  // over a `PlanLabelLayout` seeded with every on-floor run (keyed by edge id)
  // and every node glyph / grid bubble, so a tag stays beside its own run,
  // splits to two lines before escaping, and never overprints another service
  // when a clear slot exists (millimetre model space here, points in the PDF).
  final layout = PlanLabelLayout();
  for (final e in net.edges) {
    if (e.kind != EdgeKind.run) continue;
    final a = net.nodeById(e.fromId);
    final c = net.nodeById(e.toId);
    if (a == null || c == null || !onFloor(a) || !onFloor(c)) continue;
    layout.addRun(e.id, a.x * mmPerPx, -a.y * mmPerPx, c.x * mmPerPx,
        -c.y * mmPerPx);
  }
  for (final n in net.nodes) {
    if (!onFloor(n)) continue;
    final r = (n.component != null || n.role == NodeRole.fixture ? 8.0 : 3.0) *
        mmPerPx;
    final x = n.x * mmPerPx, y = -n.y * mmPerPx;
    layout.addBox((minX: x - r, minY: y - r, maxX: x + r, maxY: y + r));
  }
  if (grid != null && !grid.isEmpty && maxX.isFinite) {
    final r = textH;
    for (final ax in grid.columns) {
      final gx = ax.position * mmPerPx;
      layout.addBox(
          (minX: gx - r, minY: maxY, maxX: gx + r, maxY: maxY + 2 * r));
    }
    for (final ay in grid.rows) {
      final gy = -ay.position * mmPerPx;
      layout.addBox(
          (minX: minX - 2 * r, minY: gy - r, maxX: minX, maxY: gy + r));
    }
  }
  // R5: a point feature's tag may also sit on its LEFT — the stations of the
  // mirrored pseudo-run, tried after the right side (exactly like the PDF).
  List<({double x, double y})> mirrorStations(
          double px, double py, double gap, double w) =>
      [for (final t in const [0.5, 0.75, 0.25]) (x: px - gap - w * t, y: py)];

  // Emit a placed label (one TEXT per line) + its leader on the ANNO layer.
  void emitLabel(LeaderedLabelPlacement p) {
    for (final line in p.lines) {
      g(0, 'TEXT');
      g(8, kDxfLayerAnno);
      g(10, line.x);
      g(20, line.y);
      g(40, textH);
      g(1, line.text);
      g(50, p.angleDeg.toStringAsFixed(1));
    }
    final lead = p.leaderAnchor;
    final end = p.leaderEnd;
    if (lead != null && end != null) {
      g(0, 'LINE');
      g(8, kDxfLayerAnno);
      g(10, lead.x);
      g(20, lead.y);
      g(11, end.x);
      g(21, end.y);
    }
  }

  final riserLabelJobs =
      <({double nx, double x0, double y0, String text, List<String>? split})>[];
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
        // G5: the laid fall (`1:100`) for a gravity RUN, from the real ctx
        // gradient (never hardcoded).
        final slope = (e.service.regime == FlowRegime.gravity &&
                gravitySlope != null)
            ? gravitySlopeLabel(gravitySlope)
            : null;
        // The run's real length: the caller's §10 map, else its calibrated
        // horizontal length (pixel length × m/px) — this path is always
        // calibrated, so the take-off length is never fabricated.
        final len = edgeLengths?[e.id] ??
            Length(math.sqrt((c.x - a.x) * (c.x - a.x) +
                    (c.y - a.y) * (c.y - a.y)) *
                metersPerPixel);
        // N13 + N5 + G5 through the ONE composer the plan PDF uses
        // (`CW-F2 · DN50 - 4.4 m - CL +2.70`), so PDF == DXF.
        final lengthText = len.meters > 0 ? planLengthLabel(len) : null;
        final labelText = composePlanEdgeLabel(
          tag: edgeTags?[e.id],
          size: _sizeLabel(e, s),
          length: lengthText,
          elevation: elev,
          slope: slope,
        )!;
        // A7/N3/R5 label discipline: parallel to the run on the ANNO layer,
        // beside it first (either side, several stations), split to two lines
        // before escaping; an escaped tag is tied back by a capped leader —
        // never dropped, never fused (see `placePlanLabel`).
        final p = placePlanLabel(
            ax: ax,
            ay: ay,
            bx: cx,
            by: cy,
            text: labelText,
            textSize: textH,
            layout: layout,
            ownRunId: e.id,
            splitLines: composePlanEdgeLabelLines(
              tag: edgeTags?[e.id],
              size: _sizeLabel(e, s),
              length: lengthText,
              elevation: elev,
              slope: slope,
            ));
        emitLabel(p);
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
      final rs = sizing[e.id];
      final rLen = edgeLengths?[e.id];
      final rLenText =
          (rLen != null && rLen.meters > 0) ? planLengthLabel(rLen) : null;
      final riserLabel = composePlanEdgeLabel(
        tag: edgeTags?[e.id],
        size: rs != null ? _sizeLabel(e, rs) : null,
        length: rLenText,
        elevation: edgeElevationLabels?[e.id],
      );
      final riserSplit = composePlanEdgeLabelLines(
        tag: edgeTags?[e.id],
        size: rs != null ? _sizeLabel(e, rs) : null,
        length: rLenText,
        elevation: edgeElevationLabels?[e.id],
      );
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
          // The UP/DN mark is occupied, so the riser tag dodges it.
          final ux = n.x * mmPerPx + 12 * mmPerPx, uy = -n.y * mmPerPx;
          layout.addBox((
            minX: ux,
            minY: uy,
            maxX: ux + sense.length * textH * 0.55,
            maxY: uy + textH,
          ));
        }
        // N13: the riser stack tag (`CW-R1`) below the marker on the ANNO
        // layer, so the plan DXF carries the same riser id the single-line +
        // BOM do — now with its size + §10 length, composed exactly like the
        // plan PDF's riser label (`CW-R1 · DN32 - 4 m`; drawing-output-7).
        // R5: placed through the SAME placer as the plan PDF's riser tag (a
        // short pseudo-run just right of the marker), so it dodges the UP/DN
        // mark + the runs and splits / leaders exactly like the PDF.
        // Deferred to after the tie dimensions (the PDF's order), so the tag
        // dodges the marker + UP/DN + tie lines/figures.
        if (riserLabel != null) {
          riserLabelJobs.add((
            nx: n.x * mmPerPx,
            x0: n.x * mmPerPx + 12 * mmPerPx,
            y0: -n.y * mmPerPx,
            text: riserLabel,
            split: riserSplit,
          ));
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
    // G1: the stable equipment tag (`P-01` …) as real-mm TEXT on the ANNO
    // layer beside the glyph.
    final eqTag = nodeTags?[n.id];
    if (eqTag != null && eqTag.isNotEmpty) {
      // R5: placed like the plan PDF's equipment tag (a pseudo-run just right
      // of the glyph) so it dodges the run tags + other marks.
      final x0 = n.x * mmPerPx + 12 * mmPerPx;
      final w = eqTag.length * textH * 0.55;
      emitLabel(placePlanLabel(
          ax: x0,
          ay: cyMm,
          bx: x0 + w,
          by: cyMm,
          text: eqTag,
          textSize: textH,
          layout: layout,
          anchorPoint: (x: n.x * mmPerPx, y: cyMm),
          extraStations: mirrorStations(n.x * mmPerPx, cyMm, 12 * mmPerPx, w)));
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
      // drafting-4: mirror the PDF — an OFFSET dimension line with extension
      // lines + 45-degree oblique ticks on its own grey layer, never a bare
      // line on the riser's ordinate (where it overlaid a pipe run). R12 has
      // no DIMSTYLE table here, so the dimension is drawn as LINE entities.
      final dx = bx - ax, dy = by - ay;
      final len = math.sqrt(dx * dx + dy * dy);
      final ux = len > 1e-9 ? dx / len : 1.0;
      final uy = len > 1e-9 ? dy / len : 0.0;
      // The PDF convention (both spaces are y-up): the direction rotated by
      // -90 deg, so the dimension lands on the SAME side in both formats.
      final px = uy, py = -ux;
      final off = textH * 1.2; // ~ the PDF's 10 pt offset at plot scale
      void line(double x1, double y1, double x2, double y2) {
        g(0, 'LINE');
        g(8, kDxfLayerDims);
        g(10, x1);
        g(20, y1);
        g(11, x2);
        g(21, y2);
      }

      final dax = ax + px * off, day = ay + py * off;
      final dbx = bx + px * off, dby = by + py * off;
      final over = off + textH * 0.25;
      final gap = textH * 0.25;
      line(ax + px * gap, ay + py * gap, ax + px * over, ay + py * over);
      line(bx + px * gap * 3, by + py * gap * 3, bx + px * over,
          by + py * over);
      line(dax, day, dbx, dby);
      // R5: the dimension line + figure are occupied for the deferred riser
      // tags (placed after the ties, exactly like the plan PDF).
      layout.addRun(null, dax, day, dbx, dby);
      final tick = textH * 0.25;
      final tkx = (ux + px) * tick / math.sqrt2;
      final tky = (uy + py) * tick / math.sqrt2;
      for (final (ex, ey) in [(dax, day), (dbx, dby)]) {
        line(ex - tkx, ey - tky, ex + tkx, ey + tky);
      }
      g(0, 'TEXT');
      g(8, kDxfLayerDims);
      g(10, (dax + dbx) / 2);
      g(20, (day + dby) / 2 + textH * 0.2);
      // drafting-6: the tie figure at the full minimum text height.
      g(40, textH);
      g(1, label);
      final tx0 = (dax + dbx) / 2, ty0 = (day + dby) / 2 + textH * 0.2;
      layout.addBox((
        minX: tx0,
        minY: ty0,
        maxX: tx0 + label.length * textH * 0.55,
        maxY: ty0 + textH,
      ));
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

  // R5: the deferred riser tags — the SAME placer + pseudo-run as the PDF.
  for (final job in riserLabelJobs) {
    final w = job.text.length * textH * 0.55;
    emitLabel(placePlanLabel(
        ax: job.x0,
        ay: job.y0,
        bx: job.x0 + w,
        by: job.y0,
        text: job.text,
        textSize: textH,
        layout: layout,
        splitLines: job.split,
        anchorPoint: (x: job.nx, y: job.y0),
        extraStations:
            mirrorStations(job.nx, job.y0, job.x0 - job.nx, w)));
  }

  // ── Issuable-document chrome (opt-in), anchored to the mm extent ────────────
  // With a grid, the extent already spans every axis; the column bubbles hang
  // a further 2 × bubbleR (= 2 × textH) above it and the row bubbles the same
  // to its left, so the chrome anchor clears those too.
  if (hasChrome) {
    final bubblePad = hasGrid ? 2 * textH : 0.0;
    b.write(dxfChrome(chrome,
        minX: minX - bubblePad,
        minY: minY,
        maxX: maxX,
        maxY: maxY + bubblePad));
  }

  g(0, 'ENDSEC');
  g(0, 'EOF');
  return b.toString();
}
