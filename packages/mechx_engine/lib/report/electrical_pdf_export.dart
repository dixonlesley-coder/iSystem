/// Minimal native PDF export of the electrical single-line — a self-contained
/// vector drawing deliverable with NO third-party dependency. The electrical
/// mirror of `pdf_export.dart` (`networkToPdf`). Pure: builds the PDF byte
/// stream from the sized system; the app handles file IO. Zero Flutter imports.
///
/// A single A3-landscape page: each panel is a stroked rectangle (at its
/// schematic canvas position when placed, else an auto-laid column) with its
/// name + incomer rating as text, and feeders are grey lines parent→child. The
/// drawing is auto-fitted (uniform scale, centred). PDF space is y-up, so the
/// screen-space (y-down) layout coordinates are flipped during the fit.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../electrical/model.dart';
import '../electrical/panel_results.dart';
import 'drawing_chrome.dart';

/// Box footprint (layout units) for an auto-laid panel — matches the DXF export.
const double _boxW = 200;
const double _boxH = 90;
const double _gapY = 80;

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

String _num(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// Render the sized electrical single-line as a single-page PDF and return its
/// bytes. [title] is stamped in the top-left corner.
Uint8List electricalSldToPdf({
  required ElectricalProject project,
  required ElectricalSystemResult result,
  String title = 'iSystem electrical single-line',
  DrawingChrome? chrome,
}) {
  const pageW = 1190.55; // A3 landscape, points (420 mm)
  const pageH = 841.89; // 297 mm
  const margin = 48.0;

  final modelById = {for (final p in project.panels) p.id: p};

  // Panel box top-left positions — placed canvas coords, else an auto column.
  final pos = <String, ({double x, double y})>{};
  var autoRow = 0;
  for (final id in result.order) {
    final m = modelById[id];
    if (m?.x != null && m?.y != null) {
      pos[id] = (x: m!.x!, y: m.y!);
    } else {
      pos[id] = (x: 0, y: autoRow * (_boxH + _gapY));
      autoRow++;
    }
  }

  // ── Bounds over every box corner ───────────────────────────────────────────
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final p in pos.values) {
    minX = math.min(minX, p.x);
    minY = math.min(minY, p.y);
    maxX = math.max(maxX, p.x + _boxW);
    maxY = math.max(maxY, p.y + _boxH);
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
  const availH = pageH - 2 * margin;
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

  ({double x, double y}) centre(String id) {
    final p = pos[id]!;
    return (x: p.x + _boxW / 2, y: p.y + _boxH / 2);
  }

  // ── Content stream ─────────────────────────────────────────────────────────
  final cs = StringBuffer();
  cs.writeln('BT /F1 16 Tf 0 0 0 rg '
      '${_n(margin)} ${_n(pageH - margin + 6)} Td (${_pdfText(title)}) Tj ET');

  // Feeders first (grey), so the boxes read on top.
  cs.writeln('0.55 0.55 0.55 RG 1.0 w');
  for (final parent in project.panels) {
    for (final c in parent.circuits) {
      final child = c.feedsPanelId;
      if (child == null) continue;
      if (!pos.containsKey(parent.id) || !pos.containsKey(child)) continue;
      final a = centre(parent.id);
      final z = centre(child);
      cs.writeln('${_n(tx(a.x))} ${_n(ty(a.y))} m '
          '${_n(tx(z.x))} ${_n(ty(z.y))} l S');
    }
  }

  // Panel boxes + labels.
  cs.writeln('0.15 0.30 0.55 RG 1.4 w');
  for (final id in result.order) {
    final p = result.panels[id];
    if (p == null) continue;
    final at = pos[id]!;
    // PDF rectangle: lower-left corner is the screen bottom-left (Y + height).
    final llx = tx(at.x);
    final lly = ty(at.y + _boxH);
    cs.writeln('${_n(llx)} ${_n(lly)} ${_n(_boxW * scale)} '
        '${_n(_boxH * scale)} re S');

    final tag = p.tag != null && p.tag!.isNotEmpty ? ' [${p.tag}]' : '';
    cs.writeln('BT /F1 11 Tf 0 0 0 rg '
        '${_n(tx(at.x) + 6)} ${_n(ty(at.y) - 16)} Td '
        '(${_pdfText('${p.name}$tag')}) Tj ET');
    cs.writeln('BT /F1 8 Tf 0.25 0.25 0.25 rg '
        '${_n(tx(at.x) + 6)} ${_n(ty(at.y) - 30)} Td '
        '(${_pdfText('In ${_num(p.incomer.breaker.ratingA.amperes)} A · ${p.system.label}')}) Tj ET');
    cs.writeln('BT /F1 8 Tf 0.25 0.25 0.25 rg '
        '${_n(tx(at.x) + 6)} ${_n(ty(at.y) - 42)} Td '
        '(${_pdfText('bus ${_num(p.busbar.csaMm2)} mm2')}) Tj ET');
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
