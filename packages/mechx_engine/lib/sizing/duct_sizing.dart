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
  /// limit / friction target. Mirrors WaterSupplySizingResult.overVelocity /
  /// RainwaterSizingResult.overCapacity: the caller should surface this as a
  /// per-edge design issue rather than treat the size as valid.
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
/// return the first size whose Δp/L ≤ [targetPaPerMetre].
///
/// If no standard size achieves the target the result is CLAMPED to the
/// largest standard size with [DuctSizingResult.overCapacity] = true (its
/// friction will EXCEED [targetPaPerMetre]) — the solve never aborts; the
/// caller surfaces the over-capacity flag as a per-edge design issue.
DuctSizingResult sizeByEqualFriction({
  required FlowRate airflow,
  double targetPaPerMetre = 1.0,
}) {
  assert(airflow.cubicMetersPerSecond > 0, 'airflow must be positive');
  assert(targetPaPerMetre > 0, 'targetPaPerMetre must be positive');

  for (final sizeMm in standardDuctDiametersMm) {
    final d = Diameter.mm(sizeMm);
    final friction = ductFrictionPaPerMetre(airflow, d);
    if (friction <= targetPaPerMetre) {
      final actualVelocity = velocityFromFlow(airflow, d);
      return DuctSizingResult(
        diameter: d,
        actualVelocity: actualVelocity,
        frictionPerMetrePa: friction,
      );
    }
  }

  // No standard size meets the target — CLAMP to the largest and flag
  // overCapacity (rather than throw and abort the whole network solve).
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

  /// True when the required cross-section exceeds the largest standard side and
  /// the result was CLAMPED — the chosen W×H cannot meet the velocity limit /
  /// friction target. Mirrors [DuctSizingResult.overCapacity].
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

  // If either ideal side exceeds the largest standard side, roundUp clamps to
  // .last and the actual velocity exceeds the limit — flag overCapacity.
  final bool overCapacity =
      wIdealMm > standardDuctSidesMm.last || hIdealMm > standardDuctSidesMm.last;
  final w = Length(roundUp(wIdealMm) / 1000.0);
  final h = Length(roundUp(hIdealMm) / 1000.0);
  final actualArea = w.meters * h.meters;
  final v = Velocity(airflow.cubicMetersPerSecond / actualArea);
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
/// [ductFrictionPaPerMetre]). The first W×H whose Δp/L ≤ [targetPaPerMetre] is
/// returned. If none qualifies the result is CLAMPED to the largest sides with
/// [RectangularDuctResult.overCapacity] = true (friction exceeds the target),
/// mirroring [sizeByEqualFriction].
RectangularDuctResult sizeRectangularByEqualFriction({
  required FlowRate airflow,
  double targetPaPerMetre = 1.0,
  double aspectRatio = 1.5,
}) {
  assert(airflow.cubicMetersPerSecond > 0, 'airflow must be positive');
  assert(targetPaPerMetre > 0, 'targetPaPerMetre must be positive');
  assert(aspectRatio >= 1.0, 'aspectRatio (W/H) must be ≥ 1');

  double roundUp(double mm) => standardDuctSidesMm.firstWhere(
        (s) => s >= mm,
        orElse: () => standardDuctSidesMm.last,
      );

  for (final hMm in standardDuctSidesMm) {
    final h = Length(hMm / 1000.0);
    final w = Length(roundUp(aspectRatio * hMm) / 1000.0);
    final de = rectangularEquivalentDiameter(w, h);
    final friction = ductFrictionPaPerMetre(airflow, de);
    if (friction <= targetPaPerMetre) {
      final actualArea = w.meters * h.meters;
      return RectangularDuctResult(
        width: w,
        height: h,
        equivalentDiameter: de,
        actualVelocity: Velocity(airflow.cubicMetersPerSecond / actualArea),
        frictionPerMetrePa: friction,
      );
    }
  }

  // No standard W×H meets the target — CLAMP to the largest sides.
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
