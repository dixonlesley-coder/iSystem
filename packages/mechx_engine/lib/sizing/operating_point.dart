/// Pump/fan operating-point + NPSH analysis — the SYSTEM curve × the
/// EQUIPMENT curve, their intersection (the true operating point), a stability
/// flag, and (for pumps) an available-vs-required NPSH cavitation check.
///
/// ## Why this module exists
/// `pump.dart` / `fan.dart` size the machine for ONE design duty point
/// (Q_design, H_design) and pick a motor. But a real pump/fan does not run at
/// the duty point unless the *system* it is connected to demands exactly that.
/// Where the rising **system-resistance curve** (head/pressure the pipework or
/// ductwork imposes as a function of flow) crosses the falling **equipment
/// curve** (head/pressure the machine can produce as a function of flow) is the
/// TRUE operating point. This module composes those two curves, finds their
/// intersection, flags an unstable match, and (for pumps) estimates the
/// net-positive-suction-head margin against cavitation.
///
/// ## The two curves (both modelled, both // VERIFY)
///   • System curve (pump):  H_sys(Q) = H_static + k·Q²
///     — a fixed lift/residual `H_static` plus a friction term that grows with
///       the square of flow (Darcy/Hazen-Williams loss ∝ Q²). `k` (the system
///       resistance coefficient, Pa·s²/m⁶ when applied to a pressure, or here
///       m·s²/m⁶ as a head coefficient) is a DESIGN INPUT — it is NEVER fitted
///       from the solved network here; it is supplied by the caller (back-solved
///       from the design duty, or a user estimate). Default: back-solve k from
///       the design duty so the system curve passes through (Q_design, H_design).
///   • System curve (fan):   Δp_sys(Q) = Δp_static + k·Q²  — Δp_static is zero
///     for an ordinary duct system (the whole resistance is velocity²-driven)
///     and non-zero only for a fan holding a fixed differential (stairwell
///     pressurisation, a pressurised plenum).
///   • Equipment curve:      H_eq(Q) = H_shutoff − a·Q²  (pump),
///                            Δp_eq(Q) = Δp_shutoff − a·Q²  (fan)
///     — the classic falling parabola of a centrifugal machine: a shutoff
///       (zero-flow) head and a droop coefficient `a`. We MODEL it as a
///       representative parabola pinned to the design point (so the equipment
///       curve passes through (Q_design, H_design)) with a shutoff head a fixed
///       fraction above the design head. The shutoff fraction + the parabola
///       shape are // VERIFY — a representative selection, not a specific pump's
///       certified curve.
///
/// ## Intersection (closed form)
/// With both curves quadratic in Q the intersection is closed-form, no
/// iteration needed: setting H_static + k·Q² = H_shutoff − a·Q² gives
///   Q_op = √((H_shutoff − H_static) / (k + a)).
/// The companion guards (no real root, shallow crossing) are folded into a
/// [PumpOperatingPoint.stable] / [FanOperatingPoint.stable] flag rather than
/// throwing.
///
/// ## The shallow-crossing (stability) test — M12
/// The two curves' SLOPES at the crossing are
///   H_sys'(Q_op) = +2k·Q_op        H_eq'(Q_op) = −2a·Q_op
/// so they part at a slope difference
///   Δm = H_sys' − H_eq' = 2(k + a)·Q_op.
/// A relative disturbance ε of the operating head (a fouled strainer, a
/// throttled branch, the tolerance band on a real machine's curve) moves the
/// crossing by δQ = ε·H_op / Δm, so the duty's RELATIVE FLOW SENSITIVITY is the
/// dimensionless number
///   S = (δQ/Q_op) / ε = H_op / (Q_op·Δm) = H_op / (2(k + a)·Q_op²)
///                     = H_op / (2·(H_shutoff − H_static))
/// using (k + a)·Q_op² = H_shutoff − H_static at the crossing. S is "percent of
/// flow swing per percent of head swing": a healthy match sits well under 1
/// (the default 50/50 pump split gives S = 30/(2·22.5) = 0.667), and S blows up
/// as H_static approaches H_shutoff — the curves then meet tangentially near
/// zero flow and the duty hunts. [kOperatingPointFlowSensitivityLimit] is the
/// threshold. (The previous test compared Δm against Δm/2 and so reduced to the
/// constant `2 < 0.05` — it could never fire.)
///
/// ## NPSH (pumps only) — all terms // VERIFY
///   NPSH_available = (P_atm − P_vapour)/(ρ·g) ± h_static_suction − h_friction_suction
///   NPSH_required is estimated from the SUCTION side — a suction-specific-speed
///   correlation (see [kSuctionSpecificSpeed]) with a conservative small-pump
///   floor — NOT as a fraction of the total system head, which has no physical
///   relation to the suction condition. Cavitation risk is flagged
///   CONSERVATIVELY when NPSH_available < safetyMargin × NPSH_required
///   (default 1.5, the customary suction-margin rule of thumb).
///
/// // VERIFY — the curve coefficients (shutoff fraction, droop, NPSH_required
/// estimate, safety margin) are a SIMPLIFIED representative model, flagged
/// `secondarySource`. They are NOT a specific manufacturer's certified curve and
/// must be replaced by the selected machine's published data for a real design.
///
/// Pure Dart, zero Flutter imports (§12 architecture guardrail).
library;

import 'dart:math' as math;

import '../hydraulics.dart';
import '../units.dart';

// ── Representative-curve constants (// VERIFY — simplified model) ──────────────

/// Shutoff (zero-flow) head as a fraction of the design head for the modelled
/// equipment curve. A centrifugal pump/fan typically develops ~115–135 % of its
/// best-efficiency head at shutoff; 1.25 (125 %) is a representative middle.
///
/// // VERIFY — representative, not a certified curve. `secondarySource`.
const double kEquipmentShutoffHeadRatio = 1.25;

/// Standard atmospheric pressure at sea level (Pa) — the suction-side reference
/// for NPSH-available. // VERIFY — site elevation lowers this.
const double kStandardAtmosphericPa = 101325.0;

/// Vapour pressure of water at ≈20 °C (Pa) — the cavitation threshold term in
/// NPSH-available. // VERIFY — strongly temperature dependent (rises fast with
/// fluid temperature; hot-water pumps need this updated).
const double kWaterVapourPressure20CPa = 2339.0;

/// Suction-side friction head as a fraction of the (modelled) static suction
/// head, a first-pass allowance when no detailed suction pipework is given.
///
/// // VERIFY — general allowance, not an SNI clause. `secondarySource`.
const double kSuctionFrictionFraction = 0.10;

/// Suction specific speed used to estimate NPSH_required (M12).
///
///   N_ss = n·√Q / NPSH_r^0.75      ⇒   NPSH_r = (n·√Q / N_ss)^(4/3)
///
/// with `n` in rpm, `Q` in m³/s and NPSH_r in metres (the metric convention).
/// Standard clean-water centrifugal pumps sit around 160–220 in these units; a
/// LOW value is the conservative choice (it yields a HIGHER NPSH_r), so 160 is
/// used. Note this keys NPSH_r to the SUCTION-side variables — speed and flow —
/// not to the total system head the pump happens to develop.
///
/// // VERIFY `notAnSniClause` — a correlation, not the manufacturer's certified
/// NPSH_r curve; replace with the selected machine's published data.
const double kSuctionSpecificSpeed = 160.0;

/// Assumed rotational speed for the NPSH_required correlation, rpm.
///
/// 2900 rpm is the nominal 2-pole 50 Hz speed of the small end-suction /
/// multistage pumps this engine sizes, and is the conservative assumption (a
/// 1450 rpm 4-pole machine needs materially less NPSH at the same flow).
///
/// // VERIFY `notAnSniClause` — an assumption, not a standards value.
const double kAssumedPumpSpeedRpm = 2900.0;

/// Conservative floor on the estimated NPSH_required, metres.
///
/// Below a few litres per second the correlation trends toward implausibly
/// small values; listed small pumps rarely publish an NPSH_r under ~0.5 m, so
/// the estimate never reports less than this.
///
/// // VERIFY `notAnSniClause` — a conservative floor, not a standards value.
const double kMinNpshRequiredM = 0.5;

/// Relative-flow-sensitivity limit above which the curve crossing is reported
/// as ill-conditioned (shallow) — see the library doc's stability algebra.
///
/// `S` is the percent of flow swing per percent of head swing at the crossing;
/// 5 means "a 1 % head disturbance moves the duty more than 5 % in flow", by
/// which point the operating point is not usefully determined.
///
/// // VERIFY `notAnSniClause` — an engineering threshold, not a standards value.
const double kOperatingPointFlowSensitivityLimit = 5.0;

/// Cavitation safety margin: NPSH_available must exceed this multiple of
/// NPSH_required or cavitation risk is flagged. 1.5 (a 0.5 m + 30 % style
/// margin folded to a ratio) is the customary suction rule of thumb.
///
/// // VERIFY — general practice, not an SNI clause. `secondarySource`.
const double kNpshSafetyMargin = 1.5;

// ── Shared crossing conditioning (internal) ───────────────────────────────────

/// Relative flow sensitivity `S` of the system × equipment curve crossing, in
/// "fraction of flow swing per fraction of head/pressure swing".
///
/// Derived in the library doc from the two curves' slopes at Q_op:
///   S = H_op / (2·(H_shutoff − H_static)).
/// Works unchanged for the fan (pressures in place of heads, H_static = the
/// system's fixed differential, normally 0). Returns infinity when there is no
/// positive margin between shutoff and static — the degenerate/no-root case.
double _crossingFlowSensitivity({
  required double operatingValue,
  required double shutoffValue,
  required double staticValue,
}) {
  final margin = shutoffValue - staticValue;
  if (margin <= 0) return double.infinity;
  return operatingValue / (2.0 * margin);
}

// ── Pump operating point ──────────────────────────────────────────────────────

/// The pump system × equipment curve intersection + NPSH cavitation check.
///
/// All heads are in metres of fluid. The curve coefficients are // VERIFY (a
/// representative model, not certified data) — see the library doc.
class PumpOperatingPoint {
  /// Static lift/residual the system imposes at zero flow, H_static (m).
  final Head systemStaticHead;

  /// System resistance coefficient k in H_sys = H_static + k·Q² (head per
  /// (m³/s)²). DESIGN INPUT (// VERIFY) — never fitted from the network here.
  final double systemResistanceK;

  /// Equipment shutoff (zero-flow) head, H_shutoff (m). // VERIFY.
  final Head equipmentShutoffHead;

  /// Equipment droop coefficient a in H_eq = H_shutoff − a·Q². // VERIFY.
  final double equipmentDroopA;

  /// True operating flow where the two curves cross (m³/s). Zero when no real
  /// intersection exists (the machine cannot overcome the static head).
  final FlowRate operatingFlow;

  /// Head at the operating flow (m), evaluated on the system curve.
  final Head operatingHead;

  /// The design duty point this analysis composes over (m³/s, m).
  final FlowRate designFlow;
  final Head designHead;

  /// False when the intersection is ill-conditioned — no real root (the machine
  /// is starved by an excessive static head), or the curves cross at a SHALLOW
  /// angle, measured as the relative flow sensitivity
  /// `S = H_op / (2·(H_shutoff − H_static))` exceeding
  /// [kOperatingPointFlowSensitivityLimit] (see the library doc for the slope
  /// algebra). A stable design wants the two curves to part at a clear angle so
  /// a small head disturbance barely moves the duty.
  final bool stable;

  /// Available net positive suction head at the operating flow (m).
  final Head npshAvailable;

  /// // VERIFY required net positive suction head estimate at the operating
  /// flow (m) — from the suction-specific-speed correlation
  /// ([kSuctionSpecificSpeed], [kAssumedPumpSpeedRpm]) with the
  /// [kMinNpshRequiredM] floor. Zero when there is no operating flow. NOT a
  /// certified NPSH_r curve.
  final Head npshRequired;

  /// True when NPSH_available < [kNpshSafetyMargin] × NPSH_required — a
  /// conservative cavitation-risk flag.
  final bool cavitationRisk;

  const PumpOperatingPoint({
    required this.systemStaticHead,
    required this.systemResistanceK,
    required this.equipmentShutoffHead,
    required this.equipmentDroopA,
    required this.operatingFlow,
    required this.operatingHead,
    required this.designFlow,
    required this.designHead,
    required this.stable,
    required this.npshAvailable,
    required this.npshRequired,
    required this.cavitationRisk,
  });

  /// Operating flow as a fraction of the design flow (1.0 ⇒ runs exactly at the
  /// duty point). Useful for the report. Returns 0 if there is no design flow.
  double get flowRatio => designFlow.cubicMetersPerSecond > 0
      ? operatingFlow.cubicMetersPerSecond / designFlow.cubicMetersPerSecond
      : 0.0;
}

/// Compose a [PumpOperatingPoint] over a sized duty point.
///
/// - [designFlow] / [designHead] — the duty the pump was sized for.
/// - [systemStaticHead]          — the system's fixed lift/residual (the
///   static component of H_sys). When null it is taken as the design head minus
///   the design friction implied by [systemResistanceK]; when that too is
///   absent, half the design head (a representative static/friction split).
/// - [systemResistanceK]         — DESIGN INPUT k (// VERIFY). When null it is
///   BACK-SOLVED so the system curve passes through the design point:
///   k = (H_design − H_static) / Q_design².
/// - [suctionStaticHead]         — height of the fluid surface above (positive)
///   or below (negative) the pump centreline, for NPSH. Defaults to 0
///   (flooded-suction at the centreline).
/// - [atmosphericPressure] / [vapourPressure] — NPSH terms (// VERIFY).
///
/// All coefficients are // VERIFY representative values — see the library doc.
PumpOperatingPoint computePumpOperatingPoint({
  required FlowRate designFlow,
  required Head designHead,
  Head? systemStaticHead,
  double? systemResistanceK,
  Head suctionStaticHead = const Head(0),
  double atmosphericPressure = kStandardAtmosphericPa,
  double vapourPressure = kWaterVapourPressure20CPa,
  double density = defaultWaterDensity,
  double gravity = standardGravity,
}) {
  final qd = designFlow.cubicMetersPerSecond;
  final hd = designHead.meters;

  // ── System curve: H_sys(Q) = H_static + k·Q² ───────────────────────────────
  // k is a DESIGN INPUT. When supplied with a static head, use both verbatim.
  // When k is supplied but no static head, the static head is the design head
  // minus the friction k·Q_design² implies. When k is absent, back-solve it from
  // the static head (or a representative 50/50 static:friction split) so the
  // system curve passes through the design point.
  final double hStatic;
  final double k;
  if (systemResistanceK != null && systemStaticHead != null) {
    k = systemResistanceK;
    hStatic = systemStaticHead.meters;
  } else if (systemResistanceK != null) {
    k = systemResistanceK;
    hStatic = hd - k * qd * qd;
  } else if (systemStaticHead != null) {
    hStatic = systemStaticHead.meters;
    // Back-solve k so H_static + k·Q_design² = H_design.
    k = (qd > 0) ? (hd - hStatic) / (qd * qd) : 0.0;
  } else {
    // No inputs: representative 50 % static / 50 % friction split at design.
    hStatic = 0.5 * hd;
    k = (qd > 0) ? (0.5 * hd) / (qd * qd) : 0.0;
  }

  // ── Equipment curve: H_eq(Q) = H_shutoff − a·Q² ────────────────────────────
  // Pinned to the design point: H_eq(Q_design) = H_design, with a representative
  // shutoff head a fixed fraction above the design head. // VERIFY.
  final hShutoff = hd * kEquipmentShutoffHeadRatio;
  final a = (qd > 0) ? (hShutoff - hd) / (qd * qd) : 0.0;

  // ── Intersection (closed form) ─────────────────────────────────────────────
  // H_static + k·Q² = H_shutoff − a·Q²  ⇒  Q_op = √((H_shutoff − H_static)/(k+a)).
  final headMargin = hShutoff - hStatic;
  final den = k + a;
  double qOp;
  var stable = true;
  if (headMargin <= 0 || den <= 0) {
    // No real root: the machine cannot overcome the static head (or both curves
    // are flat). Operating point collapses to zero flow — clearly unstable.
    qOp = 0.0;
    stable = false;
  } else {
    qOp = math.sqrt(headMargin / den);
  }
  final hOp = hStatic + k * qOp * qOp;

  // Shallow-crossing test (M12): the duty's relative flow sensitivity at the
  // crossing, S = H_op / (2·(H_shutoff − H_static)) — see the library doc for
  // the slope algebra. Large S ⇒ the curves part at a shallow angle and a small
  // head disturbance swings the flow a long way (the duty hunts).
  if (stable) {
    final sensitivity = _crossingFlowSensitivity(
      operatingValue: hOp,
      shutoffValue: hShutoff,
      staticValue: hStatic,
    );
    if (sensitivity > kOperatingPointFlowSensitivityLimit) stable = false;
  }

  // ── NPSH (// VERIFY estimates) ─────────────────────────────────────────────
  // NPSH_available = (P_atm − P_vapour)/(ρ·g) + h_suction_static − h_suction_fric
  final atmHead = atmosphericPressure / (density * gravity);
  final vapHead = vapourPressure / (density * gravity);
  final hSuctionStatic = suctionStaticHead.meters;
  // Suction friction: a fraction of the |static suction| as a first-pass
  // allowance (// VERIFY — replace with the real suction pipework loss).
  final hSuctionFric = kSuctionFrictionFraction * hSuctionStatic.abs();
  final npshA = atmHead - vapHead + hSuctionStatic - hSuctionFric;

  // NPSH_required (M12): a SUCTION-SIDE estimate from the suction-specific-speed
  // correlation at the OPERATING flow,
  //   NPSH_r = (n·√Q_op / N_ss)^(4/3)   (n rpm, Q m³/s, NPSH_r m)
  // floored at kMinNpshRequiredM. It depends on speed and flow — the variables
  // that actually set the suction condition — and NOT on the total head the
  // pump develops (the old `0.15 × H_design` rule made a flooded-suction 60 m
  // pump demand 9 m of NPSH_r and so flagged cavitation on a perfectly good
  // installation). Zero flow ⇒ no meaningful cavitation question.
  double npshR = 0.0;
  if (qOp > 0) {
    final correlated = math
        .pow(kAssumedPumpSpeedRpm * math.sqrt(qOp) / kSuctionSpecificSpeed,
            4.0 / 3.0)
        .toDouble();
    npshR = correlated > kMinNpshRequiredM ? correlated : kMinNpshRequiredM;
  }

  final cavitation = npshR > 0 && npshA < kNpshSafetyMargin * npshR;

  return PumpOperatingPoint(
    systemStaticHead: Head(hStatic),
    systemResistanceK: k,
    equipmentShutoffHead: Head(hShutoff),
    equipmentDroopA: a,
    operatingFlow: FlowRate(qOp),
    operatingHead: Head(hOp),
    designFlow: designFlow,
    designHead: designHead,
    stable: stable,
    npshAvailable: Head(npshA),
    npshRequired: Head(npshR),
    cavitationRisk: cavitation,
  );
}

// ── Fan operating point ───────────────────────────────────────────────────────

/// The fan system × equipment curve intersection. Pressures in pascals; no
/// NPSH (cavitation is a liquid phenomenon). Curve coefficients are // VERIFY.
class FanOperatingPoint {
  /// Fixed (flow-independent) differential the system imposes, Δp_static (Pa).
  ///
  /// Zero for an ordinary duct system — all of its resistance is velocity²
  /// driven. Non-zero for a fan that must hold a fixed differential regardless
  /// of flow (a stairwell-pressurisation fan, a fan discharging into a
  /// pressurised plenum), which is the case that can make the curve crossing
  /// shallow. See [stable].
  final Pressure systemStaticPressure;

  /// System resistance coefficient k in Δp_sys = Δp_static + k·Q² (Pa per
  /// (m³/s)²). DESIGN INPUT (// VERIFY) — never fitted from the duct solve here.
  final double systemResistanceK;

  /// Equipment shutoff (zero-flow) static pressure, Δp_shutoff (Pa). // VERIFY.
  final Pressure equipmentShutoffPressure;

  /// Equipment droop coefficient a in Δp_eq = Δp_shutoff − a·Q². // VERIFY.
  final double equipmentDroopA;

  /// True operating flow where the two curves cross (m³/s).
  final FlowRate operatingFlow;

  /// Static pressure at the operating flow (Pa), on the system curve.
  final Pressure operatingPressure;

  /// The design duty point this analysis composes over (m³/s, Pa).
  final FlowRate designAirflow;
  final Pressure designPressure;

  /// False when the intersection is ill-conditioned (no real root, or a SHALLOW
  /// crossing by the same relative-flow-sensitivity test as
  /// [PumpOperatingPoint.stable], with Δp in place of head).
  ///
  /// Note the honest consequence of the modelled curves: with the ordinary
  /// zero-static duct system curve the sensitivity reduces to
  /// `S = k / (2(k + a)) < 0.5`, so an ordinary duct fan is ALWAYS
  /// well-conditioned and this flag stays true — as it should. It fires for a
  /// fan asked to hold a fixed [systemStaticPressure] close to its own shutoff
  /// pressure (stairwell pressurisation is the classic case), and for the
  /// degenerate no-root inputs.
  final bool stable;

  const FanOperatingPoint({
    this.systemStaticPressure = const Pressure(0),
    required this.systemResistanceK,
    required this.equipmentShutoffPressure,
    required this.equipmentDroopA,
    required this.operatingFlow,
    required this.operatingPressure,
    required this.designAirflow,
    required this.designPressure,
    required this.stable,
  });

  /// Operating flow as a fraction of the design airflow (1.0 ⇒ runs exactly at
  /// the duty point). Returns 0 if there is no design airflow.
  double get flowRatio => designAirflow.cubicMetersPerSecond > 0
      ? operatingFlow.cubicMetersPerSecond / designAirflow.cubicMetersPerSecond
      : 0.0;
}

/// Compose a [FanOperatingPoint] over a sized fan duty point.
///
/// - [designAirflow] / [designPressure] — the duty the fan was sized for.
/// - [systemStaticPressure]             — the system's FIXED differential (see
///   [FanOperatingPoint.systemStaticPressure]). Defaults to zero, the ordinary
///   duct system, which reproduces the previous behaviour exactly.
/// - [systemResistanceK]                — DESIGN INPUT k (// VERIFY) for
///   Δp_sys = Δp_static + k·Q². When null it is BACK-SOLVED so the system curve
///   passes through the design point: k = (Δp_design − Δp_static) / Q_design²
///   (clamped at 0, since a system curve cannot fall with flow).
///
/// An ordinary duct system curve has no static term (Δp_sys(0) = 0): all the
/// duct resistance is velocity²-driven. The equipment curve is pinned to the
/// design point with a representative shutoff fraction (// VERIFY).
FanOperatingPoint computeFanOperatingPoint({
  required FlowRate designAirflow,
  required Pressure designPressure,
  Pressure systemStaticPressure = const Pressure(0),
  double? systemResistanceK,
}) {
  final qd = designAirflow.cubicMetersPerSecond;
  final pd = designPressure.pascals;
  final pStatic = systemStaticPressure.pascals;

  // System curve: Δp_sys(Q) = Δp_static + k·Q². k is a DESIGN INPUT; when
  // absent, back-solve through the design point (never negative).
  final double k;
  if (systemResistanceK != null) {
    k = systemResistanceK;
  } else {
    final backSolved = (qd > 0) ? (pd - pStatic) / (qd * qd) : 0.0;
    k = backSolved > 0 ? backSolved : 0.0;
  }

  // Equipment curve pinned to the design point with a representative shutoff.
  final pShutoff = pd * kEquipmentShutoffHeadRatio;
  final a = (qd > 0) ? (pShutoff - pd) / (qd * qd) : 0.0;

  // Intersection: Δp_static + k·Q² = Δp_shutoff − a·Q²
  //             ⇒ Q_op = √((Δp_shutoff − Δp_static) / (k + a)).
  final pressureMargin = pShutoff - pStatic;
  final den = k + a;
  double qOp;
  var stable = true;
  if (pressureMargin <= 0 || den <= 0) {
    qOp = 0.0;
    stable = false;
  } else {
    qOp = math.sqrt(pressureMargin / den);
  }
  final pOp = pStatic + k * qOp * qOp;

  // Shallow-crossing test (M12) — the same relative flow sensitivity as the
  // pump, S = Δp_op / (2·(Δp_shutoff − Δp_static)); see the library doc.
  if (stable) {
    final sensitivity = _crossingFlowSensitivity(
      operatingValue: pOp,
      shutoffValue: pShutoff,
      staticValue: pStatic,
    );
    if (sensitivity > kOperatingPointFlowSensitivityLimit) stable = false;
  }

  return FanOperatingPoint(
    systemStaticPressure: Pressure(pStatic),
    systemResistanceK: k,
    equipmentShutoffPressure: Pressure(pShutoff),
    equipmentDroopA: a,
    operatingFlow: FlowRate(qOp),
    operatingPressure: Pressure(pOp),
    designAirflow: designAirflow,
    designPressure: designPressure,
    stable: stable,
  );
}
