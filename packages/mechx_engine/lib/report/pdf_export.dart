/// Minimal native PDF export of a drawn network for one sheet/floor — a
/// self-contained vector drawing deliverable with NO third-party dependency.
/// Pure: builds the PDF byte stream from the network + sizes; the app handles
/// file IO. Zero Flutter imports.
///
/// The PDF is a single landscape page (A3 by default; A2/A1 via `paper`). Runs
/// become coloured stroked LINES on
/// a per-service colour with an A6 three-band line-weight hierarchy + the
/// per-service dash pattern, risers a small circle marker at their on-floor
/// node, and each sized edge a TEXT label (DN / Ø / W×H) rotated to its edge
/// bearing with greedy collision avoidance (A7). The drawing is auto-fitted
/// (uniform scale, centred) into the page with a margin — and SNAPPED to a
/// standard plotted scale when the caller passes the sheet calibration (A3).
/// PDF space is y-up, so the screen-space (y-down) coordinates are flipped
/// during the fit.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../network/network.dart';
import '../sizing/network_sizing.dart';
import 'drawing_chrome.dart';
import 'plan_symbols.dart';
import 'sld_sheet.dart';

/// Per-service stroke colour as RGB in the 0..1 range (no Flutter `Color`).
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

/// Keep PDF text to printable ASCII (WinAnsi-safe) and escape the three PDF
/// string metacharacters so a sheet name or label never breaks the syntax.
String _pdfText(String raw) {
  final b = StringBuffer();
  for (final code in raw.runes) {
    final c = (code >= 0x20 && code <= 0x7e) ? code : 0x3f /* ? */;
    if (c == 0x28 || c == 0x29 || c == 0x5c) b.writeCharCode(0x5c); // ( ) \
    b.writeCharCode(c);
  }
  return b.toString();
}

String _n(double v) => v.toStringAsFixed(2);

/// Render the [sheetId]/[floorIndex] slice of [net] as a single-page PDF and
/// return its bytes. [title] is stamped in the top-left corner — or becomes
/// the title-block PROJECT row when [chrome] is present (A4: the issued sheet
/// carries a frame + an ISO-7200 title block instead of loose corner text).
///
/// When [metersPerPixel] (the sheet calibration) is set, the raw auto-fit is
/// SNAPPED to the nearest standard plotted scale (`kPlanScaleLadder`, always
/// the larger denominator so the drawing never draws larger than the honest
/// snap), the title-block SCALE row reads `1 : N @ <paper>` (naming the ACTUAL
/// [paper]), and an honest divided scale bar is drawn from the resulting
/// points-per-metre. When null the sheet is NTS and NO divided bar is printed
/// — a bar at an arbitrary auto-fit ratio is a bar an engineer could scale
/// wrong dimensions from (CAD-OUTPUT-UX-REVIEW A3).
///
/// [paper] selects the landscape sheet size (default A3 ⇒ byte-identical); A2
/// / A1 enlarge the page, margins, fit, chrome anchoring and scale text alike.
///
/// With [underlay] present (A1) the floor-plan substrate is painted FIRST,
/// beneath every network stroke: a [VectorPlanUnderlay] as pale-grey thin
/// linework, a [RasterPlanUnderlay] as a FlateDecode image XObject scaled to
/// the sheet frame's fitted rect. The underlay's sheet frame joins the fit
/// bounds so the whole plan lands on the page. Null keeps the output
/// byte-identical.
Uint8List networkToPdf({
  required Network net,
  required Map<String, EdgeSizing> sizing,
  required String sheetId,
  required int floorIndex,
  String title = 'MechX drawing',
  DrawingChrome? chrome,
  double? metersPerPixel,
  PlanUnderlay? underlay,
  PaperSize paper = PaperSize.a3Landscape,
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
  // A4: reserve the ISO-7200 title-block strip at the bottom. The row COUNT
  // (so the height) doesn't depend on the final scale text — with chrome the
  // SCALE row is always stamped ('NTS' or '1 : N @ A3') — so probe with a
  // placeholder here and render with the real text after the fit.
  final blockH = hasChrome
      ? pdfTitleBlock(chrome,
              pageW: pageW,
              pageH: pageH,
              margin: margin,
              projectName: title,
              scaleTextOverride: 'NTS')
          .height
      : 0.0;
  final spanX = maxX - minX;
  final spanY = maxY - minY;
  final availW = pageW - 2 * margin;
  final availH = pageH - 2 * margin - blockH;
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
    // Title, top-left, black (an issued sheet carries it in the title block).
    cs.writeln('BT /F1 16 Tf 0 0 0 rg '
        '${_n(margin)} ${_n(pageH - margin + 6)} Td (${_pdfText(title)}) Tj ET');
  }

  void strokeColor(ServiceType s) {
    final (r, g, b) = _serviceColor(s);
    cs.writeln('${_n(r)} ${_n(g)} ${_n(b)} RG');
  }

  void circle(double cx, double cy, double r) {
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
    cs.writeln('S');
  }

  // A5 flow arrow: one small OPEN chevron at the 2/3 point of a long-enough
  // sized run along its flow direction ([upstream]→[downstream] in page
  // points), mirroring the on-canvas `network_layer._flowChevron`. Drawn on
  // top of the run in the service colour.
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

  // A5 node symbol: stroke a plan-symbol prim list (already in page points,
  // y-DOWN) in the service colour of the node's dominant edge, MIRRORED about
  // the node's baseline [pageCy] (the prims are authored y-down; the PDF page
  // is y-up). Only [SldLine]/[SldCircle] arise from the plan-symbol library.
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
  // null when the node is unconnected → neutral dark.
  ServiceType? domService(NetNode n) {
    for (final e in net.edges) {
      if (e.fromId == n.id || e.toId == n.id) return e.service;
    }
    return null;
  }

  // A7 label discipline: rotate to the edge bearing (a `Tm` text matrix),
  // offset to the consistent upper side, drop on unresolvable collision.
  final placedLabels = <LabelBox>[];
  void edgeLabel(double ax, double ay, double bx, double by, String text) {
    const size = 9.0;
    final p = placeEdgeLabel(
        ax: ax,
        ay: ay,
        bx: bx,
        by: by,
        text: text,
        textSize: size,
        placed: placedLabels);
    if (p == null) return; // dropped rather than overprinting
    final rad = p.angleDeg * math.pi / 180;
    final pc = math.cos(rad), ps = math.sin(rad);
    cs.writeln('BT /F1 9 Tf 0 0 0 rg '
        '${_n(pc)} ${_n(ps)} ${_n(-ps)} ${_n(pc)} '
        '${_n(p.x)} ${_n(p.y)} Tm (${_pdfText(text)}) Tj ET');
  }

  for (final e in net.edges) {
    final a = net.nodeById(e.fromId);
    final c = net.nodeById(e.toId);
    if (a == null || c == null) continue;

    if (e.kind == EdgeKind.run) {
      if (!onFloor(a) || !onFloor(c)) continue;
      final s = sizing[e.id];
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
        final len = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
        if (len > 30) {
          final upIsA = s.flowFromId == a.id;
          flowChevron(upIsA ? ax : bx, upIsA ? ay : by, upIsA ? bx : ax,
              upIsA ? by : ay, len, e.service);
        }
      }
      if (s != null) {
        edgeLabel(tx(a.x), ty(a.y), tx(c.x), ty(c.y), _sizeLabel(e, s));
      }
    } else {
      strokeColor(e.service);
      cs.writeln('1.4 w'); // markers keep the symbol weight, solid
      for (final n in [a, c]) {
        if (!onFloor(n)) continue;
        circle(tx(n.x), ty(n.y), 5);
        // A5 riser UP/DN sense from the endpoints' floor indices.
        final other = n.id == a.id ? c : a;
        final sense =
            riserUpDown(hereFloor: n.floorIndex, otherFloor: other.floorIndex);
        if (sense != null) {
          cs.writeln('BT /F1 9 Tf 0 0 0 rg '
              '${_n(tx(n.x) + 8)} ${_n(ty(n.y) - 3)} Td (${_pdfText(sense)}) Tj ET');
        }
      }
    }
  }

  // A5 node symbols: draw the equipment glyph for a component node and a drop
  // triangle for a fixture-role node, replacing the anonymous dot. Plain main
  // junctions are unchanged (this exporter never dotted them).
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
    }
  }

  // ── Issuable-document chrome (opt-in; byte-identical when null) ─────────────
  if (hasChrome) {
    cs.write(pdfSheetFrame(pageW: pageW, pageH: pageH, margin: margin));
    cs.write(pdfTitleBlock(chrome,
            pageW: pageW,
            pageH: pageH,
            margin: margin,
            projectName: title,
            scaleTextOverride: scaleRow)
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
