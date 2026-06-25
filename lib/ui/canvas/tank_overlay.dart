import 'package:flutter/widgets.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton, PointerDownEvent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';

import '../../store/annotation_store.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import 'viewport.dart';

/// Tank-area layer for one sheet/floor. Always renders the saved tank footprints
/// (a filled rectangle + a capacity label from the sheet's calibration × depth);
/// when [active] (the tank tool is on) it captures a DRAG to draw a new footprint
/// and deletes a tank on secondary-click. Inactive ⇒ pointer-transparent, so
/// taps reach the selection overlay.
class TankOverlay extends ConsumerStatefulWidget {
  final String sheetId;
  final int floorIndex;
  final bool active;

  const TankOverlay({
    super.key,
    required this.sheetId,
    required this.floorIndex,
    required this.active,
  });

  @override
  ConsumerState<TankOverlay> createState() => _TankOverlayState();
}

class _TankOverlayState extends ConsumerState<TankOverlay> {
  Offset? _dragStart; // world
  Offset? _dragNow; // world

  @override
  void didUpdateWidget(TankOverlay old) {
    super.didUpdateWidget(old);
    if (!widget.active) {
      _dragStart = null;
      _dragNow = null;
    }
  }

  ViewportTransform get _transform =>
      ref.read(sheetsControllerProvider).viewportFor(widget.sheetId) ??
      const ViewportTransform();

  void _onSecondary(Offset localPos) {
    final t = _transform;
    final mine = ref.read(tankAreasProvider).where((a) =>
        a.sheetId == widget.sheetId && a.floorIndex == widget.floorIndex);
    String? best;
    var bestD = double.infinity;
    for (final a in mine) {
      final c = Offset((a.ax + a.bx) / 2, (a.ay + a.by) / 2);
      final d = (t.worldToScreen(c) - localPos).distance;
      if (d < bestD) {
        bestD = d;
        best = a.id;
      }
    }
    if (best != null && bestD <= 40) {
      ref.read(tankAreasProvider.notifier).removeById(best);
    }
  }

  @override
  Widget build(BuildContext context) {
    final transform =
        ref.watch(sheetsControllerProvider).viewportFor(widget.sheetId) ??
            const ViewportTransform();
    final all = ref.watch(tankAreasProvider);
    final mine = [
      for (final a in all)
        if (a.sheetId == widget.sheetId && a.floorIndex == widget.floorIndex) a,
    ];
    final calibration =
        ref.watch(projectControllerProvider).calibrationFor(widget.sheetId);

    final painter = _TankPainter(
      tanks: mine,
      transform: transform,
      calibration: calibration,
      dragStart: widget.active ? _dragStart : null,
      dragNow: widget.active ? _dragNow : null,
    );

    if (!widget.active) {
      return IgnorePointer(
        child: CustomPaint(size: Size.infinite, painter: painter),
      );
    }

    return MouseRegion(
      cursor: SystemMouseCursors.precise,
      child: Listener(
        onPointerDown: (PointerDownEvent e) {
          if (e.buttons == kSecondaryButton) _onSecondary(e.localPosition);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => setState(() {
            _dragStart = transform.screenToWorld(d.localPosition);
            _dragNow = _dragStart;
          }),
          onPanUpdate: (d) => setState(
              () => _dragNow = transform.screenToWorld(d.localPosition)),
          onPanEnd: (_) {
            final a = _dragStart, b = _dragNow;
            if (a != null && b != null) {
              ref.read(tankAreasProvider.notifier).add(
                    sheetId: widget.sheetId,
                    floorIndex: widget.floorIndex,
                    ax: a.dx,
                    ay: a.dy,
                    bx: b.dx,
                    by: b.dy,
                  );
            }
            setState(() {
              _dragStart = null;
              _dragNow = null;
            });
          },
          child: CustomPaint(size: Size.infinite, painter: painter),
        ),
      ),
    );
  }
}

class _TankPainter extends CustomPainter {
  final List<TankArea> tanks;
  final ViewportTransform transform;
  final ScaleCalibration? calibration;
  final Offset? dragStart;
  final Offset? dragNow;

  static const Color _color = Color(0xFF3AA0E5); // water blue

  _TankPainter({
    required this.tanks,
    required this.transform,
    required this.calibration,
    required this.dragStart,
    required this.dragNow,
  });

  String _capacityLabel(TankArea t) {
    final cal = calibration;
    if (cal == null) return 'set scale';
    final m3 = t.volumeM3(cal.metersPerPixel);
    final l = m3 * 1000;
    final cap = l >= 10000
        ? '${m3.toStringAsFixed(1)} m3'
        : '${l.round()} L';
    return '${t.name} · $cap · ${t.material.label}';
  }

  void _drawRect(Canvas canvas, Offset aw, Offset bw, {String? label}) {
    final a = transform.worldToScreen(aw);
    final b = transform.worldToScreen(bw);
    final rect = Rect.fromPoints(a, b);
    canvas.drawRect(rect, Paint()..color = _color.withAlpha(34));
    canvas.drawRect(
      rect,
      Paint()
        ..color = _color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
    if (label == null) return;
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: Color(0xFF0A2A40),
          fontSize: 11,
          fontFamily: 'Roboto',
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final chip = Rect.fromLTWH(
        rect.left + 3, rect.top + 3, tp.width + 10, tp.height + 6);
    canvas.drawRRect(
      RRect.fromRectAndRadius(chip, const Radius.circular(4)),
      Paint()..color = const Color(0xFFBFE3FA),
    );
    tp.paint(canvas, Offset(chip.left + 5, chip.top + 3));
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final t in tanks) {
      _drawRect(canvas, Offset(t.ax, t.ay), Offset(t.bx, t.by),
          label: _capacityLabel(t));
    }
    if (dragStart != null && dragNow != null) {
      _drawRect(canvas, dragStart!, dragNow!);
    }
  }

  @override
  bool shouldRepaint(_TankPainter old) =>
      old.tanks != tanks ||
      old.transform != transform ||
      old.calibration != calibration ||
      old.dragStart != dragStart ||
      old.dragNow != dragNow;
}
