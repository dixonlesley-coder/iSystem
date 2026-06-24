import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

/// A small, custom (non-Material) button following the iOS button hierarchy:
/// [primary] is a filled systemBlue button (white label, no border); [tertiary]
/// is a plain/borderless text button (label in the accent, faint tint on hover);
/// the default is a soft tinted-grey "gray button" (filled, borderless) that
/// reads as a chip/segment and lights to the accent tint on hover. Rounded to
/// the control radius with a brief scale-press for a tactile feel, a subtle
/// hover lift, a disabled state (pass a null [onPressed]), and a keyboard focus
/// ring (drawn as a spread shadow so it never shifts layout).
class MechXButton extends StatefulWidget {
  final String label;

  /// Tap handler. Pass `null` to render the disabled state (dimmed, no hover/
  /// press feedback, not focusable, not tappable).
  final VoidCallback? onPressed;
  final bool primary;
  final bool tertiary;

  const MechXButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.tertiary = false,
  });

  @override
  State<MechXButton> createState() => _MechXButtonState();
}

class _MechXButtonState extends State<MechXButton> {
  bool _hover = false;
  bool _down = false;
  bool _focus = false;

  bool get _enabled => widget.onPressed != null;

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
    } else if (widget.tertiary) {
      // Plain/borderless: transparent at rest, a faint tint on hover/press.
      bg = _down
          ? colors.accentMuted
          : (_hover ? colors.surfaceHover : const Color(0x00000000));
      fg = colors.accent;
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

    final scale = _down ? 0.97 : (_hover ? 0.98 : 1.0);

    Widget visual = AnimatedScale(
      scale: _enabled ? scale : 1.0,
      duration: MechXMotion.press,
      curve: MechXMotion.standard,
      child: AnimatedContainer(
        duration: MechXMotion.hover,
        curve: MechXMotion.standard,
        padding: const EdgeInsets.symmetric(
          horizontal: MechXSpacing.sm + 4,
          vertical: MechXSpacing.xs + 2,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: MechXRadii.control,
          // Keyboard focus ring — a spread shadow, so layout never shifts.
          boxShadow: _focus
              ? [
                  BoxShadow(
                    color: colors.accent.withAlpha(140),
                    blurRadius: 0,
                    spreadRadius: 2.5,
                  ),
                ]
              : null,
        ),
        child: Text(
          widget.label,
          style: type.label.copyWith(
            color: fg,
            fontWeight: widget.primary ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );

    if (!_enabled) {
      return Opacity(opacity: 0.4, child: visual);
    }

    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (v) => setState(() {
        _hover = v;
        if (!v) _down = false;
      }),
      onShowFocusHighlight: (v) => setState(() => _focus = v),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onPressed?.call();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onPressed,
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        child: visual,
      ),
    );
  }
}
