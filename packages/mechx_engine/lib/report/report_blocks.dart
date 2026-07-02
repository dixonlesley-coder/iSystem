/// Neutral REPORT BLOCK model — the small sealed vocabulary the calculation
/// reports are built from, and the shared Markdown renderer that walks it.
///
/// The four flagship report builders (`calc_report.dart`,
/// `electrical_calc_report.dart`, `mep_report.dart`,
/// `equipment_schedule.dart`) each expose a `build*Blocks` function emitting a
/// `List<RptBlock>`; their legacy Markdown entry points are now
/// `renderRptMarkdown` over those blocks and reproduce the pre-refactor output
/// BYTE-IDENTICALLY (pinned by `report_characterization_test.dart`). The same
/// block list feeds the paginating PDF typesetter (`report_pdf.dart`) — one
/// content model, two renders (golden rule 5 applied to documents).
///
/// Pure Dart, zero Flutter imports.
library;

import 'sld_sheet.dart';

/// One block of report content. Sealed so renderers (Markdown, PDF) switch
/// exhaustively — adding a block type forces every renderer to handle it.
sealed class RptBlock {
  const RptBlock();
}

/// A section heading, level 1–3 (`#`/`##`/`###`).
///
/// [tight] is a Markdown-fidelity nuance only: a tight heading emits NO blank
/// line after itself (the legacy "Unverified values" heading runs straight
/// into its paragraph). The PDF typesetter ignores it.
class RptHeading extends RptBlock {
  final int level;
  final String text;
  final bool tight;

  const RptHeading(this.level, this.text, {this.tight = false})
      : assert(level >= 1 && level <= 3, 'heading level must be 1..3');
}

/// A single paragraph of running text. May carry inline Markdown markers
/// (`**bold**`, `_emphasis_`) — the Markdown renderer emits them verbatim, the
/// PDF typesetter strips them.
class RptParagraph extends RptBlock {
  final String text;
  const RptParagraph(this.text);
}

/// A register of `(key, value)` rows — the design-basis / supply-summary
/// bullet style. Markdown renders each row as `- key value` (`- value` when
/// the key is empty — a plain bullet); the PDF typesetter lays the rows out as
/// a two-column unruled grid (full-width when the key is empty). Keys carry
/// their trailing colon verbatim (e.g. `'Levels:'`).
class RptKeyValue extends RptBlock {
  final List<(String, String)> rows;
  const RptKeyValue(this.rows);
}

/// A ruled data table. Cells are carried as exact strings (already escaped
/// for Markdown where needed).
///
/// [mdSeparator] is a Markdown-fidelity field only: the exact delimiter row
/// the legacy builder emitted (alignment markers and spacing differ between
/// reports, e.g. `|---|---:|` vs `| --- | --- |`). Null ⇒ a default
/// `| --- | ... |` row is synthesized. The PDF typesetter ignores it.
class RptTable extends RptBlock {
  final List<String> headers;
  final List<List<String>> rows;
  final String? mdSeparator;

  const RptTable(this.headers, this.rows, {this.mdSeparator});
}

/// A muted advisory / transparency note (the closing "confirm all UNVERIFIED
/// values" style). Markdown emits the text with NO trailing blank line (notes
/// close a document/section in the legacy output); the PDF typesetter renders
/// it smaller and grey.
class RptNote extends RptBlock {
  final String text;
  const RptNote(this.text);
}

/// An embedded vector figure — an [SldSheet] (riser / single-line drawing
/// primitives) with a caption. A PDF-first construct: the Markdown renderer
/// can only emit the caption (Markdown carries no vector content); the PDF
/// typesetter draws the primitives scaled into a bounded box.
class RptFigure extends RptBlock {
  final SldSheet sheet;
  final String caption;
  const RptFigure(this.sheet, {required this.caption});
}

/// TRANSITIONAL escape hatch: raw Markdown emitted verbatim (the renderer
/// adds nothing around it — the raw string carries its own newlines/blank
/// lines). Used for legacy constructs that do not decompose cleanly into the
/// typed blocks (conditional bullet clusters with indented sub-bullets, the
/// hard-break project/date lines, an embedded pre-rendered body). Prefer real
/// blocks; the PDF typesetter renders these as marker-stripped paragraphs.
class RptMarkdown extends RptBlock {
  final String raw;
  const RptMarkdown(this.raw);
}

/// Render [blocks] to Markdown. Each block emits its own trailing spacing
/// (most end with a blank line; see the block docs), so the walk is a plain
/// concatenation — this is what makes the legacy byte rhythm reproducible.
String renderRptMarkdown(List<RptBlock> blocks) {
  final b = StringBuffer();
  for (final block in blocks) {
    switch (block) {
      case RptHeading():
        b.writeln('${'#' * block.level} ${block.text}');
        if (!block.tight) b.writeln();
      case RptParagraph():
        b.writeln(block.text);
        b.writeln();
      case RptKeyValue():
        for (final (key, value) in block.rows) {
          b.writeln(key.isEmpty ? '- $value' : '- $key $value');
        }
        b.writeln();
      case RptTable():
        b.writeln('| ${block.headers.join(' | ')} |');
        b.writeln(block.mdSeparator ??
            '| ${block.headers.map((_) => '---').join(' | ')} |');
        for (final row in block.rows) {
          b.writeln('| ${row.join(' | ')} |');
        }
        b.writeln();
      case RptNote():
        b.writeln(block.text);
      case RptFigure():
        // Markdown carries no vector content — emit the caption as an
        // italic line so the figure's presence is at least recorded.
        b.writeln('_${block.caption}_');
        b.writeln();
      case RptMarkdown():
        b.write(block.raw);
    }
  }
  return b.toString();
}
