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

import '../network/network.dart';
import 'drainage_sizing.dart';
import 'network_sizing.dart' show EdgeSizing;

/// Minimum self-cleansing SLOPE (m/m) for the LARGEST mains (≥ DN200) — the
/// most lenient floor, used when no diameter is known. 0.005 (1:200) is NOT a
/// small-branch figure: small branches need far steeper grades (see
/// [minSelfCleansingSlopeFor]). // VERIFY against SNI 8153:2015 (minimum
/// gradient table).
const double kMinSelfCleansingSlope = 0.005;

/// Round 9 (plumbing-rules-min-slope-threshold) — minimum laid slope for a
/// branch ≤ DN65 (2 % ≈ ¼ in/ft; IPC 704.1, UPC 708, SNI 8153 practice).
/// // VERIFY (`notAnSniClause`).
const double kMinSlopeSmallBranch = 0.02;

/// Minimum laid slope for a DN75–DN150 drain (1 % ≈ ⅛ in/ft; IPC 704.1).
/// // VERIFY (`notAnSniClause`).
const double kMinSlopeMediumDrain = 0.01;

/// Minimum laid self-cleansing slope (m/m) for a drain of [diameterMm]:
/// ≤ DN65 ⇒ [kMinSlopeSmallBranch] (2 %), DN75 up to (but below) DN200 ⇒
/// [kMinSlopeMediumDrain] (1 %), ≥ DN200 ⇒ [kMinSelfCleansingSlope] (0.5 %).
/// A null diameter (unknown) takes the most lenient floor.
double minSelfCleansingSlopeFor(double? diameterMm) {
  if (diameterMm == null) return kMinSelfCleansingSlope;
  if (diameterMm <= 65.0 + 1e-9) return kMinSlopeSmallBranch;
  if (diameterMm < 200.0 - 1e-9) return kMinSlopeMediumDrain;
  return kMinSelfCleansingSlope;
}

/// Round 9 (plumbing-rules-developed-length-per-segment) — IPC Table 909.1
/// maximum TRAP-ARM developed length (fixture trap weir → vent) by trap-arm
/// diameter: (max DN mm, max length m). 1¼ in 5 ft, 1½ in 6 ft, 2 in 8 ft,
/// 3 in 12 ft, 4 in (and larger) 16 ft. // VERIFY (`notAnSniClause`).
const List<(double, double)> kTrapArmLimits = [
  (32, 1.5),
  (40, 1.8),
  (50, 2.4),
  (75, 3.7),
  (100, 4.9),
];

/// The [kTrapArmLimits] maximum developed length (m) for a trap arm of
/// [diameterMm] (≥ DN100 takes the DN100 row).
double maxTrapArmLengthM(double diameterMm) {
  for (final (dn, len) in kTrapArmLimits) {
    if (diameterMm <= dn + 1e-9) return len;
  }
  return kTrapArmLimits.last.$2;
}

/// Which advisory rule a [DrainageAdvisory] reports.
enum DrainageAdvisoryKind {
  /// The laid slope is below the per-DN floor [minSelfCleansingSlopeFor] —
  /// risk of solids settling.
  minSlope,

  /// The trap-arm developed length (fixture → first vented point) exceeds
  /// [maxTrapArmLengthM] for its diameter — risk of trap self-siphonage.
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

/// Run the advisory checks for one drainage [edgeId].
///
///  • [slope] (m/m, the laid gradient) is judged against the per-DN floor
///    [minSelfCleansingSlopeFor]([diameterMm]);
///  • [developedLengthM], when given, is a TRAP-ARM developed length (the
///    walk from a fixture to its first vented point — see [trapArmRuns]),
///    judged against [maxTrapArmLengthM]([diameterMm]). It is NOT a single
///    drawn segment's length: a run split into segments by the auto-elbow /
///    tee-in tools must be summed by the caller. Skipped without a diameter.
///
/// [sizing] is accepted for future refinements and is unused.
///
/// Returns zero, one, or two advisories. This NEVER resizes — it only judges the
/// design inputs against the conventional limits above (all `// VERIFY`).
List<DrainageAdvisory> drainageAdvisories({
  required String edgeId,
  required double slope,
  double? developedLengthM,
  double? diameterMm,
  DrainageSizingResult? sizing,
}) {
  final out = <DrainageAdvisory>[];

  // ── Minimum self-cleansing slope (per DN) ─────────────────────────────────
  final minSlope = minSelfCleansingSlopeFor(diameterMm);
  if (slope > 0 && slope < minSlope - 1e-12) {
    final pctMin = (minSlope * 100).toStringAsFixed(1);
    final pctSlope = (slope * 100).toStringAsFixed(2);
    final dn = diameterMm == null ? '' : 'DN${diameterMm.round()} ';
    out.add(DrainageAdvisory(
      edgeId: edgeId,
      kind: DrainageAdvisoryKind.minSlope,
      message: '${dn}drainage branch laid at $pctSlope% (1:'
          '${(1 / slope).round()}) is below the ~$pctMin% '
          '(1:${(1 / minSlope).round()}) self-cleansing minimum for its size — '
          'risk of solids settling. Steepen the gradient. (// VERIFY vs SNI 8153)',
    ));
  }

  // ── Trap-arm developed length (per DN) ────────────────────────────────────
  if (developedLengthM != null && diameterMm != null) {
    final limit = maxTrapArmLengthM(diameterMm);
    if (developedLengthM > limit + 1e-9) {
      out.add(DrainageAdvisory(
        edgeId: edgeId,
        kind: DrainageAdvisoryKind.developedLength,
        message: 'DN${diameterMm.round()} trap arm developed length '
            '${developedLengthM.toStringAsFixed(1)} m (fixture to first vent) '
            'exceeds the ~${limit.toStringAsFixed(1)} m limit for its size — '
            'risk of trap self-siphonage. Add a vent closer to the fixture. '
            '(// VERIFY vs SNI 8153)',
      ));
    }
  }

  return out;
}

/// One fixture's trap arm: the first drainage edge leaving the fixture
/// ([firstEdgeId], whose diameter is the trap-arm size) and the DEVELOPED
/// length summed downstream until the first vented point.
final class TrapArmRun {
  final String fixtureNodeId;
  final String firstEdgeId;
  final double developedLengthM;
  const TrapArmRun({
    required this.fixtureNodeId,
    required this.firstEdgeId,
    required this.developedLengthM,
  });
}

/// Round 9 — walk every DRAINAGE terminal (a degree-1 drainage node the flow
/// leaves, per the sizer's [EdgeSizing.flowFromId]) downstream, summing
/// [lengthOf] edge by edge, until the first VENTED point: a node with a vent
/// edge incident, an endpoint of a drainage riser (the stack), or the root (no
/// further downstream edge). Horizontal-only: a terminal whose first edge is
/// itself a riser has a zero-length trap arm and is skipped.
List<TrapArmRun> trapArmRuns({
  required Network net,
  required Map<String, EdgeSizing> sizing,
  required double Function(NetEdge edge) lengthOf,
}) {
  final drainEdges = [
    for (final e in net.edges)
      if (e.service == ServiceType.drainage) e,
  ];
  final byNode = <String, List<NetEdge>>{};
  for (final e in drainEdges) {
    (byNode[e.fromId] ??= []).add(e);
    (byNode[e.toId] ??= []).add(e);
  }
  final ventNodes = <String>{
    for (final e in net.edges)
      if (e.service == ServiceType.vent) ...[e.fromId, e.toId],
  };
  bool vented(String n) =>
      ventNodes.contains(n) ||
      (byNode[n] ?? const []).any((e) => e.kind == EdgeKind.riser);

  // Downstream edge out of node n: the drainage edge whose flow comes FROM n.
  NetEdge? outOf(String n) {
    for (final e in byNode[n] ?? const <NetEdge>[]) {
      if (sizing[e.id]?.flowFromId == n) return e;
    }
    return null;
  }

  final out = <TrapArmRun>[];
  for (final entry in byNode.entries) {
    if (entry.value.length != 1) continue;
    final first = entry.value.single;
    if (sizing[first.id]?.flowFromId != entry.key) continue; // not a terminal
    if (first.kind == EdgeKind.riser) continue;
    var total = 0.0;
    var edge = first;
    var at = entry.key;
    final seen = <String>{};
    while (seen.add(edge.id)) {
      total += lengthOf(edge);
      at = edge.fromId == at ? edge.toId : edge.fromId;
      if (vented(at)) break;
      final next = outOf(at);
      if (next == null || next.kind == EdgeKind.riser) break;
      edge = next;
    }
    out.add(TrapArmRun(
      fixtureNodeId: entry.key,
      firstEdgeId: first.id,
      developedLengthM: total,
    ));
  }
  return out;
}
