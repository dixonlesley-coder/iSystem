/// Commercial quotation / proposal engine (pure).
///
/// A standalone pass over a priced material [CostEstimate]: it adds assembly
/// labour, then layers overhead, contingency and profit margin to produce a
/// sell price and a labelled breakdown for a proposal.
///
/// Labour can be supplied two ways:
///  - explicitly via [labourHours] (an estimator's measured figure), OR
///  - derived from the priced BOM via the per-category labour standard
///    ([assemblyHoursForCategory]) when [labourHours] is left null.
///
/// Margin is a TRUE gross margin (profit as a fraction of the SELL price):
/// `sell = cost / (1 − margin)`. Applying `cost · (1 + margin)` would be a
/// *markup* and realise a smaller margin than entered. Ported from PanelMaker
/// `engine/quotation.ts` + `standards/labor.ts`.
///
/// Zero Flutter imports.
library;

import 'bom.dart';
import 'catalog.dart' show PartCategory;
import 'costing.dart';

// ── labour standard (// VERIFY shop rates) ──────────────────────────────────

/// Typical shop assembly/wiring man-hours per unit, keyed by BOM category.
/// // VERIFY: defensible order-of-magnitude figures for an Indonesian LV panel
/// builder (mount on DIN rail / back-plate, terminate power + control wiring,
/// label and test) — NOT an SNI/PUIL clause. The estimator overrides these with
/// a measured shop rate. Transcribed from PanelMaker `standards/labor.ts`.
const Map<PartCategory, double> assemblyHoursPerUnit = {
  PartCategory.breaker: 0.3, // mount on rail + terminate line/load + label
  PartCategory.cable: 0.2, // per run: cut, dress, gland, terminate, ferrule
  PartCategory.rcd: 0.3, // mount + wire trip path + test
  PartCategory.busbar: 1.0, // cut/drill/insulate a bar set + torque joints
  PartCategory.enclosure: 4.0, // prep, drill, gland plates, back-plate fit-out
  PartCategory.accessory: 0.1, // minor accessory (din-rail end, marker, …)
};

/// Fallback assembly hours for a category with no explicit entry.
const double defaultAssemblyHours = 0.25;

/// Assembly hours for one unit of [category] (falls back to the default).
double assemblyHoursForCategory(PartCategory category) =>
    assemblyHoursPerUnit[category] ?? defaultAssemblyHours;

/// Total assembly man-hours implied by a bill of materials (Σ hours × qty).
double labourHoursForBom(Bom bom) => bom.lines
    .fold(0.0, (s, l) => s + assemblyHoursForCategory(l.category) * l.qty);

// ── quotation result ─────────────────────────────────────────────────────────

/// A labelled amount in the quotation breakdown (for a proposal table).
class QuoteSection {
  final String label;
  final double amount;
  const QuoteSection(this.label, this.amount);
}

/// A finished quotation: the cost base, the markups and the sell price.
class Quotation {
  /// Sum of priced material lines (from the [CostEstimate]).
  final double materialSubtotal;

  /// Labour man-hours used.
  final double labourHours;

  /// Labour cost = labourHours × labourRate.
  final double labourSubtotal;

  /// Overhead loading on the prime (material + labour) cost.
  final double overhead;

  /// Contingency / risk allowance on the prime cost.
  final double contingency;

  /// Cost base before margin = prime + overhead + contingency.
  final double marginBase;

  /// Profit amount = sell − marginBase.
  final double margin;

  /// Final sell price.
  final double grandTotal;

  final String currency;

  /// Labelled breakdown for a proposal table.
  final List<QuoteSection> sections;

  const Quotation({
    required this.materialSubtotal,
    required this.labourHours,
    required this.labourSubtotal,
    required this.overhead,
    required this.contingency,
    required this.marginBase,
    required this.margin,
    required this.grandTotal,
    required this.currency,
    required this.sections,
  });
}

double _round2(double v) => (v * 100).roundToDouble() / 100;

/// Default labour rate when the caller does not pass one (IDR per hour).
/// // VERIFY: an illustrative default — the estimator sets the real shop rate.
const double defaultLabourRatePerHour = 150000;

/// Build a quotation from a priced material estimate and the markup settings.
///
/// Material is [CostEstimate.grandTotal] (priced lines only). Labour is either
/// the explicit [labourHours] or, when null, derived from [material]'s BOM via
/// the labour standard — so [bom] must be supplied to derive it. Overhead and
/// contingency load the (material + labour) prime cost; margin is a true gross
/// margin on the resulting cost base. With every percentage and the labour rate
/// at zero the grand total equals the bare material subtotal.
Quotation buildQuotation(
  CostEstimate material, {
  Bom? bom,
  double? labourHours,
  double labourRate = defaultLabourRatePerHour,
  double overheadPct = 10,
  double contingencyPct = 5,
  double marginPct = 15,
}) {
  final materialSubtotal = _round2(material.grandTotal);

  final hours = _round2(
    labourHours ?? (bom != null ? labourHoursForBom(bom) : 0.0),
  );
  final labourSubtotal = _round2(hours * labourRate);

  final prime = materialSubtotal + labourSubtotal;
  final overhead = _round2(prime * (overheadPct / 100));
  final contingency = _round2(prime * (contingencyPct / 100));

  final marginBase = _round2(prime + overhead + contingency);
  // Clamp below 100 % to keep sell = base / (1 − margin) finite.
  final marginFraction = marginPct.clamp(0.0, 99.9) / 100;
  final grandTotal = _round2(marginBase / (1 - marginFraction));
  final margin = _round2(grandTotal - marginBase);

  return Quotation(
    materialSubtotal: materialSubtotal,
    labourHours: hours,
    labourSubtotal: labourSubtotal,
    overhead: overhead,
    contingency: contingency,
    marginBase: marginBase,
    margin: margin,
    grandTotal: grandTotal,
    currency: material.currency,
    sections: [
      QuoteSection('Material', materialSubtotal),
      QuoteSection('Labour', labourSubtotal),
      QuoteSection('Overhead', overhead),
      QuoteSection('Contingency', contingency),
      QuoteSection('Margin', margin),
    ],
  );
}
