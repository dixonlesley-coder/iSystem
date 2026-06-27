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
              painter: _SeverityGlyph(
                kind: _GlyphKind.check,
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
              painter: _SeverityGlyph(
                kind: isWarning ? _GlyphKind.warn : _GlyphKind.info,
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

/// Which glyph a [_SeverityGlyph] draws: a hollow ring with an exclamation
/// (warning), a ring with a centre dot (advisory / info), or a bare check
/// (the clean-state success mark).
enum _GlyphKind { warn, info, check }

/// A small custom-painted severity glyph — a redundant cue paired with colour
/// so the meaning survives without relying on hue alone. Custom-painted (no
/// icon font), so it can never render as tofu in the goldens.
class _SeverityGlyph extends CustomPainter {
  final _GlyphKind kind;
  final Color color;

  const _SeverityGlyph({required this.kind, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final c = Offset(w / 2, h / 2);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    if (kind == _GlyphKind.check) {
      final path = Path()
        ..moveTo(w * 0.20, h * 0.52)
        ..lineTo(w * 0.42, h * 0.74)
        ..lineTo(w * 0.80, h * 0.26);
      canvas.drawPath(path, stroke);
      return;
    }

    // A ring for both warn + info.
    canvas.drawCircle(c, w * 0.42, stroke);
    final fill = Paint()..color = color;
    if (kind == _GlyphKind.warn) {
      // An exclamation stem + dot inside the ring.
      canvas.drawLine(
        Offset(w / 2, h * 0.28),
        Offset(w / 2, h * 0.58),
        stroke,
      );
      canvas.drawCircle(Offset(w / 2, h * 0.74), w * 0.07, fill);
    } else {
      // Info: a single centre dot.
      canvas.drawCircle(c, w * 0.10, fill);
    }
  }

  @override
  bool shouldRepaint(_SeverityGlyph old) =>
      old.kind != kind || old.color != color;
}
