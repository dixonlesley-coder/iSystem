import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

/// A promoted "headline result" for a sizing section: the one or two numbers an
/// engineer scans for first (pump kW, fan static, worst-zone status), rendered
/// larger/bolder than the demoted key/value detail rows beneath it, with the
/// VERDICT colour-coded via the success / warning / danger tokens.
///
/// Layout: a soft-filled card with a left value column ([headline] big + [label]
/// caption) and a right-aligned coloured [verdict] chip. Verdict + colour are
/// optional — a card with no verdict is just a prominent metric.
class ResultCard extends StatelessWidget {
  /// The big number, e.g. '2.5 kW' or '480 Pa'. Rendered in the mono face so
  /// the figure aligns with the demoted key/value rows.
  final String headline;

  /// The quiet supporting label under the headline, e.g. 'Motor' or 'Fan static'.
  final String label;

  /// Optional verdict word, e.g. 'OK' / 'over' / 'gravity OK'. Omitted ⇒ no chip.
  final String? verdict;

  /// The colour for the verdict chip — pass `context.colors.success/warning/danger`.
  /// Ignored when [verdict] is null.
  final Color? verdictColor;

  const ResultCard({
    super.key,
    required this.headline,
    required this.label,
    this.verdict,
    this.verdictColor,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final vColor = verdictColor ?? colors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MechXSpacing.sm,
        vertical: MechXSpacing.sm,
      ),
      decoration: BoxDecoration(
        // F2: a headline result card RAISES (iOS elevation) — `surface` is the
        // elevated tone above the grouped `background`, so the promoted result
        // reads lifted off the panel, not recessed into it.
        color: colors.surface,
        borderRadius: MechXRadii.control,
        border: Border.all(color: colors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  headline,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // The figure: the body scale (larger than the caption rows
                  // below) with a heavier weight so it reads as the headline.
                  style: type.body.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontFamily: MechXTypography.monoFamily,
                  ),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.caption.copyWith(color: colors.textMuted),
                ),
              ],
            ),
          ),
          if (verdict != null) ...[
            const SizedBox(width: MechXSpacing.sm),
            _VerdictChip(text: verdict!, color: vColor),
          ],
        ],
      ),
    );
  }
}

/// A small coloured verdict chip (e.g. green 'OK', red 'over'). The colour is a
/// success / warning / danger token; the text sits on a faint tint of it.
class _VerdictChip extends StatelessWidget {
  final String text;
  final Color color;

  const _VerdictChip({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    final type = context.type;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MechXSpacing.sm,
        vertical: MechXSpacing.xxs,
      ),
      decoration: BoxDecoration(
        // A faint wash of the verdict colour so it reads as a status pill, not
        // a button. The alpha is low enough to work on both light and dark.
        color: color.withValues(alpha: 0.14),
        borderRadius: const BorderRadius.all(MechXRadii.sm),
      ),
      child: Text(
        text,
        style: type.label.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
