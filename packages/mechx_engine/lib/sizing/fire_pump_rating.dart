/// Fire-pump rating-curve check — NFPA 20 / SNI 03-6570-2001 acceptance points,
/// jockey-pump recommendation, and duty/standby designation (§P5 fire).
///
/// ## Why this module exists
/// [designStandpipe] (in `fire_standpipe.dart`) sizes the fire pump for ONE
/// duty point — the rated flow/head. A listed fire pump must additionally pass a
/// *rating-curve* acceptance test that fixes the head at the **churn** (0 % flow)
/// and **overload** (150 % flow) points relative to the rated head. This module
/// derives those three points, selects the motor on the governing one and
/// reports whether that motor fits the STANDARD FRAME ladder, plus a
/// jockey-pump recommendation and a duty/standby designation.
///
/// ## The NFPA 20 acceptance curve
/// For a centrifugal fire pump, the certified curve must satisfy:
///
///   • Churn  (0 % rated flow):   head ≤ **140 %** of rated head
///   • Rated  (100 % rated flow): head  =  **100 %** of rated head (definition)
///   • Overload (150 % rated flow): head ≥ **65 %** of rated head
///
/// We MODEL the as-built curve with the three points at exactly the limiting
/// ratios (churn 140 %, overload 65 %) — i.e. a representative compliant pump.
/// The shaft power is then computed at each point from the engine's
/// [shaftPower] primitive. The 150 % point usually governs the *motor* selection
/// (power ∝ Q·H rises even though head falls), so the motor is sized on it.
///
/// // VERIFY — the 140 % churn ceiling and 65 % overload floor are the NFPA 20
/// acceptance *limits*, not a specific pump's curve. A real selected pump's
/// certified curve must be checked against these. The jockey-flow fraction and
/// duty/standby convention are general fire-engineering practice, not an SNI
/// clause. All flagged `secondarySource` until checked against the official
/// SNI 03-6570-2001 / NFPA 20 text.
///
/// Pure Dart, zero Flutter imports (§12 architecture guardrail).
library;

import '../hydraulics.dart';
import '../units.dart';
import 'pump.dart';

// ── Acceptance-curve constants (// VERIFY — NFPA 20 limits) ───────────────────

/// Maximum churn (0 % flow) head as a fraction of rated head (NFPA 20: ≤ 140 %).
const double kChurnHeadRatio = 1.40;

/// Minimum overload (150 % flow) head as a fraction of rated head (NFPA 20:
/// ≥ 65 %).
const double kOverloadHeadRatio = 0.65;

/// The overload flow point as a fraction of rated flow (NFPA 20: 150 %).
const double kOverloadFlowRatio = 1.50;

/// Default jockey (pressure-maintenance) pump flow as a fraction of the main
/// pump's rated flow. 1 % is the customary lower bound (NFPA 20 sizes the jockey
/// to make up allowable leakage in ~10 min, typically ~1 % of rated flow).
///
/// // VERIFY — general practice, not an SNI clause.
const double kJockeyFlowFraction = 0.01;

// ── Curve-point result ────────────────────────────────────────────────────────

/// One point on the fire-pump rating curve (churn / rated / overload).
final class PumpCurvePoint {
  /// Label of this point ('churn', 'rated', or 'overload').
  final String label;

  /// Flow at this point.
  final FlowRate flow;

  /// Head at this point.
  final Head head;

  /// Useful (hydraulic) power at this point: P = ρ·g·Q·H.
  final Power hydraulicPower;

  /// Shaft (brake) power at this point: P_hyd / η_pump.
  final Power shaftPower;

  const PumpCurvePoint({
    required this.label,
    required this.flow,
    required this.head,
    required this.hydraulicPower,
    required this.shaftPower,
  });
}

// ── Designation ───────────────────────────────────────────────────────────────

/// Whether a pump is the lead (duty) or the back-up (standby) unit.
enum PumpDesignation {
  /// Lead pump — runs first on demand.
  duty,

  /// Back-up pump — sized identically, started on duty-pump failure / low
  /// pressure.
  standby,
}

// ── Full rating result ────────────────────────────────────────────────────────

/// Output of [checkFirePumpRating]: the three curve points, the motor selected
/// on the governing (overload) point, the jockey-pump recommendation, and the
/// duty/standby designation.
final class FirePumpRatingResult {
  /// Rated (design) flow the curve is built around.
  final FlowRate ratedFlow;

  /// Rated (design) head at the rated flow.
  final Head ratedHead;

  /// Churn point (0 % flow, ≤ 140 % rated head).
  final PumpCurvePoint churn;

  /// Rated point (100 % flow, 100 % rated head).
  final PumpCurvePoint rated;

  /// Overload point (150 % flow, ≥ 65 % rated head).
  final PumpCurvePoint overload;

  /// Smallest standard motor covering the worst-case (overload) shaft power.
  final Power selectedMotor;

  /// `true` when [selectMotor] saturated — the largest STANDARD MOTOR frame is
  /// still below the governing shaft power, so [selectedMotor] under-states
  /// what this duty actually needs.
  ///
  /// M19 — this says nothing about the pump *curve*: the acceptance ratios are
  /// satisfied by construction here. It is purely a MOTOR-CATALOGUE limit, and
  /// the action is to specify a custom motor frame or to split the duty across
  /// paired pumps. See [verdict].
  final bool oversized;

  /// Recommended jockey-pump flow (pressure maintenance).
  final FlowRate jockeyFlow;

  /// Recommended jockey-pump head — slightly above the main pump's churn head
  /// so the jockey holds the system at the higher of the two static pressures.
  final Head jockeyHead;

  /// Designation of the *main* pump described by this result.
  final PumpDesignation designation;

  /// `true` when a standby (back-up) pump of equal duty is recommended.
  final bool standbyRecommended;

  const FirePumpRatingResult({
    required this.ratedFlow,
    required this.ratedHead,
    required this.churn,
    required this.rated,
    required this.overload,
    required this.selectedMotor,
    required this.oversized,
    required this.jockeyFlow,
    required this.jockeyHead,
    required this.designation,
    required this.standbyRecommended,
  });

  /// Human-readable verdict for the calc report / inspector (plain ASCII).
  ///
  /// M19 — the old wording ('Oversized pump curve') named the wrong thing: the
  /// flag it reads is the STANDARD MOTOR ladder saturating, not a curve
  /// acceptance failure. It now names the true condition and the action.
  String get verdict => oversized
      ? 'Motor above standard frame range - specify a custom motor or duty pairs'
      : 'Motor within standard frame range';
}

// ── Public API ───────────────────────────────────────────────────────────────

/// Build the NFPA 20 rating-curve check for a fire pump rated [ratedFlow] @
/// [ratedHead].
///
/// ## Method (ORCHESTRATION over `hydraulics.dart` + `pump.dart`)
/// 1. Churn point: Q = 0, H = [kChurnHeadRatio] · ratedHead. (Zero flow ⇒ zero
///    hydraulic/shaft power — it only constrains the static pressure, surfaced
///    via the jockey head.)
/// 2. Rated point: Q = ratedFlow, H = ratedHead.
/// 3. Overload point: Q = [kOverloadFlowRatio] · ratedFlow,
///    H = [kOverloadHeadRatio] · ratedHead.
/// 4. Each point's shaft power = [shaftPower] at [pumpEfficiency].
/// 5. The motor is selected (via [selectMotor]) on the *largest* shaft power
///    across the points — normally the overload point.
/// 6. The jockey pump is [kJockeyFlowFraction] of rated flow at the churn head.
/// 7. A standby pump of equal duty is recommended (the [designation] of *this*
///    result is the duty pump unless [designation] is overridden).
///
/// ## Parameters
/// * [ratedFlow], [ratedHead] — the pump's rated duty point (e.g. from
///   [designStandpipe]).
/// * [pumpEfficiency] — overall pump efficiency η (default 0.70). // VERIFY
///   against the certified curve per SNI 03-6570-2001.
/// * [jockeyFlowFraction] — jockey flow as a fraction of rated flow
///   (default [kJockeyFlowFraction]).
/// * [designation] — designation of the main pump (default
///   [PumpDesignation.duty]).
/// * [standbyRecommended] — whether to recommend a back-up pump (default true,
///   the NFPA 20 norm for life-safety systems).
FirePumpRatingResult checkFirePumpRating({
  required FlowRate ratedFlow,
  required Head ratedHead,
  double pumpEfficiency = 0.70,
  double jockeyFlowFraction = kJockeyFlowFraction,
  PumpDesignation designation = PumpDesignation.duty,
  bool standbyRecommended = true,
}) {
  assert(
    pumpEfficiency > 0 && pumpEfficiency <= 1,
    'pumpEfficiency must be in (0, 1]',
  );
  assert(jockeyFlowFraction > 0, 'jockeyFlowFraction must be positive');

  PumpCurvePoint point(String label, FlowRate q, Head h) {
    final hyd = hydraulicPower(flow: q, head: h);
    final shaft = shaftPower(flow: q, head: h, efficiency: pumpEfficiency);
    return PumpCurvePoint(
      label: label,
      flow: q,
      head: h,
      hydraulicPower: hyd,
      shaftPower: shaft,
    );
  }

  // 1. Churn (0 % flow): head ≤ 140 % rated → modelled at the 140 % ceiling.
  final churn = point(
    'churn',
    const FlowRate(0),
    Head(ratedHead.meters * kChurnHeadRatio),
  );

  // 2. Rated (100 % flow, 100 % head).
  final rated = point('rated', ratedFlow, ratedHead);

  // 3. Overload (150 % flow, 65 % head floor).
  final overload = point(
    'overload',
    FlowRate(ratedFlow.cubicMetersPerSecond * kOverloadFlowRatio),
    Head(ratedHead.meters * kOverloadHeadRatio),
  );

  // Governing shaft power for motor selection (overload usually wins; take max).
  final governingShaftW = [
    churn.shaftPower.watts,
    rated.shaftPower.watts,
    overload.shaftPower.watts,
  ].reduce((a, b) => a > b ? a : b);
  final governingShaft = Power(governingShaftW);
  final selectedMotor = selectMotor(governingShaft);

  // M19: this flag means the STANDARD MOTOR ladder saturated — selectMotor
  // returned the largest frame yet it is still below the governing shaft power.
  // It is a motor-catalogue limit, NOT a rating-curve acceptance failure.
  final oversized =
      selectedMotor.inKiloWatts < governingShaft.inKiloWatts - 1e-9;

  // Jockey pump: small flow, head just above the main pump's churn head.
  final jockeyFlow =
      FlowRate(ratedFlow.cubicMetersPerSecond * jockeyFlowFraction);
  final jockeyHead = Head(churn.head.meters + 5.0); // +5 m maintenance margin

  return FirePumpRatingResult(
    ratedFlow: ratedFlow,
    ratedHead: ratedHead,
    churn: churn,
    rated: rated,
    overload: overload,
    selectedMotor: selectedMotor,
    oversized: oversized,
    jockeyFlow: jockeyFlow,
    jockeyHead: jockeyHead,
    designation: designation,
    standbyRecommended: standbyRecommended,
  );
}
