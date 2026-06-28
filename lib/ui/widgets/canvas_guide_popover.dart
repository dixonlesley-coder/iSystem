import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'glass_surface.dart';

/// A small floating "(?)" affordance + its gesture-help popover, lifted from the
/// electrical canvas so the mechanical Layout canvas can advertise the same
/// right-click / drag gestures. Both canvases now share one component, so the
/// help affordance reads identically across the app.
///
/// Themed via MechXTheme (no Material). The popover is ephemeral — it shows only
/// while [open] and closes via [onClose]; nothing persists to the store, so the
/// idle canvas is byte-identical (the button is a small edge affordance the
/// goldens don't frame, and the popover only paints on demand).
class CanvasGuideButton extends StatelessWidget {
  final bool open;
  final VoidCallback onToggle;
  const CanvasGuideButton({
    super.key,
    required this.open,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onToggle,
        child: AnimatedContainer(
          duration: MechXMotion.hover,
          curve: MechXMotion.standard,
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: open ? colors.accent : colors.surface,
            shape: BoxShape.circle,
            border: Border.all(color: open ? colors.accent : colors.border),
          ),
          child: Text(
            '?',
            style: context.type.label.copyWith(
              color: open ? const Color(0xFFFFFFFF) : colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// The gesture-help popover: a titled card listing [items], with a Close affordance
/// that calls [onClose]. Parameterised so the electrical and mechanical canvases
/// can each supply their own discipline-scoped gesture list.
class CanvasGuideLegend extends StatelessWidget {
  final List<String> items;
  final VoidCallback onClose;
  final double width;
  const CanvasGuideLegend({
    super.key,
    required this.items,
    required this.onClose,
    this.width = 310,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    // Fade + slight scale-from-top-left on open, anchored to the (?) button.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: MechXMotion.appear,
      curve: MechXMotion.standard,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.scale(
          scale: 0.96 + 0.04 * t,
          alignment: Alignment.topLeft,
          child: child,
        ),
      ),
      child: SizedBox(
        width: width,
        child: GlassSurface(
          borderRadius: MechXRadii.card,
          blurSigma: MechXGlass.blurSigmaLight,
          shadow: MechXShadow.popover,
          child: Padding(
            padding: const EdgeInsets.all(MechXSpacing.md),
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Canvas guide',
                    style: type.subtitle.copyWith(color: colors.textPrimary),
                  ),
                ),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: onClose,
                    child: Text(
                      'Close',
                      style: type.label.copyWith(color: colors.textMuted),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: MechXSpacing.sm),
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 5,
                      height: 5,
                      margin: const EdgeInsets.only(
                        top: 6,
                        right: MechXSpacing.sm,
                      ),
                      decoration: BoxDecoration(
                        color: colors.accent,
                        borderRadius: const BorderRadius.all(
                          Radius.circular(3),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        item,
                        style: type.caption.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ],
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
