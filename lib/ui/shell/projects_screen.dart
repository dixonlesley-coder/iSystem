import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/app_settings.dart';
import '../../store/project_store.dart';
import '../inspector/disclosure_header.dart';
import '../inspector/project_panel.dart'
    show ExportIdentityBar, visibleEquipmentSpecTargetCount;
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/hub_scaffold.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_text_field.dart';
import 'document_control_card.dart';
import 'export_sheet.dart' show AllExportsLink;
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
    // The equipment model/spec disclosure shows only once there is tagged
    // mechanical equipment (the same gate the old inspector section used).
    final specCount = visibleEquipmentSpecTargetCount(ref);

    return HubScaffold(
      title: 'Projects',
      lead: context.strings(StringKey.projectsLead),
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
              // D1: commit on blur / Enter — renaming the project is ONE undo
              // step. Per-keystroke it pushed 25 entries for "Gedung BRI
              // Cabang Jakarta", evicting real edits from the 200-entry stack.
              MechXTextField(value: project.name, onCommitted: ctrl.setName),
              // Work item 4 (2026-10-17): the template prefill lives with the
              // project it applies to — a quiet (non-primary) button here, not
              // a separate card + explanatory paragraph. Also reachable from
              // the command palette ('New from template').
              const SizedBox(height: MechXSpacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: MechXButton(
                  label: context.strings(StringKey.projectsApplyTemplateButton),
                  onPressed: () => showTemplatesDialog(context),
                ),
              ),
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
              // H5: the document-control identity right at the export surface —
              // the Drawing no. / Revision / Client row, then (moved here off
              // the Layout inspector) the DRAWN/CHECKED/APPROVED + revision
              // block and the equipment model/spec editor as disclosures.
              ExportIdentityBar(
                footer: [
                  const SizedBox(height: MechXSpacing.md),
                  DisclosureSection(
                    name: kSignOffSectionKey,
                    label: context.strings(StringKey.projectsSignOffSection),
                    defaultExpanded: false,
                    child: const DocumentControlCard(),
                  ),
                  if (specCount > 0) ...[
                    const SizedBox(height: MechXSpacing.sm),
                    DisclosureSection(
                      name: kEquipmentSpecSectionKey,
                      label: context.strings.format(
                          StringKey.projectsEquipmentSpecSection,
                          {'n': specCount}),
                      defaultExpanded: false,
                      child: const EquipmentSpecCard(),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: MechXSpacing.sm),
              // Work item 8: every export (the submittal package, drawings,
              // reports, data) lives in the ONE Export sheet (Ctrl/Cmd+E) —
              // this card keeps the document-control identity + a link to it.
              const AllExportsLink(),
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
