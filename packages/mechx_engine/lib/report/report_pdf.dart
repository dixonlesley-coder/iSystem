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

import 'drawing_chrome.dart' show winAnsiByte;
import 'report_blocks.dart';
import 'report_strings.dart';
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

// Round 23 (report-pdf-glyph-transliteration) — AFM widths of the WinAnsi
// upper half (0x80-0xFF) for Helvetica / Helvetica-Bold, so the real ·, Ø,
// ², °, ±, ×, µ, §, fractions, dashes and curly quotes measure correctly.
// 0 = an unassigned WinAnsi slot (never produced).
const List<int> _helveticaHigh = [
  556, 0, 222, 556, 333, 1000, 556, 556, 333, 1000, 667, 333, 1000, 0, 611, 0,
  0, 222, 222, 333, 333, 350, 556, 1000, 333, 1000, 500, 333, 944, 0, 500, 667,
  278, 333, 556, 556, 556, 556, 260, 556, 333, 737, 370, 556, 584, 333, 737, 333,
  400, 584, 333, 333, 333, 556, 537, 278, 333, 333, 365, 556, 834, 834, 834, 611,
  667, 667, 667, 667, 667, 667, 1000, 722, 667, 667, 667, 667, 278, 278, 278, 278,
  722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722, 722, 722, 667, 667, 611,
  556, 556, 556, 556, 556, 556, 889, 500, 556, 556, 556, 556, 278, 278, 278, 278,
  556, 556, 556, 556, 556, 556, 556, 584, 611, 556, 556, 556, 556, 500, 556, 500,
];

const List<int> _helveticaBoldHigh = [
  556, 0, 278, 556, 500, 1000, 556, 556, 333, 1000, 667, 333, 1000, 0, 611, 0,
  0, 278, 278, 500, 500, 350, 556, 1000, 333, 1000, 556, 333, 944, 0, 500, 667,
  278, 333, 556, 556, 556, 556, 280, 556, 333, 737, 370, 556, 584, 333, 737, 333,
  400, 584, 333, 333, 333, 611, 556, 278, 333, 333, 365, 556, 834, 834, 834, 611,
  722, 722, 722, 722, 722, 722, 1000, 722, 667, 667, 667, 667, 278, 278, 278, 278,
  722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722, 722, 722, 667, 667, 611,
  556, 556, 556, 556, 556, 556, 889, 556, 556, 556, 556, 556, 278, 278, 278, 278,
  611, 611, 611, 611, 611, 611, 611, 584, 611, 611, 611, 611, 611, 556, 611, 556,
];

/// Width of [s] (already WinAnsi-sanitized: one char per WinAnsi byte) at
/// [size] points.
double _textWidth(String s, double size, {bool bold = false}) {
  final table = bold ? _helveticaBoldWidths : _helveticaWidths;
  final high = bold ? _helveticaBoldHigh : _helveticaHigh;
  var units = 0;
  for (final c in s.codeUnits) {
    if (c >= 0x20 && c <= 0x7e) {
      units += table[c - 0x20];
    } else if (c >= 0x80 && c <= 0xff && high[c - 0x80] > 0) {
      units += high[c - 0x80];
    } else {
      units += 556;
    }
  }
  return units * size / 1000.0;
}

// ── Text sanitation ──────────────────────────────────────────────────────────

/// Public view of the report-PDF transliteration (Round 9), so a test can pin
/// that every character the engine's strings carry reaches the PDF legibly.
String pdfSafeText(String raw) => _ascii(raw);

/// Map report text onto the fonts' WinAnsiEncoding: every character WinAnsi
/// carries (printable ASCII, the Latin-1 block — ·, Ø, ², °, ±, ×, µ, §,
/// fractions — and the cp1252 dashes / curly quotes / bullet / ellipsis) is
/// written as its own WinAnsi byte (one char per output byte), so the issued
/// report prints the same `Ø250` / `k·Q²` the Wave-7 drawing PDFs do (Round
/// 23, report-pdf-glyph-transliteration — it used to print `O250`, `k.Q2`).
/// Only a character OUTSIDE WinAnsi (Greek, ≤, →, √ …) is transliterated to
/// ASCII; anything else becomes `?`. Typography only — no data is altered.
///
/// Round 9 (report-parity-pdf-citation-garbled) — the clause sign `§`, Greek
/// symbols (ρ, ε, φ, µ…), `±`, vulgar fractions, `″` and `…` used to fall to
/// `?`, so the guardrail-6 'Unverified values' section printed 'IEC 60364-4-44
/// ?443 / PUIL 2011 ?3.20' and '±5 %' as '?5 %' (a changed number).
String _ascii(String raw) {
  final b = StringBuffer();
  for (final rune in raw.runes) {
    final win = winAnsiByte(rune);
    if (win != null) {
      b.writeCharCode(win);
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
      case 0x00A7: // §
        b.write('cl.');
      case 0x00B1: // ±
        b.write('+/-');
      case 0x00BD: // ½
        b.write('1/2');
      case 0x00BC: // ¼
        b.write('1/4');
      case 0x00BE: // ¾
        b.write('3/4');
      case 0x215B: // ⅛
        b.write('1/8');
      case 0x2033: // ″
        b.write('in');
      case 0x2032: // ′
        b.write("'");
      case 0x2026: // …
        b.write('...');
      case 0x03C1: // ρ
        b.write('rho');
      case 0x03B5: // ε
        b.write('eps');
      case 0x03C6: // φ
      case 0x03A6: // Φ
        b.write('ph');
      case 0x00B5: // µ (micro)
      case 0x03BC: // μ
        b.write('u');
      case 0x03BD: // ν
        b.write('nu');
      case 0x03B7: // η
        b.write('eta');
      case 0x03B1: // α
        b.write('alpha');
      case 0x03B8: // θ
        b.write('theta');
      case 0x03BB: // λ
        b.write('lambda');
      case 0x221A: // √
        b.write('sqrt');
      case 0x221D: // ∝
        b.write('prop. to');
      case 0x2211: // ∑
      case 0x03A3: // Σ
        b.write('sum');
      case 0x2260: // ≠
        b.write('!=');
      case 0x2212: // − (minus)
        b.write('-');
      case 0x2022: // •
        b.write('*');
      case 0x00A0: // no-break space
        b.write(' ');
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
  // Round 20 (drafting-visual-4-5) — a leading `_TAG_:` emphasis (the
  // reports' `_WARN_:` / `_INFO_:` severity + interlock-kind markers) is
  // unwrapped to `TAG:`; it used to survive verbatim into the PDF.
  out = out.replaceFirstMapped(
      RegExp(r'^(\s*)_([^_\s][^_]*)_:'), (m) => '${m[1]}${m[2]}:');
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
  // A width that equals the column to the last bit (a column sized exactly to
  // its widest word, Round 23) must not hard-break on float noise.
  maxW += 1e-6;
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

/// Smallest printed size (pt) an embedded figure's labels may reach before
/// the typesetter slices the figure across pages instead of shrinking it
/// further (Round 23, report-pdf-figure-illegible).
const double kMinFigureLabelPt = 5.0;

// ── Table column allocation ─────────────────────────────────────────────────

/// Round 23 (report-pdf-table-midword-breaks) — bind a number to the unit
/// that follows it with a no-break space (WinAnsi 0xA0, which [_wrap] never
/// splits on), so a cell wraps as `12.7 A` / `2.5 mm2`, never `12.7` / `A`.
String _bindUnits(String cell) => cell.replaceAllMapped(
    RegExp(r'(\d) (mA|A|kA|mm2|mm|m|kW|W|kVA|kvar|V|kPa|Pa|L/s|m/s|m3|Hz|%)'
        r'(?![A-Za-z0-9])'),
    (m) => '${m[1]}\u00A0${m[2]}');

/// The widest single unbreakable word of [s] (split on plain spaces only).
double _widestWord(String s, double size, {bool bold = false}) {
  var w = 0.0;
  for (final word in s.split(' ')) {
    w = math.max(w, _textWidth(word, size, bold: bold));
  }
  return w;
}

/// Column widths for a ruled table filling [_contentW] (Round 23 two-pass
/// allocation). Each column's MINIMUM is its widest single word (header bold,
/// body regular) + padding, floored at 28 pt — so a unit, an enum word or a
/// header is never hard-broken while room exists. The natural width (widest
/// whole cell, capped at 45 % of the page) is honoured when everything fits;
/// otherwise only the columns ABOVE their minimum give space back, each in
/// proportion to its slack. Proportional scaling (the old rule) remains only
/// as the fallback when the minimums alone exceed the content width.
List<double> _tableColumnWidths(
    List<String> headCells, List<List<String>> bodyCells,
    {required double fs, required double padX}) {
  final cols = headCells.length;
  final minW = List<double>.filled(cols, 0);
  final nat = List<double>.filled(cols, 0);
  for (var c = 0; c < cols; c++) {
    minW[c] = _widestWord(headCells[c], fs, bold: true);
    nat[c] = _textWidth(headCells[c], fs, bold: true);
  }
  for (final row in bodyCells) {
    for (var c = 0; c < cols; c++) {
      minW[c] = math.max(minW[c], _widestWord(row[c], fs));
      nat[c] = math.max(nat[c], _textWidth(row[c], fs));
    }
  }
  for (var c = 0; c < cols; c++) {
    minW[c] = math.max(28.0, minW[c] + 2 * padX);
    nat[c] = math.max(minW[c], math.min(nat[c] + 2 * padX, _contentW * 0.45));
  }
  final minTotal = minW.reduce((a, b) => a + b);
  if (minTotal >= _contentW) {
    return [for (final w in minW) w * _contentW / minTotal];
  }
  final natTotal = nat.reduce((a, b) => a + b);
  if (natTotal <= _contentW) {
    return [for (final w in nat) w * _contentW / natTotal];
  }
  final slack = natTotal - minTotal; // > 0 here
  final excess = natTotal - _contentW;
  return [
    for (var c = 0; c < cols; c++)
      nat[c] - (nat[c] - minW[c]) * excess / slack,
  ];
}

/// Public view of the table column allocation (tests pin the no-mid-word
/// property against the engine's own AFM widths).
List<double> reportTableColumnWidths(
        List<String> headers, List<List<String>> rows,
        {double fs = 8.5, double padX = 4.0}) =>
    _tableColumnWidths([
      for (final h in headers) _bindUnits(_ascii(_stripMd(h))),
    ], [
      for (final r in rows)
        [
          for (var c = 0; c < headers.length; c++)
            _bindUnits(_ascii(_stripMd(c < r.length ? r[c] : ''))),
        ],
    ], fs: fs, padX: padX);

/// The AFM width of [s] after report sanitation (test hook).
double reportTextWidth(String s, double size, {bool bold = false}) =>
    _textWidth(_bindUnits(_ascii(_stripMd(s))), size, bold: bold);

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

  /// The block that follows the one being typeset (set by the driver), so a
  /// heading can keep with the start of its body.
  RptBlock? next;

  /// Full flowed height of a fresh content page.
  static const double _pageFlowH = _pageH - _margin - _bottomLimit;

  /// Round 23 (report-pdf-orphan-headings) — the minimum height [b] needs to
  /// START on the current page (a table's header band + first row, a figure's
  /// first chunk + caption, two lines of a paragraph …): what the block's own
  /// `_ensure` asks for, so a heading reserving this can never be stranded at
  /// the page foot while its body jumps to the next page.
  double _minStartHeight(RptBlock? b) {
    switch (b) {
      case null:
        return 0;
      case RptTable():
        if (b.headers.isEmpty) return 0;
        const fs = 8.5, lead = 10.5, padX = 4.0, padY = 3.0;
        final cols = b.headers.length;
        final head = [
          for (final h in b.headers) _bindUnits(_ascii(_stripMd(h))),
        ];
        final body = [
          for (final row in b.rows)
            [
              for (var c = 0; c < cols; c++)
                _bindUnits(_ascii(_stripMd(c < row.length ? row[c] : ''))),
            ],
        ];
        final widths = _tableColumnWidths(head, body, fs: fs, padX: padX);
        var headLines = 1;
        for (var c = 0; c < cols; c++) {
          headLines = math.max(headLines,
              _wrap(head[c], fs, widths[c] - 2 * padX, bold: true).length);
        }
        var rowLines = 1;
        if (body.isNotEmpty) {
          for (var c = 0; c < cols; c++) {
            rowLines = math.max(rowLines,
                _wrap(body.first[c], fs, widths[c] - 2 * padX).length);
          }
        }
        return headLines * lead + 2 * padY + rowLines * lead + 2 * padY + 4;
      case RptFigure():
        final plan = _planFigure(b.sheet);
        return math.min(plan.firstChunkH, 120.0) + 14 + 16;
      case RptParagraph():
        return math.min(2, _wrap(b.text, 9.5, _contentW).length) * 13.0;
      case RptNote():
        return math.min(2, _wrap(b.text, 8.5, _contentW).length) * 11.5;
      case RptKeyValue():
        return math.min(2, b.rows.length) * 12.5;
      case RptMarkdown():
        return 26;
      case RptHeading():
        return 40;
    }
  }

  void heading(RptHeading h) {
    final size = switch (h.level) { 1 => 16.0, 2 => 13.0, _ => 11.0 };
    final before = switch (h.level) { 1 => 18.0, 2 => 14.0, _ => 10.0 };
    // Keep the heading with the START of the block that follows it (Round
    // 23): its own gap + wrapped lines + rule + gap, plus the next block's
    // minimum start height — capped at one page so a page-filling body still
    // takes its heading with it onto the fresh page.
    final lines =
        _wrap(_ascii(_stripMd(h.text)), size, _contentW, bold: true).length;
    final own = before + lines * (size + 3) + (h.level <= 2 ? 5 : 0) + 4;
    _ensure(math.min(_pageFlowH, own + math.max(13.0, _minStartHeight(next))));
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

    final headCells = [
      for (final h in t.headers) _bindUnits(_ascii(_stripMd(h))),
    ];
    final bodyCells = [
      for (final row in t.rows)
        [
          for (var c = 0; c < cols; c++)
            _bindUnits(_ascii(_stripMd(c < row.length ? row[c] : ''))),
        ],
    ];
    final widths = _tableColumnWidths(headCells, bodyCells, fs: fs, padX: padX);
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

  /// Round 23 (report-pdf-figure-illegible) — how a figure is set: at the
  /// width-limited scale (never above 1:1) when it fits a fresh page; else
  /// shrunk to one page when its smallest label still prints at
  /// [kMinFigureLabelPt]; else TILED across pages (top-down slices, and
  /// side-by-side columns when the sheet is also too wide) at the scale that
  /// keeps that label legible. It used to be squeezed into a fixed 460 × 300 pt box
  /// with 4 pt labels clamped against geometry scaled to 0.11 — every row of
  /// a multi-board schedule overprinted its neighbours.
  ({double scale, bool sliced, double firstChunkH}) _planFigure(
      SldSheet sheet) {
    final spanX = math.max(1e-6, sheet.maxX - sheet.minX);
    final spanY = math.max(1e-6, sheet.maxY - sheet.minY);
    const fullH = _pageFlowH - 4 - 10 - 14; // fresh page minus caption room
    var s = math.min(1.0, _contentW / spanX);
    if (!s.isFinite || s <= 0) s = 1.0;
    if (spanY * s <= fullH) {
      return (scale: s, sliced: false, firstChunkH: spanY * s);
    }
    double? minLabel;
    for (final p in sheet.prims) {
      if (p is SldLabel && p.size > 0) {
        minLabel = minLabel == null ? p.size : math.min(minLabel, p.size);
      }
    }
    final s1 = math.min(s, fullH / spanY);
    if (minLabel == null || minLabel * s1 >= kMinFigureLabelPt) {
      return (scale: s1, sliced: false, firstChunkH: spanY * s1);
    }
    // The legible scale — never above 1:1; a sheet wider than the column at
    // this scale is tiled into side-by-side column strips as well.
    final sl = math.min(1.0, kMinFigureLabelPt / minLabel);
    return (scale: sl, sliced: true, firstChunkH: fullH);
  }

  void _drawFigurePrims(SldSheet sheet, double scale, double offX, double topY,
      double y0, double y1, {double? x0}) {
    final originX = x0 ?? sheet.minX;
    double tx(double x) => offX + (x - originX) * scale;
    double ty(double y) => topY - (y - y0) * scale; // y-down → y-up
    bool inBand(double a, double b) =>
        math.max(a, b) >= y0 - 1e-6 && math.min(a, b) <= y1 + 1e-6;
    for (final p in sheet.prims) {
      switch (p) {
        case SldLine():
          if (!inBand(p.y1, p.y2)) continue;
          _cs.writeln('${_figStroke(p.role)} RG '
              '${_n(_figWeight(p.weight) * scale + 0.3)} w');
          if (p.dashed) _cs.writeln('[3 2] 0 d');
          _cs.writeln('${_n(tx(p.x1))} ${_n(ty(p.y1))} m '
              '${_n(tx(p.x2))} ${_n(ty(p.y2))} l S');
          if (p.dashed) _cs.writeln('[] 0 d');
        case SldRect():
          if (!inBand(p.y, p.y + p.h)) continue;
          _cs.writeln('${_figStroke(p.role)} RG '
              '${_n(_figWeight(p.weight) * scale + 0.3)} w');
          _cs.writeln('${_n(tx(p.x))} ${_n(ty(p.y + p.h))} '
              '${_n(p.w * scale)} ${_n(p.h * scale)} re S');
        case SldLabel():
          if (!inBand(p.y - p.size, p.y)) continue;
          final fsz = math.max(4.0, p.size * scale);
          _text(tx(p.x), ty(p.y), _ascii(p.text),
              size: fsz, bold: p.bold, color: _figStroke(p.role));
        case SldCircle():
          if (!inBand(p.cy - p.r, p.cy + p.r)) continue;
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
  }

  void figure(RptFigure f) {
    final sheet = f.sheet;
    final plan = _planFigure(sheet);
    final scale = plan.scale;
    final spanX = math.max(1e-6, sheet.maxX - sheet.minX);
    final spanY = math.max(1e-6, sheet.maxY - sheet.minY);
    final drawnW = spanX * scale;
    final offX = _margin + (_contentW - drawnW) / 2;
    const capH = 14.0;
    if (!plan.sliced) {
      final drawnH = spanY * scale;
      _ensure(drawnH + capH + 16);
      final topY = _y - 4;
      _drawFigurePrims(sheet, scale, offX, topY, sheet.minY, sheet.maxY);
      _y = topY - drawnH - 10;
    } else {
      // Tile: column strips left to right (one when the sheet fits the column
      // width), each sliced top-down — every page takes as much as fits,
      // clipped to its tile (a label straddling a cut prints on both tiles).
      final colSpan = _contentW / scale; // sheet units per column strip
      final cols = math.max(1, (spanX / colSpan - 1e-9).ceil());
      if (_y - 4 - _bottomLimit < 120) _newPage();
      for (var c = 0; c < cols; c++) {
        final x0 = sheet.minX + c * colSpan;
        final x1 = math.min(sheet.maxX, x0 + colSpan);
        final tileW = (x1 - x0) * scale;
        final tileOffX = cols == 1 ? offX : _margin;
        var y0 = sheet.minY;
        while (y0 < sheet.maxY - 1e-6) {
          final availPt = _y - 4 - _bottomLimit - 2;
          final y1 = math.min(sheet.maxY, y0 + availPt / scale);
          final topY = _y - 4;
          final bandH = (y1 - y0) * scale;
          _cs.writeln('q ${_n(tileOffX - 1)} ${_n(topY - bandH - 1)} '
              '${_n(tileW + 2)} ${_n(bandH + 2)} re W n');
          _drawFigurePrims(sheet, scale, tileOffX, topY, y0, y1, x0: x0);
          _cs.writeln('Q');
          _y = topY - bandH - 2;
          y0 = y1;
          if (y0 < sheet.maxY - 1e-6 || c + 1 < cols) _newPage();
        }
      }
      _y -= 8;
    }
    // Caption, centred beneath the figure.
    final cap = _ascii(_stripMd(f.caption));
    if (cap.isNotEmpty) {
      _ensure(capH);
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
      // Round 23 (report-pdf-literal-md-rule) — a Markdown thematic break
      // (`---`, `***`, `___`) is a hairline rule, never literal text.
      if (RegExp(r'^\s*(-{3,}|\*{3,}|_{3,})\s*$').hasMatch(line)) {
        _ensure(10);
        _gap(3);
        _line(_margin, _y, _pageW - _margin, _y, w: 0.5, color: _inkHairline);
        _gap(6);
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
  ReportStrings strings = const ReportStrings.en(),
}) {
  final cs = StringBuffer();
  // Round 23 (report-pdf-cover-standards-overflow) — every cover run is
  // WRAPPED to the content width and each line centred, returning the
  // baseline of the next line: a long standards provenance line / title /
  // project name used to be set on one line at a negative x and clipped on
  // both page edges.
  double centred(double y, String raw,
      {double size = 12, bool bold = false, String color = _inkBody}) {
    final s = _ascii(_stripMd(raw));
    if (s.isEmpty) return y;
    for (final line in _wrap(s, size, _contentW, bold: bold)) {
      final w = _textWidth(line, size, bold: bold);
      cs.writeln('BT /${bold ? 'F2' : 'F1'} ${_n(size)} Tf $color rg '
          '${_n(_margin + (_contentW - w) / 2)} ${_n(y)} Td (${_esc(line)}) '
          'Tj ET');
      y -= size + 4;
    }
    return y;
  }

  // Head rule + title cluster.
  cs.writeln('$_inkRule RG 1.0 w ${_n(_margin)} ${_n(_pageH - 200)} m '
      '${_n(_pageW - _margin)} ${_n(_pageH - 200)} l S');
  var y = centred(_pageH - 250, docTitle, size: 22, bold: true);
  y = centred(math.min(_pageH - 280, y - 4), projectName, size: 14);
  final rule2 = math.min(_pageH - 305, y - 7);
  cs.writeln('$_inkRule RG 1.0 w ${_n(_margin)} ${_n(rule2)} m '
      '${_n(_pageW - _margin)} ${_n(rule2)} l S');
  y = rule2 - 35;
  if (standardsLine != null && standardsLine.isNotEmpty) {
    y = centred(y, standardsLine, size: 10, color: _inkMuted) - 2;
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
      (strings(RptStringKey.pdfPreparedBy), preparedBy),
    if (checkedBy != null && checkedBy.isNotEmpty)
      (strings(RptStringKey.pdfCheckedBy), checkedBy),
    if (approvedBy != null && approvedBy.isNotEmpty)
      (strings(RptStringKey.pdfApprovedBy), approvedBy),
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
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
        '/Encoding /WinAnsiEncoding >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold '
        '/Encoding /WinAnsiEncoding >>',
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
///
/// Round 9 — [strings] localizes the PDF CHROME (cover sign-off role labels
/// and the 'Page X of Y' footer → 'Halaman X dari Y'); the default English
/// keeps every existing byte.
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
  ReportStrings strings = const ReportStrings.en(),
}) {
  // Lay the content out first — the footer needs the final page count.
  final ts = _Typesetter();
  for (var i = 0; i < blocks.length; i++) {
    ts.next = i + 1 < blocks.length ? blocks[i + 1] : null;
    ts.block(blocks[i]);
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
  String pageOf(int x) =>
      _ascii(strings.format(RptStringKey.pdfPageOf, {'x': x, 'y': total}));
  final suffixW = _textWidth(' - ${pageOf(total)}', 8);
  final footerMaxW = _contentW - (suffixW > 90.0 ? suffixW : 90.0);
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
    final footer = '$footerBase - ${pageOf(i + 1)}';
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
    strings: strings,
  );

  return _assemblePdf([cover, ...contentPages]);
}
