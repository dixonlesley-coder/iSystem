import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The live zoom of the [CanvasView] hosting a sheet page, published to the
/// page's subtree so sheet-space CHROME (the loading / load-error cards) can
/// stay a constant on-screen size instead of scaling with the drawing.
///
/// Only widgets that call [CanvasZoomScope.of] depend on it, so a zoom frame
/// rebuilds just those (in practice: nothing, unless a sheet is loading or
/// failed) — the drawing itself never reads it.
class CanvasZoomScope extends InheritedWidget {
  /// World → screen scale of the hosting canvas (1.0 = actual size).
  final double scale;

  const CanvasZoomScope({super.key, required this.scale, required super.child});

  /// The hosting canvas's zoom, or 1.0 outside a canvas (a bare test harness,
  /// a thumbnail) — so a page stays usable anywhere.
  static double of(BuildContext context) {
    final s = context
        .dependOnInheritedWidgetOfExactType<CanvasZoomScope>()
        ?.scale;
    return (s == null || !s.isFinite || s <= 0) ? 1.0 : s;
  }

  @override
  bool updateShouldNotify(CanvasZoomScope oldWidget) =>
      oldWidget.scale != scale;
}

/// Lays [child] out in SCREEN units over its whole world-space box and paints
/// it counter-scaled, so text / cards inside read at the same size at every
/// zoom while the box still covers exactly the sheet it sits on.
///
/// A box of world size W x H is shown at W·s x H·s on screen; laying the child
/// out at W·s x H·s and painting it at 1/s lands it back on W x H in world
/// space, i.e. 1:1 with screen pixels.
class ScreenConstantLayer extends StatelessWidget {
  final Widget child;

  /// The smallest screen box [child] is laid out in (see [build]).
  final Size minScreenSize;

  const ScreenConstantLayer({
    super.key,
    required this.child,
    this.minScreenSize = const Size(480, 320),
  });

  @override
  Widget build(BuildContext context) {
    final s = CanvasZoomScope.of(context);
    if (s == 1.0) return child;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return child;
        }
        // The sheet's on-screen box — never smaller than [minScreenSize], so
        // a card on a sheet zoomed down to a thumbnail keeps its size and
        // overhangs the paper (centred on it) instead of being crushed.
        final w = math.max(constraints.maxWidth * s, minScreenSize.width);
        final h = math.max(constraints.maxHeight * s, minScreenSize.height);
        return OverflowBox(
          alignment: Alignment.center,
          minWidth: w / s,
          maxWidth: w / s,
          minHeight: h / s,
          maxHeight: h / s,
          child: Transform.scale(
            scale: 1 / s,
            alignment: Alignment.topLeft,
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: w,
              maxWidth: w,
              minHeight: h,
              maxHeight: h,
              child: child,
            ),
          ),
        );
      },
    );
  }
}
