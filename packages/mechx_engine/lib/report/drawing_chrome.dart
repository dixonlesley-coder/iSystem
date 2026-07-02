/// Issuable-drawing CHROME — the shared, pure helpers that turn a bare vector
/// drawing into an *issuable document*: a service-colour LEGEND, a graphic
/// SCALE BAR, a NORTH arrow, a sheet "X of Y" counter, and a revision /
/// drawing-number title block. Used by the four export engines
/// (`pdf_export`, `plan_pdf_export`, `dxf_export`, `electrical_pdf_export`).
/// Also home of the A1 floor-plan UNDERLAY model + renderers (the substrate
/// the engineer drew on, printed beneath the exported network).
///
/// PURE: emits PDF content-stream fragments (y-up page space, points) and DXF
/// entity fragments (y-up, world units) as strings; never reads the clock, no
/// Flutter imports. All chrome is OPT-IN — an export that passes no
/// [DrawingChrome] is byte-identical to before this module existed.
library;

import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:math' as math;
import 'dart:typed_data';

import '../geometry/dxf_drawing.dart';
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

  // ── ISO-7200 title-block fields (all optional; a row is drawn only when its
  // value is present, so a partially-filled block is fine). ──────────────────

  /// The client / owner the drawing is issued to (title-block CLIENT row).
  final String? clientName;

  /// The drawing's descriptive title (title-block TITLE row, e.g.
  /// `GROUND FLOOR PLUMBING`). Distinct from [drawingNumber].
  final String? drawingTitle;

  /// Initials / name of the drafter (title-block DRAWN row).
  final String? drawnBy;

  /// Initials / name of the checker (title-block CHECKED row).
  final String? checkedBy;

  /// Initials / name of the approver (title-block APPROVED row).
  final String? approvedBy;

  /// Issue date string, pre-formatted by the caller — the engine never reads
  /// the clock (title-block DATE row).
  final String? dateString;

  /// Human scale text for the title-block SCALE row (e.g. `1 : 100`). A
  /// per-render `scaleTextOverride` param takes precedence when supplied.
  final String? scaleText;

  const DrawingChrome({
    this.drawingNumber,
    this.revisionNumber,
    this.sheetIndex,
    this.sheetTotal,
    this.northAngleRad = 0,
    this.legendServices = const [],
    this.scaleBarLabel,
    this.clientName,
    this.drawingTitle,
    this.drawnBy,
    this.checkedBy,
    this.approvedBy,
    this.dateString,
    this.scaleText,
  });

  /// True when nothing would be drawn — lets a caller skip chrome entirely and
  /// stay byte-identical.
  bool get isEmpty =>
      drawingNumber == null &&
      revisionNumber == null &&
      sheetIndex == null &&
      sheetTotal == null &&
      legendServices.isEmpty &&
      clientName == null &&
      drawingTitle == null &&
      drawnBy == null &&
      checkedBy == null &&
      approvedBy == null &&
      dateString == null &&
      scaleText == null;

  /// The "X of Y" sheet counter text, or null when neither part is set.
  String? get sheetCounter {
    if (sheetIndex == null && sheetTotal == null) return null;
    final i = sheetIndex ?? 1;
    final t = sheetTotal ?? i;
    return '$i of $t';
  }
}

/// A named LANDSCAPE sheet size for the plan PDF exporters — ISO A-series,
/// carrying the page dimensions in PDF POINTS and the short label the snapped
/// scale text names (`1 : N @ A2`). A3 is the historical default; A2/A1 give a
/// larger sheet for a denser plan. The point figures are the mm sizes converted
/// at 72/25.4 and rounded to 2 dp (so A3 stays the exact `1190.55 × 841.89` the
/// exporters used before this enum existed — byte-identical). A drafting-office
/// paper choice, not an engineering value, so no `// VERIFY`.
enum PaperSize {
  /// ISO A3 landscape — 420 x 297 mm.
  a3Landscape(1190.55, 841.89, 'A3'),

  /// ISO A2 landscape — 594 x 420 mm.
  a2Landscape(1683.78, 1190.55, 'A2'),

  /// ISO A1 landscape — 841 x 594 mm.
  a1Landscape(2383.94, 1683.78, 'A1');

  const PaperSize(this.widthPt, this.heightPt, this.label);

  /// Page width in PDF points (landscape ⇒ width > height).
  final double widthPt;

  /// Page height in PDF points.
  final double heightPt;

  /// Short sheet label the snapped-scale text names (`A3` / `A2` / `A1`).
  final String label;
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

// ── Shared title-block row model (used by both the PDF + DXF title blocks) ──

/// The ordered ISO-7200-style title-block rows, filtered to those whose value
/// is present (non-null/non-empty). [projectName] is always the PROJECT row;
/// [scaleTextOverride] wins over [DrawingChrome.scaleText] for the SCALE row,
/// and [titleTextOverride] / [dateTextOverride] likewise win over
/// [DrawingChrome.drawingTitle] / [DrawingChrome.dateString] (so an exporter
/// with its own sheet-name/date params keeps them on the issued sheet).
List<(String, String)> _titleBlockRows(
  DrawingChrome chrome,
  String projectName,
  String? scaleTextOverride, {
  String? titleTextOverride,
  String? dateTextOverride,
}) {
  final rows = <(String, String)>[
    ('PROJECT', projectName),
    ('CLIENT', chrome.clientName ?? ''),
    ('TITLE', titleTextOverride ?? chrome.drawingTitle ?? ''),
    ('DWG NO', chrome.drawingNumber ?? ''),
    ('REV', chrome.revisionNumber ?? ''),
    ('SCALE', scaleTextOverride ?? chrome.scaleText ?? ''),
    ('DATE', dateTextOverride ?? chrome.dateString ?? ''),
    ('DRAWN', chrome.drawnBy ?? ''),
    ('CHECKED', chrome.checkedBy ?? ''),
    ('APPROVED', chrome.approvedBy ?? ''),
    if (chrome.sheetCounter != null) ('SHEET', chrome.sheetCounter!),
  ];
  return rows.where((r) => r.$2.trim().isNotEmpty).toList();
}

// ── Issuable-SHEET PDF renderers (content-stream fragments, page space) ─────

/// A thin ISO-5457 sheet FRAME — one border rectangle inset by [margin] from
/// the page edges, drawn at 0.8 pt. Always renders (the frame carries no
/// data), so a caller gates it on whether it wants a bordered sheet.
String pdfSheetFrame({
  required double pageW,
  required double pageH,
  required double margin,
}) {
  final cs = StringBuffer();
  cs.writeln('0 0 0 RG 0.8 w');
  cs.writeln('${_n(margin)} ${_n(margin)} '
      '${_n(pageW - 2 * margin)} ${_n(pageH - 2 * margin)} re S');
  return cs.toString();
}

/// A boxed ISO-7200 title block in the bottom-RIGHT of the page. Rows are the
/// filtered [_titleBlockRows]; each row is a small muted label cell + a value
/// cell, hairline-ruled. Returns the content-stream `ops` PLUS the block
/// `height` so an exporter can reserve the vertical space above it. [ops] is ''
/// and [height] 0 when no row has a value.
({String ops, double height}) pdfTitleBlock(
  DrawingChrome chrome, {
  required double pageW,
  required double pageH,
  required double margin,
  required String projectName,
  String? scaleTextOverride,
  String? titleTextOverride,
  String? dateTextOverride,
}) {
  final rows = _titleBlockRows(chrome, projectName, scaleTextOverride,
      titleTextOverride: titleTextOverride, dateTextOverride: dateTextOverride);
  if (rows.isEmpty) return (ops: '', height: 0.0);

  const rowH = 13.0;
  const blockW = 190.0; // ~ ISO-7200 width in points
  const labelW = 52.0; // the muted label cell width
  final height = rows.length * rowH;
  final x0 = pageW - margin - blockW;
  final yBottom = margin;

  final cs = StringBuffer();
  cs.writeln('0 0 0 RG 0.4 w'); // hairline rules
  // Outer box.
  cs.writeln('${_n(x0)} ${_n(yBottom)} ${_n(blockW)} ${_n(height)} re S');
  // Rows top-to-bottom (first present row at the top of the block).
  for (var i = 0; i < rows.length; i++) {
    final (label, value) = rows[i];
    final rowTop = yBottom + height - i * rowH;
    final rowBot = rowTop - rowH;
    // Horizontal rule between rows (the outer box already draws top + bottom).
    if (i > 0) {
      cs.writeln('${_n(x0)} ${_n(rowTop)} m ${_n(x0 + blockW)} ${_n(rowTop)} l S');
    }
    // Vertical divider between the label + value cells.
    cs.writeln('${_n(x0 + labelW)} ${_n(rowBot)} m '
        '${_n(x0 + labelW)} ${_n(rowTop)} l S');
    final ty = rowBot + 3.5;
    // Muted label cell (grey, small).
    cs.writeln('BT /F1 6 Tf 0.4 0.4 0.4 rg '
        '${_n(x0 + 3)} ${_n(ty)} Td (${_pdfText(label)}) Tj ET');
    // Value cell (black).
    cs.writeln('BT /F1 8 Tf 0 0 0 rg '
        '${_n(x0 + labelW + 4)} ${_n(ty)} Td (${_pdfText(value)}) Tj ET');
  }
  return (ops: cs.toString(), height: height);
}

/// The ladder of "nice" real scale-bar lengths, in metres, for
/// [pdfScaleBarReal] — a drafting-office convention (not an SNI clause).
const _pdfScaleLadderM = <double>[1, 2, 5, 10, 20, 50, 100];

/// An HONEST graphic scale bar: given the page's [pointsPerMeter] (real-world
/// metres → page points), it picks the ladder length whose drawn width lands
/// nearest 120 pt, draws 4 alternating filled/open divisions, and figures the
/// metre marks at 0 / mid / end. Centred on [centerX] at [baseY]. Returns ''
/// when [pointsPerMeter] is not finite/positive (nothing honest to draw).
String pdfScaleBarReal({
  required double pointsPerMeter,
  required double centerX,
  required double baseY,
}) {
  if (!pointsPerMeter.isFinite || pointsPerMeter <= 0) return '';
  const targetPt = 120.0;
  var bestM = _pdfScaleLadderM.first;
  var bestErr = double.infinity;
  for (final m in _pdfScaleLadderM) {
    final err = (m * pointsPerMeter - targetPt).abs();
    if (err < bestErr) {
      bestErr = err;
      bestM = m;
    }
  }
  final barLen = bestM * pointsPerMeter;
  final divW = barLen / 4;
  const barH = 4.0;
  final x0 = centerX - barLen / 2;

  final cs = StringBuffer();
  cs.writeln('0 0 0 RG 0 0 0 rg 0.6 w');
  // 4 alternating divisions: even filled, odd open.
  for (var i = 0; i < 4; i++) {
    final dx = x0 + divW * i;
    cs.writeln('${_n(dx)} ${_n(baseY)} ${_n(divW)} ${_n(barH)} re '
        '${i.isEven ? 'f' : 'S'}');
  }
  // Whole-bar outline (so open divisions read as a bar).
  cs.writeln('${_n(x0)} ${_n(baseY)} ${_n(barLen)} ${_n(barH)} re S');
  // Metre figures at 0 / mid / end.
  String fig(double m) =>
      m == m.roundToDouble() ? m.round().toString() : _n(m);
  cs.writeln('BT /F1 8 Tf 0 0 0 rg '
      '${_n(x0 - 2)} ${_n(baseY - 10)} Td (${_pdfText('0')}) Tj ET');
  cs.writeln('BT /F1 8 Tf 0 0 0 rg '
      '${_n(centerX - 4)} ${_n(baseY - 10)} Td '
      '(${_pdfText('${fig(bestM / 2)} m')}) Tj ET');
  cs.writeln('BT /F1 8 Tf 0 0 0 rg '
      '${_n(x0 + barLen - 4)} ${_n(baseY - 10)} Td '
      '(${_pdfText('${fig(bestM)} m')}) Tj ET');
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

// ── Shared service tables (drafting-office CAD conventions) ─────────────────
//
// These are draughting *style* choices — CAD layer names, ACI colours, and
// line-types a drafter expects on an issued sheet — NOT engineering values, so
// they carry no `// VERIFY` flag. They mirror `serviceChromeColor`'s placement
// so a caller can key layer/colour/line-type/dash off one switch each.

/// Standard AIA-flavoured CAD LAYER name per service (discipline-prefixed:
/// P- plumbing, M- mechanical, F- fire).
String dxfLayerNameFor(ServiceType s) => switch (s) {
      ServiceType.coldWater => 'P-DOM-CWS',
      ServiceType.hotWater => 'P-DOM-HWS',
      ServiceType.drainage => 'P-SAN-PIPE',
      ServiceType.vent => 'P-SAN-VENT',
      ServiceType.rainwater => 'P-STM-PIPE',
      ServiceType.duct => 'M-HVAC-SUPP',
      ServiceType.returnAir => 'M-HVAC-RETN',
      ServiceType.exhaust => 'M-HVAC-EXHS',
      ServiceType.fireSprinkler => 'F-SPR-PIPE',
      ServiceType.fireHydrant => 'F-HYD-PIPE',
    };

/// DXF annotation-text layer (labels/legend text).
const kDxfLayerAnno = 'G-ANNO-TEXT';

/// DXF sheet-frame / title-block layer.
const kDxfLayerFrame = 'G-ANNO-TTLB';

/// Nearest-ACI colour index per service, chosen from the `serviceChromeColor`
/// hues (ACI: 1 red, 2 yellow, 3 green, 4 cyan, 5 blue, 6 magenta, 7 white,
/// 8 grey). Cold water reads blue, hot water orange, rainwater cyan, sprinkler
/// red, hydrant a darker red, exhaust grey; supply/return air stay distinct.
int serviceAciColorFor(ServiceType s) => switch (s) {
      ServiceType.coldWater => 5, // blue
      ServiceType.hotWater => 30, // orange
      ServiceType.drainage => 34, // brown
      ServiceType.vent => 3, // green (teal-ish)
      ServiceType.rainwater => 4, // cyan
      ServiceType.duct => 6, // magenta/violet (supply air)
      ServiceType.returnAir => 52, // olive/green-yellow (return air)
      ServiceType.exhaust => 8, // grey
      ServiceType.fireSprinkler => 1, // red
      ServiceType.fireHydrant => 12, // dark red
    };

/// PDF dash pattern (on/off run lengths in points) per service, or null for a
/// solid line. Vent + return air read DASHED; sprinkler + hydrant dash-dot.
List<double>? serviceDashPatternPdf(ServiceType s) => switch (s) {
      ServiceType.vent || ServiceType.returnAir => const [6, 4],
      ServiceType.fireSprinkler ||
      ServiceType.fireHydrant =>
        const [10, 3, 2, 3],
      _ => null,
    };

/// DXF line-type name per service, consistent with [serviceDashPatternPdf].
String dxfLinetypeFor(ServiceType s) => switch (s) {
      ServiceType.vent || ServiceType.returnAir => 'DASHED',
      ServiceType.fireSprinkler || ServiceType.fireHydrant => 'DASHDOT',
      _ => 'CONTINUOUS',
    };

/// A complete DXF R12 `TABLES` section: the three line-types
/// (CONTINUOUS / DASHED / DASHDOT) plus one LAYER record per [layers] triple
/// `(name, aciColor, linetype)`. Emit this before the `ENTITIES` section so a
/// CAD app resolves each entity's layer colour + line-type.
String dxfTablesSection({required List<(String, int, String)> layers}) {
  final b = StringBuffer();
  _g(b, 0, 'SECTION');
  _g(b, 2, 'TABLES');

  // LTYPE table.
  _g(b, 0, 'TABLE');
  _g(b, 2, 'LTYPE');
  _g(b, 70, 3);
  // CONTINUOUS — a solid line (no dash elements).
  _g(b, 0, 'LTYPE');
  _g(b, 2, 'CONTINUOUS');
  _g(b, 70, 0);
  _g(b, 3, 'Solid line');
  _g(b, 72, 65);
  _g(b, 73, 0);
  _g(b, 40, '0.0');
  // DASHED — dash 12, gap 6 (total 18).
  _g(b, 0, 'LTYPE');
  _g(b, 2, 'DASHED');
  _g(b, 70, 0);
  _g(b, 3, 'Dashed __ __ __');
  _g(b, 72, 65);
  _g(b, 73, 2);
  _g(b, 40, '18.0');
  _g(b, 49, '12.0');
  _g(b, 49, '-6.0');
  // DASHDOT — dash 12, gap 4, dot, gap 4 (total 20).
  _g(b, 0, 'LTYPE');
  _g(b, 2, 'DASHDOT');
  _g(b, 70, 0);
  _g(b, 3, 'Dash dot _ . _ .');
  _g(b, 72, 65);
  _g(b, 73, 4);
  _g(b, 40, '20.0');
  _g(b, 49, '12.0');
  _g(b, 49, '-4.0');
  _g(b, 49, '0.0');
  _g(b, 49, '-4.0');
  _g(b, 0, 'ENDTAB');

  // LAYER table.
  _g(b, 0, 'TABLE');
  _g(b, 2, 'LAYER');
  _g(b, 70, layers.length);
  for (final (name, color, linetype) in layers) {
    _g(b, 0, 'LAYER');
    _g(b, 2, name);
    _g(b, 70, 0);
    _g(b, 62, color);
    _g(b, 6, linetype);
  }
  _g(b, 0, 'ENDTAB');

  _g(b, 0, 'ENDSEC');
  return b.toString();
}

/// Convenience [dxfTablesSection] wrapper: builds the LAYER list for a set of
/// [services] (deduped) via [dxfLayerNameFor] / [serviceAciColorFor] /
/// [dxfLinetypeFor], plus the ANNO + FRAME layers (colour 7, CONTINUOUS).
String dxfTablesForServices(Iterable<ServiceType> services) {
  final layers = <(String, int, String)>[
    for (final s in services.toSet())
      (dxfLayerNameFor(s), serviceAciColorFor(s), dxfLinetypeFor(s)),
    (kDxfLayerAnno, 7, 'CONTINUOUS'),
    (kDxfLayerFrame, 7, 'CONTINUOUS'),
  ];
  return dxfTablesSection(layers: layers);
}

/// The DXF sibling of [pdfTitleBlock]: the same filtered [_titleBlockRows]
/// rendered as LINEs + TEXT on [kDxfLayerFrame], anchored to the bottom-RIGHT
/// of the [minX]/[minY]/[maxX]/[maxY] extent (DXF world, y-up). Returns ''
/// when no row has a value.
String dxfTitleBlock(
  DrawingChrome chrome, {
  required double minX,
  required double minY,
  required double maxX,
  required double maxY,
  required String projectName,
  String? scaleTextOverride,
}) {
  final rows = _titleBlockRows(chrome, projectName, scaleTextOverride);
  if (rows.isEmpty) return '';
  final b = StringBuffer();

  final spanX = (maxX - minX).abs();
  final spanY = (maxY - minY).abs();
  final span = math.max(math.max(spanX, spanY), 1.0);
  final u = span / 40.0; // sizing unit, scales to the drawing extent
  final txt = u * 1.2; // value text height
  final rowH = txt * 2.4;
  final blockW = u * 16;
  final labelW = blockW * 0.32;
  final height = rows.length * rowH;
  final x0 = maxX - blockW; // right edge at maxX
  final yBottom = minY; // bottom at minY

  void line(double ax, double ay, double bx, double by) {
    _g(b, 0, 'LINE');
    _g(b, 8, kDxfLayerFrame);
    _g(b, 10, ax);
    _g(b, 20, ay);
    _g(b, 11, bx);
    _g(b, 21, by);
  }

  void text(double tx, double ty, double h, String s) {
    _g(b, 0, 'TEXT');
    _g(b, 8, kDxfLayerFrame);
    _g(b, 10, tx);
    _g(b, 20, ty);
    _g(b, 40, h);
    _g(b, 1, _dxfText(s));
  }

  // Outer box.
  line(x0, yBottom, x0 + blockW, yBottom);
  line(x0 + blockW, yBottom, x0 + blockW, yBottom + height);
  line(x0 + blockW, yBottom + height, x0, yBottom + height);
  line(x0, yBottom + height, x0, yBottom);
  // Full-height label/value divider.
  line(x0 + labelW, yBottom, x0 + labelW, yBottom + height);
  // Rows top-to-bottom.
  for (var i = 0; i < rows.length; i++) {
    final (label, value) = rows[i];
    final rowTop = yBottom + height - i * rowH;
    final rowBot = rowTop - rowH;
    if (i > 0) line(x0, rowTop, x0 + blockW, rowTop);
    final ty = rowBot + txt * 0.5;
    text(x0 + u * 0.4, ty, txt * 0.7, label);
    text(x0 + labelW + u * 0.4, ty, txt, value);
  }
  return b.toString();
}

// ── True plotted scale (A3) + line-weight bands (A6) + label discipline (A7) ─
//
// Like the service tables above, these are draughting *style* conventions —
// standard plot scales, ISO-128-flavoured pen-weight bands, and label layout —
// NOT engineering values, so they carry no `// VERIFY` flag.

/// The standard plotted-scale ladder (denominators of `1 : N`) the plan PDF
/// exporters snap their auto-fit to — a drawing is only ever issued at one of
/// these, never at an arbitrary ratio an engineer could mis-scale from.
const kPlanScaleLadder = <int>[20, 50, 100, 200, 250, 500, 1000];

/// The outcome of snapping a raw auto-fit to a standard plotted scale — the
/// shared A3 helper both plan PDF exporters use so they snap identically.
class PlottedScale {
  /// The (possibly re-fitted) sheet scale to draw at.
  final double scale;

  /// The title-block SCALE row text — `NTS` when uncalibrated or too large for
  /// the ladder, else `1 : N @ <paper>` naming the ACTUAL paper.
  final String scaleRow;

  /// Points-per-metre at the snapped scale, or null when NTS (so the honest
  /// divided scale bar is drawn only when a real ratio exists).
  final double? pointsPerMeter;

  const PlottedScale(this.scale, this.scaleRow, this.pointsPerMeter);
}

/// A3 true plotted scale: snap [rawScale] (the auto-fit) to the nearest
/// standard rung of [kPlanScaleLadder] whose denominator is >= the raw fit's
/// (so the drawing never draws larger than the honest snap), given the sheet
/// calibration [metersPerPixel]. Returns the raw fit at `NTS` when
/// uncalibrated, when there is no content, or when the plan is too large even
/// for 1:1000. [paperLabel] names the ACTUAL paper in the snapped-scale text
/// (`1 : N @ A2`). Pure — shared verbatim by `networkToPdf` / `planToPdf`.
PlottedScale snapPlottedScale({
  required double rawScale,
  required double? metersPerPixel,
  required bool hasContent,
  required String paperLabel,
}) {
  var scale = rawScale;
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
      return PlottedScale(scale, '1 : $snappedN @ $paperLabel',
          scale / metersPerPixel);
    }
    // else: too large even for 1:1000 — keep the honest auto-fit, stay NTS.
  }
  return PlottedScale(scale, 'NTS', null);
}

/// PDF stroke widths in points for the three A6 line-weight bands
/// (index 0 small / 1 medium / 2 large). Unsized edges keep the legacy 1.4 w.
const kPdfStrokeWidths = <double>[1.0, 1.6, 2.2];

/// DXF group-370 lineweights (hundredths of a millimetre: 0.13 / 0.25 /
/// 0.35 mm) for the same three bands.
const kDxfLineweights = <int>[13, 25, 35];

/// The A6 stroke band (0 small / 1 medium / 2 large) for a sized element.
/// Pipes band on DN — small <= 50, medium <= 150; ducts on their largest
/// cross dimension — small <= 250 mm, medium <= 500 mm.
int strokeBandFor({required double sizeMm, required bool isDuct}) {
  final (double small, double medium) = isDuct ? (250, 500) : (50, 150);
  if (sizeMm <= small) return 0;
  if (sizeMm <= medium) return 1;
  return 2;
}

/// An axis-aligned box occupied by an already-placed label, in the output
/// space (y-up), for the A7 greedy collision pass.
typedef LabelBox = ({double minX, double minY, double maxX, double maxY});

/// A resolved A7 edge-label placement: the text anchor (the baseline START —
/// the left end of the rotated baseline) plus the rotation in degrees
/// counter-clockwise in the y-up output space — feed a PDF `Tm` matrix
/// (cos/sin) or a DXF TEXT group 50 directly.
class EdgeLabelPlacement {
  final double x;
  final double y;
  final double angleDeg;
  const EdgeLabelPlacement(
      {required this.x, required this.y, required this.angleDeg});
}

bool _boxesOverlap(LabelBox a, LabelBox b) =>
    a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY;

/// A7 label discipline: place [text] along the edge (ax,ay)→(bx,by) in the
/// y-up output space, rotated to the edge bearing (flipped 180 deg past +-90
/// so it never reads upside-down; an exactly-vertical run reads bottom-to-top,
/// the drafting convention), offset perpendicular by 0.7 × [textSize] on the
/// consistent upper side of the line. Greedy collision pass against [placed]:
/// on overlap try the lower side, then slide to the quarter point (upper then
/// lower), else return null — the label is DROPPED rather than overprinting.
/// A successful placement appends its box to [placed]. Text width is
/// estimated as chars × size × 0.55 (the Helvetica average). Pure and
/// deterministic.
EdgeLabelPlacement? placeEdgeLabel({
  required double ax,
  required double ay,
  required double bx,
  required double by,
  required String text,
  required double textSize,
  required List<LabelBox> placed,
}) {
  final dx = bx - ax, dy = by - ay;
  var angle = (dx == 0 && dy == 0) ? 0.0 : math.atan2(dy, dx);
  // Flip past +-90 deg so the text reads upright (exactly -90 flips to +90).
  if (angle > math.pi / 2 || angle <= -math.pi / 2) {
    angle += angle > 0 ? -math.pi : math.pi;
  }
  final ca = math.cos(angle), sa = math.sin(angle);
  final w = text.length * textSize * 0.55;

  // Candidate (anchor point along the edge, side) pairs in greedy order:
  // midpoint upper, midpoint lower, quarter-point upper, quarter-point lower.
  final anchors = <(double, double)>[
    ((ax + bx) / 2, (ay + by) / 2),
    (ax + dx * 0.25, ay + dy * 0.25),
  ];
  for (final (cx, cy) in anchors) {
    for (final side in const [1, -1]) {
      // Perpendicular baseline displacement: the text box rises [textSize]
      // above its baseline, so the lower side backs off by the box height too
      // (both sides then clear the line by ~0.7 × size).
      final d = side == 1 ? 0.7 * textSize : -(0.7 * textSize + textSize);
      // Baseline centre = anchor + d × the upper-perpendicular (-sin, cos);
      // anchor (baseline start) = half the width back along the bearing.
      final x0 = cx - sa * d - ca * w / 2;
      final y0 = cy + ca * d - sa * w / 2;
      // Axis-aligned bounds of the rotated w × textSize text rect.
      final xs = [x0, x0 + ca * w, x0 - sa * textSize, x0 + ca * w - sa * textSize];
      final ys = [y0, y0 + sa * w, y0 + ca * textSize, y0 + sa * w + ca * textSize];
      final box = (
        minX: xs.reduce(math.min),
        minY: ys.reduce(math.min),
        maxX: xs.reduce(math.max),
        maxY: ys.reduce(math.max),
      );
      if (placed.any((p) => _boxesOverlap(p, box))) continue;
      placed.add(box);
      return EdgeLabelPlacement(x: x0, y: y0, angleDeg: angle * 180 / math.pi);
    }
  }
  return null;
}

// ── A1 floor-plan UNDERLAY (printed beneath the exported network) ───────────
//
// The plan exporters historically drew the network floating on white — the
// sheet's PDF raster and parsed `DxfDrawing` both exist in the product but
// never reached an export (CAD-OUTPUT-UX-REVIEW A1). The underlay is OPT-IN
// like the chrome: a null underlay keeps every exporter byte-identical.

/// DXF layer the re-emitted floor-plan underlay entities live on, so a CAD
/// user can toggle/lock the background plan independently of the MEP work.
const kDxfLayerUnderlay = 'G-ANNO-UNDR';

/// ACI colour for the underlay layer/entities — 8 (grey), the CAD convention
/// for background/reference linework.
const kDxfUnderlayAci = 8;

/// The floor-plan substrate to print BENEATH an exported network — either the
/// already-parsed vector [DxfDrawing] (a DXF-backed sheet) or a pre-rendered,
/// pre-faded raster (a PDF-backed sheet). Both carry the sheet's content-frame
/// size in SHEET PIXELS — the same frame the drawn nodes' x/y live in — so the
/// exporters map the underlay through their own fitted transform and it lands
/// exactly under the network.
sealed class PlanUnderlay {
  const PlanUnderlay();

  /// The sheet content-frame width in sheet pixels (`Sheet.sizePx`).
  double get sheetWidthPx;

  /// The sheet content-frame height in sheet pixels (`Sheet.sizePx`).
  double get sheetHeightPx;
}

/// The VECTOR underlay: a parsed [DxfDrawing] plus the sheet-pixel frame it is
/// uniformly fitted into. The fit REPRODUCES the canvas one
/// (`dxf_import.dxfContentSize` + `dxf_sheet_page._DxfPainter`): world
/// coordinates (y-up) are scaled by [worldToSheetScale] and Y-flipped into the
/// y-down sheet-pixel frame, so the underlay lands in the SAME frame as the
/// drawn nodes.
class VectorPlanUnderlay extends PlanUnderlay {
  final DxfDrawing drawing;
  @override
  final double sheetWidthPx;
  @override
  final double sheetHeightPx;

  const VectorPlanUnderlay({
    required this.drawing,
    required this.sheetWidthPx,
    required this.sheetHeightPx,
  });

  /// The uniform DXF-world → sheet-pixel scale — the canvas rule verbatim:
  /// width ratio when the bounds width is non-degenerate, else the height
  /// ratio, else 1 (a degenerate drawing maps 1:1).
  double get worldToSheetScale {
    final b = drawing.bounds;
    final kx = b.width > 1e-9 ? sheetWidthPx / b.width : 0.0;
    final ky = b.height > 1e-9 ? sheetHeightPx / b.height : 0.0;
    if (kx != 0.0) return kx;
    return ky != 0.0 ? ky : 1.0;
  }

  /// DXF world (x, y — y-up) → sheet pixels (y-down):
  /// `x' = (x − minX)·k`, `y' = (maxY − y)·k` — the exact map the canvas
  /// paints the DXF background with.
  (double, double) toSheetPx(double x, double y) {
    final b = drawing.bounds;
    final k = worldToSheetScale;
    return ((x - b.minX) * k, (b.maxY - y) * k);
  }
}

/// The RASTER underlay: pre-rendered RGB8 pixel rows covering the FULL sheet
/// frame `[0, sheetWidthPx] × [0, sheetHeightPx]`, row 0 = the sheet TOP
/// (matching a PDF image XObject's row order). The app pre-fades the pixels
/// toward white before handing them over — the engine embeds them verbatim.
class RasterPlanUnderlay extends PlanUnderlay {
  /// Raw RGB rows, 3 bytes per pixel, row-major from the top —
  /// `pixelWidth × pixelHeight × 3` bytes.
  final Uint8List rgbPixels;
  final int pixelWidth;
  final int pixelHeight;
  @override
  final double sheetWidthPx;
  @override
  final double sheetHeightPx;

  const RasterPlanUnderlay({
    required this.rgbPixels,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.sheetWidthPx,
    required this.sheetHeightPx,
  }) : assert(rgbPixels.length == pixelWidth * pixelHeight * 3,
            'rgbPixels must be width × height × 3 bytes of RGB8');
}

/// A stroked PDF bezier circle (the exporters' own 4-arc kappa construction).
void _pdfCircleOps(StringBuffer cs, double cx, double cy, double r) {
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

/// The underlay ink: 25 % grey at a thin 0.5 pt — unmistakably background, so
/// the coloured network strokes always read on top (a draughting *style*
/// choice, not an engineering value).
const double _kUnderlayGrey = 0.75;
const double _kUnderlayStrokeW = 0.5;

/// PDF content-stream ops stroking [u]'s DXF linework as the pale-grey
/// underlay — an exporter writes this FIRST so every network stroke, label and
/// chrome overprints it. [tx]/[ty] are the exporter's own sheet-pixel → page
/// transform (y-flip included); [pageScale] its sheet-px → page-points factor,
/// used for radii. Arcs are flattened to short chords (the underlay is a
/// display background, never survey data — same simplification the canvas
/// makes for polyline bulges).
String pdfVectorUnderlayOps(
  VectorPlanUnderlay u, {
  required double Function(double x) tx,
  required double Function(double y) ty,
  required double pageScale,
}) {
  final cs = StringBuffer();
  cs.writeln('${_n(_kUnderlayGrey)} ${_n(_kUnderlayGrey)} '
      '${_n(_kUnderlayGrey)} RG');
  cs.writeln('${_n(_kUnderlayStrokeW)} w');
  final k = u.worldToSheetScale;
  (double, double) map(double x, double y) {
    final (sx, sy) = u.toSheetPx(x, y);
    return (tx(sx), ty(sy));
  }

  for (final pl in u.drawing.polylines) {
    if (pl.points.length < 2) continue;
    final (x0, y0) = map(pl.points.first.x, pl.points.first.y);
    cs.write('${_n(x0)} ${_n(y0)} m');
    for (var i = 1; i < pl.points.length; i++) {
      final (x, y) = map(pl.points[i].x, pl.points[i].y);
      cs.write(' ${_n(x)} ${_n(y)} l');
    }
    cs.writeln(pl.closed ? ' h S' : ' S');
  }
  for (final c in u.drawing.circles) {
    final (cx, cy) = map(c.center.x, c.center.y);
    _pdfCircleOps(cs, cx, cy, c.radius * k * pageScale);
  }
  for (final a in u.drawing.arcs) {
    // Sample the CCW sweep in world space and map each point — the sheet-px
    // Y-flip and the page fit both ride the shared map, so no angle algebra.
    var sweep = a.endDeg - a.startDeg;
    while (sweep <= 0) {
      sweep += 360;
    }
    final steps = math.max(4, (sweep / 12).ceil());
    for (var i = 0; i <= steps; i++) {
      final rad = (a.startDeg + sweep * i / steps) * math.pi / 180;
      final (x, y) = map(a.center.x + a.radius * math.cos(rad),
          a.center.y + a.radius * math.sin(rad));
      cs.write(i == 0 ? '${_n(x)} ${_n(y)} m' : ' ${_n(x)} ${_n(y)} l');
    }
    cs.writeln(' S');
  }
  return cs.toString();
}

/// The content-stream ops painting the raster underlay image `/Im1` into its
/// fitted page rect ([x]/[y] = the rect's BOTTOM-LEFT in points). A PDF image
/// fills the unit square with pixel row 0 at the TOP, matching the raster's
/// top-down sheet rows — so a plain scale-to-rect `cm` places it upright.
String pdfRasterUnderlayOps({
  required double x,
  required double y,
  required double w,
  required double h,
}) =>
    'q ${_n(w)} 0 0 ${_n(h)} ${_n(x)} ${_n(y)} cm /Im1 Do Q\n';

/// The complete PDF object BODY (dict + stream) for a raster underlay's
/// FlateDecode `/Image` XObject — the raw RGB8 rows zlib-deflated (`dart:io`'s
/// [zlib] produces exactly the zlib-wrapped DEFLATE that `/FlateDecode`
/// decodes). Returned as raw BYTES because the deflated stream is binary,
/// unlike the exporters' latin1-text objects; the exporter writes it between
/// its own `N 0 obj` / `endobj` markers and names it `/Im1` in the page
/// resources.
List<int> pdfRasterUnderlayObject(RasterPlanUnderlay u) {
  final deflated = zlib.encode(u.rgbPixels);
  final head = '<< /Type /XObject /Subtype /Image '
      '/Width ${u.pixelWidth} /Height ${u.pixelHeight} '
      '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode '
      '/Length ${deflated.length} >>\nstream\n';
  return [...latin1.encode(head), ...deflated, ...latin1.encode('\nendstream')];
}

/// Re-emit [u]'s parsed DXF primitives as underlay ENTITIES on
/// [kDxfLayerUnderlay] — LINEs per polyline segment (mirroring what `parseDxf`
/// yields for LINE/LWPOLYLINE/POLYLINE), plus native CIRCLE/ARC — transformed
/// into the export's world frame. [unitsPerSheetPx] is 1 for the legacy
/// pixel-space document and `mmPerPx` for the professional millimetre one.
///
/// The net map is `X = (x − minX)·k`, `Y = (y − maxY)·k` (sheet pixels are
/// y-DOWN and the DXF export negates Y back to y-up) — a pure translate +
/// uniform scale of the source geometry, so ARC angles and sweeps carry over
/// UNCHANGED. Each entity carries group 62 = [kDxfUnderlayAci] so the underlay
/// reads grey even in the legacy document, which has no LAYER table.
String dxfUnderlayEntities(
  VectorPlanUnderlay u, {
  double unitsPerSheetPx = 1.0,
}) {
  final b = StringBuffer();
  final bnd = u.drawing.bounds;
  final k = u.worldToSheetScale * unitsPerSheetPx;
  (double, double) map(double x, double y) =>
      ((x - bnd.minX) * k, (y - bnd.maxY) * k);

  void head(String type) {
    _g(b, 0, type);
    _g(b, 8, kDxfLayerUnderlay);
    _g(b, 62, kDxfUnderlayAci);
  }

  void line(DxfPoint p1, DxfPoint p2) {
    final (x1, y1) = map(p1.x, p1.y);
    final (x2, y2) = map(p2.x, p2.y);
    head('LINE');
    _g(b, 10, x1);
    _g(b, 20, y1);
    _g(b, 11, x2);
    _g(b, 21, y2);
  }

  for (final pl in u.drawing.polylines) {
    final pts = pl.points;
    for (var i = 0; i + 1 < pts.length; i++) {
      line(pts[i], pts[i + 1]);
    }
    if (pl.closed && pts.length > 2) line(pts.last, pts.first);
  }
  for (final c in u.drawing.circles) {
    final (cx, cy) = map(c.center.x, c.center.y);
    head('CIRCLE');
    _g(b, 10, cx);
    _g(b, 20, cy);
    _g(b, 40, c.radius * k);
  }
  for (final a in u.drawing.arcs) {
    final (cx, cy) = map(a.center.x, a.center.y);
    head('ARC');
    _g(b, 10, cx);
    _g(b, 20, cy);
    _g(b, 40, a.radius * k);
    _g(b, 50, a.startDeg);
    _g(b, 51, a.endDeg);
  }
  return b.toString();
}

// ── Shared plan-PDF plumbing (fit bounds + document assembly) ───────────────
//
// The two plan PDF exporters (`pdf_export` / `plan_pdf_export`) share an
// identical fit-bounds accumulation and an identical single-page object /
// cross-reference assembly. They live here as pure helpers so the two stay in
// lockstep; extraction is byte-identical (no output change).

/// The screen-pixel fit bounds for the [sheetId]/[floorIndex] slice of [net]
/// plus any [underlay] frame — the exact accumulation both plan exporters use.
/// Runs contribute both endpoints only when both are on the floor; risers
/// contribute whichever endpoint is on the floor. An underlay joins the fit at
/// `[0, sheetWidthPx] × [0, sheetHeightPx]`. [hasContent] is false when nothing
/// was drawable; the returned min/max then carry the `(0,0)–(1,1)` fallback the
/// exporters draw the (title-only) empty page into.
({double minX, double minY, double maxX, double maxY, bool hasContent})
    planFitBounds(
  Network net,
  String sheetId,
  int floorIndex,
  PlanUnderlay? underlay,
) {
  bool onFloor(NetNode n) => n.sheetId == sheetId && n.floorIndex == floorIndex;
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

  if (underlay != null) {
    minX = math.min(minX, 0);
    minY = math.min(minY, 0);
    maxX = math.max(maxX, underlay.sheetWidthPx);
    maxY = math.max(maxY, underlay.sheetHeightPx);
  }

  final hasContent = minX.isFinite;
  if (!hasContent) {
    minX = 0;
    minY = 0;
    maxX = 1;
    maxY = 1;
  }
  return (minX: minX, minY: minY, maxX: maxX, maxY: maxY, hasContent: hasContent);
}

/// Assemble the finished single-page plan PDF from its already-built content
/// stream — the byte-accurate object list + cross-reference table both plan
/// exporters share. [content] is the page content stream; [pageW]/[pageH] set
/// the `/MediaBox`; a non-null [raster] adds the FlateDecode image XObject
/// (object 6) referenced from the page resources. Byte-identical to the inline
/// assembly it replaces.
Uint8List assemblePlanPdfDocument({
  required String content,
  required double pageW,
  required double pageH,
  RasterPlanUnderlay? raster,
}) {
  final contentLen = latin1.encode(content).length;
  final objects = <Object>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R '
        '/MediaBox [0 0 ${_n(pageW)} ${_n(pageH)}] '
        '/Resources << /Font << /F1 5 0 R >> '
        '${raster != null ? '/XObject << /Im1 6 0 R >> ' : ''}'
        '>> /Contents 4 0 R >>',
    '<< /Length $contentLen >>\nstream\n$content\nendstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    if (raster != null) pdfRasterUnderlayObject(raster),
  ];

  final out = BytesBuilder();
  void w(String s) => out.add(latin1.encode(s));
  w('%PDF-1.4\n');
  w('%âãÏÓ\n'); // binary marker
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    w('${i + 1} 0 obj\n');
    final o = objects[i];
    if (o is String) {
      w(o);
    } else {
      out.add(o as List<int>); // the binary image object
    }
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
