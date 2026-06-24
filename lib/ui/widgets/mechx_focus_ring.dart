import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

/// Wraps an interactive [child] with keyboard focus + an animated focus ring,
/// for the app's bespoke controls (pills, glyph/stepper buttons, nav items,
/// chips) that aren't [MechXButton]. The ring is a spread shadow so it never
/// shifts layout, and shows only for keyboard-driven focus (a mouse click does
/// not raise it, matching macOS/iOS). Provide [onActivated] so Enter/Space fire
/// the control like a real button.
class MechXFocusRing extends StatefulWidget {
  final Widget child;
  final VoidCallback? onActivated;
  final BorderRadius borderRadius;
  final bool enabled;

  const MechXFocusRing({
    super.key,
    required this.child,
    this.onActivated,
    this.borderRadius = MechXRadii.control,
    this.enabled = true,
  });

  @override
  State<MechXFocusRing> createState() => _MechXFocusRingState();
}

class _MechXFocusRingState extends State<MechXFocusRing> {
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return FocusableActionDetector(
      enabled: widget.enabled,
      onShowFocusHighlight: (v) => setState(() => _focus = v && widget.enabled),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onActivated?.call();
            return null;
          },
        ),
      },
      child: AnimatedContainer(
        duration: MechXMotion.hover,
        curve: MechXMotion.standard,
        decoration: BoxDecoration(
          borderRadius: widget.borderRadius,
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
        child: widget.child,
      ),
    );
  }
}
