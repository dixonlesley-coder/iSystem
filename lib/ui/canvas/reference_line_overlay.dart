import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/app_state.dart' show statusMessageProvider;
import '../../store/network_store.dart' show orthoProvider;
import '../../store/reference_line_store.dart';
import '../../store/sheets_store.dart';
import '../strings/app_strings.dart';
import 'armed_delete.dart';
import 'snapping.dart';
import 'underlay_snap_service.dart';
import 'viewport.dart';

/// The B12 **Ref line** trace tool for one sheet. Always renders the saved
/// reference lines (thin dashed construction lines, distinct from the amber
/// dimension look); when [active] it captures two clicks to trace a new line and
/// a secondary-click to delete the nearest one. Mirrors [MeasurementOverlay]
/// end-to-end — the same two-click / secondary-delete idiom — except the
/// artefact is a snappable construction line, not a dimension.
///
/// Each click is itself snapped: ortho (against the first point) + the plan
/// underlay (so a traced line lands on the architecture it references). When
/// inactive the overlay is pointer-transparent so taps reach the layers beneath.
class ReferenceLineOverlay extends ConsumerStatefulWidget {
  final String sheetId;
  final bool active;

  const ReferenceLineOverlay({
    super.key,
    required this.sheetId,
    required this.active,
  });

  @override
  ConsumerState<ReferenceLineOverlay> createState() =>
      _ReferenceLineOverlayState();
}

class _ReferenceLineOverlayState extends ConsumerState<ReferenceLineOverlay> {
  Offset? _pending; // first placed point (world)
  Offset? _hover; // cursor (world)

  /// C4 — the two-click, pointer-UP secondary delete.
  final _armed = ArmedSecondaryDelete();

  @override
  void didUpdateWidget(ReferenceLineOverlay old) {
    super.didUpdateWidget(old);
    // Abandon a half-placed line when the tool is switched off.
    if (!widget.active) {
      _pending = null;
      _armed.disarm();
    }
  }

  ViewportTransform get _transform =>
      ref.read(sheetsControllerProvider).viewportFor(widget.sheetId) ??
      const ViewportTransform();

  /// Snap a candidate world point: ortho against [_pending] (when Ortho is on),
  /// then the plan underlay (DXF wall / other reference lines / PDF ink).
  Offset _snapPoint(Offset world, ViewportTransform t) {
    var p = world;
    final ortho = ref.read(orthoProvider) ^ HardwareKeyboard.instance.isShiftPressed;
    if (ortho && _pending != null) p = orthoSnap(_pending!, p);
    final u = underlaySnapFor(ref, widget.sheetId, t.scale,
            orthoAnchor: (ortho && _pending != null) ? _pending : null)
        ?.call(p);
    return u ?? p;
  }

  void _onTapUp(TapUpDetails d) {
    final t = _transform;
    final world = _snapPoint(t.screenToWorld(d.localPosition), t);
    if (_pending == null) {
      setState(() => _pending = world);
      return;
    }
    ref.read(referenceLinesProvider.notifier).add(
          sheetId: widget.sheetId,
          x1: _pending!.dx,
          y1: _pending!.dy,
          x2: world.dx,
          y2: world.dy,
        );
    setState(() => _pending = null);
  }

  /// The nearest reference-line endpoint/midpoint within a screen-space
  /// threshold (so a stray right-click hits nothing) — the delete candidate.
  String? _deleteCandidate(Offset localPos) {
    final t = _transform;
    final mine =
        ref.read(referenceLinesProvider).where((r) => r.sheetId == widget.sheetId);
    String? best;
    var bestD = double.infinity;
    for (final r in mine) {
      final mid = Offset((r.x1 + r.x2) / 2, (r.y1 + r.y2) / 2);
      for (final p in [Offset(r.x1, r.y1), Offset(r.x2, r.y2), mid]) {
        final dist = (t.worldToScreen(p) - localPos).distance;
        if (dist < bestD) {
          bestD = dist;
          best = r.id;
        }
      }
    }
    return (best != null && bestD <= 14) ? best : null;
  }

  /// C4 — the delete completes on pointer-UP after a confirming second click
  /// (see [ArmedSecondaryDelete]), with a status pill naming what went. The
  /// removal itself is unchanged — one undoable step.
  void _onSecondaryUp(PointerUpEvent e) {
    final outcome = _armed.pointerUp(e, _deleteCandidate(e.localPosition));
    final id = outcome.id;
    if (id == null) return;
    final strings = MechXStrings.of(context);
    final what = strings(StringKey.annotationReferenceLine);
    final status = ref.read(statusMessageProvider.notifier);
    switch (outcome.action) {
      case ArmedDeleteAction.none:
        return;
      case ArmedDeleteAction.armed:
        status.showStatus(strings
            .format(StringKey.annotationDeleteArmTemplate, {'what': what}));
      case ArmedDeleteAction.deleted:
        ref.read(referenceLinesProvider.notifier).removeById(id);
        status.showStatus(
            strings.format(StringKey.annotationDeletedTemplate, {'what': what}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final transform =
        ref.watch(sheetsControllerProvider).viewportFor(widget.sheetId) ??
            const ViewportTransform();
    final all = ref.watch(referenceLinesProvider);
    final mine = [for (final r in all) if (r.sheetId == widget.sheetId) r];

    final painter = _ReferenceLinePainter(
      lines: mine,
      transform: transform,
      pending: widget.active ? _pending : null,
      hover: widget.active ? _hover : null,
    );

    if (!widget.active) {
      return IgnorePointer(
        child: CustomPaint(size: Size.infinite, painter: painter),
      );
    }

    return MouseRegion(
      cursor: SystemMouseCursors.precise,
      onHover: (e) {
        final t = _transform;
        setState(() => _hover = _snapPoint(t.screenToWorld(e.localPosition), t));
      },
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

class _ReferenceLinePainter extends CustomPainter {
  final List<ReferenceLine> lines;
  final ViewportTransform transform;
  final Offset? pending;
  final Offset? hover;

  _ReferenceLinePainter({
    required this.lines,
    required this.transform,
    required this.pending,
    required this.hover,
  });

  // A cool grey-blue, distinct from the amber Measure dimension + service inks.
  static const Color _color = Color(0xFF6B8CAE);

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    final delta = b - a;
    final len = delta.distance;
    if (len < 0.5) return;
    final dir = delta / len;
    const dash = 8.0, gap = 5.0;
    var d = 0.0;
    while (d < len) {
      final s = a + dir * d;
      final e = a + dir * (d + dash).clamp(0.0, len);
      canvas.drawLine(s, e, paint);
      d += dash + gap;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = _color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final dot = Paint()..color = _color;
    for (final r in lines) {
      final a = transform.worldToScreen(Offset(r.x1, r.y1));
      final b = transform.worldToScreen(Offset(r.x2, r.y2));
      _dashed(canvas, a, b, line);
      canvas.drawCircle(a, 2.5, dot);
      canvas.drawCircle(b, 2.5, dot);
    }
    // Live placement preview.
    if (pending != null) {
      final ps = transform.worldToScreen(pending!);
      canvas.drawCircle(ps, 3.5, dot);
      if (hover != null) {
        _dashed(canvas, ps, transform.worldToScreen(hover!), line);
      }
    }
  }

  @override
  bool shouldRepaint(_ReferenceLinePainter old) =>
      old.lines != lines ||
      old.transform != transform ||
      old.pending != pending ||
      old.hover != hover;
}
