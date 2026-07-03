import 'package:flutter/widgets.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton, PointerDownEvent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';

import '../../store/annotation_store.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import 'viewport.dart';

/// What a live pointer drag on the tank overlay is doing (E6): drawing a NEW
/// footprint, MOVEing an existing one, or RESIZEing a corner.
enum _TankDrag { draw, move, resize }

/// Tank-area layer for one sheet/floor. Always renders the saved tank footprints
/// (a filled rectangle + a capacity label from the sheet's calibration × depth);
/// when [active] (the tank tool is on) it is a FIRST-CLASS editing surface (E6):
/// tap a tank to select it (framed in the inspector), drag its interior to move
/// it, drag a corner handle to resize — each a single annotation undo step — and
/// drag empty canvas to draw a new footprint; secondary-click deletes the
/// nearest. Inactive ⇒ pointer-transparent, so taps reach the selection overlay.
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
  // Draw-new state (world pixels).
  Offset? _dragStart;
  Offset? _dragNow;

  // Move/resize state.
  _TankDrag _mode = _TankDrag.draw;
  String? _targetId;
  Offset _grab = Offset.zero;
  double _origAx = 0, _origAy = 0, _origBx = 0, _origBy = 0;
  bool _cornerUsesAx = false, _cornerUsesAy = false;
  bool _snapped = false; // whether the one-per-drag undo snapshot was taken

  /// Handle hit radius in SCREEN pixels (a resize grip near a corner).
  static const double _handleHitPx = 11;

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

  List<TankArea> get _mine => [
        for (final a in ref.read(tankAreasProvider))
          if (a.sheetId == widget.sheetId && a.floorIndex == widget.floorIndex)
            a,
      ];

  void _onSecondary(Offset localPos) {
    final t = _transform;
    String? best;
    var bestD = double.infinity;
    for (final a in _mine) {
      final c = Offset((a.ax + a.bx) / 2, (a.ay + a.by) / 2);
      final d = (t.worldToScreen(c) - localPos).distance;
      if (d < bestD) {
        bestD = d;
        best = a.id;
      }
    }
    if (best != null && bestD <= 40) {
      ref.read(tankAreasProvider.notifier).removeById(best);
      ref.read(selectedAnnotationProvider.notifier).clear(best);
    }
  }

  /// The tank currently selected on the canvas (this sheet/floor), or null.
  TankArea? _selected() {
    final sel = ref.read(selectedAnnotationProvider);
    if (sel == null || sel.kind != AnnotationKind.tank) return null;
    for (final t in _mine) {
      if (t.id == sel.id) return t;
    }
    return null;
  }

  /// Which resize corner of [t] (if any) the SCREEN point [screen] grabs.
  ({bool usesAx, bool usesAy})? _cornerAt(TankArea t, Offset screen) {
    final tf = _transform;
    final corners = <({bool usesAx, bool usesAy, Offset world})>[
      (usesAx: true, usesAy: true, world: Offset(t.ax, t.ay)),
      (usesAx: false, usesAy: true, world: Offset(t.bx, t.ay)),
      (usesAx: true, usesAy: false, world: Offset(t.ax, t.by)),
      (usesAx: false, usesAy: false, world: Offset(t.bx, t.by)),
    ];
    for (final c in corners) {
      if ((tf.worldToScreen(c.world) - screen).distance <= _handleHitPx) {
        return (usesAx: c.usesAx, usesAy: c.usesAy);
      }
    }
    return null;
  }

  void _onPanStart(Offset localPos) {
    final t = _transform;
    final w = t.screenToWorld(localPos);
    _snapped = false;

    // 1) A resize handle of the currently-selected tank takes priority.
    final sel = _selected();
    if (sel != null) {
      final corner = _cornerAt(sel, localPos);
      if (corner != null) {
        _mode = _TankDrag.resize;
        _targetId = sel.id;
        _cornerUsesAx = corner.usesAx;
        _cornerUsesAy = corner.usesAy;
        _origAx = sel.ax;
        _origAy = sel.ay;
        _origBx = sel.bx;
        _origBy = sel.by;
        return;
      }
    }

    // 2) The interior of any tank (topmost wins) → move + select it.
    for (final a in _mine.reversed) {
      if (a.containsPoint(widget.sheetId, widget.floorIndex, w.dx, w.dy)) {
        _mode = _TankDrag.move;
        _targetId = a.id;
        _grab = w;
        _origAx = a.ax;
        _origAy = a.ay;
        _origBx = a.bx;
        _origBy = a.by;
        ref.read(selectedAnnotationProvider.notifier).selectTank(a.id);
        return;
      }
    }

    // 3) Empty canvas → draw a new footprint.
    _mode = _TankDrag.draw;
    _targetId = null;
    setState(() {
      _dragStart = w;
      _dragNow = w;
    });
  }

  void _onPanUpdate(Offset localPos) {
    final w = _transform.screenToWorld(localPos);
    final ctrl = ref.read(tankAreasProvider.notifier);
    switch (_mode) {
      case _TankDrag.draw:
        setState(() => _dragNow = w);
      case _TankDrag.move:
        final id = _targetId;
        if (id == null) return;
        if (!_snapped) {
          ctrl.beginGeometryEdit();
          _snapped = true;
        }
        final dx = w.dx - _grab.dx;
        final dy = w.dy - _grab.dy;
        ctrl.setBounds(
            id, _origAx + dx, _origAy + dy, _origBx + dx, _origBy + dy);
      case _TankDrag.resize:
        final id = _targetId;
        if (id == null) return;
        if (!_snapped) {
          ctrl.beginGeometryEdit();
          _snapped = true;
        }
        final ax = _cornerUsesAx ? w.dx : _origAx;
        final bx = _cornerUsesAx ? _origBx : w.dx;
        final ay = _cornerUsesAy ? w.dy : _origAy;
        final by = _cornerUsesAy ? _origBy : w.dy;
        ctrl.setBounds(id, ax, ay, bx, by);
    }
  }

  void _onPanEnd() {
    if (_mode == _TankDrag.draw) {
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
    }
    setState(() {
      _dragStart = null;
      _dragNow = null;
    });
    _mode = _TankDrag.draw;
    _targetId = null;
  }

  void _onTapUp(Offset localPos) {
    final w = _transform.screenToWorld(localPos);
    for (final a in _mine.reversed) {
      if (a.containsPoint(widget.sheetId, widget.floorIndex, w.dx, w.dy)) {
        ref.read(selectedAnnotationProvider.notifier).selectTank(a.id);
        return;
      }
    }
    ref.read(selectedAnnotationProvider.notifier).clear();
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
    final sel = ref.watch(selectedAnnotationProvider);
    final selectedId =
        (sel != null && sel.kind == AnnotationKind.tank) ? sel.id : null;

    final painter = _TankPainter(
      tanks: mine,
      transform: transform,
      calibration: calibration,
      dragStart: widget.active ? _dragStart : null,
      dragNow: widget.active ? _dragNow : null,
      selectedId: widget.active ? selectedId : null,
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
          onTapUp: (d) => _onTapUp(d.localPosition),
          onPanStart: (d) => _onPanStart(d.localPosition),
          onPanUpdate: (d) => _onPanUpdate(d.localPosition),
          onPanEnd: (_) => _onPanEnd(),
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
  final String? selectedId;

  static const Color _color = Color(0xFF3AA0E5); // water blue

  _TankPainter({
    required this.tanks,
    required this.transform,
    required this.calibration,
    required this.dragStart,
    required this.dragNow,
    required this.selectedId,
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

  void _drawRect(Canvas canvas, Offset aw, Offset bw,
      {String? label, bool selected = false}) {
    final a = transform.worldToScreen(aw);
    final b = transform.worldToScreen(bw);
    final rect = Rect.fromPoints(a, b);
    canvas.drawRect(rect, Paint()..color = _color.withAlpha(selected ? 52 : 34));
    canvas.drawRect(
      rect,
      Paint()
        ..color = _color
        ..strokeWidth = selected ? 2.5 : 1.5
        ..style = PaintingStyle.stroke,
    );
    if (selected) {
      // Resize grips at the four corners (E6).
      final grip = Paint()..color = _color;
      final gripFill = Paint()..color = const Color(0xFFFFFFFF);
      for (final c in [
        rect.topLeft,
        rect.topRight,
        rect.bottomLeft,
        rect.bottomRight,
      ]) {
        final r = Rect.fromCenter(center: c, width: 8, height: 8);
        canvas.drawRect(r, gripFill);
        canvas.drawRect(
            r,
            grip
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5);
      }
    }
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
          label: _capacityLabel(t), selected: t.id == selectedId);
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
      old.dragNow != dragNow ||
      old.selectedId != selectedId;
}
