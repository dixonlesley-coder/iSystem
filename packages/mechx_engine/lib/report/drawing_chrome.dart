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
