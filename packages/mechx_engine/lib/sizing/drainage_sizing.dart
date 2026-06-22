/// Gravity-drainage pipe sizing — the §7 "gravity" code path.
///
/// Implements Manning-based minimum-diameter selection for drain pipes flowing
/// at a specified fill ratio. The usable capacity model is:
///
///   Q_usable = Q_full_bore × fillRatio
///
/// This is exact at fillRatio = 0.5 (hydraulic radius of a half-full circular
/// pipe equals D/4, same as the full-bore value) and at fillRatio = 1.0
/// (definition). For intermediate ratios the linear interpolation is
/// conservative near r ≤ 0.5 and slightly non-conservative between 0.5 and
/// 1.0, but all practical drain-sizing standards use r = 0.5 or r = 0.75 at
/// most, so the model is fit for purpose in the §7 gravity path.
///
/// References: Manning equation; BS EN 12056-2 / SNI annex on gravity sewers.
/// Pure Dart, zero Flutter imports (§12: engine is framework-free).
library;

import '../hydraulics.dart';
import '../units.dart';

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
  /// Manning n. Equals the usable capacity divided by [fillRatio] supplied to
  /// [sizeForFlow].
  final FlowRate fullBoreCapacity;

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
/// full-bore velocity ≥ 0.6 m/s. This is a conservative check: at half-full
/// the actual velocity is approximately 90 % of the full-bore value, so pipes
/// that pass at full-bore almost always self-cleanse at the design fill level.
DrainageSizingResult sizeForFlow({
  required FlowRate flow,
  required double slope,
  double fillRatio = 0.5,
  double manningN = 0.010,
}) {
  assert(fillRatio > 0 && fillRatio <= 1.0, 'fillRatio must be in (0, 1]');
  assert(slope > 0, 'slope must be positive');
  assert(manningN > 0, 'manningN must be positive');

  // The required full-bore capacity so that Q_usable = flow at the fill ratio.
  final double requiredFullBore = flow.cubicMetersPerSecond / fillRatio;

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
    fullBoreVelocity: vFull,
    selfCleansing: selfCleansing,
  );
}
