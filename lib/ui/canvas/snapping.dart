import 'dart:math' as math;

import 'package:flutter/widgets.dart' show Offset;

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
