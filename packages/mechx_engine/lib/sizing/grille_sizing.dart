/// HVAC grille / diffuser sizing module — face-velocity method.
///
/// Sizes a supply or return grille (or ceiling diffuser) so that the
/// **face velocity** — the speed of air through the grille's effective
/// (free) area — stays at or below a noise-driven limit.  Lower face
/// velocity means quieter operation.
///
/// ## Core relations
///
/// ```
/// freeArea       = airflow / faceVelocity
/// grossFaceArea  = freeArea / freeAreaRatio
/// faceVelocity   = airflow / (grossFaceArea × freeAreaRatio)
/// ```
///
/// The **free area** is the open portion of the gross face; bars, blades,
/// and the core block the rest.  A [freeAreaRatio] of 0.8 is typical for
/// most commercial grilles (80 % open).
///
/// ## Noise-driven face-velocity limits
///
/// The limits returned by [recommendedFaceVelocity] are drawn from
/// general HVAC engineering practice (e.g. ASHRAE Fundamentals chapter
/// on air distribution) and are **not** SNI-specific.  They are
/// commonly used as starting-point design limits before acoustic
/// verification:
///
/// | Application   | Max face velocity |
/// |---------------|-------------------|
/// | Bedroom       | 2.0 m/s           |
/// | Living space  | 2.5 m/s           |
/// | Office        | 3.0 m/s           |
/// | Retail        | 3.5 m/s           |
/// | Industrial    | 5.0 m/s           |
///
/// Pure Dart, zero Flutter imports.  All typed quantities come from
/// [package:mechx_engine/units.dart].
library;

import 'dart:math' as math;

import '../units.dart';

// ── Application enum ──────────────────────────────────────────────────────────

/// Occupancy / application categories used to look up noise-driven
/// face-velocity limits for grille / diffuser sizing.
///
/// Values map directly to [recommendedFaceVelocity].
enum GrilleApplication {
  /// Bedrooms and sleeping areas — most sensitive to noise.
  bedroom,

  /// General living / lounge spaces.
  livingSpace,

  /// Open-plan or private offices.
  office,

  /// Retail shops, showrooms, and similar commercial spaces.
  retail,

  /// Industrial / warehouse / plant-room environments.
  industrial,
}

// ── Recommended face velocities ───────────────────────────────────────────────

/// Maximum face velocity recommended for [app] based on noise-driven
/// HVAC engineering practice.
///
/// These limits are **not** SNI-specific; they represent widely used
/// starting-point values from sources such as ASHRAE Fundamentals (air
/// distribution chapter).  Always verify against the project's acoustic
/// specification.
///
/// | [GrilleApplication] | Returned velocity |
/// |---------------------|-------------------|
/// | bedroom             | 2.0 m/s           |
/// | livingSpace         | 2.5 m/s           |
/// | office              | 3.0 m/s           |
/// | retail              | 3.5 m/s           |
/// | industrial          | 5.0 m/s           |
Velocity recommendedFaceVelocity(GrilleApplication app) {
  switch (app) {
    case GrilleApplication.bedroom:
      return const Velocity(2.0);
    case GrilleApplication.livingSpace:
      return const Velocity(2.5);
    case GrilleApplication.office:
      return const Velocity(3.0);
    case GrilleApplication.retail:
      return const Velocity(3.5);
    case GrilleApplication.industrial:
      return const Velocity(5.0);
  }
}

// ── Result type ───────────────────────────────────────────────────────────────

/// Outcome of a grille / diffuser sizing calculation.
///
/// All areas are in m² internally; use `.inSquareMillimeters` for mm².
/// [squareSide] is the side of a square whose area equals [grossFaceArea]
/// — useful as a quick comparison against standard face dimensions.
final class GrilleSizingResult {
  /// Effective (free/open) area through which air actually passes (m²).
  ///
  /// ```
  /// freeArea = airflow / faceVelocity
  ///          = grossFaceArea × freeAreaRatio
  /// ```
  final Area freeArea;

  /// Total face area of the grille or diffuser, including bars/core (m²).
  ///
  /// ```
  /// grossFaceArea = freeArea / freeAreaRatio
  /// ```
  final Area grossFaceArea;

  /// Actual face velocity through the free area (m/s).
  ///
  /// For [sizeGrille] this equals [maxFaceVelocity] by construction.
  /// For [selectStandardGrille] it is the actual velocity at the chosen
  /// standard face, which is ≤ [maxFaceVelocity].
  final Velocity faceVelocity;

  /// Side length of a square equivalent to [grossFaceArea] (m).
  ///
  /// ```
  /// squareSide = sqrt(grossFaceArea)
  /// ```
  ///
  /// Use `.inMillimeters` to compare with standard face dimensions.
  final Length squareSide;

  const GrilleSizingResult({
    required this.freeArea,
    required this.grossFaceArea,
    required this.faceVelocity,
    required this.squareSide,
  });
}

// ── Standard grille face sizes ────────────────────────────────────────────────

/// Standard grille face dimensions (width × height) in millimetres.
///
/// Covers the most common rectangular face sizes stocked by mainstream
/// HVAC grille manufacturers.  Entries are **not** sorted by area;
/// [selectStandardGrille] evaluates every entry and picks the smallest
/// qualifying gross area.
const List<(double widthMm, double heightMm)> standardGrilleFacesMm =
    <(double, double)>[
  (150.0, 150.0),
  (200.0, 200.0),
  (300.0, 150.0),
  (300.0, 300.0),
  (450.0, 150.0),
  (450.0, 300.0),
  (600.0, 150.0),
  (600.0, 300.0),
  (600.0, 600.0),
];

// ── Sizing functions ──────────────────────────────────────────────────────────

/// Size a grille / diffuser for [airflow] so the face velocity does not
/// exceed [maxFaceVelocity].
///
/// Returns the exact (continuously sized) free area and gross face area;
/// use [selectStandardGrille] to snap the result to a catalogue size.
///
/// ## Algorithm
///
/// ```
/// freeArea      = airflow / maxFaceVelocity
/// grossFaceArea = freeArea / freeAreaRatio
/// squareSide    = sqrt(grossFaceArea)
/// faceVelocity  = maxFaceVelocity  (by construction)
/// ```
///
/// The [freeAreaRatio] must be in the range (0, 1].  Defaults to 0.8
/// (80 % open), which is appropriate for most commercial grilles.
GrilleSizingResult sizeGrille({
  required FlowRate airflow,
  required Velocity maxFaceVelocity,
  double freeAreaRatio = 0.8,
}) {
  assert(airflow.cubicMetersPerSecond > 0, 'airflow must be positive');
  assert(maxFaceVelocity.metersPerSecond > 0, 'maxFaceVelocity must be positive');
  assert(freeAreaRatio > 0 && freeAreaRatio <= 1.0, 'freeAreaRatio must be in (0, 1]');

  final freeAreaM2 =
      airflow.cubicMetersPerSecond / maxFaceVelocity.metersPerSecond;
  final grossAreaM2 = freeAreaM2 / freeAreaRatio;
  final squareSideM = math.sqrt(grossAreaM2);

  return GrilleSizingResult(
    freeArea: Area(freeAreaM2),
    grossFaceArea: Area(grossAreaM2),
    faceVelocity: maxFaceVelocity,
    squareSide: Length(squareSideM),
  );
}

/// Select the smallest standard grille face (from [standardGrilleFacesMm])
/// that keeps the face velocity at or below [maxFaceVelocity].
///
/// ## Algorithm
///
/// For each entry in [standardGrilleFacesMm] compute:
/// ```
/// grossArea    = width × height  (in m²)
/// faceVelocity = airflow / (grossArea × freeAreaRatio)
/// ```
/// Collect all faces whose faceVelocity ≤ [maxFaceVelocity], then
/// choose the one with the **smallest gross area** (quietest face that
/// is still as compact as possible).  If no face qualifies, the largest
/// face in [standardGrilleFacesMm] is returned (best available).
///
/// The returned [GrilleSizingResult.faceVelocity] is the **actual**
/// velocity at the chosen face, which is ≤ [maxFaceVelocity] whenever a
/// qualifying face exists.
GrilleSizingResult selectStandardGrille({
  required FlowRate airflow,
  required Velocity maxFaceVelocity,
  double freeAreaRatio = 0.8,
}) {
  assert(airflow.cubicMetersPerSecond > 0, 'airflow must be positive');
  assert(maxFaceVelocity.metersPerSecond > 0, 'maxFaceVelocity must be positive');
  assert(freeAreaRatio > 0 && freeAreaRatio <= 1.0, 'freeAreaRatio must be in (0, 1]');

  // Build a list of (grossAreaM2, record) for every standard face, sorted
  // ascending by gross area so the first qualifying entry is the smallest.
  final sorted = standardGrilleFacesMm.map((face) {
    final grossM2 = (face.$1 / 1000.0) * (face.$2 / 1000.0);
    return (grossM2, face);
  }).toList()
    ..sort((a, b) => a.$1.compareTo(b.$1));

  (double, (double, double))? chosen;
  for (final entry in sorted) {
    final grossM2 = entry.$1;
    final velocity = airflow.cubicMetersPerSecond / (grossM2 * freeAreaRatio);
    if (velocity <= maxFaceVelocity.metersPerSecond) {
      chosen = entry;
      break;
    }
  }

  // Fall back to the largest face if nothing qualifies.
  chosen ??= sorted.last;

  final chosenGrossM2 = chosen.$1;
  final actualVelocity =
      airflow.cubicMetersPerSecond / (chosenGrossM2 * freeAreaRatio);
  final freeAreaM2 = chosenGrossM2 * freeAreaRatio;
  final squareSideM = math.sqrt(chosenGrossM2);

  return GrilleSizingResult(
    freeArea: Area(freeAreaM2),
    grossFaceArea: Area(chosenGrossM2),
    faceVelocity: Velocity(actualVelocity),
    squareSide: Length(squareSideM),
  );
}
