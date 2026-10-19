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
import '../electrical/catalog.dart' show PartCategory;
import '../electrical/costing.dart';
import '../electrical/quotation.dart'
    show QuoteSection, defaultLabourRatePerHour, labourHoursForBom;
import '../network/network.dart';
import '../sizing/bom.dart';
import '../sizing/pipe_optimizer.dart';
import 'number_format.dart';
import 'report_strings.dart';

double _round2(double v) => (v * 100).roundToDouble() / 100;

// ── mechanical pricelist keys ─────────────────────────────────────────────────

/// Every mechanical pricelist key is prefixed with this so mechanical prices
/// coexist in the SAME `sku → price` map as the electrical catalogue codes
/// without ever colliding (an electrical SKU is a catalogue order code and
/// never starts with `mech:`). This lets the mechanical prices ride the
/// existing persisted `priceList` with no new `.mechx` field / version bump.
const String kMechPriceKeyPrefix = 'mech:';

/// The stable pricelist key for a mechanical pipe/duct line (per service, run vs
/// riser, MATERIAL and size). Human-stable so the pricelist survives edits.
///
/// With a [material] (and/or a rectangular [widthMm]×[heightMm]) the key is
/// `mech:pipe:<svc>:<kind>:<material>:<size>` where size is `WxH` for a
/// rectangular duct, else the nominal mm — so PPR and HDPE, or a PU and a BJLS
/// duct, price apart (audit r8; `sizing/bom.dart` already splits lines by
/// material and W×H). Without either the LEGACY key
/// `mech:pipe:<svc>:<kind>:<mm>` is returned, which [estimateMechanicalCost]
/// also reads as a fallback so a saved pricelist keeps applying.
String mechPipeKey(
  ServiceType service,
  EdgeKind kind,
  int diameterMm, {
  String material = '',
  int? widthMm,
  int? heightMm,
}) {
  final rect = widthMm != null && heightMm != null;
  if (material.isEmpty && !rect) {
    return '${kMechPriceKeyPrefix}pipe:${service.name}:${kind.name}:$diameterMm';
  }
  final size = rect ? '${widthMm}x$heightMm' : '$diameterMm';
  final mat = material.isEmpty ? '-' : material;
  return '${kMechPriceKeyPrefix}pipe:${service.name}:${kind.name}:$mat:$size';
}

/// The pricelist key a [BomLine] prices under (material + W×H aware).
String mechPipeKeyFor(BomLine p) => mechPipeKey(p.service, p.kind, p.diameterMm,
    material: p.material, widthMm: p.widthMm, heightMm: p.heightMm);

/// The stable pricelist key for a mechanical fitting line (per service, type,
/// MATERIAL and nominal DN in mm). Without a [material] the legacy
/// `mech:fitting:<svc>:<type>:<mm>` key is returned (also the read fallback).
///
/// Round 21 (bom-quote-6) — a RECTANGULAR duct fitting keys on its W×H
/// (`mech:fitting:<svc>:<type>:<mat>:<W>x<H>`), never the circular
/// equivalent.
String mechFittingKey(
  ServiceType service,
  FittingType type,
  int diameterMm, {
  String material = '',
  int? widthMm,
  int? heightMm,
}) {
  final rect = widthMm != null && heightMm != null;
  if (material.isEmpty && !rect) {
    return '${kMechPriceKeyPrefix}fitting:${service.name}:${type.name}:'
        '$diameterMm';
  }
  final size = rect ? '${widthMm}x$heightMm' : '$diameterMm';
  final mat = material.isEmpty ? '-' : material;
  return '${kMechPriceKeyPrefix}fitting:${service.name}:${type.name}:'
      '$mat:$size';
}

/// Round 21 (bom-quote-3) — the stable pricelist key for a drawn COMPONENT
/// (`mech:component:<svc>:<component>:<size>`, size '-' when unsized).
String mechComponentKey(
        ServiceType service, NodeComponent component, String sizeLabel) =>
    '${kMechPriceKeyPrefix}component:${service.name}:${component.name}:'
    '${sizeLabel.isEmpty ? '-' : sizeLabel}';

/// Round 30 (costing-2-1) — the stable pricelist key for a scheduled
/// EQUIPMENT item (`mech:equipment:<component>:<duty>`, duty '-' when none):
/// each duty prices apart, unpriced until the estimator prices it.
String mechEquipmentKey(NodeComponent component, String duty) =>
    '${kMechPriceKeyPrefix}equipment:${component.name}:'
    '${duty.isEmpty ? '-' : duty}';

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

/// The quotation description of a drawn [component] on [service]: the
/// service label then the component label, with a word the two share at the
/// seam said once ('Cold water' + 'Water outlet' -> 'Cold water outlet', not
/// 'Cold water Water outlet'). Pure.
String mechComponentDescription(ServiceType service, NodeComponent component) {
  final svc = mechServiceLabel(service);
  final comp = component.label;
  final svcWords = svc.split(' ');
  final compWords = comp.split(' ');
  if (compWords.length > 1 &&
      svcWords.last.toLowerCase() == compWords.first.toLowerCase()) {
    return '$svc ${compWords.skip(1).join(' ')}';
  }
  return '$svc $comp';
}

/// Whether a mechanical cost line is a length of pipe/duct, a fitting, or
/// (Round 21) a drawn component (valve, head, terminal, drain, damper).
enum MechItemCategory { pipe, fitting, component, equipment }

/// Round 30 (costing-2-6) — the suffix an ASSUMED (not drawn) line carries on
/// every surface (description, CSV, Markdown proposal).
const String kMechAssumedSuffix = ' (assumed recirculation return - not drawn)';

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

  /// Round 21 (bom-quote-2) — runs of this pipe/duct line on an UNCALIBRATED
  /// sheet: measured at 0 m, so [qty] (and the price) is understated. The
  /// description carries an 'unmeasured' note and the quotation a caveat.
  final int unmeasuredSegments;

  /// Round 30 (costing-2-6) — an ASSUMED piece the calculation relies on but
  /// the drawing does not hold (the HW recirculation return + its pump).
  final bool assumed;

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
    this.unmeasuredSegments = 0,
    this.assumed = false,
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

  /// Round 21 — lines carrying unmeasured runs (understated metres).
  int get unmeasuredLineCount =>
      lines.where((l) => l.unmeasuredSegments > 0).length;

  /// Round 30 — lines that are an assumption, not a drawn quantity.
  int get assumedLineCount => lines.where((l) => l.assumed).length;

  /// Round 30 — scheduled equipment lines (pumps, tanks, AHU …).
  int get equipmentLineCount =>
      lines.where((l) => l.category == MechItemCategory.equipment).length;

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
  // Round 21 (bom-quote-3) — the drawn components, priced per piece.
  List<ComponentLine> components = const [],
  // Round 30 (costing-2-1) — the drawn plant, priced per piece by duty.
  List<ComponentLine> equipment = const [],
  List<PipeCutGroup> cutPlan = const [],
  String currency = 'IDR',
}) {
  // Aggregate the cut plan by (service, DN, material) — the plan packs all runs
  // of a size AND material into shared stock bars (multiple stock lengths for
  // one key are summed). A PPR line must not show the PVC bars.
  final planByKey = <String, ({int bars, double purchased, double waste})>{};
  for (final g in cutPlan) {
    final k = '${g.service.name}:${g.diameterMm}:${g.material}';
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
    String? legacyKey,
    required String description,
    required MechItemCategory category,
    required ServiceType service,
    required double qty,
    required String unit,
    int? stockBars,
    double? wastePercent,
    int unmeasuredSegments = 0,
    bool assumed = false,
  }) {
    // Read-time fallback to the legacy (material-less) key so a pricelist
    // saved before the material split still applies (no version bump).
    final unitPrice =
        priceList[key] ?? (legacyKey == null ? null : priceList[legacyKey]);
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
        unmeasuredSegments: unmeasuredSegments,
        assumed: assumed,
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
      unmeasuredSegments: unmeasuredSegments,
      assumed: assumed,
    ));
  }

  for (final p in pipes) {
    final noun = p.service.isAir ? 'duct' : 'pipe';
    final kindWord = p.kind == EdgeKind.riser ? '$noun riser' : noun;
    // Join on the line's own material; a hand-built group without a material
    // ('') still joins on (service, DN) as before.
    // Round 30 (costing-2-6) — an ASSUMED line (the undrawn recirculation
    // return) never inherits the DRAWN group's cut-plan bars: its metres are
    // in no cut plan, so a spreadsheet summing the column would double count.
    final plan = p.kind == EdgeKind.run && !p.assumed
        ? (planByKey['${p.service.name}:${p.diameterMm}:${p.material}'] ??
            planByKey['${p.service.name}:${p.diameterMm}:'])
        : null;
    priceLine(
      key: mechPipeKeyFor(p),
      legacyKey: mechPipeKey(p.service, p.kind, p.diameterMm),
      description: '${mechServiceLabel(p.service)} $kindWord ${p.sizeLabel}'
          '${p.material.isEmpty ? '' : ' ${p.material}'}'
          // Round 21 — never a measured-looking total over unmeasured runs.
          '${p.hasUnmeasured ? ' (${p.unmeasuredSegments} of '
              '${p.segmentCount} runs unmeasured - calibrate the sheet)' : ''}'
          '${p.assumed ? kMechAssumedSuffix : ''}',
      assumed: p.assumed,
      category: MechItemCategory.pipe,
      service: p.service,
      qty: _round2(p.totalLength.meters),
      unit: 'm',
      unmeasuredSegments: p.unmeasuredSegments,
      stockBars: plan?.bars,
      wastePercent: plan == null || plan.purchased <= 0
          ? null
          : _round2(100 * plan.waste / plan.purchased),
    );
  }

  for (final f in fittings) {
    final rect = f.widthMm != null && f.heightMm != null;
    priceLine(
      key: mechFittingKey(f.service, f.type, f.diameterMm,
          material: f.material, widthMm: f.widthMm, heightMm: f.heightMm),
      // A rectangular fitting has no legacy (equivalent-Ø) price to inherit.
      legacyKey: rect ? null : mechFittingKey(f.service, f.type, f.diameterMm),
      description: '${mechServiceLabel(f.service)} ${_fittingLabel(f.type)} '
          '${f.sizeLabel}${f.material.isEmpty ? '' : ' ${f.material}'}',
      category: MechItemCategory.fitting,
      service: f.service,
      qty: f.count.toDouble(),
      unit: 'ea',
    );
  }

  for (final c in components) {
    // Round 30 (costing-2-6) — an ASSUMED piece (the recirculation pump an
    // undrawn return relies on) keys on its component alone (its motor kW is
    // a design output: keying on it dropped the price on every small design
    // change) and says it is an assumption.
    priceLine(
      key: mechComponentKey(
          c.service, c.component, c.assumed ? '' : c.sizeLabel),
      description: '${mechComponentDescription(c.service, c.component)}'
          '${c.sizeLabel.isEmpty ? '' : ' ${c.sizeLabel}'}'
          '${c.assumed ? kMechAssumedSuffix : ''}',
      category: MechItemCategory.component,
      service: c.service,
      qty: c.count.toDouble(),
      unit: 'ea',
      assumed: c.assumed,
    );
  }

  for (final c in equipment) {
    priceLine(
      key: mechEquipmentKey(c.component, c.sizeLabel),
      description: '${mechComponentDescription(c.service, c.component)}'
          '${c.sizeLabel.isEmpty ? '' : ' ${c.sizeLabel}'}',
      category: MechItemCategory.equipment,
      service: c.service,
      qty: c.count.toDouble(),
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

/// Round 21 — install man-hours to set one drawn component (valve, head,
/// terminal, drain, damper). // VERIFY: a trade figure, not an SNI clause.
const double mechInstallHoursPerComponent = 0.5; // VERIFY

/// Round 30 (costing-2-1) — install man-hours to set, level, connect and
/// commission one piece of scheduled equipment (pump, tank, AHU / FCU, fan,
/// AC unit). // VERIFY: a trade figure, not an SNI clause.
const double mechInstallHoursPerEquipment = 4.0; // VERIFY

/// Total mechanical install man-hours implied by the pipe/duct lengths + the
/// fitting count. Air services use the (heavier) duct rate.
double mechanicalLabourHours({
  required List<BomLine> pipes,
  required List<FittingLine> fittings,
  List<ComponentLine> components = const [],
  List<ComponentLine> equipment = const [],
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
  for (final c in components) {
    h += c.count * mechInstallHoursPerComponent;
  }
  for (final c in equipment) {
    h += c.count * mechInstallHoursPerEquipment;
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
  List<ComponentLine> mechanicalComponents = const [],
  List<ComponentLine> mechanicalEquipment = const [],
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
    components: mechanicalComponents,
    equipment: mechanicalEquipment,
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
      ..write(',')
      // Round 30 (costing-2-5) — cable is bought by the metre, every other
      // electrical line per piece; the key is the one the line PRICED under.
      ..write(l.line.category == PartCategory.cable ? 'm' : 'ea')
      ..write(',')
      ..write(_csv(l.line.category.name))
      ..write(',')
      ..write(_csv(l.line.description))
      ..write(',')
      ..write(_csv(l.line.priceKey ?? l.line.sku ?? ''))
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
///
/// Round 30 (costing-2-7) — [strings] localizes the proposal (headings,
/// columns, roll-up rows, notes); the default English keeps every byte.
/// Round 30 (costing-2-1 / -6) — scheduled equipment and assumed lines carry
/// an explicit note, so the proposal never reads as complete while silently
/// omitting or inventing a quantity.
String mepQuotationToMarkdown(
  MepQuotation quotation, {
  required MechCostEstimate mechanical,
  required CostEstimate electrical,
  String projectName = 'Project',
  ReportStrings strings = const ReportStrings.en(),
}) {
  final s = strings;
  final cur = quotation.currency;
  String m(double v) => money(v, dp: 2);
  final unpriced = s(RptStringKey.mqUnpriced);
  final b = StringBuffer()
    ..writeln(s.format(RptStringKey.mqTitle, {'project': projectName}))
    ..writeln();

  if (mechanical.lines.isNotEmpty) {
    b
      ..writeln(s(RptStringKey.mqMechBom))
      ..writeln()
      ..writeln(s.format(RptStringKey.mqMechHead, {'cur': cur}))
      ..writeln('| ---: | --- | --- | ---: | ---: |');
    for (final l in mechanical.lines) {
      b.writeln('| ${quantity(l.qty)} | ${l.unit} | ${_md(l.description)} | '
          '${l.unitPrice == null ? '-' : m(l.unitPrice!)} | '
          '${l.lineTotal == null ? unpriced : m(l.lineTotal!)} |');
    }
    b.writeln();
  }

  if (electrical.lines.isNotEmpty) {
    b
      ..writeln(s(RptStringKey.mqElecBom))
      ..writeln()
      ..writeln(s.format(RptStringKey.mqElecHead, {'cur': cur}))
      ..writeln('| ---: | --- | --- | --- | ---: | ---: |');
    for (final l in electrical.lines) {
      b.writeln('| ${quantity(l.line.qty)} | ${l.line.category.name} | '
          '${_md(l.line.description)} | ${_md(l.line.sku ?? '-')} | '
          '${l.unitPrice == null ? '-' : m(l.unitPrice!)} | '
          '${l.lineTotal == null ? unpriced : m(l.lineTotal!)} |');
    }
    b.writeln();
  }

  b
    ..writeln(s(RptStringKey.mqQuotation))
    ..writeln()
    ..writeln(s.format(RptStringKey.mqQuoteHead, {'cur': cur}))
    ..writeln('| --- | ---: |')
    ..writeln('| ${s(RptStringKey.mqMechMaterial)} | '
        '${m(quotation.mechanicalMaterial)} |')
    ..writeln('| ${s(RptStringKey.mqElecMaterial)} | '
        '${m(quotation.electricalMaterial)} |')
    ..writeln('| ${s(RptStringKey.mqMaterialSubtotal)} | '
        '${m(quotation.materialSubtotal)} |')
    ..writeln('| ${s.format(RptStringKey.mqLabour, {
          'h': quantity(quotation.labourHours)
        })} | ${m(quotation.labourSubtotal)} |')
    ..writeln('| ${s(RptStringKey.mqOverhead)} | ${m(quotation.overhead)} |')
    ..writeln('| ${s(RptStringKey.mqContingency)} | '
        '${m(quotation.contingency)} |')
    ..writeln('| ${s(RptStringKey.mqMargin)} | ${m(quotation.margin)} |')
    ..writeln('| **${s(RptStringKey.mqGrandTotal)}** | '
        '**${m(quotation.grandTotal)}** |');

  // Round 21 (bom-quote-2) — runs on an uncalibrated sheet are in no total.
  if (mechanical.unmeasuredLineCount > 0) {
    b
      ..writeln()
      ..writeln(s.format(RptStringKey.mqUnmeasuredNote,
          {'n': mechanical.unmeasuredLineCount}));
  }
  if (mechanical.equipmentLineCount > 0) {
    b
      ..writeln()
      ..writeln(s.format(RptStringKey.mqEquipmentNote, {
        'n': mechanical.lines
            .where((l) => l.category == MechItemCategory.equipment)
            .fold<double>(0, (a, l) => a + l.qty)
            .round()
      }));
  }
  if (mechanical.assumedLineCount > 0) {
    b
      ..writeln()
      ..writeln(s.format(
          RptStringKey.mqAssumedNote, {'n': mechanical.assumedLineCount}));
  }
  if (quotation.unpricedCount > 0) {
    b
      ..writeln()
      ..writeln(s.format(RptStringKey.mqUnpricedNote, {
        'n': quotation.unpricedCount,
        'mech': quotation.mechanicalUnpricedCount,
        'elec': quotation.electricalUnpricedCount,
      }));
  }
  return b.toString();
}
