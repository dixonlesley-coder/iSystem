/// Manufacturer parts catalogue — the commercial layer's part dataset.
///
/// A [Part] is a single orderable line item (an order code + descriptive
/// attributes). [seedCatalog] is a SMALL set of REAL, verified parts so the BOM
/// matcher and costing have something to bind to out of the box: a handful of
/// Schneider Acti9 iC60N MCBs, ComPacT NSX MCCBs, and the generic Indonesian
/// (SNI) cable ladder.
///
/// ─────────────────────────────────────────────────────────────────────────
/// // VERIFY every order code against the manufacturer datasheet before
/// // ordering. Codes/ratings here were transcribed individually from
/// // manufacturer product-page titles (se.com for Schneider) — they are
/// // convenience references, NOT a substitute for the datasheet.
///
/// DATA-ENTRY FOLLOW-UP — DONE: [seedCatalog] stays a deliberately tiny set of
/// hand-pinned parts (the BOM-matcher tests bind to its exact SKUs), but the
/// FULL multi-brand dataset PanelMaker ships is now ported verbatim under
/// `catalog_data/` (Schneider, Mitsubishi, LS, ABB, Legrand, Chint + generic
/// cables — every code transcribed by a human in PanelMaker, NEVER pattern-
/// generated). [fullCatalog] parses + merges them; [catalogIssues] mirrors
/// PanelMaker's validation gate. The matchers below operate on whatever parts
/// list is passed, so callers choose [seedCatalog] (default) or [fullCatalog].
/// ─────────────────────────────────────────────────────────────────────────
///
/// Prices are NOT baked in here — a pricelist (sku → unit price) is a separate
/// concern (see `costing.dart`), so the committed catalogue stays price-free
/// (the ported datasets carry no price field, exactly as PanelMaker commits).
///
/// Zero Flutter imports.
library;

import 'dart:convert' show jsonDecode;

import 'catalog_data/abb.dart' as abb;
import 'catalog_data/cables.dart' as cables;
import 'catalog_data/chint.dart' as chint;
import 'catalog_data/legrand.dart' as legrand;
import 'catalog_data/ls.dart' as ls;
import 'catalog_data/mitsubishi.dart' as mitsubishi;
import 'catalog_data/schneider.dart' as schneider;

/// Coarse classification of a catalogue part, mirroring PanelMaker's
/// `Part.category` for the line items this commercial layer emits.
enum PartCategory {
  breaker,
  cable,
  rcd,
  busbar,
  enclosure,
  accessory,
}

/// A single orderable catalogue part.
///
/// [attributes] is an open string→dynamic bag of the discriminating spec used
/// by the matchers, e.g. for a breaker `{ratingA, poles, curve, deviceClass,
/// breakingKa}`; for a cable `{csaMm2, type, conductor}`. Keeping it open lets
/// new brands carry brand-specific fields without changing this type — exactly
/// the shape PanelMaker's JSON parts use.
class Part {
  /// Manufacturer order code / catalogue number (e.g. `A9F44116`). Unique key.
  final String sku;

  /// Brand (e.g. `Schneider Electric`, or `Generic` for unbranded cable refs).
  final String manufacturer;

  final PartCategory category;

  /// Product family / series, for display (e.g. `Acti9 iC60N`).
  final String series;

  /// Human-readable model description (e.g. `iC60N 1P C16`).
  final String model;

  /// Selling unit — `'ea'` for a device, `'m'` for cable sold per metre.
  final String unit;

  /// Discriminating spec read by the matchers (see class doc).
  final Map<String, Object?> attributes;

  const Part({
    required this.sku,
    required this.manufacturer,
    required this.category,
    required this.series,
    required this.model,
    required this.attributes,
    this.unit = 'ea',
  });

  /// Typed attribute accessors (null when absent or of the wrong type).
  double? get ratingA => _asNum(attributes['ratingA']);
  int? get poles => _asNum(attributes['poles'])?.toInt();
  String? get curve => attributes['curve'] as String?;
  String? get deviceClass => attributes['deviceClass'] as String?;
  double? get csaMm2 => _asNum(attributes['csaMm2']);
  String? get cableType => attributes['type'] as String?;

  static double? _asNum(Object? v) => v is num ? v.toDouble() : null;
}

/// A small SEED of REAL, verified parts. // VERIFY each against the datasheet.
///
/// Breakers: Schneider Acti9 iC60N MCBs (1P/3P, C-curve, 6 kA Icn) + ComPacT
/// NSX100F/160F/250F TMD MCCBs (3P, 36 kA). Cables: the generic Indonesian
/// (SNI) NYY copper ladder + a couple of NYM. Codes/ratings transcribed from
/// se.com product-page titles and standard SNI cable constructions — they
/// match the entries in PanelMaker's committed catalogue.
const List<Part> seedCatalog = [
  // ── Schneider Acti9 iC60N MCBs — 1-pole, C-curve, 6 kA Icn ────────────────
  // // VERIFY: se.com Acti9 iC60 range (A9F44xxx). 1P Cxx.
  Part(
    sku: 'A9F44106',
    manufacturer: 'Schneider Electric',
    category: PartCategory.breaker,
    series: 'Acti9 iC60N',
    model: 'iC60N 1P C6',
    attributes: {'ratingA': 6, 'poles': 1, 'curve': 'C', 'deviceClass': 'MCB', 'breakingKa': 6},
  ),
  Part(
    sku: 'A9F44110',
    manufacturer: 'Schneider Electric',
    category: PartCategory.breaker,
    series: 'Acti9 iC60N',
    model: 'iC60N 1P C10',
    attributes: {'ratingA': 10, 'poles': 1, 'curve': 'C', 'deviceClass': 'MCB', 'breakingKa': 6},
  ),
  Part(
    sku: 'A9F44116',
    manufacturer: 'Schneider Electric',
    category: PartCategory.breaker,
    series: 'Acti9 iC60N',
    model: 'iC60N 1P C16',
    attributes: {'ratingA': 16, 'poles': 1, 'curve': 'C', 'deviceClass': 'MCB', 'breakingKa': 6},
  ),
  Part(
    sku: 'A9F44120',
    manufacturer: 'Schneider Electric',
    category: PartCategory.breaker,
    series: 'Acti9 iC60N',
    model: 'iC60N 1P C20',
    attributes: {'ratingA': 20, 'poles': 1, 'curve': 'C', 'deviceClass': 'MCB', 'breakingKa': 6},
  ),
  Part(
    sku: 'A9F44125',
    manufacturer: 'Schneider Electric',
    category: PartCategory.breaker,
    series: 'Acti9 iC60N',
    model: 'iC60N 1P C25',
    attributes: {'ratingA': 25, 'poles': 1, 'curve': 'C', 'deviceClass': 'MCB', 'breakingKa': 6},
  ),
  Part(
    sku: 'A9F44132',
    manufacturer: 'Schneider Electric',
    category: PartCategory.breaker,
    series: 'Acti9 iC60N',
    model: 'iC60N 1P C32',
    attributes: {'ratingA': 32, 'poles': 1, 'curve': 'C', 'deviceClass': 'MCB', 'breakingKa': 6},
  ),
  Part(
    sku: 'A9F44163',
    manufacturer: 'Schneider Electric',
    category: PartCategory.breaker,
    series: 'Acti9 iC60N',
    model: 'iC60N 1P C63',
    attributes: {'ratingA': 63, 'poles': 1, 'curve': 'C', 'deviceClass': 'MCB', 'breakingKa': 6},
  ),
  // ── Schneider Acti9 iC60N MCBs — 3-pole, C-curve, 6 kA Icn ────────────────
  // // VERIFY: se.com A9F443xx (3P Cxx).
  Part(
    sku: 'A9F44316',
    manufacturer: 'Schneider Electric',
    category: PartCategory.breaker,
    series: 'Acti9 iC60N',
    model: 'iC60N 3P C16',
    attributes: {'ratingA': 16, 'poles': 3, 'curve': 'C', 'deviceClass': 'MCB', 'breakingKa': 6},
  ),
  Part(
    sku: 'A9F44325',
    manufacturer: 'Schneider Electric',
    category: PartCategory.breaker,
    series: 'Acti9 iC60N',
    model: 'iC60N 3P C25',
    attributes: {'ratingA': 25, 'poles': 3, 'curve': 'C', 'deviceClass': 'MCB', 'breakingKa': 6},
  ),
  Part(
    sku: 'A9F44332',
    manufacturer: 'Schneider Electric',
    category: PartCategory.breaker,
    series: 'Acti9 iC60N',
    model: 'iC60N 3P C32',
    attributes: {'ratingA': 32, 'poles': 3, 'curve': 'C', 'deviceClass': 'MCB', 'breakingKa': 6},
  ),
  Part(
    sku: 'A9F44363',
    manufacturer: 'Schneider Electric',
    category: PartCategory.breaker,
    series: 'Acti9 iC60N',
    model: 'iC60N 3P C63',
    attributes: {'ratingA': 63, 'poles': 3, 'curve': 'C', 'deviceClass': 'MCB', 'breakingKa': 6},
  ),
  // ── Schneider ComPacT NSX TMD MCCBs — 3-pole, 36 kA Icu ───────────────────
  // // VERIFY: se.com ComPacT/Compact NSX100F-160F-250F TMD (LV42963x / LV43x630).
  Part(
    sku: 'LV429630',
    manufacturer: 'Schneider Electric',
    category: PartCategory.breaker,
    series: 'ComPacT NSX100F',
    model: 'NSX100F TMD 100A 3P3d',
    attributes: {'ratingA': 100, 'poles': 3, 'deviceClass': 'MCCB', 'tripUnit': 'TMD', 'breakingKa': 36},
  ),
  Part(
    sku: 'LV430630',
    manufacturer: 'Schneider Electric',
    category: PartCategory.breaker,
    series: 'ComPacT NSX160F',
    model: 'NSX160F TMD 160A 3P3d',
    attributes: {'ratingA': 160, 'poles': 3, 'deviceClass': 'MCCB', 'tripUnit': 'TMD', 'breakingKa': 36},
  ),
  Part(
    sku: 'LV431630',
    manufacturer: 'Schneider Electric',
    category: PartCategory.breaker,
    series: 'ComPacT NSX250F',
    model: 'NSX250F TMD 250A 3P3d',
    attributes: {'ratingA': 250, 'poles': 3, 'deviceClass': 'MCCB', 'tripUnit': 'TMD', 'breakingKa': 36},
  ),

  // ── Generic SNI cables — NYY 0.6/1 kV copper ladder ───────────────────────
  // // VERIFY: standard SNI/IEC NYY constructions; substitute a maker (Supreme,
  // // Kabelindo, Jembo, Voksel, …) and check KHA/derating against PUIL 2011.
  Part(
    sku: 'NYY-1.5',
    manufacturer: 'Generic',
    category: PartCategory.cable,
    series: 'NYY 0.6/1kV',
    model: 'NYY 1.5 mm² Cu',
    unit: 'm',
    attributes: {'csaMm2': 1.5, 'type': 'NYY', 'conductor': 'Cu', 'voltageRating': '0.6/1 kV'},
  ),
  Part(
    sku: 'NYY-2.5',
    manufacturer: 'Generic',
    category: PartCategory.cable,
    series: 'NYY 0.6/1kV',
    model: 'NYY 2.5 mm² Cu',
    unit: 'm',
    attributes: {'csaMm2': 2.5, 'type': 'NYY', 'conductor': 'Cu', 'voltageRating': '0.6/1 kV'},
  ),
  Part(
    sku: 'NYY-4',
    manufacturer: 'Generic',
    category: PartCategory.cable,
    series: 'NYY 0.6/1kV',
    model: 'NYY 4 mm² Cu',
    unit: 'm',
    attributes: {'csaMm2': 4, 'type': 'NYY', 'conductor': 'Cu', 'voltageRating': '0.6/1 kV'},
  ),
  Part(
    sku: 'NYY-6',
    manufacturer: 'Generic',
    category: PartCategory.cable,
    series: 'NYY 0.6/1kV',
    model: 'NYY 6 mm² Cu',
    unit: 'm',
    attributes: {'csaMm2': 6, 'type': 'NYY', 'conductor': 'Cu', 'voltageRating': '0.6/1 kV'},
  ),
  Part(
    sku: 'NYY-10',
    manufacturer: 'Generic',
    category: PartCategory.cable,
    series: 'NYY 0.6/1kV',
    model: 'NYY 10 mm² Cu',
    unit: 'm',
    attributes: {'csaMm2': 10, 'type': 'NYY', 'conductor': 'Cu', 'voltageRating': '0.6/1 kV'},
  ),
  Part(
    sku: 'NYY-16',
    manufacturer: 'Generic',
    category: PartCategory.cable,
    series: 'NYY 0.6/1kV',
    model: 'NYY 16 mm² Cu',
    unit: 'm',
    attributes: {'csaMm2': 16, 'type': 'NYY', 'conductor': 'Cu', 'voltageRating': '0.6/1 kV'},
  ),
  Part(
    sku: 'NYY-25',
    manufacturer: 'Generic',
    category: PartCategory.cable,
    series: 'NYY 0.6/1kV',
    model: 'NYY 25 mm² Cu',
    unit: 'm',
    attributes: {'csaMm2': 25, 'type': 'NYY', 'conductor': 'Cu', 'voltageRating': '0.6/1 kV'},
  ),
  Part(
    sku: 'NYY-35',
    manufacturer: 'Generic',
    category: PartCategory.cable,
    series: 'NYY 0.6/1kV',
    model: 'NYY 35 mm² Cu',
    unit: 'm',
    attributes: {'csaMm2': 35, 'type': 'NYY', 'conductor': 'Cu', 'voltageRating': '0.6/1 kV'},
  ),
  Part(
    sku: 'NYY-50',
    manufacturer: 'Generic',
    category: PartCategory.cable,
    series: 'NYY 0.6/1kV',
    model: 'NYY 50 mm² Cu',
    unit: 'm',
    attributes: {'csaMm2': 50, 'type': 'NYY', 'conductor': 'Cu', 'voltageRating': '0.6/1 kV'},
  ),
  // ── Generic SNI cables — NYM 300/500 V sheathed indoor (a couple) ─────────
  // // VERIFY: standard SNI NYM constructions (final-circuit wiring).
  Part(
    sku: 'NYM-1.5',
    manufacturer: 'Generic',
    category: PartCategory.cable,
    series: 'NYM 300/500V',
    model: 'NYM 1.5 mm² Cu',
    unit: 'm',
    attributes: {'csaMm2': 1.5, 'type': 'NYM', 'conductor': 'Cu', 'voltageRating': '300/500 V'},
  ),
  Part(
    sku: 'NYM-2.5',
    manufacturer: 'Generic',
    category: PartCategory.cable,
    series: 'NYM 300/500V',
    model: 'NYM 2.5 mm² Cu',
    unit: 'm',
    attributes: {'csaMm2': 2.5, 'type': 'NYM', 'conductor': 'Cu', 'voltageRating': '300/500 V'},
  ),
];

// ── Full multi-brand catalogue (ported verbatim from PanelMaker) ─────────────
//
// PanelMaker keeps a richer `PartCategory` union (~40 values) than this engine's
// six-value [PartCategory] enum. We map the JSON `category` string to the
// closest engine enum — the matchers only care about `breaker`/`cable`, and both
// map 1:1 — and preserve the ORIGINAL PanelMaker category verbatim in
// `attributes['partCategory']` so no classification is lost. Everything outside
// {breaker, cable, busbar, enclosure} (contactor, overload_relay, switch,
// current_transformer, control_protection, indicator_lamp, timer_relay,
// pilot_device, …) folds onto [PartCategory.accessory] — the catch-all that
// already carries un-priced auxiliary gear in the BOM.
const Map<String, PartCategory> _categoryMap = {
  'breaker': PartCategory.breaker,
  'cable': PartCategory.cable,
  'busbar': PartCategory.busbar,
  'enclosure': PartCategory.enclosure,
};

/// The full set of PanelMaker part categories accepted as valid (mirrors
/// `PART_CATEGORIES` in PanelMaker `types/parts.ts`). A JSON row whose category
/// is outside this set is rejected (recorded as a [CatalogIssue]); a row whose
/// category is valid but unmodelled by [PartCategory] folds to `accessory`.
const Set<String> knownPartCategories = {
  // power
  'breaker', 'cable', 'busbar', 'enclosure', 'accessory',
  // final-circuit points & switching
  'light_fixture', 'switch', 'smart_switch', 'socket_outlet',
  // control
  'contactor', 'overload_relay', 'control_relay', 'timer_relay',
  'phase_protection_relay', 'pilot_device', 'indicator_lamp',
  'control_transformer', 'control_protection', 'vfd', 'soft_starter',
  'vfd_accessory', 'aux_contact_block', 'terminal_block',
  // metering
  'panel_meter', 'current_transformer',
  // level / pump
  'level_relay', 'float_switch', 'electrode_assembly', 'pressure_switch',
  'pressure_transmitter', 'level_sensor', 'alternator_relay', 'hoa_selector',
  'run_hour_meter', 'alarm_device',
};

/// One catalogue dataset embedded verbatim from PanelMaker: the brand label that
/// stamps `Part.manufacturer` and the raw JSON text (parsed lazily on first use).
class _CatalogSource {
  final String brand;
  final String json;
  const _CatalogSource(this.brand, this.json);
}

/// The registry of embedded brand datasets, in PanelMaker's `CATALOG_SOURCES`
/// order (Schneider first for back-compat). Adding a brand = one embedded data
/// file + one line here.
const List<_CatalogSource> _catalogSources = [
  _CatalogSource(schneider.schneiderCatalogBrand, schneider.schneiderCatalogJson),
  _CatalogSource(mitsubishi.mitsubishiCatalogBrand, mitsubishi.mitsubishiCatalogJson),
  _CatalogSource(ls.lsCatalogBrand, ls.lsCatalogJson),
  _CatalogSource(abb.abbCatalogBrand, abb.abbCatalogJson),
  _CatalogSource(legrand.legrandCatalogBrand, legrand.legrandCatalogJson),
  _CatalogSource(chint.chintCatalogBrand, chint.chintCatalogJson),
  _CatalogSource(cables.cablesCatalogBrand, cables.cablesCatalogJson),
];

/// A catalogue row that failed validation, with the reason (surfaced by tests),
/// mirroring PanelMaker's `CatalogIssue`.
class CatalogIssue {
  final String brand;
  final int index;
  final String sku;
  final String reason;
  const CatalogIssue({
    required this.brand,
    required this.index,
    required this.sku,
    required this.reason,
  });

  @override
  String toString() => '[$brand #$index "$sku"] $reason';
}

bool _isPositiveNum(Object? v) => v is num && v > 0;

/// Validate + project ONE brand dataset's JSON onto [Part]s, mirroring
/// PanelMaker `loadCatalog`. A row that fails validation is skipped and recorded
/// in [issues] (so a bad row can never crash the engine, while the test asserts
/// [issues] is empty so a bad row can never be committed). De-dup of SKUs across
/// brands happens in the merge ([fullCatalog]); here `seen` guards intra-file dups.
List<Part> _loadBrand(
  _CatalogSource src,
  Set<String> seen,
  List<CatalogIssue> issues,
) {
  final parts = <Part>[];
  final decoded = jsonDecode(src.json);
  if (decoded is! Map || decoded['parts'] is! List) {
    issues.add(CatalogIssue(
        brand: src.brand, index: -1, sku: '', reason: 'malformed catalogue file'));
    return parts;
  }
  final rows = decoded['parts'] as List;
  for (var index = 0; index < rows.length; index++) {
    final raw = rows[index];
    void fail(String reason) => issues.add(CatalogIssue(
        brand: src.brand,
        index: index,
        sku: (raw is Map && raw['sku'] is String) ? raw['sku'] as String : '?',
        reason: reason));

    if (raw is! Map) {
      fail('row not an object');
      continue;
    }
    final sku = raw['sku'];
    if (sku is! String || sku.trim().isEmpty) {
      fail('missing sku');
      continue;
    }
    if (seen.contains(sku)) {
      fail('duplicate sku "$sku"');
      continue;
    }
    final catStr = raw['category'];
    if (catStr is! String || !knownPartCategories.contains(catStr)) {
      fail('unknown category "$catStr"');
      continue;
    }
    final model = raw['model'];
    if (model is! String || model.trim().isEmpty) {
      fail('missing model');
      continue;
    }
    final attrsRaw = raw['attributes'];
    if (attrsRaw is! Map) {
      fail('attributes not an object');
      continue;
    }
    final a = Map<String, Object?>.from(attrsRaw);
    if (a.containsKey('ratingA') && !_isPositiveNum(a['ratingA'])) {
      fail('ratingA must be a positive number');
      continue;
    }
    if (a.containsKey('poles') && !const [1, 2, 3, 4].contains(a['poles'])) {
      fail('poles must be 1-4 (got ${a['poles']})');
      continue;
    }
    if (a.containsKey('curve') && !const ['B', 'C', 'D'].contains(a['curve'])) {
      fail('curve must be B/C/D (got ${a['curve']})');
      continue;
    }
    if (a.containsKey('breakingKa') && !_isPositiveNum(a['breakingKa'])) {
      fail('breakingKa must be a positive number');
      continue;
    }

    seen.add(sku);
    final series = raw['series'] is String ? raw['series'] as String : model;
    final unit = raw['unit'] is String ? raw['unit'] as String : 'ea';
    // PanelMaker's per-row `manufacturer` override falls back to the brand.
    final manufacturer =
        raw['manufacturer'] is String ? raw['manufacturer'] as String : src.brand;
    parts.add(Part(
      sku: sku,
      manufacturer: manufacturer,
      // Engine enum is narrower than PanelMaker's union — fold the rest to
      // accessory, keeping the original string for callers that want it.
      category: _categoryMap[catStr] ?? PartCategory.accessory,
      series: series,
      model: model,
      unit: unit,
      attributes: {...a, 'partCategory': catStr},
    ));
  }
  return parts;
}

class _LoadedCatalog {
  final List<Part> parts;
  final List<CatalogIssue> issues;
  const _LoadedCatalog(this.parts, this.issues);
}

_LoadedCatalog? _cached;

_LoadedCatalog _loadAll() {
  final cached = _cached;
  if (cached != null) return cached;
  final seen = <String>{};
  final issues = <CatalogIssue>[];
  final parts = <Part>[];
  // First source wins on a cross-brand SKU clash (matches PanelMaker's merge).
  for (final src in _catalogSources) {
    parts.addAll(_loadBrand(src, seen, issues));
  }
  return _cached = _LoadedCatalog(parts, issues);
}

/// The brand labels declared by the embedded datasets, in registry order
/// (e.g. `Schneider`, `Mitsubishi Electric`, …, `Generic`). Distinct, order-
/// preserving.
List<String> get catalogBrands {
  final out = <String>[];
  for (final s in _catalogSources) {
    if (!out.contains(s.brand)) out.add(s.brand);
  }
  return out;
}

/// Every validated catalogue [Part] across ALL embedded brands, de-duplicated by
/// SKU (Schneider first, then the registry order; first source wins on a clash).
/// Parsed once and cached. This is the full ~534-part PanelMaker dataset.
///
/// // VERIFY each order code against the manufacturer datasheet before ordering.
List<Part> fullCatalog() => List<Part>.unmodifiable(_loadAll().parts);

/// Validation issues found while parsing the embedded datasets — asserted empty
/// by the catalogue test (so a malformed row can never be committed). Mirrors
/// PanelMaker's `CATALOG_ISSUES`.
List<CatalogIssue> get catalogIssues =>
    List<CatalogIssue>.unmodifiable(_loadAll().issues);

/// Narrow a parts list to a single manufacturer for order-code matching, while
/// keeping the generic standard items (cables, brand `Generic`) so cable runs
/// still match. A null/empty [brand] returns every part. Mirrors PanelMaker
/// `partsForBrand`.
List<Part> partsForBrand(List<Part> parts, String? brand) {
  if (brand == null || brand.isEmpty) return List<Part>.from(parts);
  return parts
      .where((p) => p.manufacturer == brand || p.manufacturer == 'Generic')
      .toList();
}
