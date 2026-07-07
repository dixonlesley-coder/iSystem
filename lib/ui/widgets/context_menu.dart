/// Shared right-click context-menu chrome — ONE visual language for every
/// floating menu in the app (the mechanical edge/fitting menus and the
/// electrical panel/circuit menus). Styled with MechXTheme — no Material.
///
/// The mechanical menu is the richer of the two, so its affordances are the
/// superset captured here: a [MechXContextMenu] panel (rounded surface, soft
/// shadow, hairline border, grow-from-top-left entrance) hosting any of
/// [MechXMenuHeader] (section caption), [MechXMenuNote] (quiet derived note),
/// [MechXMenuDivider], and [MechXMenuRow] (with optional `selected`/`danger`/
/// `muted`/`mono` variants). The electrical menu uses the plain-row subset.
library;

import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'glass_surface.dart';
import 'mechx_focus_ring.dart';

/// A one-shot menu entrance: scales from ~0.92 -> 1.0 and fades 0 -> 1 over
/// [MechXMotion.appear], anchored top-left so the menu grows out of the click
/// point. Transient — the menu settles at its natural size/opacity, so nothing
/// changes at rest.
class MechXMenuEntrance extends StatelessWidget {
  final Widget child;
  const MechXMenuEntrance({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: MechXMotion.appear,
      curve: MechXMotion.emphasized,
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.scale(
          scale: 0.92 + 0.08 * t,
          alignment: Alignment.topLeft,
          child: child,
        ),
      ),
    );
  }
}

/// The floating menu panel: a rounded surface card with a soft shadow + hairline
/// border, clipped, growing out of the click point via [MechXMenuEntrance].
/// Wrap a column of [MechXMenuRow]/[MechXMenuHeader]/[MechXMenuDivider]/
/// [MechXMenuNote] children. When [scrollable] the body scrolls (used when the
/// menu can be tall, e.g. a long size ladder).
class MechXContextMenu extends StatelessWidget {
  final List<Widget> children;
  final bool scrollable;

  const MechXContextMenu({
    super.key,
    required this.children,
    this.scrollable = false,
  });

  @override
  Widget build(BuildContext context) {
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
    // Liquid-Glass popover: a translucent blurred card that floats over the
    // canvas/diagram, rimmed on all sides and lifted by the popover shadow.
    return MechXMenuEntrance(
      child: GlassSurface(
        borderRadius: MechXRadii.card,
        blurSigma: MechXGlass.blurSigmaLight,
        shadow: MechXShadow.popover,
        child: scrollable
            ? SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xs),
                child: column,
              )
            : Padding(
                padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xs),
                child: column,
              ),
      ),
    );
  }
}

/// A small all-caps section caption inside a menu.
class MechXMenuHeader extends StatelessWidget {
  final String text;
  const MechXMenuHeader(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          MechXSpacing.sm + 2,
          MechXSpacing.xs,
          MechXSpacing.sm,
          MechXSpacing.xxs,
        ),
        child: Text(
          text.toUpperCase(),
          style: context.type.caption.copyWith(
            color: context.colors.textMuted,
            letterSpacing: 0.7,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

/// A quiet derived note line (e.g. a takeoff summary) inside a menu.
class MechXMenuNote extends StatelessWidget {
  final String text;
  const MechXMenuNote(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          MechXSpacing.sm + 2,
          MechXSpacing.xxs,
          MechXSpacing.sm,
          MechXSpacing.xs,
        ),
        child: Text(
          text,
          style: context.type.caption
              .copyWith(color: context.colors.textSecondary),
        ),
      );
}

/// A hairline separator between menu sections.
class MechXMenuDivider extends StatelessWidget {
  const MechXMenuDivider({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs),
        child: Container(height: 1, color: context.colors.border),
      );
}

/// A single tappable menu row with hover fill. Variants:
///   • [selected] — bold label + a trailing accent dot.
///   • [danger]   — destructive (delete) tint.
///   • [muted]    — a quiet secondary action (e.g. "Clear override").
///   • [mono]     — monospaced label (size ladders).
class MechXMenuRow extends StatefulWidget {
  final String label;
  final bool selected;
  final bool danger;
  final bool muted;
  final bool mono;
  final VoidCallback onTap;

  const MechXMenuRow({
    super.key,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.danger = false,
    this.muted = false,
    this.mono = false,
  });

  @override
  State<MechXMenuRow> createState() => _MechXMenuRowState();
}

class _MechXMenuRowState extends State<MechXMenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final Color fg = widget.danger
        ? colors.danger
        : widget.muted
            ? colors.textMuted
            : colors.textPrimary;
    // L3: this is the ONE shared row every mechanical AND electrical
    // right-click context menu renders — wrap it in the shared focus ring so
    // Tab reaches a menu entry and Enter/Space fires it, matching every other
    // interactive control's keyboard idiom.
    return MechXFocusRing(
      onActivated: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: MechXMotion.hover,
            curve: MechXMotion.standard,
            color: _hover ? colors.surfaceHover : const Color(0x00000000),
            padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.sm + 2,
              vertical: MechXSpacing.xs + 1,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.label,
                    style: (widget.mono ? type.mono : type.label).copyWith(
                      color: fg,
                      fontWeight: widget.selected ? FontWeight.w700 : null,
                    ),
                  ),
                ),
                if (widget.selected)
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: colors.accent,
                      borderRadius: MechXRadii.small,
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
