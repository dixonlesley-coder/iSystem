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
///   • System curve (fan):   Δp_sys(Q) = k·Q²  (no static term — duct systems
///     have negligible fixed pressure; the whole resistance is velocity²-driven).
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
/// The companion Newton-style guards (no real root, near-flat curves) are folded
/// into a [stable] flag rather than throwing.
///
/// ## NPSH (pumps only) — all terms // VERIFY
///   NPSH_available = (P_atm − P_vapour)/(ρ·g) ± h_static_suction − h_friction_suction
///   We model NPSH_required as a // VERIFY estimate that grows with flow
///   (NPSH_r ∝ Q²/D⁴-ish — here a simple Q-scaled estimate). Cavitation risk is
///   flagged CONSERVATIVELY when NPSH_available < safetyMargin × NPSH_required
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

/// Required-NPSH estimate at the design flow as a fraction of the design head —
/// a // VERIFY stand-in for the manufacturer's NPSH_r curve. NPSH_r grows with
/// flow² in reality; we scale this design-point value by (Q/Q_design)².
///
/// // VERIFY — representative, NOT a certified NPSH_r curve. `secondarySource`.
const double kNpshRequiredHeadFraction = 0.15;

/// Cavitation safety margin: NPSH_available must exceed this multiple of
/// NPSH_required or cavitation risk is flagged. 1.5 (a 0.5 m + 30 % style
/// margin folded to a ratio) is the customary suction rule of thumb.
///
/// // VERIFY — general practice, not an SNI clause. `secondarySource`.
const double kNpshSafetyMargin = 1.5;

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
  /// is starved by an excessive static head), or the curves cross at a shallow
  /// angle (flat near the operating point ⇒ the duty hunts). A stable design
  /// wants the system and equipment curves to cross at a clear angle.
  final bool stable;

  /// Available net positive suction head at the operating flow (m).
  final Head npshAvailable;

  /// // VERIFY required net positive suction head estimate at the operating
  /// flow (m). NOT a certified NPSH_r curve.
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
  final num = hShutoff - hStatic;
  final den = k + a;
  double qOp;
  var stable = true;
  if (num <= 0 || den <= 0) {
    // No real root: the machine cannot overcome the static head (or both curves
    // are flat). Operating point collapses to zero flow — clearly unstable.
    qOp = 0.0;
    stable = false;
  } else {
    qOp = math.sqrt(num / den);
    // Stability: a healthy match crosses at a clear angle. The crossing slope
    // difference is d/dQ(H_sys − H_eq) = 2(k + a)·Q. Near-zero ⇒ the curves are
    // tangent/flat and the duty hunts. Compare the head developed over the
    // operating flow against a small fraction of the shutoff head as a
    // dimensionless conditioning check.
    final slopeDiff = 2.0 * den * qOp; // m per (m³/s)
    // Reference slope: shutoff head spread over the operating flow.
    final refSlope = (qOp > 0) ? hShutoff / qOp : 0.0;
    if (refSlope > 0 && slopeDiff < 0.05 * refSlope) stable = false;
  }
  final hOp = hStatic + k * qOp * qOp;

  // ── NPSH (// VERIFY estimates) ─────────────────────────────────────────────
  // NPSH_available = (P_atm − P_vapour)/(ρ·g) + h_suction_static − h_suction_fric
  final atmHead = atmosphericPressure / (density * gravity);
  final vapHead = vapourPressure / (density * gravity);
  final hSuctionStatic = suctionStaticHead.meters;
  // Suction friction: a fraction of the |static suction| as a first-pass
  // allowance (// VERIFY — replace with the real suction pipework loss).
  final hSuctionFric = kSuctionFrictionFraction * hSuctionStatic.abs();
  final npshA = atmHead - vapHead + hSuctionStatic - hSuctionFric;

  // NPSH_required: a // VERIFY estimate scaled by (Q_op/Q_design)² off a
  // design-point value (NPSH_r grows ~Q²). NOT a certified curve.
  final npshRdesign = hd * kNpshRequiredHeadFraction;
  final qRatio = (qd > 0) ? qOp / qd : 0.0;
  final npshR = npshRdesign * qRatio * qRatio;

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
  /// System resistance coefficient k in Δp_sys = k·Q² (Pa per (m³/s)²). DESIGN
  /// INPUT (// VERIFY) — never fitted from the duct solve here.
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

  /// False when the intersection is ill-conditioned (no real root or near-flat
  /// crossing) — see [PumpOperatingPoint.stable].
  final bool stable;

  const FanOperatingPoint({
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
/// - [systemResistanceK]                — DESIGN INPUT k (// VERIFY) for
///   Δp_sys = k·Q². When null it is BACK-SOLVED so the system curve passes
///   through the design point: k = Δp_design / Q_design².
///
/// The duct system curve has no static term (Δp_sys(0) = 0): all the duct
/// resistance is velocity²-driven. The equipment curve is pinned to the design
/// point with a representative shutoff fraction (// VERIFY).
FanOperatingPoint computeFanOperatingPoint({
  required FlowRate designAirflow,
  required Pressure designPressure,
  double? systemResistanceK,
}) {
  final qd = designAirflow.cubicMetersPerSecond;
  final pd = designPressure.pascals;

  // System curve: Δp_sys(Q) = k·Q² (no static term). k is a DESIGN INPUT; when
  // absent, back-solve through the design point.
  final k = systemResistanceK ?? ((qd > 0) ? pd / (qd * qd) : 0.0);

  // Equipment curve pinned to the design point with a representative shutoff.
  final pShutoff = pd * kEquipmentShutoffHeadRatio;
  final a = (qd > 0) ? (pShutoff - pd) / (qd * qd) : 0.0;

  // Intersection: k·Q² = Δp_shutoff − a·Q² ⇒ Q_op = √(Δp_shutoff / (k + a)).
  final den = k + a;
  double qOp;
  var stable = true;
  if (pShutoff <= 0 || den <= 0) {
    qOp = 0.0;
    stable = false;
  } else {
    qOp = math.sqrt(pShutoff / den);
    final slopeDiff = 2.0 * den * qOp; // Pa per (m³/s)
    final refSlope = (qOp > 0) ? pShutoff / qOp : 0.0;
    if (refSlope > 0 && slopeDiff < 0.05 * refSlope) stable = false;
  }
  final pOp = k * qOp * qOp;

  return FanOperatingPoint(
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
