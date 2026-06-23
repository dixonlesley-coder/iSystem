import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

/// A small, custom (non-Material) button following the iOS button hierarchy:
/// [primary] is a filled systemBlue button (white label, no border); the
/// default is a soft tinted-grey "gray button" (filled, borderless) that reads
/// as a chip/segment and lights to the accent tint on hover. Rounded to the
/// control radius with a brief scale-press for a tactile feel.
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
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;

    final Color bg;
    final Color fg;
    if (widget.primary) {
      bg = _down
          ? Color.lerp(colors.accent, const Color(0xFF000000), 0.12)!
          : colors.accent;
      fg = const Color(0xFFFFFFFF);
    } else {
      // iOS "gray button": a soft fill, no border; hover lifts to the accent
      // tint, press deepens it. The label stays the primary label colour.
      bg = _down
          ? colors.accentMuted
          : (_hover
              ? Color.lerp(colors.surfaceHover, colors.accentMuted, 0.5)!
              : colors.surfaceHover);
      fg = colors.textPrimary;
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: GestureDetector(
        onTap: widget.onPressed,
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        child: AnimatedScale(
          scale: _down ? 0.97 : 1.0,
          duration: MechXMotion.instant,
          curve: MechXMotion.standard,
          child: AnimatedContainer(
            duration: MechXMotion.fast,
            curve: MechXMotion.standard,
            padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.sm + 4,
              vertical: MechXSpacing.xs + 2,
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: MechXRadii.control,
            ),
            child: Text(
              widget.label,
              style: type.label.copyWith(
                color: fg,
                fontWeight: widget.primary ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
