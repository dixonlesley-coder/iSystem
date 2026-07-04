import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/inspector_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_focus_ring.dart';
import '../widgets/section_label.dart';

/// A collapsible inspector section: a tappable [MechXSectionLabel]-styled header
/// carrying a chevron (custom-painted, so never tofu in goldens) that toggles
/// whether [child] is shown. Expansion state lives in [sectionVisibilityProvider]
/// keyed by [name] — transient UI state, not persisted to `.mechx`.
///
/// [defaultExpanded] seeds the initial state the first time [name] is seen (so a
/// section with active results can open itself, an empty one can stay closed)
/// without overriding a user's later toggle.
///
/// The header replaces the section's own `MechXSectionLabel`, so wrapped sections
/// must NOT also render their own label.
class DisclosureSection extends ConsumerWidget {
  final String name;
  final bool defaultExpanded;
  final Widget child;

  const DisclosureSection({
    super.key,
    required this.name,
    required this.child,
    this.defaultExpanded = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded =
        ref.watch(sectionExpandedProvider(SectionKey(name, defaultExpanded)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DisclosureHeaderBar(
          label: name,
          expanded: expanded,
          onTap: () => ref
              .read(sectionVisibilityProvider.notifier)
              .toggle(name, defaultExpanded),
        ),
        // Disclose the body only when expanded. Sized-out (not faded) when
        // collapsed so the panel stays compact and the canvas dominates.
        if (expanded) ...[
          const SizedBox(height: MechXSpacing.sm),
          child,
        ],
      ],
    );
  }
}

/// The tappable header row: the uppercase section label plus a rotating chevron.
class _DisclosureHeaderBar extends StatefulWidget {
  final String label;
  final bool expanded;
  final VoidCallback onTap;

  const _DisclosureHeaderBar({
    required this.label,
    required this.expanded,
    required this.onTap,
  });

  @override
  State<_DisclosureHeaderBar> createState() => _DisclosureHeaderBarState();
}

class _DisclosureHeaderBarState extends State<_DisclosureHeaderBar> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // F3: the chevron pairs with the (now AA-legible) structural section label,
    // so its rest tint tracks the label at `textSecondary` rather than the
    // sub-AA `textMuted`; hover still lifts to the accent.
    final fg = _hover ? colors.accent : colors.textSecondary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: MechXFocusRing(
        onActivated: widget.onTap,
        borderRadius: MechXRadii.control,
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Semantics(
            button: true,
            container: true,
            excludeSemantics: true,
            label: widget.expanded
                ? 'Collapse ${widget.label} section'
                : 'Expand ${widget.label} section',
            child: Row(
              children: [
                Expanded(child: MechXSectionLabel(widget.label)),
                // Down-chevron when expanded ("collapse"), right-chevron when
                // collapsed ("expand") — a quarter-turn rotation reads as one
                // continuous motion. Reuses the proven golden-stable painter.
                AnimatedRotation(
                  turns: widget.expanded ? 0.25 : 0.0,
                  duration: MechXMotion.appear,
                  curve: MechXMotion.standard,
                  child: CustomPaint(
                    size: const Size(14, 14),
                    painter: _DisclosureChevronPainter(color: fg),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A single right-pointing chevron drawn from primitives (no glyph font, so
/// never tofu). The caller's [AnimatedRotation] turns it down when expanded.
class _DisclosureChevronPainter extends CustomPainter {
  final Color color;

  _DisclosureChevronPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
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
  bool shouldRepaint(_DisclosureChevronPainter old) => old.color != color;
}
