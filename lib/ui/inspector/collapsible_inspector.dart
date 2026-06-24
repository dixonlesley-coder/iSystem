import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/inspector_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_focus_ring.dart';

/// Wraps a right-side inspector ([child]) with a collapse/expand affordance so
/// the canvas can become the focal point. A slim vertical toggle strip (a
/// chevron, custom-painted so it never renders as tofu) sits at the inspector's
/// left edge; tapping it flips [inspectorCollapsedProvider].
///
/// Expanded: the strip + the [child] at its natural [expandedWidth].
/// Collapsed: just the [collapsedWidth] strip — the canvas reclaims the rest.
/// The width animates smoothly (and the body cross-fades) so the transition
/// orients without churn.
class CollapsibleInspector extends ConsumerWidget {
  final Widget child;
  final double expandedWidth;

  const CollapsibleInspector({
    super.key,
    required this.child,
    required this.expandedWidth,
  });

  /// The thin strip shown when collapsed (just wide enough for the toggle).
  static const double collapsedWidth = 36;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final collapsed = ref.watch(inspectorCollapsedProvider);
    // strip + hairline border + body when expanded; just the strip collapsed.
    final width =
        collapsed ? collapsedWidth : expandedWidth + collapsedWidth + 1;

    return AnimatedContainer(
      duration: MechXMotion.medium,
      curve: MechXMotion.emphasized,
      width: width,
      color: colors.surface,
      // ClipRect so the body slides out (rather than overflowing) while the
      // container width animates between collapsed and expanded.
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.centerLeft,
          minWidth: 0,
          // strip + hairline border + body.
          maxWidth: expandedWidth + CollapsibleInspector.collapsedWidth + 1,
          child: Row(
            children: [
              _ToggleStrip(
                collapsed: collapsed,
                onTap: () =>
                    ref.read(inspectorCollapsedProvider.notifier).toggle(),
              ),
              Container(width: 1, color: colors.border),
              // The panel body, held at its natural width during the animation.
              // It cross-fades alongside the width so the collapse feels unified
              // (the content dissolves rather than abruptly clipping out).
              SizedBox(
                width: expandedWidth,
                child: AnimatedOpacity(
                  opacity: collapsed ? 0 : 1,
                  duration: MechXMotion.appear,
                  curve: MechXMotion.standard,
                  child: child,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The slim vertical strip carrying the collapse/expand chevron. Hover-lit,
/// iOS-styled. Shows a left-chevron when expanded ("collapse →| edge"), a
/// right-chevron when collapsed ("expand the panel back out").
class _ToggleStrip extends StatefulWidget {
  final bool collapsed;
  final VoidCallback onTap;

  const _ToggleStrip({required this.collapsed, required this.onTap});

  @override
  State<_ToggleStrip> createState() => _ToggleStripState();
}

class _ToggleStripState extends State<_ToggleStrip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final fg = _hover ? colors.accent : colors.textMuted;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: MechXFocusRing(
        onActivated: widget.onTap,
        borderRadius: MechXRadii.control,
        child: GestureDetector(
          onTap: widget.onTap,
          child: Semantics(
            button: true,
            label: widget.collapsed ? 'Expand inspector' : 'Collapse inspector',
            child: AnimatedContainer(
              duration: MechXMotion.hover,
              curve: MechXMotion.standard,
              width: CollapsibleInspector.collapsedWidth,
              color: _hover ? colors.surfaceHover : const Color(0x00000000),
              alignment: Alignment.topCenter,
              padding: const EdgeInsets.symmetric(vertical: MechXSpacing.sm),
              // The chevron points left while expanded ("collapse it away"),
              // and rotates a half-turn to point right when collapsed ("open it
              // back out"). Rotating — rather than swapping a painter — reads as
              // one continuous motion. (Expanded is the half-turn so the at-rest
              // direction matches the prior left-pointing painter exactly.)
              child: AnimatedRotation(
                turns: widget.collapsed ? 0.0 : 0.5,
                duration: MechXMotion.appear,
                curve: MechXMotion.standard,
                child: CustomPaint(
                  size: const Size(18, 18),
                  painter: _ChevronPainter(color: fg),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A single right-pointing chevron drawn from primitives (no glyph font, so
/// never tofu). Direction is handled by the caller's [AnimatedRotation].
class _ChevronPainter extends CustomPainter {
  final Color color;

  _ChevronPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.40, h * 0.24)
      ..lineTo(w * 0.66, h * 0.50)
      ..lineTo(w * 0.40, h * 0.76);
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(_ChevronPainter old) => old.color != color;
}
