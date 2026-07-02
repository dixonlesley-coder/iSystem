import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';

import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import '../../store/smart_input_store.dart';
import 'service_style.dart';
import 'snapping.dart';
import 'viewport.dart';

/// Interaction layer active while a draw tool is selected. Maps taps to
/// sheet/world coordinates (via the live viewport), places run points / risers,
/// and shows a rubber-band preview from the pending point to the cursor with
/// the LIVE calibrated run length (the primary gesture gets the same feedback
/// immediacy the Measure tool already has) and a snap ring over the node the
/// next click would land on (mirrors the palette drop preview). A
/// secondary-click finishes the run (first click ends the pending chain, a
/// second returns to Select) — the CAD right-click-to-finish convention.
class DrawingOverlay extends ConsumerStatefulWidget {
  final String sheetId;
  final int floorIndex;
  final int levelCount;

  const DrawingOverlay({
    super.key,
    required this.sheetId,
    required this.floorIndex,
    required this.levelCount,
  });

  @override
  ConsumerState<DrawingOverlay> createState() => _DrawingOverlayState();
}

class _DrawingOverlayState extends ConsumerState<DrawingOverlay> {
  Offset? _hoverWorld;

  /// The nearest node (same sheet/floor) within the snap radius of [worldP], or
  /// null — mirrors the store's `_snap` so the ring marks the genuine target.
  NetNode? _snapTarget(Offset worldP, double snapWorld) {
    final nodes = ref.read(networkControllerProvider).network.nodes;
    NetNode? best;
    var bestD2 = snapWorld * snapWorld;
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

  @override
  Widget build(BuildContext context) {
    final drawing = ref.watch(networkControllerProvider);
    final notifier = ref.read(networkControllerProvider.notifier);
    final ortho = ref.watch(orthoProvider);
    final transform = ref.watch(sheetsControllerProvider).viewportFor(widget.sheetId) ??
        const ViewportTransform();
    final calibration =
        ref.watch(projectControllerProvider).calibrationFor(widget.sheetId);
    final snapWorld = 12 / transform.scale; // keep snap ≈12 screen px

    // Ortho-snapped cursor for the rubber-band preview.
    final pending = drawing.pendingPoint;
    final previewHover = (ortho && pending != null && _hoverWorld != null)
        ? orthoSnap(pending, _hoverWorld!)
        : _hoverWorld;
    // Where the NEXT click would snap — the ortho-adjusted cursor is what
    // placeRunPoint/placeRiser receive, so search from it.
    final snapNode = previewHover != null
        ? _snapTarget(previewHover, snapWorld)
        : null;

    return MouseRegion(
      cursor: SystemMouseCursors.precise,
      onHover: (e) {
        final world = transform.screenToWorld(e.localPosition);
        // Publish the live cursor so the smart input bar can place a
        // length-only entry along the current pointing direction.
        ref.read(drawHoverProvider.notifier).set(world);
        setState(() => _hoverWorld = world);
      },
      onExit: (_) => ref.read(drawHoverProvider.notifier).set(null),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) {
          var world = transform.screenToWorld(details.localPosition);
          switch (drawing.tool) {
            case DrawTool.drawRun:
              if (ortho && pending != null) world = orthoSnap(pending, world);
              notifier.placeRunPoint(
                widget.sheetId,
                widget.floorIndex,
                world,
                snapRadius: snapWorld,
              );
            case DrawTool.drawRiser:
              notifier.placeRiser(
                widget.sheetId,
                widget.floorIndex,
                world,
                widget.levelCount,
                snapRadius: snapWorld,
              );
            case DrawTool.select:
              break;
          }
        },
        onSecondaryTapUp: (_) {
          // Right-click finishes: end the pending run first, then a second
          // right-click steps back to Select.
          if (drawing.pendingPoint != null) {
            notifier.cancelPending();
          } else {
            notifier.setTool(DrawTool.select);
          }
        },
        child: CustomPaint(
          size: Size.infinite,
          painter: _RubberBandPainter(
            pending: drawing.pendingPoint,
            hover: previewHover,
            snapScreen: snapNode != null
                ? transform.worldToScreen(Offset(snapNode.x, snapNode.y))
                : null,
            transform: transform,
            calibration: calibration,
            color: serviceColor(drawing.service),
            active: drawing.tool == DrawTool.drawRun,
          ),
        ),
      ),
    );
  }
}

class _RubberBandPainter extends CustomPainter {
  final Offset? pending;
  final Offset? hover;
  final Offset? snapScreen;
  final ViewportTransform transform;
  final ScaleCalibration? calibration;
  final Color color;
  final bool active;

  _RubberBandPainter({
    required this.pending,
    required this.hover,
    required this.snapScreen,
    required this.transform,
    required this.calibration,
    required this.color,
    required this.active,
  });

  /// The live run length: calibrated metres, or an honest 'set scale' nudge
  /// (the same wording the Measure tool uses when the sheet is uncalibrated).
  String _label(double pixelLength) {
    final cal = calibration;
    if (cal == null) return 'set scale';
    final m = cal.lengthForPixels(pixelLength).meters;
    return m >= 10 ? '${m.toStringAsFixed(1)} m' : '${m.toStringAsFixed(2)} m';
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Snap ring + crosshair over the node the next click lands on — shown for
    // run AND riser placement (both snap), mirroring the drop preview.
    final snap = snapScreen;
    if (snap != null) {
      final ring = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawCircle(snap, 12, ring);
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

    if (!active || pending == null) return;
    final a = transform.worldToScreen(pending!);
    canvas.drawCircle(a, 3.5, Paint()..color = color);
    if (hover != null) {
      final b = transform.worldToScreen(hover!);
      canvas.drawLine(
        a,
        b,
        Paint()
          ..color = color.withAlpha(150)
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke,
      );

      // Live length chip at the segment midpoint (the Measure tool's idiom,
      // in the service colour so it reads as part of the run being drawn).
      final dx = hover!.dx - pending!.dx;
      final dy = hover!.dy - pending!.dy;
      final tp = TextPainter(
        text: TextSpan(
          text: _label(math.sqrt(dx * dx + dy * dy)),
          style: const TextStyle(
            color: Color(0xFFFFFFFF),
            fontSize: 11,
            fontFamily: 'Roboto',
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
      final rect = Rect.fromCenter(
        center: mid.translate(0, -14),
        width: tp.width + 10,
        height: tp.height + 6,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        Paint()..color = color,
      );
      tp.paint(canvas, Offset(rect.left + 5, rect.top + 3));
    }
  }

  @override
  bool shouldRepaint(_RubberBandPainter old) =>
      old.pending != pending ||
      old.hover != hover ||
      old.snapScreen != snapScreen ||
      old.transform != transform ||
      old.calibration != calibration ||
      old.color != color ||
      old.active != active;
}
