import 'package:flutter/widgets.dart' show Offset;

/// Pure route + segment geometry shared by the network store's CAD editing
/// intents (B17 two-click ortho routing, B18 trim/extend, B19 corner-join). No
/// Riverpod / no store state — just points in — so every rule is unit-testable
/// in isolation. (App-side, so `Offset` from `package:flutter/widgets` is fine —
/// this is NOT the pure engine.)

/// The shape of a two-click orthogonal route (B17). Cycled by Tab in the draw
/// overlay; the pure [orthoRoute] renders each into concrete leg points.
enum OrthoRouteKind {
  /// L-shape, the HORIZONTAL leg leads: start -> (end.x, start.y) -> end.
  horizontalFirst,

  /// L-shape, the VERTICAL leg leads: start -> (start.x, end.y) -> end.
  verticalFirst,

  /// A chamfered "Z": a 45-degree leg covering the SHORTER offset, then an
  /// axis-aligned leg to the end. Used when both offsets are large.
  diagonalZ,
}

/// Off-axis threshold (world px) below which [orthoRoute] collapses a bend to a
/// single straight segment — an invisible micro-jog is never worth a node.
const double kRouteStraightEpsilonPx = 1e-6;

/// The default per-axis offset (world px) above which BOTH offsets are
/// considered "large" enough to prefer the [OrthoRouteKind.diagonalZ] chamfer
/// over a hard right-angle L (see [autoRouteKind]).
const double kRouteZThresholdPx = 40;

/// The concrete leg POINTS of an orthogonal route from [start] to [end] in the
/// requested [kind] — 2 points (a single axis/45 segment) when the route is
/// degenerate (one offset zero, or an exact 45 diagonal), else 3 points (two
/// segments meeting at one bend). Every returned segment is axis-aligned or on
/// an exact 45-degree multiple BY CONSTRUCTION, so ortho geometry is preserved
/// with no trig / no rounding.
List<Offset> orthoRoute(
  Offset start,
  Offset end, {
  OrthoRouteKind kind = OrthoRouteKind.horizontalFirst,
}) {
  final dx = end.dx - start.dx;
  final dy = end.dy - start.dy;
  final ax = dx.abs();
  final ay = dy.abs();
  // A straight axis run (one offset zero) OR an exact 45 diagonal (equal
  // offsets) needs no bend — the corner would be zero-length.
  if (ax <= kRouteStraightEpsilonPx ||
      ay <= kRouteStraightEpsilonPx ||
      (ax - ay).abs() <= kRouteStraightEpsilonPx) {
    return [start, end];
  }
  switch (kind) {
    case OrthoRouteKind.horizontalFirst:
      return [start, Offset(end.dx, start.dy), end];
    case OrthoRouteKind.verticalFirst:
      return [start, Offset(start.dx, end.dy), end];
    case OrthoRouteKind.diagonalZ:
      final sx = dx.sign;
      final sy = dy.sign;
      if (ax > ay) {
        // Horizontal is the longer axis: a 45 diagonal covers the vertical
        // offset (reaching end.y), then an axis-horizontal leg closes to end.
        final knee = Offset(start.dx + sx * ay, end.dy);
        return [start, knee, end];
      }
      // Vertical is the longer axis: diagonal covers the horizontal offset
      // (reaching end.x), then an axis-vertical leg closes to end.
      final knee = Offset(end.dx, start.dy + sy * ax);
      return [start, knee, end];
  }
}

/// Which [OrthoRouteKind] to default to for the [start]->[end] geometry: the
/// diagonal Z when BOTH offsets exceed [threshold] (a long dog-leg reads better
/// chamfered), else an L led by the caller's [legFirstHorizontal] preference.
/// Tab still lets the user override; this is only the initial pick.
OrthoRouteKind autoRouteKind(
  Offset start,
  Offset end, {
  double threshold = kRouteZThresholdPx,
  bool legFirstHorizontal = true,
}) {
  final ax = (end.dx - start.dx).abs();
  final ay = (end.dy - start.dy).abs();
  if (ax > threshold && ay > threshold) return OrthoRouteKind.diagonalZ;
  return legFirstHorizontal
      ? OrthoRouteKind.horizontalFirst
      : OrthoRouteKind.verticalFirst;
}

/// The parametric intersection of two INFINITE lines: line A through [a0] with
/// direction [da], line B through [b0] with direction [db]. Returns `(tA, sB)`
/// such that `a0 + tA*da == b0 + sB*db`, or null when the lines are parallel
/// (cross product within [eps]). `sB` in [0,1] means the crossing lies within
/// the B SEGMENT [b0, b0+db] — the "on the boundary" test for trim/extend.
(double tA, double sB)? lineIntersectionParams(
  Offset a0,
  Offset da,
  Offset b0,
  Offset db, {
  double eps = 1e-9,
}) {
  final denom = da.dx * db.dy - da.dy * db.dx; // da x db
  if (denom.abs() < eps) return null; // parallel / collinear
  final wx = b0.dx - a0.dx;
  final wy = b0.dy - a0.dy;
  final tA = (wx * db.dy - wy * db.dx) / denom;
  final sB = (wx * da.dy - wy * da.dx) / denom;
  return (tA, sB);
}
