import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/design_issues_store.dart';
import '../../store/electrical_focus_store.dart';
import '../../store/electrical_store.dart';
import '../../store/project_store.dart';
import '../../store/selection_store.dart';
import '../../store/sheets_store.dart';
import '../shell/nav_rail.dart';
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

    // Criticals (blockers — uncalibrated sheets carrying drawn runs) fold into
    // the Warnings group rendered first; their row glyph/colour is promoted to
    // the danger style so they read as the top-priority items without a new,
    // golden-shifting header.
    final warnings = issues
        .where((i) =>
            i.severity == IssueSeverity.critical ||
            i.severity == IssueSeverity.warning)
        .toList();
    final infos =
        issues.where((i) => i.severity == IssueSeverity.info).toList();

    // H1 — advisory acknowledgement. An acknowledged advisory drops out of the
    // OPEN "Advisory" group into an "Acknowledged" group (still visible, still
    // in the report), and no longer blocks the PASS verdict. Only info-severity
    // rows are acknowledgeable; warnings/criticals always block.
    final acknowledged = ref.watch(acknowledgedIssuesProvider);
    final ackCtrl = ref.read(acknowledgedIssuesProvider.notifier);
    final openInfos =
        infos.where((i) => !acknowledged.contains(i.key)).toList();
    final ackInfos =
        infos.where((i) => acknowledged.contains(i.key)).toList();
    final openAckableKeys = [
      for (final i in openInfos)
        if (i.isAcknowledgeable) i.key,
    ];

    void locate(DesignIssue issue) {
      final loc = issue.locate;
      if (loc == null) return;
      // An electrical issue lives on the single-line, not a floor plan: switch
      // to the Electrical workspace and hand the panel id to the focus seam
      // (the ElectricalView consumes it centrally). Mirrors the mechanical jump
      // below (sheet + selection + view), just on the electrical axis.
      if (loc.panelId != null) {
        ref.read(shellSectionProvider.notifier).set(ShellSection.design);
        ref.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
        // H7: forward the specific circuit (way) too, so the jump selects the
        // exact way row — not just the board.
        ref
            .read(electricalFocusProvider.notifier)
            .request(loc.panelId!, circuitId: loc.circuitId);
        return;
      }
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
              _IssueRow(
                  issue: i, onTap: i.isLocatable ? () => locate(i) : null),
          ],
          if (openInfos.isNotEmpty) ...[
            const SizedBox(height: MechXSpacing.sm),
            Row(
              children: [
                Expanded(child: _GroupLabel('Advisory', openInfos.length)),
                // Acknowledge every open advisory at once — the fast path to a
                // reachable PASS once the engineer has reviewed the register.
                if (openAckableKeys.isNotEmpty)
                  _AckAction(
                    label: 'Acknowledge all',
                    onTap: () => ackCtrl.acknowledgeAll(openAckableKeys),
                  ),
              ],
            ),
            for (final i in openInfos)
              _IssueRow(
                issue: i,
                onTap: i.isLocatable ? () => locate(i) : null,
                ackLabel: i.isAcknowledgeable ? 'Acknowledge' : null,
                onAck:
                    i.isAcknowledgeable ? () => ackCtrl.acknowledge(i.key) : null,
              ),
          ],
          if (ackInfos.isNotEmpty) ...[
            const SizedBox(height: MechXSpacing.sm),
            _GroupLabel('Acknowledged', ackInfos.length),
            for (final i in ackInfos)
              _IssueRow(
                issue: i,
                onTap: i.isLocatable ? () => locate(i) : null,
                muted: true,
                ackLabel: 'Undo',
                onAck: () => ackCtrl.unacknowledge(i.key),
              ),
          ],
        ],
      ),
    );
  }
}

/// A small tappable accent text action (Acknowledge / Undo / Acknowledge all).
class _AckAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _AckAction({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Text(label,
            style: type.caption.copyWith(color: colors.accent)),
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

  /// H1 — the acknowledge/undo affordance for an advisory row. Rendered as a
  /// separate trailing tappable text ([ackLabel]) so it doesn't collide with the
  /// whole-row locate tap.
  final String? ackLabel;
  final VoidCallback? onAck;

  /// True for an already-acknowledged row: dimmed so it reads as resolved.
  final bool muted;

  const _IssueRow({
    required this.issue,
    this.onTap,
    this.ackLabel,
    this.onAck,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final isCritical = issue.severity == IssueSeverity.critical;
    final isWarning = issue.severity == IssueSeverity.warning || isCritical;
    final dotColor = muted
        ? colors.textMuted
        : (isCritical
            ? colors.danger
            : (isWarning ? colors.warning : colors.accent));
    final titleColor = muted ? colors.textMuted : colors.textPrimary;
    final bodyColor = muted ? colors.textMuted : colors.textSecondary;

    final row = Padding(
      padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Severity is carried by a glyph (a "!" ring for a warning, an "i"
          // dot-ring for advisory) as well as colour, so it stays legible
          // without relying on hue alone (redundant cue). An acknowledged row
          // shows a check.
          Padding(
            padding: const EdgeInsets.only(top: 2, right: MechXSpacing.sm),
            child: CustomPaint(
              size: const Size(11, 11),
              painter: SeverityGlyph(
                kind: muted
                    ? SeverityGlyphKind.check
                    : (isWarning
                        ? SeverityGlyphKind.warn
                        : SeverityGlyphKind.info),
                color: dotColor,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(issue.title,
                    style: type.caption.copyWith(color: titleColor)),
                Text(issue.message,
                    style: type.caption.copyWith(color: bodyColor)),
              ],
            ),
          ),
          if (onTap != null)
            Padding(
              padding: const EdgeInsets.only(left: MechXSpacing.sm, top: 1),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onTap,
                  child: Text('Locate',
                      style: type.caption.copyWith(color: colors.accent)),
                ),
              ),
            ),
          if (ackLabel != null && onAck != null)
            Padding(
              padding: const EdgeInsets.only(left: MechXSpacing.sm, top: 1),
              child: _AckAction(label: ackLabel!, onTap: onAck!),
            ),
        ],
      ),
    );

    return row;
  }
}

