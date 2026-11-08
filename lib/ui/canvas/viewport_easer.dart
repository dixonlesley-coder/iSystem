/// Eases a canvas's PROGRAMMATIC viewport change (zoom buttons, Fit, keyboard
/// zoom, a "frame this board" gesture) from the current view to a target —
/// the Layout canvas's G4 tween (`CanvasView._animateTo`: [MechXMotion.medium]
/// on [MechXMotion.standard]) as a reusable helper. The duration passes through
/// [MechXMotion.resolve], so with reduced motion the change lands at once.
/// Live manipulation (wheel, drag, pinch, arrow pan) calls [stop] and writes
/// directly.
///
/// Adopters (2026-10-20): the electrical single-line canvas. The Riser canvases
/// carry an identical private copy (`schematic_view.dart` `_ViewportEaser`)
/// that can switch to this class without a behaviour change.
library;

import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import 'viewport.dart';

class ViewportEaser {
  ViewportEaser(TickerProvider vsync, this._onTick)
      : _ctrl = AnimationController(vsync: vsync, duration: MechXMotion.medium) {
    _ctrl.addListener(_tick);
  }

  final AnimationController _ctrl;
  final void Function(ViewportTransform) _onTick;
  ViewportTransform? _from;
  ViewportTransform? _to;

  /// Whether an eased change is in flight.
  bool get isAnimating => _ctrl.isAnimating;

  /// Ease from [from] to [to] (reduced motion ⇒ one immediate tick).
  void animateTo(
      BuildContext context, ViewportTransform from, ViewportTransform to) {
    stop();
    if (from == to) return;
    final d = MechXMotion.resolve(context, MechXMotion.medium);
    if (d == Duration.zero) {
      _onTick(to);
      return;
    }
    _from = from;
    _to = to;
    _ctrl
      ..duration = d
      ..reset()
      ..forward();
  }

  void _tick() {
    final from = _from, to = _to;
    if (from == null || to == null) return;
    final t = MechXMotion.standard.transform(_ctrl.value);
    _onTick(ViewportTransform(
      scale: from.scale + (to.scale - from.scale) * t,
      offset: Offset.lerp(from.offset, to.offset, t)!,
    ));
  }

  /// Cancel any in-flight ease (the view stays where it is).
  void stop() {
    if (_ctrl.isAnimating) _ctrl.stop();
    _from = null;
    _to = null;
  }

  void dispose() => _ctrl.dispose();
}
