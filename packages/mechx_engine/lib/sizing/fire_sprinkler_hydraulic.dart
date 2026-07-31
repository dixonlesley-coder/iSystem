/// Sprinkler remote-area hydraulic calc — the K-factor + branch-friction layer
/// on top of the density/area method in `fire_sprinkler.dart` (§P5 fire).
///
/// ## Why this module exists
/// [designSprinklerSystem] (density/area) gives the *system* flow demand and an
/// equal-split per-head flow. That equal split is conservative but does not tell
/// the engineer whether the most-remote (hydraulically worst) head can actually
/// deliver its share at an acceptable pressure. This module adds the per-head
/// **K-factor** relation and a **branch-line friction** estimate so we can:
///
///   1. find the operating pressure the most-remote head needs to discharge its
///      required flow (`Q = K·√P`, the universal sprinkler discharge law), and
///   2. add the branch-line friction back to the *base* of the design area so
///      the supply demand at the riser is honest, and
///   3. apply the **minimum operating pressure** floor for a standard spray
///      head, re-deriving the demand at that floor when the density share alone
///      would sit below it.
///
/// ## The minimum-pressure floor (why this is not a failure verdict)
/// The density/area split is a *lower bound* on what each head must deliver. A
/// listed head, however, cannot discharge below its minimum operating pressure —
/// below that pressure it does not form a spray pattern at all. So when the
/// density share `(Q/K)²` lands under the minimum, the head does not "fail": it
/// simply discharges MORE than the density share, at the floor pressure:
///
///   Q_head = K · √(P_min)        (the standard hydraulic-calculation floor)
///
/// and the design-area demand rises with it (`Q_head × head count`). This is
/// exactly what a hand hydraulic calculation does, and it is the structural case
/// at **light hazard**: 2.25 L/min/m² over 84 m² split across 5 heads
/// (20 m² coverage) is 37.8 L/min/head ⇒ (37.8/80)² = 0.223 bar, always under
/// the 0.5 bar floor. Reporting that as an under-pressure FAILURE was an
/// unactionable verdict on every light-hazard project; the honest output is the
/// uplifted per-head flow (K·√0.5 = 56.57 L/min) and the resulting higher
/// remote-area demand, flagged via [SprinklerRemoteAreaResult.governedByMinimumPressure].
/// Heavier hazards, whose density share already clears the floor, are untouched.
///
/// ## The discharge law  Q = K·√P
/// The K-factor relates a head's discharge `Q` to its inlet pressure `P`:
///
///   Q [L/min] = K · √(P [bar])          ⇒   P [bar] = (Q / K)²
///
/// K is a *nominal* discharge coefficient stamped on the head. The metric K used
/// here (L/min/bar^0.5) is the European/SNI convention; a US K (gpm/psi^0.5) is
/// ≈ K_metric / 14.4. The default **K = 80** is a standard-response 15 mm
/// (½") pendent/upright head. // VERIFY — the exact K and the minimum operating
/// pressure depend on the listed head model (manufacturer datasheet); the values
/// here are general fire-engineering practice, not an SNI clause.
///
/// ## Branch-line friction
/// The friction from the riser/cross-main to the most-remote head along the
/// branch line is taken straight from the engine's Hazen–Williams primitive
/// ([headLossHazenWilliams]) at the design flow carried by that branch — no new
/// hydraulics are introduced here (this is ORCHESTRATION over `hydraulics.dart`,
/// per §12: the diagram/heatmap/sizing are renders of the one solve kernel).
///
/// Pure Dart, zero Flutter imports (§12 architecture guardrail).
library;

import 'dart:math' as math;

import '../hydraulics.dart';
import '../units.dart';
import 'fire_sprinkler.dart';

// ── Defaults (general fire-engineering practice — // VERIFY) ──────────────────

/// Default nominal K-factor of a standard 15 mm pendent/upright spray head,
/// in L/min/bar^0.5 (metric convention).
///
/// // VERIFY — head-model dependent (manufacturer datasheet); not an SNI clause.
const double kDefaultPendentKFactor = 80.0;

/// Default minimum operating pressure required at the most-remote head, in bar.
///
/// A standard spray head needs a minimum inlet pressure to form its spray
/// pattern. 0.5 bar is the common listed floor; many designers carry a higher
/// design floor (e.g. 0.7 bar) for margin. Expressed in bar to pair directly
/// with the K-factor law.
///
/// // VERIFY — head-model dependent; not an SNI clause.
const double kDefaultMinHeadPressureBar = 0.5;

/// Default Hazen–Williams roughness coefficient C for sprinkler branch piping
/// (black steel, the usual wet-pipe branch material).
///
/// // VERIFY — material/age dependent; C = 120 is the customary clean-steel
/// design value, not an SNI clause.
const double kSprinklerBranchHazenC = 120.0;

// ── The discharge law ─────────────────────────────────────────────────────────

/// Inlet pressure a head must see to discharge [flow] through a head of
/// K-factor [kFactor]: from `Q = K·√P` ⇒ `P = (Q / K)²` (returns a [Pressure]).
///
/// [kFactor] is in L/min/bar^0.5; [flow] is converted to L/min internally.
Pressure headPressureForFlow(FlowRate flow, double kFactor) {
  assert(kFactor > 0, 'K-factor must be positive');
  final qLpm = flow.inLitersPerMinute;
  final pBar = (qLpm / kFactor) * (qLpm / kFactor); // (Q/K)²  [bar]
  return Pressure.bar(pBar);
}

/// Discharge of a head of K-factor [kFactor] at inlet [pressure]:
/// `Q = K·√P` (returns a [FlowRate]). Inverse of [headPressureForFlow].
FlowRate headFlowForPressure(Pressure pressure, double kFactor) {
  assert(kFactor > 0, 'K-factor must be positive');
  final pBar = pressure.inBar;
  final qLpm = kFactor * _sqrt(pBar < 0 ? 0 : pBar);
  return FlowRate.litersPerMinute(qLpm);
}

double _sqrt(double x) => x <= 0 ? 0.0 : math.sqrt(x);

// ── Result ─────────────────────────────────────────────────────────────────

/// Output of [remoteAreaHydraulics]: the worst-head pressure/flow picture for a
/// sprinkler design, plus the minimum-pressure verdict.
final class SprinklerRemoteAreaResult {
  /// The base density/area design this hydraulic check augments.
  final SprinklerDesign design;

  /// Nominal K-factor used for the most-remote head (L/min/bar^0.5).
  final double kFactor;

  /// Flow the most-remote head actually delivers.
  ///
  /// Normally its share from the density/area split
  /// ([SprinklerDesign.flowPerSprinkler]); when that share would need less than
  /// [minOperatingPressure] the head is re-derived at the floor,
  /// `Q = K·√P_min`, and this carries the UPLIFTED flow (see
  /// [governedByMinimumPressure] and [densityShareFlow]).
  final FlowRate remoteHeadFlow;

  /// The un-uplifted density/area share for the most-remote head
  /// ([SprinklerDesign.flowPerSprinkler]) — equal to [remoteHeadFlow] unless
  /// [governedByMinimumPressure] is set.
  final FlowRate densityShareFlow;

  /// Inlet pressure the most-remote head needs to discharge [remoteHeadFlow]
  /// through K (`P = (Q/K)²`). Exactly [minOperatingPressure] when
  /// [governedByMinimumPressure] is set.
  final Pressure remoteHeadPressure;

  /// Minimum operating pressure required at the most-remote head.
  final Pressure minOperatingPressure;

  /// Friction head lost along the branch line from the cross-main to the most-
  /// remote head, carrying the head's own flow (Hazen–Williams).
  final Head branchLineFrictionHead;

  /// Pressure that must be present at the *base* of the branch (cross-main tap)
  /// to satisfy the remote head: remote-head pressure + branch friction.
  final Pressure branchBasePressure;

  /// Demand of the whole design area at [remoteHeadFlow] —
  /// `remoteHeadFlow × design.sprinklerCount`.
  ///
  /// Equals [SprinklerDesign.requiredFlow] in the density-governed case; HIGHER
  /// than it (the real supply demand) when [governedByMinimumPressure] is set.
  final FlowRate remoteAreaDemand;

  /// `true` when the density/area share alone would sit below
  /// [minOperatingPressure] and the head demand was therefore re-derived at the
  /// floor (`Q = K·√P_min`) — the design-area demand is then governed by the
  /// HEAD MINIMUM PRESSURE, not by the density.
  ///
  /// This, not [meetsMinimumPressure], is the informative flag: see the library
  /// doc for why the floor case is a design fact rather than a failure.
  final bool governedByMinimumPressure;

  /// `true` when [remoteHeadPressure] ≥ [minOperatingPressure].
  ///
  /// Kept for the report's pass/fail row, but note it is now true BY
  /// CONSTRUCTION: the floor is applied by uplifting the flow, so the remote
  /// head always sits at or above its minimum. The falsifiable information is
  /// [governedByMinimumPressure] + the resulting [remoteAreaDemand]. It can
  /// still read `false` only for a degenerate input (a non-finite / negative
  /// K-factor path guarded by the assert above).
  final bool meetsMinimumPressure;

  const SprinklerRemoteAreaResult({
    required this.design,
    required this.kFactor,
    required this.remoteHeadFlow,
    required this.densityShareFlow,
    required this.remoteHeadPressure,
    required this.minOperatingPressure,
    required this.branchLineFrictionHead,
    required this.branchBasePressure,
    required this.remoteAreaDemand,
    required this.meetsMinimumPressure,
    this.governedByMinimumPressure = false,
  });

  /// Human-readable verdict for the calc report / inspector.
  ///
  /// (The localized report picks its own sentence off [meetsMinimumPressure];
  /// this getter is the engine-side plain-ASCII wording.)
  String get verdict => governedByMinimumPressure
      ? 'Remote head OK - demand governed by head minimum pressure, not density'
      : meetsMinimumPressure
          ? 'Remote head OK'
          : 'Remote head under-pressure';
}

// ── Public API ───────────────────────────────────────────────────────────────

/// Run the remote-area hydraulic check for a sprinkler [design].
///
/// ## Method (ORCHESTRATION over `hydraulics.dart`)
/// 1. The most-remote head must pass at least its density/area share
///    `Q = design.flowPerSprinkler`.
/// 2. Its required inlet pressure is `P = (Q / K)²` ([headPressureForFlow]).
/// 3. **Minimum-pressure floor.** If that pressure is below
///    [minOperatingPressure], the head cannot discharge there — the demand is
///    RE-DERIVED at the floor, `Q = K·√P_min` ([headFlowForPressure]), and the
///    uplifted flow (and the resulting design-area demand) is what the rest of
///    the calculation uses. Flagged via
///    [SprinklerRemoteAreaResult.governedByMinimumPressure].
/// 4. The branch-line friction to that head is Hazen–Williams head loss at the
///    head's own (possibly uplifted) flow over [branchLength] in
///    [branchDiameter] ([headLossHazenWilliams]).
/// 5. The branch-base pressure that must be supplied is the head pressure plus
///    the branch friction (as pressure).
/// 6. The design-area demand is the per-head flow × the operating head count.
///
/// ## Parameters
/// * [design] — the density/area result whose remote head is checked.
/// * [kFactor] — head K-factor (L/min/bar^0.5; default [kDefaultPendentKFactor]).
/// * [minOperatingPressure] — minimum acceptable remote-head inlet pressure
///   (default [kDefaultMinHeadPressureBar] bar).
/// * [branchLength] — pipe length from the cross-main tap to the most-remote
///   head (default 20 m, a representative single branch line). // VERIFY: in a
///   drawn project this comes from §10 geometry.
/// * [branchDiameter] — branch-line inside diameter (default 25 mm / 1" branch).
/// * [hazenWilliamsC] — branch pipe roughness coefficient
///   (default [kSprinklerBranchHazenC]).
SprinklerRemoteAreaResult remoteAreaHydraulics({
  required SprinklerDesign design,
  double kFactor = kDefaultPendentKFactor,
  Pressure minOperatingPressure =
      const Pressure(kDefaultMinHeadPressureBar * 1e5),
  Length branchLength = const Length(20),
  Diameter branchDiameter = const Diameter(0.025),
  double hazenWilliamsC = kSprinklerBranchHazenC,
}) {
  assert(kFactor > 0, 'K-factor must be positive');

  final densityShare = design.flowPerSprinkler;

  // Pressure the remote head would need to discharge its density/area share
  // alone: P = (Q/K)².
  final densitySharePressure = headPressureForFlow(densityShare, kFactor);

  // Minimum-pressure floor: a listed head cannot discharge below its minimum
  // operating pressure, so when the density share lands under the floor the
  // head is re-derived AT the floor (Q = K·√P_min) and discharges more than the
  // density share. Density-governed designs take neither branch and are
  // byte-identical to the pre-floor behaviour.
  final governedByMinimum =
      densitySharePressure.pascals < minOperatingPressure.pascals;

  final FlowRate remoteFlow;
  final Pressure headPressure;
  if (governedByMinimum) {
    remoteFlow = headFlowForPressure(minOperatingPressure, kFactor);
    headPressure = minOperatingPressure;
  } else {
    remoteFlow = densityShare;
    headPressure = densitySharePressure;
  }

  // Branch-line friction at the head's own flow (Hazen–Williams primitive).
  final branchFriction = headLossHazenWilliams(
    flow: remoteFlow,
    length: branchLength,
    diameter: branchDiameter,
    hazenWilliamsC: hazenWilliamsC,
  );

  // Pressure that must be present at the branch base (head P + friction head).
  final branchBase = Pressure(
    headPressure.pascals + pressureFromHead(branchFriction).pascals,
  );

  // Design-area demand at the flow each head actually delivers.
  final areaDemand = FlowRate(
    remoteFlow.cubicMetersPerSecond * design.sprinklerCount,
  );

  final meets = headPressure.pascals >= minOperatingPressure.pascals;

  return SprinklerRemoteAreaResult(
    design: design,
    kFactor: kFactor,
    remoteHeadFlow: remoteFlow,
    densityShareFlow: densityShare,
    remoteHeadPressure: headPressure,
    minOperatingPressure: minOperatingPressure,
    branchLineFrictionHead: branchFriction,
    branchBasePressure: branchBase,
    remoteAreaDemand: areaDemand,
    meetsMinimumPressure: meets,
    governedByMinimumPressure: governedByMinimum,
  );
}
