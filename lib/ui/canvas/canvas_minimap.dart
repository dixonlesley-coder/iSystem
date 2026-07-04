import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'viewport.dart';

/// The live viewport a [CanvasView] publishes for its minimap (G1): the affine
/// [transform] plus the canvas widget [size], so the minimap can draw a truthful
/// visible-region rectangle. Mirrors the electrical canvas's `CanvasViewport`
/// record so both workspaces track their view the same way.
typedef MinimapViewport = ({ViewportTransform transform, Size size});

/// A small on-canvas MINIMAP (G1) — a scaled overview of the fixed-size sheet
/// ([contentSize]) with the drawn-content [markers] and the current viewport
/// rectangle; tap or drag to recenter the canvas.
///
/// Modelled on the electrical canvas's minimap (opaque `surface` fill + hairline
/// border + card shadow, tap/drag-to-navigate through the same geometry the
/// painter uses) so the two workspaces read as one tool. It is chrome, but
/// content-bearing (a scaled render), so it stays OPAQUE for legibility — like
/// the electrical minimap — not Liquid Glass.
class CanvasMinimap extends StatelessWidget {
  /// The world-space (content-pixel) bounds of the sheet — the minimap frames
  /// the rectangle 0,0 .. [contentSize].
  final Size contentSize;

  /// Drawn-content landmarks in CONTENT (sheet-pixel) space — the network nodes
  /// on the current sheet/floor — painted as small dots for orientation. Empty
  /// ⇒ just the sheet outline + the viewport rectangle.
  final List<Offset> markers;

  /// The live viewport (transform + canvas size); null before the first frame.
  final MinimapViewport? viewport;

  /// Recenter the canvas so this CONTENT-space point lands at the viewport
  /// centre (a tap, or a drag, on the minimap).
  final ValueChanged<Offset> onRecenter;

  const CanvasMinimap({
    super.key,
    required this.contentSize,
    required this.markers,
    required this.viewport,
    required this.onRecenter,
  });

  /// The minimap box: the sheet contained within a small max box at the sheet's
  /// own aspect (no letterbox), so world↔mini is ONE uniform scale and the
  /// painter + the tap hit-test agree.
  static const double _maxW = 140, _maxH = 108;

  double _fitScale() {
    if (contentSize.width <= 0 || contentSize.height <= 0) return 1;
    return math.min(_maxW / contentSize.width, _maxH / contentSize.height);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final s = _fitScale();
    final box = Size(contentSize.width * s, contentSize.height * s);
    if (box.isEmpty) return const SizedBox.shrink();
    void recenter(Offset local) =>
        onRecenter(Offset(local.dx / s, local.dy / s));
    return SizedBox.fromSize(
      size: box,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: MechXRadii.control,
          border: Border.all(color: colors.border),
          boxShadow: MechXShadow.card,
        ),
        child: ClipRRect(
          borderRadius: MechXRadii.control,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => recenter(d.localPosition),
              onPanStart: (d) => recenter(d.localPosition),
              onPanUpdate: (d) => recenter(d.localPosition),
              child: CustomPaint(
                painter: _MinimapPainter(
                  contentSize: contentSize,
                  scale: s,
                  markers: markers,
                  viewport: viewport,
                  sheetFill: colors.canvas,
                  sheetEdge: colors.border,
                  marker: colors.accent,
                  frame: colors.textMuted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MinimapPainter extends CustomPainter {
  final Size contentSize;
  final double scale;
  final List<Offset> markers;
  final MinimapViewport? viewport;
  final Color sheetFill, sheetEdge, marker, frame;

  _MinimapPainter({
    required this.contentSize,
    required this.scale,
    required this.markers,
    required this.viewport,
    required this.sheetFill,
    required this.sheetEdge,
    required this.marker,
    required this.frame,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // The sheet substrate — the whole box IS the sheet at [scale].
    final sheet =
        Rect.fromLTWH(0, 0, contentSize.width * scale, contentSize.height * scale);
    canvas.drawRect(sheet, Paint()..color = sheetFill);
    canvas.drawRect(
      sheet,
      Paint()
        ..color = sheetEdge
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    // Drawn-content landmarks.
    final dot = Paint()..color = marker;
    for (final m in markers) {
      canvas.drawCircle(Offset(m.dx * scale, m.dy * scale), 1.6, dot);
    }
    // The live viewport rectangle — the world region currently on screen,
    // mapped through the SAME uniform scale (clipped to the box by the ClipRRect
    // when the view is panned past a sheet edge).
    final vp = viewport;
    if (vp != null && !vp.size.isEmpty) {
      final tl = vp.transform.screenToWorld(Offset.zero) * scale;
      final br =
          vp.transform.screenToWorld(vp.size.bottomRight(Offset.zero)) * scale;
      canvas.drawRect(
        Rect.fromPoints(tl, br),
        Paint()
          ..color = frame
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
    }
  }

  @override
  bool shouldRepaint(_MinimapPainter old) =>
      old.contentSize != contentSize ||
      old.scale != scale ||
      old.markers != markers ||
      old.viewport != viewport ||
      old.marker != marker ||
      old.frame != frame ||
      old.sheetFill != sheetFill ||
      old.sheetEdge != sheetEdge;
}
