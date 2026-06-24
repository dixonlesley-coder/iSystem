/// Commercial export renderers (pure) — turn a priced [CostEstimate] and a
/// [Quotation] into a CSV bill-of-materials and a Markdown proposal. Pure string
/// builders: the app handles the file IO (mirrors `sizing/bom.dart`'s `bomToCsv`).
///
/// Zero Flutter imports.
library;

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
      ..write(l.unitPrice == null ? '' : _num(l.unitPrice!))
      ..write(',')
      ..write(l.lineTotal == null ? '' : _num(l.lineTotal!))
      ..write(',')
      ..write(l.matched ? 'yes' : 'no')
      ..write('\n');
  }
  b
    ..write(_csv('Material subtotal (${estimate.currency})'))
    ..write(',,,,,')
    ..write(_num(estimate.grandTotal))
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
  final b = StringBuffer()
    ..writeln('# Electrical proposal — $projectName')
    ..writeln()
    ..writeln('## Bill of materials')
    ..writeln()
    ..writeln('| Qty | Category | Description | SKU | Unit ($cur) | Total ($cur) |')
    ..writeln('| ---: | --- | --- | --- | ---: | ---: |');
  for (final l in estimate.lines) {
    b.writeln('| ${_num(l.line.qty)} | ${l.line.category.name} | '
        '${l.line.description} | ${l.line.sku ?? '-'} | '
        '${l.unitPrice == null ? '-' : _num(l.unitPrice!)} | '
        '${l.lineTotal == null ? '(unpriced)' : _num(l.lineTotal!)} |');
  }
  b
    ..writeln()
    ..writeln('## Quotation')
    ..writeln()
    ..writeln('| Item | Amount ($cur) |')
    ..writeln('| --- | ---: |')
    ..writeln('| Material | ${_num(quotation.materialSubtotal)} |')
    ..writeln('| Labour (${_num(quotation.labourHours)} h) | '
        '${_num(quotation.labourSubtotal)} |')
    ..writeln('| Overhead | ${_num(quotation.overhead)} |')
    ..writeln('| Contingency | ${_num(quotation.contingency)} |')
    ..writeln('| Margin | ${_num(quotation.margin)} |')
    ..writeln('| **Grand total** | **${_num(quotation.grandTotal)}** |');
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
