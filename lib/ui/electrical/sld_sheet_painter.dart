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

/// Indonesian R-S-T / N / PE rail colours (hard hex, ported verbatim). ONE home
/// for the phase palette: the summary-card cells, the micro R/S/T bar, the
/// phase badges AND the engine-sheet phase roles ([SldRole.phaseR]/`phaseS`/
/// `phaseT`) all read these, so a phase is the same hue at every LOD and in
/// every projection.
const Color kRailR = Color(0xFFC92A2A); // L1 / R / single-phase live
const Color kRailS = Color(0xFFE8990C); // L2 / S
const Color kRailT = Color(0xFF1971C2); // L3 / T
const Color kRailN = Color(0xFF4DABF7); // neutral
const Color kRailPE = Color(0xFF2F9E44); // protective earth

/// Stroke px per [SldWeight] bucket (shared by the painter + the free function).
double _weightPxFor(SldWeight w) => switch (w) {
      SldWeight.thin => 1.0,
      SldWeight.medium => 1.8,
      SldWeight.thick => 3.0,
    };

/// Dash run lengths (screen px, zoom-independent like a CAD screen linetype)
/// for a dashed [SldLine] — mirrors the PDF's `[4 3]` pattern.
const double _kDashOnPx = 4.0;
const double _kDashOffPx = 3.0;

/// Walk a dashed line as plain segments (pure canvas math — Flutter has no
/// stroke dash). Solid lines never come here, so they stay byte-identical.
void _drawDashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
  final delta = b - a;
  final len = delta.distance;
  if (len <= 0) return;
  final dir = delta / len;
  var t = 0.0;
  while (t < len) {
    final e = math.min(t + _kDashOnPx, len);
    canvas.drawLine(a + dir * t, a + dir * e, paint);
    t = e + _kDashOffPx;
  }
}

/// Paint just the sealed primitives of an [SldSheet] through [transform] (no
/// grid, no background fill) — the ONE prim-painting routine shared by the
/// full [SldSheetView] (overview / riser) and the in-card deep-zoom board
/// schedule (`electrical_canvas.dart`). Role → colour via [ink] / [essential] /
/// [source]; [rectFill] backs each box so its content stays legible.
void paintSldPrims(
  Canvas canvas,
  SldSheet sheet,
  ViewportTransform transform, {
  required Color ink,
  required Color essential,
  required Color source,
  required Color rectFill,
}) {
  Color roleColor(SldRole role) => switch (role) {
        SldRole.normal => ink,
        SldRole.essential => essential,
        SldRole.source => source,
        // Phase-bearing schedule content — the same rail hues the summary
        // card / micro bar use, so R/S/T read identically at every LOD.
        SldRole.phaseR => kRailR,
        SldRole.phaseS => kRailS,
        SldRole.phaseT => kRailT,
      };
  final s = transform.scale;
  for (final prim in sheet.prims) {
    switch (prim) {
      case SldLine():
        final a = transform.worldToScreen(Offset(prim.x1, prim.y1));
        final b = transform.worldToScreen(Offset(prim.x2, prim.y2));
        final paint = Paint()
          ..color = roleColor(prim.role)
          ..strokeWidth = (_weightPxFor(prim.weight) * s).clamp(0.6, 6.0)
          ..strokeCap = StrokeCap.round;
        if (prim.dashed) {
          _drawDashedLine(canvas, a, b, paint);
        } else {
          canvas.drawLine(a, b, paint);
        }
      case SldRect():
        final tl = transform.worldToScreen(Offset(prim.x, prim.y));
        final rect = Rect.fromLTWH(tl.dx, tl.dy, prim.w * s, prim.h * s);
        final rrect = RRect.fromRectAndRadius(
          rect,
          Radius.circular(math.min(6 * s, rect.shortestSide / 4)),
        );
        canvas.drawRRect(rrect, Paint()..color = rectFill);
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = roleColor(prim.role)
            ..style = PaintingStyle.stroke
            ..strokeWidth = (_weightPxFor(prim.weight) * s).clamp(0.8, 4.0),
        );
      case SldLabel():
        final fontSize = prim.size * s;
        if (fontSize < _kMinLabelPx) continue;
        final at = transform.worldToScreen(Offset(prim.x, prim.y));
        final tp = TextPainter(
          text: TextSpan(
            text: prim.text,
            style: TextStyle(
              fontFamily: 'Roboto',
              fontSize: fontSize,
              color: roleColor(prim.role),
              fontWeight: prim.bold ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, at - Offset(0, tp.height * 0.78));
      case SldCircle():
        final c = transform.worldToScreen(Offset(prim.cx, prim.cy));
        canvas.drawCircle(
            c, prim.r * s, Paint()..color = rectFill);
        canvas.drawCircle(
          c,
          prim.r * s,
          Paint()
            ..color = roleColor(prim.role)
            ..style = PaintingStyle.stroke
            ..strokeWidth = (_weightPxFor(prim.weight) * s).clamp(0.8, 4.0),
        );
    }
  }
}

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

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    paintCanvasGrid(canvas, size, transform, gridLine);
    paintSldPrims(
      canvas,
      sheet,
      transform,
      ink: ink,
      essential: essential,
      source: source,
      rectFill: background,
    );
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

/// A non-interactive painter that fits a single [SldSheet] (e.g. one panel's
/// board schedule, `buildElectricalPanelDetail`) into the paint box with a
/// fixed transform — no grid, no background fill (the host card surface shows
/// through), so the engine board schedule renders as the deep-zoom level of
/// detail INSIDE a panel card on the interactive single-line canvas. The SAME
/// geometry the PDF / DXF export draws — one source of truth.
/// Schedule row geometry (sheet-space), shared by the painter's row highlight
/// and the body's hit-test so they agree: header band `46` + `6` pad + the
/// column-header row (`rowH`), then one `rowH` per way.
const double kScheduleHeaderH = 46;
const double kScheduleRowH = 20;
double scheduleRowTop(int wayIndex) =>
    kScheduleHeaderH + 6 + kScheduleRowH + wayIndex * kScheduleRowH;

class SldBoardSchedulePainter extends CustomPainter {
  final SldSheet sheet;
  final Color ink;
  final Color essential;
  final double pad;

  /// The way (circuit) ROW the pointer is hovering, painted as a highlight band;
  /// null = none. Drawn in [highlight] (the accent) behind the schedule text.
  final int? hoveredRow;
  final Color? highlight;

  SldBoardSchedulePainter({
    required this.sheet,
    required this.ink,
    required this.essential,
    this.pad = 6,
    this.hoveredRow,
    this.highlight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (sheet.isEmpty || size.isEmpty) return;
    final content = Size(
      math.max(1.0, sheet.maxX - sheet.minX),
      math.max(1.0, sheet.maxY - sheet.minY),
    );
    final fitted = ViewportTransform.fit(content, size, padding: pad);
    final transform = ViewportTransform(
      scale: fitted.scale,
      offset: fitted.offset - Offset(sheet.minX, sheet.minY) * fitted.scale,
    );
    // Hover highlight band BEHIND the schedule text (the row the pointer is on).
    if (hoveredRow != null && hoveredRow! >= 0 && highlight != null) {
      final top = scheduleRowTop(hoveredRow!);
      final tl = transform.worldToScreen(Offset(sheet.minX + 2, top));
      final w = (sheet.maxX - sheet.minX - 4) * transform.scale;
      final h = kScheduleRowH * transform.scale;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(tl.dx, tl.dy, w, h),
          Radius.circular(3 * transform.scale),
        ),
        Paint()..color = highlight!.withAlpha(30),
      );
    }
    // A panel's own schedule has no source spine inside it, so `source` reuses
    // the ink colour (a normal panel reads as the existing dark schedule).
    paintSldPrims(
      canvas,
      sheet,
      transform,
      ink: ink,
      essential: essential,
      source: ink,
      rectFill: const Color(0x00000000),
    );
  }

  @override
  bool shouldRepaint(SldBoardSchedulePainter old) =>
      old.sheet != sheet ||
      old.ink != ink ||
      old.essential != essential ||
      old.pad != pad ||
      old.hoveredRow != hoveredRow ||
      old.highlight != highlight;
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
