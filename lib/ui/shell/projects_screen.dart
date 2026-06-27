import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/project_store.dart';
import '../inspector/project_panel.dart'
    show
        exportAnnotatedPlanPdf,
        exportCalcReport,
        exportDrawingDxf,
        exportDrawingPdf,
        exportEquipmentSchedule,
        exportMepUnifiedReport;
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/hub_scaffold.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_text_field.dart';
import 'templates_dialog.dart';

/// Projects landing — now also the home of the current project's identity:
/// its name and the document exports (calc report / DXF / PDF), lifted off the
/// canvas inspector so the drawing area stays focused. The open/save flows live
/// in the top bar; a recent-projects browser arrives in a later wave.
class ProjectsScreen extends ConsumerWidget {
  const ProjectsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final project = ref.watch(projectControllerProvider);
    final ctrl = ref.read(projectControllerProvider.notifier);

    return HubScaffold(
      title: 'Projects',
      lead: 'Name the current project and export its deliverables here. Open and '
          'save .mechx files from the top bar; autosave keeps a recovery '
          'snapshot between sessions.',
      children: [
        // ── Current project ──────────────────────────────────────────────
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(MechXSpacing.md),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: MechXRadii.card,
            border: Border.all(color: colors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(context.strings(StringKey.inspectorProject),
                  style: type.subtitle.copyWith(color: colors.textPrimary)),
              const SizedBox(height: MechXSpacing.sm),
              MechXTextField(value: project.name, onChanged: ctrl.setName),
              const SizedBox(height: MechXSpacing.md),
              Text('Export',
                  style: type.caption.copyWith(color: colors.textMuted)),
              const SizedBox(height: MechXSpacing.xs),
              Wrap(
                spacing: MechXSpacing.xs,
                runSpacing: MechXSpacing.xs,
                children: [
                  MechXButton(
                    label: context.strings(StringKey.inspectorExportCalcReportMd),
                    onPressed: () => exportCalcReport(ref),
                  ),
                  MechXButton(
                    label: context.strings(StringKey.inspectorExportMepReportMd),
                    onPressed: () => exportMepUnifiedReport(ref),
                  ),
                  MechXButton(
                    label: context.strings(
                        StringKey.inspectorExportEquipmentScheduleMd),
                    onPressed: () => exportEquipmentSchedule(ref),
                  ),
                  MechXButton(
                    label: context.strings(StringKey.inspectorExportDrawingDxf),
                    onPressed: () => exportDrawingDxf(ref),
                  ),
                  MechXButton(
                    label: context.strings(StringKey.inspectorExportDrawingPdf),
                    onPressed: () => exportDrawingPdf(ref),
                  ),
                  MechXButton(
                    label: context
                        .strings(StringKey.inspectorExportAnnotatedPlanPdf),
                    onPressed: () => exportAnnotatedPlanPdf(ref),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: MechXSpacing.md),
        // ── New project from template ────────────────────────────────────
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(MechXSpacing.md),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: MechXRadii.card,
            border: Border.all(color: colors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('New project from template',
                  style: type.subtitle.copyWith(color: colors.textPrimary)),
              const SizedBox(height: MechXSpacing.xs),
              Text(
                'Prefill floors, occupancy, fire hazard, and design rainfall '
                'for a common building type, then refine.',
                style: type.caption.copyWith(color: colors.textMuted),
              ),
              const SizedBox(height: MechXSpacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: MechXButton(
                  label: 'Choose template...',
                  onPressed: () => showTemplatesDialog(context),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
