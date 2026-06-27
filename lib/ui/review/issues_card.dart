import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/design_issues_store.dart';
import '../../store/electrical_store.dart';
import '../../store/project_store.dart';
import '../../store/selection_store.dart';
import '../../store/sheets_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/severity_glyph.dart';

/// The unified "Design Issues" card for the Review hub — every design warning
/// the app already computes (out-of-band air velocities, unsized air elements,
/// uncalibrated sheets, unverified standards) aggregated into one list grouped
/// by severity. A locatable row (one with a sheet + element) is tappable: it
/// sets the active sheet, selects the element, and switches to the Layout view.
///
/// Read-only over [designIssuesProvider]; renders nothing when there are no
/// issues (so a clean project leaves the hub byte-identical).
class IssuesCard extends ConsumerWidget {
  const IssuesCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final issues = ref.watch(designIssuesProvider);
    if (issues.isEmpty) {
      // A clean design earns an explicit, positive confirmation rather than an
      // empty void — the card still renders, with a success check + message.
      return Container(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: MechXRadii.card,
          border: Border.all(color: colors.border),
        ),
        padding: const EdgeInsets.all(MechXSpacing.md),
        child: Row(
          children: [
            CustomPaint(
              size: const Size(16, 16),
              painter: SeverityGlyph(
                kind: SeverityGlyphKind.check,
                color: colors.success,
              ),
            ),
            const SizedBox(width: MechXSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('No design issues found',
                      style:
                          type.subtitle.copyWith(color: colors.textPrimary)),
                  Text(
                    'Air velocities are in band, sheets are calibrated, and '
                    'every standards value is accounted for.',
                    style: type.caption.copyWith(color: colors.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final warnings =
        issues.where((i) => i.severity == IssueSeverity.warning).toList();
    final infos =
        issues.where((i) => i.severity == IssueSeverity.info).toList();

    void locate(DesignIssue issue) {
      final loc = issue.locate;
      if (loc == null) return;
      ref.read(sheetsControllerProvider.notifier).selectSheetById(loc.sheetId);
      final sel = ref.read(selectionProvider.notifier);
      if (loc.nodeId != null) {
        sel.selectNode(loc.nodeId!);
      } else if (loc.edgeId != null) {
        sel.selectEdge(loc.edgeId!);
      } else {
        sel.clear();
      }
      ref.read(workspaceViewProvider.notifier).set(WorkspaceView.plan);
    }

    // One-click batch actions over a whole class of issues — SAFE: each either
    // multi-selects the offending elements (then jumps to Layout to review) or
    // copies a calibrated sheet's scale to the rest. Never edits/sizes anything.
    final batchActions = ref.watch(issueBatchActionsProvider);
    void runBatch(IssueBatchAction a) {
      if (!a.enabled) return;
      switch (a.kind) {
        case IssueBatchKind.selectVelocityWarnings:
        case IssueBatchKind.selectUnsizedAir:
          ref.read(selectionProvider.notifier).setMulti(a.nodeIds, a.edgeIds);
          ref.read(workspaceViewProvider.notifier).set(WorkspaceView.plan);
        case IssueBatchKind.calibrateAllSheets:
          final src = a.sourceSheetId;
          if (src != null) {
            ref
                .read(projectControllerProvider.notifier)
                .applyCalibrationToAllSheets(src, toSheetIds: a.targetSheetIds);
          }
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.border),
      ),
      padding: const EdgeInsets.all(MechXSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Design issues',
                  style: type.subtitle.copyWith(color: colors.textPrimary)),
              const SizedBox(width: MechXSpacing.sm),
              Text('${issues.length}',
                  style: type.caption.copyWith(color: colors.textMuted)),
            ],
          ),
          if (batchActions.isNotEmpty) ...[
            const SizedBox(height: MechXSpacing.sm),
            _GroupLabel('Quick fixes', batchActions.length),
            const SizedBox(height: MechXSpacing.xs),
            Wrap(
              spacing: MechXSpacing.xs,
              runSpacing: MechXSpacing.xs,
              children: [
                for (final a in batchActions)
                  _BatchChip(
                    label: a.label,
                    enabled: a.enabled,
                    onTap: () => runBatch(a),
                  ),
              ],
            ),
          ],
          if (warnings.isNotEmpty) ...[
            const SizedBox(height: MechXSpacing.sm),
            _GroupLabel('Warnings', warnings.length),
            for (final i in warnings)
              _IssueRow(issue: i, onTap: i.isLocatable ? () => locate(i) : null),
          ],
          if (infos.isNotEmpty) ...[
            const SizedBox(height: MechXSpacing.sm),
            _GroupLabel('Advisory', infos.length),
            for (final i in infos)
              _IssueRow(issue: i, onTap: i.isLocatable ? () => locate(i) : null),
          ],
        ],
      ),
    );
  }
}

/// A tappable pill for a one-click batch action. Disabled chips are muted and
/// non-interactive (e.g. calibrate-all before any sheet is calibrated).
class _BatchChip extends StatelessWidget {
  final String label;
  final bool enabled;
  final VoidCallback onTap;
  const _BatchChip({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final fg = enabled ? colors.accent : colors.textMuted;
    final chip = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MechXSpacing.sm,
        vertical: MechXSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: enabled ? colors.accentMuted : colors.surface,
        borderRadius: MechXRadii.control,
        border: Border.all(color: enabled ? colors.accent : colors.border),
      ),
      child: Text(label, style: type.caption.copyWith(color: fg)),
    );
    if (!enabled) return chip;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: chip),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  final String text;
  final int count;
  const _GroupLabel(this.text, this.count);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Padding(
      padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
      child: Text('$text  ($count)',
          style: type.caption.copyWith(color: colors.textMuted)),
    );
  }
}

class _IssueRow extends StatelessWidget {
  final DesignIssue issue;
  final VoidCallback? onTap;
  const _IssueRow({required this.issue, this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final isWarning = issue.severity == IssueSeverity.warning;
    final dotColor = isWarning ? colors.warning : colors.accent;

    final row = Padding(
      padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Severity is carried by a glyph (a "!" ring for a warning, an "i"
          // dot-ring for advisory) as well as colour, so it stays legible
          // without relying on hue alone (redundant cue).
          Padding(
            padding: const EdgeInsets.only(top: 2, right: MechXSpacing.sm),
            child: CustomPaint(
              size: const Size(11, 11),
              painter: SeverityGlyph(
                kind: isWarning ? SeverityGlyphKind.warn : SeverityGlyphKind.info,
                color: dotColor,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(issue.title,
                    style:
                        type.caption.copyWith(color: colors.textPrimary)),
                Text(issue.message,
                    style:
                        type.caption.copyWith(color: colors.textSecondary)),
              ],
            ),
          ),
          if (onTap != null)
            Padding(
              padding: const EdgeInsets.only(left: MechXSpacing.sm, top: 1),
              child: Text('Locate',
                  style: type.caption.copyWith(color: colors.accent)),
            ),
        ],
      ),
    );

    if (onTap == null) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: row,
    );
  }
}

