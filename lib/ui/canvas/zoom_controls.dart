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

  /// Optional live zoom read-out (e.g. '57%'), shown as a tappable mono label
  /// between '-' and '+'. Omitted (null) on canvases that cannot read their
  /// scale truthfully — absence is the honest state.
  final String? percentLabel;

  /// Called when the [percentLabel] is tapped — resets the view to 100%.
  /// Null ⇒ the read-out is rendered NON-interactive (a plain label: no
  /// tooltip, focus stop, click cursor or hover lift) rather than a button that
  /// does nothing when pressed.
  final VoidCallback? onResetZoom;

  const ZoomControls({
    super.key,
    required this.onIn,
    required this.onOut,
    required this.onFit,
    this.percentLabel,
    this.onResetZoom,
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
          // L5/M4: each glyph is otherwise unlabeled icon-only chrome — a hover
          // tooltip names the action for a sighted mouse user; L4: the same
          // caption names the button for a screen reader. The accessible label
          // is put on the button's own focus-ring node (with the glyph excluded
          // from semantics), NOT on a second Semantics node here — the inner
          // MechXFocusRing already emits the button node, so wrapping it in
          // another labelled Semantics would double-announce (name + glyph).
          MechXTooltip(
            message: strings(StringKey.tooltipZoomIn),
            child: _IconBtn(
              glyph: '+',
              onTap: onIn,
              semanticLabel: strings(StringKey.tooltipZoomIn),
            ),
          ),
          _Sep(),
          MechXTooltip(
            message: strings(StringKey.tooltipZoomOut),
            child: _IconBtn(
              glyph: '-',
              onTap: onOut,
              semanticLabel: strings(StringKey.tooltipZoomOut),
            ),
          ),
          // Work item 9: the zoom read-out lives HERE (moved off the top bar),
          // beside the controls that change it; tapping it resets to 100%.
          if (percentLabel != null) ...[
            _Sep(),
            if (onResetZoom != null)
              MechXTooltip(
                message: strings(StringKey.tooltipZoomReset),
                child: _IconBtn(
                  key: const ValueKey('zoom-percent'),
                  glyph: percentLabel!,
                  mono: true,
                  onTap: onResetZoom!,
                  semanticLabel: strings(StringKey.tooltipZoomReset),
                ),
              )
            else
              _Readout(
                key: const ValueKey('zoom-percent'),
                text: percentLabel!,
              ),
          ],
          _Sep(),
          MechXTooltip(
            message: strings(StringKey.tooltipZoomFit),
            child: _IconBtn(
              glyph: 'fit',
              onTap: onFit,
              semanticLabel: strings(StringKey.tooltipZoomFit),
            ),
          ),
        ],
      ),
    );
  }
}

/// The zoom read-out when nothing resets the view: the same footprint and
/// tabular mono face as the tappable read-out at rest, but a plain label.
class _Readout extends StatelessWidget {
  final String text;
  const _Readout({super.key, required this.text});

  @override
  Widget build(BuildContext context) => Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: MechXSpacing.sm),
        alignment: Alignment.center,
        child: Text(
          text,
          style: MechXTypography.tabular(
              context.type.mono.copyWith(color: context.colors.textSecondary)),
        ),
      );
}

class _Sep extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 22, color: context.colors.border);
}

class _IconBtn extends StatefulWidget {
  final String glyph;
  final VoidCallback onTap;

  /// L4 (a11y): the button's accessible name; the decorative glyph is hidden
  /// from semantics so only this reads out (mirrors `_StepperGlyphButton`).
  final String? semanticLabel;

  /// Render the glyph in the tabular mono face (the zoom % read-out).
  final bool mono;
  const _IconBtn({
    super.key,
    required this.glyph,
    this.mono = false,
    required this.onTap,
    this.semanticLabel,
  });

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
      semanticLabel: widget.semanticLabel,
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
              width: widget.mono
                  ? null
                  : (widget.glyph.length > 1 ? 34 : 28),
              padding: widget.mono
                  ? const EdgeInsets.symmetric(horizontal: MechXSpacing.sm)
                  : null,
              height: 28,
              alignment: Alignment.center,
              color: _hover ? colors.surfaceHover : const Color(0x00000000),
              child: ExcludeSemantics(
                // Decorative once the button carries a real label — hide it so
                // a screen reader announces "Zoom in", not "plus".
                child: Text(
                  widget.glyph,
                  style: widget.mono
                      ? MechXTypography.tabular(context.type.mono
                          .copyWith(color: colors.textSecondary))
                      : context.type.label
                          .copyWith(color: colors.textSecondary),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
