/// Auto-generated schematic riser diagram of the drawn MechX network (P4
/// "auto diagram"). Read-only; derives its layout entirely from the live
/// Riverpod state — network, sizing, and building levels.
///
/// Layout:
///   VERTICAL   — one horizontal band per floor.  Band 0 is at the BOTTOM,
///                the top floor is at the TOP (architecture convention).
///   HORIZONTAL — nodes within a floor are ordered by their canvas x and
///                evenly spaced across the paint width.
///
/// Callers place it like any other widget; no configuration is required.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';

import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/sizing_store.dart';
import '../canvas/service_style.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

// ---------------------------------------------------------------------------
// Public widget
// ---------------------------------------------------------------------------

/// Renders a generated schematic riser diagram from the current network /
/// sizing / building state.  Drop-in: it is pointer-passive and sizes itself
/// to fill the available space via [LayoutBuilder] → [CustomPaint].
class SchematicView extends ConsumerWidget {
  const SchematicView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network = ref.watch(networkControllerProvider).network;
    final sizing = ref.watch(sizingProvider);
    final building = ref.watch(projectControllerProvider).building;
    final colors = context.colors;
    final type = context.type;

    // Empty-network guard — show a centred, muted placeholder message.
    if (network.nodes.isEmpty) {
      return ColoredBox(
        color: colors.canvas,
        child: Center(
          child: Text(
            'No network drawn',
            style: type.body.copyWith(color: colors.textMuted),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(
          constraints.maxWidth.isFinite ? constraints.maxWidth : 800,
          constraints.maxHeight.isFinite ? constraints.maxHeight : 600,
        );
        return ColoredBox(
          color: colors.canvas,
          child: CustomPaint(
            size: size,
            painter: _SchematicPainter(
              network: network,
              sizing: sizing,
              building: building,
              colors: colors,
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Painter
// ---------------------------------------------------------------------------

class _SchematicPainter extends CustomPainter {
  const _SchematicPainter({
    required this.network,
    required this.sizing,
    required this.building,
    required this.colors,
  });

  final Network network;
  final Map<String, EdgeSizing> sizing;
  final BuildingLevels building;
  final MechXColors colors;

  // Visual constants (design-token multiples).
  static const double _sidePad = MechXSpacing.xl; // left/right margin
  static const double _nodeRadius = 4.0;
  static const double _edgeStroke = 2.0;
  static const double _gridStrokeWidth = 0.5;
  static const double _labelFontSize = 10.0;
  static const double _floorLabelFontSize = 11.0;

  // ---------------------------------------------------------------------------
  // Layout helpers
  // ---------------------------------------------------------------------------

  /// Height (pixels) allocated to one floor band.
  double _bandHeight(double totalHeight) =>
      totalHeight / building.levelCount.clamp(1, 999999);

  /// Screen-y of the top edge of a floor band.
  ///
  /// Floor 0 → bottom of canvas (high y); highest floor → top (low y).
  double _bandTopY(int floorIndex, double totalHeight) {
    final n = building.levelCount;
    final bandH = totalHeight / n;
    final invertedIndex = (n - 1) - floorIndex;
    return bandH * invertedIndex;
  }

  /// Screen-y of the horizontal centre-line of a floor band.
  double _bandCentreY(int floorIndex, double totalHeight) =>
      _bandTopY(floorIndex, totalHeight) + _bandHeight(totalHeight) / 2;

  // ---------------------------------------------------------------------------
  // Node → screen-position mapping
  // ---------------------------------------------------------------------------

  /// Returns a nodeId → screen-space [Offset] map.
  ///
  /// Within each floor, nodes are sorted by their original canvas x and then
  /// evenly distributed across [_sidePad … width - _sidePad].
  Map<String, Offset> _computeNodePositions(Size size) {
    final byFloor = <int, List<NetNode>>{};
    for (final node in network.nodes) {
      (byFloor[node.floorIndex] ??= []).add(node);
    }

    final positions = <String, Offset>{};
    final drawWidth = size.width - 2 * _sidePad;

    for (final entry in byFloor.entries) {
      final floorIndex = entry.key;
      final nodes = List<NetNode>.from(entry.value)
        ..sort((a, b) => a.x.compareTo(b.x));
      final cy = _bandCentreY(floorIndex, size.height);

      if (nodes.length == 1) {
        positions[nodes.first.id] = Offset(size.width / 2, cy);
      } else {
        final step = drawWidth / (nodes.length - 1);
        for (var i = 0; i < nodes.length; i++) {
          positions[nodes[i].id] = Offset(_sidePad + i * step, cy);
        }
      }
    }

    return positions;
  }

  // ---------------------------------------------------------------------------
  // Sizing label
  // ---------------------------------------------------------------------------

  String _sizeLabel(EdgeSizing s) {
    final mm = s.diameter.inMillimeters.round();
    return s.service.regime == FlowRegime.air ? 'Ø$mm' : 'DN$mm';
  }

  // ---------------------------------------------------------------------------
  // paint
  // ---------------------------------------------------------------------------

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final nodePos = _computeNodePositions(size);
    _paintBands(canvas, size);
    _paintEdges(canvas, nodePos);
    _paintNodes(canvas, nodePos);
  }

  // ---------------------------------------------------------------------------
  // Band rendering
  // ---------------------------------------------------------------------------

  void _paintBands(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = colors.border.withAlpha(115) // ~45 % opacity
      ..strokeWidth = _gridStrokeWidth
      ..style = PaintingStyle.stroke;

    for (var i = 0; i < building.levelCount; i++) {
      final top = _bandTopY(i, size.height);

      // Faint horizontal grid line at the top edge of each band.
      canvas.drawLine(Offset(0, top), Offset(size.width, top), gridPaint);

      // Floor label: name + elevation.
      final floor = building.floors[i];
      final elevM = building.elevationOf(i).meters;
      // Show whole-number elevations without decimals.
      final elevStr =
          elevM % 1 == 0 ? '${elevM.toStringAsFixed(0)} m' : '${elevM.toStringAsFixed(2)} m';
      final label = '${floor.name}  +$elevStr';

      _drawText(
        canvas,
        label,
        Offset(MechXSpacing.sm, top + MechXSpacing.xs),
        fontSize: _floorLabelFontSize,
        color: colors.textMuted,
        fontWeight: FontWeight.w500,
        maxWidth: size.width / 2,
      );
    }

    // Bottom grid line.
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      gridPaint,
    );
  }

  // ---------------------------------------------------------------------------
  // Edge rendering
  // ---------------------------------------------------------------------------

  void _paintEdges(Canvas canvas, Map<String, Offset> nodePos) {
    for (final edge in network.edges) {
      final from = nodePos[edge.fromId];
      final to = nodePos[edge.toId];
      if (from == null || to == null) continue;

      final color = serviceColor(edge.service);
      final linePaint = Paint()
        ..color = color
        ..strokeWidth = _edgeStroke
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      if (edge.kind == EdgeKind.riser) {
        // Route as an orthogonal L-shape: horizontal to the midpoint-x, then
        // vertical, then horizontal to the destination.  The vertical segment
        // makes riser routing visually unambiguous.
        final midX = (from.dx + to.dx) / 2;
        final path = Path()
          ..moveTo(from.dx, from.dy)
          ..lineTo(midX, from.dy)
          ..lineTo(midX, to.dy)
          ..lineTo(to.dx, to.dy);
        canvas.drawPath(path, linePaint);

        // Direction arrow on the vertical segment.
        final arrowY = (from.dy + to.dy) / 2;
        final goingUp = to.dy < from.dy;
        _drawArrow(canvas, Offset(midX, arrowY), goingUp, color);

        // Size label beside the vertical leg.
        final s = sizing[edge.id];
        if (s != null) {
          _drawText(
            canvas,
            _sizeLabel(s),
            Offset(midX + MechXSpacing.xs, arrowY - MechXSpacing.sm),
            fontSize: _labelFontSize,
            color: color,
            fontWeight: FontWeight.w500,
          );
        }
      } else {
        // Run: straight connector within the band.
        canvas.drawLine(from, to, linePaint);

        final s = sizing[edge.id];
        if (s != null) {
          final midX = (from.dx + to.dx) / 2;
          final midY = (from.dy + to.dy) / 2;
          _drawText(
            canvas,
            _sizeLabel(s),
            Offset(midX, midY - MechXSpacing.md),
            fontSize: _labelFontSize,
            color: color,
            fontWeight: FontWeight.w500,
            centered: true,
          );
        }
      }
    }
  }

  void _drawArrow(Canvas canvas, Offset tip, bool pointUp, Color color) {
    const h = 6.0;
    const w = 4.0;
    final sign = pointUp ? -1.0 : 1.0;
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(tip.dx - w, tip.dy + sign * h)
      ..lineTo(tip.dx + w, tip.dy + sign * h)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  // ---------------------------------------------------------------------------
  // Node rendering
  // ---------------------------------------------------------------------------

  void _paintNodes(Canvas canvas, Map<String, Offset> nodePos) {
    for (final pos in nodePos.values) {
      // Canvas-coloured halo keeps the dot legible over edge lines.
      canvas.drawCircle(
        pos,
        _nodeRadius + 1.5,
        Paint()..color = colors.canvas,
      );
      canvas.drawCircle(
        pos,
        _nodeRadius,
        Paint()..color = colors.textSecondary,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Text helper using TextPainter (no dart:ui import required)
  // ---------------------------------------------------------------------------

  void _drawText(
    Canvas canvas,
    String text,
    Offset origin, {
    required double fontSize,
    required Color color,
    FontWeight fontWeight = FontWeight.w400,
    double? maxWidth,
    bool centered = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'Roboto',
          fontSize: fontSize,
          color: color,
          fontWeight: fontWeight,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth ?? 200);

    final dx = centered ? origin.dx - tp.width / 2 : origin.dx;
    tp.paint(canvas, Offset(dx, origin.dy));
  }

  // ---------------------------------------------------------------------------

  @override
  bool shouldRepaint(_SchematicPainter old) =>
      old.network != network ||
      old.sizing != sizing ||
      old.building != building ||
      old.colors != colors;
}
