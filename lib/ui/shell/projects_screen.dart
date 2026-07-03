import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/app_settings.dart';
import '../../store/project_store.dart';
import '../inspector/project_panel.dart'
    show
        exportAnnotatedPlanPdf,
        exportCalcReport,
        exportCalcReportPdf,
        exportDrawingDxf,
        exportDrawingPdf,
        exportEquipmentSchedule,
        exportEquipmentSchedulePdf,
        exportMepUnifiedReport,
        exportMepUnifiedReportPdf;
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/hub_scaffold.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_text_field.dart';
import 'project_io.dart';
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
    final recents = ref.watch(appSettingsProvider).mru;

    return HubScaffold(
      title: 'Projects',
      lead: 'Start a new project, reopen a recent one, and name + export the '
          'current project here. Open and save .mechx files from the top bar; '
          'autosave keeps a recovery snapshot between sessions.',
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
              Row(
                children: [
                  Expanded(
                    child: Text(context.strings(StringKey.inspectorProject),
                        style:
                            type.subtitle.copyWith(color: colors.textPrimary)),
                  ),
                  MechXButton(
                    label: 'New project',
                    onPressed: () => newProject(context, ref),
                  ),
                ],
              ),
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
                    label: context
                        .strings(StringKey.inspectorExportCalcReportPdfBtn),
                    onPressed: () => exportCalcReportPdf(ref),
                  ),
                  MechXButton(
                    label: context.strings(StringKey.inspectorExportMepReportMd),
                    onPressed: () => exportMepUnifiedReport(ref),
                  ),
                  MechXButton(
                    label: context
                        .strings(StringKey.inspectorExportMepReportPdfBtn),
                    onPressed: () => exportMepUnifiedReportPdf(ref),
                  ),
                  MechXButton(
                    label: context.strings(
                        StringKey.inspectorExportEquipmentScheduleMd),
                    onPressed: () => exportEquipmentSchedule(ref),
                  ),
                  MechXButton(
                    label: context.strings(
                        StringKey.inspectorExportEquipmentSchedulePdfBtn),
                    onPressed: () => exportEquipmentSchedulePdf(ref),
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
        // ── Recent projects (MRU) ────────────────────────────────────────
        if (recents.isNotEmpty) ...[
          const SizedBox(height: MechXSpacing.md),
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
                Text('Recent projects',
                    style: type.subtitle.copyWith(color: colors.textPrimary)),
                const SizedBox(height: MechXSpacing.xs),
                for (final e in recents)
                  _RecentRow(
                    entry: e,
                    onOpen: () => openProjectPath(context, ref, e.path),
                    onRemove: () => ref
                        .read(appSettingsProvider.notifier)
                        .removeRecent(e.path),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: MechXSpacing.md),
        // ── Apply a building template (to the CURRENT project) ────────────
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
              Text('Apply a building template',
                  style: type.subtitle.copyWith(color: colors.textPrimary)),
              const SizedBox(height: MechXSpacing.xs),
              Text(
                'Prefill floors, occupancy, fire hazard, and design rainfall '
                'for a common building type on the CURRENT project (it does not '
                'create a new one), then refine.',
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

/// One recent-project row: its name + path (dimmed, with a "(missing)" tag when
/// the file has moved/been deleted), tapping the row opens it, plus a Remove
/// action that prunes it from the recent list.
class _RecentRow extends StatelessWidget {
  final MruEntry entry;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  const _RecentRow({
    required this.entry,
    required this.onOpen,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final missing = !File(entry.path).existsSync();

    return Padding(
      padding: const EdgeInsets.only(top: MechXSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onOpen,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      missing ? '${entry.name}  (missing)' : entry.name,
                      style: type.body.copyWith(
                          color:
                              missing ? colors.textMuted : colors.textPrimary),
                    ),
                    Text(
                      entry.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.caption.copyWith(color: colors.textMuted),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: MechXSpacing.sm),
          MechXButton(label: 'Remove', tertiary: true, onPressed: onRemove),
        ],
      ),
    );
  }
}
