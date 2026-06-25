import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'canvas_grid.dart';
import 'viewport.dart';

/// A pannable / zoomable canvas hosting a fixed-size [child] (a sheet page).
///
/// Native desktop input (§4): mouse-wheel zoom-to-cursor, middle-drag pan,
/// trackpad/touch pan + pinch, and keyboard shortcuts (Ctrl +/- zoom, Ctrl+0
/// actual size, F fit, arrows pan). It is *controlled per sheet*: give it a
/// [ValueKey] of the sheet id and an [initialTransform] (the restored viewport,
/// or null to fit-on-first-layout); it reports every change via
/// [onTransformChanged] for the store to persist.
class CanvasView extends StatefulWidget {
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

  const CanvasView({
    super.key,
    required this.contentSize,
    required this.child,
    required this.initialTransform,
    required this.onTransformChanged,
    required this.background,
    this.gridColor,
  });

  @override
  State<CanvasView> createState() => CanvasViewState();
}

/// Public so a host can drive zoom imperatively via a [GlobalKey] (the shared
/// on-canvas [ZoomControls]). The canvas owns its live transform, so the
/// buttons go through these methods rather than the persisted store.
class CanvasViewState extends State<CanvasView> {
  ViewportTransform? _transform;
  Size _viewportSize = Size.zero;
  final FocusNode _focus = FocusNode(debugLabel: 'canvas');

  // Middle-button pan tracking.
  // Scale-gesture incremental tracking.
  double _lastScale = 1.0;
  // Grab-cursor affordance (left/middle click pans).
  bool _grabbing = false;

  @override
  void initState() {
    super.initState();
    _transform = widget.initialTransform;
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _emit(ViewportTransform next) {
    if (next == _transform) return;
    setState(() => _transform = next);
    widget.onTransformChanged(next);
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
    _emit(_current.zoomedBy(1.2, _viewportSize.center(Offset.zero)));
  }

  void zoomOut() {
    if (_viewportSize.isEmpty) return;
    _emit(_current.zoomedBy(1 / 1.2, _viewportSize.center(Offset.zero)));
  }

  void fitView() {
    if (_viewportSize.isEmpty) return;
    _emit(ViewportTransform.fit(widget.contentSize, _viewportSize));
  }

  /// Pan the viewport by a screen-space [delta]. Public so a parent (above the
  /// canvas overlays, which are opaque and would otherwise swallow the
  /// middle-button drag) can drive middle-click panning.
  void panByScreen(Offset delta) => _emit(_current.panned(delta));

  // ── Pointer (mouse) ────────────────────────────────────────────────────────

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final factor = math.pow(1.0015, -event.scrollDelta.dy).toDouble();
      _emit(_current.zoomedBy(factor, event.localPosition));
    }
  }

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

    if (mod &&
        (key == LogicalKeyboardKey.equal ||
            key == LogicalKeyboardKey.add ||
            key == LogicalKeyboardKey.numpadAdd)) {
      _emit(vt.zoomedBy(1.2, center));
      return KeyEventResult.handled;
    }
    if (mod &&
        (key == LogicalKeyboardKey.minus ||
            key == LogicalKeyboardKey.numpadSubtract)) {
      _emit(vt.zoomedBy(1 / 1.2, center));
      return KeyEventResult.handled;
    }
    if (mod && key == LogicalKeyboardKey.digit0) {
      _emit(ViewportTransform.actualSize(widget.contentSize, _viewportSize));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      _emit(ViewportTransform.fit(widget.contentSize, _viewportSize));
      return KeyEventResult.handled;
    }
    switch (key) {
      case LogicalKeyboardKey.arrowLeft:
        _emit(vt.panned(const Offset(panStep, 0)));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        _emit(vt.panned(const Offset(-panStep, 0)));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _emit(vt.panned(const Offset(0, panStep)));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        _emit(vt.panned(const Offset(0, -panStep)));
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: MouseRegion(
        cursor: _grabbing
            ? SystemMouseCursors.grabbing
            : SystemMouseCursors.grab,
        child: Listener(
          onPointerSignal: _onPointerSignal,
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

  _BackdropPainter({
    required this.transform,
    required this.background,
    required this.gridColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final grid = gridColor;
    if (grid != null) paintCanvasGrid(canvas, size, transform, grid);
  }

  @override
  bool shouldRepaint(_BackdropPainter old) =>
      old.transform != transform ||
      old.background != background ||
      old.gridColor != gridColor;
}
