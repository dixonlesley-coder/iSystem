/// Pure hydraulic-formula kernel for the MechX engine.
///
/// This file holds only the *primitive* relations (areas, velocities,
/// friction, head loss, pump energy). It contains zero Flutter imports and no
/// state — every function is a pure mapping from typed SI quantities to typed
/// SI quantities (§12: engine is pure, SI-internal, typed-quantity boundaries).
///
/// IMPORTANT (§12 — three separate code paths): the sizing layer must NOT
/// collapse pressurized, gravity, and fire flow into one "size a pipe"
/// routine. This kernel deliberately exposes them as *separate* primitives so
/// each sizing path composes the right ones:
///   • Pressurized supply  → [reynolds] + [frictionFactorSwameeJain] /
///     [frictionFactorColebrook] + [headLossDarcy], or [headLossHazenWilliams].
///   • Gravity drainage    → [manningVelocity] / [manningFlowFull]
///     (Manning, partial/full-bore); never reuse the pressurized path here.
///   • Pump / energy        → [hydraulicPower] / [shaftPower].
library;

import 'dart:math' as math;

import 'units.dart';

// ── Physical constants & default fluid properties ──────────────────────────

/// Standard gravitational acceleration (m/s²).
// VERIFY: confirm the value SNI worked-examples assume (9.81 vs 9.80665).
const double standardGravity = 9.81;

/// Design density of water (kg/m³). Common plumbing-design value; real water at
/// 20 °C is ≈998.2 kg/m³ — override per fluid/temperature where it matters.
const double defaultWaterDensity = 1000.0;

/// Kinematic viscosity of water at ≈20 °C (m²/s).
const double defaultKinematicViscosity = 1.004e-6;

double _pow(num base, num exponent) => math.pow(base, exponent).toDouble();
double _log10(num x) => math.log(x) / math.ln10;

// ── Geometry ───────────────────────────────────────────────────────────────

/// Upper Reynolds bound of the laminar regime in a circular pipe. Below this
/// the friction factor is `64/Re` (Hagen–Poiseuille), not Colebrook-family.
const double laminarReynoldsLimit = 2300.0;

/// Cross-sectional area of a circular pipe of inside [diameter].
Area circularArea(Diameter diameter) {
  assert(diameter.meters > 0, 'diameter must be positive');
  return Area(math.pi * diameter.meters * diameter.meters / 4.0);
}

/// Mean velocity for a given volumetric [flow] in a circular pipe of inside
/// [diameter] (continuity: v = Q / A).
Velocity velocityFromFlow(FlowRate flow, Diameter diameter) {
  assert(diameter.meters > 0, 'diameter must be positive');
  return Velocity(flow.cubicMetersPerSecond / circularArea(diameter).squareMeters);
}

/// Volumetric flow for a given mean [velocity] in a circular pipe of inside
/// [diameter] (Q = v · A).
FlowRate flowFromVelocity(Velocity velocity, Diameter diameter) => FlowRate(
      velocity.metersPerSecond * circularArea(diameter).squareMeters,
    );

// ── Pressurized flow: Reynolds / friction / Darcy–Weisbach ─────────────────

/// Reynolds number (dimensionless) for full-bore circular flow.
double reynolds(
  Velocity velocity,
  Diameter diameter, {
  double kinematicViscosity = defaultKinematicViscosity,
}) {
  assert(diameter.meters > 0, 'diameter must be positive');
  assert(kinematicViscosity > 0, 'kinematic viscosity must be positive');
  return velocity.metersPerSecond * diameter.meters / kinematicViscosity;
}

/// Darcy friction factor for full-bore flow at [reynolds] with relative
/// roughness ε/D = [relativeRoughness].
///
/// Regime-aware: laminar flow (`Re ≤ laminarReynoldsLimit`) uses the exact
/// Hagen–Poiseuille `f = 64/Re`; turbulent flow uses the Swamee–Jain explicit
/// approximation of Colebrook–White (valid 5·10³ < Re < 10⁸,
/// 10⁻⁶ < ε/D < 10⁻²). `Re = 0` (no flow) returns 0 — there is no friction
/// without flow, and callers fold this into a zero head loss.
double frictionFactorSwameeJain(double reynolds, double relativeRoughness) {
  assert(reynolds >= 0, 'Reynolds number must be non-negative');
  if (reynolds <= 0) return 0.0;
  if (reynolds <= laminarReynoldsLimit) return 64.0 / reynolds;
  final denom = _log10(relativeRoughness / 3.7 + 5.74 / _pow(reynolds, 0.9));
  return 0.25 / (denom * denom);
}

/// Darcy friction factor by iterating the implicit Colebrook–White equation,
/// seeded with [frictionFactorSwameeJain]. Laminar/zero-flow are delegated to
/// the seed (exact `64/Re` or 0); the turbulent fixed-point iterates to a tight
/// tolerance and exits early once converged.
double frictionFactorColebrook(
  double reynolds,
  double relativeRoughness, {
  int iterations = 16,
  double tolerance = 1e-10,
}) {
  // Laminar / no-flow: the explicit form is already exact — don't iterate
  // (the Colebrook fixed-point divides by Re·√f and would blow up at Re = 0).
  if (reynolds <= laminarReynoldsLimit) {
    return frictionFactorSwameeJain(reynolds, relativeRoughness);
  }
  var f = frictionFactorSwameeJain(reynolds, relativeRoughness);
  for (var i = 0; i < iterations; i++) {
    final rhs = -2.0 *
        _log10(relativeRoughness / 3.7 + 2.51 / (reynolds * math.sqrt(f)));
    final next = 1.0 / (rhs * rhs);
    if ((next - f).abs() <= tolerance) return next;
    f = next;
  }
  return f;
}

/// Friction head loss along a pipe via Darcy–Weisbach:
/// h_f = f · (L/D) · v² / (2g).
Head headLossDarcy({
  required double frictionFactor,
  required Length length,
  required Diameter diameter,
  required Velocity velocity,
  double gravity = standardGravity,
}) {
  final v = velocity.metersPerSecond;
  return Head(
    frictionFactor * (length.meters / diameter.meters) * (v * v) / (2 * gravity),
  );
}

/// Minor (local / fitting) head loss h = K · v² / (2g) for a dimensionless loss
/// coefficient [k] at a mean [velocity]. Used for inline restrictors — valves,
/// strainers, meters — on the pressurized path (the K's are general hydraulics
/// practice, NOT an SNI clause; see [NodeComponentInfo.minorLossK]). K = 0 ⇒ no
/// loss, so a network without such components is byte-identical.
Head minorLossHead({
  required double k,
  required Velocity velocity,
  double gravity = standardGravity,
}) {
  final v = velocity.metersPerSecond;
  return Head(k * v * v / (2 * gravity));
}

/// Friction head loss via Hazen–Williams (SI form, water only):
/// h_f = 10.67 · L · Q^1.852 / (C^1.852 · D^4.8704).
/// Common in plumbing & fire because it folds friction into the empirical
/// roughness coefficient [hazenWilliamsC].
Head headLossHazenWilliams({
  required FlowRate flow,
  required Length length,
  required Diameter diameter,
  required double hazenWilliamsC,
}) {
  assert(diameter.meters > 0, 'diameter must be positive');
  assert(hazenWilliamsC > 0, 'Hazen–Williams C must be positive');
  final q = flow.cubicMetersPerSecond;
  final d = diameter.meters;
  final hf = 10.67 *
      length.meters *
      _pow(q, 1.852) /
      (_pow(hazenWilliamsC, 1.852) * _pow(d, 4.8704));
  return Head(hf);
}

// ── Gravity flow: Manning (drainage) ───────────────────────────────────────

/// Mean velocity from the Manning equation: v = (1/n) · R^(2/3) · S^(1/2),
/// where [hydraulicRadius] R is in metres and [slope] S is dimensionless
/// (m/m). For *gravity* drainage only — keep this off the pressurized path.
Velocity manningVelocity({
  required double manningN,
  required Length hydraulicRadius,
  required double slope,
}) {
  assert(manningN > 0, "Manning's n must be positive");
  assert(slope >= 0, 'slope must be non-negative');
  assert(hydraulicRadius.meters >= 0, 'hydraulic radius must be non-negative');
  return Velocity(
    (1.0 / manningN) * _pow(hydraulicRadius.meters, 2.0 / 3.0) * math.sqrt(slope),
  );
}

/// Full-bore Manning discharge for a circular pipe (R = D/4, A = πD²/4). This
/// is the capacity bound; partial-full drainage sizing scales it by the
/// fill-ratio relations in the sizing layer.
FlowRate manningFlowFull(
  Diameter diameter, {
  required double manningN,
  required double slope,
}) {
  final area = circularArea(diameter);
  final radius = Length(diameter.meters / 4.0);
  final v = manningVelocity(
    manningN: manningN,
    hydraulicRadius: radius,
    slope: slope,
  );
  return FlowRate(v.metersPerSecond * area.squareMeters);
}

// ── Pump / energy ──────────────────────────────────────────────────────────

/// Useful (hydraulic) power delivered to the fluid: P = ρ · g · Q · H.
Power hydraulicPower({
  required FlowRate flow,
  required Head head,
  double density = defaultWaterDensity,
  double gravity = standardGravity,
}) =>
    Power(density * gravity * flow.cubicMetersPerSecond * head.meters);

/// Shaft (brake) power a pump must supply: hydraulic power divided by overall
/// [efficiency] (0 < η ≤ 1).
Power shaftPower({
  required FlowRate flow,
  required Head head,
  required double efficiency,
  double density = defaultWaterDensity,
  double gravity = standardGravity,
}) {
  assert(efficiency > 0 && efficiency <= 1, 'efficiency must be in (0, 1]');
  final hydraulic = hydraulicPower(
    flow: flow,
    head: head,
    density: density,
    gravity: gravity,
  );
  return Power(hydraulic.watts / efficiency);
}

// ── Pressure ↔ head ────────────────────────────────────────────────────────

/// Convert a head of fluid to pressure: P = ρ · g · h.
Pressure pressureFromHead(
  Head head, {
  double density = defaultWaterDensity,
  double gravity = standardGravity,
}) =>
    Pressure(density * gravity * head.meters);

/// Convert a pressure to head of fluid: h = P / (ρ · g).
Head headFromPressure(
  Pressure pressure, {
  double density = defaultWaterDensity,
  double gravity = standardGravity,
}) {
  assert(density > 0 && gravity > 0, 'density and gravity must be positive');
  return Head(pressure.pascals / (density * gravity));
}
