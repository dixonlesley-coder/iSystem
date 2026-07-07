import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/smart_input_store.dart';
import '../theme/design_tokens.dart';
import 'canvas_grid.dart';
import 'canvas_minimap.dart';
import 'viewport.dart';

/// B30 — the screen-space edge band (px) inside which the live draw pointer
/// drives auto-pan.
const double _kAutoPanBand = 24.0;

/// B30 — peak auto-pan speed (px per ~16 ms tick) at full edge penetration.
const double _kAutoPanMaxSpeed = 14.0;

/// A bump signal asking the live [CanvasView] to fit its content to the
/// viewport. A mounted [CanvasViewState] listens and calls [CanvasViewState.fitView]
/// on every bump, so a host that doesn't hold the canvas's [GlobalKey] (the
/// command palette's "Fit view" action, W3-P5; the Layout canvas's F key) can
/// still trigger a fit. The int is a monotonic counter — only the CHANGE
/// matters, never the value.
final canvasFitRequestProvider =
    NotifierProvider<CanvasFitRequestController, int>(
  CanvasFitRequestController.new,
);

class CanvasFitRequestController extends Notifier<int> {
  @override
  int build() => 0;

  /// Ask every mounted [CanvasView] to fit its content (bumps the counter so
  /// listeners fire). Idempotent-safe — fitting an already-fit canvas is a no-op.
  void request() => state = state + 1;
}

/// A pannable / zoomable canvas hosting a fixed-size [child] (a sheet page).
///
/// Native desktop input (§4): mouse-wheel zoom-to-cursor, middle-drag pan,
/// trackpad/touch pan + pinch, and keyboard shortcuts (Ctrl +/- zoom, Ctrl+0
/// actual size, F fit, arrows pan). It is *controlled per sheet*: give it a
/// [ValueKey] of the sheet id and an [initialTransform] (the restored viewport,
/// or null to fit-on-first-layout); it reports every change via
/// [onTransformChanged] for the store to persist.
class CanvasView extends ConsumerStatefulWidget {
  final Size contentSize;
  final Widget child;
  final ViewportTransform? initialTransform;
  final ValueChanged<ViewportTransform> onTransformChanged;
  final Color background;

  /// The drafting grid colour (typically `colors.gridLine`). When null no grid
  /// is drawn; when set, the canvas paints the SAME graph-paper grid as the
  /// electrical single-line canvas (see [paintCanvasGrid]) so both workspaces
  /// share one substrate.
  final Color? gridColor;

  /// World-space spacing (content px) of the drafting grid's minor lines. Null
  /// keeps [paintCanvasGrid]'s default (the uncalibrated 32 px texture); a
  /// calibrated sheet passes [calibratedGridWorldStep] so the minors land on a
  /// round 1-2-5 metre ladder (majors on the 4× multiple).
  final double? gridWorldStep;

  /// Optional mouse-cursor override. Null keeps the default grab/grabbing pan
  /// affordance; a host whose overlays repurpose left-drag (draw / marquee
  /// modes) passes the honest cursor for the active tool instead.
  final MouseCursor? cursor;

  /// Optional host hook for the directional (arrow) keys. Called BEFORE the
  /// built-in arrow-pan; if it returns true the key is consumed by the host
  /// (e.g. nudging a selection, E2) and the canvas does NOT pan. Null ⇒ arrows
  /// always pan (the default for callers that don't own a selection).
  final bool Function(LogicalKeyboardKey key)? onDirectionalKey;

  /// Optional sink the canvas publishes its live viewport into (the affine
  /// transform + the widget size) each frame the view changes, so a sibling
  /// minimap ([CanvasMinimap], G1) can draw a truthful viewport rectangle and
  /// pan-to-tap without rebuilding the canvas subtree. Null ⇒ nothing published
  /// ⇒ byte-identical.
  final ValueNotifier<MinimapViewport?>? viewportSink;

  const CanvasView({
    super.key,
    required this.contentSize,
    required this.child,
    required this.initialTransform,
    required this.onTransformChanged,
    required this.background,
    this.gridColor,
    this.gridWorldStep,
    this.cursor,
    this.onDirectionalKey,
    this.viewportSink,
  });

  @override
  ConsumerState<CanvasView> createState() => CanvasViewState();
}

/// Public so a host can drive zoom imperatively via a [GlobalKey] (the shared
/// on-canvas [ZoomControls]). The canvas owns its live transform, so the
/// buttons go through these methods rather than the persisted store.
class CanvasViewState extends ConsumerState<CanvasView>
    with SingleTickerProviderStateMixin {
  ViewportTransform? _transform;
  Size _viewportSize = Size.zero;
  final FocusNode _focus = FocusNode(debugLabel: 'canvas');

  // Middle-button pan tracking.
  // Scale-gesture incremental tracking.
  double _lastScale = 1.0;
  // Grab-cursor affordance (left/middle click pans).
  bool _grabbing = false;

  // G4 — programmatic viewport changes (zoom / fit / minimap recenter) EASE
  // from the current transform to the target rather than teleporting. Live
  // manipulation (wheel / drag / trackpad pinch, arrow pan) stays immediate.
  late final AnimationController _animCtrl;
  ViewportTransform? _animFrom;
  ViewportTransform? _animTo;

  @override
  void initState() {
    super.initState();
    _transform = widget.initialTransform;
    _animCtrl = AnimationController(vsync: this, duration: MechXMotion.medium)
      ..addListener(_onAnimTick);
  }

  // B30 — auto-pan ticker, live only while a draw gesture publishes a pointer.
  Timer? _autoPanTimer;

  @override
  void dispose() {
    _autoPanTimer?.cancel();
    _animCtrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ── B30 auto-pan (drives the existing pan path while drawing near an edge) ────

  void _startAutoPan() {
    _autoPanTimer ??= Timer.periodic(
        const Duration(milliseconds: 16), (_) => _autoPanTick());
  }

  void _stopAutoPan() {
    _autoPanTimer?.cancel();
    _autoPanTimer = null;
  }

  void _autoPanTick() {
    final probe = ref.read(canvasAutoPanProbeProvider);
    if (probe == null || _viewportSize.isEmpty) return;
    final w = _viewportSize.width, h = _viewportSize.height;
    // Ignore a pointer well outside this viewport (a stale / other-canvas probe).
    if (probe.dx < -_kAutoPanBand ||
        probe.dx > w + _kAutoPanBand ||
        probe.dy < -_kAutoPanBand ||
        probe.dy > h + _kAutoPanBand) {
      return;
    }
    double dx = 0, dy = 0;
    if (probe.dx < _kAutoPanBand) {
      dx = (_kAutoPanBand - probe.dx) / _kAutoPanBand * _kAutoPanMaxSpeed;
    } else if (probe.dx > w - _kAutoPanBand) {
      dx = -((probe.dx - (w - _kAutoPanBand)) / _kAutoPanBand) *
          _kAutoPanMaxSpeed;
    }
    if (probe.dy < _kAutoPanBand) {
      dy = (_kAutoPanBand - probe.dy) / _kAutoPanBand * _kAutoPanMaxSpeed;
    } else if (probe.dy > h - _kAutoPanBand) {
      dy = -((probe.dy - (h - _kAutoPanBand)) / _kAutoPanBand) *
          _kAutoPanMaxSpeed;
    }
    if (dx == 0 && dy == 0) return;
    // Clamp so we stop at the content bounds (never scroll past the sheet).
    final vt = _current;
    final cw = widget.contentSize.width * vt.scale;
    final ch = widget.contentSize.height * vt.scale;
    dx = _clampPan(dx, vt.offset.dx, vt.offset.dx + cw, w);
    dy = _clampPan(dy, vt.offset.dy, vt.offset.dy + ch, h);
    if (dx == 0 && dy == 0) return;
    panByScreen(Offset(dx, dy));
  }

  /// Clamp a pan delta on one axis so the content edge can't move past the
  /// viewport edge. [contentMin]/[contentMax] are the content span in screen px;
  /// [viewMax] the viewport size on that axis.
  static double _clampPan(
      double d, double contentMin, double contentMax, double viewMax) {
    if (d > 0) {
      final room = -contentMin; // room before content start reaches 0
      return room <= 0 ? 0 : math.min(d, room);
    }
    if (d < 0) {
      final room = viewMax - contentMax; // room before content end reaches edge
      return room >= 0 ? 0 : math.max(d, room);
    }
    return 0;
  }

  void _emit(ViewportTransform next) {
    if (next == _transform) return;
    setState(() => _transform = next);
    widget.onTransformChanged(next);
  }

  // ── Programmatic (eased) viewport changes (G4) ───────────────────────────────

  /// Ease the view from the current transform to [target] over [MechXMotion]
  /// timing (lerping scale + offset). A no-op if the target equals the current
  /// view or the viewport isn't laid out yet.
  void _animateTo(ViewportTransform target) {
    if (_viewportSize.isEmpty) return;
    final from = _current;
    if (from == target) return;
    _animFrom = from;
    _animTo = target;
    _animCtrl
      ..stop()
      ..reset()
      ..forward();
  }

  void _onAnimTick() {
    final from = _animFrom, to = _animTo;
    if (from == null || to == null) return;
    final t = MechXMotion.standard.transform(_animCtrl.value);
    final scale = from.scale + (to.scale - from.scale) * t;
    final offset = Offset.lerp(from.offset, to.offset, t)!;
    _emit(ViewportTransform(scale: scale, offset: offset));
  }

  /// Cancel any in-flight eased change so a live gesture (wheel / drag / pinch /
  /// arrow pan) takes over cleanly rather than fighting the tween.
  void _stopAnim() {
    if (_animCtrl.isAnimating) _animCtrl.stop();
    _animFrom = null;
    _animTo = null;
  }

  ViewportTransform get _current =>
      _transform ?? ViewportTransform.fit(widget.contentSize, _viewportSize);

  void _maybeFitOnFirstLayout() {
    if (_transform != null || _viewportSize.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _transform != null || _viewportSize.isEmpty) return;
      _emit(ViewportTransform.fit(widget.contentSize, _viewportSize));
    });
  }

  // ── Imperative zoom (driven by the shared on-canvas ZoomControls) ────────────

  void zoomIn() {
    if (_viewportSize.isEmpty) return;
    _animateTo(_current.zoomedBy(1.2, _viewportSize.center(Offset.zero)));
  }

  void zoomOut() {
    if (_viewportSize.isEmpty) return;
    _animateTo(_current.zoomedBy(1 / 1.2, _viewportSize.center(Offset.zero)));
  }

  void fitView() {
    if (_viewportSize.isEmpty) return;
    _animateTo(ViewportTransform.fit(widget.contentSize, _viewportSize));
  }

  /// Pan (keeping the current scale) so [world] (content px) lands at the
  /// viewport centre — the minimap tap / drag-to-navigate target (G1).
  /// IMMEDIATE (not eased): a minimap click/drag is DIRECT MANIPULATION (like a
  /// scrollbar), so it must track 1:1 rather than trail behind a per-frame tween
  /// (a drag that re-eased every frame would rubber-band). The discrete zoom /
  /// fit buttons keep the G4 ease; `_stopAnim` cancels any in-flight zoom so the
  /// direct pan takes over cleanly. No-op before the first layout.
  void centreOnWorld(Offset world) {
    if (_viewportSize.isEmpty) return;
    _stopAnim();
    final s = _current.scale;
    _emit(ViewportTransform(
      scale: s,
      offset: _viewportSize.center(Offset.zero) - world * s,
    ));
  }

  /// Pan the viewport by a screen-space [delta]. Public so a parent (above the
  /// canvas overlays, which are opaque and would otherwise swallow the
  /// middle-button drag) can drive middle-click panning.
  void panByScreen(Offset delta) {
    _stopAnim();
    _emit(_current.panned(delta));
  }

  /// Zoom toward [localPos] (canvas-local px) by a mouse-wheel [scrollDeltaY].
  /// Public for the same reason as [panByScreen]: the overlays above this widget
  /// swallow the wheel signal, so a parent drives zoom from above them.
  void zoomByScroll(Offset localPos, double scrollDeltaY) {
    _stopAnim();
    final factor = math.pow(1.0015, -scrollDeltaY).toDouble();
    _emit(_current.zoomedBy(factor, localPos));
  }

  // ── Pointer (mouse) ────────────────────────────────────────────────────────

  void _onPointerDown(PointerDownEvent event) {
    _focus.requestFocus();
    if (!_grabbing) setState(() => _grabbing = true);
    // NB: middle-button PAN is driven from an ancestor Listener (see
    // [panByScreen]) because the canvas overlays sit ON TOP of this widget and
    // are opaque — they'd swallow the middle-drag before it reached here.
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_grabbing) setState(() => _grabbing = false);
  }

  // ── Scale gesture (trackpad / touch / left-drag pan) ────────────────────────

  void _onScaleStart(ScaleStartDetails details) {
    _stopAnim();
    _lastScale = 1.0;
  }

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
    _emit(vt);
  }

  // ── Keyboard ────────────────────────────────────────────────────────────────

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_viewportSize.isEmpty) return KeyEventResult.ignored;
    final vt = _current;
    final center = _viewportSize.center(Offset.zero);
    final mod = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final key = event.logicalKey;
    const panStep = 64.0;

    // Discrete keyboard zoom / fit / actual-size ease like the on-canvas zoom
    // cluster (G4); arrow pan below stays immediate.
    if (mod &&
        (key == LogicalKeyboardKey.equal ||
            key == LogicalKeyboardKey.add ||
            key == LogicalKeyboardKey.numpadAdd)) {
      _animateTo(vt.zoomedBy(1.2, center));
      return KeyEventResult.handled;
    }
    if (mod &&
        (key == LogicalKeyboardKey.minus ||
            key == LogicalKeyboardKey.numpadSubtract)) {
      _animateTo(vt.zoomedBy(1 / 1.2, center));
      return KeyEventResult.handled;
    }
    if (mod && key == LogicalKeyboardKey.digit0) {
      _animateTo(ViewportTransform.actualSize(widget.contentSize, _viewportSize));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      _animateTo(ViewportTransform.fit(widget.contentSize, _viewportSize));
      return KeyEventResult.handled;
    }
    switch (key) {
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.arrowUp:
      case LogicalKeyboardKey.arrowDown:
        // A host that owns a selection nudges it (E2) and consumes the key; a
        // null hook (or "nothing selected") falls through to arrow-pan. The
        // nudge fires ONLY on a fresh, unmodified key-DOWN: a held arrow
        // (KeyRepeatEvent) or any modifier+arrow falls through to pan, so a held
        // nudge can't flood the undo stack (one snapshot per repeat) and
        // Ctrl/Shift/Alt+Arrow pans rather than moving the selection.
        final anyMod = mod ||
            HardwareKeyboard.instance.isShiftPressed ||
            HardwareKeyboard.instance.isAltPressed;
        if (event is KeyDownEvent &&
            !anyMod &&
            (widget.onDirectionalKey?.call(key) ?? false)) {
          return KeyEventResult.handled;
        }
        // Live arrow pan is immediate (a running eased change would otherwise
        // keep overriding it).
        _stopAnim();
        switch (key) {
          case LogicalKeyboardKey.arrowLeft:
            _emit(vt.panned(const Offset(panStep, 0)));
          case LogicalKeyboardKey.arrowRight:
            _emit(vt.panned(const Offset(-panStep, 0)));
          case LogicalKeyboardKey.arrowUp:
            _emit(vt.panned(const Offset(0, panStep)));
          default:
            _emit(vt.panned(const Offset(0, -panStep)));
        }
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // A host without the canvas's GlobalKey can request a fit through the
    // shared bump provider (the command palette's Fit action, the Layout F key);
    // fire on every bump. fitView() self-guards an empty viewport.
    ref.listen(canvasFitRequestProvider, (_, _) => fitView());
    // B30 — start/stop the auto-pan ticker as a draw gesture publishes / clears
    // its pointer. Null probe ⇒ ticker stopped ⇒ byte-identical when idle.
    ref.listen<Offset?>(canvasAutoPanProbeProvider, (_, next) {
      if (next == null) {
        _stopAutoPan();
      } else {
        _startAutoPan();
      }
    });
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: MouseRegion(
        // An explicit override (the host's honest tool cursor) wins; otherwise
        // the default pan affordance (grab, grabbing while pressed).
        cursor: widget.cursor ??
            (_grabbing
                ? SystemMouseCursors.grabbing
                : SystemMouseCursors.grab),
        child: Listener(
          onPointerDown: _onPointerDown,
          onPointerUp: _onPointerUp,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            child: LayoutBuilder(
            builder: (context, constraints) {
              _viewportSize = constraints.biggest;
              _maybeFitOnFirstLayout();
              final vt = _current;
              // Publish the live viewport for a sibling minimap (G1). Deferred to
              // after the frame — the minimap's ValueListenableBuilder is a
              // SIBLING (not a descendant of this LayoutBuilder), so notifying it
              // mid-build would markNeedsBuild during build; a post-frame set is
              // safe, and record equality means an unchanged view never notifies.
              final sink = widget.viewportSink;
              if (sink != null) {
                final next = (transform: vt, size: _viewportSize);
                if (sink.value != next) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) sink.value = next;
                  });
                }
              }
              return SizedBox.expand(
                child: ClipRect(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Backdrop: the canvas fill + the shared drafting grid,
                      // painted in screen space so it pans/zooms with content.
                      CustomPaint(
                        painter: _BackdropPainter(
                          transform: vt,
                          background: widget.background,
                          gridColor: widget.gridColor,
                          gridWorldStep: widget.gridWorldStep,
                        ),
                      ),
                      Transform.translate(
                        offset: vt.offset,
                        child: Transform.scale(
                          scale: vt.scale,
                          alignment: Alignment.topLeft,
                          // OverflowBox lets the content take its true pixel size
                          // (rather than being clamped to the viewport) so it
                          // scales 1:1 with the world-space overlays.
                          child: OverflowBox(
                            alignment: Alignment.topLeft,
                            minWidth: 0,
                            maxWidth: double.infinity,
                            minHeight: 0,
                            maxHeight: double.infinity,
                            child: SizedBox.fromSize(
                              size: widget.contentSize,
                              child: RepaintBoundary(child: widget.child),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the canvas fill and (when [gridColor] is set) the shared drafting
/// grid behind the world content.
class _BackdropPainter extends CustomPainter {
  final ViewportTransform transform;
  final Color background;
  final Color? gridColor;
  final double? gridWorldStep;

  _BackdropPainter({
    required this.transform,
    required this.background,
    required this.gridColor,
    this.gridWorldStep,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final grid = gridColor;
    if (grid != null) {
      final step = gridWorldStep;
      if (step != null) {
        paintCanvasGrid(canvas, size, transform, grid, worldStep: step);
      } else {
        paintCanvasGrid(canvas, size, transform, grid);
      }
    }
  }

  @override
  bool shouldRepaint(_BackdropPainter old) =>
      old.transform != transform ||
      old.background != background ||
      old.gridColor != gridColor ||
      old.gridWorldStep != gridWorldStep;
}
