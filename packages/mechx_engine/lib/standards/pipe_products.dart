/// MEP **pipe products** catalog — product-level material data + nominal-size
/// ladder for the mechanical/plumbing canvas, where an engineer picks a pipe
/// product per segment.
///
/// This is a richer, *product-level* superset of the generic [PipeMaterial]
/// tier in `standards/sni.dart` (`pvc`, `hdpe`, …). Where `sni.dart` knows a
/// material family, this knows the actual product an Indonesian contractor
/// specifies on a riser diagram — **PPR PN10/16/20**, **PVC AW / D / JIS**,
/// **cast iron**, **acoustic PVC**, **HDPE** — each carrying its Hazen–Williams
/// C, Darcy–Weisbach roughness, a pressure (PN) rating where the product is
/// pressure-rated, and a regime suitability hint.
///
/// PROVENANCE POLICY (mirrors `sni.dart` / `puil.dart`, §12.6): the HW-C,
/// roughness and PN values are real engineering figures (manufacturer
/// catalogues — Wavin/Rucika/SD, plus the standard hydraulics references —
/// IEC/ASHRAE/Crane TP-410) but are **NOT confirmed verbatim against the
/// official SNI / product datasheet PDFs**, so every entry defaults to
/// **`secondarySource`** (or `notAnSniClause` for the general-practice NPS→mm
/// nominal mapping). **Nothing is `sniVerbatim`.** Every unverified value MUST
/// surface via [pipeProductsVerifyChecklist] in any report.
///
/// SI internally (guardrail §12.2): roughness via [Roughness], pressure ratings
/// via [Pressure]. Nominal sizes are quoted in **inches (NPS)** at the UI but
/// the engine carries millimetres; the inch↔mm conversion lives at this
/// boundary ([npsToMm] / [mmToNps]).
///
/// Zero Flutter imports.
library;

import '../units.dart';
import 'sni.dart' show StandardValue, VerificationStatus;

/// Hydraulic regime a pipe product is intended for — used as a UI/sizing hint
/// so the canvas can offer drainage products on a gravity segment and
/// pressure-rated products on a pumped/pressurized one. (The sizing dispatcher
/// still routes by `ServiceType.regime`; this is only a product-suitability
/// hint, not a re-implementation of that routing — guardrail §12.4.)
enum PipeRegime {
  /// Pressurized supply (pumped / mains / boosted) — needs a PN rating.
  pressurized,

  /// Gravity drainage / vent / soil — unpressurized, sized by slope + DFU.
  gravity,

  /// Suitable for either (the product is pressure-rated yet also commonly used
  /// on non-pressure duties).
  both,
}

/// A pipe **product** an engineer specifies per segment. A product-level
/// superset of the generic `PipeMaterial` family in `sni.dart`.
enum PipeProduct {
  /// Polypropylene-random PN10 (≤10 bar) — low-pressure hot/cold supply.
  pprPn10,

  /// Polypropylene-random PN16 (≤16 bar) — the common building-supply grade.
  pprPn16,

  /// Polypropylene-random PN20 (≤20 bar) — risers / high-pressure hot supply.
  pprPn20,

  /// PVC class AW — the Indonesian *pressure*-rated PVC (≈10 kgf/cm² class),
  /// the workhorse cold-water supply pipe.
  pvcAw,

  /// PVC class D — the thinner *drainage* grade (≈5 kgf/cm² class), soil/waste.
  pvcD,

  /// PVC to JIS K-6741 (Japanese-standard PVC) — general drainage / low
  /// pressure; thinner-walled than AW.
  pvcJis,

  /// Cast iron (SML / hubless) — soil & waste stacks; rougher, lower HW-C.
  castIron,

  /// Acoustic (silencer / low-noise) PVC — mineral-filled drainage pipe; same
  /// hydraulics as PVC drainage, specified for noise.
  acousticPvc,

  /// High-density polyethylene (PE100) — buried mains / pressure; very smooth.
  hdpe,
}

/// Per-product engineering data (the catalog row).
class PipeProductSpec {
  /// Human-readable label for the UI/BOM.
  final String label;

  /// Hazen–Williams roughness coefficient C (dimensionless) for pressurized
  /// friction. Higher = smoother. Plastics ≈150; cast iron lower.
  final double hazenWilliamsC;

  /// Absolute wall roughness ε for Darcy–Weisbach / Colebrook (SI, via
  /// [Roughness]).
  final Roughness roughness;

  /// Nominal pressure (PN) rating where the product is pressure-rated; `null`
  /// for gravity-only products (drainage PVC, cast iron soil, acoustic PVC).
  final Pressure? pressureRating;

  /// Regime suitability hint (see [PipeRegime]).
  final PipeRegime regime;

  /// Provenance note — the honesty surface for this row (mirrors
  /// `StandardValue.note`).
  final String note;

  /// Provenance tier — `secondarySource` for catalogue/handbook figures,
  /// `notAnSniClause` for general practice.
  final VerificationStatus status;

  const PipeProductSpec({
    required this.label,
    required this.hazenWilliamsC,
    required this.roughness,
    required this.pressureRating,
    required this.regime,
    required this.note,
    this.status = VerificationStatus.secondarySource,
  });
}

// Common roughness anchors (SI, metres). Smooth plastic ε ≈ 0.0015 mm
// (1.5 µm) — the value `sni.dart` uses for pvc/hdpe/copper; cast iron
// (uncoated/aged) ε ≈ 0.25 mm (the Crane TP-410 / Moody cast-iron band).
const Roughness _epsSmoothPlastic = Roughness(1.5e-6); // 0.0015 mm
const Roughness _epsCastIron = Roughness(2.5e-4); // 0.25 mm

/// The catalog. A `static final` map (not `const`) only because the values are
/// `const` already — kept as a top-level lookup so [hazenWilliamsCFor] etc. are
/// trivial reads.
///
// VERIFY: HW-C / roughness / PN figures are manufacturer-catalogue & standard
// hydraulics-handbook values (Wavin/Rucika PPR & PVC catalogues, Crane TP-410 /
// ASHRAE roughness bands), NOT confirmed verbatim against the official product
// datasheet or SNI PDFs. Confirm before a submission.
final Map<PipeProduct, PipeProductSpec> pipeProductSpecs = {
  PipeProduct.pprPn10: const PipeProductSpec(
    label: 'PPR PN10',
    hazenWilliamsC: 150, // smooth plastic
    roughness: _epsSmoothPlastic,
    pressureRating: Pressure(1.0e6), // 10 bar = PN10
    regime: PipeRegime.pressurized,
    note: 'PPR-R PN10 (≤10 bar) low-pressure hot/cold supply. HW-C≈150, '
        'ε≈0.0015 mm (smooth plastic). VERIFY PN/temperature derating against '
        'the PPR catalogue (PN drops with sustained hot-water temperature).',
  ),
  PipeProduct.pprPn16: const PipeProductSpec(
    label: 'PPR PN16',
    hazenWilliamsC: 150,
    roughness: _epsSmoothPlastic,
    pressureRating: Pressure(1.6e6), // 16 bar = PN16
    regime: PipeRegime.pressurized,
    note: 'PPR-R PN16 (≤16 bar) common building-supply grade. HW-C≈150, '
        'ε≈0.0015 mm. VERIFY against PPR catalogue.',
  ),
  PipeProduct.pprPn20: const PipeProductSpec(
    label: 'PPR PN20',
    hazenWilliamsC: 150,
    roughness: _epsSmoothPlastic,
    pressureRating: Pressure(2.0e6), // 20 bar = PN20
    regime: PipeRegime.pressurized,
    note: 'PPR-R PN20 (≤20 bar) risers / high-pressure hot supply. HW-C≈150, '
        'ε≈0.0015 mm. VERIFY against PPR catalogue.',
  ),
  PipeProduct.pvcAw: const PipeProductSpec(
    label: 'PVC AW (pressure)',
    hazenWilliamsC: 150,
    roughness: _epsSmoothPlastic,
    // Class AW ≈ 10 kgf/cm² working class. 10 kgf/cm² = 980 665 Pa ≈ 9.8 bar.
    pressureRating: Pressure(980665.0),
    regime: PipeRegime.pressurized,
    note: 'PVC class AW — Indonesian pressure-rated PVC (≈10 kgf/cm² ≈ 9.8 bar) '
        'cold-water supply workhorse. HW-C≈150, ε≈0.0015 mm. VERIFY the AW '
        'pressure class against SNI 06-0084 / the PVC catalogue.',
  ),
  PipeProduct.pvcD: const PipeProductSpec(
    label: 'PVC D (drainage)',
    hazenWilliamsC: 150, // same smooth bore; used on gravity drainage
    roughness: _epsSmoothPlastic,
    pressureRating: null, // drainage grade — not pressure-rated
    regime: PipeRegime.gravity,
    note: 'PVC class D — thin-wall drainage/soil grade (≈5 kgf/cm² class, sized '
        'as gravity, not pressure). HW-C≈150, ε≈0.0015 mm. No working PN '
        'assigned (drainage). VERIFY the D class against SNI 06-0084.',
  ),
  PipeProduct.pvcJis: const PipeProductSpec(
    label: 'PVC JIS K-6741',
    hazenWilliamsC: 150,
    roughness: _epsSmoothPlastic,
    pressureRating: null, // general drainage / low pressure
    regime: PipeRegime.gravity,
    note: 'PVC to JIS K-6741 — general drainage / low-pressure grade, thinner '
        'than AW. HW-C≈150, ε≈0.0015 mm. No working PN assigned. VERIFY '
        'against JIS K-6741.',
  ),
  PipeProduct.castIron: const PipeProductSpec(
    label: 'Cast iron (SML)',
    hazenWilliamsC: 110, // rougher / aged cast iron, lower than plastic 150
    roughness: _epsCastIron, // ε≈0.25 mm
    pressureRating: null, // soil/waste stacks — gravity
    regime: PipeRegime.gravity,
    note: 'Cast iron SML / hubless soil & waste. HW-C≈110 (aged uncoated; new '
        'lined can reach ~130), ε≈0.25 mm (Crane TP-410 cast-iron band). '
        'Gravity soil stack — no PN. VERIFY C against the lining condition.',
  ),
  PipeProduct.acousticPvc: const PipeProductSpec(
    label: 'Acoustic PVC',
    hazenWilliamsC: 150, // mineral-filled but smooth bore — hydraulically PVC
    roughness: _epsSmoothPlastic,
    pressureRating: null, // low-noise drainage
    regime: PipeRegime.gravity,
    note: 'Acoustic (silencer) PVC — mineral-filled low-noise drainage; '
        'hydraulically the same as PVC drainage (smooth bore). HW-C≈150, '
        'ε≈0.0015 mm. Specified for noise, not pressure (no PN). VERIFY.',
  ),
  PipeProduct.hdpe: const PipeProductSpec(
    label: 'HDPE (PE100)',
    hazenWilliamsC: 150,
    roughness: _epsSmoothPlastic,
    // PE100 SDR17 ≈ PN10 working pressure; SDR11 ≈ PN16. Take the common
    // SDR17 / PN10 grade as the catalog default.
    pressureRating: Pressure(1.0e6), // 10 bar (PE100 SDR17 ≈ PN10)
    regime: PipeRegime.both,
    note: 'HDPE PE100 buried mains / pressure. Very smooth (HW-C≈150, '
        'ε≈0.0015 mm). PN depends on SDR: SDR17≈PN10 (default here), '
        'SDR11≈PN16. VERIFY PN against the chosen SDR.',
  ),
};

/// Hazen–Williams C for a pipe [product].
double hazenWilliamsCFor(PipeProduct product) =>
    pipeProductSpecs[product]!.hazenWilliamsC;

/// Absolute wall roughness ε for a pipe [product].
Roughness roughnessFor(PipeProduct product) =>
    pipeProductSpecs[product]!.roughness;

/// Nominal pressure (PN) rating for a pipe [product]; `null` for gravity-only
/// (drainage / soil) products.
Pressure? pressureRatingFor(PipeProduct product) =>
    pipeProductSpecs[product]!.pressureRating;

/// Regime suitability hint for a pipe [product].
PipeRegime regimeFor(PipeProduct product) => pipeProductSpecs[product]!.regime;

/// Display label for a pipe [product].
String labelFor(PipeProduct product) => pipeProductSpecs[product]!.label;

// ── Nominal-size ladder (NPS, inches) + inch↔mm mapping ────────────────────

/// The nominal-size ladder in **inches (NPS)** the UI offers, ½″ … 12″. NPS is
/// a dimensionless size *designator*, not a literal bore — the engine carries
/// the matching millimetre DN via [npsToMm].
const List<double> npsInches = <double>[
  0.5, // ½″   DN15
  0.75, // ¾″   DN20
  1.0, // 1″   DN25
  1.25, // 1¼″  DN32
  1.5, // 1½″  DN40
  2.0, // 2″   DN50
  2.5, // 2½″  DN65
  3.0, // 3″   DN80
  4.0, // 4″   DN100
  5.0, // 5″   DN125
  6.0, // 6″   DN150
  8.0, // 8″   DN200
  10.0, // 10″ DN250
  12.0, // 12″ DN300
];

// NPS → DN (nominal millimetres) — the standard ISO 6708 / ASME B36 *nominal*
// designator mapping, NOT 25.4×inches (DN is a rounded designator: 1″ → DN25,
// not 25.4). For ≥14″ NPS, DN == 25×inches; below that the table is bespoke.
//
// notAnSniClause: the NPS↔DN designator mapping is general international
// practice (ISO 6708), not an SNI clause.
final Map<double, double> _npsToDnMm = {
  0.5: 15.0,
  0.75: 20.0,
  1.0: 25.0,
  1.25: 32.0,
  1.5: 40.0,
  2.0: 50.0,
  2.5: 65.0,
  3.0: 80.0,
  4.0: 100.0,
  5.0: 125.0,
  6.0: 150.0,
  8.0: 200.0,
  10.0: 250.0,
  12.0: 300.0,
};

/// Convert a nominal size in **inches (NPS)** to its nominal **millimetre (DN)**
/// designator. Uses the ISO 6708 / ASME B36 *designator* table for the standard
/// ladder (1″ → 25 mm, not 25.4); off-ladder sizes fall back to the ≥14″ rule
/// `DN = 25 × inches` (a documented nominal mapping, not a true OD/bore).
double npsToMm(double inches) {
  final dn = _npsToDnMm[inches];
  if (dn != null) return dn;
  // Off-ladder: the large-size convention DN = 25 × NPS (e.g. 14″ → 350).
  return inches * 25.0;
}

/// Convert a nominal **millimetre (DN)** designator back to **inches (NPS)** —
/// the inverse of [npsToMm] over the standard ladder (nearest DN), else the
/// `inches = mm / 25` large-size convention.
double mmToNps(double mm) {
  double? bestNps;
  var bestErr = double.infinity;
  for (final entry in _npsToDnMm.entries) {
    final err = (entry.value - mm).abs();
    if (err < bestErr) {
      bestErr = err;
      bestNps = entry.key;
    }
  }
  // Within a small tolerance of a tabled DN → return the exact NPS; otherwise
  // fall back to the large-size DN = 25×NPS convention.
  if (bestNps != null && bestErr <= 1.0) return bestNps;
  return mm / 25.0;
}

// ── Verify checklist (UI surfaces these as still-unverified) ───────────────

/// All currently-unverified pipe-product values, for the report's "verify
/// against the official PDF" panel. Mirrors `SniProfile.verifyChecklist`.
final List<StandardValue<Object?>> pipeProductsVerifyChecklist =
    <StandardValue<Object?>>[
  for (final entry in pipeProductSpecs.entries)
    StandardValue<Object?>(
      entry.key.name,
      unit: 'pipe product',
      citation:
          '${entry.value.label} — HW-C=${entry.value.hazenWilliamsC}, '
          'ε=${entry.value.roughness.inMillimeters} mm'
          '${entry.value.pressureRating == null ? '' : ', '
              'PN=${entry.value.pressureRating!.inBar.round()} bar'}',
      verified: false,
      status: entry.value.status,
      note: entry.value.note,
    ),
  // The nominal NPS→DN designator mapping (general international practice).
  const StandardValue<Object?>(
    'NPS→DN nominal size mapping (½″…12″)',
    unit: 'mapping',
    citation: 'ISO 6708 / ASME B36 nominal designators (NOT an SNI clause)',
    verified: false,
    status: VerificationStatus.notAnSniClause,
    note: 'NPS is a dimensionless designator; the mm column is the rounded DN '
        '(1″→DN25, not 25.4 mm). General international practice, not an SNI '
        'clause. Off-ladder ≥14″ uses DN = 25 × NPS.',
  ),
];
