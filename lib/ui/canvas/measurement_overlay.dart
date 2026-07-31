import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';

import '../../store/annotation_store.dart';
import '../../store/app_state.dart' show statusMessageProvider;
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import '../strings/app_strings.dart';
import 'armed_delete.dart';
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

  /// C4 — the two-click, pointer-UP secondary delete.
  final _armed = ArmedSecondaryDelete();

  @override
  void didUpdateWidget(MeasurementOverlay old) {
    super.didUpdateWidget(old);
    // Abandon a half-placed dimension when the tool is switched off, so it
    // doesn't reappear on re-activation.
    if (!widget.active) {
      _pending = null;
      _armed.disarm();
    }
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

  /// The nearest measurement endpoint/midpoint within a screen-space threshold
  /// (so a stray right-click hits nothing) — the delete candidate.
  String? _deleteCandidate(Offset localPos) {
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
    return (best != null && bestD <= 14) ? best : null;
  }

  /// C4 — the delete completes on pointer-UP after a confirming second click
  /// (see [ArmedSecondaryDelete]), with a status pill naming what went. The
  /// removal itself is unchanged — one undoable annotation step.
  void _onSecondaryUp(PointerUpEvent e) {
    final outcome = _armed.pointerUp(e, _deleteCandidate(e.localPosition));
    final id = outcome.id;
    if (id == null) return;
    final strings = MechXStrings.of(context);
    final what = strings(StringKey.annotationDimension);
    final status = ref.read(statusMessageProvider.notifier);
    switch (outcome.action) {
      case ArmedDeleteAction.none:
        return;
      case ArmedDeleteAction.armed:
        status.showStatus(strings
            .format(StringKey.annotationDeleteArmTemplate, {'what': what}));
      case ArmedDeleteAction.deleted:
        ref.read(measurementsProvider.notifier).removeById(id);
        status.showStatus(
            strings.format(StringKey.annotationDeletedTemplate, {'what': what}));
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
        onPointerDown: _armed.pointerDown,
        onPointerUp: _onSecondaryUp,
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

  /// Perpendicular offset (screen px) of the dimension line from the picked
  /// points, and how far the thin extension lines run past it.
  static const double _dimOffset = 16;
  static const double _extBeyond = 5;

  void _drawDim(Canvas canvas, Offset aw, Offset bw, double pixelLength) {
    final a = transform.worldToScreen(aw);
    final b = transform.worldToScreen(bw);
    final line = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;

    final dir = b - a;
    final len = dir.distance;
    // Degenerate (first click before the cursor has moved): just a point.
    if (len <= 0.001) {
      canvas.drawCircle(a, 2.5, Paint()..color = color);
      return;
    }
    final u = dir / len;
    // Perpendicular, pinned to a CONSISTENT side (toward smaller screen y).
    var perp = Offset(-u.dy, u.dx);
    if (perp.dy > 0) perp = -perp;

    // The offset dimension line, clear of the object being measured.
    final da = a + perp * _dimOffset;
    final db = b + perp * _dimOffset;

    // Thin extension lines from each picked point to just past the dim line
    // (a small gap from the point, the CAD convention).
    final ext = Paint()
      ..color = color
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;
    canvas.drawLine(a + perp * 2, a + perp * (_dimOffset + _extBeyond), ext);
    canvas.drawLine(b + perp * 2, b + perp * (_dimOffset + _extBeyond), ext);

    // The dimension line itself + filled arrowheads at each end pointing
    // outward toward the extension lines.
    canvas.drawLine(da, db, line);
    _arrowHead(canvas, da, -u, perp);
    _arrowHead(canvas, db, u, perp);

    // Length text rotated along the line, sitting just ABOVE it on a smaller
    // translucent chip (no longer covering the dimension line).
    final tp = TextPainter(
      text: TextSpan(
        text: _label(pixelLength),
        style: TextStyle(
          color: textColor,
          fontSize: 10.5,
          fontFamily: 'Roboto',
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final boxW = tp.width + 6;
    final boxH = tp.height + 3;
    final midDim = (da + db) / 2;
    // Just above the dim line (further along perp) by half the chip height + a
    // hair, so the chip clears the line rather than sitting on it.
    final center = midDim + perp * (boxH / 2 + 2);
    var angle = math.atan2(u.dy, u.dx);
    if (angle > math.pi / 2 || angle < -math.pi / 2) angle += math.pi;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);
    final rect = Rect.fromCenter(center: Offset.zero, width: boxW, height: boxH);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()..color = labelBg.withAlpha(0xCC),
    );
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  /// A small filled arrowhead at [tip] pointing along unit direction [along],
  /// with [perp] the (unit) perpendicular that fixes its width.
  void _arrowHead(Canvas canvas, Offset tip, Offset along, Offset perp) {
    const l = 7.0; // length back from the tip
    const w = 2.6; // half-width
    final base = tip + along * l;
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(base.dx + perp.dx * w, base.dy + perp.dy * w)
      ..lineTo(base.dx - perp.dx * w, base.dy - perp.dy * w)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
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
