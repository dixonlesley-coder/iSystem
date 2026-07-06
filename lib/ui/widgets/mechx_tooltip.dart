import 'dart:async';

import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

/// Which side of the wrapped control the bubble appears on. `bottom` suits a
/// horizontal control (a button in a top bar / toolbar); `right` suits a
/// control sitting in a narrow VERTICAL rail (sheet rail, nav rail) where a
/// bubble below would be cramped against neighbouring rows.
enum MechXTooltipEdge { bottom, right }

/// L5/M4 — a small, MechXTheme-styled hover tooltip for icon-only chrome (the
/// theme toggle, the zoom +/-/fit cluster, the inspector/nav-rail collapse
/// chevrons, the sheet-rail calibration dot, the canvas "?" guide button) —
/// anywhere a glyph-only control carries no on-screen caption. Deliberately
/// NOT `package:material`'s `Tooltip` (the design system forbids Material);
/// this generalises the bubble pattern already proven by the nav rail's
/// collapsed-item label (`nav_rail.dart` `_CollapsedLabelTooltip`) into one
/// small reusable widget any icon-only control can wrap itself in.
///
/// The bubble appears only after [waitDuration] of continuous hover (the
/// ~600 ms Windows/macOS convention) and disappears immediately the pointer
/// leaves — so a quick mouse pass-over never flashes it. It exists only while
/// hovered (an ephemeral overlay entry), so the at-rest widget tree — and
/// every idle golden screenshot — is byte-identical to before this widget
/// wrapped the control.
class MechXTooltip extends StatefulWidget {
  /// The already-localized caption shown in the bubble.
  final String message;
  final Widget child;
  final MechXTooltipEdge edge;
  final Duration waitDuration;

  /// L4 (a11y): when non-null, the wrapped icon-only control is also exposed to
  /// a screen reader as a labelled button — so the same name the hover bubble
  /// shows a sighted mouse user is announced to an assistive one (the visual
  /// tooltip alone is invisible to a screen reader). Pass the control's own name
  /// (commonly the same string as [message]). Default null ⇒ no Semantics node
  /// is added, so a control that already carries its own label (e.g. the theme
  /// toggle) is unchanged and never double-announced. Semantics is
  /// layout/paint-transparent ⇒ goldens are unaffected either way.
  final String? semanticLabel;

  const MechXTooltip({
    super.key,
    required this.message,
    required this.child,
    this.edge = MechXTooltipEdge.bottom,
    this.waitDuration = const Duration(milliseconds: 600),
    this.semanticLabel,
  });

  @override
  State<MechXTooltip> createState() => _MechXTooltipState();
}

class _MechXTooltipState extends State<MechXTooltip> {
  final OverlayPortalController _controller = OverlayPortalController();
  final LayerLink _link = LayerLink();
  Timer? _timer;

  void _scheduleShow() {
    _timer?.cancel();
    _timer = Timer(widget.waitDuration, () {
      if (mounted) _controller.show();
    });
  }

  void _hide() {
    _timer?.cancel();
    if (_controller.isShowing) _controller.hide();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget content = MouseRegion(
      onEnter: (_) => _scheduleShow(),
      onExit: (_) => _hide(),
      child: OverlayPortal(
        controller: _controller,
        overlayChildBuilder: (context) => _MechXTooltipBubble(
          message: widget.message,
          link: _link,
          edge: widget.edge,
        ),
        child: CompositedTransformTarget(link: _link, child: widget.child),
      ),
    );
    if (widget.semanticLabel == null) return content;
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: content,
    );
  }
}

/// The floating bubble itself — a small opaque MechXTheme card (hairline
/// border + popover shadow, matching every other transient popover in the
/// app), positioned relative to the hovered control via a [LayerLink].
/// Pointer-transparent so it never steals the hover that spawned it.
class _MechXTooltipBubble extends StatelessWidget {
  final String message;
  final LayerLink link;
  final MechXTooltipEdge edge;

  const _MechXTooltipBubble({
    required this.message,
    required this.link,
    required this.edge,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final below = edge == MechXTooltipEdge.bottom;
    return Positioned(
      left: 0,
      top: 0,
      child: CompositedTransformFollower(
        link: link,
        showWhenUnlinked: false,
        targetAnchor: below ? Alignment.bottomCenter : Alignment.centerRight,
        followerAnchor: below ? Alignment.topCenter : Alignment.centerLeft,
        offset: below
            ? const Offset(0, MechXSpacing.xxs)
            : const Offset(MechXSpacing.xs, 0),
        child: IgnorePointer(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 240),
            padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.sm,
              vertical: MechXSpacing.xxs,
            ),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: MechXRadii.control,
              border: Border.all(color: colors.border),
              boxShadow: MechXShadow.popover,
            ),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: type.caption.copyWith(color: colors.textPrimary),
            ),
          ),
        ),
      ),
    );
  }
}
