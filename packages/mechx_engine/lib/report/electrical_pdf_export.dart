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
/// now stamps the shared `pdfTitleBlock` tabular grid — the SAME title block the
/// plan exporters use, N20); [electricalSldToPdfPaginated] issues ONE PAGE
/// PER PANEL (root-first `result.order`, the `onlyPanelId` detail filter) with
/// a real per-page `Sheet i of t`; [electricalSldSheetsToPdf] renders any list
/// of prebuilt sheets as one multi-page document (the `sldSheetsToPdf` engine).
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../electrical/containment.dart' show ConduitSpec;
import '../electrical/model.dart';
import '../electrical/panel_results.dart';
import '../network/network.dart' show ServiceType;
import 'drawing_chrome.dart';
import 'electrical_sld_drawing.dart';
import 'plan_annotation_layout.dart' show planOverlapWarning;
import 'riser_tags.dart' show riserServiceCode;
import 'sld_plot_fit.dart';

/// One WinAnsi text rule for every vector PDF (Round 13): see
/// [pdfWinAnsiText] in `drawing_chrome.dart`.
String _pdfText(String raw) => pdfWinAnsiText(raw);

String _n(double v) => v.toStringAsFixed(2);

double _weightPt(SldWeight w) => switch (w) {
      SldWeight.thin => 0.6,
      SldWeight.medium => 1.0,
      SldWeight.thick => 1.8,
    };

// Role → ink. `normal` keeps the existing dark scheme (so the detail sheet, all
// normal, is byte-identical); `essential` is red (emergency convention). The
// phase roles carry the Indonesian R / S / T = red / yellow / blue schedule
// convention (the S yellow printed as a dark amber so it stays legible on
// paper) — the SAME hues the live canvas rails use, so screen and print agree.
const String _phaseRRg = '0.79 0.16 0.16'; // R — red    (canvas 0xC92A2A)
const String _phaseSRg = '0.80 0.50 0.03'; // S — amber  (canvas 0xE8990C)
const String _phaseTRg = '0.10 0.44 0.76'; // T — blue   (canvas 0x1971C2)

/// The service an [SldLine.layer] names when it is a riser SERVICE code (`CW`,
/// `D`, `V`…), or null. The mechanical riser and the master legend tag their
/// pipe lines this way; the DXF renderer already maps the same code to the
/// service's AIA layer and colour.
ServiceType? _serviceForLayer(String? layer) {
  if (layer == null) return null;
  for (final s in ServiceType.values) {
    if (riserServiceCode(s) == layer) return s;
  }
  return null;
}

/// Stroke colour for an [SldLine]: a NORMAL-role line on a riser service-code
/// layer prints in that service's plan colour (drafting-8), the SAME colour the
/// plan PDFs and the DXF layer use, so a legend swatch and the runs it keys
/// match. Every other line keeps its role colour.
String _strokeRgForLine(SldLine l) {
  final s = l.role == SldRole.normal ? _serviceForLayer(l.layer) : null;
  if (s == null) return _strokeRgForRole(l.role);
  final (r, g, b) = serviceChromeColor(s);
  return '${_n(r)} ${_n(g)} ${_n(b)}';
}

String _strokeRgForRole(SldRole r) => switch (r) {
      SldRole.normal => '0.12 0.12 0.12',
      SldRole.essential => '0.80 0.13 0.13',
      SldRole.source => '0.10 0.10 0.30',
      SldRole.phaseR => _phaseRRg,
      SldRole.phaseS => _phaseSRg,
      SldRole.phaseT => _phaseTRg,
    };

String _rectStrokeForRole(SldRole r) => switch (r) {
      SldRole.normal => '0.12 0.20 0.40',
      SldRole.essential => '0.80 0.13 0.13',
      SldRole.source => '0.10 0.10 0.30',
      SldRole.phaseR => _phaseRRg,
      SldRole.phaseS => _phaseSRg,
      SldRole.phaseT => _phaseTRg,
    };

String _textRgForRole(SldRole r) => switch (r) {
      SldRole.normal => '0 0 0',
      SldRole.essential => '0.70 0.10 0.10',
      SldRole.source => '0.10 0.10 0.30',
      SldRole.phaseR => _phaseRRg,
      SldRole.phaseS => _phaseSRg,
      SldRole.phaseT => _phaseTRg,
    };

// Page geometry shared by every sheet of the set.
const double _pageW = 1190.55; // A3 landscape, points (420 mm)
const double _pageH = 841.89; // 297 mm
const double _margin = 40.0;

/// Clear space (points) kept between the sheet frame and the auto-fitted
/// drawing on every side (drafting-9).
const double _drawInset = 12.0;

/// Build one page's content stream: the auto-fitted drawing + sheet border +
/// title block + device legend. WITH a non-empty [chrome] the title block is
/// the SAME shared `pdfTitleBlock` tabular grid the plan exporters stamp (N20 —
/// one title block across the whole issued set); WITHOUT chrome it is the legacy
/// header-style block (byte-identical). [sheetIndexOverride] /
/// [sheetTotalOverride] force the per-page `Sheet i of t` counter (the paginated
/// exports) — folded into the chrome the shared block reads.
/// The reserved strip across the page bottom: the device legend takes the
/// bottom-left, the title block (height [titleBlockHeight], null = no chrome
/// ⇒ the legacy 96 pt strip) the bottom-right.
double _sldTitleStripH(SldSheet sheet, double? titleBlockHeight) {
  final legendH =
      sheet.legend.isNotEmpty ? 18.0 + sheet.legend.length * 11.0 : 0.0;
  return titleBlockHeight != null
      ? math.max(titleBlockHeight, legendH) + 24.0
      : 96.0;
}

/// Round 10 (elec-drawing-props-3) — the smallest label size [sheet] would
/// PRINT at (page points, after [fitSldSheetForPlot]) on the one-page A3
/// layout [_sldPageContent] uses with [chrome]. Below [kMinPlotLabelPt] the
/// page is unreadable as a single sheet.
double sldSinglePageMinLabelPt(SldSheet sheet,
    {DrawingChrome? chrome,
    String projectName = 'Untitled project',
    String diagramTitle = 'ELECTRICAL SINGLE-LINE DIAGRAM'}) {
  final hasChrome = chrome != null && !chrome.isEmpty;
  final tbH = hasChrome
      ? pdfTitleBlock(chrome,
              pageW: _pageW,
              pageH: _pageH,
              margin: _margin,
              projectName: projectName,
              scaleTextOverride: chrome.scaleText ?? 'NTS',
              titleTextOverride: diagramTitle)
          .height
      : null;
  const availW = _pageW - 2 * _margin - 2 * _drawInset;
  final availH =
      _pageH - 2 * _margin - _sldTitleStripH(sheet, tbH) - 2 * _drawInset;
  final fit = fitSldSheetForPlot(sheet, availW: availW, availH: availH);
  var minPt = double.infinity;
  for (final p in fit.sheet.prims) {
    if (p is SldLabel && p.text.trim().isNotEmpty) {
      minPt = math.min(minPt, p.size * fit.scale);
    }
  }
  return minPt;
}

/// Round 10 (elec-drawing-props-3) — the DETAIL single-line (every board's
/// schedule) as an ISSUABLE PDF: one A3 sheet when every label still prints
/// at [kMinPlotLabelPt] or more, else the one-board-per-page set
/// ([electricalSldToPdfPaginated]) — a 45-way project stacked onto one page
/// printed its schedule cells at ~3.6 pt (the cells sit between row rules, so
/// the plot fit cannot grow them).
Uint8List electricalSldDetailToPdf({
  required ElectricalProject project,
  required ElectricalSystemResult result,
  String title = 'iSystem electrical single-line',
  String diagramTitle = 'ELECTRICAL SINGLE-LINE DIAGRAM',
  DrawingChrome? chrome,
  Map<String, double>? breakerIcuKaByPanelId,
  Map<String, double>? breakerKaByCircuitId,
  Map<String, ConduitSpec>? containmentByCircuitId,
  String? projectName,
}) {
  // Round 14 (drafting-visual-1) — [projectName] overrides the electrical
  // model's own name, so a submittal stamps ONE project name on every sheet.
  final pname = (projectName != null && projectName.isNotEmpty)
      ? projectName
      : _projectName(project);
  final whole = buildElectricalSld(
      project: project,
      result: result,
      breakerIcuKaByPanelId: breakerIcuKaByPanelId,
      breakerKaByCircuitId: breakerKaByCircuitId,
      containmentByCircuitId: containmentByCircuitId);
  final minPt = sldSinglePageMinLabelPt(whole,
      chrome: chrome, projectName: pname, diagramTitle: diagramTitle);
  // Round 34 — one page only when it really prints at the floor: a single
  // TALL board below it now paginates by way range (was: always one page).
  if (minPt >= kMinPlotLabelPt - 1e-9) {
    return electricalSldToPdf(
        project: project,
        sheet: whole,
        title: title,
        diagramTitle: diagramTitle,
        chrome: chrome,
        projectName: pname);
  }
  return electricalSldToPdfPaginated(
      project: project,
      result: result,
      title: title,
      diagramTitle: diagramTitle,
      chrome: chrome,
      breakerIcuKaByPanelId: breakerIcuKaByPanelId,
      breakerKaByCircuitId: breakerKaByCircuitId,
      containmentByCircuitId: containmentByCircuitId,
      projectName: pname);
}

/// Round 34 (electrical-drawings-4-tall-board-schedule-illegible) — ONE
/// board's schedule as issuable sheets: `[whole]` when it prints at
/// [kMinPlotLabelPt] on one A3 page, else the fewest equal WAY RANGES whose
/// every page prints at the floor (first page: header + incomer; later pages
/// 'LANJUTAN W<a>-W<b>'; the last: spares + TOTAL). The schedule rows sit
/// between rules, so the plot fit cannot grow them — splitting is the only
/// way a 36-way board's rows stay legible. Pure.
List<SldSheet> electricalBoardScheduleSheets({
  required ElectricalProject project,
  required ElectricalSystemResult result,
  required String panelId,
  String diagramTitle = 'ELECTRICAL SINGLE-LINE DIAGRAM',
  DrawingChrome? chrome,
  Map<String, double>? breakerIcuKaByPanelId,
  Map<String, double>? breakerKaByCircuitId,
  Map<String, ConduitSpec>? containmentByCircuitId,
  String projectName = 'Untitled project',
}) {
  SldSheet build(({int lo, int hi})? r) => buildElectricalSld(
      project: project,
      result: result,
      onlyPanelId: panelId,
      breakerIcuKaByPanelId: breakerIcuKaByPanelId,
      breakerKaByCircuitId: breakerKaByCircuitId,
      containmentByCircuitId: containmentByCircuitId,
      wayRange: r);
  bool legible(SldSheet s) =>
      sldSinglePageMinLabelPt(s,
          chrome: chrome,
          projectName: projectName,
          diagramTitle: diagramTitle) >=
      kMinPlotLabelPt - 1e-9;
  final whole = build(null);
  final ways = result.panels[panelId]?.circuits.length ?? 0;
  if (ways <= 1 || legible(whole)) return [whole];
  var pages = [whole];
  for (var g = 2; g <= ways; g++) {
    final size = (ways / g).ceil();
    pages = [
      for (var lo = 0; lo < ways; lo += size)
        build((lo: lo, hi: math.min(lo + size, ways) - 1)),
    ];
    if (pages.every(legible)) break;
  }
  return pages;
}

String _sldPageContent({
  required SldSheet sheet,
  required String projectName,
  required String title,
  required String diagramTitle,
  DrawingChrome? chrome,
  int? sheetIndexOverride,
  int? sheetTotalOverride,
}) {
  // N20: WITH chrome the sheet carries the SAME shared drawing_chrome tabular
  // title block the plan exporters stamp — PROJECT/CLIENT/TITLE/DWG NO/REV/
  // SCALE/DATE/DRAWN/CHECKED/APPROVED/SHEET — bottom-right, with the diagram
  // title as the TITLE row (a single-line is schematic ⇒ SCALE defaults `NTS`).
  // WITHOUT chrome the sheet keeps the legacy header-style block, byte-identical.
  final hasChrome = chrome != null && !chrome.isEmpty;
  // A paginated export re-stamps the per-page `i of N`; fold that into the
  // chrome the shared block reads so its SHEET row reads the page's own number.
  final effChrome = hasChrome
      ? chrome.withSheet(sheetIndexOverride, sheetTotalOverride)
      : null;
  final tb = hasChrome
      ? pdfTitleBlock(effChrome!,
          pageW: _pageW,
          pageH: _pageH,
          margin: _margin,
          projectName: projectName,
          scaleTextOverride: effChrome.scaleText ?? 'NTS',
          titleTextOverride: diagramTitle)
      : null;
  final titleBlockH = _sldTitleStripH(sheet, tb?.height);

  // ── Auto-fit the drawing into the area above the title block ────────────────
  // drafting-9: the drawing sits a [_drawInset] inside the frame on every side,
  // so a height-limited sheet's top label (the source-spine head) no longer
  // prints on the frame line. drafting-6: [fitSldSheetForPlot] keeps every
  // label at or above the minimum plotted size (kMinPlotLabelPt) where there is
  // clear space, and its bounds cover each label's real text extent.
  const availW = _pageW - 2 * _margin - 2 * _drawInset;
  final availH = _pageH - 2 * _margin - titleBlockH - 2 * _drawInset;
  final fit = fitSldSheetForPlot(sheet, availW: availW, availH: availH);
  final plot = fit.sheet;
  final scale = fit.scale;
  final drawnW = (plot.maxX - plot.minX) * scale;
  final drawnH = (plot.maxY - plot.minY) * scale;
  final offX = _margin + _drawInset + (availW - drawnW) / 2;
  // Top of the drawing area (PDF y-up): just under the top margin + inset.
  final topY = _pageH - _margin - _drawInset - (availH - drawnH) / 2;
  double tx(double x) => offX + (x - plot.minX) * scale;
  double ty(double y) => topY - (y - plot.minY) * scale; // flip y-down→y-up

  final cs = StringBuffer();

  // ── Sheet border ───────────────────────────────────────────────────────────
  cs.writeln('0.20 0.20 0.20 RG 1.0 w');
  cs.writeln('${_n(_margin)} ${_n(_margin)} '
      '${_n(_pageW - 2 * _margin)} ${_n(_pageH - 2 * _margin)} re S');

  // ── Drawing content (panels / busbars / ways / feeders) ─────────────────────
  for (final p in plot.prims) {
    switch (p) {
      case SldLine():
        cs.writeln('${_strokeRgForLine(p)} RG '
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
        // Round 10 (elec-drawing-props-4) — print the FITTED size exactly, as
        // the DXF does: [fitSldSheetForPlot] already grew every label it could
        // into clear space; a renderer-side floor re-enlarged boxed-in labels
        // around the same anchor and overprinted their neighbours (PDF != DXF).
        final fs = p.size * scale;
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
  if (hasChrome) {
    // N20: the shared drawing_chrome tabular block — one title block across the
    // whole issued set (plan + SLD). The diagram title is its TITLE row.
    cs.write(tb!.ops);
    // The honest supply note kept as a muted line just above the block (the
    // schematic feed context the tabular grid has no row for).
    if (sheet.supplyNote.isNotEmpty) {
      final ny = _margin + titleBlockH - 24 + 8; // = max(tb, legend) + 8
      cs.writeln('BT /F1 8 Tf 0.30 0.30 0.30 rg '
          '${_n(_margin + 4)} ${_n(ny)} Td (${_pdfText(sheet.supplyNote)}) Tj ET');
    }
  } else {
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
    // Sheet counter: a paginated export forces its own per-page `i of t`.
    String? counter;
    if (sheetIndexOverride != null || sheetTotalOverride != null) {
      final i = sheetIndexOverride ?? 1;
      final t = sheetTotalOverride ?? i;
      counter = 'Sheet $i of $t';
    }
    if (counter != null) {
      cs.writeln('BT /F1 8 Tf 0.30 0.30 0.30 rg '
          '${_n(tbX + 8)} ${_n(tbY + 8)} Td (${_pdfText(counter)}) Tj ET');
    }
  }

  // Round 29 (drawings-3-1) — a sheet whose builder could only place some
  // tags fused into others says so (top-left, inside the frame), like the
  // plan pipeline, instead of being issued as if clean.
  final overlapNote = planOverlapWarning(sheet.overlapCount);
  if (overlapNote != null) {
    cs.writeln('BT /F1 8 Tf 0.75 0.10 0.10 rg '
        '${_n(_margin + 6)} ${_n(_pageH - _margin - 12)} Td '
        '(${_pdfText(overlapNote)}) Tj ET');
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
    // WinAnsi so the Latin-1 bytes `_pdfText` emits (U+00B7 middle dot, degree,
    // super-2/3, O-stroke, plus-minus) render as their real glyph, not `?`.
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
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

String _projectName(ElectricalProject? project) =>
    (project?.name.isNotEmpty ?? false) ? project!.name : 'Untitled project';

/// Render the sized electrical single-line as a single-page PDF and return its
/// bytes. [title] is stamped in the title block.
///
/// Supply EITHER [project] + [result] (the exporter builds the sheet — a detail
/// single-line, or the [overview] / [sourceChain] variant) OR a prebuilt
/// [sheet] (e.g. a riser built by the app with the live `BuildingLevels`) —
/// keeping the [SldSheet] the single source of geometry.
///
/// [projectName] overrides the title-block PROJECT row: with a prebuilt [sheet]
/// there is no [project] to read a name from, so pass the live name here to
/// avoid the `Untitled project` placeholder (N2). Null / empty ⇒ the derived
/// name (byte-identical).
Uint8List electricalSldToPdf({
  ElectricalProject? project,
  ElectricalSystemResult? result,
  SldSheet? sheet,
  String title = 'iSystem electrical single-line',
  String diagramTitle = 'ELECTRICAL SINGLE-LINE DIAGRAM',
  DrawingChrome? chrome,
  bool overview = false,
  bool sourceChain = false,
  String? projectName,
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
      projectName: (projectName != null && projectName.isNotEmpty)
          ? projectName
          : _projectName(project),
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
  Map<String, double>? breakerKaByCircuitId,
  Map<String, ConduitSpec>? containmentByCircuitId,
  String? projectName,
}) {
  final ids = result.order;
  final pname = (projectName != null && projectName.isNotEmpty)
      ? projectName
      : _projectName(project);
  if (ids.isEmpty) {
    return _assemblePdf([
      _sldPageContent(
        sheet: buildElectricalSld(
            project: project,
            result: result,
            breakerIcuKaByPanelId: breakerIcuKaByPanelId,
            breakerKaByCircuitId: breakerKaByCircuitId,
            containmentByCircuitId: containmentByCircuitId),
        projectName: pname,
        title: title,
        diagramTitle: diagramTitle,
        chrome: chrome,
        sheetIndexOverride: 1,
        sheetTotalOverride: 1,
      ),
    ]);
  }
  // Round 34 — a board too tall for one legible page continues on way-range
  // pages; `Sheet i of N` runs across the whole set.
  final sheets = <SldSheet>[
    for (final id in ids)
      ...electricalBoardScheduleSheets(
          project: project,
          result: result,
          panelId: id,
          diagramTitle: diagramTitle,
          chrome: chrome,
          breakerIcuKaByPanelId: breakerIcuKaByPanelId,
          breakerKaByCircuitId: breakerKaByCircuitId,
          containmentByCircuitId: containmentByCircuitId,
          projectName: pname),
  ];
  final pages = <String>[
    for (var i = 0; i < sheets.length; i++)
      _sldPageContent(
        sheet: sheets[i],
        projectName: pname,
        title: title,
        diagramTitle: diagramTitle,
        chrome: chrome,
        sheetIndexOverride: i + 1,
        sheetTotalOverride: sheets.length,
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
