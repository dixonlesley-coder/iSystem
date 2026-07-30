/// HVAC duct-sizing module — §7 "air" code path.
///
/// Implements two standard sizing methods for circular ducts:
///   • [sizeByVelocity]      — keeps mean air velocity below a designer limit.
///   • [sizeByEqualFriction] — limits pressure drop per unit length (Pa/m).
///
/// Also provides [rectangularEquivalentDiameter] for converting a rectangular
/// cross-section to a hydraulically equivalent circular diameter (the
/// "circular-equivalent" formula from ASHRAE Handbook — Fundamentals).
///
/// All inputs and outputs use the typed SI quantities from [units.dart].
/// Internally every computation runs in SI (m, m³/s, m/s, Pa). No Flutter
/// imports; safe to use in pure-Dart (server, test, CLI) contexts.
///
/// Air properties assumed throughout:
///   ρ = 1.2 kg/m³   (standard air at ≈ 20 °C, sea level)
///   ν = 1.5 × 10⁻⁵ m²/s
///   ε = 9.0 × 10⁻⁵ m  (galvanised-steel absolute roughness)
library;

import 'dart:math' as math;

import '../hydraulics.dart';
import '../units.dart';

// ── Standard duct-diameter series ─────────────────────────────────────────────

/// ISO/EN standard circular duct diameters in millimetres.
///
/// Ascending order is required by [sizeByVelocity] (first value ≥ ideal) and
/// [sizeByEqualFriction] (iterate smallest → largest).
const List<double> standardDuctDiametersMm = <double>[
  100,
  125,
  150,
  160,
  200,
  250,
  315,
  355,
  400,
  450,
  500,
  560,
  630,
  710,
  800,
  900,
  1000,
];

/// Standard rectangular duct side lengths (mm), ascending. Used by
/// [sizeRectangularByVelocity] to round each side up to a buildable size.
const List<double> standardDuctSidesMm = <double>[
  100,
  150,
  200,
  250,
  300,
  350,
  400,
  450,
  500,
  600,
  700,
  800,
  900,
  1000,
  1200,
];

// ── Result type ───────────────────────────────────────────────────────────────

/// Outcome of a duct-sizing calculation.
final class DuctSizingResult {
  /// Chosen standard circular duct diameter.
  final Diameter diameter;

  /// Actual mean air velocity inside the chosen duct at [airflow].
  final Velocity actualVelocity;

  /// Darcy–Weisbach friction pressure loss per metre of duct (Pa/m).
  final double frictionPerMetrePa;

  /// True when the required size exceeds the largest standard duct and the
  /// result was CLAMPED to that size — the chosen duct cannot meet the velocity
  /// limit and/or the friction target it was sized against. Mirrors
  /// WaterSupplySizingResult.overVelocity / RainwaterSizingResult.overCapacity:
  /// the caller should surface this as a per-edge design issue rather than
  /// treat the size as valid.
  final bool overCapacity;

  const DuctSizingResult({
    required this.diameter,
    required this.actualVelocity,
    required this.frictionPerMetrePa,
    this.overCapacity = false,
  });
}

// ── Air constants ─────────────────────────────────────────────────────────────

/// Standard air density at ≈ 20 °C sea-level (kg/m³).
const double _airDensity = 1.2;

/// Kinematic viscosity of standard air (m²/s).
const double _airKinematicViscosity = 1.5e-5;

/// Absolute roughness for galvanised-steel ductwork (m).
const double _galvSteelRoughness = 9.0e-5;

// ── Private helpers ───────────────────────────────────────────────────────────

/// Darcy–Weisbach friction pressure drop per unit length (Pa/m) for a circular
/// duct carrying airflow [q] of diameter [d].
///
/// Formula: Δp/L = f · (1/D) · (ρ v² / 2), with f the Swamee–Jain friction
/// factor, ρ = [_airDensity], ν = [_airKinematicViscosity]. The absolute wall
/// roughness ε defaults to [_galvSteelRoughness] (galvanised steel); pass
/// [roughness] to use a per-product ε (e.g. a smoother PU pre-insulated panel).
/// Omitting [roughness] keeps the galvanised-steel default, so existing callers
/// are unchanged. Public so the fan-static solve can sum it along a duct run.
double ductFrictionPaPerMetre(FlowRate q, Diameter d, {Roughness? roughness}) {
  final v = velocityFromFlow(q, d);
  final re = reynolds(v, d, kinematicViscosity: _airKinematicViscosity);
  final eps = roughness?.meters ?? _galvSteelRoughness;
  final relRoughness = eps / d.meters;
  final f = frictionFactorSwameeJain(re, relRoughness);
  return f * (1.0 / d.meters) * (_airDensity * v.metersPerSecond * v.metersPerSecond / 2.0);
}

/// Relative tolerance used when comparing an ACHIEVED duct velocity against a
/// velocity cap. A standard size that lands exactly ON the cap (e.g. 1.2 m³/s
/// through 600 × 400 mm = 5.000 m/s) must not be rejected — or flagged
/// over-capacity — by floating-point dust in the area product.
const double _velocityCompareTolerance = 1e-9;

/// True when [v] satisfies the [cap] (within [_velocityCompareTolerance]).
/// A null [cap] means "no velocity constraint" ⇒ always true, which is what
/// keeps the equal-friction callers that pass no cap byte-identical.
bool _withinVelocity(Velocity v, Velocity? cap) =>
    cap == null ||
    v.metersPerSecond <=
        cap.metersPerSecond * (1.0 + _velocityCompareTolerance);

/// Air velocity pressure (Pa) at mean [velocity]: ρv²/2 (ρ = standard air).
double airVelocityPressurePa(Velocity velocity) =>
    _airDensity * velocity.metersPerSecond * velocity.metersPerSecond / 2.0;

/// Static loss (Pa) of an inline duct fitting/restrictor (damper, VAV box) with
/// loss coefficient [c] carrying [flow] in a duct of [diameter]: C · ρv²/2.
/// C = 0 ⇒ no loss, so a duct without such a component is byte-identical.
double ductFittingLossPa({
  required double c,
  required FlowRate flow,
  required Diameter diameter,
}) =>
    c * airVelocityPressurePa(velocityFromFlow(flow, diameter));

// ── Public sizing functions ───────────────────────────────────────────────────

/// Size a circular duct so the mean air velocity stays at or below
/// [maxVelocity].
///
/// Algorithm:
///   1. Required minimum cross-section: A = Q / v_max.
///   2. Ideal diameter from A = π D² / 4  →  D = √(4A/π).
///   3. Round *up* to the first entry in [standardDuctDiametersMm].
///   4. Compute actual velocity and friction for that diameter.
///
/// If the ideal diameter exceeds the largest standard size the result is
/// CLAMPED to that largest size with [DuctSizingResult.overCapacity] = true
/// (the actual velocity will exceed [maxVelocity]) — the solve never aborts;
/// the caller surfaces the over-capacity flag as a per-edge design issue.
/// Asserts non-positive [airflow] / [maxVelocity] in debug builds.
DuctSizingResult sizeByVelocity({
  required FlowRate airflow,
  required Velocity maxVelocity,
}) {
  assert(airflow.cubicMetersPerSecond > 0, 'airflow must be positive');
  assert(maxVelocity.metersPerSecond > 0, 'maxVelocity must be positive');

  final areaSi = airflow.cubicMetersPerSecond / maxVelocity.metersPerSecond;
  final idealDiameterM = math.sqrt(4.0 * areaSi / math.pi);
  final idealDiameterMm = idealDiameterM * 1000.0;

  // Round UP to the first standard size ≥ the ideal diameter. Rounding up is
  // required for a velocity-limit method: a smaller duct would push the mean
  // velocity back above maxVelocity. If none is large enough, CLAMP to the
  // largest standard size and flag overCapacity (rather than throw and abort
  // the whole network solve).
  final bool overCapacity = idealDiameterMm > standardDuctDiametersMm.last;
  final chosenMm = overCapacity
      ? standardDuctDiametersMm.last
      : standardDuctDiametersMm.firstWhere((sizeMm) => sizeMm >= idealDiameterMm);

  final chosen = Diameter.mm(chosenMm);
  final actualVelocity = velocityFromFlow(airflow, chosen);
  final friction = ductFrictionPaPerMetre(airflow, chosen);

  return DuctSizingResult(
    diameter: chosen,
    actualVelocity: actualVelocity,
    frictionPerMetrePa: friction,
    overCapacity: overCapacity,
  );
}

/// Size a circular duct so the friction pressure drop stays at or below
/// [targetPaPerMetre] Pa per metre of duct (equal-friction method).
///
/// Algorithm: iterate [standardDuctDiametersMm] from smallest to largest;
/// return the first size whose Δp/L ≤ [targetPaPerMetre] **and** — when a
/// [maxVelocity] cap is supplied — whose mean velocity ≤ that cap. Both
/// constraints relax monotonically as the duct grows, so the first size that
/// satisfies both is the smallest adequate one.
///
/// M2 — the equal-friction method on its own says nothing about velocity: at a
/// 1.0 Pa/m target a 1.2 m³/s duct lands on DN500 at 6.1 m/s, well past the
/// 5 m/s design cap, with no flag anywhere. Pass [maxVelocity] (the sizing
/// context's duct velocity limit) so the ladder keeps stepping UP until BOTH
/// hold. [maxVelocity] defaults to null ⇒ friction-only selection, i.e. every
/// existing caller is byte-identical.
///
/// If no standard size satisfies the active constraints the result is CLAMPED
/// to the largest standard size with [DuctSizingResult.overCapacity] = true
/// (its friction will EXCEED [targetPaPerMetre] and/or its velocity will exceed
/// [maxVelocity]) — the solve never aborts; the caller surfaces the
/// over-capacity flag as a per-edge design issue.
DuctSizingResult sizeByEqualFriction({
  required FlowRate airflow,
  double targetPaPerMetre = 1.0,
  Velocity? maxVelocity,
}) {
  assert(airflow.cubicMetersPerSecond > 0, 'airflow must be positive');
  assert(targetPaPerMetre > 0, 'targetPaPerMetre must be positive');
  assert(maxVelocity == null || maxVelocity.metersPerSecond > 0,
      'maxVelocity must be positive when supplied');

  for (final sizeMm in standardDuctDiametersMm) {
    final d = Diameter.mm(sizeMm);
    final friction = ductFrictionPaPerMetre(airflow, d);
    final actualVelocity = velocityFromFlow(airflow, d);
    if (friction <= targetPaPerMetre &&
        _withinVelocity(actualVelocity, maxVelocity)) {
      return DuctSizingResult(
        diameter: d,
        actualVelocity: actualVelocity,
        frictionPerMetrePa: friction,
      );
    }
  }

  // No standard size meets the target (and/or the velocity cap) — CLAMP to the
  // largest and flag overCapacity (rather than throw and abort the whole solve).
  final d = Diameter.mm(standardDuctDiametersMm.last);
  return DuctSizingResult(
    diameter: d,
    actualVelocity: velocityFromFlow(airflow, d),
    frictionPerMetrePa: ductFrictionPaPerMetre(airflow, d),
    overCapacity: true,
  );
}

/// Circular-equivalent diameter for a rectangular duct of sides [a] × [b].
///
/// Uses the ASHRAE / ACCA formula:
///   De = 1.30 · (a·b)^0.625 / (a + b)^0.25
///
/// where a and b are the internal cross-section dimensions in metres. The
/// result De is in metres.
Diameter rectangularEquivalentDiameter(Length a, Length b) {
  final aSi = a.meters;
  final bSi = b.meters;
  final deMetre = 1.30 *
      math.pow(aSi * bSi, 0.625) /
      math.pow(aSi + bSi, 0.25);
  return Diameter(deMetre.toDouble());
}

/// Outcome of a rectangular duct-sizing calculation.
final class RectangularDuctResult {
  /// Chosen duct width and height (standard sides, ≥ the ideal cross-section).
  final Length width;
  final Length height;

  /// Circular-equivalent diameter of the chosen W×H (for friction/labelling).
  final Diameter equivalentDiameter;

  /// True mean velocity through the rectangular cross-section at the airflow.
  final Velocity actualVelocity;

  /// Friction pressure loss per metre (Pa/m), via the equivalent diameter.
  final double frictionPerMetrePa;

  /// True when the chosen W×H — after clamping at the largest standard side —
  /// cannot meet the constraint it was sized against. Mirrors
  /// [DuctSizingResult.overCapacity].
  ///
  /// M6 — the velocity method judges this from the ACHIEVED velocity
  /// ([actualVelocity] > the cap), NOT from the ideal sides. Rounding each side
  /// UP means an ideal side past the top of the ladder can still land on a
  /// cross-section that satisfies the cap (Q = 4.92 m³/s, aspect 1.5, cap
  /// 5.0 m/s ⇒ ideal 1215 × 810 clamps to 1200 × 900 = 1.08 m² ⇒ 4.56 m/s,
  /// which is compliant), and flagging it produced a red plan badge and a
  /// Review warning on a perfectly good duct.
  final bool overCapacity;

  const RectangularDuctResult({
    required this.width,
    required this.height,
    required this.equivalentDiameter,
    required this.actualVelocity,
    required this.frictionPerMetrePa,
    this.overCapacity = false,
  });
}

/// Size a rectangular duct so the mean velocity stays at or below [maxVelocity]
/// at the given width:height [aspectRatio] (W/H, ≥ 1).
///
/// Algorithm: required area A = Q / v_max; with W = aspect·H and A = W·H,
/// H = √(A/aspect), W = aspect·H. Each side is rounded UP to the next standard
/// side so the actual area ≥ A (velocity stays under the limit). Friction is
/// computed from the circular-equivalent diameter.
RectangularDuctResult sizeRectangularByVelocity({
  required FlowRate airflow,
  required Velocity maxVelocity,
  double aspectRatio = 1.5,
}) {
  assert(airflow.cubicMetersPerSecond > 0, 'airflow must be positive');
  assert(maxVelocity.metersPerSecond > 0, 'maxVelocity must be positive');
  assert(aspectRatio >= 1.0, 'aspectRatio (W/H) must be ≥ 1');

  final reqArea = airflow.cubicMetersPerSecond / maxVelocity.metersPerSecond;
  final hIdealMm = math.sqrt(reqArea / aspectRatio) * 1000.0;
  final wIdealMm = aspectRatio * math.sqrt(reqArea / aspectRatio) * 1000.0;

  double roundUp(double mm) => standardDuctSidesMm.firstWhere(
        (s) => s >= mm,
        orElse: () => standardDuctSidesMm.last,
      );

  final w = Length(roundUp(wIdealMm) / 1000.0);
  final h = Length(roundUp(hIdealMm) / 1000.0);
  final actualArea = w.meters * h.meters;
  final v = Velocity(airflow.cubicMetersPerSecond / actualArea);
  // M6 — flag from the ACHIEVED velocity, not the ideal sides: when an ideal
  // side is clamped at the top of the ladder the OTHER side is still rounded
  // UP, so the delivered cross-section can (and often does) still satisfy the
  // cap. Only a genuinely over-velocity duct is an over-capacity duct.
  final bool overCapacity = !_withinVelocity(v, maxVelocity);
  final de = rectangularEquivalentDiameter(w, h);
  final friction = ductFrictionPaPerMetre(airflow, de);

  return RectangularDuctResult(
    width: w,
    height: h,
    equivalentDiameter: de,
    actualVelocity: v,
    frictionPerMetrePa: friction,
    overCapacity: overCapacity,
  );
}

/// Size a rectangular duct so the friction pressure drop stays at or below
/// [targetPaPerMetre] Pa/m (equal-friction method) at the given width:height
/// [aspectRatio] (W/H, ≥ 1).
///
/// Pure ORCHESTRATION over the existing primitives — NO new physics. For each
/// candidate height H in [standardDuctSidesMm] (ascending), W = aspect·H rounded
/// up to the next standard side; the friction is read from the circular-
/// equivalent diameter ([rectangularEquivalentDiameter] →
/// [ductFrictionPaPerMetre]). The first W×H whose Δp/L ≤ [targetPaPerMetre]
/// **and** — when a [maxVelocity] cap is supplied — whose mean velocity ≤ that
/// cap is returned; both constraints relax monotonically as the section grows
/// (H ascends and W = aspect·H rounded up is non-decreasing), so the first
/// qualifying candidate is the smallest adequate one.
///
/// M2 — see [sizeByEqualFriction]: equal friction alone does not bound
/// velocity. [maxVelocity] defaults to null ⇒ friction-only selection, so every
/// existing caller is byte-identical. If none qualifies the result is CLAMPED
/// to the largest sides with [RectangularDuctResult.overCapacity] = true
/// (friction exceeds the target and/or the velocity exceeds the cap),
/// mirroring [sizeByEqualFriction].
RectangularDuctResult sizeRectangularByEqualFriction({
  required FlowRate airflow,
  double targetPaPerMetre = 1.0,
  double aspectRatio = 1.5,
  Velocity? maxVelocity,
}) {
  assert(airflow.cubicMetersPerSecond > 0, 'airflow must be positive');
  assert(targetPaPerMetre > 0, 'targetPaPerMetre must be positive');
  assert(aspectRatio >= 1.0, 'aspectRatio (W/H) must be ≥ 1');
  assert(maxVelocity == null || maxVelocity.metersPerSecond > 0,
      'maxVelocity must be positive when supplied');

  double roundUp(double mm) => standardDuctSidesMm.firstWhere(
        (s) => s >= mm,
        orElse: () => standardDuctSidesMm.last,
      );

  for (final hMm in standardDuctSidesMm) {
    final h = Length(hMm / 1000.0);
    final w = Length(roundUp(aspectRatio * hMm) / 1000.0);
    final de = rectangularEquivalentDiameter(w, h);
    final friction = ductFrictionPaPerMetre(airflow, de);
    final actualArea = w.meters * h.meters;
    final v = Velocity(airflow.cubicMetersPerSecond / actualArea);
    if (friction <= targetPaPerMetre && _withinVelocity(v, maxVelocity)) {
      return RectangularDuctResult(
        width: w,
        height: h,
        equivalentDiameter: de,
        actualVelocity: v,
        frictionPerMetrePa: friction,
      );
    }
  }

  // No standard W×H meets the target (and/or the cap) — CLAMP to the largest.
  final h = Length(standardDuctSidesMm.last / 1000.0);
  final w = Length(standardDuctSidesMm.last / 1000.0);
  final de = rectangularEquivalentDiameter(w, h);
  final actualArea = w.meters * h.meters;
  return RectangularDuctResult(
    width: w,
    height: h,
    equivalentDiameter: de,
    actualVelocity: Velocity(airflow.cubicMetersPerSecond / actualArea),
    frictionPerMetrePa: ductFrictionPaPerMetre(airflow, de),
    overCapacity: true,
  );
}
