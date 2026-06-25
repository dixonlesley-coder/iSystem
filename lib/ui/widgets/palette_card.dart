import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'mechx_focus_ring.dart';

/// A draggable palette chip, shared by the mechanical (SegmentPalette) and the
/// electrical (ElectricalPalette) right-bar palettes so both read as one app:
/// a leading swatch dot + label, a soft hairline at rest that lifts to the
/// accent border + a drop shadow while dragging, a hover scale, and a keyboard
/// focus ring (the chip is drag-only, so the ring carries no Enter/Space action).
///
/// Generic over the drag payload [T] (PaletteItem / PaletteLoad). Set
/// [fillWidth] when the card sits in a full-width vertical list (the labels can
/// then ellipsize); leave it false for a compact [Wrap] of min-width chips.
class PaletteCard<T extends Object> extends StatefulWidget {
  final String label;
  final Color swatch;
  final T data;
  final BoxShape dotShape;
  final bool dotHollow;
  final bool fillWidth;

  /// An optional leading visual that replaces the swatch dot (e.g. a schematic
  /// load symbol). When null, the [swatch] dot is shown.
  final Widget? leading;

  const PaletteCard({
    super.key,
    required this.label,
    required this.swatch,
    required this.data,
    this.dotShape = BoxShape.circle,
    this.dotHollow = false,
    this.fillWidth = false,
    this.leading,
  });

  @override
  State<PaletteCard<T>> createState() => _PaletteCardState<T>();
}

class _PaletteCardState<T extends Object> extends State<PaletteCard<T>> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final chip = _chip(context, dragging: false, fill: widget.fillWidth);
    return MechXFocusRing(
      child: Draggable<T>(
        data: widget.data,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        // The drag feedback is ALWAYS compact (min-width): the Overlay lays the
        // feedback out under loose constraints, where a fillWidth Row(max)+
        // Expanded would balloon to the full width (and can trip the RenderFlex
        // unbounded assertion). The chip hugs its content while it follows the
        // cursor, regardless of the in-list fillWidth.
        feedback: _chip(context, dragging: true, fill: false),
        childWhenDragging: Opacity(opacity: 0.4, child: chip),
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: AnimatedScale(
            scale: _hover ? 1.03 : 1.0,
            duration: MechXMotion.hover,
            curve: MechXMotion.standard,
            child: chip,
          ),
        ),
      ),
    );
  }

  Widget _chip(
    BuildContext context, {
    required bool dragging,
    required bool fill,
  }) {
    final colors = context.colors;
    final type = context.type;
    final label = Text(
      widget.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: type.label.copyWith(color: colors.textSecondary),
    );
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MechXSpacing.sm,
        vertical: MechXSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: dragging ? colors.surfaceHover : colors.background,
        borderRadius: MechXRadii.control,
        border: Border.all(color: dragging ? colors.accent : colors.border),
        boxShadow: dragging
            ? const [
                BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 10,
                    offset: Offset(0, 3)),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
        children: [
          widget.leading ??
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: widget.dotHollow
                      ? const Color(0x00000000)
                      : widget.swatch,
                  shape: widget.dotShape,
                  borderRadius: widget.dotShape == BoxShape.rectangle
                      ? const BorderRadius.all(Radius.circular(2))
                      : null,
                  border: widget.dotHollow
                      ? Border.all(color: widget.swatch, width: 1.5)
                      : null,
                ),
              ),
          const SizedBox(width: MechXSpacing.xs),
          // In a full-width list the label flexes (ellipsis on overflow); the
          // compact (feedback / Wrap) form hugs its content.
          if (fill) Expanded(child: label) else label,
        ],
      ),
    );
  }
}
