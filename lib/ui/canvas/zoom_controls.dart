import 'package:flutter/widgets.dart';

import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/glass_surface.dart';
import '../widgets/mechx_focus_ring.dart';
import '../widgets/mechx_tooltip.dart';

/// The on-canvas zoom cluster (+ / − / fit) shared by BOTH the mechanical and
/// electrical canvases, so the two workspaces present one zoom affordance. A
/// grouped, hairline-bordered, rounded pill (iOS map-style): each segment is
/// transparent at rest and lifts to the soft fill on hover, divided by
/// hairline separators.
class ZoomControls extends StatelessWidget {
  final VoidCallback onIn;
  final VoidCallback onOut;
  final VoidCallback onFit;

  const ZoomControls({
    super.key,
    required this.onIn,
    required this.onOut,
    required this.onFit,
  });

  @override
  Widget build(BuildContext context) {
    // Liquid-Glass zoom cluster — a translucent blurred pill floating over the
    // canvas (iOS map-style), lifted by the card shadow.
    final strings = context.strings;
    return GlassSurface(
      borderRadius: MechXRadii.control,
      blurSigma: MechXGlass.blurSigmaLight,
      shadow: MechXShadow.card,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // L5/M4: each glyph is otherwise unlabeled icon-only chrome — a
          // hover tooltip names the action for a sighted mouse user.
          MechXTooltip(
            message: strings(StringKey.tooltipZoomIn),
            child: _IconBtn(glyph: '+', onTap: onIn),
          ),
          _Sep(),
          MechXTooltip(
            message: strings(StringKey.tooltipZoomOut),
            child: _IconBtn(glyph: '-', onTap: onOut),
          ),
          _Sep(),
          MechXTooltip(
            message: strings(StringKey.tooltipZoomFit),
            child: _IconBtn(glyph: 'fit', onTap: onFit),
          ),
        ],
      ),
    );
  }
}

class _Sep extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 22, color: context.colors.border);
}

class _IconBtn extends StatefulWidget {
  final String glyph;
  final VoidCallback onTap;
  const _IconBtn({required this.glyph, required this.onTap});

  @override
  State<_IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<_IconBtn> {
  bool _hover = false;
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
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
              width: widget.glyph.length > 1 ? 34 : 28,
              height: 28,
              alignment: Alignment.center,
              color: _hover ? colors.surfaceHover : const Color(0x00000000),
              child: Text(
                widget.glyph,
                style: context.type.label.copyWith(color: colors.textSecondary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
