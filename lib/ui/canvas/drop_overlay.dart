import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

import '../../store/network_store.dart';
import '../../store/sheets_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'segment_palette.dart';
import 'segment_symbols.dart';
import 'viewport.dart';

/// ≈14 screen px snap radius — the same value the store's add-actions use, so
/// the preview ring highlights exactly the node a drop will attach to.
const double _kSnapScreenPx = 14;

/// A [DragTarget] spanning the canvas: a [PaletteItem] dropped here is mapped
/// from the local drop offset to sheet/world coordinates (via the live
/// [ViewportTransform]) and routed to the matching add-action on the network
/// store. Pointer-translucent so the canvas keeps panning/zooming when nothing
/// is being dragged. Mounted only while NOT calibrating and NOT drawing.
///
/// While a palette card hovers, it paints a faint GHOST of the node at the
/// cursor and a SNAP ring on the nearest fitting within the 14px snap radius;
/// when a snap is live the canvas tint strengthens to a "will-snap" state. This
/// preview paints ONLY during a drag — at rest the overlay is fully transparent
/// and pointer-ignored, so goldens are unchanged.
class DropOverlay extends ConsumerStatefulWidget {
  final String sheetId;
  final int floorIndex;

  const DropOverlay({
    super.key,
    required this.sheetId,
    required this.floorIndex,
  });

  @override
  ConsumerState<DropOverlay> createState() => _DropOverlayState();
}

class _DropOverlayState extends ConsumerState<DropOverlay> {
  /// The live drag position (LOCAL canvas px) and payload, set on enter/move and
  /// cleared on leave/accept. Transient — exists only during a drag gesture.
  Offset? _dragLocal;
  PaletteItem? _dragItem;

  Offset? _toLocal(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    return box?.globalToLocal(global);
  }

  ViewportTransform get _transform =>
      ref.read(sheetsControllerProvider).viewportFor(widget.sheetId) ??
      const ViewportTransform();

  /// The nearest node (same sheet/floor) within the snap radius of [worldP], or
  /// null — mirrors the store's `_snap` so the ring marks the genuine target.
  NetNode? _snapTarget(Offset worldP, double snapWorld) {
    final nodes = ref.read(networkControllerProvider).network.nodes;
    final r2 = snapWorld * snapWorld;
    NetNode? best;
    var bestD2 = r2;
    for (final n in nodes) {
      if (n.sheetId != widget.sheetId || n.floorIndex != widget.floorIndex) {
        continue;
      }
      final dx = n.x - worldP.dx;
      final dy = n.y - worldP.dy;
      final d2 = dx * dx + dy * dy;
      if (d2 <= bestD2) {
        bestD2 = d2;
        best = n;
      }
    }
    return best;
  }

  void _clearDrag() {
    if (_dragLocal != null || _dragItem != null) {
      setState(() {
        _dragLocal = null;
        _dragItem = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<PaletteItem>(
      hitTestBehavior: HitTestBehavior.translucent,
      onMove: (details) {
        final local = _toLocal(details.offset);
        if (local == null) return;
        setState(() {
          _dragLocal = local;
          _dragItem = details.data;
        });
      },
      onLeave: (_) => _clearDrag(),
      onAcceptWithDetails: (details) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final local = box.globalToLocal(details.offset);
        final transform = _transform;
        final world = transform.screenToWorld(local);
        final ctrl = ref.read(networkControllerProvider.notifier);
        final snapWorld = _kSnapScreenPx / transform.scale; // ≈14 screen px
        switch (details.data.kind) {
          case PaletteItemKind.pipeSegment:
          case PaletteItemKind.ductSegment:
            ctrl.addSegment(
              widget.sheetId,
              widget.floorIndex,
              world,
              service: details.data.service,
              snapRadius: snapWorld,
            );
          case PaletteItemKind.fitting:
            ctrl.addFitting(widget.sheetId, widget.floorIndex, world);
          case PaletteItemKind.terminal:
            ctrl.addTerminal(widget.sheetId, widget.floorIndex, world);
          case PaletteItemKind.component:
            final c = details.data.component;
            if (c != null) {
              ctrl.addComponentNode(widget.sheetId, widget.floorIndex, world, c);
            }
        }
        _clearDrag();
      },
      builder: (context, candidate, rejected) {
        final active = candidate.isNotEmpty;
        // Resolve the live snap target (in screen space) for the preview paint.
        final transform = _transform;
        final snapWorld = _kSnapScreenPx / transform.scale;
        NetNode? snap;
        if (active && _dragLocal != null) {
          final world = transform.screenToWorld(_dragLocal!);
          snap = _snapTarget(world, snapWorld);
        }
        final willSnap = snap != null;

        // Translucent fill while a card hovers, so the user sees the canvas is a
        // valid drop zone; cross-fades in/out (rather than popping) and is
        // pointer-ignored when idle so the canvas keeps panning/zooming. The
        // fill STRENGTHENS to a "will-snap" state when a fitting is in range.
        return IgnorePointer(
          ignoring: !active,
          child: Stack(
            children: [
              Positioned.fill(
                child: AnimatedOpacity(
                  opacity: active ? 1.0 : 0.0,
                  duration: MechXMotion.hover,
                  curve: MechXMotion.standard,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.colors.accent.withAlpha(willSnap ? 35 : 18),
                      border: Border.all(
                        color: context.colors.accent
                            .withAlpha(willSnap ? 170 : 120),
                        width: 1.5,
                      ),
                      borderRadius: MechXRadii.card,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              // The drag preview: a faint ghost node at the cursor + a snap ring
              // on the nearest fitting. Paints ONLY during a drag.
              if (active && _dragLocal != null && _dragItem != null)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _DropPreviewPainter(
                      item: _dragItem!,
                      cursorLocal: _dragLocal!,
                      snapScreen: snap == null
                          ? null
                          : transform.worldToScreen(Offset(snap.x, snap.y)),
                      color: context.colors.accent,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Paints the drag-place preview: a translucent ghost glyph of the dragged
/// palette item at the cursor, and (when snapping) a ring + crosshair over the
/// target fitting. Drag-only, so it never affects the at-rest canvas.
class _DropPreviewPainter extends CustomPainter {
  final PaletteItem item;
  final Offset cursorLocal;
  final Offset? snapScreen;
  final Color color;

  _DropPreviewPainter({
    required this.item,
    required this.cursorLocal,
    required this.snapScreen,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // ── Ghost glyph at the cursor (≈36px box, ~45% opacity) ──────────────────
    const box = 36.0;
    final ghostColor = color.withAlpha(115);
    canvas.save();
    canvas.translate(cursorLocal.dx - box / 2, cursorLocal.dy - box / 2);
    final c = item.component;
    if (c != null) {
      paintComponentSymbol(canvas, const Size(box, box), c, ghostColor,
          stroke: 2.0);
    } else {
      paintSegmentSymbol(canvas, const Size(box, box), item.kind, ghostColor,
          stroke: 2.0);
    }
    canvas.restore();

    // ── Snap indicator: a ring + crosshair over the target fitting ───────────
    final snap = snapScreen;
    if (snap != null) {
      final ring = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawCircle(snap, _kSnapScreenPx, ring);
      final cross = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      const arm = 5.0;
      canvas.drawLine(
          snap + const Offset(-arm, 0), snap + const Offset(arm, 0), cross);
      canvas.drawLine(
          snap + const Offset(0, -arm), snap + const Offset(0, arm), cross);
    }
  }

  @override
  bool shouldRepaint(_DropPreviewPainter old) =>
      old.item != item ||
      old.cursorLocal != cursorLocal ||
      old.snapScreen != snapScreen ||
      old.color != color;
}
