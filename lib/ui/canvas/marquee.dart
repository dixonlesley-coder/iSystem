/// The rubber-band MARQUEE vocabulary shared by the electrical canvases (the
/// single-line and the electrical layer on the Layout plan): the AutoCAD
/// muscle-memory WINDOW (left-to-right drag, solid edge, fully-enclosed items
/// only) vs CROSSING (right-to-left drag, dashed 5/3 edge, anything touched)
/// convention the mechanical Layout (`selection_overlay`) and the Riser use,
/// with the same translucent accent fill (alpha 38).
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Whether a marquee dragged from [start] to [now] is a WINDOW (left-to-right,
/// fully-enclosed-only); false ⇒ a CROSSING (right-to-left, touch-selects).
bool marqueeIsWindow(Offset start, Offset now) => now.dx >= start.dx;

/// Whether an item occupying [item] is caught by the marquee [rect]: fully
/// inside it for a [window], merely touching it for a crossing.
bool marqueeCatches(Rect rect, Rect item, {required bool window}) => window
    ? item.left >= rect.left &&
        item.top >= rect.top &&
        item.right <= rect.right &&
        item.bottom <= rect.bottom
    : item.overlaps(rect);

/// Paints the translucent marquee rectangle (screen space) from [start] to
/// [now]: a SOLID border for a window, a DASHED one for a crossing.
class MarqueePainter extends CustomPainter {
  final Offset start;
  final Offset now;
  final Color accent;

  MarqueePainter({
    required this.start,
    required this.now,
    required this.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromPoints(start, now);
    canvas.drawRect(rect, Paint()..color = accent.withAlpha(38));
    final border = Paint()
      ..color = accent
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    if (marqueeIsWindow(start, now)) {
      canvas.drawRect(rect, border);
    } else {
      _dashedRect(canvas, rect, border);
    }
  }

  static void _dashedRect(Canvas canvas, Rect rect, Paint paint) {
    const dash = 5.0;
    const gap = 3.0;
    void dashedLine(Offset a, Offset b) {
      final total = (b - a).distance;
      if (total == 0) return;
      final dir = (b - a) / total;
      var walked = 0.0;
      while (walked < total) {
        final segEnd = math.min(walked + dash, total);
        canvas.drawLine(a + dir * walked, a + dir * segEnd, paint);
        walked += dash + gap;
      }
    }

    dashedLine(rect.topLeft, rect.topRight);
    dashedLine(rect.topRight, rect.bottomRight);
    dashedLine(rect.bottomRight, rect.bottomLeft);
    dashedLine(rect.bottomLeft, rect.topLeft);
  }

  @override
  bool shouldRepaint(MarqueePainter old) =>
      old.start != start || old.now != now || old.accent != accent;
}
