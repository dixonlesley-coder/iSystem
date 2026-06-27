/// Issuable-drawing CHROME — the shared, pure helpers that turn a bare vector
/// drawing into an *issuable document*: a service-colour LEGEND, a graphic
/// SCALE BAR, a NORTH arrow, a sheet "X of Y" counter, and a revision /
/// drawing-number title block. Used by the four export engines
/// (`pdf_export`, `plan_pdf_export`, `dxf_export`, `electrical_pdf_export`).
///
/// PURE: emits PDF content-stream fragments (y-up page space, points) and DXF
/// entity fragments (y-up, world units) as strings; never reads the clock, no
/// Flutter imports. All chrome is OPT-IN — an export that passes no
/// [DrawingChrome] is byte-identical to before this module existed.
library;

import 'dart:math' as math;

import '../network/network.dart';

/// The issuable-document parameters a caller stamps onto an exported drawing.
/// All fields are optional; the renderers draw only the parts that are present,
/// so a partially-filled block (e.g. drawing number but no revision) is fine.
class DrawingChrome {
  /// The drawing number stamped in the title area (e.g. `M-101`).
  final String? drawingNumber;

  /// The revision tag stamped in the title area (e.g. `Rev. B`).
  final String? revisionNumber;

  /// 1-based sheet index within the issued set (for the "X of Y" counter).
  final int? sheetIndex;

  /// Total sheets in the issued set (for the "X of Y" counter).
  final int? sheetTotal;

  /// North bearing, radians clockwise from page-up. 0 ⇒ north points up the
  /// page (the default site convention when no magnetic bearing is tracked).
  final double northAngleRad;

  /// The services to list in the legend colour/line key. Empty ⇒ no legend.
  final List<ServiceType> legendServices;

  /// Optional human label under the scale bar (e.g. `1 : 100` or `5 m`). The
  /// engine never computes a real-world scale (it has no calibration here); the
  /// caller passes a label when it can, else the bar is a graphic-only marker.
  final String? scaleBarLabel;

  const DrawingChrome({
    this.drawingNumber,
    this.revisionNumber,
    this.sheetIndex,
    this.sheetTotal,
    this.northAngleRad = 0,
    this.legendServices = const [],
    this.scaleBarLabel,
  });

  /// True when nothing would be drawn — lets a caller skip chrome entirely and
  /// stay byte-identical.
  bool get isEmpty =>
      drawingNumber == null &&
      revisionNumber == null &&
      sheetIndex == null &&
      sheetTotal == null &&
      legendServices.isEmpty;

  /// The "X of Y" sheet counter text, or null when neither part is set.
  String? get sheetCounter {
    if (sheetIndex == null && sheetTotal == null) return null;
    final i = sheetIndex ?? 1;
    final t = sheetTotal ?? i;
    return '$i of $t';
  }
}

/// Engine-side service display name (mirrors `calc_report` `_service`; the UI's
/// `serviceLabel` lives in the Flutter layer and can't be imported here).
String serviceChromeLabel(ServiceType s) => switch (s) {
      ServiceType.coldWater => 'Cold water',
      ServiceType.hotWater => 'Hot water',
      ServiceType.drainage => 'Drainage',
      ServiceType.vent => 'Vent',
      ServiceType.rainwater => 'Rainwater',
      ServiceType.duct => 'Supply air',
      ServiceType.returnAir => 'Return air',
      ServiceType.exhaust => 'Exhaust',
      ServiceType.fireSprinkler => 'Sprinkler',
      ServiceType.fireHydrant => 'Hydrant',
    };

/// Per-service stroke colour as RGB in 0..1 — the single source shared by the
/// PDF exporters so legend swatches match the drawn lines.
(double, double, double) serviceChromeColor(ServiceType s) => switch (s) {
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

String _n(double v) => v.toStringAsFixed(2);

/// Keep PDF text to printable ASCII (WinAnsi-safe) and escape the three PDF
/// string metacharacters — same rule the exporters use for their own text.
String _pdfText(String raw) {
  final b = StringBuffer();
  for (final code in raw.runes) {
    final c = (code >= 0x20 && code <= 0x7e) ? code : 0x3f /* ? */;
    if (c == 0x28 || c == 0x29 || c == 0x5c) b.writeCharCode(0x5c); // ( ) \
    b.writeCharCode(c);
  }
  return b.toString();
}

// ── PDF chrome (content-stream fragments, page space y-up, points) ──────────

/// The revision / drawing-number + sheet "X of Y" block, in the top-RIGHT
/// title area. [pageW]/[pageH] are the page size; [margin] the page margin.
/// Returns content-stream text (or '' when nothing to stamp).
String pdfRevisionBlock(
  DrawingChrome chrome, {
  required double pageW,
  required double pageH,
  required double margin,
}) {
  final lines = <String>[
    if (chrome.drawingNumber != null) chrome.drawingNumber!,
    if (chrome.revisionNumber != null) chrome.revisionNumber!,
    if (chrome.sheetCounter != null) 'Sheet ${chrome.sheetCounter}',
  ];
  if (lines.isEmpty) return '';
  final cs = StringBuffer();
  // Right-aligned-ish: anchored at a fixed inset from the right edge. Text is
  // left-set from there; the inset leaves room for ~24 chars at 10 pt.
  final x = pageW - margin - 160;
  var y = pageH - margin + 6;
  // First line (drawing number / first present) a touch larger.
  for (var i = 0; i < lines.length; i++) {
    final size = i == 0 ? 12 : 9;
    cs.writeln('BT /F1 $size Tf 0 0 0 rg '
        '${_n(x)} ${_n(y)} Td (${_pdfText(lines[i])}) Tj ET');
    y -= i == 0 ? 14 : 11;
  }
  return cs.toString();
}

/// A service-colour legend in the bottom-LEFT, one row per service: a short
/// coloured swatch line + the service name. Grows UP from [originY].
String pdfLegend(
  DrawingChrome chrome, {
  required double originX,
  required double originY,
}) {
  if (chrome.legendServices.isEmpty) return '';
  final cs = StringBuffer();
  const rowH = 12.0;
  const swatchW = 18.0;
  // Title above the rows.
  final titleY = originY + chrome.legendServices.length * rowH + 4;
  cs.writeln('BT /F1 9 Tf 0 0 0 rg '
      '${_n(originX)} ${_n(titleY)} Td (${_pdfText('LEGEND')}) Tj ET');
  cs.writeln('1.4 w');
  var y = originY + (chrome.legendServices.length - 1) * rowH;
  for (final s in chrome.legendServices) {
    final (r, g, b) = serviceChromeColor(s);
    cs.writeln('${_n(r)} ${_n(g)} ${_n(b)} RG');
    cs.writeln('${_n(originX)} ${_n(y + 3)} m '
        '${_n(originX + swatchW)} ${_n(y + 3)} l S');
    cs.writeln('BT /F1 8 Tf 0 0 0 rg '
        '${_n(originX + swatchW + 6)} ${_n(y)} Td '
        '(${_pdfText(serviceChromeLabel(s))}) Tj ET');
    y -= rowH;
  }
  return cs.toString();
}

/// A graphic SCALE BAR (a divided bar with end ticks) at the bottom-CENTRE.
/// Length [barLen] in points; the optional [DrawingChrome.scaleBarLabel] is set
/// below it. Drawn black.
String pdfScaleBar(
  DrawingChrome chrome, {
  required double centerX,
  required double baseY,
  double barLen = 120,
}) {
  final cs = StringBuffer();
  final x0 = centerX - barLen / 2;
  final x1 = centerX + barLen / 2;
  cs.writeln('0 0 0 RG 1.2 w');
  // Main bar.
  cs.writeln('${_n(x0)} ${_n(baseY)} m ${_n(x1)} ${_n(baseY)} l S');
  // End + mid ticks (a simple 4-division bar).
  for (var i = 0; i <= 4; i++) {
    final x = x0 + barLen * i / 4;
    final h = i % 2 == 0 ? 6.0 : 3.0;
    cs.writeln('${_n(x)} ${_n(baseY)} m ${_n(x)} ${_n(baseY + h)} l S');
  }
  cs.writeln('BT /F1 8 Tf 0 0 0 rg '
      '${_n(x0)} ${_n(baseY - 10)} Td '
      '(${_pdfText('SCALE${chrome.scaleBarLabel != null ? '  ${chrome.scaleBarLabel}' : ''}')}) Tj ET');
  return cs.toString();
}

/// A NORTH arrow at [cx]/[cy] of radius [r], rotated by
/// [DrawingChrome.northAngleRad] (clockwise from page-up). Drawn black with an
/// 'N' at the tip.
String pdfNorthArrow(
  DrawingChrome chrome, {
  required double cx,
  required double cy,
  double r = 16,
}) {
  // Page space is y-up, so "up" is +y. A clockwise bearing rotates the tip the
  // engineering way; on a y-up page that is a negative mathematical rotation.
  final a = -chrome.northAngleRad;
  ({double x, double y}) rot(double dx, double dy) {
    final ca = math.cos(a), sa = math.sin(a);
    return (x: cx + dx * ca - dy * sa, y: cy + dx * sa + dy * ca);
  }

  final tip = rot(0, r); // north tip
  final tail = rot(0, -r);
  final left = rot(-r * 0.45, -r * 0.2);
  final right = rot(r * 0.45, -r * 0.2);

  final cs = StringBuffer();
  cs.writeln('0 0 0 RG 0 0 0 rg 1.0 w');
  // Shaft.
  cs.writeln('${_n(tail.x)} ${_n(tail.y)} m ${_n(tip.x)} ${_n(tip.y)} l S');
  // Arrowhead (filled triangle at the tip).
  cs.writeln('${_n(tip.x)} ${_n(tip.y)} m '
      '${_n(left.x)} ${_n(left.y)} l '
      '${_n(right.x)} ${_n(right.y)} l f');
  // 'N' just beyond the tip.
  final label = rot(0, r + 7);
  cs.writeln('BT /F1 9 Tf 0 0 0 rg '
      '${_n(label.x - 3)} ${_n(label.y - 3)} Td (${_pdfText('N')}) Tj ET');
  return cs.toString();
}

// ── DXF chrome (entity fragments, world space y-up) ─────────────────────────

void _g(StringBuffer b, int code, Object value) {
  b.writeln(code);
  b.writeln(value);
}

/// DXF chrome entities (legend / scale / north / title) placed near the
/// drawing's [minX]/[maxY] corner in world units, each on its own layer so a
/// CAD user can toggle them. [unit] scales the chrome to the drawing extent so
/// it reads at the model's size (pass ~ drawing span / 40). Returns '' when the
/// chrome is empty.
String dxfChrome(
  DrawingChrome chrome, {
  required double minX,
  required double minY,
  required double maxX,
  required double maxY,
}) {
  if (chrome.isEmpty) return '';
  final b = StringBuffer();
  final spanX = (maxX - minX).abs();
  final spanY = (maxY - minY).abs();
  final span = math.max(math.max(spanX, spanY), 1.0);
  final u = span / 40.0; // chrome unit
  final txt = u * 1.6; // text height

  // Title / revision / sheet block — TEXT on layer 'title', top-left in DXF
  // (DXF y-up, so the on-screen top is the larger world Y after negation; here
  // we place above the drawing at maxY-equivalent). World Y of these exports is
  // negated screen-Y, so "above the drawing" is the LEAST-negative end (minY
  // here is the most negative). We anchor near (minX, maxY).
  final titleLines = <String>[
    if (chrome.drawingNumber != null) chrome.drawingNumber!,
    if (chrome.revisionNumber != null) chrome.revisionNumber!,
    if (chrome.sheetCounter != null) 'Sheet ${chrome.sheetCounter}',
  ];
  var ty = maxY + u * 3;
  for (final line in titleLines) {
    _g(b, 0, 'TEXT');
    _g(b, 8, 'title');
    _g(b, 10, minX);
    _g(b, 20, ty);
    _g(b, 40, txt);
    _g(b, 1, _dxfText(line));
    ty += txt * 1.6;
  }

  // Legend — a short LINE swatch + TEXT name per service, layer 'legend',
  // stacked below the drawing's bottom-left.
  var ly = minY - u * 3;
  for (final s in chrome.legendServices) {
    _g(b, 0, 'LINE');
    _g(b, 8, 'legend');
    _g(b, 10, minX);
    _g(b, 20, ly);
    _g(b, 11, minX + u * 3);
    _g(b, 21, ly);
    _g(b, 0, 'TEXT');
    _g(b, 8, 'legend');
    _g(b, 10, minX + u * 3.6);
    _g(b, 20, ly - txt / 2);
    _g(b, 40, txt);
    _g(b, 1, _dxfText(serviceChromeLabel(s)));
    ly -= txt * 2.0;
  }

  // Scale bar — a divided LWPOLYLINE-free LINE bar on layer 'scale', under the
  // legend block.
  final sbY = ly - u * 2;
  final sbLen = u * 12;
  _g(b, 0, 'LINE');
  _g(b, 8, 'scale');
  _g(b, 10, minX);
  _g(b, 20, sbY);
  _g(b, 11, minX + sbLen);
  _g(b, 21, sbY);
  for (var i = 0; i <= 4; i++) {
    final x = minX + sbLen * i / 4;
    _g(b, 0, 'LINE');
    _g(b, 8, 'scale');
    _g(b, 10, x);
    _g(b, 20, sbY);
    _g(b, 11, x);
    _g(b, 21, sbY + (i.isEven ? u : u / 2));
  }
  _g(b, 0, 'TEXT');
  _g(b, 8, 'scale');
  _g(b, 10, minX);
  _g(b, 20, sbY - txt * 1.4);
  _g(b, 40, txt);
  _g(b, 1, _dxfText(
      'SCALE${chrome.scaleBarLabel != null ? '  ${chrome.scaleBarLabel}' : ''}'));

  // North arrow — a LINE shaft + an 'N' on layer 'north', at the drawing's
  // bottom-RIGHT, rotated by the bearing. World Y is y-up here.
  final nx = maxX + u * 3;
  final ny = minY - u * 3;
  final r = u * 2.5;
  final a = -chrome.northAngleRad; // clockwise bearing on a y-up plane
  final ca = math.cos(a), sa = math.sin(a);
  final tipX = nx + (0 * ca - r * sa);
  final tipY = ny + (0 * sa + r * ca);
  final tailX = nx - (0 * ca - r * sa);
  final tailY = ny - (0 * sa + r * ca);
  _g(b, 0, 'LINE');
  _g(b, 8, 'north');
  _g(b, 10, tailX);
  _g(b, 20, tailY);
  _g(b, 11, tipX);
  _g(b, 21, tipY);
  _g(b, 0, 'TEXT');
  _g(b, 8, 'north');
  _g(b, 10, tipX);
  _g(b, 20, tipY + txt / 2);
  _g(b, 40, txt);
  _g(b, 1, 'N');

  return b.toString();
}

/// DXF group-1 text must avoid the control chars that would break the ASCII
/// stream; keep it to printable ASCII.
String _dxfText(String raw) {
  final b = StringBuffer();
  for (final code in raw.runes) {
    b.writeCharCode((code >= 0x20 && code <= 0x7e) ? code : 0x3f);
  }
  return b.toString();
}
