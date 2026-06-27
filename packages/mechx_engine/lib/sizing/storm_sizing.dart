/// Storm / rainwater sizing — the §7 gravity path for roof drainage.
///
/// Roof runoff is sized from the design rainfall intensity and the catchment
/// area, then the rainwater downpipe is chosen from a standard vertical-pipe
/// capacity table (a downpipe runs roughly one-third full, so capacity is far
/// below a full-bore Manning flow — hence a dedicated table rather than the
/// sanitary drainage path).
///
/// Pure Dart, zero Flutter imports.
///
/// // VERIFY — the default rainfall intensity and the downpipe capacities below
/// against SNI 03-7065-2005 / SNI 8153 and the local design storm. Indonesian
/// design storms are intense; 200 mm/hr is a common starting figure.
library;

import '../units.dart';

/// Default design rainfall intensity (mm/hr). // VERIFY against the local
/// design storm (Indonesian rates are high; confirm per region/return period).
const double kDefaultRainfallMmPerHr = 200.0;

/// Default runoff coefficient C (dimensionless, 0–1) — the fraction of rainfall
/// that becomes runoff at the outlet. A flat impervious roof is near-unity; a
/// gravel/green roof or a paved catchment with some retention is lower.
///
/// 0.9 is a defensible default for a typical impervious building roof
/// (small losses to wetting/evaporation), but the value is surface- and
/// region-dependent. // VERIFY against SNI 8153 / SNI 03-7065-2005 and the local
/// design practice (rational-method C tables vary by surface and return period).
const double kDefaultRunoffCoefficient = 0.9;

/// Roof runoff design flow (the rational method) for a catchment of [roofAreaM2]
/// under rainfall [intensityMmPerHr] with runoff coefficient [runoffCoefficient]
/// (the fraction of rainfall that runs off; 1.0 = a fully impervious roof):
///   Q [m³/s] = C × intensity[mm/hr] × area[m²] / (1000 mm/m × 3600 s/hr).
///
/// [runoffCoefficient] defaults to 1.0 so existing callers that pass only an
/// intensity + area are byte-identical; the app threads the project's design
/// coefficient (see `kDefaultRunoffCoefficient`). // VERIFY — C is surface- and
/// region-dependent (rational-method tables); confirm against SNI practice.
FlowRate rainwaterDesignFlow({
  required double intensityMmPerHr,
  required double roofAreaM2,
  double runoffCoefficient = 1.0,
}) {
  assert(intensityMmPerHr >= 0 && roofAreaM2 >= 0);
  assert(runoffCoefficient >= 0, 'runoffCoefficient must be non-negative');
  return FlowRate(
    runoffCoefficient * intensityMmPerHr * roofAreaM2 / (1000.0 * 3600.0),
  );
}

/// Standard vertical rainwater downpipe capacities (capacity L/s, diameter mm),
/// ascending — a pipe running ≈1/3 full. // VERIFY against SNI tables.
const List<(double capacityLps, double diameterMm)> standardDownpipeCapacities =
    [
  (1.8, 50),
  (3.4, 65),
  (5.0, 75),
  (10.5, 100),
  (19.0, 125),
  (30.0, 150),
  (65.0, 200),
];

/// Outcome of a rainwater downpipe sizing.
final class RainwaterSizingResult {
  /// Chosen standard downpipe diameter.
  final Diameter diameter;

  /// The design runoff flow this pipe must carry.
  final FlowRate flow;

  /// Rated capacity of the chosen diameter (L/s).
  final double capacityLps;

  /// True when even the largest tabulated pipe cannot carry the flow — the
  /// caller must split the catchment across more downpipes.
  final bool overCapacity;

  const RainwaterSizingResult({
    required this.diameter,
    required this.flow,
    required this.capacityLps,
    required this.overCapacity,
  });
}

/// Pick the smallest standard rainwater downpipe whose capacity covers [flow].
/// If none suffices, returns the largest with [RainwaterSizingResult.overCapacity]
/// set.
RainwaterSizingResult sizeRainwaterDownpipe(FlowRate flow) {
  final lps = flow.inLitersPerSecond;
  for (final (capacity, mm) in standardDownpipeCapacities) {
    if (capacity >= lps) {
      return RainwaterSizingResult(
        diameter: Diameter.mm(mm),
        flow: flow,
        capacityLps: capacity,
        overCapacity: false,
      );
    }
  }
  final last = standardDownpipeCapacities.last;
  return RainwaterSizingResult(
    diameter: Diameter.mm(last.$2),
    flow: flow,
    capacityLps: last.$1,
    overCapacity: true,
  );
}
