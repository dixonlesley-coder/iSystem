import 'package:flutter/widgets.dart';

/// Which glyph a [SeverityGlyph] draws: a hollow ring with an exclamation
/// (warning), a ring with a centre dot (advisory / info), or a bare check
/// (the clean-state success mark).
///
/// Shared across the Review issues card and the electrical warning rows so a
/// severity is carried by SHAPE as well as colour — legible without relying on
/// hue alone (a redundant accessibility cue). Custom-painted (no icon font), so
/// it can never render as tofu in the goldens.
enum SeverityGlyphKind { warn, info, check }

/// A small custom-painted severity glyph painter — paired with a colour so the
/// meaning survives without relying on hue alone.
class SeverityGlyph extends CustomPainter {
  final SeverityGlyphKind kind;
  final Color color;

  const SeverityGlyph({required this.kind, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final c = Offset(w / 2, h / 2);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    if (kind == SeverityGlyphKind.check) {
      final path = Path()
        ..moveTo(w * 0.20, h * 0.52)
        ..lineTo(w * 0.42, h * 0.74)
        ..lineTo(w * 0.80, h * 0.26);
      canvas.drawPath(path, stroke);
      return;
    }

    // A ring for both warn + info.
    canvas.drawCircle(c, w * 0.42, stroke);
    final fill = Paint()..color = color;
    if (kind == SeverityGlyphKind.warn) {
      // An exclamation stem + dot inside the ring.
      canvas.drawLine(
        Offset(w / 2, h * 0.28),
        Offset(w / 2, h * 0.58),
        stroke,
      );
      canvas.drawCircle(Offset(w / 2, h * 0.74), w * 0.07, fill);
    } else {
      // Info: a single centre dot.
      canvas.drawCircle(c, w * 0.10, fill);
    }
  }

  @override
  bool shouldRepaint(SeverityGlyph old) =>
      old.kind != kind || old.color != color;
}
