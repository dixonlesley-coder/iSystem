/// Native ANNOTATED plan PDF export — a self-contained vector drawing of one
/// sheet/floor's drawn network with NO third-party dependency, modelled on
/// `electrical_pdf_export.dart`. A richer companion to `pdf_export.dart`
/// (`networkToPdf`): it adds real run/riser LENGTHS to each size label
/// (e.g. `DN50 · 3.5 m`), small node dots, riser markers, and a title block
/// (project name + sheet name + a date STRING the caller passes — the engine
/// never reads the clock).
///
/// A single landscape page (A3 by default; A2/A1 via `paper`). Runs become
/// coloured stroked LINES on a
/// per-service colour with an A6 three-band line-weight hierarchy + the
/// per-service dash pattern, risers a small circle marker at their on-floor
/// node, nodes small filled dots, and each sized edge a TEXT label rotated to
/// its edge bearing with greedy collision avoidance (A7). The drawing is
/// auto-fitted (uniform scale, centred) into the page with a margin — and
/// SNAPPED to a standard plotted scale when the caller passes the sheet
/// calibration (A3). PDF space is y-up, so the screen-space (y-down)
/// coordinates are flipped during the fit.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../network/network.dart';
import '../sizing/network_sizing.dart';
import '../units.dart';
import 'drawing_chrome.dart';
import 'plan_annotation_layout.dart';
import 'plan_symbols.dart';
import 'sld_sheet.dart';

/// Per-service stroke colour as RGB in the 0..1 range (no Flutter `Color`).
/// Delegates to the ONE shared `serviceChromeColor` table (E2) — matches
/// `pdf_export.dart` AND the live canvas `serviceColor`, so the annotated /
/// plain PDFs and the on-screen line read the same colour.
(double, double, double) _serviceColor(ServiceType s) => serviceChromeColor(s);

/// The size half of an edge label: `DN50` (pipe), `Ø200` (round duct — the
/// WinAnsi O-stroke, R5), or `200x100` (rectangular duct).
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

/// WinAnsi (Latin-1) code points the drawing labels legitimately emit, passed
/// through as their own byte (code point == WinAnsi byte at these positions) so
/// a `/WinAnsiEncoding` Helvetica renders the real glyph, not `?`: U+00B7
/// middle-dot separator (SIZE·SERVICE / cable·conduit), U+00B0 degree, U+00B1
/// plus-minus, U+00B2/00B3 super-2/3, U+00D8/00F8 O-stroke.
const _winAnsiPassThrough = {0xB0, 0xB1, 0xB2, 0xB3, 0xB7, 0xD8, 0xF8};

/// Keep PDF text to WinAnsi-encodable characters (printable ASCII + the few
/// Latin-1 glyphs above) and escape the three PDF string metacharacters so a
/// name or label never breaks the syntax; anything else falls back to `?`.
String _pdfText(String raw) {
  final b = StringBuffer();
  for (final code in raw.runes) {
    final c =
        (code >= 0x20 && code <= 0x7e) || _winAnsiPassThrough.contains(code)
            ? code
            : 0x3f /* ? */;
    if (c == 0x28 || c == 0x29 || c == 0x5c) b.writeCharCode(0x5c); // ( ) \
    b.writeCharCode(c);
  }
  return b.toString();
}

String _n(double v) => v.toStringAsFixed(2);

/// A font size: a whole number prints bare (`9`, the long-standing form),
/// anything else to two decimals (`7.09`).
String _fs(double v) =>
    (v - v.roundToDouble()).abs() < 1e-6 ? '${v.round()}' : _n(v);

/// N4 grid bubble radius (points) and the strip it occupies beyond the fitted
/// extent: the bubble centre sits `r + 2` off the line end, so its far edge is
/// `2r + 2` = 20 pt out.
const double _kGridBubbleR = 9.0;
const double _kGridBubblePad = 2 * _kGridBubbleR + 2;

/// The plan sheet's fit (shared by [planToPdf] and
/// [planPlottedScaleDenominator]): the page, the fitted sheet-pixel extent
/// (network + underlay + every grid axis), the title-block strip, and the
/// snapped plotted scale.
({
  double pageW,
  double pageH,
  double margin,
  double minX,
  double minY,
  double maxX,
  double maxY,
  bool hasContent,
  bool hasGrid,
  double gridPad,
  bool hasChrome,
  String blockTitle,
  String blockDate,
  double blockH,
  double spanX,
  double spanY,
  double availW,
  double availH,
  double scale,
  String scaleRow,
  double? pointsPerMeter,
  double offX,
  double offY,
  List<LabelBox> occupied,
}) _planSheetFit({
  required Network net,
  required String sheetId,
  required int floorIndex,
  required String projectName,
  required String sheetName,
  required String dateString,
  required DrawingChrome? chrome,
  required double? metersPerPixel,
  required PlanUnderlay? underlay,
  required PaperSize paper,
  required ReferenceGrid? grid,
}) {
  final pageW = paper.widthPt; // landscape sheet width, points
  final pageH = paper.heightPt; // landscape sheet height, points
  const margin = 48.0;

  // ── Bounds of everything we'll draw, in screen pixels (A1: incl. underlay) ──
  final fit = planFitBounds(net, sheetId, floorIndex, underlay);
  var minX = fit.minX, minY = fit.minY, maxX = fit.maxX, maxY = fit.maxY;
  final hasContent = fit.hasContent;
  // N4 grid fit (audit 2026-10 drawing-output-3): a setting-out grid normally
  // spans the whole building while one service's network covers part of it, so
  // EVERY axis joins the fit (else an axis beyond the network lands off the
  // sheet, and row/column lines — drawn across the fitted extent — stop short
  // of the axes they should cross). Its bubbles hang [_kGridBubblePad] points
  // above / left of the extent, reserved from the fit area below. No grid ⇒
  // byte-identical.
  final hasGrid = grid != null && !grid.isEmpty && hasContent;
  if (hasGrid) {
    for (final ax in grid.columns) {
      minX = math.min(minX, ax.position);
      maxX = math.max(maxX, ax.position);
    }
    for (final ay in grid.rows) {
      minY = math.min(minY, ay.position);
      maxY = math.max(maxY, ay.position);
    }
  }
  final gridPad = hasGrid ? _kGridBubblePad : 0.0;
  final hasChrome = chrome != null && !chrome.isEmpty;
  // The title block's TITLE/DATE rows fall back to this function's own
  // sheet-name/date params, so the issued sheet never loses them.
  final blockTitle = hasChrome ? (chrome.drawingTitle ?? sheetName) : sheetName;
  final blockDate = hasChrome ? (chrome.dateString ?? dateString) : dateString;
  // A4: reserve the ISO-7200 title-block strip at the bottom. The row COUNT
  // (so the height) doesn't depend on the final scale text — with chrome the
  // SCALE row is always stamped ('NTS' or '1 : N @ A3') — so probe with a
  // placeholder here and render with the real text after the fit.
  final blockH = hasChrome
      ? pdfTitleBlock(chrome,
              pageW: pageW,
              pageH: pageH,
              margin: margin,
              projectName: projectName,
              scaleTextOverride: 'NTS',
              titleTextOverride: blockTitle,
              dateTextOverride: blockDate)
          .height
      : 0.0;
  final spanX = maxX - minX;
  final spanY = maxY - minY;
  final availW = pageW - 2 * margin - gridPad;
  // Reserve the title-block strip (chrome) or a little headroom for the
  // legacy two-line top-left title (and the grid bubbles' strip on top).
  final availH = pageH - 2 * margin - (hasChrome ? blockH : 24.0) - gridPad;
  var scale = 1.0;
  if (spanX > 0 || spanY > 0) {
    final sx = spanX > 0 ? availW / spanX : double.infinity;
    final sy = spanY > 0 ? availH / spanY : double.infinity;
    scale = math.min(sx, sy);
    if (!scale.isFinite || scale <= 0) scale = 1.0;
  }

  // ── A3 true plotted scale: snap the raw auto-fit to a standard scale, the
  // snapped-scale text naming the ACTUAL paper (`1 : N @ A2`). ───────────────
  final snap = snapPlottedScale(
      rawScale: scale,
      metersPerPixel: metersPerPixel,
      hasContent: hasContent,
      paperLabel: paper.label);
  scale = snap.scale;
  final scaleRow = snap.scaleRow;
  final pointsPerMeter = snap.pointsPerMeter;

  return (
    pageW: pageW,
    pageH: pageH,
    margin: margin,
    minX: minX,
    minY: minY,
    maxX: maxX,
    maxY: maxY,
    hasContent: hasContent,
    hasGrid: hasGrid,
    gridPad: gridPad,
    hasChrome: hasChrome,
    blockTitle: blockTitle,
    blockDate: blockDate,
    blockH: blockH,
    spanX: spanX,
    spanY: spanY,
    availW: availW,
    availH: availH,
    scale: scale,
    scaleRow: scaleRow,
    pointsPerMeter: pointsPerMeter,
    // The grid-bubble strip sits LEFT of and ABOVE the fitted extent.
    offX: margin + gridPad + (availW - spanX * scale) / 2,
    offY: margin + gridPad + (availH - spanY * scale) / 2,
    // Frame discipline (audit 2026-10 drawing-output-5): everything outside
    // the frame (four strips) plus the title-block box is occupied, so every
    // tag picks an in-frame slot.
    occupied: <LabelBox>[
      (minX: -_kFar, minY: -_kFar, maxX: margin, maxY: _kFar), // left
      (minX: pageW - margin, minY: -_kFar, maxX: _kFar, maxY: _kFar), // right
      (minX: -_kFar, minY: -_kFar, maxX: _kFar, maxY: margin), // below
      (minX: -_kFar, minY: pageH - margin, maxX: _kFar, maxY: _kFar), // above
      if (hasChrome && blockH > 0)
        (
          minX: pageW - margin - kPdfTitleBlockWidth,
          minY: margin,
          maxX: pageW - margin,
          maxY: margin + blockH,
        ),
    ],
  );
}

/// "Infinitely" far, for the off-frame occupied strips (points).
const double _kFar = 1e5;

/// R6: how [planToPdf] plots this sheet — its standard plotted scale
/// (`1 : N`) and the sheet area outside its drawing frame + title block, in
/// SHEET PIXELS. Pass it to `networkToDxf(sheetPlot:)` so the DXF sizes every
/// annotation to the same paper dimensions against the same sheet limits, and
/// the shared annotation layout makes the PDF's exact label choices. Null when
/// the PDF is NTS (uncalibrated, empty, or too large for 1 : 1000). Same
/// inputs as [planToPdf]; pure.
PlanSheetPlot? planSheetPlot({
  required Network net,
  required String sheetId,
  required int floorIndex,
  required String projectName,
  required String sheetName,
  required String dateString,
  DrawingChrome? chrome,
  double? metersPerPixel,
  PlanUnderlay? underlay,
  PaperSize paper = PaperSize.a3Landscape,
  ReferenceGrid? grid,
}) {
  final f = _planSheetFit(
      net: net,
      sheetId: sheetId,
      floorIndex: floorIndex,
      projectName: projectName,
      sheetName: sheetName,
      dateString: dateString,
      chrome: chrome,
      metersPerPixel: metersPerPixel,
      underlay: underlay,
      paper: paper,
      grid: grid);
  if (f.pointsPerMeter == null || metersPerPixel == null) return null;
  // Page points → sheet pixels (the inverse of planToPdf's tx / ty).
  double px(double x) => (x - f.offX) / f.scale + f.minX;
  double py(double y) => (f.pageH - f.offY - y) / f.scale + f.minY;
  return PlanSheetPlot(
    scaleDenominator:
        (metersPerPixel * 1000 / (f.scale * kPlanPaperMmPerPt)).round(),
    occupiedPx: [
      for (final o in f.occupied)
        (
          minX: px(o.minX),
          minY: math.min(py(o.minY), py(o.maxY)),
          maxX: px(o.maxX),
          maxY: math.max(py(o.minY), py(o.maxY)),
        ),
    ],
  );
}

/// Render the [sheetId]/[floorIndex] slice of [net] as a single-page ANNOTATED
/// PDF and return its bytes. [edgeLengths] maps edge id → real §10 length (run
/// from calibration, riser from the elevation delta); the caller computes it
/// (the engine's `edgeLength`) and passes it so this stays a pure draw routine.
/// [projectName] / [sheetName] / [dateString] populate the title block — the
/// engine NEVER calls `DateTime.now()`; the caller passes the formatted date.
///
/// With [chrome] present the issued sheet carries an ISO-5457 frame + an
/// ISO-7200 title block bottom-right (PROJECT/TITLE/DATE fed from this
/// function's own params when the chrome doesn't override them) instead of the
/// loose top-left text lines (A4). When [metersPerPixel] (the sheet
/// calibration) is set, the raw auto-fit is SNAPPED to the nearest standard
/// plotted scale (`kPlanScaleLadder`, always the larger denominator so the
/// drawing never draws larger than the honest snap), the SCALE row reads
/// `1 : N @ <paper>` (naming the ACTUAL [paper]), and an honest divided scale
/// bar is drawn from the resulting points-per-metre. When null the sheet is
/// NTS and NO divided bar is printed — a bar at an arbitrary auto-fit ratio is
/// a bar an engineer could scale wrong dimensions from (CAD-OUTPUT-UX-REVIEW
/// A3).
///
/// [paper] selects the landscape sheet size (default A3 ⇒ byte-identical); A2
/// / A1 enlarge the page, margins, fit, chrome anchoring and scale text alike.
///
/// With [edgeElevationLabels] present (N5) each entry's `edge id → label` (e.g.
/// `CL +2.70`, the centreline height above the run's floor FFL, built by the app
/// from the §10 role-aware `nodeElevation`) is APPENDED to that run's size/length
/// label (`DN32 - 4.2 m - CL +2.70`), so a foreman can hang each service at a
/// defensible level. The engine stays pure — it receives the finished strings,
/// never the elevation model. A missing/empty entry ⇒ that run is unchanged.
///
/// With [grid] present (N4) a reference setting-out grid is drawn — thin chain
/// column/row lines with bubble labels, plus a leadered TIE dimension from each
/// riser node to its nearest column + row axis (only when [metersPerPixel] gives
/// a real scale — an unscaled dimension would be fabricated). Null/empty ⇒
/// byte-identical.
///
/// With [edgeTags] present (N13) each entry's `edge id → stable tag` (the riser
/// stack tag `CW-R1` for a riser, `<code>-F<floor>` for a run — built by the app
/// via `elementTags`) is PREPENDED to that edge's label as `<tag> · <size> - …`,
/// so a run/riser on the plan carries the SAME identifier the riser single-line,
/// BOM and calc report use — answering "which run on the plan is CW-R1?". A
/// missing/empty entry ⇒ that edge's label is unchanged; the default empty map ⇒
/// byte-identical.
///
/// With [nodeTags] present (G1) each entry's `node id → equipment tag` (the
/// stable `P-01` / `TK-01` / `AHU-01` from `equipmentNodeTags`) is drawn as a
/// small leader label beside that equipment glyph, so a pump on the plan carries
/// the SAME tag the equipment schedule / BOM use. A missing entry ⇒ that node is
/// unlabelled; the default null map ⇒ byte-identical.
///
/// With [gravitySlope] present (G5) each gravity-regime (drainage / vent /
/// rainwater) RUN's size label gains the laid fall as a drafting ratio `1:N`
/// (e.g. `DN100 - 3.5 m - 1:100`) from that real `SizingContext.drainageSlope`
/// value — never a hardcoded default. Null ⇒ byte-identical.
///
/// With [underlay] present (A1) the floor-plan substrate is painted FIRST,
/// beneath every network stroke: a [VectorPlanUnderlay] as pale-grey thin
/// linework, a [RasterPlanUnderlay] as a FlateDecode image XObject scaled to
/// the sheet frame's fitted rect. The underlay's sheet frame joins the fit
/// bounds so the whole plan lands on the page. Null keeps the output
/// byte-identical.
Uint8List planToPdf({
  required Network net,
  required Map<String, EdgeSizing> sizing,
  required Map<String, Length> edgeLengths,
  required String sheetId,
  required int floorIndex,
  required String projectName,
  required String sheetName,
  required String dateString,
  DrawingChrome? chrome,
  double? metersPerPixel,
  PlanUnderlay? underlay,
  PaperSize paper = PaperSize.a3Landscape,
  Map<String, String>? edgeElevationLabels,
  ReferenceGrid? grid,
  Map<String, String>? edgeTags,
  Map<String, String>? nodeTags,
  double? gravitySlope,
}) {
  bool onFloor(NetNode n) => n.sheetId == sheetId && n.floorIndex == floorIndex;

  final fit0 = _planSheetFit(
      net: net,
      sheetId: sheetId,
      floorIndex: floorIndex,
      projectName: projectName,
      sheetName: sheetName,
      dateString: dateString,
      chrome: chrome,
      metersPerPixel: metersPerPixel,
      underlay: underlay,
      paper: paper,
      grid: grid);
  final pageW = fit0.pageW, pageH = fit0.pageH, margin = fit0.margin;
  final minX = fit0.minX, minY = fit0.minY, maxX = fit0.maxX, maxY = fit0.maxY;
  final hasGrid = fit0.hasGrid;
  final hasChrome = fit0.hasChrome;
  final blockTitle = fit0.blockTitle, blockDate = fit0.blockDate;
  final scale = fit0.scale;
  final scaleRow = fit0.scaleRow;
  final pointsPerMeter = fit0.pointsPerMeter;
  // The grid-bubble strip sits LEFT of and ABOVE the fitted extent.
  final offX = fit0.offX, offY = fit0.offY;
  double tx(double x) => offX + (x - minX) * scale;
  double ty(double y) => (pageH - offY) - (y - minY) * scale; // flip y

  // ── Content stream ─────────────────────────────────────────────────────────
  final cs = StringBuffer();

  // A1: the floor-plan underlay paints FIRST — every network stroke, label and
  // chrome overprints the pale plan.
  switch (underlay) {
    case final VectorPlanUnderlay v:
      cs.write(pdfVectorUnderlayOps(v, tx: tx, ty: ty, pageScale: scale));
    case final RasterPlanUnderlay r:
      cs.write(pdfRasterUnderlayOps(
          x: tx(0),
          y: ty(r.sheetHeightPx),
          w: r.sheetWidthPx * scale,
          h: r.sheetHeightPx * scale));
    case null:
      break;
  }

  if (!hasChrome) {
    // Title block, top-left, two lines (project name; sheet name + date) —
    // an issued sheet carries these in the ISO-7200 title block instead.
    cs.writeln('BT /F1 16 Tf 0 0 0 rg '
        '${_n(margin)} ${_n(pageH - margin + 6)} Td '
        '(${_pdfText(projectName)}) Tj ET');
    final counter = chrome?.sheetCounter;
    cs.writeln('BT /F1 10 Tf 0.25 0.25 0.25 rg '
        '${_n(margin)} ${_n(pageH - margin - 9)} Td '
        '(${_pdfText('$sheetName   -   $dateString'
            '${counter != null ? '   -   Sheet $counter' : ''}')}) Tj ET');
  }

  void strokeColor(ServiceType s) {
    final (r, g, b) = _serviceColor(s);
    cs.writeln('${_n(r)} ${_n(g)} ${_n(b)} RG');
    cs.writeln('${_n(r)} ${_n(g)} ${_n(b)} rg');
  }

  void circle(double cx, double cy, double r, {bool fill = false}) {
    const k = 0.5523;
    cs.writeln('${_n(cx + r)} ${_n(cy)} m');
    cs.writeln('${_n(cx + r)} ${_n(cy + k * r)} ${_n(cx + k * r)} ${_n(cy + r)} '
        '${_n(cx)} ${_n(cy + r)} c');
    cs.writeln('${_n(cx - k * r)} ${_n(cy + r)} ${_n(cx - r)} ${_n(cy + k * r)} '
        '${_n(cx - r)} ${_n(cy)} c');
    cs.writeln('${_n(cx - r)} ${_n(cy - k * r)} ${_n(cx - k * r)} ${_n(cy - r)} '
        '${_n(cx)} ${_n(cy - r)} c');
    cs.writeln('${_n(cx + k * r)} ${_n(cy - r)} ${_n(cx + r)} ${_n(cy - k * r)} '
        '${_n(cx + r)} ${_n(cy)} c');
    cs.writeln(fill ? 'f' : 'S');
  }

  // A5 flow arrow: one small OPEN chevron at the 2/3 point of a long-enough
  // sized run along its flow direction ([upstream]→[downstream] in page
  // points), mirroring the on-canvas `network_layer._flowChevron`.
  void flowChevron(double ux, double uy, double dxp, double dyp, double len,
      ServiceType service) {
    const arm = 5.0;
    final dirx = (dxp - ux) / len, diry = (dyp - uy) / len;
    final perpx = -diry, perpy = dirx;
    final atx = ux + dirx * (len * 2 / 3), aty = uy + diry * (len * 2 / 3);
    final tipx = atx + dirx * (arm * 0.5), tipy = aty + diry * (arm * 0.5);
    final backx = tipx - dirx * arm, backy = tipy - diry * arm;
    final w1x = backx + perpx * (arm * 0.75), w1y = backy + perpy * (arm * 0.75);
    final w2x = backx - perpx * (arm * 0.75), w2y = backy - perpy * (arm * 0.75);
    final (r, g, b) = _serviceColor(service);
    cs.writeln('${_n(r)} ${_n(g)} ${_n(b)} RG');
    cs.writeln('1.60 w');
    cs.writeln('${_n(w1x)} ${_n(w1y)} m ${_n(tipx)} ${_n(tipy)} l S');
    cs.writeln('${_n(w2x)} ${_n(w2y)} m ${_n(tipx)} ${_n(tipy)} l S');
  }

  // A5 node symbol: stroke a plan-symbol prim list (page points, y-DOWN) in
  // the given colour, MIRRORED about the node's baseline [pageCy] (the prims
  // are y-down; the PDF page is y-up). Only [SldLine]/[SldCircle] arise here.
  void strokePrims(
      List<SldPrim> prims, double pageCy, (double, double, double) col) {
    final (r, g, b) = col;
    cs.writeln('${_n(r)} ${_n(g)} ${_n(b)} RG');
    cs.writeln('1.00 w');
    for (final pr in prims) {
      switch (pr) {
        case final SldLine l:
          cs.writeln('${_n(l.x1)} ${_n(2 * pageCy - l.y1)} m '
              '${_n(l.x2)} ${_n(2 * pageCy - l.y2)} l S');
        case final SldCircle cc:
          circle(cc.cx, 2 * pageCy - cc.cy, cc.r);
        case SldRect():
        case SldLabel():
          break; // never produced by the plan-symbol library
      }
    }
  }

  // The service of a node's first incident edge (for its symbol colour), or
  // null when unconnected → neutral dark.
  ServiceType? domService(NetNode n) {
    for (final e in net.edges) {
      if (e.fromId == n.id || e.toId == n.id) return e.service;
    }
    return null;
  }

  // A7/N3/R5/R6 label discipline: every annotation — grid marks, UP/DN marks,
  // tie dimensions, run / riser / equipment tags — comes from the ONE shared
  // `layoutPlanAnnotations` (the DXF calls it too), in page points at 72/25.4
  // points per paper millimetre. A tag rotates to its run's bearing (a `Tm`
  // text matrix), hugs it, splits to two lines before escaping, and an escaped
  // tag ties back with a thin leader — never dropped, never fused.
  //
  // Frame discipline (audit 2026-10 drawing-output-5): the layout is SEEDED
  // with the whole region outside the frame (four strips) plus the title-block
  // box as occupied space, so every tag picks an in-frame slot.
  final occupied = fit0.occupied;

  // Compose every edge's label up front (size · length · CL · fall) through
  // the ONE composer pair the plan DXF uses, so both print the same text.
  final edgeLabels = <String, PlanEdgeLabelText>{};
  for (final e in net.edges) {
    final s = sizing[e.id];
    final len = edgeLengths[e.id];
    final elev = edgeElevationLabels?[e.id];
    final sizeText = s != null ? _sizeLabel(e, s) : null;
    final lenText =
        (len != null && len.meters > 0) ? planLengthLabel(len) : null;
    // G5: the laid fall (`1:100`) for a gravity-regime RUN, from the real ctx
    // gradient the caller passes (never a hardcoded default).
    final slopeText = (e.kind == EdgeKind.run &&
            e.service.regime == FlowRegime.gravity &&
            gravitySlope != null)
        ? gravitySlopeLabel(gravitySlope)
        : null;
    // N5 + N13: `CW-R1 · DN50 - 3.5 m - CL +2.70`. U+00B7 is WinAnsi
    // pass-through, so the separator survives the PDF text encoder.
    final label = composePlanEdgeLabel(
      tag: edgeTags?[e.id],
      size: sizeText,
      length: lenText,
      elevation: elev,
      slope: slopeText,
    );
    if (label == null) continue;
    edgeLabels[e.id] = (
      text: label,
      // R5: the two-line form (`tag · size` over `length - CL - fall`).
      split: composePlanEdgeLabelLines(
        tag: edgeTags?[e.id],
        size: sizeText,
        length: lenText,
        elevation: elev,
        slope: slopeText,
      ),
    );
  }

  final ann = layoutPlanAnnotations(
    net: net,
    sheetId: sheetId,
    floorIndex: floorIndex,
    map: (x, y) => (x: tx(x), y: ty(y)),
    unitsPerMm: 1 / kPlanPaperMmPerPt,
    edgeLabels: edgeLabels,
    nodeTags: nodeTags,
    grid: hasGrid ? grid : null,
    gridExtentPx: (minX: minX, minY: minY, maxX: maxX, maxY: maxY),
    // Tie dimensions only with a real scale (an unscaled one is fabricated).
    metersPerPixel: metersPerPixel,
    occupied: occupied,
  );

  // N4: the reference setting-out grid — thin chain column/row lines with bubble
  // labels — is drawn BENEATH the network (the MEP strokes overprint it).
  if (ann.grid.isNotEmpty) {
    cs.writeln('0.55 0.55 0.55 RG 0.4 w');
    cs.writeln('[8 3 2 3] 0 d'); // chain linetype for a setting-out grid
    for (final g in ann.grid) {
      cs.writeln('${_n(g.line.x1)} ${_n(g.line.y1)} m '
          '${_n(g.line.x2)} ${_n(g.line.y2)} l S');
      circle(g.bubbleX, g.bubbleY, g.bubbleR);
      cs.writeln('BT /F1 8 Tf 0 0 0 rg '
          '${_n(g.bubbleX - g.label.length * 2.2)} ${_n(g.bubbleY - 3)} Td '
          '(${_pdfText(g.label)}) Tj ET');
    }
    cs.writeln('[] 0 d'); // back to solid
  }

  // Edges: lines (runs) + riser markers.
  for (final e in net.edges) {
    final a = net.nodeById(e.fromId);
    final c = net.nodeById(e.toId);
    if (a == null || c == null) continue;
    final s = sizing[e.id];
    if (e.kind == EdgeKind.run) {
      if (!onFloor(a) || !onFloor(c)) continue;
      strokeColor(e.service);
      // A6 line-weight hierarchy: three bands from the sized dimension;
      // unsized edges keep the legacy 1.4 w.
      cs.writeln('${_n(s == null ? 1.4 : kPdfStrokeWidths[_strokeBand(s)])} w');
      final dash = serviceDashPatternPdf(e.service);
      if (dash != null) cs.writeln('[${dash.map(_n).join(' ')}] 0 d');
      cs.writeln('${_n(tx(a.x))} ${_n(ty(a.y))} m '
          '${_n(tx(c.x))} ${_n(ty(c.y))} l S');
      if (dash != null) cs.writeln('[] 0 d'); // back to solid
      // A5 flow arrow on a sized run with a known orientation and enough length.
      if (s != null && s.flowFromId != null) {
        final ax = tx(a.x), ay = ty(a.y), bx = tx(c.x), by = ty(c.y);
        final flen = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
        if (flen > 30) {
          final upIsA = s.flowFromId == a.id;
          flowChevron(upIsA ? ax : bx, upIsA ? ay : by, upIsA ? bx : ax,
              upIsA ? by : ay, flen, e.service);
        }
      }
    } else {
      strokeColor(e.service);
      cs.writeln('1.4 w'); // markers keep the symbol weight, solid
      for (final n in [a, c]) {
        if (!onFloor(n)) continue;
        circle(tx(n.x), ty(n.y), kPlanRiserMarkerMm / kPlanPaperMmPerPt);
      }
    }
  }
  // A5 riser UP/DN sense marks (the layout picked a clear quadrant for each).
  for (final m in ann.upDown) {
    cs.writeln('BT /F1 ${_fs(m.textSize)} Tf 0 0 0 rg '
        '${_n(m.x)} ${_n(m.y)} Td (${_pdfText(m.text)}) Tj ET');
  }

  // Nodes on top: a component node draws its equipment glyph, a fixture-role
  // node a drop triangle, and a plain junction keeps the small filled dot
  // (A5 — replacing the anonymous dot for component/fixture nodes).
  const glyph = kPlanGlyphSizeMm / kPlanPaperMmPerPt;
  for (final n in net.nodes) {
    if (!onFloor(n)) continue;
    final px = tx(n.x), py = ty(n.y);
    final svc = domService(n);
    final col = svc == null ? (0.20, 0.20, 0.20) : _serviceColor(svc);
    final comp = n.component;
    if (comp != null) {
      strokePrims(planComponentPrims(comp, cx: px, cy: py, size: glyph), py, col);
    } else if (n.role == NodeRole.fixture) {
      strokePrims(planFixturePrims(cx: px, cy: py, size: glyph), py, col);
    } else {
      cs.writeln('0.20 0.20 0.20 rg');
      circle(px, py, 2, fill: true);
    }
  }

  // N4: per-riser TIE dimensions — offset dimension line, extension lines and
  // 45-degree oblique ticks in a lighter grey (so a coincident pipe keeps its
  // colour), the figure staggered clear of the marker cluster.
  for (final t in ann.ties) {
    cs.writeln('0.45 0.45 0.45 RG 0.35 w');
    for (final l in [t.axisExtension, t.riserExtension, t.dimension]) {
      cs.writeln('${_n(l.x1)} ${_n(l.y1)} m ${_n(l.x2)} ${_n(l.y2)} l S');
    }
    cs.writeln('0.6 w');
    for (final l in t.ticks) {
      cs.writeln('${_n(l.x1)} ${_n(l.y1)} m ${_n(l.x2)} ${_n(l.y2)} l S');
    }
    cs.writeln('BT /F1 ${_fs(t.textSize)} Tf 0 0 0 rg '
        '${_n(t.textX)} ${_n(t.textY)} Td '
        '(${_pdfText(t.text)}) Tj ET');
  }

  // Every tag (runs, equipment G1, risers N13) LAST, over all the linework.
  for (final l in ann.labels) {
    final p = l.placement;
    final lead = p.leaderAnchor;
    final end = p.leaderEnd;
    if (lead != null && end != null) {
      // A thin dark-grey leader from the run / feature to the label.
      cs.writeln('0.30 0.30 0.30 RG 0.5 w');
      cs.writeln('${_n(lead.x)} ${_n(lead.y)} m ${_n(end.x)} ${_n(end.y)} l S');
    }
    final rad = p.angleDeg * math.pi / 180;
    final pc = math.cos(rad), ps = math.sin(rad);
    for (final line in p.lines) {
      cs.writeln('BT /F1 ${_fs(l.textSize)} Tf 0 0 0 rg '
          '${_n(pc)} ${_n(ps)} ${_n(-ps)} ${_n(pc)} '
          '${_n(line.x)} ${_n(line.y)} Tm (${_pdfText(line.text)}) Tj ET');
    }
  }

  // ── Issuable-document chrome (opt-in; byte-identical when null) ─────────────
  if (hasChrome && chrome != null) {
    cs.write(pdfSheetFrame(pageW: pageW, pageH: pageH, margin: margin));
    cs.write(pdfTitleBlock(chrome,
            pageW: pageW,
            pageH: pageH,
            margin: margin,
            projectName: projectName,
            scaleTextOverride: scaleRow,
            titleTextOverride: blockTitle,
            dateTextOverride: blockDate)
        .ops);
    cs.write(pdfLegend(chrome,
        originX: margin + kLegendFrameInset, originY: margin + 28));
    cs.write(pdfNorthArrow(chrome, cx: pageW - margin - 18, cy: pageH - margin - 40));
  }
  // The honest divided scale bar rides the calibration (A3): drawn ONLY when a
  // real points-per-metre exists — never at an arbitrary auto-fit ratio.
  if (pointsPerMeter != null) {
    // drafting-9: on a framed (chrome) sheet the bar sits kScaleBarFrameInset
    // above the frame line so its figures print INSIDE the frame.
    cs.write(pdfScaleBarReal(
        pointsPerMeter: pointsPerMeter,
        centerX: pageW / 2,
        baseY: hasChrome ? margin + kScaleBarFrameInset : margin));
  }

  // ── Object assembly with a byte-accurate cross-reference table ──────────────
  // A1: a raster underlay adds one image XObject (object 6); the shared
  // assembler keeps the plain object sequence + xref byte-accurate.
  return assemblePlanPdfDocument(
    content: cs.toString(),
    pageW: pageW,
    pageH: pageH,
    raster: underlay is RasterPlanUnderlay ? underlay : null,
  );
}
