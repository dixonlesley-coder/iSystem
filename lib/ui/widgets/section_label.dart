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
          color: context.colors.textMuted,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
        ),
      );
}
