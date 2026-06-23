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
