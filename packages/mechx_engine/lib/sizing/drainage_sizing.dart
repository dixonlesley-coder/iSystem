/// Gravity-drainage pipe sizing — the §7 "gravity" code path.
///
/// Implements Manning-based minimum-diameter selection for drain pipes flowing
/// at a specified fill ratio. The usable capacity uses the TRUE partial-full
/// circular-pipe hydraulics (not a linear fill-ratio scaling):
///
///   Q(θ)/Q_full = [(θ − sinθ)/2π] · [(θ − sinθ)/θ]^(2/3),
///     where θ = 2·acos(1 − 2·r) is the central angle for depth ratio r.
///
/// This is exact across the whole range — 0.5 at half-full (where R = D/4 =
/// R_full so velocity is unchanged) and 1.0 at full bore — and correctly
/// captures that capacity rises faster than depth (e.g. Q/Q_full ≈ 0.912 at
/// r = 0.75, not 0.75).
///
/// References: Manning equation; partial-full circular conduit relations;
/// BS EN 12056-2 / SNI annex on gravity sewers.
/// Pure Dart, zero Flutter imports (§12: engine is framework-free).
library;

import 'dart:math' as math;

import '../hydraulics.dart';
import '../units.dart';

// ── Partial-full hydraulics ───────────────────────────────────────────────────

/// Ratio Q(r)/Q_full for a circular pipe flowing at depth ratio r = [fillRatio]
/// (depth / diameter), from the exact Manning partial-full relations.
///
/// Returns 0.5 at r = 0.5 and 1.0 at r = 1.0; ≈0.912 at r = 0.75.
double partialFullCapacityFactor(double fillRatio) {
  assert(fillRatio > 0 && fillRatio <= 1.0, 'fillRatio must be in (0, 1]');
  if (fillRatio >= 1.0) return 1.0;
  final theta = 2.0 * math.acos(1.0 - 2.0 * fillRatio); // central angle (rad)
  final areaRatio = (theta - math.sin(theta)) / (2.0 * math.pi);
  final radiusRatio = (theta - math.sin(theta)) / theta;
  return areaRatio * math.pow(radiusRatio, 2.0 / 3.0).toDouble();
}

// ── Standard diameters ──────────────────────────────────────────────────────

/// Nominal inside diameters (mm) available in the standard drain-pipe series.
///
/// Covers the range used in building sanitary drainage from wash-basin
/// branches (DN50) through main drain connections (DN300). A sizing result
/// always resolves to one of these values or, when demand exceeds the largest,
/// stays at DN300 (over-loaded — the caller must flag this).
const List<double> standardDrainDiametersMm = [
  50,
  75,
  100,
  125,
  150,
  200,
  250,
  300,
];

// ── Result type ─────────────────────────────────────────────────────────────

/// Output of [sizeForFlow]: the chosen pipe and its performance at full bore.
///
/// All velocity and capacity values are **full-bore** figures. The *usable*
/// capacity at the design fill ratio is `fullBoreCapacity × fillRatio` (the
/// linear capacity model applied at the sizing stage).
final class DrainageSizingResult {
  /// Selected nominal diameter from [standardDrainDiametersMm].
  final Diameter diameter;

  /// Full-bore Manning discharge for the selected pipe at the design slope and
  /// Manning n.
  final FlowRate fullBoreCapacity;

  /// Usable discharge at the design fill ratio:
  /// `fullBoreCapacity × partialFullCapacityFactor(fillRatio)`. This is what the
  /// selected pipe can actually carry at the design depth (≥ the design flow).
  final FlowRate usableCapacity;

  /// Full-bore Manning mean velocity for the selected pipe. Used to check
  /// [selfCleansing].
  final Velocity fullBoreVelocity;

  /// `true` when [fullBoreVelocity] ≥ 0.6 m/s, the widely-accepted minimum
  /// self-cleansing velocity for gravity drains (solids are kept in
  /// suspension). A result of `false` means the slope must be steepened or a
  /// larger pipe must be avoided.
  final bool selfCleansing;

  /// Constructs a result directly; prefer calling [sizeForFlow].
  const DrainageSizingResult({
    required this.diameter,
    required this.fullBoreCapacity,
    required this.usableCapacity,
    required this.fullBoreVelocity,
    required this.selfCleansing,
  });
}

// ── Sizing function ─────────────────────────────────────────────────────────

/// Select the smallest standard drain diameter that can carry [flow] at the
/// given [slope] without exceeding the design [fillRatio].
///
/// ## Method
/// For each diameter in [standardDrainDiametersMm] (ascending), the full-bore
/// Manning capacity is computed via [manningFlowFull]. The usable capacity is:
///
///   Q_usable = Q_full_bore × fillRatio
///
/// The smallest pipe whose full-bore capacity satisfies
/// `Q_full_bore ≥ flow / fillRatio` is selected. If no standard size
/// suffices, the largest (DN300) is returned — the caller should treat this as
/// an overload condition.
///
/// ## Parameters
/// * [flow]       — Design peak flow demand (m³/s internally).
/// * [slope]      — Hydraulic gradient, dimensionless (e.g. 0.01 for 1 in 100).
/// * [fillRatio]  — Maximum permitted depth / diameter ratio; default 0.5
///                  (half-full, the common design standard).
/// * [manningN]   — Manning roughness coefficient; default 0.010 for smooth
///                  plastic drain pipes (PVC/HDPE). Use 0.013 for cast iron.
///
/// ## Self-cleansing
/// The returned [DrainageSizingResult.selfCleansing] flag is `true` when the
/// full-bore velocity ≥ 0.6 m/s. At half-full the actual velocity EQUALS the
/// full-bore value (hydraulic radius is identical, R = D/4), and between half-
/// full and ~0.8 it is slightly higher, so a pipe that passes at full bore
/// self-cleanses at the design fill level.
DrainageSizingResult sizeForFlow({
  required FlowRate flow,
  required double slope,
  double fillRatio = 0.5,
  double manningN = 0.010,
}) {
  assert(fillRatio > 0 && fillRatio <= 1.0, 'fillRatio must be in (0, 1]');
  assert(slope > 0, 'slope must be positive');
  assert(manningN > 0, 'manningN must be positive');
  assert(flow.cubicMetersPerSecond >= 0, 'flow must be non-negative');

  // Required full-bore capacity so the TRUE partial-full discharge ≥ flow.
  final double fillFactor = partialFullCapacityFactor(fillRatio);
  final double requiredFullBore = flow.cubicMetersPerSecond / fillFactor;

  // Walk ascending diameters; pick the first that meets the requirement.
  Diameter? chosen;
  for (final double dmm in standardDrainDiametersMm) {
    final Diameter d = Diameter.mm(dmm);
    final FlowRate qFull = manningFlowFull(d, manningN: manningN, slope: slope);
    if (qFull.cubicMetersPerSecond >= requiredFullBore) {
      chosen = d;
      break;
    }
  }

  // Fall back to the largest standard size if no pipe is big enough.
  final Diameter selected =
      chosen ?? Diameter.mm(standardDrainDiametersMm.last);

  // Full-bore performance for the selected diameter.
  final FlowRate qFull =
      manningFlowFull(selected, manningN: manningN, slope: slope);
  final Velocity vFull = manningVelocity(
    manningN: manningN,
    hydraulicRadius: Length(selected.meters / 4.0),
    slope: slope,
  );
  final bool selfCleansing = vFull.metersPerSecond >= 0.6;

  return DrainageSizingResult(
    diameter: selected,
    fullBoreCapacity: qFull,
    usableCapacity: FlowRate(qFull.cubicMetersPerSecond * fillFactor),
    fullBoreVelocity: vFull,
    selfCleansing: selfCleansing,
  );
}
