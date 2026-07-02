/// The unsaved-changes guard — a Save / Discard / Cancel modal shown before any
/// action that would REPLACE the live project (Open, Import a plan, quit) when
/// the work differs from the last clean Save. So the app never silently destroys
/// unsaved work (finding F2).
///
/// No Material: a [showGeneralDialog]-driven floating card themed with
/// [MechXTheme] — the same idiom as `templates_dialog.dart`. Every text style
/// comes from `context.type` (Roboto-backed) so it renders in goldens, and every
/// label is localized via [StringKey].
library;

import 'package:flutter/widgets.dart';

import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_button.dart';

/// The engineer's choice in the guard dialog. A barrier-dismiss / Esc resolves
/// to `null`, which every caller treats exactly like [cancel] (abort).
enum DiscardChoice { save, discard, cancel }

/// Show the unsaved-changes guard over the current [MechXTheme]. Resolves to the
/// chosen [DiscardChoice], or `null` if dismissed via the scrim / Esc.
Future<DiscardChoice?> showConfirmDiscardDialog(BuildContext context) {
  final theme = MechXTheme.of(context);
  return showGeneralDialog<DiscardChoice>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Unsaved changes',
    barrierColor: theme.colors.scrim,
    transitionDuration: MechXMotion.appear,
    pageBuilder: (ctx, _, _) => MechXTheme(
      data: theme,
      child: const Center(child: _ConfirmDiscardDialog()),
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

class _ConfirmDiscardDialog extends StatelessWidget {
  const _ConfirmDiscardDialog();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;

    void pop(DiscardChoice choice) => Navigator.of(context).pop(choice);

    return Container(
      width: 420,
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
          Text(context.strings(StringKey.confirmDiscardTitle),
              style: type.title.copyWith(color: colors.textPrimary)),
          const SizedBox(height: MechXSpacing.xs),
          Text(
            context.strings(StringKey.confirmDiscardBody),
            style: type.caption.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: MechXSpacing.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              MechXButton(
                label: context.strings(StringKey.confirmDiscardCancel),
                tertiary: true,
                onPressed: () => pop(DiscardChoice.cancel),
              ),
              const SizedBox(width: MechXSpacing.sm),
              MechXButton(
                label: context.strings(StringKey.confirmDiscardDiscard),
                onPressed: () => pop(DiscardChoice.discard),
              ),
              const SizedBox(width: MechXSpacing.sm),
              MechXButton(
                label: context.strings(StringKey.confirmDiscardSave),
                primary: true,
                onPressed: () => pop(DiscardChoice.save),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
