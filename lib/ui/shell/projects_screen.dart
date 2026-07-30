import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/app_settings.dart';
import '../../store/project_store.dart';
import '../inspector/disclosure_header.dart';
import '../inspector/project_panel.dart'
    show
        ExportIdentityBar,
        exportAnnotatedPlanPdf,
        exportCalcReport,
        exportCalcReportPdf,
        exportDrawingDxf,
        exportDrawingPdf,
        exportEquipmentSchedule,
        exportEquipmentSchedulePdf,
        exportMepUnifiedReport,
        exportMepUnifiedReportPdf,
        exportSubmittalPackage;
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
                  // A6: the workflow-primary action on this hub — starting a
                  // project — carries the one accent button (mirroring the
                  // top bar's own single-accent convention), not Export.
                  MechXButton(
                    label: 'New project',
                    primary: true,
                    onPressed: () => newProject(context, ref),
                  ),
                ],
              ),
              const SizedBox(height: MechXSpacing.sm),
              MechXTextField(value: project.name, onChanged: ctrl.setName),
            ],
          ),
        ),
        const SizedBox(height: MechXSpacing.md),
        // ── Export ────────────────────────────────────────────────────────
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
              // H5: the document-control identity right at the export surface.
              const ExportIdentityBar(),
              const SizedBox(height: MechXSpacing.md),
              // A5: a leading, visually-primary 'Export deliverables' group —
              // the cross-discipline submittal package + the unified MEP
              // report — ahead of the per-artifact rows below. No longer an
              // accent button (A6 moves the page's one accent to 'New
              // project'); it stays first and its own labelled group instead.
              Text(context.strings(StringKey.reviewExportDeliverables),
                  style: type.subtitle.copyWith(color: colors.textPrimary)),
              const SizedBox(height: MechXSpacing.xs),
              Wrap(
                spacing: MechXSpacing.xs,
                runSpacing: MechXSpacing.xs,
                children: [
                  MechXButton(
                    label: 'Export submittal package...',
                    onPressed: () => exportSubmittalPackage(ref),
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
                ],
              ),
              const SizedBox(height: MechXSpacing.md),
              // Per-artifact rows, grouped under labelled disclosures so the
              // hub reads as a scannable set of clusters instead of one flat
              // wall of same-weight buttons. P1: each group header names how
              // many exports it holds — an inventory count derived from the
              // group's own action list, never a hardcoded literal, so it can
              // never drift from what's actually inside.
              _exportGroups(context, ref),
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
              Text(context.strings(StringKey.projectApplyBuildingTemplate),
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

  /// P1 — the three per-artifact export groups (Drawings / Reports / Data),
  /// each header carrying a `(N)` count of the exports it actually holds so
  /// a collapsed section never hides how much is inside. N is the real
  /// length of that group's own action list — never a hardcoded literal —
  /// so it can't drift if a group gains or loses an export.
  Widget _exportGroups(BuildContext context, WidgetRef ref) {
    final drawingsActions = <Widget>[
      Align(
        alignment: Alignment.centerLeft,
        child: MechXButton(
          label: context.strings(StringKey.inspectorExportDrawingDxf),
          onPressed: () => exportDrawingDxf(ref),
        ),
      ),
      _ExportRow(
        label: context.strings(StringKey.inspectorExportDrawingPdf),
        hint: context.strings(StringKey.projectsExportDrawingPdfHint),
        onPressed: () => exportDrawingPdf(ref),
      ),
      _ExportRow(
        label: context.strings(StringKey.inspectorExportAnnotatedPlanPdf),
        hint: context.strings(StringKey.projectsExportAnnotatedPlanPdfHint),
        onPressed: () => exportAnnotatedPlanPdf(ref),
      ),
    ];
    final reportsActions = <Widget>[
      MechXButton(
        label: context.strings(StringKey.inspectorExportCalcReportMd),
        onPressed: () => exportCalcReport(ref),
      ),
      MechXButton(
        label: context.strings(StringKey.inspectorExportCalcReportPdfBtn),
        onPressed: () => exportCalcReportPdf(ref),
      ),
    ];
    final dataActions = <Widget>[
      MechXButton(
        label: context.strings(StringKey.inspectorExportEquipmentScheduleMd),
        onPressed: () => exportEquipmentSchedule(ref),
      ),
      MechXButton(
        label:
            context.strings(StringKey.inspectorExportEquipmentSchedulePdfBtn),
        onPressed: () => exportEquipmentSchedulePdf(ref),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DisclosureSection(
          name: '${context.strings(StringKey.projectsExportGroupDrawings)}'
              ' (${drawingsActions.length})',
          defaultExpanded: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < drawingsActions.length; i++) ...[
                if (i > 0) const SizedBox(height: MechXSpacing.xs),
                drawingsActions[i],
              ],
            ],
          ),
        ),
        const SizedBox(height: MechXSpacing.sm),
        DisclosureSection(
          name: '${context.strings(StringKey.projectsExportGroupReports)}'
              ' (${reportsActions.length})',
          defaultExpanded: false,
          child: Wrap(
            spacing: MechXSpacing.xs,
            runSpacing: MechXSpacing.xs,
            children: reportsActions,
          ),
        ),
        const SizedBox(height: MechXSpacing.sm),
        DisclosureSection(
          name: '${context.strings(StringKey.projectsExportGroupData)}'
              ' (${dataActions.length})',
          defaultExpanded: false,
          child: Wrap(
            spacing: MechXSpacing.xs,
            runSpacing: MechXSpacing.xs,
            children: dataActions,
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

/// A5: one export button plus a short clarifying caption underneath — used
/// for the two near-identical plan-PDF rows (plain drawing vs annotated with
/// real run/riser lengths) so the difference reads without opening either
/// file.
class _ExportRow extends StatelessWidget {
  final String label;
  final String hint;
  final VoidCallback onPressed;

  const _ExportRow({
    required this.label,
    required this.hint,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: MechXButton(label: label, onPressed: onPressed),
        ),
        const SizedBox(height: MechXSpacing.xxs),
        Text(hint, style: type.caption.copyWith(color: colors.textMuted)),
      ],
    );
  }
}
