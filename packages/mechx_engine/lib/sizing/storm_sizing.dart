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

/// Roof runoff design flow for a catchment of [roofAreaM2] under rainfall
/// [intensityMmPerHr] (assuming runoff coefficient 1.0 for an impervious roof):
///   Q [m³/s] = intensity[mm/hr] × area[m²] / (1000 mm/m × 3600 s/hr).
FlowRate rainwaterDesignFlow({
  required double intensityMmPerHr,
  required double roofAreaM2,
}) {
  assert(intensityMmPerHr >= 0 && roofAreaM2 >= 0);
  return FlowRate(intensityMmPerHr * roofAreaM2 / (1000.0 * 3600.0));
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
