import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/document_control_store.dart';
import '../../store/equipment_spec_store.dart';

export '../../store/inspector_store.dart'
    show kEquipmentSpecSectionKey, kSignOffSectionKey;
import '../inspector/project_panel.dart'
    show
        InspectorGlyphButton,
        equipmentSpecTargets,
        visibleEquipmentSpecTargetCount;
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_text_field.dart';

/// Document control sign-off — the DRAWN/CHECKED/APPROVED names plus a minimal
/// revision-history editor (D3). Moved off the Layout inspector to the Projects
/// page, beneath the Drawing no. / Revision / Client row of the document-control
/// card ([ExportIdentityBar]), so the whole issuable-sheet identity lives beside
/// the exports it stamps. All fields commit straight into
/// [documentControlProvider] (persisted with the project), from where they feed
/// every report head and PDF/DXF title block.
class DocumentControlCard extends ConsumerStatefulWidget {
  const DocumentControlCard({super.key});

  @override
  ConsumerState<DocumentControlCard> createState() =>
      _DocumentControlCardState();
}

class _DocumentControlCardState extends ConsumerState<DocumentControlCard> {
  // The pending add-revision row. The epoch keys the row's text fields so a
  // successful Add remounts them EMPTY — an EditableText keeps its own text
  // while focused, so clearing the state alone would not clear the field.
  String _revDate = '';
  String _revDesc = '';
  int _addEpoch = 0;

  void _addRevision() {
    final date = _revDate.trim();
    final desc = _revDesc.trim();
    if (date.isEmpty && desc.isEmpty) return;
    ref.read(documentControlProvider.notifier).addRevision(date, desc);
    setState(() {
      _revDate = '';
      _revDesc = '';
      _addEpoch++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final doc = ref.watch(documentControlProvider);
    final ctrl = ref.read(documentControlProvider.notifier);

    // A labelled single-line field. The store setter normalizes (trims; an
    // emptied field clears back to null). Round 29 — it commits on blur /
    // Enter (the project-name idiom), so one edit = ONE settings undo step,
    // never one step per keystroke.
    Widget field(
      StringKey label,
      String? value,
      ValueChanged<String> onChanged,
    ) => Padding(
      padding: const EdgeInsets.only(bottom: MechXSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.strings(label),
            style: type.caption.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: MechXSpacing.xs),
          MechXTextField(value: value ?? '', onCommitted: onChanged),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // (Document no. / Revision / Client sit in the always-visible row
        // above this disclosure — not repeated here.)
        field(
          StringKey.inspectorPreparedBy,
          doc.preparedBy,
          ctrl.setPreparedBy,
        ),
        field(StringKey.inspectorCheckedBy, doc.checkedBy, ctrl.setCheckedBy),
        field(
          StringKey.inspectorApprovedBy,
          doc.approvedBy,
          ctrl.setApprovedBy,
        ),

        // ── Revision history (date + description rows) ─────────────────────
        Text(
          context.strings(StringKey.inspectorRevisionHistory),
          style: type.caption.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: MechXSpacing.xs),
        for (var i = 0; i < doc.revisions.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${doc.revisions[i].date} · ${doc.revisions[i].description}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.caption.copyWith(color: colors.textSecondary),
                  ),
                ),
                InspectorGlyphButton(
                  glyph: '−',
                  onTap: () => ctrl.removeRevisionAt(i),
                ),
              ],
            ),
          ),
        Row(
          key: ValueKey('doc-rev-add-$_addEpoch'),
          children: [
            SizedBox(
              width: 92,
              child: MechXTextField(
                value: '',
                hint: context.strings(StringKey.inspectorRevisionDateHint),
                onChanged: (v) => _revDate = v,
              ),
            ),
            const SizedBox(width: MechXSpacing.xs),
            Expanded(
              child: MechXTextField(
                value: '',
                hint: context.strings(StringKey.inspectorRevisionDescHint),
                onChanged: (v) => _revDesc = v,
              ),
            ),
          ],
        ),
        const SizedBox(height: MechXSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: MechXButton(
            label: context.strings(StringKey.inspectorAddRevision),
            onPressed: _addRevision,
          ),
        ),
      ],
    );
  }
}

/// N23 — the compact "Model / spec" editor for the equipment schedule: one
/// row per tagged pump / fan / AHU-FCU-AC (+ the electrical panel / source
/// apparatus rows once shown) — the same tags `gatherEquipmentScheduleData`
/// assigns — each with a free-text field committing straight into
/// [equipmentModelSpecProvider] (persisted with the project). Threaded into
/// every equipment-schedule export by tag. Renders nothing when there is no
/// tagged mechanical equipment yet (the host gates its disclosure on the same
/// [visibleEquipmentSpecTargetCount]).
class EquipmentSpecCard extends ConsumerWidget {
  const EquipmentSpecCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final specs = ref.watch(equipmentModelSpecProvider);
    if (visibleEquipmentSpecTargetCount(ref) == 0) {
      return const SizedBox.shrink();
    }
    final targets = equipmentSpecTargets(ref);

    final colors = context.colors;
    final type = context.type;
    final ctrl = ref.read(equipmentModelSpecProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.strings(StringKey.inspectorEquipmentScheduleHint),
          style: type.caption.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: MechXSpacing.sm),
        for (final t in targets)
          Padding(
            padding: const EdgeInsets.only(bottom: MechXSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${t.tag} · ${t.service}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.caption.copyWith(color: colors.textSecondary),
                ),
                const SizedBox(height: MechXSpacing.xxs),
                MechXTextField(
                  value: specs[t.tag] ?? '',
                  hint: context.strings(StringKey.inspectorModelSpecHint),
                  onCommitted: (v) => ctrl.setSpec(t.tag, v),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
