import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton, PointerDownEvent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';

import '../../store/annotation_store.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import 'viewport.dart';

/// Dimension-annotation layer for one sheet/floor. Always renders the saved
/// measurements (real-world length via the sheet's calibration); when [active]
/// (the measure tool is on) it also captures taps for two-click placement, shows
/// a live rubber-band length, and deletes a measurement on secondary-click. When
/// inactive it is pointer-transparent so taps reach the selection overlay.
class MeasurementOverlay extends ConsumerStatefulWidget {
  final String sheetId;
  final int floorIndex;
  final bool active;

  const MeasurementOverlay({
    super.key,
    required this.sheetId,
    required this.floorIndex,
    required this.active,
  });

  @override
  ConsumerState<MeasurementOverlay> createState() => _MeasurementOverlayState();
}

class _MeasurementOverlayState extends ConsumerState<MeasurementOverlay> {
  Offset? _pending; // first placed point (world)
  Offset? _hover; // cursor (world)

  @override
  void didUpdateWidget(MeasurementOverlay old) {
    super.didUpdateWidget(old);
    // Abandon a half-placed dimension when the tool is switched off, so it
    // doesn't reappear on re-activation.
    if (!widget.active) _pending = null;
  }

  ViewportTransform get _transform =>
      ref.read(sheetsControllerProvider).viewportFor(widget.sheetId) ??
      const ViewportTransform();

  void _onTapUp(TapUpDetails d) {
    final world = _transform.screenToWorld(d.localPosition);
    if (_pending == null) {
      setState(() => _pending = world);
      return;
    }
    ref.read(measurementsProvider.notifier).add(
          sheetId: widget.sheetId,
          floorIndex: widget.floorIndex,
          ax: _pending!.dx,
          ay: _pending!.dy,
          bx: world.dx,
          by: world.dy,
        );
    setState(() => _pending = null);
  }

  /// Secondary-click deletes the nearest measurement endpoint/midpoint within a
  /// screen-space threshold (so a stray right-click does nothing).
  void _onSecondary(Offset localPos) {
    final t = _transform;
    final mine = ref
        .read(measurementsProvider)
        .where((m) =>
            m.sheetId == widget.sheetId && m.floorIndex == widget.floorIndex);
    String? best;
    var bestD = double.infinity;
    for (final m in mine) {
      final mid = Offset((m.ax + m.bx) / 2, (m.ay + m.by) / 2);
      for (final p in [Offset(m.ax, m.ay), Offset(m.bx, m.by), mid]) {
        final d = (t.worldToScreen(p) - localPos).distance;
        if (d < bestD) {
          bestD = d;
          best = m.id;
        }
      }
    }
    if (best != null && bestD <= 14) {
      ref.read(measurementsProvider.notifier).removeById(best);
    }
  }

  @override
  Widget build(BuildContext context) {
    final transform = ref.watch(sheetsControllerProvider).viewportFor(widget.sheetId) ??
        const ViewportTransform();
    final all = ref.watch(measurementsProvider);
    final mine = [
      for (final m in all)
        if (m.sheetId == widget.sheetId && m.floorIndex == widget.floorIndex) m,
    ];
    final calibration =
        ref.watch(projectControllerProvider).calibrationFor(widget.sheetId);

    final painter = _MeasurementPainter(
      measurements: mine,
      transform: transform,
      calibration: calibration,
      pending: widget.active ? _pending : null,
      hover: widget.active ? _hover : null,
      color: const Color(0xFFE0A23B), // amber — distinct from service colours
      textColor: const Color(0xFF1A1A1A),
      labelBg: const Color(0xFFE0A23B),
    );

    if (!widget.active) {
      return IgnorePointer(
        child: CustomPaint(size: Size.infinite, painter: painter),
      );
    }

    return MouseRegion(
      cursor: SystemMouseCursors.precise,
      onHover: (e) =>
          setState(() => _hover = transform.screenToWorld(e.localPosition)),
      child: Listener(
        onPointerDown: (PointerDownEvent e) {
          if (e.buttons == kSecondaryButton) _onSecondary(e.localPosition);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: _onTapUp,
          child: CustomPaint(size: Size.infinite, painter: painter),
        ),
      ),
    );
  }
}

class _MeasurementPainter extends CustomPainter {
  final List<Measurement> measurements;
  final ViewportTransform transform;
  final ScaleCalibration? calibration;
  final Offset? pending;
  final Offset? hover;
  final Color color;
  final Color textColor;
  final Color labelBg;

  _MeasurementPainter({
    required this.measurements,
    required this.transform,
    required this.calibration,
    required this.pending,
    required this.hover,
    required this.color,
    required this.textColor,
    required this.labelBg,
  });

  String _label(double pixelLength) {
    final cal = calibration;
    if (cal == null) return 'set scale';
    final m = cal.lengthForPixels(pixelLength).meters;
    return m >= 10 ? '${m.toStringAsFixed(1)} m' : '${m.toStringAsFixed(2)} m';
  }

  void _drawDim(Canvas canvas, Offset aw, Offset bw, double pixelLength) {
    final a = transform.worldToScreen(aw);
    final b = transform.worldToScreen(bw);
    final line = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(a, b, line);
    // End ticks (perpendicular).
    final dir = (b - a);
    final len = dir.distance;
    if (len > 0.001) {
      final n = Offset(-dir.dy / len, dir.dx / len) * 5;
      canvas.drawLine(a - n, a + n, line);
      canvas.drawLine(b - n, b + n, line);
    }
    final dot = Paint()..color = color;
    canvas.drawCircle(a, 2.5, dot);
    canvas.drawCircle(b, 2.5, dot);

    // Length label at the midpoint, on a filled chip for legibility.
    final tp = TextPainter(
      text: TextSpan(
        text: _label(pixelLength),
        style: TextStyle(
          color: textColor,
          fontSize: 11,
          fontFamily: 'Roboto',
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
    final rect = Rect.fromCenter(
      center: mid,
      width: tp.width + 10,
      height: tp.height + 6,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      Paint()..color = labelBg,
    );
    tp.paint(canvas, Offset(rect.left + 5, rect.top + 3));
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final m in measurements) {
      _drawDim(canvas, Offset(m.ax, m.ay), Offset(m.bx, m.by), m.pixelLength);
    }
    // Live placement preview.
    if (pending != null) {
      final ps = transform.worldToScreen(pending!);
      canvas.drawCircle(ps, 3.5, Paint()..color = color);
      if (hover != null) {
        final dx = hover!.dx - pending!.dx;
        final dy = hover!.dy - pending!.dy;
        _drawDim(canvas, pending!, hover!, math.sqrt(dx * dx + dy * dy));
      }
    }
  }

  @override
  bool shouldRepaint(_MeasurementPainter old) =>
      old.measurements != measurements ||
      old.transform != transform ||
      old.calibration != calibration ||
      old.pending != pending ||
      old.hover != hover;
}
