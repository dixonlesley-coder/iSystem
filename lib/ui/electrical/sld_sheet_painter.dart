/// A reusable, read-only canvas for ANY pure-engine [SldSheet] — the
/// drawing-space geometry produced by `report/electrical_sld_drawing.dart`
/// (`buildElectricalOverview` / `buildElectricalRiser` / `buildElectricalSld`).
/// It renders the sheet's sealed primitives ([SldLine] / [SldRect] /
/// [SldLabel]) on a pannable / zoomable [ViewportTransform]-driven surface, so
/// the SAME geometry the PDF + DXF exporters draw also shows LIVE on the
/// electrical workspace — never a parallel re-derivation.
///
/// Colour is driven by [SldRole]: `normal` → the ink colour, `essential` →
/// danger red, `source` → the brand accent (mirroring the reference drawings'
/// cyan-normal / red-essential / blue-source split). Every label renders via a
/// `fontFamily: 'Roboto'` [TextSpan] (the engine writes ASCII only — `kW`, `3P`,
/// `NYM 3x2.5`, `+12.50` — so it never tofus), and is dropped below a legibility
/// scale to avoid sub-pixel mush.
///
/// Styled with MechXTheme — no Material. Pure presentation: it does NO hit
/// testing on the primitives (the overview / riser are read-only projections;
/// editing stays on the interactive single-line canvas + the Layout layer).
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';

import '../canvas/canvas_grid.dart';
import '../canvas/viewport.dart';
import '../theme/mechx_theme.dart';

/// Below this on-screen font size a label is skipped (avoids unreadable mush
/// when zoomed far out; mirrors the interactive canvas's `_label` guard).
const double _kMinLabelPx = 4.5;

/// Paints an [SldSheet] in screen space through a [ViewportTransform].
class SldSheetPainter extends CustomPainter {
  final SldSheet sheet;
  final ViewportTransform transform;

  /// Role → colour. `normal` = [ink]; `essential` = [essential]; `source` =
  /// [source].
  final Color ink;
  final Color essential;
  final Color source;
  final Color background;
  final Color gridLine;

  SldSheetPainter({
    required this.sheet,
    required this.transform,
    required this.ink,
    required this.essential,
    required this.source,
    required this.background,
    required this.gridLine,
  });

  Color _roleColor(SldRole role) => switch (role) {
        SldRole.normal => ink,
        SldRole.essential => essential,
        SldRole.source => source,
      };

  double _weightPx(SldWeight w) => switch (w) {
        SldWeight.thin => 1.0,
        SldWeight.medium => 1.8,
        SldWeight.thick => 3.0,
      };

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    paintCanvasGrid(canvas, size, transform, gridLine);

    final s = transform.scale;
    for (final prim in sheet.prims) {
      switch (prim) {
        case SldLine():
          final a = transform.worldToScreen(Offset(prim.x1, prim.y1));
          final b = transform.worldToScreen(Offset(prim.x2, prim.y2));
          canvas.drawLine(
            a,
            b,
            Paint()
              ..color = _roleColor(prim.role)
              ..strokeWidth = (_weightPx(prim.weight) * s).clamp(0.6, 6.0)
              ..strokeCap = StrokeCap.round,
          );
        case SldRect():
          final tl = transform.worldToScreen(Offset(prim.x, prim.y));
          final rect = Rect.fromLTWH(
            tl.dx,
            tl.dy,
            prim.w * s,
            prim.h * s,
          );
          final rrect = RRect.fromRectAndRadius(
            rect,
            Radius.circular(math.min(6 * s, rect.shortestSide / 4)),
          );
          // Opaque card fill (content stays legible) + a role-coloured border.
          canvas.drawRRect(rrect, Paint()..color = background);
          canvas.drawRRect(
            rrect,
            Paint()
              ..color = _roleColor(prim.role)
              ..style = PaintingStyle.stroke
              ..strokeWidth = (_weightPx(prim.weight) * s).clamp(0.8, 4.0),
          );
        case SldLabel():
          _label(canvas, prim, s);
      }
    }
  }

  void _label(Canvas canvas, SldLabel prim, double s) {
    final fontSize = prim.size * s;
    if (fontSize < _kMinLabelPx) return;
    final at = transform.worldToScreen(Offset(prim.x, prim.y));
    final tp = TextPainter(
      text: TextSpan(
        text: prim.text,
        style: TextStyle(
          fontFamily: 'Roboto',
          fontSize: fontSize,
          color: _roleColor(prim.role),
          fontWeight: prim.bold ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // Engine labels are baseline-ish anchored (y at the text baseline in the
    // exporters); paint with the top a touch above so it reads inside its row.
    tp.paint(canvas, at - Offset(0, tp.height * 0.78));
  }

  @override
  bool shouldRepaint(SldSheetPainter old) =>
      old.sheet != sheet ||
      old.transform != transform ||
      old.ink != ink ||
      old.essential != essential ||
      old.source != source ||
      old.background != background ||
      old.gridLine != gridLine;
}

/// A small read-only host that frames an [SldSheet] and lets the user pan
/// (left-drag / middle-drag) and zoom (scroll / pinch). Exposes an imperative
/// zoom API (`zoomIn` / `zoomOut` / `fitView`) through its [State] so a parent
/// can wire the shared [ZoomControls]. Re-fits whenever the sheet identity
/// changes (a fresh solve), unless the user has taken the viewport.
class SldSheetView extends StatefulWidget {
  final SldSheet sheet;
  const SldSheetView({super.key, required this.sheet});

  @override
  SldSheetViewState createState() => SldSheetViewState();
}

class SldSheetViewState extends State<SldSheetView> {
  ViewportTransform? _transform;
  Size _viewportSize = Size.zero;

  // Once the user pans / zooms we stop auto-fitting on sheet change.
  bool _userOwnsViewport = false;

  bool _panning = false;
  Offset _lastPanPoint = Offset.zero;
  double _lastScale = 1.0;

  ViewportTransform get _current =>
      _transform ?? const ViewportTransform(scale: 0.5);

  /// Current zoom scale (exposed for the host / tests).
  double get currentScale => _current.scale;

  void _setTransform(ViewportTransform next, {bool userDriven = true}) {
    if (next == _transform) return;
    setState(() {
      _transform = next;
      if (userDriven) _userOwnsViewport = true;
    });
  }

  // ── Fit ──────────────────────────────────────────────────────────────────

  ViewportTransform? _fitTransform() {
    if (_viewportSize.isEmpty || widget.sheet.isEmpty) return null;
    final sheet = widget.sheet;
    final content = Size(
      math.max(1.0, sheet.maxX - sheet.minX),
      math.max(1.0, sheet.maxY - sheet.minY),
    );
    final fitted =
        ViewportTransform.fit(content, _viewportSize, padding: 36);
    // Re-anchor so the sheet's (minX,minY) lands at the padded top-left.
    return ViewportTransform(
      scale: fitted.scale,
      offset: fitted.offset - Offset(sheet.minX, sheet.minY) * fitted.scale,
    );
  }

  /// Frame the whole sheet (resets user ownership).
  void fitView() {
    final t = _fitTransform();
    if (t != null) {
      setState(() {
        _transform = t;
        _userOwnsViewport = false;
      });
    }
  }

  void zoomIn() => _setTransform(
        _current.zoomedBy(1.2, _viewportSize.center(Offset.zero)),
      );
  void zoomOut() => _setTransform(
        _current.zoomedBy(1 / 1.2, _viewportSize.center(Offset.zero)),
      );

  /// Frame on the first layout (synchronous so even a single-frame render is
  /// framed, not clipped at the origin), and re-frame when the sheet changes
  /// while the user hasn't taken the viewport.
  void _ensureFitted() {
    if (_viewportSize.isEmpty || widget.sheet.isEmpty) return;
    if (_transform != null && _userOwnsViewport) return;
    final t = _fitTransform();
    if (t != null) _transform = t;
  }

  @override
  void didUpdateWidget(covariant SldSheetView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new sheet identity (fresh solve) re-fits unless the user owns the view.
    if (!identical(oldWidget.sheet, widget.sheet) && !_userOwnsViewport) {
      _transform = null; // force a re-fit on the next layout
    }
  }

  // ── Pointer / gestures ─────────────────────────────────────────────────────

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final factor = math.pow(1.0015, -event.scrollDelta.dy).toDouble();
      _setTransform(_current.zoomedBy(factor, event.localPosition));
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons & kMiddleMouseButton != 0) {
      _panning = true;
      _lastPanPoint = event.localPosition;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_panning) return;
    _setTransform(_current.panned(event.localPosition - _lastPanPoint));
    _lastPanPoint = event.localPosition;
  }

  void _onPointerUp(PointerUpEvent event) => _panning = false;

  void _onScaleStart(ScaleStartDetails details) => _lastScale = 1.0;

  void _onScaleUpdate(ScaleUpdateDetails details) {
    var vt = _current;
    if (details.focalPointDelta != Offset.zero) {
      vt = vt.panned(details.focalPointDelta);
    }
    final incremental = details.scale / _lastScale;
    _lastScale = details.scale;
    if (incremental != 1.0) {
      vt = vt.zoomedBy(incremental, details.localFocalPoint);
    }
    _setTransform(vt);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Listener(
      onPointerSignal: _onPointerSignal,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        child: LayoutBuilder(
          builder: (context, constraints) {
            _viewportSize = constraints.biggest;
            _ensureFitted();
            return ClipRect(
              child: CustomPaint(
                size: Size.infinite,
                painter: SldSheetPainter(
                  sheet: widget.sheet,
                  transform: _current,
                  ink: colors.textPrimary,
                  essential: colors.danger,
                  source: colors.accent,
                  background: colors.canvas,
                  gridLine: colors.gridLine,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
