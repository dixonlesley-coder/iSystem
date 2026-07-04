/// The "New from template" picker — a custom design-system modal that lists the
/// built-in [BuildingTemplate]s (Residential highrise / Office tower / Hospital /
/// Retail shop) and, on selection, applies the template's smart defaults (floor
/// stack + occupancy + fire hazard + design rainfall) to the live project via
/// [applyTemplate].
///
/// No Material: a [showGeneralDialog]-driven floating card themed with
/// [MechXTheme]. Every text style comes from `context.type` (Roboto-backed) so
/// it renders in goldens.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/network_store.dart';
import '../../store/sheets_store.dart';
import '../../store/templates.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_button.dart';
import 'project_io.dart';

/// Open the template picker as a modal over the current [MechXTheme].
Future<void> showTemplatesDialog(BuildContext context) {
  final theme = MechXTheme.of(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Apply a building template',
    barrierColor: theme.colors.scrim,
    transitionDuration: MechXMotion.appear,
    pageBuilder: (ctx, _, _) => MechXTheme(
      data: theme,
      child: const Center(child: _TemplatesDialog()),
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

class _TemplatesDialog extends ConsumerWidget {
  const _TemplatesDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;

    return Container(
      width: 460,
      constraints: const BoxConstraints(maxHeight: 640),
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
          Row(
            children: [
              Expanded(
                child: Text('Apply a building template',
                    style: type.title.copyWith(color: colors.textPrimary)),
              ),
              MechXButton(
                label: 'Close',
                tertiary: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: MechXSpacing.xs),
          Text(
            'Prefill the floor stack, occupancy, fire hazard, and design '
            'rainfall for a common building type. These are smart starting '
            'defaults you can refine; your per-sheet calibration is left '
            'untouched.',
            style: type.caption.copyWith(color: colors.textMuted),
          ),
          // Honest warning (B6): applying a template REPLACES the floor stack.
          // If it has fewer floors than the current building, any drawn work
          // above the new top floor is moved down onto it (one undo step) — so
          // "the drawn network is left untouched" is only true when nothing is
          // drawn. Surface that only when there IS drawn work to move.
          if (ref.watch(networkControllerProvider).network.nodes.isNotEmpty) ...[
            const SizedBox(height: MechXSpacing.xs),
            Text(
              'You have drawn work: if the chosen template has fewer floors than '
              'your building, any elements above its top floor will be moved '
              'down onto the new top floor.',
              style: type.caption.copyWith(color: colors.warning),
            ),
          ],
          const SizedBox(height: MechXSpacing.md),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: kBuildingTemplates.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(height: MechXSpacing.xs),
              itemBuilder: (ctx, i) {
                final t = kBuildingTemplates[i];
                return _TemplateTile(
                  template: t,
                  onApply: () async {
                    // A3: applying a template seeds the building (floors /
                    // occupancy / fire / rainfall) but attaches NO drawable
                    // sheet — so on an empty project route straight into Import
                    // rather than dropping the engineer back onto a "No plan
                    // attached" canvas. Import runs while THIS dialog is still
                    // mounted (so `ref` / `context` stay valid across the OS file
                    // picker) and skips the unsaved-work guard — the only
                    // "unsaved work" is the template we just applied and want to
                    // keep. On a project that ALREADY has sheets, applying a
                    // template just closes (no forced import).
                    final hadNoSheets =
                        ref.read(sheetsControllerProvider).sheets.isEmpty;
                    applyTemplate(ref, t);
                    if (hadNoSheets) {
                      await importPlan(context, ref, skipDiscardGuard: true);
                    }
                    if (context.mounted) Navigator.of(context).pop();
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TemplateTile extends StatelessWidget {
  final BuildingTemplate template;
  final VoidCallback onApply;

  const _TemplateTile({required this.template, required this.onApply});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;

    return Container(
      padding: const EdgeInsets.all(MechXSpacing.sm),
      decoration: BoxDecoration(
        color: colors.surfaceHover,
        borderRadius: MechXRadii.control,
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(template.name,
                    style: type.subtitle.copyWith(color: colors.textPrimary)),
                const SizedBox(height: 2),
                Text(template.description,
                    style: type.caption.copyWith(color: colors.textMuted)),
                const SizedBox(height: 2),
                Text(
                  '${template.floors.length} floors  ·  '
                  '${template.rainfallMmPerHr.toStringAsFixed(0)} mm/hr',
                  style: type.caption.copyWith(color: colors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: MechXSpacing.sm),
          MechXButton(label: 'Apply', onPressed: onApply),
        ],
      ),
    );
  }
}
