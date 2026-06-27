import 'package:flutter/widgets.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton, PointerDownEvent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/sizing/room_air.dart';

import '../../store/annotation_store.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import 'viewport.dart';

/// Room/zone layer for one sheet/floor. Always renders the saved room footprints
/// (a filled rectangle + an airflow label from the sheet's calibration: area ×
/// ceiling × ACH → CFM); when [active] (the room tool is on) it captures a DRAG
/// to draw a new footprint and deletes a room on secondary-click. Inactive ⇒
/// pointer-transparent, so taps reach the selection overlay.
class RoomOverlay extends ConsumerStatefulWidget {
  final String sheetId;
  final int floorIndex;
  final bool active;

  const RoomOverlay({
    super.key,
    required this.sheetId,
    required this.floorIndex,
    required this.active,
  });

  @override
  ConsumerState<RoomOverlay> createState() => _RoomOverlayState();
}

class _RoomOverlayState extends ConsumerState<RoomOverlay> {
  Offset? _dragStart; // world
  Offset? _dragNow; // world

  @override
  void didUpdateWidget(RoomOverlay old) {
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
    final mine = ref.read(roomAreasProvider).where((a) =>
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
      ref.read(roomAreasProvider.notifier).removeById(best);
    }
  }

  @override
  Widget build(BuildContext context) {
    final transform =
        ref.watch(sheetsControllerProvider).viewportFor(widget.sheetId) ??
            const ViewportTransform();
    final all = ref.watch(roomAreasProvider);
    final mine = [
      for (final a in all)
        if (a.sheetId == widget.sheetId && a.floorIndex == widget.floorIndex) a,
    ];
    final calibration =
        ref.watch(projectControllerProvider).calibrationFor(widget.sheetId);

    final painter = _RoomPainter(
      rooms: mine,
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
              ref.read(roomAreasProvider.notifier).add(
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

class _RoomPainter extends CustomPainter {
  final List<RoomArea> rooms;
  final ViewportTransform transform;
  final ScaleCalibration? calibration;
  final Offset? dragStart;
  final Offset? dragNow;

  static const Color _color = Color(0xFF1FA88B); // teal — distinct from tank/measure

  _RoomPainter({
    required this.rooms,
    required this.transform,
    required this.calibration,
    required this.dragStart,
    required this.dragNow,
  });

  String _airflowLabel(RoomArea r) {
    final cal = calibration;
    if (cal == null) return 'set scale';
    final s = r.sizing(cal.metersPerPixel);
    if (s == null) return r.name;
    final cfm = s.airflowCfm.round();
    final lps = s.airflow.inLitersPerSecond.round();
    return '${r.name} · $cfm CFM ($lps L/s) · ${airEquipmentLabel(r.equipmentKind)}';
  }

  void _drawRect(Canvas canvas, Offset aw, Offset bw, {String? label}) {
    final a = transform.worldToScreen(aw);
    final b = transform.worldToScreen(bw);
    final rect = Rect.fromPoints(a, b);
    canvas.drawRect(rect, Paint()..color = _color.withAlpha(30));
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
          color: Color(0xFF053A30),
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
      Paint()..color = const Color(0xFFBDEDE1),
    );
    tp.paint(canvas, Offset(chip.left + 5, chip.top + 3));
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final r in rooms) {
      _drawRect(canvas, Offset(r.ax, r.ay), Offset(r.bx, r.by),
          label: _airflowLabel(r));
    }
    if (dragStart != null && dragNow != null) {
      _drawRect(canvas, dragStart!, dragNow!);
    }
  }

  @override
  bool shouldRepaint(_RoomPainter old) =>
      old.rooms != rooms ||
      old.transform != transform ||
      old.calibration != calibration ||
      old.dragStart != dragStart ||
      old.dragNow != dragNow;
}
