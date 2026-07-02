/// Native ANNOTATED plan PDF export — a self-contained vector drawing of one
/// sheet/floor's drawn network with NO third-party dependency, modelled on
/// `electrical_pdf_export.dart`. A richer companion to `pdf_export.dart`
/// (`networkToPdf`): it adds real run/riser LENGTHS to each size label
/// (e.g. `DN50 · 3.5 m`), small node dots, riser markers, and a title block
/// (project name + sheet name + a date STRING the caller passes — the engine
/// never reads the clock).
///
/// A single A3-landscape page. Runs become coloured stroked LINES on a
/// per-service colour with an A6 three-band line-weight hierarchy + the
/// per-service dash pattern, risers a small circle marker at their on-floor
/// node, nodes small filled dots, and each sized edge a TEXT label rotated to
/// its edge bearing with greedy collision avoidance (A7). The drawing is
/// auto-fitted (uniform scale, centred) into the page with a margin — and
/// SNAPPED to a standard plotted scale when the caller passes the sheet
/// calibration (A3). PDF space is y-up, so the screen-space (y-down)
/// coordinates are flipped during the fit.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../network/network.dart';
import '../sizing/network_sizing.dart';
import '../units.dart';
import 'drawing_chrome.dart';

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

/// Keep PDF text to printable ASCII (WinAnsi-safe) and escape the three PDF
/// string metacharacters so a name or label never breaks the syntax.
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
/// `1 : N @ A3`, and an honest divided scale bar is drawn from the resulting
/// points-per-metre. When null the sheet is NTS and NO divided bar is printed
/// — a bar at an arbitrary auto-fit ratio is a bar an engineer could scale
/// wrong dimensions from (CAD-OUTPUT-UX-REVIEW A3).
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
}) {
  const pageW = 1190.55; // A3 landscape, points (420 mm)
  const pageH = 841.89; // 297 mm
  const margin = 48.0;

  bool onFloor(NetNode n) => n.sheetId == sheetId && n.floorIndex == floorIndex;

  // ── Bounds of everything we'll draw, in screen pixels ──────────────────────
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  void include(NetNode n) {
    minX = math.min(minX, n.x);
    minY = math.min(minY, n.y);
    maxX = math.max(maxX, n.x);
    maxY = math.max(maxY, n.y);
  }

  for (final e in net.edges) {
    final a = net.nodeById(e.fromId);
    final c = net.nodeById(e.toId);
    if (a == null || c == null) continue;
    if (e.kind == EdgeKind.run) {
      if (onFloor(a) && onFloor(c)) {
        include(a);
        include(c);
      }
    } else {
      if (onFloor(a)) include(a);
      if (onFloor(c)) include(c);
    }
  }

  final hasContent = minX.isFinite;
  if (!hasContent) {
    minX = 0;
    minY = 0;
    maxX = 1;
    maxY = 1;
  }
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
  const availW = pageW - 2 * margin;
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

  // ── A3 true plotted scale: snap the raw auto-fit to a standard scale ───────
  var scaleRow = 'NTS';
  double? pointsPerMeter;
  if (metersPerPixel != null && metersPerPixel > 0 && hasContent) {
    const mmPerPoint = 25.4 / 72; // PDF points → paper millimetres
    // The raw fit's plotted-scale denominator: real-world mm per paper mm.
    final rawN = metersPerPixel * 1000 / (scale * mmPerPoint);
    int? snappedN;
    for (final n in kPlanScaleLadder) {
      if (n >= rawN - 1e-9) {
        snappedN = n;
        break;
      }
    }
    if (snappedN != null) {
      // Re-fit at the snapped scale — a denominator >= the raw fit's, so the
      // drawing never draws larger than the honest snap.
      scale = metersPerPixel * 1000 / (snappedN * mmPerPoint);
      scaleRow = '1 : $snappedN @ A3';
      pointsPerMeter = scale / metersPerPixel;
    }
    // else: too large even for 1:1000 — keep the honest auto-fit, stay NTS.
  }

  final drawnW = spanX * scale;
  final drawnH = spanY * scale;
  final offX = margin + (availW - drawnW) / 2;
  final offY = margin + (availH - drawnH) / 2;
  double tx(double x) => offX + (x - minX) * scale;
  double ty(double y) => (pageH - offY) - (y - minY) * scale; // flip y

  // ── Content stream ─────────────────────────────────────────────────────────
  final cs = StringBuffer();

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

  // Edges: lines (runs) + riser markers, each labelled size · length.
  for (final e in net.edges) {
    final a = net.nodeById(e.fromId);
    final c = net.nodeById(e.toId);
    if (a == null || c == null) continue;

    final s = sizing[e.id];
    final len = edgeLengths[e.id];
    final sizeText = s != null ? _sizeLabel(e, s) : null;
    final lenText = (len != null && len.meters > 0) ? _lengthLabel(len) : null;
    final label = sizeText != null && lenText != null
        ? '$sizeText - $lenText'
        : (sizeText ?? lenText);

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
      if (label != null) {
        edgeLabel(tx(a.x), ty(a.y), tx(c.x), ty(c.y), label);
      }
    } else {
      strokeColor(e.service);
      cs.writeln('1.4 w'); // markers keep the symbol weight, solid
      for (final n in [a, c]) {
        if (!onFloor(n)) continue;
        circle(tx(n.x), ty(n.y), 5);
      }
      // Riser length label at the on-floor end. A riser has no on-plan
      // bearing, so it stays horizontal; its box is recorded so later run
      // labels dodge it (A7 greedy collision).
      final marker = onFloor(a) ? a : (onFloor(c) ? c : null);
      if (marker != null && label != null) {
        final lx = tx(marker.x) + 8;
        final ly = ty(marker.y) + 3;
        cs.writeln('BT /F1 9 Tf 0 0 0 rg '
            '${_n(lx)} ${_n(ly)} Td '
            '(${_pdfText(label)}) Tj ET');
        placedLabels.add((
          minX: lx,
          minY: ly,
          maxX: lx + label.length * 9 * 0.55,
          maxY: ly + 9,
        ));
      }
    }
  }

  // Nodes: small filled dots on top, so junctions read clearly.
  cs.writeln('0.20 0.20 0.20 rg');
  for (final n in net.nodes) {
    if (!onFloor(n)) continue;
    circle(tx(n.x), ty(n.y), 2, fill: true);
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
  final content = cs.toString();
  final contentLen = latin1.encode(content).length;
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R '
        '/MediaBox [0 0 ${_n(pageW)} ${_n(pageH)}] '
        '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
    '<< /Length $contentLen >>\nstream\n$content\nendstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];

  final out = BytesBuilder();
  void w(String s) => out.add(latin1.encode(s));
  w('%PDF-1.4\n');
  w('%âãÏÓ\n'); // binary marker
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    w('${i + 1} 0 obj\n');
    w(objects[i]);
    w('\nendobj\n');
  }
  final xref = out.length;
  w('xref\n0 ${objects.length + 1}\n');
  w('0000000000 65535 f \n');
  for (final off in offsets) {
    w('${off.toString().padLeft(10, '0')} 00000 n \n');
  }
  w('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n');
  w('startxref\n$xref\n%%EOF\n');
  return out.toBytes();
}
