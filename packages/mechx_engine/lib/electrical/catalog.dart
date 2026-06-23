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
/// DATA-ENTRY FOLLOW-UP: this seed is deliberately tiny. PanelMaker ships a
/// ~492-part multi-brand dataset (Schneider, Mitsubishi, LS, ABB, Legrand,
/// Chint + generic cables). Porting that full dataset (every code transcribed,
/// never pattern-generated) is a separate data-entry task — DO NOT machine-
/// generate part numbers to pad this list.
/// ─────────────────────────────────────────────────────────────────────────
///
/// Prices are NOT baked in here — a pricelist (sku → unit price) is a separate
/// concern (see `costing.dart`), so the committed catalogue stays price-free.
///
/// Zero Flutter imports.
library;

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
