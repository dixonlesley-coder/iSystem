/// Commercial export renderers (pure) — turn a priced [CostEstimate] and a
/// [Quotation] into a CSV bill-of-materials and a Markdown proposal. Pure string
/// builders: the app handles the file IO (mirrors `sizing/bom.dart`'s `bomToCsv`).
///
/// Zero Flutter imports.
library;

import '../report/number_format.dart';
import 'costing.dart';
import 'quotation.dart';

/// Escape a value for a CSV cell: wrap in quotes and double any embedded quotes
/// when it contains a comma, quote or newline.
String _csv(String v) {
  if (v.contains(',') || v.contains('"') || v.contains('\n')) {
    return '"${v.replaceAll('"', '""')}"';
  }
  return v;
}

/// Format a number without a trailing `.0`.
String _num(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// Escape a value for a Markdown table cell: a literal `|` would otherwise
/// split the row into extra columns, and a newline would break the row.
String _md(String v) => v.replaceAll('|', r'\|').replaceAll('\n', ' ');

/// Render a priced [estimate] as CSV: one header row + one row per priced BOM
/// line (qty, category, description, sku, unit price, line total, matched). The
/// grand total is appended as a trailing summary row.
String costEstimateToCsv(CostEstimate estimate) {
  final b = StringBuffer(
      'qty,category,description,sku,unit_price,line_total,matched\n');
  for (final l in estimate.lines) {
    b
      ..write(_num(l.line.qty))
      ..write(',')
      ..write(_csv(l.line.category.name))
      ..write(',')
      ..write(_csv(l.line.description))
      ..write(',')
      ..write(_csv(l.line.sku ?? ''))
      ..write(',')
      // Money cells are UNGROUPED (spreadsheet-parseable) but fixed to 2 dp so
      // a whole-rupiah price and a fractional one line up (D7).
      ..write(l.unitPrice == null ? '' : l.unitPrice!.toStringAsFixed(2))
      ..write(',')
      ..write(l.lineTotal == null ? '' : l.lineTotal!.toStringAsFixed(2))
      ..write(',')
      ..write(l.matched ? 'yes' : 'no')
      ..write('\n');
  }
  b
    ..write(_csv('Material subtotal (${estimate.currency})'))
    ..write(',,,,,')
    ..write(estimate.grandTotal.toStringAsFixed(2))
    ..write(',\n');
  return b.toString();
}

/// Render a [quotation] (and its priced [estimate]) as a Markdown proposal: a
/// material line-item table, then the costed roll-up (material / labour /
/// overhead / contingency / margin / grand total) and any unmatched-line note.
String quotationToMarkdown(
  Quotation quotation,
  CostEstimate estimate, {
  String projectName = 'Project',
}) {
  final cur = quotation.currency;
  // Client-facing money: thousands grouped + a fixed 2 dp (D7) — no more raw
  // `toString` doubles (`1181250` beside `3703.68`) in the proposal tables.
  String m(double v) => money(v, dp: 2);
  final b = StringBuffer()
    ..writeln('# Electrical proposal — $projectName')
    ..writeln()
    ..writeln('## Bill of materials')
    ..writeln()
    ..writeln('| Qty | Category | Description | SKU | Unit ($cur) | Total ($cur) |')
    ..writeln('| ---: | --- | --- | --- | ---: | ---: |');
  for (final l in estimate.lines) {
    b.writeln('| ${_num(l.line.qty)} | ${l.line.category.name} | '
        '${_md(l.line.description)} | ${_md(l.line.sku ?? '-')} | '
        '${l.unitPrice == null ? '-' : m(l.unitPrice!)} | '
        '${l.lineTotal == null ? '(unpriced)' : m(l.lineTotal!)} |');
  }
  b
    ..writeln()
    ..writeln('## Quotation')
    ..writeln()
    ..writeln('| Item | Amount ($cur) |')
    ..writeln('| --- | ---: |')
    ..writeln('| Material | ${m(quotation.materialSubtotal)} |')
    ..writeln('| Labour (${_num(quotation.labourHours)} h) | '
        '${m(quotation.labourSubtotal)} |')
    ..writeln('| Overhead | ${m(quotation.overhead)} |')
    ..writeln('| Contingency | ${m(quotation.contingency)} |')
    ..writeln('| Margin | ${m(quotation.margin)} |')
    ..writeln('| **Grand total** | **${m(quotation.grandTotal)}** |');
  if (estimate.unmatchedCount > 0) {
    b
      ..writeln()
      ..writeln('> ${estimate.unmatchedCount} line(s) are unpriced (no '
          'catalogue match or no price in the pricelist) and are excluded from '
          'the material subtotal.');
  }
  return b.toString();
}

/// Render the pricelist (`sku → unit price`) as CSV, sorted by sku. Useful as an
/// export of the prices the user has entered (re-importable into a spreadsheet).
String priceListToCsv(Map<String, double> priceList) {
  final b = StringBuffer('sku,unit_price\n');
  final skus = priceList.keys.toList()..sort();
  for (final sku in skus) {
    b
      ..write(_csv(sku))
      ..write(',')
      ..write(_num(priceList[sku]!))
      ..write('\n');
  }
  return b.toString();
}
