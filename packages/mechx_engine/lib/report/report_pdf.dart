/// Paginating PDF TYPESETTER for the report block model — turns any
/// `List<RptBlock>` (`report_blocks.dart`) into a typeset, submittable A4
/// PORTRAIT calculation-report PDF: cover page, running footer with real
/// `Page X of Y` numbering, wrapped paragraphs, ruled tables that split across
/// pages with the header band repeated, and embedded vector figures
/// (`SldSheet` primitives).
///
/// Built on the repo's proven raw-PDF object-assembly technique (see
/// `electrical_pdf_export.dart`): plain uncompressed content streams, a
/// byte-accurate cross-reference table, Type1 Helvetica / Helvetica-Bold.
/// Text is wrapped with the standard Helvetica AFM character-width tables —
/// public typographic metrics, not engineering data.
///
/// Pure Dart, zero Flutter imports. The app renders blocks + handles file IO.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'report_blocks.dart';
import 'sld_sheet.dart';

// ── Page geometry (A4 portrait, points) ─────────────────────────────────────
const double _pageW = 595.28; // 210 mm
const double _pageH = 841.89; // 297 mm
const double _margin = 48.0;
const double _contentW = _pageW - 2 * _margin;

/// Bottom limit for flowed content — the strip below is the footer's.
const double _bottomLimit = _margin + 18.0;

// ── Helvetica AFM character widths (units per 1000, chars 0x20–0x7E) ─────────
// Standard Adobe AFM metrics for the base-14 Helvetica / Helvetica-Bold fonts
// — public typographic data, embedded so paragraph + table-cell wrapping can
// measure text without a font file.
const List<int> _helveticaWidths = [
  278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, //
  278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, //
  584, 584, 584, 556, 1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, //
  500, 667, 556, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, //
  667, 667, 611, 278, 278, 278, 469, 556, 333, 556, 556, 500, 556, 556, //
  278, 556, 556, 222, 222, 500, 222, 833, 556, 556, 556, 556, 333, 500, //
  278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,
];

const List<int> _helveticaBoldWidths = [
  278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, //
  278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, //
  584, 584, 584, 611, 975, 722, 722, 722, 722, 667, 611, 778, 722, 278, //
  556, 722, 611, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, //
  667, 667, 611, 333, 278, 333, 584, 556, 333, 556, 611, 556, 611, 556, //
  333, 611, 611, 278, 278, 556, 278, 889, 611, 611, 611, 611, 389, 556, //
  333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584,
];

/// Width of [s] (already ASCII-sanitized) at [size] points.
double _textWidth(String s, double size, {bool bold = false}) {
  final table = bold ? _helveticaBoldWidths : _helveticaWidths;
  var units = 0;
  for (final c in s.codeUnits) {
    units += (c >= 0x20 && c <= 0x7e) ? table[c - 0x20] : 556;
  }
  return units * size / 1000.0;
}

// ── Text sanitation ──────────────────────────────────────────────────────────

/// Transliterate the handful of non-ASCII typographic characters the report
/// strings carry into printable ASCII (the base-14 fonts here are unencoded
/// beyond Latin-1 and the house rule is ASCII exports); anything else becomes
/// `?`. Typography only — no data is altered.
String _ascii(String raw) {
  final b = StringBuffer();
  for (final rune in raw.runes) {
    if (rune >= 0x20 && rune <= 0x7e) {
      b.writeCharCode(rune);
      continue;
    }
    switch (rune) {
      case 0x00B7: // ·
        b.write('.');
      case 0x2013: // –
      case 0x2014: // —
        b.write('-');
      case 0x26A0: // ⚠
        b.write('!');
      case 0x00D7: // ×
        b.write('x');
      case 0x00B2: // ²
        b.write('2');
      case 0x00B3: // ³
        b.write('3');
      case 0x00D8: // Ø
      case 0x00F8: // ø
        b.write('O');
      case 0x2248: // ≈
        b.write('~');
      case 0x00B0: // °
        b.write('deg');
      case 0x03A9: // Ω
        b.write('ohm');
      case 0x0394: // Δ
        b.write('d');
      case 0x2264: // ≤
        b.write('<=');
      case 0x2265: // ≥
        b.write('>=');
      case 0x2192: // →
        b.write('->');
      case 0x21D2: // ⇒
        b.write('=>');
      case 0x2018: // ‘
      case 0x2019: // ’
        b.write("'");
      case 0x201C: // “
      case 0x201D: // ”
        b.write('"');
      default:
        b.write('?');
    }
  }
  return b.toString();
}

/// Strip simple Markdown markers for typeset display: `**bold**` and
/// `` `code` `` markers are removed, a Markdown table-cell `\|` escape is
/// unescaped, the reports' `_( … )_` caveat wraps and a whole-string
/// `_emphasis_` wrap are unwrapped. Inner underscores (H_sys, NPSH_a…) are
/// identifiers and stay.
String _stripMd(String s) {
  var out = s
      .replaceAll('**', '')
      .replaceAll('`', '')
      .replaceAll(r'\|', '|')
      .replaceAll('_(', '(')
      .replaceAll(')_', ')');
  final t = out.trim();
  if (t.length > 1 && t.startsWith('_') && t.endsWith('_')) {
    out = t.substring(1, t.length - 1);
  }
  return out;
}

/// Escape a (sanitized) string for a PDF literal string.
String _esc(String s) =>
    s.replaceAll(r'\', r'\\').replaceAll('(', r'\(').replaceAll(')', r'\)');

String _n(double v) => v.toStringAsFixed(2);

/// Greedy word-wrap of [text] to [maxW] points at [size].
List<String> _wrap(String text, double size, double maxW, {bool bold = false}) {
  if (text.isEmpty) return const [''];
  final words = text.split(' ');
  final lines = <String>[];
  var line = '';
  void push(String w) {
    final candidate = line.isEmpty ? w : '$line $w';
    if (_textWidth(candidate, size, bold: bold) <= maxW || line.isEmpty) {
      line = candidate;
    } else {
      lines.add(line);
      line = w;
    }
  }

  for (var w in words) {
    // Hard-break a single word wider than the column.
    while (_textWidth(w, size, bold: bold) > maxW && w.length > 1) {
      var cut = w.length - 1;
      while (cut > 1 &&
          _textWidth(w.substring(0, cut), size, bold: bold) > maxW) {
        cut--;
      }
      push(w.substring(0, cut));
      lines.add(line);
      line = '';
      w = w.substring(cut);
    }
    push(w);
  }
  if (line.isNotEmpty) lines.add(line);
  return lines.isEmpty ? const [''] : lines;
}

// ── Ink ──────────────────────────────────────────────────────────────────────
const String _inkBody = '0.10 0.10 0.10';
const String _inkMuted = '0.42 0.42 0.42';
const String _inkRule = '0.55 0.55 0.55';
const String _inkHairline = '0.75 0.75 0.75';

// Role → stroke ink for embedded figures (mirrors electrical_pdf_export,
// incl. the R/S/T = red/amber/blue phase-column convention).
String _figStroke(SldRole r) => switch (r) {
      SldRole.normal => '0.12 0.12 0.12',
      SldRole.essential => '0.80 0.13 0.13',
      SldRole.source => '0.10 0.10 0.30',
      SldRole.phaseR => '0.79 0.16 0.16',
      SldRole.phaseS => '0.80 0.50 0.03',
      SldRole.phaseT => '0.10 0.44 0.76',
    };

double _figWeight(SldWeight w) => switch (w) {
      SldWeight.thin => 0.6,
      SldWeight.medium => 1.0,
      SldWeight.thick => 1.8,
    };

// ── The flowing typesetter ────────────────────────────────────────────────────

class _Typesetter {
  /// Content-page streams (the cover is assembled separately by the caller).
  final List<StringBuffer> pages = [];
  double _y = 0;

  _Typesetter() {
    _newPage();
  }

  StringBuffer get _cs => pages.last;

  void _newPage() {
    pages.add(StringBuffer());
    _y = _pageH - _margin;
  }

  /// Ensure [h] points of vertical space; start a new page when short.
  void _ensure(double h) {
    if (_y - h < _bottomLimit) _newPage();
  }

  void _text(double x, double baseline, String s,
      {double size = 9.5, bool bold = false, String color = _inkBody}) {
    if (s.isEmpty) return;
    _cs.writeln('BT /${bold ? 'F2' : 'F1'} ${_n(size)} Tf $color rg '
        '${_n(x)} ${_n(baseline)} Td (${_esc(s)}) Tj ET');
  }

  void _line(double x1, double y1, double x2, double y2,
      {double w = 0.5, String color = _inkRule}) {
    _cs.writeln(
        '$color RG ${_n(w)} w ${_n(x1)} ${_n(y1)} m ${_n(x2)} ${_n(y2)} l S');
  }

  /// Flow one wrapped text run at the cursor (full content width, optional
  /// left [indent]).
  void _flowText(String s,
      {double size = 9.5,
      double leading = 13.0,
      bool bold = false,
      String color = _inkBody,
      double indent = 0}) {
    final lines = _wrap(s, size, _contentW - indent, bold: bold);
    for (final l in lines) {
      _ensure(leading);
      _text(_margin + indent, _y - size, l, size: size, bold: bold, color: color);
      _y -= leading;
    }
  }

  void _gap(double h) {
    _y = math.max(_bottomLimit, _y - h);
  }

  // ── Blocks ─────────────────────────────────────────────────────────────────

  void heading(RptHeading h) {
    final size = switch (h.level) { 1 => 16.0, 2 => 13.0, _ => 11.0 };
    final before = switch (h.level) { 1 => 18.0, 2 => 14.0, _ => 10.0 };
    // Keep the heading + a couple of body lines together.
    _ensure(before + size + 32);
    _gap(before);
    _flowText(_ascii(_stripMd(h.text)),
        size: size, leading: size + 3, bold: true);
    if (h.level <= 2) {
      _line(_margin, _y - 1, _pageW - _margin, _y - 1,
          w: h.level == 1 ? 0.8 : 0.5, color: _inkHairline);
      _y -= 4;
    }
    _gap(4);
  }

  void paragraph(String text,
      {double size = 9.5, String color = _inkBody, double indent = 0}) {
    _flowText(_ascii(_stripMd(text)),
        size: size, leading: size + 3.5, color: color, indent: indent);
    _gap(4);
  }

  void note(RptNote nb) {
    _flowText(_ascii(_stripMd(nb.text)),
        size: 8.5, leading: 11.5, color: _inkMuted);
    _gap(4);
  }

  void keyValue(RptKeyValue kv) {
    const size = 9.5;
    const leading = 12.5;
    // Key column sized to the widest key (capped at 42 % of the content width).
    var keyW = 0.0;
    for (final (k, _) in kv.rows) {
      keyW = math.max(keyW, _textWidth(_ascii(_stripMd(k)), size));
    }
    keyW = math.min(keyW + 12, _contentW * 0.42);
    for (final (k, v) in kv.rows) {
      final key = _ascii(_stripMd(k));
      final value = _ascii(_stripMd(v));
      if (key.isEmpty) {
        // A plain bullet row — full width, dash-marked, hanging indent.
        final lines = _wrap(value, size, _contentW - 10);
        for (var i = 0; i < lines.length; i++) {
          _ensure(leading);
          if (i == 0) _text(_margin, _y - size, '-', size: size);
          _text(_margin + 10, _y - size, lines[i], size: size);
          _y -= leading;
        }
        continue;
      }
      final keyLines = _wrap(key, size, keyW - 6);
      final valLines = _wrap(value, size, _contentW - keyW);
      final rowLines = math.max(keyLines.length, valLines.length);
      _ensure(rowLines * leading);
      for (var i = 0; i < rowLines; i++) {
        _ensure(leading);
        if (i < keyLines.length) {
          _text(_margin, _y - size, keyLines[i], size: size, color: _inkMuted);
        }
        if (i < valLines.length) {
          _text(_margin + keyW, _y - size, valLines[i], size: size);
        }
        _y -= leading;
      }
    }
    _gap(6);
  }

  void table(RptTable t) {
    if (t.headers.isEmpty) return;
    const fs = 8.5;
    const lead = 10.5;
    const padX = 4.0;
    const padY = 3.0;
    final cols = t.headers.length;

    // Column widths proportional to the widest content (header measured bold),
    // floored + capped, then scaled to fill the content width.
    final nat = List<double>.filled(cols, 0);
    final headCells = [for (final h in t.headers) _ascii(_stripMd(h))];
    for (var c = 0; c < cols; c++) {
      nat[c] = _textWidth(headCells[c], fs, bold: true);
    }
    final bodyCells = [
      for (final row in t.rows)
        [
          for (var c = 0; c < cols; c++)
            _ascii(_stripMd(c < row.length ? row[c] : '')),
        ],
    ];
    for (final row in bodyCells) {
      for (var c = 0; c < cols; c++) {
        nat[c] = math.max(nat[c], _textWidth(row[c], fs));
      }
    }
    for (var c = 0; c < cols; c++) {
      nat[c] = (nat[c] + 2 * padX).clamp(28.0, _contentW * 0.45);
    }
    final natTotal = nat.reduce((a, b) => a + b);
    final widths = [for (final w in nat) w * _contentW / natTotal];
    final xs = List<double>.filled(cols + 1, _margin);
    for (var c = 0; c < cols; c++) {
      xs[c + 1] = xs[c] + widths[c];
    }

    // Wrapped header lines (shared by every repeat of the band).
    final headWrapped = [
      for (var c = 0; c < cols; c++)
        _wrap(headCells[c], fs, widths[c] - 2 * padX, bold: true),
    ];
    final headLines =
        headWrapped.map((l) => l.length).reduce(math.max).toDouble();
    final headH = headLines * lead + 2 * padY;

    void drawHeaderBand() {
      final top = _y;
      // Light fill behind the header band.
      _cs.writeln('0.93 0.93 0.93 rg ${_n(_margin)} ${_n(top - headH)} '
          '${_n(_contentW)} ${_n(headH)} re f');
      for (var c = 0; c < cols; c++) {
        final lines = headWrapped[c];
        for (var i = 0; i < lines.length; i++) {
          _text(xs[c] + padX, top - padY - fs - i * lead, lines[i],
              size: fs, bold: true);
        }
      }
      _line(_margin, top, _pageW - _margin, top, w: 0.8);
      _line(_margin, top - headH, _pageW - _margin, top - headH, w: 0.8);
      for (var c = 0; c <= cols; c++) {
        _line(xs[c], top, xs[c], top - headH, w: 0.4, color: _inkHairline);
      }
      _y -= headH;
    }

    // Room for the header + at least one body row before starting.
    _ensure(headH + lead + 2 * padY + 4);
    drawHeaderBand();

    for (final row in bodyCells) {
      final wrapped = [
        for (var c = 0; c < cols; c++)
          _wrap(row[c], fs, widths[c] - 2 * padX),
      ];
      final rowLines = wrapped.map((l) => l.length).reduce(math.max);
      final rowH = rowLines * lead + 2 * padY;
      if (_y - rowH < _bottomLimit) {
        // Split: close nothing (the band bottom rule already drawn), repeat
        // the header on the fresh page.
        _newPage();
        drawHeaderBand();
      }
      final top = _y;
      for (var c = 0; c < cols; c++) {
        final lines = wrapped[c];
        for (var i = 0; i < lines.length; i++) {
          _text(xs[c] + padX, top - padY - fs - i * lead, lines[i], size: fs);
        }
      }
      // Row rule + this row's column verticals (per-row so the grid stays
      // closed across page splits).
      _line(_margin, top - rowH, _pageW - _margin, top - rowH,
          w: 0.4, color: _inkHairline);
      for (var c = 0; c <= cols; c++) {
        _line(xs[c], top, xs[c], top - rowH, w: 0.4, color: _inkHairline);
      }
      _y -= rowH;
    }
    // Heavier closing rule under the table.
    _line(_margin, _y, _pageW - _margin, _y, w: 0.8);
    _gap(8);
  }

  void figure(RptFigure f) {
    final sheet = f.sheet;
    final spanX = math.max(1e-6, sheet.maxX - sheet.minX);
    final spanY = math.max(1e-6, sheet.maxY - sheet.minY);
    final boxW = math.min(460.0, _contentW);
    const boxH = 300.0;
    var scale = math.min(boxW / spanX, boxH / spanY);
    if (!scale.isFinite || scale <= 0) scale = 1.0;
    scale = math.min(scale, 1.0); // never blow a small drawing up past 1:1
    final drawnW = spanX * scale;
    final drawnH = spanY * scale;
    const capH = 14.0;
    _ensure(drawnH + capH + 12);
    final offX = _margin + (_contentW - drawnW) / 2;
    final topY = _y - 4;
    double tx(double x) => offX + (x - sheet.minX) * scale;
    double ty(double y) => topY - (y - sheet.minY) * scale; // y-down → y-up

    for (final p in sheet.prims) {
      switch (p) {
        case SldLine():
          _cs.writeln('${_figStroke(p.role)} RG '
              '${_n(_figWeight(p.weight) * scale + 0.3)} w');
          if (p.dashed) _cs.writeln('[3 2] 0 d');
          _cs.writeln('${_n(tx(p.x1))} ${_n(ty(p.y1))} m '
              '${_n(tx(p.x2))} ${_n(ty(p.y2))} l S');
          if (p.dashed) _cs.writeln('[] 0 d');
        case SldRect():
          _cs.writeln('${_figStroke(p.role)} RG '
              '${_n(_figWeight(p.weight) * scale + 0.3)} w');
          _cs.writeln('${_n(tx(p.x))} ${_n(ty(p.y + p.h))} '
              '${_n(p.w * scale)} ${_n(p.h * scale)} re S');
        case SldLabel():
          final fsz = math.max(4.0, p.size * scale);
          _text(tx(p.x), ty(p.y), _ascii(p.text),
              size: fsz, bold: p.bold, color: _figStroke(p.role));
        case SldCircle():
          _cs.writeln('${_figStroke(p.role)} RG '
              '${_n(_figWeight(p.weight) * scale + 0.3)} w');
          final cx = tx(p.cx), cy = ty(p.cy), r = p.r * scale;
          const k = 0.5523;
          _cs.writeln('${_n(cx + r)} ${_n(cy)} m');
          _cs.writeln('${_n(cx + r)} ${_n(cy + r * k)} '
              '${_n(cx + r * k)} ${_n(cy + r)} ${_n(cx)} ${_n(cy + r)} c');
          _cs.writeln('${_n(cx - r * k)} ${_n(cy + r)} '
              '${_n(cx - r)} ${_n(cy + r * k)} ${_n(cx - r)} ${_n(cy)} c');
          _cs.writeln('${_n(cx - r)} ${_n(cy - r * k)} '
              '${_n(cx - r * k)} ${_n(cy - r)} ${_n(cx)} ${_n(cy - r)} c');
          _cs.writeln('${_n(cx + r * k)} ${_n(cy - r)} '
              '${_n(cx + r)} ${_n(cy - r * k)} ${_n(cx + r)} ${_n(cy)} c');
          _cs.writeln('S');
      }
    }
    _y = topY - drawnH - 10;
    // Caption, centred beneath the figure.
    final cap = _ascii(_stripMd(f.caption));
    if (cap.isNotEmpty) {
      final capW = _textWidth(cap, 8.5);
      _text(_margin + (_contentW - capW) / 2, _y - 8.5, cap,
          size: 8.5, color: _inkMuted);
      _y -= capH;
    }
    _gap(6);
  }

  void markdown(RptMarkdown m) {
    // Transitional: render line-by-line as marker-stripped paragraphs; blank
    // lines become small gaps.
    for (final line in m.raw.split('\n')) {
      if (line.trim().isEmpty) {
        _gap(4);
        continue;
      }
      final indent = line.startsWith('  ') ? 12.0 : 0.0;
      _flowText(_ascii(_stripMd(line.trim())),
          size: 9.5, leading: 13.0, indent: indent);
    }
  }

  void block(RptBlock b) {
    switch (b) {
      case RptHeading():
        heading(b);
      case RptParagraph():
        paragraph(b.text);
      case RptKeyValue():
        keyValue(b);
      case RptTable():
        table(b);
      case RptNote():
        note(b);
      case RptFigure():
        figure(b);
      case RptMarkdown():
        markdown(b);
    }
  }
}

// ── Cover page ────────────────────────────────────────────────────────────────

String _coverPage({
  required String docTitle,
  required String projectName,
  String? documentNumber,
  String? revisionTag,
  String? dateString,
  String? standardsLine,
  String? preparedBy,
  String? checkedBy,
  String? approvedBy,
}) {
  final cs = StringBuffer();
  void centred(double y, String raw,
      {double size = 12, bool bold = false, String color = _inkBody}) {
    final s = _ascii(_stripMd(raw));
    if (s.isEmpty) return;
    final w = _textWidth(s, size, bold: bold);
    cs.writeln('BT /${bold ? 'F2' : 'F1'} ${_n(size)} Tf $color rg '
        '${_n(_margin + (_contentW - w) / 2)} ${_n(y)} Td (${_esc(s)}) Tj ET');
  }

  // Head rule + title cluster.
  cs.writeln('$_inkRule RG 1.0 w ${_n(_margin)} ${_n(_pageH - 200)} m '
      '${_n(_pageW - _margin)} ${_n(_pageH - 200)} l S');
  centred(_pageH - 250, docTitle, size: 22, bold: true);
  centred(_pageH - 280, projectName, size: 14);
  cs.writeln('$_inkRule RG 1.0 w ${_n(_margin)} ${_n(_pageH - 305)} m '
      '${_n(_pageW - _margin)} ${_n(_pageH - 305)} l S');
  var y = _pageH - 340.0;
  if (standardsLine != null && standardsLine.isNotEmpty) {
    centred(y, standardsLine, size: 10, color: _inkMuted);
    y -= 16;
  }
  final docRev = [
    if (documentNumber != null && documentNumber.isNotEmpty) documentNumber,
    if (revisionTag != null && revisionTag.isNotEmpty) revisionTag,
  ].join(' - ');
  if (docRev.isNotEmpty) {
    centred(y, docRev, size: 10, color: _inkMuted);
    y -= 16;
  }
  if (dateString != null && dateString.isNotEmpty) {
    centred(y, dateString, size: 10, color: _inkMuted);
  }

  // Prepared / Checked / Approved — ONLY the roles actually supplied are
  // drawn (an empty approval box would read as an unsigned-but-expected
  // signature; absent data is omitted instead).
  final roles = <(String, String)>[
    if (preparedBy != null && preparedBy.isNotEmpty)
      ('Prepared by', preparedBy),
    if (checkedBy != null && checkedBy.isNotEmpty) ('Checked by', checkedBy),
    if (approvedBy != null && approvedBy.isNotEmpty)
      ('Approved by', approvedBy),
  ];
  if (roles.isNotEmpty) {
    const rowH = 22.0;
    const labelW = 110.0;
    const tableW = 320.0;
    const tableX = _margin + (_contentW - tableW) / 2;
    final tableTop = _margin + 90 + roles.length * rowH;
    cs.writeln('$_inkRule RG 0.8 w ${_n(tableX)} ${_n(tableTop - roles.length * rowH)} '
        '${_n(tableW)} ${_n(roles.length * rowH)} re S');
    cs.writeln('$_inkRule RG 0.5 w ${_n(tableX + labelW)} ${_n(tableTop)} m '
        '${_n(tableX + labelW)} ${_n(tableTop - roles.length * rowH)} l S');
    for (var i = 0; i < roles.length; i++) {
      final rowTop = tableTop - i * rowH;
      if (i > 0) {
        cs.writeln('$_inkRule RG 0.5 w ${_n(tableX)} ${_n(rowTop)} m '
            '${_n(tableX + tableW)} ${_n(rowTop)} l S');
      }
      final (label, name) = roles[i];
      cs.writeln('BT /F1 8 Tf $_inkMuted rg ${_n(tableX + 8)} '
          '${_n(rowTop - 15)} Td (${_esc(_ascii(label))}) Tj ET');
      cs.writeln('BT /F1 10 Tf $_inkBody rg ${_n(tableX + labelW + 8)} '
          '${_n(rowTop - 15)} Td (${_esc(_ascii(name))}) Tj ET');
    }
  }
  return cs.toString();
}

// ── PDF assembly (byte-accurate xref; two base-14 fonts) ─────────────────────

Uint8List _assemblePdf(List<String> pageContents) {
  final n = pageContents.length;
  final f1Obj = 3 + 2 * n;
  final f2Obj = 4 + 2 * n;
  final kids = [for (var i = 0; i < n; i++) '${3 + 2 * i} 0 R'].join(' ');
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [$kids] /Count $n >>',
    for (var i = 0; i < n; i++) ...[
      '<< /Type /Page /Parent 2 0 R '
          '/MediaBox [0 0 ${_n(_pageW)} ${_n(_pageH)}] '
          '/Resources << /Font << /F1 $f1Obj 0 R /F2 $f2Obj 0 R >> >> '
          '/Contents ${4 + 2 * i} 0 R >>',
      '<< /Length ${latin1.encode(pageContents[i]).length} >>\n'
          'stream\n${pageContents[i]}\nendstream',
    ],
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>',
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

/// Typeset [blocks] into a submittable A4-portrait PDF report.
///
/// Page 1 is a cover (title, project, standards line, date, document number /
/// revision, and a Prepared/Checked/Approved table drawn ONLY for the roles
/// supplied). Every following content page carries a running footer
/// `projectName - documentNumber - Page X of Y` (the document number is
/// skipped when null; X/Y count the content pages, stamped after layout so
/// the total is real).
Uint8List reportBlocksToPdf(
  List<RptBlock> blocks, {
  required String docTitle,
  required String projectName,
  String? documentNumber,
  String? revisionTag,
  String? dateString,
  String? standardsLine,
  String? preparedBy,
  String? checkedBy,
  String? approvedBy,
}) {
  // Lay the content out first — the footer needs the final page count.
  final ts = _Typesetter();
  for (final b in blocks) {
    ts.block(b);
  }

  final total = ts.pages.length;
  var footerBase = [
    _ascii(projectName),
    if (documentNumber != null && documentNumber.isNotEmpty)
      _ascii(documentNumber),
  ].join(' - ');
  // The footer is a single un-wrapped run — ellipsize the identity half so a
  // very long project name / doc number can never overflow the content column
  // (the ' - Page X of Y' suffix stays intact; ~90pt reserves its width).
  const footerMaxW = _contentW - 90.0;
  if (_textWidth(footerBase, 8) > footerMaxW) {
    while (footerBase.isNotEmpty &&
        _textWidth('$footerBase...', 8) > footerMaxW) {
      footerBase = footerBase.substring(0, footerBase.length - 1);
    }
    footerBase = '$footerBase...';
  }
  final contentPages = <String>[];
  for (var i = 0; i < total; i++) {
    final cs = ts.pages[i];
    // Running footer: hairline + `project - doc no - Page X of Y`.
    cs.writeln('$_inkHairline RG 0.5 w ${_n(_margin)} ${_n(_margin - 8)} m '
        '${_n(_pageW - _margin)} ${_n(_margin - 8)} l S');
    final footer = '$footerBase - Page ${i + 1} of $total';
    cs.writeln('BT /F1 8 Tf $_inkMuted rg ${_n(_margin)} ${_n(_margin - 20)} '
        'Td (${_esc(footer)}) Tj ET');
    contentPages.add(cs.toString());
  }

  final cover = _coverPage(
    docTitle: docTitle,
    projectName: projectName,
    documentNumber: documentNumber,
    revisionTag: revisionTag,
    dateString: dateString,
    standardsLine: standardsLine,
    preparedBy: preparedBy,
    checkedBy: checkedBy,
    approvedBy: approvedBy,
  );

  return _assemblePdf([cover, ...contentPages]);
}
