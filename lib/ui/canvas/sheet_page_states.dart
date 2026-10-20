import 'package:flutter/widgets.dart';

import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_empty_state_card.dart';
import 'canvas_zoom_scope.dart';

/// Fixed caption ink for text drawn straight ON the drawing paper — the paper
/// (`sheetPaper`) is light in BOTH themes, so a theme-variant label tier would
/// lose contrast on it in dark mode (the minimap's 'MAP' caption uses the same
/// reasoning). ~6:1 on `sheetPaper`.
const Color kSheetPaperCaptionInk = Color(0xFF5F6670);

MechXColors _colorsOf(BuildContext context) =>
    MechXTheme.maybeOf(context)?.colors ?? MechXColors.light;

/// The placeholder a plan sheet shows while its PDF page / DXF drawing is
/// still loading: the sheet's own paper (never a raw white slab, never the
/// void canvas colour) with a quiet centred 'Loading plan…' caption, so the
/// slot already reads as the drawing it is about to become.
class SheetLoadingPage extends StatelessWidget {
  const SheetLoadingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = _colorsOf(context);
    final type =
        MechXTheme.maybeOf(context)?.typography ?? MechXTypography.standard;
    return ColoredBox(
      color: colors.sheetPaper,
      // The caption is chrome, not drawing: screen-sized at every zoom.
      child: ScreenConstantLayer(
        child: Center(
          child: Text(
            MechXStrings.of(context)(StringKey.sheetLoadingPlan),
            style: type.caption.copyWith(color: kSheetPaperCaptionInk),
          ),
        ),
      ),
    );
  }
}

/// A plan sheet whose source could not be read (a moved / deleted / corrupt
/// PDF or DXF): the design system's empty-state card on the sheet paper — a
/// concise title, the reason in a muted detail line (the raw error text is
/// kept, but never shouted in red across the page) and, when the host can
/// offer it, the existing 'Replace plan…' flow as the way forward.
class SheetLoadErrorPage extends StatelessWidget {
  /// What failed, in plain words ('The PDF could not be opened.').
  final String message;

  /// The underlying error text, shown muted (may be empty).
  final String detail;

  /// Re-point this sheet at another file (the rail's 'Replace plan…' flow).
  /// Null ⇒ no action button.
  final VoidCallback? onReplacePlan;

  const SheetLoadErrorPage({
    super.key,
    required this.message,
    this.detail = '',
    this.onReplacePlan,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _colorsOf(context);
    final strings = MechXStrings.of(context);
    final card = MechXEmptyStateCard(
      title: strings(StringKey.sheetLoadFailedTitle),
      body: message,
      detail: detail,
      actions: [
        if (onReplacePlan != null)
          MechXButton(
            label: strings(StringKey.sheetReplacePlan),
            primary: true,
            onPressed: onReplacePlan,
          ),
      ],
    );
    return ColoredBox(
      color: colors.sheetPaper,
      // The card is chrome, not drawing: screen-sized at every zoom (it
      // used to shrink to an illegible speck on a fitted A1 sheet).
      child: ScreenConstantLayer(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(MechXSpacing.md),
            // The card is content: opaque, on the theme's own surface — it
            // needs a theme above it, which a bare test harness may lack.
            child: MechXTheme.maybeOf(context) == null
                ? MechXTheme(data: MechXThemeData.light, child: card)
                : card,
          ),
        ),
      ),
    );
  }
}
