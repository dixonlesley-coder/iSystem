/// Industry-standard (IEC 60617-style) single-line symbols for electrical
/// loads, drawn as crisp vector paths so a placed load reads as its schematic
/// symbol on the PDF instead of a text tag. Shared by the layout markers, the
/// Loads palette and the unplaced tray.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:mechx_engine/electrical/load_kind.dart';

/// Paint the [kind]'s symbol centred in [size], stroked in [color].
void paintLoadSymbol(
  Canvas canvas,
  Size size,
  LoadKind kind,
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
  final c = Offset(size.width / 2, size.height / 2);
  final r = math.min(size.width, size.height) * 0.42;

  void circle() => canvas.drawCircle(c, r, p);
  void letter(String s) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          fontFamily: 'Roboto',
          fontSize: r * 1.25,
          fontWeight: FontWeight.w700,
          color: color,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(c.dx - tp.width / 2, c.dy - tp.height / 2));
  }

  switch (kind) {
    // Luminaire — a circle crossed by an X (IEC lamp).
    case LoadKind.lighting:
      circle();
      final d = r * 0.707;
      canvas.drawLine(c + Offset(-d, -d), c + Offset(d, d), p);
      canvas.drawLine(c + Offset(d, -d), c + Offset(-d, d), p);
      break;

    // Socket-outlet — a semicircle on a baseline with a stem.
    case LoadKind.socket:
      final base = c.dy + r * 0.55;
      canvas.drawArc(
        Rect.fromCircle(center: Offset(c.dx, base), radius: r * 0.9),
        math.pi,
        math.pi,
        false,
        p,
      );
      canvas.drawLine(
          Offset(c.dx - r, base), Offset(c.dx + r, base), p);
      canvas.drawLine(
          Offset(c.dx, base - r * 0.9), Offset(c.dx, base - r * 1.5), p);
      break;

    // Motor / pump / generic-rotating-machine — letter in a circle (IEC).
    case LoadKind.motor:
      circle();
      letter('M');
      break;
    case LoadKind.pump:
      circle();
      letter('P');
      break;

    // Air-handling / fan — a circle with three swept blades.
    case LoadKind.hvac:
      circle();
      for (var i = 0; i < 3; i++) {
        final a = i * 2 * math.pi / 3;
        final tip = c + Offset(math.cos(a), math.sin(a)) * r * 0.78;
        final mid = c +
            Offset(math.cos(a + 0.9), math.sin(a + 0.9)) * r * 0.42;
        canvas.drawPath(
            Path()
              ..moveTo(c.dx, c.dy)
              ..quadraticBezierTo(mid.dx, mid.dy, tip.dx, tip.dy),
            p);
      }
      break;

    // Heating / resistive element — a rectangle (IEC resistor / heater).
    case LoadKind.heating:
      final rect = Rect.fromCenter(
          center: c, width: r * 2.0, height: r * 1.15);
      canvas.drawRect(rect, p);
      canvas.drawLine(Offset(rect.left, c.dy), Offset(rect.left - r * 0.5, c.dy), p);
      canvas.drawLine(Offset(rect.right, c.dy), Offset(rect.right + r * 0.5, c.dy), p);
      break;

    // EV charger — a charging connector with a lightning bolt.
    case LoadKind.evCharger:
      final rect = RRect.fromRectAndRadius(
          Rect.fromCenter(center: c, width: r * 1.7, height: r * 2.0),
          Radius.circular(r * 0.3));
      canvas.drawRRect(rect, p);
      final bolt = Path()
        ..moveTo(c.dx + r * 0.25, c.dy - r * 0.7)
        ..lineTo(c.dx - r * 0.35, c.dy + r * 0.1)
        ..lineTo(c.dx + r * 0.05, c.dy + r * 0.1)
        ..lineTo(c.dx - r * 0.25, c.dy + r * 0.7)
        ..lineTo(c.dx + r * 0.4, c.dy - r * 0.15)
        ..lineTo(c.dx, c.dy - r * 0.15)
        ..close();
      canvas.drawPath(bolt, fill);
      break;

    // Welding set — a transformer (two interlocking circles).
    case LoadKind.welding:
      canvas.drawCircle(c + Offset(-r * 0.45, 0), r * 0.7, p);
      canvas.drawCircle(c + Offset(r * 0.45, 0), r * 0.7, p);
      break;

    // UPS — a battery (two cells: long/short plate pairs).
    case LoadKind.ups:
      for (final dx in [-r * 0.5, r * 0.25]) {
        canvas.drawLine(Offset(c.dx + dx, c.dy - r), Offset(c.dx + dx, c.dy + r), p);
        canvas.drawLine(Offset(c.dx + dx + r * 0.35, c.dy - r * 0.55),
            Offset(c.dx + dx + r * 0.35, c.dy + r * 0.55), p);
      }
      canvas.drawLine(Offset(c.dx - r, c.dy), Offset(c.dx - r * 0.5, c.dy), p);
      canvas.drawLine(Offset(c.dx + r * 0.6, c.dy), Offset(c.dx + r, c.dy), p);
      break;

    // Capacitor / PFC — two parallel plates.
    case LoadKind.capacitor:
      canvas.drawLine(Offset(c.dx - r, c.dy - r * 0.35),
          Offset(c.dx + r, c.dy - r * 0.35), p);
      canvas.drawLine(Offset(c.dx - r, c.dy + r * 0.35),
          Offset(c.dx + r, c.dy + r * 0.35), p);
      canvas.drawLine(Offset(c.dx, c.dy - r * 0.35), Offset(c.dx, c.dy - r), p);
      canvas.drawLine(Offset(c.dx, c.dy + r * 0.35), Offset(c.dx, c.dy + r), p);
      break;

    // Spare way — a dashed circle (empty).
    case LoadKind.spare:
      const seg = 14;
      for (var i = 0; i < seg; i += 2) {
        final a0 = i * 2 * math.pi / seg;
        final a1 = (i + 1) * 2 * math.pi / seg;
        canvas.drawArc(Rect.fromCircle(center: c, radius: r), a0, a1 - a0, false, p);
      }
      break;

    // Feeder (sub-panel) — a board square. Not normally shown as a load.
    case LoadKind.feeder:
      canvas.drawRect(Rect.fromCenter(center: c, width: r * 1.8, height: r * 1.8), p);
      break;

    // General / unknown — a generic load square.
    case LoadKind.general:
      canvas.drawRect(Rect.fromCenter(center: c, width: r * 1.7, height: r * 1.7), p);
      break;
  }
}

/// A widget that draws the [kind]'s schematic symbol at [size]px in [color].
class LoadSymbol extends StatelessWidget {
  final LoadKind kind;
  final Color color;
  final double size;
  final double stroke;
  const LoadSymbol({
    super.key,
    required this.kind,
    required this.color,
    this.size = 18,
    this.stroke = 1.6,
  });

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _LoadSymbolPainter(kind, color, stroke),
      );
}

class _LoadSymbolPainter extends CustomPainter {
  final LoadKind kind;
  final Color color;
  final double stroke;
  const _LoadSymbolPainter(this.kind, this.color, this.stroke);

  @override
  void paint(Canvas canvas, Size size) =>
      paintLoadSymbol(canvas, size, kind, color, stroke: stroke);

  @override
  bool shouldRepaint(_LoadSymbolPainter old) =>
      old.kind != kind || old.color != color || old.stroke != stroke;
}
