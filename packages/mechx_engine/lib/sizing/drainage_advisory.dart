/// Advisory checks for gravity-drainage branches — a JUDGE-ONLY layer over the
/// [DrainageSizingResult] + the run geometry. It never resizes anything; it only
/// flags two classic sanitary-drainage rules of thumb the auto-sizer does not
/// already enforce:
///
///   • minimum self-cleansing SLOPE — a branch laid too flat will not keep
///     solids in suspension. The sizer reports a full-bore velocity and a
///     [DrainageSizingResult.selfCleansing] flag, but the *slope itself* (the
///     gradient the installer must lay) has a conventional floor too; and
///   • developed-length / trap-arm limits — a fixture drain (trap arm) longer
///     than the code limit risks self-siphonage of the trap seal, and an
///     over-long un-vented branch likewise. We flag the developed length when it
///     exceeds a conventional limit.
///
/// Both thresholds are general plumbing practice (UPC/IPC-style), NOT confirmed
/// SNI clauses — every numeric limit below is `// VERIFY` against SNI 8153:2015.
///
/// Pure Dart, zero Flutter imports (§12: engine is framework-free).
library;

import 'drainage_sizing.dart';

/// Minimum self-cleansing SLOPE for a small sanitary branch (m/m). A branch laid
/// flatter than this is unlikely to reach the self-cleansing velocity at the
/// design fill, regardless of the pipe chosen. 0.005 (1:200) is the widely-used
/// floor for small branches; larger mains tolerate flatter grades.
/// // VERIFY against SNI 8153:2015 (minimum gradient table).
const double kMinSelfCleansingSlope = 0.005;

/// Maximum recommended developed length (m) for an un-vented fixture branch /
/// trap arm before self-siphonage and waste-of-grade become a concern. 32 m is a
/// conventional horizontal-branch / developed-length figure; trap arms are far
/// shorter still. // VERIFY against SNI 8153:2015 (trap-arm + developed-length
/// limits, which depend on pipe size).
const double kMaxDevelopedLengthM = 32.0;

/// Which advisory rule a [DrainageAdvisory] reports.
enum DrainageAdvisoryKind {
  /// The laid slope is below [kMinSelfCleansingSlope] — risk of solids settling.
  minSlope,

  /// The developed run length exceeds [kMaxDevelopedLengthM] — risk of trap
  /// self-siphonage / loss of grade on an over-long branch.
  developedLength,
}

/// One advisory raised against a single drainage edge. Carries the [edgeId] so
/// the app can make the Review row locatable, the [kind], and a human-readable
/// [message]. Advisory-only: it never changes the sizing.
final class DrainageAdvisory {
  final String edgeId;
  final DrainageAdvisoryKind kind;
  final String message;

  const DrainageAdvisory({
    required this.edgeId,
    required this.kind,
    required this.message,
  });
}

/// Run the advisory checks for one drainage [edgeId] given its [slope] (m/m, the
/// gradient the branch is laid at) and its [developedLengthM] (the real run
/// length from §10 geometry — pass `null`/0 to skip the length check).
///
/// [sizing] is the already-computed drainage result for the edge, accepted so a
/// future refinement can judge against its velocity/diameter; the current checks
/// key only off the slope and developed length and so leave it optional.
///
/// Returns zero, one, or two advisories. This NEVER resizes — it only judges the
/// design inputs against the conventional limits above (all `// VERIFY`).
List<DrainageAdvisory> drainageAdvisories({
  required String edgeId,
  required double slope,
  double? developedLengthM,
  DrainageSizingResult? sizing,
}) {
  final out = <DrainageAdvisory>[];

  // ── Minimum self-cleansing slope ──────────────────────────────────────────
  // Flag a branch laid flatter than the conventional floor. We deliberately key
  // off the laid SLOPE (not the result's full-bore velocity self-cleansing flag)
  // because the slope is what the installer controls and what the code limits.
  if (slope > 0 && slope < kMinSelfCleansingSlope) {
    final pctMin = (kMinSelfCleansingSlope * 100).toStringAsFixed(1);
    final pctSlope = (slope * 100).toStringAsFixed(2);
    out.add(DrainageAdvisory(
      edgeId: edgeId,
      kind: DrainageAdvisoryKind.minSlope,
      message: 'Drainage branch laid at $pctSlope% (1:'
          '${(1 / slope).round()}) is below the ~$pctMin% '
          '(1:${(1 / kMinSelfCleansingSlope).round()}) self-cleansing minimum — '
          'risk of solids settling. Steepen the gradient. (// VERIFY vs SNI 8153)',
    ));
  }

  // ── Developed length / trap-arm limit ─────────────────────────────────────
  if (developedLengthM != null && developedLengthM > kMaxDevelopedLengthM) {
    out.add(DrainageAdvisory(
      edgeId: edgeId,
      kind: DrainageAdvisoryKind.developedLength,
      message: 'Drainage branch developed length '
          '${developedLengthM.toStringAsFixed(1)} m exceeds the '
          '~${kMaxDevelopedLengthM.toStringAsFixed(0)} m limit — risk of trap '
          'self-siphonage / loss of grade. Add a vent or break the run. '
          '(// VERIFY vs SNI 8153)',
    ));
  }

  return out;
}
