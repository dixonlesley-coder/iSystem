/// Native PDF export of the electrical single-line — a self-contained vector
/// drawing deliverable with NO third-party dependency. The electrical mirror of
/// `pdf_export.dart` (`networkToPdf`). Pure: builds the PDF byte stream from the
/// sized system; the app handles file IO. Zero Flutter imports.
///
/// A3-landscape pages. The professional single-line CONTENT — every
/// panel as a distribution-board single-line (incomer breaker → busbar → one row
/// per outgoing way with breaker / cable / load / phase / Ib, feeders routed to
/// the sub-panel they supply) — is built once in `electrical_sld_drawing.dart`
/// and rendered here; the sheet FRAME (title block + device legend + the opt-in
/// `DrawingChrome` revision/client/scale rows) is stamped in page space so it
/// stays legible regardless of the drawing's auto-fit scale.
///
/// [electricalSldToPdf] is the single-page export — with a NULL/EMPTY chrome it
/// is byte-identical to before the N-page writer existed (a NON-empty chrome
/// now also carries the C3 title-block rows, e.g. a SCALE `NTS` row, that the
/// pre-wave writer never drew); [electricalSldToPdfPaginated] issues ONE PAGE
/// PER PANEL (root-first `result.order`, the `onlyPanelId` detail filter) with
/// a real per-page `Sheet i of t`; [electricalSldSheetsToPdf] renders any list
/// of prebuilt sheets as one multi-page document (the `sldSheetsToPdf` engine).
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../electrical/model.dart';
import '../electrical/panel_results.dart';
import 'drawing_chrome.dart';
import 'electrical_sld_drawing.dart';

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

double _weightPt(SldWeight w) => switch (w) {
      SldWeight.thin => 0.6,
      SldWeight.medium => 1.0,
      SldWeight.thick => 1.8,
    };

// Role → ink. `normal` keeps the existing dark scheme (so the detail sheet, all
// normal, is byte-identical); `essential` is red (emergency convention).
String _strokeRgForRole(SldRole r) => switch (r) {
      SldRole.normal => '0.12 0.12 0.12',
      SldRole.essential => '0.80 0.13 0.13',
      SldRole.source => '0.10 0.10 0.30',
    };

String _rectStrokeForRole(SldRole r) => switch (r) {
      SldRole.normal => '0.12 0.20 0.40',
      SldRole.essential => '0.80 0.13 0.13',
      SldRole.source => '0.10 0.10 0.30',
    };

String _textRgForRole(SldRole r) => switch (r) {
      SldRole.normal => '0 0 0',
      SldRole.essential => '0.70 0.10 0.10',
      SldRole.source => '0.10 0.10 0.30',
    };

// Page geometry shared by every sheet of the set.
const double _pageW = 1190.55; // A3 landscape, points (420 mm)
const double _pageH = 841.89; // 297 mm
const double _margin = 40.0;

/// The additional ISO-7200-style title-block rows a [DrawingChrome] carries —
/// CLIENT / SCALE / DATE / DRAWN / CHECKED / APPROVED — filtered to those
/// present. A single-line is schematic, so the SCALE row defaults to `NTS`
/// (not to scale) whenever the chrome is non-empty and no scale text is given;
/// null / empty chrome ⇒ no rows ⇒ the block stays byte-identical.
List<(String, String)> _chromeTitleRows(DrawingChrome? chrome) {
  if (chrome == null || chrome.isEmpty) return const [];
  bool has(String? s) => s != null && s.isNotEmpty;
  return [
    if (has(chrome.clientName)) ('CLIENT', chrome.clientName!),
    ('SCALE', has(chrome.scaleText) ? chrome.scaleText! : 'NTS'),
    if (has(chrome.dateString)) ('DATE', chrome.dateString!),
    if (has(chrome.drawnBy)) ('DRAWN', chrome.drawnBy!),
    if (has(chrome.checkedBy)) ('CHECKED', chrome.checkedBy!),
    if (has(chrome.approvedBy)) ('APPROVED', chrome.approvedBy!),
  ];
}

/// Build one page's content stream: the auto-fitted drawing + sheet border +
/// title block (+ the chrome's ruled rows) + device legend. [sheetIndexOverride]
/// / [sheetTotalOverride] force the per-page `Sheet i of t` counter (the
/// paginated exports); null falls back to the chrome's own counter.
String _sldPageContent({
  required SldSheet sheet,
  required String projectName,
  required String title,
  required String diagramTitle,
  DrawingChrome? chrome,
  int? sheetIndexOverride,
  int? sheetTotalOverride,
}) {
  // The chrome's extra ruled rows grow the reserved title strip; no rows ⇒ the
  // original 96 pt strip ⇒ byte-identical layout.
  final extraRows = _chromeTitleRows(chrome);
  const extraRowH = 13.0;
  final extraH = extraRows.length * extraRowH;
  final titleBlockH = // reserved strip across the page bottom
      extraRows.isEmpty ? 96.0 : 96.0 + 12.0 + extraH;

  // ── Auto-fit the drawing into the area above the title block ────────────────
  final spanX = math.max(1e-6, sheet.maxX - sheet.minX);
  final spanY = math.max(1e-6, sheet.maxY - sheet.minY);
  const availW = _pageW - 2 * _margin;
  final availH = _pageH - 2 * _margin - titleBlockH;
  var scale = math.min(availW / spanX, availH / spanY);
  if (!scale.isFinite || scale <= 0) scale = 1.0;
  scale = math.min(scale, 1.0); // never blow a tiny drawing up past 1:1
  final drawnW = spanX * scale;
  final drawnH = spanY * scale;
  final offX = _margin + (availW - drawnW) / 2;
  // Top of the drawing area (PDF y-up): just under the top margin.
  final topY = _pageH - _margin - (availH - drawnH) / 2;
  double tx(double x) => offX + (x - sheet.minX) * scale;
  double ty(double y) => topY - (y - sheet.minY) * scale; // flip y-down→y-up

  final cs = StringBuffer();

  // ── Sheet border ───────────────────────────────────────────────────────────
  cs.writeln('0.20 0.20 0.20 RG 1.0 w');
  cs.writeln('${_n(_margin)} ${_n(_margin)} '
      '${_n(_pageW - 2 * _margin)} ${_n(_pageH - 2 * _margin)} re S');

  // ── Drawing content (panels / busbars / ways / feeders) ─────────────────────
  for (final p in sheet.prims) {
    switch (p) {
      case SldLine():
        cs.writeln('${_strokeRgForRole(p.role)} RG '
            '${_n(_weightPt(p.weight) * scale + 0.3)} w');
        // A dashed prim strokes inside a dash pattern, reset straight after so
        // the following prims stay solid. Default solid ⇒ byte-identical.
        if (p.dashed) cs.writeln('[4 3] 0 d');
        cs.writeln('${_n(tx(p.x1))} ${_n(ty(p.y1))} m '
            '${_n(tx(p.x2))} ${_n(ty(p.y2))} l S');
        if (p.dashed) cs.writeln('[] 0 d');
      case SldRect():
        cs.writeln('${_rectStrokeForRole(p.role)} RG '
            '${_n(_weightPt(p.weight) * scale + 0.3)} w');
        // PDF rect origin is the lower-left; flip the y-down top-left.
        cs.writeln('${_n(tx(p.x))} ${_n(ty(p.y + p.h))} '
            '${_n(p.w * scale)} ${_n(p.h * scale)} re S');
      case SldLabel():
        final fs = math.max(5.0, p.size * scale);
        cs.writeln('BT /F1 ${_n(fs)} Tf ${_textRgForRole(p.role)} rg '
            '${_n(tx(p.x))} ${_n(ty(p.y))} Td (${_pdfText(p.text)}) Tj ET');
      case SldCircle():
        // A stroked circle approximated by 4 cubic beziers (kappa ~= 0.5523).
        cs.writeln('${_strokeRgForRole(p.role)} RG '
            '${_n(_weightPt(p.weight) * scale + 0.3)} w');
        final cx = tx(p.cx), cy = ty(p.cy), r = p.r * scale;
        const k = 0.5523;
        cs.writeln('${_n(cx + r)} ${_n(cy)} m');
        cs.writeln('${_n(cx + r)} ${_n(cy + r * k)} '
            '${_n(cx + r * k)} ${_n(cy + r)} ${_n(cx)} ${_n(cy + r)} c');
        cs.writeln('${_n(cx - r * k)} ${_n(cy + r)} '
            '${_n(cx - r)} ${_n(cy + r * k)} ${_n(cx - r)} ${_n(cy)} c');
        cs.writeln('${_n(cx - r)} ${_n(cy - r * k)} '
            '${_n(cx - r * k)} ${_n(cy - r)} ${_n(cx)} ${_n(cy - r)} c');
        cs.writeln('${_n(cx + r * k)} ${_n(cy - r)} '
            '${_n(cx + r)} ${_n(cy - r * k)} ${_n(cx + r)} ${_n(cy)} c');
        cs.writeln('S');
    }
  }

  // ── Title block (bottom-right) ──────────────────────────────────────────────
  final tbW = math.min(360.0, _pageW - 2 * _margin);
  final tbX = _pageW - _margin - tbW;
  const tbY = _margin;
  cs.writeln('0.20 0.20 0.20 RG 1.0 w');
  cs.writeln('${_n(tbX)} ${_n(tbY)} ${_n(tbW)} ${_n(titleBlockH)} re S');
  // internal divider under the title
  cs.writeln('${_n(tbX)} ${_n(tbY + titleBlockH - 28)} m '
      '${_n(tbX + tbW)} ${_n(tbY + titleBlockH - 28)} l S');
  cs.writeln('BT /F1 13 Tf 0 0 0 rg '
      '${_n(tbX + 8)} ${_n(tbY + titleBlockH - 20)} Td (${_pdfText(projectName)}) Tj ET');
  cs.writeln('BT /F1 11 Tf 0.15 0.15 0.15 rg '
      '${_n(tbX + 8)} ${_n(tbY + titleBlockH - 46)} Td '
      '(${_pdfText(diagramTitle)}) Tj ET');
  cs.writeln('BT /F1 8 Tf 0.30 0.30 0.30 rg '
      '${_n(tbX + 8)} ${_n(tbY + titleBlockH - 62)} Td '
      '(${_pdfText(title)}) Tj ET');
  cs.writeln('BT /F1 8 Tf 0.30 0.30 0.30 rg '
      '${_n(tbX + 8)} ${_n(tbY + titleBlockH - 76)} Td '
      '(${_pdfText(sheet.supplyNote)}) Tj ET');
  if (chrome != null) {
    // Drawing number + revision (left of the sheet counter) — title-block facts.
    final dwg = <String>[
      if (chrome.drawingNumber != null && chrome.drawingNumber!.isNotEmpty)
        chrome.drawingNumber!,
      if (chrome.revisionNumber != null && chrome.revisionNumber!.isNotEmpty)
        chrome.revisionNumber!,
    ].join('   ');
    if (dwg.isNotEmpty) {
      cs.writeln('BT /F1 9 Tf 0 0 0 rg '
          '${_n(tbX + 8)} ${_n(tbY + 22)} Td (${_pdfText(dwg)}) Tj ET');
    }
  }
  // Sheet counter: a paginated export forces its own per-page `i of t`;
  // otherwise the chrome's counter (unchanged) when set.
  String? counter;
  if (sheetIndexOverride != null || sheetTotalOverride != null) {
    final i = sheetIndexOverride ?? 1;
    final t = sheetTotalOverride ?? i;
    counter = 'Sheet $i of $t';
  } else if (chrome != null &&
      (chrome.sheetIndex != null || chrome.sheetTotal != null)) {
    final i = chrome.sheetIndex ?? 1;
    final t = chrome.sheetTotal ?? i;
    counter = 'Sheet $i of $t';
  }
  if (counter != null) {
    cs.writeln('BT /F1 8 Tf 0.30 0.30 0.30 rg '
        '${_n(tbX + 8)} ${_n(tbY + 8)} Td (${_pdfText(counter)}) Tj ET');
  }
  // The chrome's extra rows — CLIENT / SCALE / DATE / DRAWN / CHECKED /
  // APPROVED — as a hairline-ruled label|value band between the header and the
  // dwg-number/sheet lines, the `pdfTitleBlock` visual language. Rows absent ⇒
  // nothing emitted (and the block height above stayed 96) ⇒ byte-identical.
  if (extraRows.isNotEmpty) {
    const labelW = 52.0;
    const bandBot = tbY + 32.0;
    final bandTop = bandBot + extraH;
    cs.writeln('0.20 0.20 0.20 RG 0.5 w');
    cs.writeln('${_n(tbX)} ${_n(bandTop)} m ${_n(tbX + tbW)} ${_n(bandTop)} l S');
    cs.writeln('${_n(tbX)} ${_n(bandBot)} m ${_n(tbX + tbW)} ${_n(bandBot)} l S');
    cs.writeln('${_n(tbX + labelW)} ${_n(bandBot)} m '
        '${_n(tbX + labelW)} ${_n(bandTop)} l S');
    for (var i = 0; i < extraRows.length; i++) {
      final (label, value) = extraRows[i];
      final rowTop = bandTop - i * extraRowH;
      if (i > 0) {
        cs.writeln('${_n(tbX)} ${_n(rowTop)} m ${_n(tbX + tbW)} ${_n(rowTop)} l S');
      }
      final tyRow = rowTop - extraRowH + 3.5;
      cs.writeln('BT /F1 6 Tf 0.35 0.35 0.35 rg '
          '${_n(tbX + 6)} ${_n(tyRow)} Td (${_pdfText(label)}) Tj ET');
      cs.writeln('BT /F1 8 Tf 0 0 0 rg '
          '${_n(tbX + labelW + 6)} ${_n(tyRow)} Td (${_pdfText(value)}) Tj ET');
    }
  }

  // ── Device legend (KETERANGAN, bottom-left) ─────────────────────────────────
  if (sheet.legend.isNotEmpty) {
    const rowH = 11.0;
    final lh = 18.0 + sheet.legend.length * rowH;
    const lw = 240.0;
    const lx = _margin + 4;
    const ly = _margin + 2;
    cs.writeln('0.20 0.20 0.20 RG 0.8 w');
    cs.writeln('${_n(lx)} ${_n(ly)} ${_n(lw)} ${_n(lh)} re S');
    cs.writeln('BT /F1 9 Tf 0 0 0 rg '
        '${_n(lx + 6)} ${_n(ly + lh - 12)} Td (${_pdfText('LEGEND')}) Tj ET');
    var row = 0;
    for (final e in sheet.legend) {
      final ry = ly + lh - 24 - row * rowH;
      cs.writeln('BT /F1 7.5 Tf 0.12 0.12 0.12 rg '
          '${_n(lx + 6)} ${_n(ry)} Td '
          '(${_pdfText('${e.code}  -  ${e.meaning}')}) Tj ET');
      row++;
    }
  }

  // A single-line is schematic, not geographic — no north arrow / scale bar.
  // The DrawingChrome carries only title-block facts, stamped above.

  return cs.toString();
}

/// Assemble [pageContents] into a PDF with a byte-accurate cross-reference
/// table. Object layout: 1 = Catalog, 2 = Pages, then per page i (0-based)
/// object `3+2i` = Page and `4+2i` = its content stream, and the shared font
/// last (`3+2N`) — so a single page yields the exact 5-object document the
/// original single-page writer emitted (byte-identical).
Uint8List _assemblePdf(List<String> pageContents) {
  final n = pageContents.length;
  final fontObj = 3 + 2 * n;
  final kids = [for (var i = 0; i < n; i++) '${3 + 2 * i} 0 R'].join(' ');
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [$kids] /Count $n >>',
    for (var i = 0; i < n; i++) ...[
      '<< /Type /Page /Parent 2 0 R '
          '/MediaBox [0 0 ${_n(_pageW)} ${_n(_pageH)}] '
          '/Resources << /Font << /F1 $fontObj 0 R >> >> /Contents ${4 + 2 * i} 0 R >>',
      '<< /Length ${latin1.encode(pageContents[i]).length} >>\n'
          'stream\n${pageContents[i]}\nendstream',
    ],
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

String _projectName(ElectricalProject? project) =>
    (project?.name.isNotEmpty ?? false) ? project!.name : 'Untitled project';

/// Render the sized electrical single-line as a single-page PDF and return its
/// bytes. [title] is stamped in the title block.
///
/// Supply EITHER [project] + [result] (the exporter builds the sheet — a detail
/// single-line, or the [overview] / [sourceChain] variant) OR a prebuilt
/// [sheet] (e.g. a riser built by the app with the live `BuildingLevels`) —
/// keeping the [SldSheet] the single source of geometry.
Uint8List electricalSldToPdf({
  ElectricalProject? project,
  ElectricalSystemResult? result,
  SldSheet? sheet,
  String title = 'iSystem electrical single-line',
  String diagramTitle = 'ELECTRICAL SINGLE-LINE DIAGRAM',
  DrawingChrome? chrome,
  bool overview = false,
  bool sourceChain = false,
}) {
  assert(sheet != null || (project != null && result != null),
      'electricalSldToPdf needs either a prebuilt sheet or project+result');
  // A prebuilt [sheet] wins; else `overview` = the ZOOMED-OUT building
  // single-line (compact panel tree, optional source spine), default = the
  // per-panel detail single-line.
  final sheetResolved = sheet ??
      (overview
          ? buildElectricalOverview(
              project: project!, result: result!, sourceChain: sourceChain)
          : buildElectricalSld(project: project!, result: result!));
  return _assemblePdf([
    _sldPageContent(
      sheet: sheetResolved,
      projectName: _projectName(project),
      title: title,
      diagramTitle: diagramTitle,
      chrome: chrome,
    ),
  ]);
}

/// The PAGINATED single-line set — ONE PAGE PER PANEL (root-first
/// `result.order`, each page the `onlyPanelId` board-schedule detail), every
/// page carrying the shared title block with a real per-page `Sheet i of t`
/// counter (any counter on [chrome] is superseded page-by-page; its other
/// fields — drawing number, client, scale… — stamp every page). A project with
/// no panels degrades to the one-page full sheet, never throws.
Uint8List electricalSldToPdfPaginated({
  required ElectricalProject project,
  required ElectricalSystemResult result,
  String title = 'iSystem electrical single-line',
  String diagramTitle = 'ELECTRICAL SINGLE-LINE DIAGRAM',
  DrawingChrome? chrome,
  Map<String, double>? breakerIcuKaByPanelId,
}) {
  final ids = result.order;
  final pname = _projectName(project);
  if (ids.isEmpty) {
    return _assemblePdf([
      _sldPageContent(
        sheet: buildElectricalSld(
            project: project,
            result: result,
            breakerIcuKaByPanelId: breakerIcuKaByPanelId),
        projectName: pname,
        title: title,
        diagramTitle: diagramTitle,
        chrome: chrome,
        sheetIndexOverride: 1,
        sheetTotalOverride: 1,
      ),
    ]);
  }
  final pages = <String>[
    for (var i = 0; i < ids.length; i++)
      _sldPageContent(
        sheet: buildElectricalSld(
            project: project,
            result: result,
            onlyPanelId: ids[i],
            breakerIcuKaByPanelId: breakerIcuKaByPanelId),
        projectName: pname,
        title: title,
        diagramTitle: diagramTitle,
        chrome: chrome,
        sheetIndexOverride: i + 1,
        sheetTotalOverride: ids.length,
      ),
  ];
  return _assemblePdf(pages);
}

/// Render N prebuilt [sheets] as one N-page PDF over the same writer — the
/// engine behind the discipline-neutral `sldSheetsToPdf` (a mechanical riser
/// drawing SET: per-service + combined sheets). Page i stamps `Sheet i of N`;
/// [diagramTitles] (when given) supplies a per-page heading, else every page
/// carries [diagramTitle]. An empty list yields a valid one-page blank
/// document, never throws.
Uint8List electricalSldSheetsToPdf({
  required List<SldSheet> sheets,
  String title = 'iSystem single-line',
  String diagramTitle = 'SINGLE-LINE DIAGRAM',
  List<String>? diagramTitles,
  DrawingChrome? chrome,
  String projectName = 'Untitled project',
}) {
  if (sheets.isEmpty) {
    const blank = SldSheet(
      prims: [],
      minX: 0,
      minY: 0,
      maxX: 1,
      maxY: 1,
      legend: [],
      supplyNote: '',
    );
    return _assemblePdf([
      _sldPageContent(
        sheet: blank,
        projectName: projectName,
        title: title,
        diagramTitle: diagramTitle,
        chrome: chrome,
        sheetIndexOverride: 1,
        sheetTotalOverride: 1,
      ),
    ]);
  }
  final pages = <String>[
    for (var i = 0; i < sheets.length; i++)
      _sldPageContent(
        sheet: sheets[i],
        projectName: projectName,
        title: title,
        diagramTitle: (diagramTitles != null && i < diagramTitles.length)
            ? diagramTitles[i]
            : diagramTitle,
        chrome: chrome,
        sheetIndexOverride: i + 1,
        sheetTotalOverride: sheets.length,
      ),
  ];
  return _assemblePdf(pages);
}
