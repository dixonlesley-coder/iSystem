/// The shared selectable-SEGMENT vocabulary — one widget for the app-wide
/// "segmented control" selected look used by the electrical tabs, the enum/
/// option chips, and (optionally) the Layout layer switcher. It captures the
/// established selected-segment language in one place so the disciplines can
/// never drift:
///
///   * SELECTED   → an `accentMuted` fill + an `accent` hairline border + a
///                  `textPrimary` label (the strong signal).
///   * UNSELECTED → no fill at rest, lifting to `surfaceHover` on hover, with a
///                  `textSecondary` label and a transparent (layout-stable)
///                  border.
///
/// Keyboard focus + Enter/Space activate (via [MechXFocusRing]); a tap
/// compresses the segment slightly. Styled with MechXTheme — no Material.
library;

import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'mechx_focus_ring.dart';

/// One selectable segment carrying [label]; [selected] drives the tinted-fill
/// look. [selectedWeight] lets a call site keep its exact selected label weight
/// (tabs use the normal weight; chips bump to w600) without forking the style.
class MechXSegment extends StatefulWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// The label weight when [selected]. The unselected weight is always w500.
  final FontWeight selectedWeight;

  const MechXSegment({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.selectedWeight = FontWeight.w500,
  });

  @override
  State<MechXSegment> createState() => _MechXSegmentState();
}

class _MechXSegmentState extends State<MechXSegment> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final selected = widget.selected;
    // Calm rest: unselected = no decoration; it lifts to the soft fill only on
    // hover. Selected = the accent tint + a hairline accent border (the strong
    // signal). Hover colour animates and a press compresses the segment.
    final bg = selected
        ? colors.accentMuted
        : (_hover ? colors.surfaceHover : const Color(0x00000000));
    return MechXFocusRing(
      onActivated: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _down = false;
        }),
        child: GestureDetector(
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _down = true),
          onTapUp: (_) => setState(() => _down = false),
          onTapCancel: () => setState(() => _down = false),
          child: AnimatedScale(
            scale: _down ? 0.97 : 1.0,
            duration: MechXMotion.press,
            curve: MechXMotion.standard,
            child: AnimatedContainer(
              duration: MechXMotion.hover,
              curve: MechXMotion.standard,
              padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.sm + 2,
                vertical: MechXSpacing.xs + 2,
              ),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: MechXRadii.control,
                border: Border.all(
                  color: selected ? colors.accent : const Color(0x00000000),
                ),
              ),
              child: Text(
                widget.label,
                style: type.label.copyWith(
                  color: selected ? colors.textPrimary : colors.textSecondary,
                  fontWeight: selected ? widget.selectedWeight : FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
