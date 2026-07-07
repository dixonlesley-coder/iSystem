import 'dart:math' as math;

import 'package:flutter/widgets.dart' show Offset;

/// The kind of geometric feature a resolved snap latched onto — the shared
/// **OSNAP marker vocabulary** (B24) the canvas draws distinct markers for
/// (square endpoint, triangle midpoint, x intersection, perpendicular foot, …).
///
/// It spans every snap SOURCE, not just the plan underlay: a network [node] /
/// tee, a run [midpoint], the magnetic [grid], an alignment [align] guide, and
/// the underlay features ([endpoint], [intersection], [perpendicular],
/// [refline], [ink]). A plain nearest-point-on-a-plan-line snap (a DXF wall OR a
/// traced reference line) reads as [refline] — the generic "on a drafting line"
/// marker — while [endpoint] / [intersection] / [perpendicular] are geometric
/// features regardless of which line produced them (the underlay hit's `source`
/// still records the provenance).
enum SnapKind {
  node,
  endpoint,
  midpoint,
  intersection,
  perpendicular,
  refline,
  ink,
  grid,
  align,
}

/// Snap the segment [from]→[to] to the nearest 45° direction, preserving its
/// length — the classic "ortho" constraint that keeps runs horizontal,
/// vertical, or on a clean diagonal. Returns [to] unchanged for a zero-length
/// segment.
Offset orthoSnap(Offset from, Offset to) {
  final v = to - from;
  if (v.dx == 0 && v.dy == 0) return to;
  const step = math.pi / 4; // 45°
  final snappedAngle = (math.atan2(v.dy, v.dx) / step).round() * step;
  final length = v.distance;
  return from +
      Offset(math.cos(snappedAngle) * length, math.sin(snappedAngle) * length);
}

/// Off-ray distance (world px) below which an auto-elbow would be an invisible
/// micro-jog — the target is absorbed straight into the constrained ray instead
/// (B13).
const double kOrthoElbowEpsilonPx = 0.75;

/// The CAD auto-elbow BEND point for an ortho run laid from [anchor] toward
/// [through] that must CONNECT to an off-ray [target] (a snapped node / tee /
/// underlay candidate). The bend is the foot of [target] on the constrained
/// 45°-multiple ray from [anchor] — so the run draws as anchor→bend (the
/// dominant leg, running the full aligned extent along the constraint) then
/// bend→[target] (a short axis/45 correcting leg, since the residual to the
/// foot is perpendicular to the ray, itself a 45-multiple direction).
///
/// Returns null — meaning draw the single segment straight to [target] — when
/// the segment [anchor]→[through] is degenerate, [target] is within [epsilon]
/// of the ray (absorb, no micro-elbow), or the ray points away from the target
/// (no forward dominant leg). Shared by the live preview and, by contract, the
/// store's commit path.
Offset? orthoElbow(Offset anchor, Offset through, Offset target,
    {double epsilon = kOrthoElbowEpsilonPx}) {
  final v = through - anchor;
  if (v.dx == 0 && v.dy == 0) return null;
  const step = math.pi / 4; // 45°
  final a = (math.atan2(v.dy, v.dx) / step).round() * step;
  final u = Offset(math.cos(a), math.sin(a)); // unit ortho direction
  final rel = target - anchor;
  final proj = rel.dx * u.dx + rel.dy * u.dy;
  if (proj <= epsilon) return null; // target behind/at anchor — no forward leg
  final foot = anchor + u * proj;
  if ((target - foot).distance <= epsilon) return null; // on-ray — absorb
  return foot;
}

/// One axis-alignment guide (B23): the probe pinned onto a shared axis with an
/// existing [node], so fixtures laid in a row latch to their neighbours' x or y.
/// [horizontal] true ⇒ a HORIZONTAL dashed guide (probe and node share Y);
/// false ⇒ a VERTICAL guide (they share X). [delta] is the axis offset that was
/// closed (|dx| for a vertical guide, |dy| for a horizontal one).
class AlignGuide {
  /// The probe with the aligned axis pinned to the node's; the other axis kept.
  final Offset point;

  /// The existing node the guide runs through (for rendering the dashed line).
  final Offset node;

  /// True: shares Y (horizontal guide). False: shares X (vertical guide).
  final bool horizontal;

  /// The axis offset closed to produce the snap (always ≤ the tolerance).
  final double delta;
  const AlignGuide({
    required this.point,
    required this.node,
    required this.horizontal,
    required this.delta,
  });

  SnapKind get kind => SnapKind.align;

  @override
  String toString() =>
      'AlignGuide($point through $node, ${horizontal ? 'H' : 'V'}, d=$delta)';
}

/// The nearest axis-alignment guide for [probe] against existing [nodes], or
/// null when no node's x OR y is within [tolerance] (the standard 14 screen-px
/// pick radius ÷ zoom). A single O(n) pass tracks the closest vertical
/// (shared-x) and horizontal (shared-y) candidate and returns whichever axis is
/// nearer (**nearest-axis-first**; a tie prefers the vertical guide). Only the
/// aligned axis is pinned; the other keeps the probe's value — so a run/place
/// gesture stays free along the guide. Linear min-scan is the sensible cap
/// (sheets are small); no O(n²) pairing.
AlignGuide? nearestAlignment(
  Iterable<Offset> nodes,
  Offset probe,
  double tolerance,
) {
  if (tolerance <= 0) return null;
  var bestDx = double.infinity;
  Offset? bestXNode; // shares x → vertical guide
  var bestDy = double.infinity;
  Offset? bestYNode; // shares y → horizontal guide
  for (final n in nodes) {
    final dx = (n.dx - probe.dx).abs();
    if (dx <= tolerance && dx < bestDx) {
      bestDx = dx;
      bestXNode = n;
    }
    final dy = (n.dy - probe.dy).abs();
    if (dy <= tolerance && dy < bestDy) {
      bestDy = dy;
      bestYNode = n;
    }
  }
  if (bestXNode == null && bestYNode == null) return null;
  // Nearest-axis-first: smaller offset wins; a tie prefers the vertical guide.
  final useVertical =
      bestXNode != null && (bestYNode == null || bestDx <= bestDy);
  if (useVertical) {
    return AlignGuide(
      point: Offset(bestXNode.dx, probe.dy),
      node: bestXNode,
      horizontal: false,
      delta: bestDx,
    );
  }
  return AlignGuide(
    point: Offset(probe.dx, bestYNode!.dy),
    node: bestYNode,
    horizontal: true,
    delta: bestDy,
  );
}

/// A midpoint snap (B24) onto an existing run (network edge): the run's midpoint
/// [point] and its [distance] from the probe. In the store's precedence this
/// sits between node-snap and the plan-underlay vector candidates.
class MidpointHit {
  final Offset point;
  final double distance;
  const MidpointHit(this.point, this.distance);

  SnapKind get kind => SnapKind.midpoint;

  @override
  String toString() => 'MidpointHit($point, d=$distance)';
}

/// The nearest run midpoint within [radius] of [probe], or null. [runs] are the
/// existing edges as (endpointA, endpointB) pairs; a zero-length run is skipped.
MidpointHit? nearestRunMidpoint(
  Iterable<(Offset, Offset)> runs,
  Offset probe,
  double radius,
) {
  if (radius <= 0) return null;
  MidpointHit? best;
  for (final (a, b) in runs) {
    if (a.dx == b.dx && a.dy == b.dy) continue; // degenerate run
    final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
    final d = (mid - probe).distance;
    if (d <= radius && (best == null || d < best.distance)) {
      best = MidpointHit(mid, d);
    }
  }
  return best;
}

/// The B25 parallel-offset TRACK lock: given an underlay segment [a]→[b], an
/// [offset] distance, and the current [probe], the probe PROJECTED onto the line
/// parallel to the segment at [offset], on the **probe's side** of the segment.
/// Null for a degenerate (zero-length) segment. [side] (+1/−1) records which side
/// the parallel sits (relative to the segment's left-normal) and [base] is a
/// point on that parallel — both for the dashed-track render; the rubber band
/// locks to [point].
class ParallelTrack {
  /// The probe projected onto the offset parallel — the locked point.
  final Offset point;

  /// A point on the parallel line (the segment start pushed out by the offset).
  final Offset base;

  /// +1 = the segment's left-normal side, −1 = the right — whichever the probe is on.
  final int side;
  const ParallelTrack({
    required this.point,
    required this.base,
    required this.side,
  });

  @override
  String toString() => 'ParallelTrack($point, base=$base, side=$side)';
}

/// Project [probe] onto the line parallel to segment [a]→[b] at [offset],
/// choosing the side of the segment the probe lies on. Pure; the UI locks the
/// rubber band to the returned [ParallelTrack.point]. Returns null when the
/// segment is degenerate.
ParallelTrack? parallelTrackProjection(
  Offset a,
  Offset b,
  double offset,
  Offset probe,
) {
  final dx = b.dx - a.dx, dy = b.dy - a.dy;
  final len = math.sqrt(dx * dx + dy * dy);
  if (len <= 1e-12) return null;
  final ux = dx / len, uy = dy / len; // unit direction along the segment
  final nx = -uy, ny = ux; // unit left-normal
  final signed = (probe.dx - a.dx) * nx + (probe.dy - a.dy) * ny;
  final side = signed >= 0 ? 1 : -1;
  final baseX = a.dx + side * offset * nx;
  final baseY = a.dy + side * offset * ny;
  final t = (probe.dx - baseX) * ux + (probe.dy - baseY) * uy;
  return ParallelTrack(
    point: Offset(baseX + t * ux, baseY + t * uy),
    base: Offset(baseX, baseY),
    side: side,
  );
}
