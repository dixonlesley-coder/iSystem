import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

/// A small, custom (non-Material) text button with hover feedback.
class MechXButton extends StatefulWidget {
  final String label;
  final VoidCallback onPressed;
  final bool primary;

  const MechXButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  @override
  State<MechXButton> createState() => _MechXButtonState();
}

class _MechXButtonState extends State<MechXButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final bg = widget.primary
        ? colors.accent
        : (_hover ? colors.surfaceHover : const Color(0x00000000));
    final fg = widget.primary ? const Color(0xFFFFFFFF) : colors.textSecondary;
    final border = widget.primary ? colors.accent : colors.border;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: MechXMotion.fast,
          curve: MechXMotion.standard,
          padding: const EdgeInsets.symmetric(
            horizontal: MechXSpacing.sm + 2,
            vertical: MechXSpacing.xs + 1,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: MechXRadii.control,
            border: Border.all(color: border),
          ),
          child: Text(widget.label, style: type.label.copyWith(color: fg)),
        ),
      ),
    );
  }
}
