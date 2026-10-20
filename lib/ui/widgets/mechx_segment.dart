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

  /// Size the label for its SELECTED weight even while unselected (a hidden
  /// [selectedWeight] copy reserves the width), so a row of segments whose
  /// selected weight is heavier never changes width as the selection moves —
  /// nothing beside it jumps. Default false ⇒ unchanged layout.
  final bool reserveSelectedWidth;

  const MechXSegment({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.selectedWeight = FontWeight.w500,
    this.reserveSelectedWidth = false,
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
            duration: MechXMotion.resolve(context, MechXMotion.press),
            curve: MechXMotion.standard,
            child: AnimatedContainer(
              duration: MechXMotion.resolve(context, MechXMotion.hover),
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
              child: _label(type, colors, selected),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(MechXTypography type, MechXColors colors, bool selected) {
    final style = type.label.copyWith(
      color: selected ? colors.textPrimary : colors.textSecondary,
      fontWeight: selected ? widget.selectedWeight : FontWeight.w500,
    );
    if (!widget.reserveSelectedWidth) return Text(widget.label, style: style);
    // Measure the label at the SELECTED weight and give the visible label at
    // least that width (centred), so the segment is one width in both states.
    final bold = TextPainter(
      text: TextSpan(
          text: widget.label,
          style: type.label.copyWith(fontWeight: widget.selectedWeight)),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling,
      maxLines: 1,
    )..layout();
    final minWidth = bold.width.ceilToDouble();
    bold.dispose();
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: minWidth),
      child: Text(widget.label, style: style, textAlign: TextAlign.center),
    );
  }
}
