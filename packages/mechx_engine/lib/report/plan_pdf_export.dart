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
import 'plan_symbols.dart';
import 'sld_sheet.dart';

/// Per-service stroke colour as RGB in the 0..1 range (no Flutter `Color`).
/// Matches `pdf_export.dart` so the annotated and plain PDFs read the same.
(double, double, double) _serviceColor(ServiceType s) => switch (s) {
      ServiceType.coldWater => (0.13, 0.45, 0.85),
      ServiceType.hotWater => (0.85, 0.30, 0.20),
      ServiceType.drainage => (0.50, 0.35, 0.20),
      ServiceType.vent => (0.20, 0.60, 0.60),
      ServiceType.rainwater => (0.20, 0.70, 0.85),
      ServiceType.duct => (0.20, 0.60, 0.30),
      ServiceType.returnAir => (0.50, 0.60, 0.20),
      ServiceType.exhaust => (0.50, 0.30, 0.60),
      ServiceType.fireSprinkler => (0.80, 0.15, 0.15),
      ServiceType.fireHydrant => (0.60, 0.10, 0.10),
    };

/// The size half of an edge label: `DN50` (pipe), `O200` (round duct, the
/// ASCII stand-in for Ø since Roboto/Helvetica printable-ASCII has no Ø), or
/// `W200x100` (rectangular duct).
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

/// A human metres string for a length label: `3.5 m` (one decimal, trimmed).
String _lengthLabel(Length l) {
  final m = l.meters;
  final txt = m == m.roundToDouble() ? m.toInt().toString() : m.toStringAsFixed(1);
  return '$txt m';
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

/// Axis-aligned overlap test for two [LabelBox]es (y-up output space) — the N3
/// riser-base collision pass uses it to stagger the tie-dimension text and to
/// seed the riser-label placer with the marker / UP-DN / tie boxes.
bool _boxesOverlap(LabelBox a, LabelBox b) =>
    a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY;

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
}) {
  final pageW = paper.widthPt; // landscape sheet width, points
  final pageH = paper.heightPt; // landscape sheet height, points
  const margin = 48.0;

  bool onFloor(NetNode n) => n.sheetId == sheetId && n.floorIndex == floorIndex;

  // ── Bounds of everything we'll draw, in screen pixels (A1: incl. underlay) ──
  final fit = planFitBounds(net, sheetId, floorIndex, underlay);
  final minX = fit.minX, minY = fit.minY, maxX = fit.maxX, maxY = fit.maxY;
  final hasContent = fit.hasContent;
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
  final availW = pageW - 2 * margin;
  // Reserve the title-block strip (chrome) or a little headroom for the
  // legacy two-line top-left title.
  final availH = pageH - 2 * margin - (hasChrome ? blockH : 24.0);
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

  final drawnW = spanX * scale;
  final drawnH = spanY * scale;
  final offX = margin + (availW - drawnW) / 2;
  final offY = margin + (availH - drawnH) / 2;
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

  // A7/N3 label discipline: rotate to the edge bearing (a `Tm` text matrix),
  // offset to the consistent upper side; when a dense branch can't clear, the
  // tag ESCAPES further out and is tied back to its run with a thin leader —
  // never dropped, never fused (see `placeEdgeLabelLeadered`).
  final placedLabels = <LabelBox>[];
  void edgeLabel(double ax, double ay, double bx, double by, String text) {
    const size = 9.0;
    final p = placeEdgeLabelLeadered(
        ax: ax,
        ay: ay,
        bx: bx,
        by: by,
        text: text,
        textSize: size,
        placed: placedLabels);
    final lead = p.leaderAnchor;
    if (lead != null) {
      // A thin dark-grey leader from the run midpoint to the pulled-off label.
      cs.writeln('0.30 0.30 0.30 RG 0.5 w');
      cs.writeln('${_n(lead.x)} ${_n(lead.y)} m ${_n(p.x)} ${_n(p.y)} l S');
    }
    final rad = p.angleDeg * math.pi / 180;
    final pc = math.cos(rad), ps = math.sin(rad);
    cs.writeln('BT /F1 9 Tf 0 0 0 rg '
        '${_n(pc)} ${_n(ps)} ${_n(-ps)} ${_n(pc)} '
        '${_n(p.x)} ${_n(p.y)} Tm (${_pdfText(text)}) Tj ET');
  }

  // N4: the reference setting-out grid — thin chain column/row lines with bubble
  // labels — is drawn BENEATH the network (the MEP strokes overprint it) when
  // present. The per-riser tie dimensions ride ON TOP (after the nodes).
  if (grid != null && !grid.isEmpty && hasContent) {
    const bubbleR = 9.0;
    cs.writeln('0.55 0.55 0.55 RG 0.4 w');
    cs.writeln('[8 3 2 3] 0 d'); // chain linetype for a setting-out grid
    for (final ax in grid.columns) {
      final gx = tx(ax.position);
      final y1 = ty(minY), y2 = ty(maxY);
      cs.writeln('${_n(gx)} ${_n(y1)} m ${_n(gx)} ${_n(y2)} l S');
      final topY = math.max(y1, y2) + bubbleR + 2;
      circle(gx, topY, bubbleR);
      cs.writeln('BT /F1 8 Tf 0 0 0 rg '
          '${_n(gx - ax.label.length * 2.2)} ${_n(topY - 3)} Td '
          '(${_pdfText(ax.label)}) Tj ET');
    }
    for (final ay in grid.rows) {
      final gy = ty(ay.position);
      final x1 = tx(minX), x2 = tx(maxX);
      cs.writeln('${_n(x1)} ${_n(gy)} m ${_n(x2)} ${_n(gy)} l S');
      final leftX = math.min(x1, x2) - bubbleR - 2;
      circle(leftX, gy, bubbleR);
      cs.writeln('BT /F1 8 Tf 0 0 0 rg '
          '${_n(leftX - ay.label.length * 2.2)} ${_n(gy - 3)} Td '
          '(${_pdfText(ay.label)}) Tj ET');
    }
    cs.writeln('[] 0 d'); // back to solid
  }

  // N3: riser-base labels are DEFERRED to a final pass so they dodge not just
  // each other + the run labels, but the riser marker, its UP/DN text, AND the
  // N4 tie-dimension text (all registered as occupied boxes below) — a crowded
  // base pushes the tag off with a leader instead of overprinting the cluster.
  final riserLabelJobs = <({double px, double py, String text})>[];

  // Edges: lines (runs) + riser markers, each labelled size · length · elev.
  for (final e in net.edges) {
    final a = net.nodeById(e.fromId);
    final c = net.nodeById(e.toId);
    if (a == null || c == null) continue;

    final s = sizing[e.id];
    final len = edgeLengths[e.id];
    final elev = edgeElevationLabels?[e.id];
    final sizeText = s != null ? _sizeLabel(e, s) : null;
    final lenText = (len != null && len.meters > 0) ? _lengthLabel(len) : null;
    // N5: append the centreline-elevation token to the size/length label.
    final parts = <String>[
      if (sizeText != null) sizeText,
      if (lenText != null) lenText,
      if (elev != null && elev.isNotEmpty) elev,
    ];
    final core = parts.isEmpty ? null : parts.join(' - ');
    // N13: prepend the stable element tag (`CW-R1 · DN50 - 3.5 m`). U+00B7 is
    // WinAnsi pass-through, so the separator survives the PDF text encoder.
    final tag = edgeTags?[e.id];
    final String? label;
    if (tag != null && tag.isNotEmpty) {
      label = core == null ? tag : '$tag · $core';
    } else {
      label = core;
    }

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
      if (label != null) {
        edgeLabel(tx(a.x), ty(a.y), tx(c.x), ty(c.y), label);
      }
    } else {
      strokeColor(e.service);
      cs.writeln('1.4 w'); // markers keep the symbol weight, solid
      for (final n in [a, c]) {
        if (!onFloor(n)) continue;
        final nx = tx(n.x), ny = ty(n.y);
        circle(nx, ny, 5);
        // N3: the marker circle is an occupied box so the base labels dodge it.
        placedLabels.add((minX: nx - 5, minY: ny - 5, maxX: nx + 5, maxY: ny + 5));
        // A5 riser UP/DN sense from the endpoints' floor indices, above marker.
        final other = n.id == a.id ? c : a;
        final sense =
            riserUpDown(hereFloor: n.floorIndex, otherFloor: other.floorIndex);
        if (sense != null) {
          final uw = sense.length * 9 * 0.55;
          final ux = nx + 8;
          var uy = ny - 8;
          LabelBox upBox(double y) =>
              (minX: ux, minY: y, maxX: ux + uw, maxY: y + 9);
          // Two risers can share a node (one UP, one DN); step the second sense
          // clear of the first so the marks STACK instead of overprinting (N3).
          for (var step = 0; step < 4; step++) {
            if (!placedLabels.any((p) => _boxesOverlap(p, upBox(uy)))) break;
            uy -= 12;
          }
          cs.writeln('BT /F1 9 Tf 0 0 0 rg '
              '${_n(ux)} ${_n(uy)} Td (${_pdfText(sense)}) Tj ET');
          // Register the UP/DN box so the riser tag never lands on it (N3).
          placedLabels.add(upBox(uy));
        }
      }
      // Defer the riser length/tag label to the final pass (after the tie
      // dimensions are placed), so it dodges the marker + UP/DN + tie boxes.
      final marker = onFloor(a) ? a : (onFloor(c) ? c : null);
      if (marker != null && label != null) {
        riserLabelJobs
            .add((px: tx(marker.x), py: ty(marker.y), text: label));
      }
    }
  }

  // Nodes on top: a component node draws its equipment glyph, a fixture-role
  // node a drop triangle, and a plain junction keeps the small filled dot
  // (A5 — replacing the anonymous dot for component/fixture nodes).
  for (final n in net.nodes) {
    if (!onFloor(n)) continue;
    final px = tx(n.x), py = ty(n.y);
    final svc = domService(n);
    final col = svc == null ? (0.20, 0.20, 0.20) : _serviceColor(svc);
    final comp = n.component;
    if (comp != null) {
      strokePrims(planComponentPrims(comp, cx: px, cy: py, size: 14), py, col);
    } else if (n.role == NodeRole.fixture) {
      strokePrims(planFixturePrims(cx: px, cy: py, size: 14), py, col);
    } else {
      cs.writeln('0.20 0.20 0.20 rg');
      circle(px, py, 2, fill: true);
    }
  }

  // N4: per-riser TIE dimensions — the offset from each riser node to its
  // nearest column + row axis, as a leadered dimension the mandor sets out from.
  // Drawn ON TOP of the network, only with a real scale (an unscaled dimension
  // would be fabricated — see `formatTieOffsetMm`).
  if (grid != null && !grid.isEmpty && hasContent && metersPerPixel != null) {
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
      final lax = tx(fromXpx), lay = ty(fromYpx); // axis end (page space)
      final lbx = tx(toXpx), lby = ty(toYpx); // node end (at the riser marker)
      cs.writeln('0.20 0.20 0.20 RG 0.5 w');
      cs.writeln('${_n(lax)} ${_n(lay)} m ${_n(lbx)} ${_n(lby)} l S');
      // N3: stagger the dimension text AWAY from the marker (the node end) —
      // back off along the line toward the axis, then step perpendicular until
      // the box clears everything already placed (marker / UP-DN / labels).
      // Register the cleared box so the riser tag (placed last) dodges it too.
      const fs = 7.0;
      final w = label.length * fs * 0.55;
      const h = fs;
      final dxp = lbx - lax, dyp = lby - lay;
      final len = math.sqrt(dxp * dxp + dyp * dyp);
      final ux = len > 1e-6 ? dxp / len : 1.0;
      final uy = len > 1e-6 ? dyp / len : 0.0;
      final perpX = uy, perpY = -ux; // the line direction rotated by -90 deg
      final along = math.min(22.0, len * 0.5); // back off from the node
      final cx0 = lbx - ux * along;
      final cy0 = lby - uy * along;
      LabelBox boxAt(double bcx, double bcy) => (
            minX: bcx - w / 2,
            minY: bcy - h / 2,
            maxX: bcx + w / 2,
            maxY: bcy + h / 2,
          );
      var cx = cx0 + perpX * 7, cy = cy0 + perpY * 7;
      for (var step = 0; step < 6; step++) {
        if (!placedLabels.any((p) => _boxesOverlap(p, boxAt(cx, cy)))) break;
        final off = 7 + (step + 1) * (h + 4);
        cx = cx0 + perpX * off;
        cy = cy0 + perpY * off;
      }
      placedLabels.add(boxAt(cx, cy));
      cs.writeln('BT /F1 7 Tf 0 0 0 rg '
          '${_n(cx - w / 2)} ${_n(cy - h / 2)} Td '
          '(${_pdfText(label)}) Tj ET');
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

  // N3: the deferred riser-base labels — placed LAST via the leadered placer so
  // they dodge the marker + UP/DN + tie-dimension boxes registered above. A
  // short horizontal "edge" just right of the marker keeps the tag beside it in
  // the common case; a crowded base escapes (up/down) and ties back with a
  // leader rather than overprinting the cluster.
  for (final job in riserLabelJobs) {
    final w = job.text.length * 9.0 * 0.55;
    edgeLabel(job.px + 8, job.py, job.px + 8 + w, job.py, job.text);
  }

  // ── Issuable-document chrome (opt-in; byte-identical when null) ─────────────
  if (hasChrome) {
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
    cs.write(pdfLegend(chrome, originX: margin, originY: margin + 28));
    cs.write(pdfNorthArrow(chrome, cx: pageW - margin - 18, cy: pageH - margin - 40));
  }
  // The honest divided scale bar rides the calibration (A3): drawn ONLY when a
  // real points-per-metre exists — never at an arbitrary auto-fit ratio.
  if (pointsPerMeter != null) {
    cs.write(pdfScaleBarReal(
        pointsPerMeter: pointsPerMeter, centerX: pageW / 2, baseY: margin));
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
