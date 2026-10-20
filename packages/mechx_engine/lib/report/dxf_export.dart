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
import '../sizing/drainage_advisory.dart' show laidGravitySlope;
import '../sizing/network_sizing.dart';
import '../units.dart';
import 'drawing_chrome.dart';
import 'plan_annotation_layout.dart';
import 'plan_symbols.dart';
import 'sld_sheet.dart';

/// Round 10 (mech-drawing-props-2) — the neutral (grey) layer an UNCONNECTED
/// component's glyph is drawn on: no incident edge ⇒ no service layer to own
/// it, but the equipment is still on the sheet.
const String kDxfLayerUnconnected = 'M-EQPM-NCON';

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

/// Render the [sheetId]/[floorIndex] slice of [net] as a DXF document.
///
/// With [metersPerPixel] null the output is the legacy ENTITIES-only
/// pixel-space document — byte-identical to before the parameter existed.
/// With the sheet calibration supplied, coordinates are multiplied to
/// MILLIMETRES so every run measures true in CAD, and the document gains a
/// HEADER (`$ACADVER` AC1009 + `$LTSCALE`; Round 27 — no R2000 `$INSUNITS` /
/// group-370 lineweights in an R12 file), a TABLES section
/// (LTYPE + one LAYER per present service + annotation/frame layers), AIA-style
/// layer names, group 6 linetypes, and
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
///
/// R6: [sheetPlot] is how the sheet is issued — pass `planSheetPlot` (the
/// plan PDF's own snapped `1 : N` + its frame/title-block limits) so every
/// annotation is sized to the SAME paper dimensions as the PDF, dodges the
/// same sheet limits, and the shared annotation layout makes identical label
/// choices in both formats. Null estimates N from the extent on A3
/// (`a3PlottedScaleDenominatorFor`) with no sheet limits.
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
  PlanSheetPlot? sheetPlot,
  String? projectName,
}) {
  if (metersPerPixel != null && metersPerPixel > 0) {
    return _professionalDxf(
      projectName: projectName ?? '',
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
      sheetPlot: sheetPlot,
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
            ? gravitySlopeLabel(
                laidGravitySlope(e, gravitySlope, s.diameter.inMillimeters))
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
    // Round 10 (mech-drawing-props-2) — an unconnected component keeps its
    // glyph (neutral layer) and joins the chrome extent.
    final layer = svc?.name ?? kDxfLayerUnconnected;
    include(n.x, -n.y);
    final comp = n.component;
    if (comp != null) {
      emitPrims(planComponentPrims(comp, cx: n.x, cy: -n.y, size: 16),
          layer, -n.y);
    } else if (n.role == NodeRole.fixture) {
      emitPrims(planFixturePrims(cx: n.x, cy: -n.y, size: 16), layer, -n.y);
    }
    // G1: the stable equipment tag (`P-01` …) as TEXT beside the glyph;
    // Round 33 — a plumbing fixture's plan code (WC / LAV …) likewise.
    final eqTag = nodeTags?[n.id] ?? fixturePlanCode(n);
    if (eqTag != null && eqTag.isNotEmpty) {
      g(0, 'TEXT');
      g(8, layer);
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
  required PlanSheetPlot? sheetPlot,
  required String projectName,
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
  // Round 10 (mech-drawing-props-2) — every on-floor node joins the extent
  // (the plan PDF's `planFitBounds` rule), so an unconnected component is
  // inside the chrome-anchoring extent; an unconnected GLYPH is drawn on the
  // neutral [kDxfLayerUnconnected] layer (its tag used to float alone).
  var hasUnconnectedGlyph = false;
  for (final n in net.nodes) {
    if (!onFloor(n)) continue;
    include(n.x * mmPerPx, -n.y * mmPerPx);
    if (!net.edges.any((e) => e.fromId == n.id || e.toId == n.id) &&
        (n.component != null || n.role == NodeRole.fixture)) {
      hasUnconnectedGlyph = true;
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
  final plotN = (sheetPlot != null && sheetPlot.scaleDenominator > 0)
      ? sheetPlot.scaleDenominator
      : a3PlottedScaleDenominatorFor(maxX - minX, maxY - minY);
  // R6: model millimetres per PAPER millimetre — the plotted-scale
  // denominator, else the span/80 estimate expressed per 2.5 mm of text. Every
  // annotation is sized in paper mm × this (the plan PDF's paper sizes).
  final u = plotN != null ? plotN.toDouble() : span / 80 / kMinPlotTextMm;
  final textH = kMinPlotTextMm * u;

  // ── HEADER: millimetre drawing units, metric measurement ────────────────────
  g(0, 'SECTION');
  g(2, 'HEADER');
  // drafting-5: declare the R12 format the file is written in.
  g(9, r'$ACADVER');
  g(1, 'AC1009');
  // Round 27 (export-files-2-4) — R12 has no $INSUNITS / $MEASUREMENT
  // (R2000 / R14 variables), so none is written; the coordinates stay 1:1 mm
  // and the title block's SCALE row states the plotted 1 : N.
  // Round 24 — the model is real-world millimetres, so the LTYPE dashes must
  // be scaled to plot at the PDF's paper dash (PDF == DXF linetype parity).
  g(9, r'$LTSCALE');
  g(40, dxfLtScaleFor(u).toStringAsFixed(4));
  g(0, 'ENDSEC');

  // ── TABLES: LTYPE + one LAYER per present service + ANNO/FRAME (+ chrome) ──
  final hasChrome = chrome != null && !chrome.isEmpty;
  b.write(dxfTablesSection(layers: [
    for (final s in services)
      (dxfLayerNameFor(s), serviceAciColorFor(s), dxfLinetypeFor(s)),
    (kDxfLayerAnno, 7, 'CONTINUOUS'),
    (kDxfLayerFrame, 7, 'CONTINUOUS'),
    // Round 10: the neutral layer for unconnected equipment, only when used.
    if (hasUnconnectedGlyph) (kDxfLayerUnconnected, 8, 'CONTINUOUS'),
    // A1: the grey floor-plan underlay layer, declared only when present.
    if (underlay != null) (kDxfLayerUnderlay, kDxfUnderlayAci, 'CONTINUOUS'),
    // N4: the grey setting-out grid layer (chain linetype), only when present.
    if (grid != null && !grid.isEmpty) (kDxfLayerGrid, 8, 'DASHDOT'),
    // drafting-4: the tie dimensions' own layer (grey), with the grid.
    if (grid != null && !grid.isEmpty) (kDxfLayerDims, 8, 'CONTINUOUS'),
    // Round 14 (drafting-visual-5) — the plan chrome rides the G-ANNO-*
    // layers (the title block on G-ANNO-TTLB, declared above).
    if (hasChrome) ...const [
      (kDxfLayerLegend, 7, 'CONTINUOUS'),
      (kDxfLayerScale, 7, 'CONTINUOUS'),
      (kDxfLayerNorth, 7, 'CONTINUOUS'),
    ],
  ]));

  g(0, 'SECTION');
  g(2, 'ENTITIES');

  // A1: the floor-plan underlay is re-emitted FIRST (millimetre frame) so the
  // network entities land above it.
  if (underlay != null) {
    b.write(dxfUnderlayEntities(underlay, unitsPerSheetPx: mmPerPx));
  }

  // R6: ONE annotation layout with the plan PDF — `layoutPlanAnnotations`
  // places the grid marks, UP/DN marks, tie dimensions and every tag in model
  // millimetres at [unitsPerMm] model mm per PAPER mm (the plotted scale), so
  // at the same plotted scale the DXF makes the PDF's exact line splits and
  // slot choices. Compose the labels through the PDF's composer pair.
  // Round 10 (mech-drawing-props-1) — the SAME composition rule as the plan
  // PDF (`composePlanEdgeLabels`): an unsized run is tagged with its take-off
  // length here too, so both formats make identical slot choices.
  final edgeLabels = composePlanEdgeLabels(
    net: net,
    sizeText: (e) {
      final s = sizing[e.id];
      return s != null ? _sizeLabel(e, s) : null;
    },
    // Round 33 — the laid fall of a drainage run reads its own sized bore.
    diameterMmOf: (e) => sizing[e.id]?.diameter.inMillimeters,
    // A run's real length: the caller's §10 map, else its calibrated
    // horizontal length (pixel length × m/px) — this path is always
    // calibrated, so the take-off length is never fabricated. A riser prints
    // only a §10 length from the caller.
    lengthOf: (e) {
      final given = edgeLengths?[e.id];
      if (given != null || e.kind != EdgeKind.run) return given;
      final a = net.nodeById(e.fromId);
      final c = net.nodeById(e.toId);
      if (a == null || c == null) return null;
      return Length(math.sqrt(
              (c.x - a.x) * (c.x - a.x) + (c.y - a.y) * (c.y - a.y)) *
          metersPerPixel);
    },
    edgeTags: edgeTags,
    edgeElevationLabels: edgeElevationLabels,
    gravitySlope: gravitySlope,
  );
  // Round 24 — a sized duct is drawn TRUE-WIDTH (its real W / Ø in model
  // mm, double line) when that width reaches kPlanDuctDoubleLineMinMm on
  // paper at the plotted scale — the same rule as the plan PDF. Round 24
  // (r2): only on a REAL plotted scale ([plotN]), like the PDF's
  // `pointsPerMeter != null` gate — an NTS sheet (no ladder scale) keeps the
  // single band stroke in BOTH formats, never double-lined on the u = span/80
  // heuristic alone.
  final ductHalfMm = <String, double>{};
  if (plotN != null) {
    for (final e in net.edges) {
      if (e.kind != EdgeKind.run) continue;
      final w = planDuctWidthM(sizing[e.id]);
      if (w == null) continue;
      final mm = w * 1000;
      if (mm / u >= kPlanDuctDoubleLineMinMm) ductHalfMm[e.id] = mm / 2;
    }
  }
  final ann = layoutPlanAnnotations(
    runHalfWidths: ductHalfMm,
    net: net,
    sheetId: sheetId,
    floorIndex: floorIndex,
    map: (x, y) => (x: x * mmPerPx, y: -y * mmPerPx),
    unitsPerMm: u,
    edgeLabels: edgeLabels,
    nodeTags: nodeTags,
    grid: hasGrid ? grid : null,
    // The grid spans the drawn extent (mm, y-up) — back in sheet pixels.
    gridExtentPx: (
      minX: minX / mmPerPx,
      minY: -maxY / mmPerPx,
      maxX: maxX / mmPerPx,
      maxY: -minY / mmPerPx,
    ),
    // This path is always calibrated, so the tie dimension is honest.
    metersPerPixel: metersPerPixel,
    // The issued sheet's limits (outside the frame, the title block), mapped
    // from sheet pixels to model mm (Y negated), exactly as the PDF seeds them.
    occupied: [
      for (final o in sheetPlot?.occupiedPx ?? const <LabelBox>[])
        (
          minX: o.minX * mmPerPx,
          minY: -o.maxY * mmPerPx,
          maxX: o.maxX * mmPerPx,
          maxY: -o.minY * mmPerPx,
        ),
    ],
  );

  // N4: the reference setting-out grid — chain column/row LINEs + bubble
  // CIRCLE/TEXT on the grey grid layer, spanning the drawing extent (mm).
  for (final gm in ann.grid) {
    g(0, 'LINE');
    g(8, kDxfLayerGrid);
    g(10, gm.line.x1);
    g(20, gm.line.y1);
    g(11, gm.line.x2);
    g(21, gm.line.y2);
    g(0, 'CIRCLE');
    g(8, kDxfLayerGrid);
    g(10, gm.bubbleX);
    g(20, gm.bubbleY);
    g(40, gm.bubbleR);
    g(0, 'TEXT');
    g(8, kDxfLayerGrid);
    g(10, gm.bubbleX - textH * 0.55 * gm.label.length / 2);
    g(20, gm.bubbleY - textH / 2);
    g(40, textH);
    g(1, gm.label);
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

  // Edges: run LINEs (+ flow chevrons) and riser marker CIRCLEs, each at the
  // plotted marker size (R6: paper-sized like the plan PDF's).
  for (final e in net.edges) {
    final a = net.nodeById(e.fromId);
    final c = net.nodeById(e.toId);
    if (a == null || c == null) continue;
    if (e.kind == EdgeKind.run) {
      if (!onFloor(a) || !onFloor(c)) continue;
      final ax = a.x * mmPerPx, ay = -a.y * mmPerPx;
      final cx = c.x * mmPerPx, cy = -c.y * mmPerPx;
      final s = sizing[e.id];
      final half = ductHalfMm[e.id];
      if (half != null) {
        // Round 24 — true-width double-line duct (outline at ±W/2, real mm).
        for (final o in planDoubleLineOutline(ax, ay, cx, cy, half)) {
          g(0, 'LINE');
          g(8, dxfLayerNameFor(e.service));
          g(6, dxfLinetypeFor(e.service));
          g(10, o.x1);
          g(20, o.y1);
          g(11, o.x2);
          g(21, o.y2);
        }
      } else {
        g(0, 'LINE');
        g(8, dxfLayerNameFor(e.service));
        g(6, dxfLinetypeFor(e.service));
        // Round 27 — no group-370 lineweight under AC1009 (R12 has none);
        // the A6 stroke bands print in the plan PDF.
        g(10, ax);
        g(20, ay);
        g(11, cx);
        g(21, cy);
      }
      // A5 flow arrow on a sized, oriented, long-enough run.
      if (s != null && s.flowFromId != null) {
        final len = math.sqrt((cx - ax) * (cx - ax) + (cy - ay) * (cy - ay));
        // Round 10 (mech-drawing-props-5) — sized in PAPER units like the
        // glyphs (and the plan PDF's 30 pt threshold / 5 pt arm): model mm =
        // points × (paper mm per pt) × u (model mm per paper mm), so the
        // chevron no longer depends on how the sheet was calibrated.
        const ptMm = kPlanPaperMmPerPt;
        if (len > 30 * ptMm * u) {
          final upIsA = s.flowFromId == a.id;
          flowChevron(upIsA ? ax : cx, upIsA ? ay : cy, upIsA ? cx : ax,
              upIsA ? cy : ay, len, dxfLayerNameFor(e.service), 5 * ptMm * u);
        }
      }
    } else {
      for (final n in [a, c]) {
        if (!onFloor(n)) continue;
        g(0, 'CIRCLE');
        g(8, dxfLayerNameFor(e.service));
        g(6, dxfLinetypeFor(e.service));
        g(10, n.x * mmPerPx);
        g(20, -n.y * mmPerPx);
        g(40, kPlanRiserMarkerMm * u);
      }
    }
  }
  // A5: each riser's UP/DN sense on the ANNO layer (a clear quadrant — R6).
  for (final m in ann.upDown) {
    g(0, 'TEXT');
    g(8, kDxfLayerAnno);
    g(10, m.x);
    g(20, m.y);
    g(40, m.textSize);
    g(1, m.text);
  }

  // A5 node symbols: an equipment glyph for a component node, a drop triangle
  // for a fixture-role node; plain junctions unchanged. On the node's dominant
  // service layer, at the plotted glyph size (R6: the plan PDF's).
  for (final n in net.nodes) {
    if (!onFloor(n)) continue;
    final svc = domService(n);
    // Round 10 (mech-drawing-props-2) — an UNCONNECTED component / fixture
    // still draws its glyph (on the neutral layer, as the PDF draws it in a
    // neutral grey) so its equipment tag never floats without a symbol.
    final layer = svc == null ? kDxfLayerUnconnected : dxfLayerNameFor(svc);
    final cyMm = -n.y * mmPerPx;
    final comp = n.component;
    if (comp != null) {
      emitPrims(
          planComponentPrims(comp,
              cx: n.x * mmPerPx, cy: cyMm, size: kPlanGlyphSizeMm * u),
          layer,
          cyMm);
    } else if (n.role == NodeRole.fixture) {
      emitPrims(
          planFixturePrims(
              cx: n.x * mmPerPx, cy: cyMm, size: kPlanGlyphSizeMm * u),
          layer,
          cyMm);
    }
  }

  // N4: per-riser TIE dimensions on their own grey layer — two extension lines,
  // the offset dimension line, two 45-degree oblique ticks (R12 has no DIMSTYLE
  // table here, so the dimension is drawn as LINE entities) + the figure.
  for (final t in ann.ties) {
    for (final l in [t.axisExtension, t.riserExtension, t.dimension, ...t.ticks]) {
      g(0, 'LINE');
      g(8, kDxfLayerDims);
      g(10, l.x1);
      g(20, l.y1);
      g(11, l.x2);
      g(21, l.y2);
    }
    g(0, 'TEXT');
    g(8, kDxfLayerDims);
    g(10, t.textX);
    g(20, t.textY);
    g(40, t.textSize);
    g(1, t.text);
  }

  // Every tag (runs, equipment G1, risers N13) as TEXT on the ANNO layer, one
  // entity per line, parallel to its run, + its leader when escaped.
  for (final l in ann.labels) {
    final p = l.placement;
    for (final line in p.lines) {
      g(0, 'TEXT');
      g(8, kDxfLayerAnno);
      g(10, line.x);
      g(20, line.y);
      g(40, l.textSize);
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

  // Round 24 — the overlap warning (same text as the PDF), above the extent.
  final overlapNote = planOverlapWarning(ann.overlapCount);
  if (overlapNote != null) {
    g(0, 'TEXT');
    g(8, kDxfLayerAnno);
    g(62, 1);
    g(10, minX);
    g(20, maxY + 2 * textH);
    g(40, textH);
    g(1, overlapNote);
  }

  // ── Issuable-document chrome (opt-in), anchored to the mm extent ────────────
  // With a grid, the extent already spans every axis; the column bubbles hang
  // a further gap + 2 × bubble radius above it and the row bubbles the same to
  // its left, so the chrome anchor clears those too.
  if (hasChrome) {
    final bubblePad =
        hasGrid ? (2 * kPlanGridBubbleMm + kPlanGridBubbleGapMm) * u : 0.0;
    b.write(dxfPlanChrome(chrome,
        minX: minX - bubblePad,
        minY: minY,
        maxX: maxX,
        maxY: maxY + bubblePad,
        unitsPerPaperMm: u,
        plotDenominator: plotN,
        projectName: projectName));
  }

  g(0, 'ENDSEC');
  g(0, 'EOF');
  return b.toString();
}
