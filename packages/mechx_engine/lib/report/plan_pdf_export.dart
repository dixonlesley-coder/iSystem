/// Native ANNOTATED plan PDF export — a self-contained vector drawing of one
/// sheet/floor's drawn network with NO third-party dependency, modelled on
/// `electrical_pdf_export.dart`. A richer companion to `pdf_export.dart`
/// (`networkToPdf`): it adds real run/riser LENGTHS to each size label
/// (e.g. `DN50 · 3.5 m`), small node dots, riser markers, and a title block
/// (project name + sheet name + a date STRING the caller passes — the engine
/// never reads the clock).
///
/// A single A3-landscape page. Runs become coloured stroked LINES on a
/// per-service colour, risers a small circle marker at their on-floor node,
/// nodes small filled dots, and each sized edge a TEXT label. The drawing is
/// auto-fitted (uniform scale, centred) into the page with a margin. PDF space
/// is y-up, so the screen-space (y-down) coordinates are flipped during the fit.
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
  final spanX = maxX - minX;
  final spanY = maxY - minY;
  const availW = pageW - 2 * margin;
  // Reserve a little headroom for the two-line title block.
  const availH = pageH - 2 * margin - 24;
  var scale = 1.0;
  if (spanX > 0 || spanY > 0) {
    final sx = spanX > 0 ? availW / spanX : double.infinity;
    final sy = spanY > 0 ? availH / spanY : double.infinity;
    scale = math.min(sx, sy);
    if (!scale.isFinite || scale <= 0) scale = 1.0;
  }
  final drawnW = spanX * scale;
  final drawnH = spanY * scale;
  final offX = margin + (availW - drawnW) / 2;
  final offY = margin + (availH - drawnH) / 2;
  double tx(double x) => offX + (x - minX) * scale;
  double ty(double y) => (pageH - offY) - (y - minY) * scale; // flip y

  // ── Content stream ─────────────────────────────────────────────────────────
  final cs = StringBuffer();

  // Title block, top-left, two lines (project name; sheet name + date).
  cs.writeln('BT /F1 16 Tf 0 0 0 rg '
      '${_n(margin)} ${_n(pageH - margin + 6)} Td '
      '(${_pdfText(projectName)}) Tj ET');
  final counter = chrome?.sheetCounter;
  cs.writeln('BT /F1 10 Tf 0.25 0.25 0.25 rg '
      '${_n(margin)} ${_n(pageH - margin - 9)} Td '
      '(${_pdfText('$sheetName   -   $dateString'
          '${counter != null ? '   -   Sheet $counter' : ''}')}) Tj ET');

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

  // Edges: lines (runs) + riser markers, each labelled size · length.
  cs.writeln('1.4 w');
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
      cs.writeln('${_n(tx(a.x))} ${_n(ty(a.y))} m '
          '${_n(tx(c.x))} ${_n(ty(c.y))} l S');
      if (label != null) {
        cs.writeln('BT /F1 9 Tf 0 0 0 rg '
            '${_n(tx((a.x + c.x) / 2))} ${_n(ty((a.y + c.y) / 2) + 3)} Td '
            '(${_pdfText(label)}) Tj ET');
      }
    } else {
      strokeColor(e.service);
      for (final n in [a, c]) {
        if (!onFloor(n)) continue;
        circle(tx(n.x), ty(n.y), 5);
      }
      // Riser length label at the on-floor end.
      final marker = onFloor(a) ? a : (onFloor(c) ? c : null);
      if (marker != null && label != null) {
        cs.writeln('BT /F1 9 Tf 0 0 0 rg '
            '${_n(tx(marker.x) + 8)} ${_n(ty(marker.y) + 3)} Td '
            '(${_pdfText(label)}) Tj ET');
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
  if (chrome != null && !chrome.isEmpty) {
    cs.write(pdfRevisionBlock(chrome, pageW: pageW, pageH: pageH, margin: margin));
    cs.write(pdfLegend(chrome, originX: margin, originY: margin + 28));
    cs.write(pdfScaleBar(chrome, centerX: pageW / 2, baseY: margin));
    cs.write(pdfNorthArrow(chrome, cx: pageW - margin - 18, cy: pageH - margin - 40));
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
