/// Native PDF export of the electrical single-line — a self-contained vector
/// drawing deliverable with NO third-party dependency. The electrical mirror of
/// `pdf_export.dart` (`networkToPdf`). Pure: builds the PDF byte stream from the
/// sized system; the app handles file IO. Zero Flutter imports.
///
/// A single A3-landscape page. The professional single-line CONTENT — every
/// panel as a distribution-board single-line (incomer breaker → busbar → one row
/// per outgoing way with breaker / cable / load / phase / Ib, feeders routed to
/// the sub-panel they supply) — is built once in `electrical_sld_drawing.dart`
/// and rendered here; the sheet FRAME (title block + device legend + the opt-in
/// `DrawingChrome` north/scale/revision) is stamped in page space so it stays
/// legible regardless of the drawing's auto-fit scale.
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
  DrawingChrome? chrome,
  bool overview = false,
  bool sourceChain = false,
}) {
  assert(sheet != null || (project != null && result != null),
      'electricalSldToPdf needs either a prebuilt sheet or project+result');
  const pageW = 1190.55; // A3 landscape, points (420 mm)
  const pageH = 841.89; // 297 mm
  const margin = 40.0;
  const titleBlockH = 96.0; // reserved strip across the page bottom

  // A prebuilt [sheet] wins; else `overview` = the ZOOMED-OUT building
  // single-line (compact panel tree, optional source spine), default = the
  // per-panel detail single-line.
  final sheetResolved = sheet ??
      (overview
          ? buildElectricalOverview(
              project: project!, result: result!, sourceChain: sourceChain)
          : buildElectricalSld(project: project!, result: result!));

  // ── Auto-fit the drawing into the area above the title block ────────────────
  final spanX = math.max(1e-6, sheetResolved.maxX - sheetResolved.minX);
  final spanY = math.max(1e-6, sheetResolved.maxY - sheetResolved.minY);
  const availW = pageW - 2 * margin;
  const availH = pageH - 2 * margin - titleBlockH;
  var scale = math.min(availW / spanX, availH / spanY);
  if (!scale.isFinite || scale <= 0) scale = 1.0;
  scale = math.min(scale, 1.0); // never blow a tiny drawing up past 1:1
  final drawnW = spanX * scale;
  final drawnH = spanY * scale;
  final offX = margin + (availW - drawnW) / 2;
  // Top of the drawing area (PDF y-up): just under the top margin.
  final topY = pageH - margin - (availH - drawnH) / 2;
  double tx(double x) => offX + (x - sheetResolved.minX) * scale;
  double ty(double y) => topY - (y - sheetResolved.minY) * scale; // flip y-down→y-up

  final cs = StringBuffer();

  // ── Sheet border ───────────────────────────────────────────────────────────
  cs.writeln('0.20 0.20 0.20 RG 1.0 w');
  cs.writeln('${_n(margin)} ${_n(margin)} '
      '${_n(pageW - 2 * margin)} ${_n(pageH - 2 * margin)} re S');

  // ── Drawing content (panels / busbars / ways / feeders) ─────────────────────
  for (final p in sheetResolved.prims) {
    switch (p) {
      case SldLine():
        cs.writeln('${_strokeRgForRole(p.role)} RG '
            '${_n(_weightPt(p.weight) * scale + 0.3)} w');
        cs.writeln('${_n(tx(p.x1))} ${_n(ty(p.y1))} m '
            '${_n(tx(p.x2))} ${_n(ty(p.y2))} l S');
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
  final tbW = math.min(360.0, pageW - 2 * margin);
  final tbX = pageW - margin - tbW;
  const tbY = margin;
  cs.writeln('0.20 0.20 0.20 RG 1.0 w');
  cs.writeln('${_n(tbX)} ${_n(tbY)} ${_n(tbW)} ${_n(titleBlockH)} re S');
  // internal divider under the title
  cs.writeln('${_n(tbX)} ${_n(tbY + titleBlockH - 28)} m '
      '${_n(tbX + tbW)} ${_n(tbY + titleBlockH - 28)} l S');
  final pname = (project?.name.isNotEmpty ?? false)
      ? project!.name
      : 'Untitled project';
  cs.writeln('BT /F1 13 Tf 0 0 0 rg '
      '${_n(tbX + 8)} ${_n(tbY + titleBlockH - 20)} Td (${_pdfText(pname)}) Tj ET');
  cs.writeln('BT /F1 11 Tf 0.15 0.15 0.15 rg '
      '${_n(tbX + 8)} ${_n(tbY + titleBlockH - 46)} Td '
      '(${_pdfText('ELECTRICAL SINGLE-LINE DIAGRAM')}) Tj ET');
  cs.writeln('BT /F1 8 Tf 0.30 0.30 0.30 rg '
      '${_n(tbX + 8)} ${_n(tbY + titleBlockH - 62)} Td '
      '(${_pdfText(title)}) Tj ET');
  cs.writeln('BT /F1 8 Tf 0.30 0.30 0.30 rg '
      '${_n(tbX + 8)} ${_n(tbY + titleBlockH - 76)} Td '
      '(${_pdfText(sheetResolved.supplyNote)}) Tj ET');
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
    if (chrome.sheetIndex != null || chrome.sheetTotal != null) {
      final i = chrome.sheetIndex ?? 1;
      final t = chrome.sheetTotal ?? i;
      cs.writeln('BT /F1 8 Tf 0.30 0.30 0.30 rg '
          '${_n(tbX + 8)} ${_n(tbY + 8)} Td (${_pdfText('Sheet $i of $t')}) Tj ET');
    }
  }

  // ── Device legend (KETERANGAN, bottom-left) ─────────────────────────────────
  if (sheetResolved.legend.isNotEmpty) {
    const rowH = 11.0;
    final lh = 18.0 + sheetResolved.legend.length * rowH;
    const lw = 240.0;
    const lx = margin + 4;
    const ly = margin + 2;
    cs.writeln('0.20 0.20 0.20 RG 0.8 w');
    cs.writeln('${_n(lx)} ${_n(ly)} ${_n(lw)} ${_n(lh)} re S');
    cs.writeln('BT /F1 9 Tf 0 0 0 rg '
        '${_n(lx + 6)} ${_n(ly + lh - 12)} Td (${_pdfText('LEGEND')}) Tj ET');
    var row = 0;
    for (final e in sheetResolved.legend) {
      final ry = ly + lh - 24 - row * rowH;
      cs.writeln('BT /F1 7.5 Tf 0.12 0.12 0.12 rg '
          '${_n(lx + 6)} ${_n(ry)} Td '
          '(${_pdfText('${e.code}  -  ${e.meaning}')}) Tj ET');
      row++;
    }
  }

  // A single-line is schematic, not geographic — no north arrow / scale bar.
  // The DrawingChrome carries only the sheet number, stamped in the title block.

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
