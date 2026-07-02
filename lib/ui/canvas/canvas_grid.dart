import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'viewport.dart';

/// The shared "drafting" grid painted behind BOTH the mechanical sheet canvas
/// and the electrical single-line canvas, so the two workspaces read as one
/// app on the same graph-paper substrate (one implementation — never two grids
/// that drift apart).
///
/// World-space lines every [worldStep] px, faded to a hairline ([gridLine] at
/// ~35% alpha), with every [majorEvery]-th line drawn noticeably stronger —
/// the drafting major/minor hierarchy. The major cadence is keyed to the
/// WORLD line index (line k sits at world k·[worldStep]), so majors are
/// anchored to the world origin and stay put under pan/zoom. Minor lines hide
/// once their on-screen spacing drops below [minScreenStep] (avoids moiré when
/// zoomed far out); the majors survive on their own until their spacing drops
/// below it too. Painted in SCREEN space using the [transform], so the grid
/// pans/zooms 1:1 with the content above it.
void paintCanvasGrid(
  Canvas canvas,
  Size size,
  ViewportTransform transform,
  Color gridLine, {
  double worldStep = 32.0,
  double minScreenStep = 6.0,
  int majorEvery = 4,
}) {
  final step = worldStep * transform.scale;
  if (step <= 0 || !step.isFinite) return;
  final minorsVisible = step >= minScreenStep;
  final majorsVisible = step * majorEvery >= minScreenStep;
  if (!minorsVisible && !majorsVisible) return;

  final minorPaint = Paint()
    ..color = gridLine.withAlpha(90)
    ..strokeWidth = 1;
  final majorPaint = Paint()
    ..color = gridLine.withAlpha(190)
    ..strokeWidth = 1;

  // Draw the lines along one axis: line k sits at screen `offset + k·step`
  // (world x = k·worldStep). When the minors are hidden we stride straight
  // over the major indices so a far-out zoom stays cheap.
  void drawAxis(double offset, double extent, void Function(double, Paint) line) {
    final stride = minorsVisible ? 1 : majorEvery;
    var k = ((-offset) / step).ceil();
    if (stride > 1) k = (k / stride).ceil() * stride;
    for (;; k += stride) {
      final pos = offset + k * step;
      if (pos >= extent) break;
      line(pos, k % majorEvery == 0 ? majorPaint : minorPaint);
    }
  }

  drawAxis(transform.offset.dx, size.width,
      (x, p) => canvas.drawLine(Offset(x, 0), Offset(x, size.height), p));
  drawAxis(transform.offset.dy, size.height,
      (y, p) => canvas.drawLine(Offset(0, y), Offset(size.width, y), p));
}

/// The drafting-grid WORLD step (sheet px) for a CALIBRATED sheet: the minor
/// grid lands on a round 1-2-5 metre ladder value (0.5 m, 1 m, 2 m, 5 m …) —
/// the step whose pixel span is closest (log-scale) to the uncalibrated
/// [defaultStep] texture — so with [paintCanvasGrid]'s default `majorEvery: 4`
/// the majors fall on the 4× round-metre multiple. A non-positive/non-finite
/// [metersPerPixel] falls back to [defaultStep] (the uncalibrated default).
double calibratedGridWorldStep(double metersPerPixel,
    {double defaultStep = 32.0}) {
  if (!(metersPerPixel > 0) || !metersPerPixel.isFinite) return defaultStep;
  final pxPerMetre = 1.0 / metersPerPixel;
  var best = defaultStep;
  var bestErr = double.infinity;
  for (var exp = -3; exp <= 3; exp++) {
    for (final m in const [1.0, 2.0, 5.0]) {
      final metres = m * math.pow(10.0, exp).toDouble();
      final px = metres * pxPerMetre;
      if (px <= 0 || !px.isFinite) continue;
      final err = (math.log(px) - math.log(defaultStep)).abs();
      if (err < bestErr) {
        bestErr = err;
        best = px;
      }
    }
  }
  return best;
}
