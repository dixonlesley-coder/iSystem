import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/network_store.dart';
import '../../store/sheets_store.dart';
import 'service_style.dart';
import 'snapping.dart';
import 'viewport.dart';

/// Interaction layer active while a draw tool is selected. Maps taps to
/// sheet/world coordinates (via the live viewport), places run points / risers,
/// and shows a rubber-band preview from the pending point to the cursor.
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

  @override
  Widget build(BuildContext context) {
    final drawing = ref.watch(networkControllerProvider);
    final notifier = ref.read(networkControllerProvider.notifier);
    final ortho = ref.watch(orthoProvider);
    final transform = ref.watch(sheetsControllerProvider).viewportFor(widget.sheetId) ??
        const ViewportTransform();
    final snapWorld = 12 / transform.scale; // keep snap ≈12 screen px

    // Ortho-snapped cursor for the rubber-band preview.
    final pending = drawing.pendingPoint;
    final previewHover = (ortho && pending != null && _hoverWorld != null)
        ? orthoSnap(pending, _hoverWorld!)
        : _hoverWorld;

    return MouseRegion(
      cursor: SystemMouseCursors.precise,
      onHover: (e) =>
          setState(() => _hoverWorld = transform.screenToWorld(e.localPosition)),
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
        child: CustomPaint(
          size: Size.infinite,
          painter: _RubberBandPainter(
            pending: drawing.pendingPoint,
            hover: previewHover,
            transform: transform,
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
  final ViewportTransform transform;
  final Color color;
  final bool active;

  _RubberBandPainter({
    required this.pending,
    required this.hover,
    required this.transform,
    required this.color,
    required this.active,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (!active || pending == null) return;
    final a = transform.worldToScreen(pending!);
    canvas.drawCircle(a, 3.5, Paint()..color = color);
    if (hover != null) {
      canvas.drawLine(
        a,
        transform.worldToScreen(hover!),
        Paint()
          ..color = color.withAlpha(150)
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_RubberBandPainter old) =>
      old.pending != pending ||
      old.hover != hover ||
      old.transform != transform ||
      old.color != color ||
      old.active != active;
}
