/// Fire-sprinkler system design — density/area method (NFPA 13 §11 / P5 fire).
///
/// ## Method overview
/// The required system flow rate is obtained from the density/area method:
///
///   totalFlow [L/min] = designDensity [L/min/m²] × designArea [m²]
///
/// The number of operating sprinklers is:
///
///   count = ceil(designArea / coveragePerSprinkler [m²])
///
/// The hydraulic demand per sprinkler:
///
///   flowPerSprinkler = totalFlow / count
///
/// ## IMPORTANT — PLACEHOLDERS: DO NOT USE FOR FINAL DESIGN
///
/// The per-hazard design densities and design areas in this module are
/// **UNVERIFIED PLACEHOLDERS** based on general NFPA 13 practice. They have
/// NOT been checked against the applicable Indonesian standards:
///
/// * **SNI 03-3989-2000** — Tata Cara Perencanaan dan Pemasangan Sistem
///   Springkler Otomatik untuk Pencegahan Bahaya Kebakaran pada Bangunan Gedung.
/// * **SNI 8489** — Springkler otomatik (where applicable).
///
/// Every value tagged `// VERIFY` below **must** be confirmed against those
/// standards before being used in a real project submission or permit drawing.
///
/// Pure Dart, zero Flutter imports (§12 architecture guardrail: engine is
/// framework-free).
library;

import '../units.dart';

// ── Hazard classification ─────────────────────────────────────────────────────

/// Fire hazard classification used to select design density and design area.
///
/// Corresponds broadly to NFPA 13 occupancy hazard groups. Verify that the
/// classification mapping and thresholds match SNI 03-3989-2000 tables for the
/// specific occupancy — Indonesian practice may differ in categorisation.
///
/// // VERIFY — hazard class boundary definitions against SNI 03-3989-2000 §4.
enum FireHazardClass {
  /// Light hazard: low quantities of combustibles, e.g. offices, schools.
  lightHazard,

  /// Ordinary hazard group 1: moderate combustibles, low-to-moderate heat
  /// release, e.g. car parks, light assembly.
  ordinaryHazard1,

  /// Ordinary hazard group 2: higher piles of combustibles or moderate-to-high
  /// heat release, e.g. mercantile, woodworking.
  ordinaryHazard2,

  /// Extra hazard: high heat release and/or rapidly spreading fires, e.g.
  /// foam plastics manufacturing, paint shops.
  extraHazard,
}

// ── Design data ───────────────────────────────────────────────────────────────

/// Design density in litres per minute per square metre [L/min/m²] for each
/// [FireHazardClass].
///
/// // VERIFY — all four density values against SNI 03-3989-2000 density/area
/// curves (Table/Figure applicable to the occupancy). NFPA 13 allows a range;
/// values here are representative mid-range points only.
double designDensityLpmPerM2(FireHazardClass hazard) {
  switch (hazard) {
    case FireHazardClass.lightHazard:
      return 2.8; // VERIFY — placeholder; NFPA 13 light hazard typical ~2.0–4.1
    case FireHazardClass.ordinaryHazard1:
      return 4.1; // VERIFY — placeholder; NFPA 13 OH1 typical ~4.1–8.2
    case FireHazardClass.ordinaryHazard2:
      return 6.1; // VERIFY — placeholder; NFPA 13 OH2 typical ~6.1–12.2
    case FireHazardClass.extraHazard:
      return 8.2; // VERIFY — placeholder; NFPA 13 EH typical ~8.2–20.4
  }
}

/// Design area [m²] for each [FireHazardClass].
///
/// // VERIFY — all four area values against SNI 03-3989-2000 density/area
/// curves. Areas below are based on common NFPA 13 design area defaults and
/// may not match the SNI required remote design area for these hazard classes.
Area designArea(FireHazardClass hazard) {
  switch (hazard) {
    case FireHazardClass.lightHazard:
      return const Area(140.0); // VERIFY — placeholder; units: m²
    case FireHazardClass.ordinaryHazard1:
      return const Area(140.0); // VERIFY — placeholder; units: m²
    case FireHazardClass.ordinaryHazard2:
      return const Area(140.0); // VERIFY — placeholder; units: m²
    case FireHazardClass.extraHazard:
      return const Area(230.0); // VERIFY — placeholder; units: m²
  }
}

// ── Result type ───────────────────────────────────────────────────────────────

/// Output of [designSprinklerSystem]: the hydraulic demand for the design area.
///
/// All quantities are typed SI values from `units.dart`.
final class SprinklerDesign {
  /// Hazard class used to derive this design.
  final FireHazardClass hazard;

  /// Design area (the "remote area") used for this calculation.
  final Area designAreaValue;

  /// Total required system flow entering the design area.
  ///
  /// Equals designDensity × designArea, expressed as a [FlowRate].
  final FlowRate requiredFlow;

  /// Number of operating sprinklers within the design area.
  ///
  /// Equals `ceil(designArea / coveragePerSprinklerM2)`.
  final int sprinklerCount;

  /// Hydraulic demand assigned to each sprinkler head.
  ///
  /// Equals `requiredFlow / sprinklerCount`.
  final FlowRate flowPerSprinkler;

  /// Constructs a [SprinklerDesign] directly. Prefer calling
  /// [designSprinklerSystem] which derives all fields from first principles.
  const SprinklerDesign({
    required this.hazard,
    required this.designAreaValue,
    required this.requiredFlow,
    required this.sprinklerCount,
    required this.flowPerSprinkler,
  });
}

// ── Sizing function ───────────────────────────────────────────────────────────

/// Size a wet-pipe sprinkler system using the density/area method.
///
/// ## Method
/// 1. Look up [designDensityLpmPerM2] and [designArea] for [hazard].
/// 2. `totalFlowLpm = density × area.squareMeters`
/// 3. `requiredFlow = FlowRate.litersPerMinute(totalFlowLpm)`
/// 4. `sprinklerCount = ceil(area.squareMeters / coveragePerSprinklerM2)`
/// 5. `flowPerSprinkler = FlowRate.litersPerMinute(totalFlowLpm / sprinklerCount)`
///
/// ## Parameters
/// * [hazard] — occupancy hazard class; drives density and design area lookup.
/// * [coveragePerSprinklerM2] — maximum floor area per sprinkler head [m²];
///   default 12.0 m² (typical for standard-response upright/pendant heads in
///   ordinary hazard per NFPA 13 §8.6). // VERIFY against SNI 03-3989-2000
///   Table on maximum spacing/coverage area for the applicable hazard class and
///   sprinkler type (standard, ESFR, etc.).
///
/// ## Return
/// A [SprinklerDesign] with the computed [SprinklerDesign.requiredFlow],
/// [SprinklerDesign.sprinklerCount], and [SprinklerDesign.flowPerSprinkler].
SprinklerDesign designSprinklerSystem({
  required FireHazardClass hazard,
  double coveragePerSprinklerM2 = 12.0, // VERIFY — see doc comment above
}) {
  assert(coveragePerSprinklerM2 > 0, 'coveragePerSprinklerM2 must be positive');

  final double density = designDensityLpmPerM2(hazard);
  final Area area = designArea(hazard);
  final double areaM2 = area.squareMeters;

  // Total system flow demand for the remote design area.
  final double totalFlowLpm = density * areaM2;
  final FlowRate requiredFlow = FlowRate.litersPerMinute(totalFlowLpm);

  // Number of operating sprinkler heads covering the design area.
  final int count = (areaM2 / coveragePerSprinklerM2).ceil();

  // Per-head hydraulic demand (equal distribution; conservative for design).
  final FlowRate perHead = FlowRate.litersPerMinute(totalFlowLpm / count);

  return SprinklerDesign(
    hazard: hazard,
    designAreaValue: area,
    requiredFlow: requiredFlow,
    sprinklerCount: count,
    flowPerSprinkler: perHead,
  );
}
