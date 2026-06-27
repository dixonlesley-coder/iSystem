import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/design_issues_store.dart';
import '../../store/electrical_store.dart';
import '../../store/selection_store.dart';
import '../../store/sheets_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

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
    if (issues.isEmpty) return const SizedBox.shrink();

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
    final dotColor =
        issue.severity == IssueSeverity.warning ? colors.warning : colors.accent;

    final row = Padding(
      padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.only(top: 5, right: MechXSpacing.sm),
            decoration: BoxDecoration(
              color: dotColor,
              borderRadius: const BorderRadius.all(MechXRadii.xs),
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
