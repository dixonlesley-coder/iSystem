/// Air-velocity sanity checks — the "is this duct / diffuser the right size?"
/// guard for a MANUALLY routed and sized air network.
///
/// The user draws the ducts and places the diffusers / AHU / FCU / fan by hand
/// (for aesthetic / coordination reasons), choosing a duct size and a diffuser
/// face size. This module does NOT size anything; it only judges the resulting
/// air velocity against a recommended band and reports whether it is OK, too
/// LOW (oversized / poor throw / cold-air dumping) or too HIGH (noisy / high
/// static). The sizing engine stays the authority on the numbers; this is the
/// honesty layer on top.
///
/// The bands are general low-pressure HVAC engineering practice (ASHRAE
/// Fundamentals air-distribution chapter style), **NOT an SNI clause** —
/// flagged `// VERIFY` against the project's acoustic / energy spec. They are
/// plain constants so a project can tune them later.
///
/// Pure Dart, zero Flutter imports.
library;

import '../units.dart';

// ── Recommended velocity bands (general practice — // VERIFY) ─────────────────

/// Supply duct mean-velocity band (m/s). Below the min the duct is oversized
/// (wasteful, possible settling); above the max it gets noisy / high-static.
const Velocity kSupplyDuctVelocityMin = Velocity(3.0);
const Velocity kSupplyDuctVelocityMax = Velocity(7.0);

/// Supply diffuser FACE-velocity band (m/s). Below the min the jet dumps (cold
/// air drops); above the max it is noisy.
const Velocity kSupplyFaceVelocityMin = Velocity(1.0);
const Velocity kSupplyFaceVelocityMax = Velocity(3.0);

/// Return / exhaust grille FACE-velocity band (m/s). Returns tolerate a higher
/// face velocity than supply (no throw requirement), so the max is looser.
const Velocity kReturnFaceVelocityMin = Velocity(1.0);
const Velocity kReturnFaceVelocityMax = Velocity(4.0);

// ── Verdict + result ──────────────────────────────────────────────────────────

/// Where an air velocity sits relative to its recommended band.
enum VelocityBandVerdict { ok, tooLow, tooHigh }

/// Outcome of checking one air velocity against a [min]–[max] band.
final class VelocityCheck {
  /// The actual mean / face velocity being judged.
  final Velocity actual;

  /// Recommended lower / upper bounds of the band.
  final Velocity min;
  final Velocity max;

  final VelocityBandVerdict verdict;

  const VelocityCheck({
    required this.actual,
    required this.min,
    required this.max,
    required this.verdict,
  });

  /// True when the velocity is outside the recommended band.
  bool get isWarning => verdict != VelocityBandVerdict.ok;

  /// Short human-readable summary, e.g. `"3.6 m/s — too high (> 3.0)"`.
  String get message {
    final v = actual.metersPerSecond.toStringAsFixed(1);
    switch (verdict) {
      case VelocityBandVerdict.ok:
        return '$v m/s — OK';
      case VelocityBandVerdict.tooLow:
        return '$v m/s — too low (< ${min.metersPerSecond.toStringAsFixed(1)})';
      case VelocityBandVerdict.tooHigh:
        return '$v m/s — too high (> ${max.metersPerSecond.toStringAsFixed(1)})';
    }
  }
}

// ── Checks ────────────────────────────────────────────────────────────────────

/// Judge [actual] against a [min]–[max] band. A non-positive velocity (no flow
/// or no chosen size) is reported as [VelocityBandVerdict.ok] — there is nothing
/// to warn about until the element carries air through a real size.
VelocityCheck checkVelocityBand(
  Velocity actual, {
  required Velocity min,
  required Velocity max,
}) {
  final v = actual.metersPerSecond;
  final VelocityBandVerdict verdict;
  if (v <= 0) {
    verdict = VelocityBandVerdict.ok;
  } else if (v < min.metersPerSecond) {
    verdict = VelocityBandVerdict.tooLow;
  } else if (v > max.metersPerSecond) {
    verdict = VelocityBandVerdict.tooHigh;
  } else {
    verdict = VelocityBandVerdict.ok;
  }
  return VelocityCheck(actual: actual, min: min, max: max, verdict: verdict);
}

/// Check a supply duct's mean velocity against the supply-duct band.
VelocityCheck checkSupplyDuctVelocity(Velocity actual) => checkVelocityBand(
      actual,
      min: kSupplyDuctVelocityMin,
      max: kSupplyDuctVelocityMax,
    );

/// Mean FACE velocity (m/s) of a grille / diffuser carrying [airflow] through a
/// gross face of [grossFaceArea] with the given open-area [freeAreaRatio].
/// Returns zero velocity when the free area is non-positive (undefined).
Velocity faceVelocityFor(
  FlowRate airflow, {
  required Area grossFaceArea,
  double freeAreaRatio = 0.8,
}) {
  final freeM2 = grossFaceArea.squareMeters * freeAreaRatio;
  if (freeM2 <= 0) return const Velocity(0);
  return Velocity(airflow.cubicMetersPerSecond / freeM2);
}

/// Check a supply diffuser's face velocity against the supply-face band.
VelocityCheck checkSupplyFaceVelocity(Velocity actual) => checkVelocityBand(
      actual,
      min: kSupplyFaceVelocityMin,
      max: kSupplyFaceVelocityMax,
    );

/// Check a return / exhaust grille's face velocity against the return-face band.
VelocityCheck checkReturnFaceVelocity(Velocity actual) => checkVelocityBand(
      actual,
      min: kReturnFaceVelocityMin,
      max: kReturnFaceVelocityMax,
    );
