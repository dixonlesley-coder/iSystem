/// Cost a bill of materials against a pricelist (pure).
///
/// The pricelist is a separate concern from the catalogue (prices NEVER live in
/// the committed parts dataset), so [estimateCost] takes a `sku → unit price`
/// map. A line whose sku is null, or whose sku is absent from the pricelist, is
/// kept but flagged unmatched and contributes nothing to the grand total — so a
/// caller can prompt the user to resolve it.
///
/// Ported from PanelMaker `engine/costing.ts costBom`.
///
/// Zero Flutter imports.
library;

import 'bom.dart';

/// One priced BOM line: the source [line] plus the resolved unit/line totals.
class CostLine {
  final BomLine line;

  /// Unit price from the pricelist, or null when unmatched.
  final double? unitPrice;

  /// qty × unitPrice, or null when unmatched.
  final double? lineTotal;

  /// True when the line was priced (sku found in the pricelist).
  final bool matched;

  const CostLine({
    required this.line,
    required this.matched,
    this.unitPrice,
    this.lineTotal,
  });
}

/// A priced bill of materials.
class CostEstimate {
  final List<CostLine> lines;

  /// Sum of priced line totals (unmatched lines excluded).
  final double grandTotal;

  /// ISO-ish currency label (display only).
  final String currency;

  /// Count of lines that could not be priced.
  final int unmatchedCount;

  const CostEstimate({
    required this.lines,
    required this.grandTotal,
    required this.currency,
    required this.unmatchedCount,
  });
}

double _round2(double v) => (v * 100).roundToDouble() / 100;

/// Price [bom] against [priceList] (`sku → unit price`). Returns a per-line
/// breakdown, the grand total of priced lines, and the count of unmatched lines.
CostEstimate estimateCost(
  Bom bom,
  Map<String, double> priceList, {
  String currency = 'IDR',
}) {
  var grandTotal = 0.0;
  var unmatched = 0;
  final out = <CostLine>[];

  for (final line in bom.lines) {
    final unit = line.sku == null ? null : priceList[line.sku];
    if (unit == null) {
      unmatched += 1;
      out.add(CostLine(line: line, matched: false));
      continue;
    }
    final total = _round2(unit * line.qty);
    grandTotal += total;
    out.add(CostLine(
      line: line,
      matched: true,
      unitPrice: unit,
      lineTotal: total,
    ));
  }

  return CostEstimate(
    lines: out,
    grandTotal: _round2(grandTotal),
    currency: currency,
    unmatchedCount: unmatched,
  );
}
