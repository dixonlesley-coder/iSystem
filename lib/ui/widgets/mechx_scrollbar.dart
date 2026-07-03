import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

/// A themed scroll indicator built on [RawScrollbar] — plain `package:flutter/
/// widgets.dart`, NOT Material's `Scrollbar` (§8 custom design system). Wrap any
/// scroll view (a [SingleChildScrollView] / [ListView] / …) so that content
/// below the fold is discoverable on this mouse-driven desktop app (J1).
///
/// Byte-identical AT REST: with the default [thumbVisibility] `false` the thumb
/// only fades in while the wheel / drag is actively scrolling and fades back out
/// after — on a static frame (goldens) nothing is painted, so wrapping an
/// existing scrollable does not shift a screenshot. Keep it `false` unless a
/// persistent thumb is genuinely wanted (that WILL change goldens).
///
/// Pass a [controller] — the SAME [ScrollController] the wrapped scroll view
/// uses — to make the thumb draggable. Without one the thumb still appears as an
/// indicator (driven by the child's scroll notifications), it just isn't
/// grabbable. Styling comes entirely from [MechXColors] / [MechXRadii].
class MechXScrollbar extends StatelessWidget {
  /// The scroll view to wrap. Its notifications drive the thumb.
  final Widget child;

  /// The wrapped scroll view's controller. Supply it (shared with the child) to
  /// enable thumb dragging; null ⇒ indicator-only (still fades in on scroll).
  final ScrollController? controller;

  /// Keep the thumb permanently visible. Defaults to `false` so the at-rest
  /// frame is byte-identical. Requires a non-null [controller] when `true`.
  final bool thumbVisibility;

  /// Thumb thickness in logical pixels.
  final double thickness;

  const MechXScrollbar({
    super.key,
    required this.child,
    this.controller,
    this.thumbVisibility = false,
    this.thickness = 6,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return RawScrollbar(
      controller: controller,
      thumbVisibility: thumbVisibility,
      // The thumb is a quiet, semi-transparent grey pill that reads in both
      // light and dark; the fade animation multiplies this by opacity, so it is
      // invisible when idle.
      thumbColor: colors.textMuted.withAlpha(140),
      radius: MechXRadii.sm,
      thickness: thickness,
      // Draggable when a controller is resolvable; a no-op otherwise (no assert).
      interactive: true,
      // Inset the thumb slightly from the content edge + the track ends so it
      // reads as a floating indicator, not a hard rail flush to the border.
      crossAxisMargin: 2,
      mainAxisMargin: 4,
      child: child,
    );
  }
}
