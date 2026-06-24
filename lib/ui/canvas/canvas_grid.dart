import 'package:flutter/widgets.dart';

import 'viewport.dart';

/// The shared "drafting" grid painted behind BOTH the mechanical sheet canvas
/// and the electrical single-line canvas, so the two workspaces read as one
/// app on the same graph-paper substrate (one implementation — never two grids
/// that drift apart).
///
/// World-space lines every [worldStep] px, faded to a hairline ([gridLine] at
/// ~35% alpha). The grid hides once the on-screen spacing drops below
/// [minScreenStep] (avoids moiré when zoomed far out). Painted in SCREEN space
/// using the [transform], so it pans/zooms 1:1 with the content above it.
void paintCanvasGrid(
  Canvas canvas,
  Size size,
  ViewportTransform transform,
  Color gridLine, {
  double worldStep = 32.0,
  double minScreenStep = 6.0,
}) {
  final step = worldStep * transform.scale;
  if (step < minScreenStep) return;
  final paint = Paint()
    ..color = gridLine.withAlpha(90)
    ..strokeWidth = 1;
  // `%` with a positive divisor is non-negative in Dart, so a panned (negative)
  // offset still yields an origin in [0, step).
  final originX = transform.offset.dx % step;
  final originY = transform.offset.dy % step;
  for (var x = originX; x < size.width; x += step) {
    canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
  }
  for (var y = originY; y < size.height; y += step) {
    canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
  }
}
