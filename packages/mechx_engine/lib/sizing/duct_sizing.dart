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

// ── Result type ───────────────────────────────────────────────────────────────

/// Outcome of a duct-sizing calculation.
final class DuctSizingResult {
  /// Chosen standard circular duct diameter.
  final Diameter diameter;

  /// Actual mean air velocity inside the chosen duct at [airflow].
  final Velocity actualVelocity;

  /// Darcy–Weisbach friction pressure loss per metre of duct (Pa/m).
  final double frictionPerMetrePa;

  const DuctSizingResult({
    required this.diameter,
    required this.actualVelocity,
    required this.frictionPerMetrePa,
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

/// Darcy–Weisbach friction pressure drop per unit length (Pa/m) for a
/// circular duct carrying airflow [q] of diameter [d].
///
/// Formula: Δp/L = f · (1/D) · (ρ v² / 2)
///
/// where f is the Swamee–Jain approximation of the Colebrook–White friction
/// factor, ρ = [_airDensity], ν = [_airKinematicViscosity],
/// ε = [_galvSteelRoughness].
double _frictionPaPerMetre(FlowRate q, Diameter d) {
  final v = velocityFromFlow(q, d);
  final re = reynolds(v, d, kinematicViscosity: _airKinematicViscosity);
  final relRoughness = _galvSteelRoughness / d.meters;
  final f = frictionFactorSwameeJain(re, relRoughness);
  return f * (1.0 / d.meters) * (_airDensity * v.metersPerSecond * v.metersPerSecond / 2.0);
}

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
/// Throws [ArgumentError] if [airflow] or [maxVelocity] are non-positive, or
/// if the ideal diameter exceeds the largest standard size.
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
  // velocity back above maxVelocity.
  final chosenMm = standardDuctDiametersMm.firstWhere(
    (sizeMm) => sizeMm >= idealDiameterMm,
    orElse: () => throw ArgumentError(
      'Required duct diameter ${idealDiameterMm.toStringAsFixed(1)} mm '
      'exceeds the largest standard size '
      '(${standardDuctDiametersMm.last} mm).',
    ),
  );

  final chosen = Diameter.mm(chosenMm);
  final actualVelocity = velocityFromFlow(airflow, chosen);
  final friction = _frictionPaPerMetre(airflow, chosen);

  return DuctSizingResult(
    diameter: chosen,
    actualVelocity: actualVelocity,
    frictionPerMetrePa: friction,
  );
}

/// Size a circular duct so the friction pressure drop stays at or below
/// [targetPaPerMetre] Pa per metre of duct (equal-friction method).
///
/// Algorithm: iterate [standardDuctDiametersMm] from smallest to largest;
/// return the first size whose Δp/L ≤ [targetPaPerMetre].
///
/// Throws [ArgumentError] if no standard size achieves the target friction.
DuctSizingResult sizeByEqualFriction({
  required FlowRate airflow,
  double targetPaPerMetre = 1.0,
}) {
  assert(airflow.cubicMetersPerSecond > 0, 'airflow must be positive');
  assert(targetPaPerMetre > 0, 'targetPaPerMetre must be positive');

  for (final sizeMm in standardDuctDiametersMm) {
    final d = Diameter.mm(sizeMm);
    final friction = _frictionPaPerMetre(airflow, d);
    if (friction <= targetPaPerMetre) {
      final actualVelocity = velocityFromFlow(airflow, d);
      return DuctSizingResult(
        diameter: d,
        actualVelocity: actualVelocity,
        frictionPerMetrePa: friction,
      );
    }
  }

  throw ArgumentError(
    'Cannot achieve $targetPaPerMetre Pa/m with any standard duct size up to '
    '${standardDuctDiametersMm.last} mm for the given airflow '
    '(${airflow.inCubicMetersPerHour.toStringAsFixed(1)} m³/h).',
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
