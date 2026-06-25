import 'package:flutter/widgets.dart';

import 'segment_palette.dart';

/// Industry-style glyphs for the mechanical palette's node/segment kinds, drawn
/// from primitives (no icon font, so they never tofu) — the mechanical analogue
/// of the electrical `LoadSymbol`, so both palettes read as one node language.
void paintSegmentSymbol(
  Canvas canvas,
  Size size,
  PaletteItemKind kind,
  Color color, {
  double stroke = 1.6,
}) {
  final p = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final fill = Paint()
    ..color = color
    ..style = PaintingStyle.fill;
  final w = size.width;
  final h = size.height;
  final cy = h / 2;

  switch (kind) {
    case PaletteItemKind.pipeSegment:
      // A run of pipe: a horizontal line capped by two junction nodes.
      canvas.drawLine(Offset(w * 0.16, cy), Offset(w * 0.84, cy), p);
      canvas.drawCircle(Offset(w * 0.16, cy), w * 0.08, fill);
      canvas.drawCircle(Offset(w * 0.84, cy), w * 0.08, fill);
    case PaletteItemKind.ductSegment:
      // A duct: a double-walled rectangle (two parallel rails).
      canvas.drawLine(Offset(w * 0.16, h * 0.34), Offset(w * 0.84, h * 0.34), p);
      canvas.drawLine(Offset(w * 0.16, h * 0.66), Offset(w * 0.84, h * 0.66), p);
      canvas.drawLine(Offset(w * 0.16, h * 0.34), Offset(w * 0.16, h * 0.66), p);
      canvas.drawLine(Offset(w * 0.84, h * 0.34), Offset(w * 0.84, h * 0.66), p);
    case PaletteItemKind.fitting:
      // A fitting / junction: a filled elbow node.
      final path = Path()
        ..moveTo(w * 0.22, h * 0.78)
        ..lineTo(w * 0.22, cy)
        ..lineTo(w * 0.78, cy);
      canvas.drawPath(path, p);
      canvas.drawCircle(Offset(w * 0.22, cy), w * 0.11, fill);
    case PaletteItemKind.terminal:
      // A terminal / outlet: a hollow square (a fixture/diffuser endpoint).
      final r = Rect.fromCenter(
          center: Offset(w / 2, cy), width: w * 0.5, height: h * 0.5);
      canvas.drawRect(r, p);
      canvas.drawLine(Offset(w * 0.5, h * 0.1), Offset(w * 0.5, h * 0.25), p);
  }
}

/// A small widget rendering [paintSegmentSymbol] for [kind].
class SegmentSymbol extends StatelessWidget {
  final PaletteItemKind kind;
  final Color color;
  final double size;
  final double stroke;

  const SegmentSymbol({
    super.key,
    required this.kind,
    required this.color,
    this.size = 16,
    this.stroke = 1.6,
  });

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(size, size),
        painter: _SegmentSymbolPainter(kind, color, stroke),
      );
}

class _SegmentSymbolPainter extends CustomPainter {
  final PaletteItemKind kind;
  final Color color;
  final double stroke;
  _SegmentSymbolPainter(this.kind, this.color, this.stroke);

  @override
  void paint(Canvas canvas, Size size) =>
      paintSegmentSymbol(canvas, size, kind, color, stroke: stroke);

  @override
  bool shouldRepaint(_SegmentSymbolPainter old) =>
      old.kind != kind || old.color != color || old.stroke != stroke;
}
