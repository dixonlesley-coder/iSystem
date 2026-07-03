/// Unified M+E+P commercial costing (pure).
///
/// The electrical commercial pipeline (`electrical/{bom,costing,quotation}`)
/// prices the ELECTRICAL bill of materials only. This module adds the missing
/// **mechanical** side — pricing the mechanical pipe/duct [BomLine]s and the
/// [FittingLine]s (from `sizing/bom.dart`), enriched with the pipe cut-plan
/// ([PipeCutGroup] from `sizing/pipe_optimizer.dart`) — and folds both
/// disciplines into ONE [MepQuotation] with per-discipline material subtotals.
///
/// Prices live NEVER in the committed catalogue (a separate concern, exactly
/// like the electrical pricelist): a mechanical line is priced by a stable
/// **mechanical key** ([mechPipeKey] / [mechFittingKey]) looked up in the same
/// `sku → unit price` map the project already persists. A key with no price is
/// kept, contributes nothing, and is COUNTED as unpriced — a price is the
/// engineer's input, never invented.
///
/// Byte-identical-by-default: an ELECTRICAL-only project (no mechanical lines)
/// yields a [MepQuotation] whose roll-up equals the electrical-only
/// `buildQuotation` result — the mechanical material + labour reduce to zero.
///
/// Zero Flutter imports.
library;

import '../electrical/bom.dart' as elec;
import '../electrical/costing.dart';
import '../electrical/quotation.dart'
    show QuoteSection, defaultLabourRatePerHour, labourHoursForBom;
import '../network/network.dart';
import '../sizing/bom.dart';
import '../sizing/pipe_optimizer.dart';
import 'number_format.dart';

double _round2(double v) => (v * 100).roundToDouble() / 100;

// ── mechanical pricelist keys ─────────────────────────────────────────────────

/// Every mechanical pricelist key is prefixed with this so mechanical prices
/// coexist in the SAME `sku → price` map as the electrical catalogue codes
/// without ever colliding (an electrical SKU is a catalogue order code and
/// never starts with `mech:`). This lets the mechanical prices ride the
/// existing persisted `priceList` with no new `.mechx` field / version bump.
const String kMechPriceKeyPrefix = 'mech:';

/// The stable pricelist key for a mechanical pipe/duct line (per service, run vs
/// riser, and nominal DN in mm). Human-stable so the pricelist survives edits.
String mechPipeKey(ServiceType service, EdgeKind kind, int diameterMm) =>
    '${kMechPriceKeyPrefix}pipe:${service.name}:${kind.name}:$diameterMm';

/// The stable pricelist key for a mechanical fitting line (per service, type,
/// and nominal DN in mm).
String mechFittingKey(ServiceType service, FittingType type, int diameterMm) =>
    '${kMechPriceKeyPrefix}fitting:${service.name}:${type.name}:$diameterMm';

/// True when [key] addresses a mechanical price (vs an electrical catalogue SKU).
bool isMechPriceKey(String key) => key.startsWith(kMechPriceKeyPrefix);

/// Human label for a service (for a BOM row / pricelist description).
String mechServiceLabel(ServiceType service) => switch (service) {
      ServiceType.coldWater => 'Cold water',
      ServiceType.hotWater => 'Hot water',
      ServiceType.drainage => 'Drainage',
      ServiceType.vent => 'Vent',
      ServiceType.rainwater => 'Rainwater',
      ServiceType.duct => 'Supply air',
      ServiceType.returnAir => 'Return air',
      ServiceType.exhaust => 'Exhaust air',
      ServiceType.fireSprinkler => 'Sprinkler',
      ServiceType.fireHydrant => 'Hydrant',
    };

String _fittingLabel(FittingType t) => switch (t) {
      FittingType.elbow => 'elbow',
      FittingType.tee => 'tee',
      FittingType.cross => 'cross',
      FittingType.reducer => 'reducer',
    };

// ── mechanical material costing ───────────────────────────────────────────────

/// Whether a mechanical cost line is a length of pipe/duct or a fitting.
enum MechItemCategory { pipe, fitting }

/// One priced mechanical BOM line — a pipe/duct length (priced per metre) or a
/// fitting (priced per piece). [unitPrice] / [lineTotal] are null when the key
/// carries no price (unpriced).
class MechCostLine {
  /// The pricelist key ([mechPipeKey] / [mechFittingKey]).
  final String key;
  final String description;
  final MechItemCategory category;
  final ServiceType service;

  /// Metres (pipe/duct) or piece count (fitting).
  final double qty;

  /// `m` for a length, `ea` for a fitting.
  final String unit;

  /// Unit price from the pricelist, or null when unpriced.
  final double? unitPrice;

  /// qty × unitPrice, or null when unpriced.
  final double? lineTotal;

  /// True when a price was found for [key].
  final bool priced;

  /// Stock bars this (service, DN) draws from the cut plan (pipe RUNS only —
  /// risers/ducts are excluded from the chain plan), or null. Informational.
  final int? stockBars;

  /// Cut-plan waste for this (service, DN), % of purchased stock, or null.
  final double? wastePercent;

  const MechCostLine({
    required this.key,
    required this.description,
    required this.category,
    required this.service,
    required this.qty,
    required this.unit,
    required this.priced,
    this.unitPrice,
    this.lineTotal,
    this.stockBars,
    this.wastePercent,
  });
}

/// A priced mechanical bill of materials.
class MechCostEstimate {
  final List<MechCostLine> lines;

  /// Sum of priced line totals (unpriced lines excluded).
  final double grandTotal;
  final String currency;

  /// Count of lines with no price.
  final int unpricedCount;

  const MechCostEstimate({
    required this.lines,
    required this.grandTotal,
    required this.currency,
    required this.unpricedCount,
  });

  bool get isEmpty => lines.isEmpty;
}

/// Price the mechanical BOM ([pipes] + [fittings]) against [priceList]. Pipe/duct
/// lines are priced per metre of [BomLine.totalLength]; fittings per piece. When
/// [cutPlan] is supplied, each pipe RUN line is annotated (informationally) with
/// the stock-bar count + waste for its (service, DN) group. A line with no price
/// contributes nothing and is counted in [MechCostEstimate.unpricedCount].
MechCostEstimate estimateMechanicalCost({
  required List<BomLine> pipes,
  required List<FittingLine> fittings,
  required Map<String, double> priceList,
  List<PipeCutGroup> cutPlan = const [],
  String currency = 'IDR',
}) {
  // Aggregate the cut plan by (service, DN) — the plan packs all runs of a size
  // into shared stock bars (multiple stock lengths for one DN are summed).
  final planByKey = <String, ({int bars, double purchased, double waste})>{};
  for (final g in cutPlan) {
    final k = '${g.service.name}:${g.diameterMm}';
    final prev = planByKey[k];
    planByKey[k] = prev == null
        ? (
            bars: g.plan.totalBars,
            purchased: g.plan.purchasedM,
            waste: g.plan.wasteM,
          )
        : (
            bars: prev.bars + g.plan.totalBars,
            purchased: prev.purchased + g.plan.purchasedM,
            waste: prev.waste + g.plan.wasteM,
          );
  }

  final lines = <MechCostLine>[];
  var total = 0.0;
  var unpriced = 0;

  void priceLine({
    required String key,
    required String description,
    required MechItemCategory category,
    required ServiceType service,
    required double qty,
    required String unit,
    int? stockBars,
    double? wastePercent,
  }) {
    final unitPrice = priceList[key];
    if (unitPrice == null) {
      unpriced += 1;
      lines.add(MechCostLine(
        key: key,
        description: description,
        category: category,
        service: service,
        qty: qty,
        unit: unit,
        priced: false,
        stockBars: stockBars,
        wastePercent: wastePercent,
      ));
      return;
    }
    final lineTotal = _round2(unitPrice * qty);
    total += lineTotal;
    lines.add(MechCostLine(
      key: key,
      description: description,
      category: category,
      service: service,
      qty: qty,
      unit: unit,
      priced: true,
      unitPrice: unitPrice,
      lineTotal: lineTotal,
      stockBars: stockBars,
      wastePercent: wastePercent,
    ));
  }

  for (final p in pipes) {
    final noun = p.service.isAir ? 'duct' : 'pipe';
    final kindWord = p.kind == EdgeKind.riser ? '$noun riser' : noun;
    final plan =
        p.kind == EdgeKind.run ? planByKey['${p.service.name}:${p.diameterMm}'] : null;
    priceLine(
      key: mechPipeKey(p.service, p.kind, p.diameterMm),
      description: '${mechServiceLabel(p.service)} $kindWord DN${p.diameterMm}',
      category: MechItemCategory.pipe,
      service: p.service,
      qty: _round2(p.totalLength.meters),
      unit: 'm',
      stockBars: plan?.bars,
      wastePercent: plan == null || plan.purchased <= 0
          ? null
          : _round2(100 * plan.waste / plan.purchased),
    );
  }

  for (final f in fittings) {
    priceLine(
      key: mechFittingKey(f.service, f.type, f.diameterMm),
      description:
          '${mechServiceLabel(f.service)} ${_fittingLabel(f.type)} DN${f.diameterMm}',
      category: MechItemCategory.fitting,
      service: f.service,
      qty: f.count.toDouble(),
      unit: 'ea',
    );
  }

  return MechCostEstimate(
    lines: lines,
    grandTotal: _round2(total),
    currency: currency,
    unpricedCount: unpriced,
  );
}

// ── mechanical install labour standard (// VERIFY) ───────────────────────────

/// Typical install man-hours per metre of pressurized / gravity pipe (cut,
/// align, joint, bracket). // VERIFY: an order-of-magnitude trade figure, NOT
/// an SNI clause — the estimator overrides it with a measured shop rate.
const double mechInstallHoursPerMetrePipe = 0.2; // VERIFY

/// Install man-hours per metre of sheet-metal / PU duct (heavier than pipe).
const double mechInstallHoursPerMetreDuct = 0.3; // VERIFY

/// Install man-hours to make up one pipe/duct fitting.
const double mechInstallHoursPerFitting = 0.3; // VERIFY

/// Total mechanical install man-hours implied by the pipe/duct lengths + the
/// fitting count. Air services use the (heavier) duct rate.
double mechanicalLabourHours({
  required List<BomLine> pipes,
  required List<FittingLine> fittings,
}) {
  var h = 0.0;
  for (final p in pipes) {
    final rate = p.service.isAir
        ? mechInstallHoursPerMetreDuct
        : mechInstallHoursPerMetrePipe;
    h += p.totalLength.meters * rate;
  }
  for (final f in fittings) {
    h += f.count * mechInstallHoursPerFitting;
  }
  return h;
}

// ── unified M+E+P quotation ───────────────────────────────────────────────────

/// A finished M+E+P quotation: per-discipline material subtotals, the combined
/// labour + markups, and the sell price. Mirrors the electrical `Quotation`
/// roll-up (same true-gross-margin arithmetic) but splits material by discipline.
class MepQuotation {
  final double mechanicalMaterial;
  final double electricalMaterial;

  /// mechanicalMaterial + electricalMaterial.
  final double materialSubtotal;

  final double mechanicalLabourHours;
  final double electricalLabourHours;

  /// mechanical + electrical hours (rounded).
  final double labourHours;
  final double labourSubtotal;

  final double overhead;
  final double contingency;

  /// Cost base before margin = prime + overhead + contingency.
  final double marginBase;
  final double margin;
  final double grandTotal;
  final String currency;

  final int mechanicalUnpricedCount;
  final int electricalUnpricedCount;

  /// mechanical + electrical unpriced lines.
  final int unpricedCount;

  /// Labelled breakdown for a proposal table.
  final List<QuoteSection> sections;

  const MepQuotation({
    required this.mechanicalMaterial,
    required this.electricalMaterial,
    required this.materialSubtotal,
    required this.mechanicalLabourHours,
    required this.electricalLabourHours,
    required this.labourHours,
    required this.labourSubtotal,
    required this.overhead,
    required this.contingency,
    required this.marginBase,
    required this.margin,
    required this.grandTotal,
    required this.currency,
    required this.mechanicalUnpricedCount,
    required this.electricalUnpricedCount,
    required this.unpricedCount,
    required this.sections,
  });
}

/// Compose ONE M+E+P quotation from the priced [mechanical] estimate and the
/// electrical [electrical] estimate. Material is the sum of the two disciplines'
/// priced subtotals; labour is the mechanical install hours ([mechanicalPipes] /
/// [mechanicalFittings]) plus the electrical assembly hours (derived from
/// [electricalBom] via the electrical labour standard), unless an explicit
/// [labourHours] is given. Overhead + contingency load the (material + labour)
/// prime; margin is a true gross margin on the resulting cost base.
///
/// With no mechanical lines (`mechanical.grandTotal == 0`, no mechanical pipes /
/// fittings) the result reduces to the electrical-only `buildQuotation` roll-up
/// (byte-identical), so an electrical-only project quotes exactly as before.
MepQuotation buildMepQuotation({
  required MechCostEstimate mechanical,
  required CostEstimate electrical,
  elec.Bom? electricalBom,
  List<BomLine> mechanicalPipes = const [],
  List<FittingLine> mechanicalFittings = const [],
  double? labourHours,
  double labourRate = defaultLabourRatePerHour,
  double overheadPct = 10,
  double contingencyPct = 5,
  double marginPct = 15,
}) {
  final mechMat = _round2(mechanical.grandTotal);
  final elecMat = _round2(electrical.grandTotal);
  final materialSubtotal = _round2(mechMat + elecMat);

  final mechHoursRaw = mechanicalLabourHours(
    pipes: mechanicalPipes,
    fittings: mechanicalFittings,
  );
  final elecHoursRaw =
      electricalBom != null ? labourHoursForBom(electricalBom) : 0.0;
  final hoursRaw = labourHours ?? (mechHoursRaw + elecHoursRaw);
  final hours = _round2(hoursRaw);
  final labourSubtotal = _round2(hours * labourRate);

  final prime = materialSubtotal + labourSubtotal;
  final overhead = _round2(prime * (overheadPct / 100));
  final contingency = _round2(prime * (contingencyPct / 100));

  final marginBase = _round2(prime + overhead + contingency);
  final marginFraction = marginPct.clamp(0.0, 99.9) / 100;
  final grandTotal = _round2(marginBase / (1 - marginFraction));
  final margin = _round2(grandTotal - marginBase);

  final currency =
      electrical.currency.isNotEmpty ? electrical.currency : mechanical.currency;

  return MepQuotation(
    mechanicalMaterial: mechMat,
    electricalMaterial: elecMat,
    materialSubtotal: materialSubtotal,
    mechanicalLabourHours: _round2(mechHoursRaw),
    electricalLabourHours: _round2(elecHoursRaw),
    labourHours: hours,
    labourSubtotal: labourSubtotal,
    overhead: overhead,
    contingency: contingency,
    marginBase: marginBase,
    margin: margin,
    grandTotal: grandTotal,
    currency: currency,
    mechanicalUnpricedCount: mechanical.unpricedCount,
    electricalUnpricedCount: electrical.unmatchedCount,
    unpricedCount: mechanical.unpricedCount + electrical.unmatchedCount,
    sections: [
      QuoteSection('Mechanical material', mechMat),
      QuoteSection('Electrical material', elecMat),
      QuoteSection('Material', materialSubtotal),
      QuoteSection('Labour', labourSubtotal),
      QuoteSection('Overhead', overhead),
      QuoteSection('Contingency', contingency),
      QuoteSection('Margin', margin),
    ],
  );
}

// ── exports (pure string builders) ────────────────────────────────────────────

/// Escape a CSV cell.
String _csv(String v) {
  if (v.contains(',') || v.contains('"') || v.contains('\n')) {
    return '"${v.replaceAll('"', '""')}"';
  }
  return v;
}

/// Escape a Markdown table cell.
String _md(String v) => v.replaceAll('|', r'\|').replaceAll('\n', ' ');

/// Quantity without a trailing `.0` (whole → int, else 2 dp).
String _qty(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

/// Render the unified M+E+P bill of materials as CSV: a `discipline` column, one
/// row per mechanical line then one per electrical line, with the combined
/// material subtotal as a trailing row. Money cells are ungrouped + 2 dp
/// (spreadsheet-parseable); the two cut-plan columns are populated for mechanical
/// pipe runs only (empty otherwise — never invented).
String mepBomToCsv(MechCostEstimate mechanical, CostEstimate electrical) {
  final b = StringBuffer('discipline,qty,unit,category,description,key,'
      'unit_price,line_total,priced,stock_bars,waste_pct\n');
  for (final l in mechanical.lines) {
    b
      ..write('mechanical,')
      ..write(_qty(l.qty))
      ..write(',')
      ..write(l.unit)
      ..write(',')
      ..write(l.category.name)
      ..write(',')
      ..write(_csv(l.description))
      ..write(',')
      ..write(_csv(l.key))
      ..write(',')
      ..write(l.unitPrice == null ? '' : l.unitPrice!.toStringAsFixed(2))
      ..write(',')
      ..write(l.lineTotal == null ? '' : l.lineTotal!.toStringAsFixed(2))
      ..write(',')
      ..write(l.priced ? 'yes' : 'no')
      ..write(',')
      ..write(l.stockBars?.toString() ?? '')
      ..write(',')
      ..write(l.wastePercent == null ? '' : l.wastePercent!.toStringAsFixed(1))
      ..write('\n');
  }
  for (final l in electrical.lines) {
    b
      ..write('electrical,')
      ..write(_qty(l.line.qty))
      ..write(',,') // electrical unit unknown at this layer
      ..write(_csv(l.line.category.name))
      ..write(',')
      ..write(_csv(l.line.description))
      ..write(',')
      ..write(_csv(l.line.sku ?? ''))
      ..write(',')
      ..write(l.unitPrice == null ? '' : l.unitPrice!.toStringAsFixed(2))
      ..write(',')
      ..write(l.lineTotal == null ? '' : l.lineTotal!.toStringAsFixed(2))
      ..write(',')
      ..write(l.matched ? 'yes' : 'no')
      ..write(',,\n');
  }
  final total = _round2(mechanical.grandTotal + electrical.grandTotal);
  b
    ..write(_csv('Material subtotal (${electrical.currency})'))
    ..write(',,,,,,,')
    ..write(total.toStringAsFixed(2))
    ..write(',,,\n');
  return b.toString();
}

/// Render the unified M+E+P proposal as Markdown: a mechanical BOM table (when
/// present), an electrical BOM table (when present), then the combined costed
/// roll-up (per-discipline material subtotals · labour · overhead · contingency
/// · margin · grand total) and any unpriced-line notes.
String mepQuotationToMarkdown(
  MepQuotation quotation, {
  required MechCostEstimate mechanical,
  required CostEstimate electrical,
  String projectName = 'Project',
}) {
  final cur = quotation.currency;
  String m(double v) => money(v, dp: 2);
  final b = StringBuffer()
    ..writeln('# MEP proposal — $projectName')
    ..writeln();

  if (mechanical.lines.isNotEmpty) {
    b
      ..writeln('## Mechanical bill of materials')
      ..writeln()
      ..writeln('| Qty | Unit | Item | Unit ($cur) | Total ($cur) |')
      ..writeln('| ---: | --- | --- | ---: | ---: |');
    for (final l in mechanical.lines) {
      b.writeln('| ${_qty(l.qty)} | ${l.unit} | ${_md(l.description)} | '
          '${l.unitPrice == null ? '-' : m(l.unitPrice!)} | '
          '${l.lineTotal == null ? '(unpriced)' : m(l.lineTotal!)} |');
    }
    b.writeln();
  }

  if (electrical.lines.isNotEmpty) {
    b
      ..writeln('## Electrical bill of materials')
      ..writeln()
      ..writeln('| Qty | Category | Description | SKU | Unit ($cur) | Total ($cur) |')
      ..writeln('| ---: | --- | --- | --- | ---: | ---: |');
    for (final l in electrical.lines) {
      b.writeln('| ${_qty(l.line.qty)} | ${l.line.category.name} | '
          '${_md(l.line.description)} | ${_md(l.line.sku ?? '-')} | '
          '${l.unitPrice == null ? '-' : m(l.unitPrice!)} | '
          '${l.lineTotal == null ? '(unpriced)' : m(l.lineTotal!)} |');
    }
    b.writeln();
  }

  b
    ..writeln('## Quotation')
    ..writeln()
    ..writeln('| Item | Amount ($cur) |')
    ..writeln('| --- | ---: |')
    ..writeln('| Mechanical material | ${m(quotation.mechanicalMaterial)} |')
    ..writeln('| Electrical material | ${m(quotation.electricalMaterial)} |')
    ..writeln('| Material subtotal | ${m(quotation.materialSubtotal)} |')
    ..writeln('| Labour (${_qty(quotation.labourHours)} h) | '
        '${m(quotation.labourSubtotal)} |')
    ..writeln('| Overhead | ${m(quotation.overhead)} |')
    ..writeln('| Contingency | ${m(quotation.contingency)} |')
    ..writeln('| Margin | ${m(quotation.margin)} |')
    ..writeln('| **Grand total** | **${m(quotation.grandTotal)}** |');

  if (quotation.unpricedCount > 0) {
    b
      ..writeln()
      ..writeln('> ${quotation.unpricedCount} line(s) are unpriced (no price in '
          'the pricelist) and are excluded from the material subtotal '
          '(${quotation.mechanicalUnpricedCount} mechanical, '
          '${quotation.electricalUnpricedCount} electrical).');
  }
  return b.toString();
}
