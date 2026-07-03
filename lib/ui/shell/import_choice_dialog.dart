/// The Import "Add vs Replace" chooser (A5). When Import runs into a project
/// that ALREADY has sheets, the engineer decides whether the incoming plan is
/// ADDED to the current sheet set (keeping every current sheet, its calibration
/// and the drawn network) or REPLACES all sheets (today's behaviour — the
/// network orphaned by the replace is then pruned). An EMPTY project skips this
/// entirely and just loads.
///
/// No Material: a [showGeneralDialog]-driven floating card themed with
/// [MechXTheme] — the same idiom as `confirm_discard_dialog.dart`. EN literals
/// (a net-new safety surface; localization is batched separately, per J7).
library;

import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_button.dart';

/// The engineer's choice. A barrier-dismiss / Esc resolves to `null`, which the
/// caller treats as "cancel the import" (keep the current project untouched).
enum ImportChoice { add, replace }

/// Show the Add-vs-Replace chooser over the current [MechXTheme]. [existingSheets]
/// / [incomingSheets] tune the copy. Resolves to the chosen [ImportChoice], or
/// `null` if dismissed via the scrim / Esc.
Future<ImportChoice?> showImportChoiceDialog(
  BuildContext context, {
  required int existingSheets,
  required int incomingSheets,
}) {
  final theme = MechXTheme.of(context);
  return showGeneralDialog<ImportChoice>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Import plan',
    barrierColor: theme.colors.scrim,
    transitionDuration: MechXMotion.appear,
    pageBuilder: (ctx, _, _) => MechXTheme(
      data: theme,
      child: Center(
        child: _ImportChoiceDialog(
          existingSheets: existingSheets,
          incomingSheets: incomingSheets,
        ),
      ),
    ),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: MechXMotion.standard,
        reverseCurve: MechXMotion.standard,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _ImportChoiceDialog extends StatelessWidget {
  final int existingSheets;
  final int incomingSheets;

  const _ImportChoiceDialog({
    required this.existingSheets,
    required this.incomingSheets,
  });

  static String _plural(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;

    void pop(ImportChoice? choice) => Navigator.of(context).pop(choice);

    return Container(
      width: 440,
      padding: const EdgeInsets.all(MechXSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        boxShadow: MechXShadow.popover,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Add or replace sheets?',
              style: type.title.copyWith(color: colors.textPrimary)),
          const SizedBox(height: MechXSpacing.xs),
          Text(
            'This project already has ${_plural(existingSheets, 'sheet')}. '
            'Add the ${_plural(incomingSheets, 'incoming sheet')} to it — keeping '
            'your current sheets, calibration and drawn network — or replace all '
            'sheets with the new plan.',
            style: type.caption.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: MechXSpacing.md),
          // The two choice labels are descriptive (and localize longer), so the
          // actions stack vertically, right-aligned — the safe recommended ADD
          // on top, the destructive REPLACE below it, Cancel last.
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              MechXButton(
                label: 'Add to project',
                primary: true,
                onPressed: () => pop(ImportChoice.add),
              ),
              const SizedBox(height: MechXSpacing.xs),
              MechXButton(
                label: 'Replace all sheets',
                tone: MechXButtonTone.danger,
                onPressed: () => pop(ImportChoice.replace),
              ),
              const SizedBox(height: MechXSpacing.xs),
              MechXButton(
                label: 'Cancel',
                tertiary: true,
                onPressed: () => pop(null),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
