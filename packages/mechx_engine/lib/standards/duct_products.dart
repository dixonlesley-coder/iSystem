/// MEP **duct products** catalog — sheet-material data + automatic gauge
/// selection for the mechanical (air) canvas, the sibling of `pipe_products.dart`.
///
/// Two products an Indonesian HVAC contractor specifies:
///   • **BJLS** (Baja Lapis Seng — galvanized steel sheet): the standard
///     rectangular/round duct material. Its sheet thickness is **size-derived**
///     — bigger ducts need thicker sheet to stay rigid against the static
///     pressure — via a SMACNA / SNI-style gauge ladder ([bjlsThicknessMm]).
///   • **PU** (polyurethane pre-insulated rigid panel): a sandwich panel duct
///     built from a fixed-thickness board ([puPanelThicknessMm]), not gauge-
///     selected by size.
///
/// PROVENANCE POLICY (mirrors `sni.dart`, §12.6): the BJLS gauge ladder and the
/// PU panel thickness are real engineering values (SMACNA HVAC Duct
/// Construction Standards low-pressure galvanized-steel gauge schedule; PU panel
/// manufacturer data) but are **NOT confirmed verbatim against the official
/// SMACNA / SNI 03-6572 PDFs**, so they default to **`secondarySource`**. Every
/// unverified value MUST surface via [ductProductsVerifyChecklist].
///
/// SI internally (guardrail §12.2): the largest-duct-side input and the
/// returned sheet thickness are in millimetres (the dimension HVAC engineers
/// quote ducts in), the engine's working unit for these small spans.
///
/// Zero Flutter imports.
library;

import '../units.dart';
import 'sni.dart' show StandardValue, VerificationStatus;

/// A duct **product** an engineer specifies per segment.
enum DuctProduct {
  /// BJLS — Baja Lapis Seng (galvanized steel sheet). Gauge by duct size.
  bjls,

  /// PU — polyurethane pre-insulated rigid panel (fixed panel thickness).
  pu,
}

/// Display label for a duct [product].
String ductLabelFor(DuctProduct product) => switch (product) {
      DuctProduct.bjls => 'BJLS (galvanized steel)',
      DuctProduct.pu => 'PU pre-insulated panel',
    };

// ── Per-product absolute wall roughness ε (Darcy–Weisbach / Colebrook) ──────

/// Galvanised-steel duct roughness ε. Matches `duct_sizing._galvSteelRoughness`
/// (9.0 × 10⁻⁵ m, the value the duct-sizing air-friction kernel uses by
/// default), so a BJLS segment reproduces the existing galvanised-steel result
/// exactly.
const Roughness _bjlsRoughness = Roughness(9.0e-5); // 0.09 mm, galvanised steel

/// PU pre-insulated panel roughness ε. The rigid PU sandwich panel has a
/// smoother bore than galvanised sheet, so its air friction is lower.
///
// VERIFY: no official ε figure for PU pre-insulated ductwork in SMACNA /
// SNI 03-6572; 3.0 × 10⁻⁵ m (0.03 mm) is a representative smooth-panel value
// (secondarySource — between drawn plastic and galvanised steel). Confirm
// against the PU panel manufacturer datasheet before a submission.
const Roughness _puRoughness = Roughness(3.0e-5); // 0.03 mm, smooth PU panel

/// Absolute wall roughness ε for a duct [product], for the Darcy–Weisbach air
/// friction in [ductFrictionPaPerMetre]. BJLS matches the galvanised-steel
/// default; PU is smoother (lower friction).
Roughness ductRoughnessFor(DuctProduct product) => switch (product) {
      DuctProduct.bjls => _bjlsRoughness,
      DuctProduct.pu => _puRoughness,
    };

// ── BJLS automatic gauge (sheet thickness) by duct size ────────────────────

/// BJLS sheet-thickness ladder, keyed by the **inclusive upper bound of the
/// largest duct side (mm)** → sheet thickness (mm). A larger duct needs thicker
/// sheet for rigidity. Modelled on the SMACNA low-pressure rectangular-duct
/// galvanized-steel gauge schedule (and the common Indonesian BJLS practice of
/// quoting sheet by mm rather than US gauge number):
///
///   ≤ 450 mm  → 0.50 mm  (≈ 26 ga)
///   ≤ 750 mm  → 0.60 mm  (≈ 24 ga)
///   ≤ 1200 mm → 0.70 mm  (≈ 22 ga)
///   ≤ 1800 mm → 0.80 mm  (≈ 20 ga)
///   ≤ 2100 mm → 1.00 mm  (≈ 18 ga)
///   >  2100 mm → 1.20 mm  (≈ 16 ga)
///
/// A `static final` map (not `const`) because Dart forbids a `const` map with
/// `double` keys.
///
// VERIFY: SMACNA HVAC Duct Construction Standards (low-pressure, galvanized
// steel) gauge-by-size schedule and SNI 03-6572-2001 (tata cara perancangan
// sistem ventilasi & pengkondisian udara). The mm thicknesses are the nominal
// metric equivalents of the US gauges; the size break-points are
// representative low-pressure values, NOT confirmed verbatim against either
// PDF. Confirm before a submission.
final Map<double, double> _bjlsGaugeLadderMm = {
  450.0: 0.50,
  750.0: 0.60,
  1200.0: 0.70,
  1800.0: 0.80,
  2100.0: 1.00,
};

/// Sheet thickness used above the top tabled break-point.
const double _bjlsThicknessAboveLadderMm = 1.20;

/// **Automatic** BJLS sheet thickness (mm) for a duct whose largest side is
/// [largestSideMm] (mm). Steps up with size per the SMACNA/SNI-style gauge
/// ladder above; returns 1.20 mm for ducts above the top break-point.
double bjlsThicknessMm(double largestSideMm) {
  // Sorted ascending: pick the first break-point the duct fits within.
  final bounds = _bjlsGaugeLadderMm.keys.toList()..sort();
  for (final bound in bounds) {
    if (largestSideMm <= bound) return _bjlsGaugeLadderMm[bound]!;
  }
  return _bjlsThicknessAboveLadderMm;
}

// ── PU pre-insulated panel thickness ───────────────────────────────────────

/// Default PU sandwich-panel board thickness (mm). PU duct is built from a
/// fixed-thickness rigid panel — it is NOT gauge-selected by duct size.
const double _puDefaultPanelThicknessMm = 20.0;

/// PU pre-insulated rigid-panel thickness (mm). Unlike [bjlsThicknessMm] this
/// is a fixed-ish panel board, defaulting to 20 mm; pass [panelThicknessMm] to
/// specify a thicker board (common grades 20 / 25 / 30 mm). The duct *size*
/// does not change the panel thickness.
double puPanelThicknessMm({double? panelThicknessMm}) =>
    panelThicknessMm ?? _puDefaultPanelThicknessMm;

// ── Verify checklist (UI surfaces these as still-unverified) ───────────────

/// All currently-unverified duct-product values, for the report's "verify
/// against the official PDF" panel. Mirrors `SniProfile.verifyChecklist`.
final List<StandardValue<Object?>> ductProductsVerifyChecklist =
    <StandardValue<Object?>>[
  const StandardValue<Object?>(
    'BJLS automatic sheet-gauge ladder (0.50–1.20 mm by duct size)',
    unit: 'gauge table',
    citation:
        'SMACNA HVAC Duct Construction Standards / SNI 03-6572-2001 (NOT '
        'confirmed verbatim)',
    verified: false,
    status: VerificationStatus.secondarySource,
    note: 'BJLS (galvanized steel) sheet thickness vs largest duct side: '
        '≤450→0.50, ≤750→0.60, ≤1200→0.70, ≤1800→0.80, ≤2100→1.00, '
        '>2100→1.20 mm. Metric equivalents of the SMACNA low-pressure US '
        'gauges; size break-points representative. VERIFY against SMACNA + '
        'SNI 03-6572.',
  ),
  const StandardValue<Object?>(
    'PU pre-insulated panel thickness (default 20 mm)',
    unit: 'mm',
    citation: 'PU panel manufacturer data (NOT confirmed verbatim)',
    verified: false,
    status: VerificationStatus.secondarySource,
    note: 'PU = polyurethane pre-insulated rigid sandwich panel; fixed-ish '
        'board thickness (common 20 / 25 / 30 mm), not gauge-selected by duct '
        'size. Default 20 mm. VERIFY against the panel manufacturer datasheet.',
  ),
  const StandardValue<Object?>(
    'PU pre-insulated panel air roughness (ε ≈ 0.03 mm)',
    unit: 'mm',
    citation: 'Representative smooth-panel value (NOT confirmed verbatim)',
    verified: false,
    status: VerificationStatus.secondarySource,
    note: 'PU duct absolute wall roughness ε ≈ 3.0e-5 m (0.03 mm) — smoother '
        'than galvanised steel (ε ≈ 0.09 mm), so PU air friction is lower. No '
        'official PU figure in SMACNA / SNI 03-6572; representative value. '
        'Now feeds the fan-static (Darcy) solve. VERIFY against the PU panel '
        'manufacturer datasheet.',
  ),
];
