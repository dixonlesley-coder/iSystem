import 'package:flutter/widgets.dart';
import 'package:mechx_engine/network/network.dart';

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
    case PaletteItemKind.component:
      // Equipment uses its own [paintComponentSymbol]; this is only a fallback
      // (a generic node dot) so the switch stays exhaustive.
      canvas.drawCircle(Offset(w / 2, cy), w * 0.12, fill);
  }
}

/// Schematic glyphs for an equipment [NodeComponent] (pump, tank, valve, drain,
/// meter…). Drawn from primitives so they never tofu; one source for both the
/// palette card and the on-canvas node marker.
void paintComponentSymbol(
  Canvas canvas,
  Size size,
  NodeComponent c,
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
  final cx = w / 2;
  final cy = h / 2;

  void bowtie() {
    // A valve body: two triangles meeting tip-to-tip.
    final path = Path()
      ..moveTo(w * 0.2, h * 0.28)
      ..lineTo(w * 0.2, h * 0.72)
      ..lineTo(cx, cy)
      ..close()
      ..moveTo(w * 0.8, h * 0.28)
      ..lineTo(w * 0.8, h * 0.72)
      ..lineTo(cx, cy)
      ..close();
    canvas.drawPath(path, p);
  }

  switch (c) {
    case NodeComponent.pump:
      // Circle with an inscribed triangle (impeller), flow to the right.
      canvas.drawCircle(Offset(cx, cy), w * 0.30, p);
      final tri = Path()
        ..moveTo(cx - w * 0.10, cy - w * 0.14)
        ..lineTo(cx + w * 0.18, cy)
        ..lineTo(cx - w * 0.10, cy + w * 0.14)
        ..close();
      canvas.drawPath(tri, fill);
    case NodeComponent.roofTank:
      // A tank with a roof cap + water line.
      final r = Rect.fromLTWH(w * 0.22, h * 0.34, w * 0.56, h * 0.46);
      canvas.drawRect(r, p);
      canvas.drawLine(Offset(w * 0.18, h * 0.34), Offset(w * 0.82, h * 0.34), p);
      canvas.drawLine(Offset(w * 0.30, h * 0.34), Offset(cx, h * 0.18), p);
      canvas.drawLine(Offset(w * 0.70, h * 0.34), Offset(cx, h * 0.18), p);
      canvas.drawLine(Offset(w * 0.28, h * 0.50), Offset(w * 0.72, h * 0.50), p);
    case NodeComponent.groundTank:
      // A tank sitting on the ground (base line), water line inside.
      final r = Rect.fromLTWH(w * 0.20, h * 0.30, w * 0.60, h * 0.46);
      canvas.drawRect(r, p);
      canvas.drawLine(Offset(w * 0.26, h * 0.44), Offset(w * 0.74, h * 0.44), p);
      canvas.drawLine(Offset(w * 0.12, h * 0.80), Offset(w * 0.88, h * 0.80), p);
    case NodeComponent.boosterSet:
      // Two small pumps on a base — a packaged set.
      canvas.drawCircle(Offset(w * 0.36, cy), w * 0.16, p);
      canvas.drawCircle(Offset(w * 0.64, cy), w * 0.16, p);
      canvas.drawLine(Offset(w * 0.14, h * 0.78), Offset(w * 0.86, h * 0.78), p);
    case NodeComponent.gateValve:
      bowtie();
    case NodeComponent.checkValve:
      // Valve body + a flow arrow (non-return direction).
      bowtie();
      canvas.drawLine(Offset(w * 0.12, cy), Offset(w * 0.88, cy), p);
      final a = Path()
        ..moveTo(w * 0.74, cy - w * 0.08)
        ..lineTo(w * 0.88, cy)
        ..lineTo(w * 0.74, cy + w * 0.08);
      canvas.drawPath(a, p);
    case NodeComponent.prv:
      // Valve body + an adjuster stem/spring on top (pressure-reducing).
      bowtie();
      canvas.drawLine(Offset(cx, h * 0.28), Offset(cx, h * 0.08), p);
      canvas.drawLine(Offset(w * 0.40, h * 0.10), Offset(w * 0.60, h * 0.10), p);
    case NodeComponent.balancingValve:
      // Valve body + a handle dot (measuring/balancing).
      bowtie();
      canvas.drawLine(Offset(cx, h * 0.28), Offset(cx, h * 0.12), p);
      canvas.drawCircle(Offset(cx, h * 0.12), w * 0.06, fill);
    case NodeComponent.roofDrain:
      // A domed drain with a grate cross.
      canvas.drawCircle(Offset(cx, cy), w * 0.30, p);
      canvas.drawLine(Offset(w * 0.26, cy), Offset(w * 0.74, cy), p);
      canvas.drawLine(Offset(cx, h * 0.26), Offset(cx, h * 0.74), p);
    case NodeComponent.floorDrain:
      // A square grated drain.
      final r = Rect.fromCenter(
          center: Offset(cx, cy), width: w * 0.56, height: h * 0.56);
      canvas.drawRect(r, p);
      canvas.drawLine(Offset(w * 0.30, cy), Offset(w * 0.70, cy), p);
      canvas.drawLine(Offset(cx, h * 0.30), Offset(cx, h * 0.70), p);
    case NodeComponent.cleanout:
      // A circle with a removable plug cap.
      canvas.drawCircle(Offset(cx, cy + h * 0.04), w * 0.26, p);
      canvas.drawRect(
          Rect.fromLTWH(w * 0.40, h * 0.12, w * 0.20, h * 0.12), fill);
    case NodeComponent.waterMeter:
      // A gauge: circle + a needle.
      canvas.drawCircle(Offset(cx, cy), w * 0.30, p);
      canvas.drawLine(Offset(cx, cy), Offset(w * 0.66, h * 0.34), p);
      canvas.drawCircle(Offset(cx, cy), w * 0.04, fill);
    case NodeComponent.strainer:
      // A Y-strainer: a horizontal line with a diagonal branch.
      canvas.drawLine(Offset(w * 0.14, cy), Offset(w * 0.86, cy), p);
      canvas.drawLine(Offset(cx, cy), Offset(w * 0.74, h * 0.82), p);
      canvas.drawLine(Offset(w * 0.62, h * 0.74), Offset(w * 0.84, h * 0.90), p);
    case NodeComponent.expansionTank:
      // A capsule with a diaphragm line.
      final r = RRect.fromRectAndRadius(
          Rect.fromLTWH(w * 0.34, h * 0.16, w * 0.32, h * 0.68),
          Radius.circular(w * 0.16));
      canvas.drawRRect(r, p);
      canvas.drawLine(Offset(w * 0.34, cy), Offset(w * 0.66, cy), p);
    case NodeComponent.airVent:
      // A small body with an up arrow (air escaping).
      canvas.drawCircle(Offset(cx, h * 0.64), w * 0.20, p);
      final up = Path()
        ..moveTo(cx, h * 0.10)
        ..lineTo(cx - w * 0.12, h * 0.30)
        ..moveTo(cx, h * 0.10)
        ..lineTo(cx + w * 0.12, h * 0.30)
        ..moveTo(cx, h * 0.10)
        ..lineTo(cx, h * 0.44);
      canvas.drawPath(up, p);
    case NodeComponent.sprinklerHead:
      // A pendent sprinkler: a small circle with a downward deflector bar.
      canvas.drawCircle(Offset(cx, h * 0.40), w * 0.16, p);
      canvas.drawLine(Offset(cx, h * 0.56), Offset(cx, h * 0.74), p);
      canvas.drawLine(Offset(w * 0.34, h * 0.78), Offset(w * 0.66, h * 0.78), p);
    case NodeComponent.fireExtinguisher:
      // A portable extinguisher: a rounded bottle with a valve cap.
      final body = RRect.fromRectAndRadius(
          Rect.fromLTWH(w * 0.36, h * 0.34, w * 0.28, h * 0.50),
          Radius.circular(w * 0.10));
      canvas.drawRRect(body, p);
      canvas.drawRect(Rect.fromLTWH(w * 0.44, h * 0.22, w * 0.12, h * 0.12), p);
      canvas.drawLine(Offset(w * 0.56, h * 0.26), Offset(w * 0.72, h * 0.26), p);
    case NodeComponent.hydrantBox:
      // A wall hydrant/hose box: a square with a coiled-hose ring inside.
      canvas.drawRect(
          Rect.fromLTWH(w * 0.18, h * 0.20, w * 0.64, h * 0.60), p);
      canvas.drawCircle(Offset(cx, cy), w * 0.14, p);
      canvas.drawCircle(Offset(cx, cy), w * 0.05, p);
    case NodeComponent.hoseReel:
      // A swing hose reel: concentric rings with a feed line.
      canvas.drawCircle(Offset(cx, cy), w * 0.28, p);
      canvas.drawCircle(Offset(cx, cy), w * 0.10, p);
      canvas.drawLine(Offset(w * 0.10, cy), Offset(w * 0.22, cy), p);
    case NodeComponent.fireDeptConnection:
      // A Siamese FDC: two inlets with an arrow feeding in.
      canvas.drawCircle(Offset(w * 0.36, cy), w * 0.16, p);
      canvas.drawCircle(Offset(w * 0.64, cy), w * 0.16, p);
      final a = Path()
        ..moveTo(cx, h * 0.10)
        ..lineTo(cx - w * 0.10, h * 0.26)
        ..moveTo(cx, h * 0.10)
        ..lineTo(cx + w * 0.10, h * 0.26);
      canvas.drawPath(a, p);
  }
}

/// A small widget rendering [paintComponentSymbol] for [component].
class ComponentSymbol extends StatelessWidget {
  final NodeComponent component;
  final Color color;
  final double size;
  final double stroke;

  const ComponentSymbol({
    super.key,
    required this.component,
    required this.color,
    this.size = 16,
    this.stroke = 1.6,
  });

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(size, size),
        painter: _ComponentSymbolPainter(component, color, stroke),
      );
}

class _ComponentSymbolPainter extends CustomPainter {
  final NodeComponent component;
  final Color color;
  final double stroke;
  _ComponentSymbolPainter(this.component, this.color, this.stroke);

  @override
  void paint(Canvas canvas, Size size) =>
      paintComponentSymbol(canvas, size, component, color, stroke: stroke);

  @override
  bool shouldRepaint(_ComponentSymbolPainter old) =>
      old.component != component ||
      old.color != color ||
      old.stroke != stroke;
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
