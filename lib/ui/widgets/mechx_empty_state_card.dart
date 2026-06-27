import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

/// A branded empty-state card — a surface card with a [title], a secondary
/// [body] sentence, and an optional row of [actions] (typically `MechXButton`s).
///
/// Shared by BOTH the mechanical Layout canvas (no sheet loaded) and the
/// electrical single-line view (no panels yet), so an empty workspace reads as
/// one app. Styled with MechXTheme tokens — no Material. Constrained to 360 px
/// so it scales down gracefully on a narrow window without overflowing; callers
/// supply their own outer alignment/background.
class MechXEmptyStateCard extends StatelessWidget {
  final String title;
  final String body;
  final List<Widget> actions;

  const MechXEmptyStateCard({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Container(
        padding: const EdgeInsets.all(MechXSpacing.lg),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: MechXRadii.card,
          border: Border.all(color: colors.border),
          boxShadow: MechXShadow.card,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: type.title.copyWith(color: colors.textPrimary)),
            const SizedBox(height: MechXSpacing.xs),
            Text(
              body,
              style: type.body.copyWith(color: colors.textSecondary),
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: MechXSpacing.md),
              Row(children: actions),
            ],
          ],
        ),
      ),
    );
  }
}
