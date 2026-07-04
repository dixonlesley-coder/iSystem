import 'package:flutter/widgets.dart';

import '../theme/mechx_theme.dart';

/// The one section header used across every inspector / right-bar / palette
/// (PROJECT · BUILDING · DRAW · PALETTE · LOADS …): a quiet UPPERCASE caption
/// in the tertiary tier with positive tracking. Shared so the mechanical and
/// electrical surfaces title their sections identically.
class MechXSectionLabel extends StatelessWidget {
  final String text;
  const MechXSectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: context.type.caption.copyWith(
          // F3: a STRUCTURAL heading — `textSecondary` (~5.9:1 on white) clears
          // WCAG AA, where the old `textMuted` (~2.8:1) did not. Only the colour
          // tier changes; the uppercase + tracking stay.
          color: context.colors.textSecondary,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
        ),
      );
}
