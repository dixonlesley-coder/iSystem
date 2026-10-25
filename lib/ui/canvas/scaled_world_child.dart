/// One WORLD-sized child drawn on a screen-space canvas: laid out at its
/// natural world-px size, then scaled to fill the (already-scaled) box its
/// caller positions — shared by the electrical single-line cards and the
/// electrical markers on the Layout plan (E1), so both surfaces hit-test the
/// whole painted node at every zoom.
library;

import 'package:flutter/widgets.dart';

/// Lays [child] out at its natural world-px size ([width] x [height]) and
/// scales it to fill the box it is given (which the caller sizes to
/// `width * scale` x `height * scale`, so both axes scale by exactly `scale` —
/// the paint is identical to a `Transform.scale`).
///
/// Implemented with a [FittedBox] rather than `Transform.scale` + `OverflowBox`
/// because HIT TESTING has to survive the scale. `RenderBox.hitTest` refuses any
/// position outside the box's OWN size, and an `OverflowBox` under tight
/// constraints is sized to the SCALED box while its child is laid out at the
/// natural size — so below 1x only the top-left `scale` fraction of the node
/// took pointers (and above 1x nothing outside the natural box did). [FittedBox]
/// carries a real paint transform that `hitTestChildren` inverts, so the whole
/// painted node is live at every zoom. `clipBehavior` stays [Clip.none] (the
/// default) so a node may still paint outside its box (a hover lift).
class ScaledWorldChild extends StatelessWidget {
  final double width;
  final double height;
  final Widget child;

  const ScaledWorldChild({
    super.key,
    required this.width,
    required this.height,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.fill,
      alignment: Alignment.topLeft,
      child: SizedBox(width: width, height: height, child: child),
    );
  }
}
