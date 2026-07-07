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

  /// L4 (a11y): an explicit accessible name for the wrapped control. Supply this
  /// ONLY for icon/glyph-only controls whose [child] carries no readable text
  /// (a stepper `−`/`+`, a lock/eye toggle, a zoom glyph); a control whose child
  /// already renders its own label must leave this null so the label isn't
  /// announced twice. Default null ⇒ existing callers are unchanged.
  final String? semanticLabel;

  const MechXFocusRing({
    super.key,
    required this.child,
    this.onActivated,
    this.borderRadius = MechXRadii.control,
    this.enabled = true,
    this.semanticLabel,
  });

  @override
  State<MechXFocusRing> createState() => _MechXFocusRingState();
}

class _MechXFocusRingState extends State<MechXFocusRing> {
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final Widget ring = FocusableActionDetector(
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

    // I7 / L4 (a11y): when this ring wraps an activatable control ([onActivated]
    // set), mark it as a button and expose a tap action so a screen reader
    // announces the role + can activate it. The wrapped [child] supplies the
    // accessible label from its own text; [semanticLabel] supplies one for an
    // icon/glyph-only child that has none. When neither is set it stays a plain
    // focus ring. Semantics is layout/paint-transparent ⇒ goldens unchanged.
    if (widget.onActivated == null && widget.semanticLabel == null) return ring;
    return Semantics(
      button: widget.onActivated != null,
      label: widget.semanticLabel,
      enabled: widget.enabled,
      onTap: widget.enabled ? widget.onActivated : null,
      child: ring,
    );
  }
}
