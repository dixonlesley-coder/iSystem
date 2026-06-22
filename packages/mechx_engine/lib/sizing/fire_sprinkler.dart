/// Fire-sprinkler system design — density/area method (§P5 fire).
///
/// ## Method overview
/// The required system flow rate is obtained from the density/area method
/// (SNI 03-3989-2000 §5 — kepadatan pancaran × luas operasi maksimum):
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
/// ## Provenance
/// The per-hazard design densities and maximum operating areas below are taken
/// from **SNI 03-3989-2000** — *Tata Cara Perencanaan dan Pemasangan Sistem
/// Springkler Otomatik untuk Pencegahan Bahaya Kebakaran pada Bangunan Gedung*.
///
/// Note that a "discharge density" expressed in mm/min is numerically equal to
/// L/min/m² (a 1 mm depth of water spread over 1 m² is exactly 1 litre), so the
/// SNI mm/min figures are used directly as L/min/m².
///
/// Values that remain engineering judgement (the representative Berat density
/// within the SNI range, and the default head coverage where SNI specifies a
/// maximum rather than an exact value) are still tagged `// VERIFY`.
///
/// Pure Dart, zero Flutter imports (§12 architecture guardrail: engine is
/// framework-free).
library;

import '../units.dart';

// ── Hazard classification ─────────────────────────────────────────────────────

/// Fire hazard classification used to select design density and design area.
///
/// Maps to the SNI 03-3989-2000 occupancy hazard groups:
///   * [lightHazard]      → Bahaya Kebakaran Ringan (BKR)
///   * [ordinaryHazard1]  → Bahaya Kebakaran Sedang Kelompok I (BKS-I)
///   * [ordinaryHazard2]  → Bahaya Kebakaran Sedang Kelompok II/III (BKS-II/III)
///   * [extraHazard]      → Bahaya Kebakaran Berat (BKB)
///
/// // VERIFY — the assignment of a specific occupancy (office, car park, etc.)
/// to one of these classes must follow the SNI 03-3989-2000 §4 occupancy
/// tables; this enum only carries the design data per class.
enum FireHazardClass {
  /// Light hazard — Bahaya Kebakaran Ringan: low quantities of combustibles,
  /// e.g. offices, schools, dwellings.
  lightHazard,

  /// Ordinary hazard group 1 — Bahaya Kebakaran Sedang Kelompok I: moderate
  /// combustibles, e.g. car parks, light assembly.
  ordinaryHazard1,

  /// Ordinary hazard group 2 — Bahaya Kebakaran Sedang Kelompok II/III: higher
  /// piles of combustibles, e.g. mercantile, woodworking, warehouses.
  ordinaryHazard2,

  /// Extra hazard — Bahaya Kebakaran Berat: high heat release and/or rapidly
  /// spreading fires, e.g. foam-plastics manufacturing, paint shops.
  extraHazard,
}

// ── Design data ───────────────────────────────────────────────────────────────

/// Design discharge density in litres per minute per square metre [L/min/m²]
/// for each [FireHazardClass].
///
/// Source: SNI 03-3989-2000 §5 (kepadatan pancaran). The Ringan (2.25) and
/// Sedang (5.0) figures are stated directly by the standard. The Berat figure
/// is a representative point within the SNI range (≈7.5–12.5 mm/min) and is
/// still tagged `// VERIFY` because the exact value depends on the Berat
/// sub-group and storage configuration.
double designDensityLpmPerM2(FireHazardClass hazard) {
  switch (hazard) {
    case FireHazardClass.lightHazard:
      return 2.25; // SNI 03-3989-2000 — Ringan
    case FireHazardClass.ordinaryHazard1:
      return 5.0; // SNI 03-3989-2000 — Sedang
    case FireHazardClass.ordinaryHazard2:
      return 5.0; // SNI 03-3989-2000 — Sedang
    case FireHazardClass.extraHazard:
      return 10.0; // VERIFY — Berat: representative mid-range (7.5–12.5 mm/min)
  }
}

/// Maximum operating ("remote") design area [m²] for each [FireHazardClass].
///
/// Source: SNI 03-3989-2000 §5 (luas operasi maksimum). Ringan ≈ 84 m²;
/// Sedang spans ≈72–360 m² by sub-group (Kelompok I ≈ 72 m², II/III larger).
/// The Berat area is a representative point in the SNI range (≈260–300 m²) and
/// is tagged `// VERIFY` pending the specific Berat sub-group.
Area designArea(FireHazardClass hazard) {
  switch (hazard) {
    case FireHazardClass.lightHazard:
      return const Area(84.0); // SNI 03-3989-2000 — Ringan (m²)
    case FireHazardClass.ordinaryHazard1:
      return const Area(72.0); // SNI 03-3989-2000 — Sedang Kel. I (m²)
    case FireHazardClass.ordinaryHazard2:
      return const Area(144.0); // SNI 03-3989-2000 — Sedang Kel. II/III (m²)
    case FireHazardClass.extraHazard:
      return const Area(260.0); // VERIFY — Berat: representative (260–300 m²)
  }
}

/// Maximum floor area covered by one sprinkler head [m²] for [hazard].
///
/// Source: SNI 03-3989-2000 §6 (jarak/luas lindung kepala springkler):
/// Ringan ≤ 20 m², Sedang ≤ 12 m², Berat ≤ 9 m² per standard-coverage head.
/// Used as the default head spacing when the caller does not override it.
double maxCoveragePerSprinklerM2(FireHazardClass hazard) {
  switch (hazard) {
    case FireHazardClass.lightHazard:
      return 20.0; // SNI 03-3989-2000 — Ringan
    case FireHazardClass.ordinaryHazard1:
    case FireHazardClass.ordinaryHazard2:
      return 12.0; // SNI 03-3989-2000 — Sedang
    case FireHazardClass.extraHazard:
      return 9.0; // SNI 03-3989-2000 — Berat
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
/// 4. `sprinklerCount = ceil(area.squareMeters / coverage)`
/// 5. `flowPerSprinkler = FlowRate.litersPerMinute(totalFlowLpm / sprinklerCount)`
///
/// ## Parameters
/// * [hazard] — occupancy hazard class; drives density and design area lookup.
/// * [coveragePerSprinklerM2] — maximum floor area per sprinkler head [m²]. When
///   omitted it defaults to [maxCoveragePerSprinklerM2] for [hazard] (SNI
///   03-3989-2000 §6: Ringan 20, Sedang 12, Berat 9 m²). Pass an explicit value
///   to model a tighter head grid.
///
/// ## Return
/// A [SprinklerDesign] with the computed [SprinklerDesign.requiredFlow],
/// [SprinklerDesign.sprinklerCount], and [SprinklerDesign.flowPerSprinkler].
SprinklerDesign designSprinklerSystem({
  required FireHazardClass hazard,
  double? coveragePerSprinklerM2,
}) {
  final double coverage =
      coveragePerSprinklerM2 ?? maxCoveragePerSprinklerM2(hazard);
  assert(coverage > 0, 'coveragePerSprinklerM2 must be positive');

  final double density = designDensityLpmPerM2(hazard);
  final Area area = designArea(hazard);
  final double areaM2 = area.squareMeters;

  // Total system flow demand for the remote design area.
  final double totalFlowLpm = density * areaM2;
  final FlowRate requiredFlow = FlowRate.litersPerMinute(totalFlowLpm);

  // Number of operating sprinkler heads covering the design area.
  final int count = (areaM2 / coverage).ceil();

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
