/// The Power one-line tab — a read-only render of the hybrid power one-line
/// (`PowerOneLine` from the A8 sources pass): the source nodes (PLN utility,
/// generator, solar PV, battery), the buses (main / essential / UPS), the main
/// panel, and the source interlocks. Ported in spirit from PanelMaker's
/// `PowerOneline.tsx` — a generated render of the sources design, not a parallel
/// calculation. Styled with MechXTheme (no Material).
library;

import 'package:flutter/widgets.dart';
import 'package:mechx_engine/electrical/power_oneline.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

class PowerOneLineView extends StatelessWidget {
  final PowerOneLine? oneLine;
  const PowerOneLineView({super.key, required this.oneLine});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final ol = oneLine;
    if (ol == null) {
      return ColoredBox(
        color: colors.canvas,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Container(
              padding: const EdgeInsets.all(MechXSpacing.lg),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: MechXRadii.card,
                border: Border.all(color: colors.border),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('No energy sources',
                      style: type.title.copyWith(color: colors.textPrimary)),
                  const SizedBox(height: MechXSpacing.xs),
                  Text(
                    'Add a generator, solar PV or battery from the Loads palette '
                    'to build a hybrid power one-line with source interlocks.',
                    style: type.body.copyWith(color: colors.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return ColoredBox(
      color: colors.canvas,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(MechXSpacing.lg),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Power one-line',
                    style: type.title.copyWith(color: colors.textPrimary)),
                const SizedBox(height: MechXSpacing.md),
                // Source nodes.
                Wrap(
                  spacing: MechXSpacing.md,
                  runSpacing: MechXSpacing.md,
                  children: [
                    for (final n in ol.nodes) _Node(node: n),
                  ],
                ),
                const SizedBox(height: MechXSpacing.lg),
                // Connections.
                if (ol.edges.isNotEmpty) ...[
                  _SectionLabel('Connections'),
                  const SizedBox(height: MechXSpacing.xs),
                  for (final e in ol.edges)
                    _Row(
                      a: _label(ol, e.from),
                      b: _label(ol, e.to),
                      note: e.label,
                    ),
                  const SizedBox(height: MechXSpacing.lg),
                ],
                // Interlocks.
                if (ol.interlocks.isNotEmpty) ...[
                  _SectionLabel('Source interlocks'),
                  const SizedBox(height: MechXSpacing.xs),
                  for (final il in ol.interlocks)
                    _Interlock(
                      title:
                          '${_label(ol, il.aId)} <> ${_label(ol, il.bId)} · ${_kind(il.kind)} · ${_rel(il.relation)}',
                      note: il.note,
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _label(PowerOneLine ol, String id) =>
      ol.nodes.where((n) => n.id == id).firstOrNull?.label ?? id;

  String _kind(PowerInterlockKind k) =>
      k == PowerInterlockKind.mechanical ? 'mechanical' : 'electrical';

  String _rel(PowerInterlockRelation r) => switch (r) {
        PowerInterlockRelation.mutualExclusion => 'mutual exclusion',
        PowerInterlockRelation.sequence => 'sequence',
        PowerInterlockRelation.permissive => 'permissive',
      };
}

class _Node extends StatelessWidget {
  final PowerNode node;
  const _Node({required this.node});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final accent = _color(context, node.kind);
    return Container(
      width: 170,
      padding: const EdgeInsets.all(MechXSpacing.sm),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: accent.withAlpha(160), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(right: MechXSpacing.xs),
                decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
              ),
              Expanded(
                child: Text(node.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.label.copyWith(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          if (node.sub != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 16),
              child: Text(node.sub!,
                  style: type.caption.copyWith(color: colors.textMuted)),
            ),
        ],
      ),
    );
  }

  Color _color(BuildContext context, PowerNodeKind kind) {
    final colors = context.colors;
    return switch (kind) {
      PowerNodeKind.utility => colors.accent,
      PowerNodeKind.generator => colors.warning,
      PowerNodeKind.pv || PowerNodeKind.pvInverter => colors.success,
      PowerNodeKind.battery || PowerNodeKind.batteryInverter => colors.danger,
      PowerNodeKind.hybridInverter => colors.accent,
      PowerNodeKind.bus => colors.textSecondary,
      PowerNodeKind.mainPanel => colors.textPrimary,
      PowerNodeKind.ats => colors.warning,
    };
  }
}

class _Row extends StatelessWidget {
  final String a;
  final String b;
  final String? note;
  const _Row({required this.a, required this.b, this.note});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs),
      child: Row(
        children: [
          Text('$a -> $b',
              style: type.body.copyWith(color: colors.textSecondary)),
          if (note != null) ...[
            const SizedBox(width: MechXSpacing.sm),
            Text('(${note!})',
                style: type.caption.copyWith(color: colors.textMuted)),
          ],
        ],
      ),
    );
  }
}

class _Interlock extends StatelessWidget {
  final String title;
  final String note;
  const _Interlock({required this.title, required this.note});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Container(
      margin: const EdgeInsets.only(bottom: MechXSpacing.sm),
      padding: const EdgeInsets.all(MechXSpacing.sm),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.control,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: type.label.copyWith(color: colors.textPrimary)),
          const SizedBox(height: 2),
          Text(note, style: type.caption.copyWith(color: colors.textSecondary)),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: context.type.caption.copyWith(
          color: context.colors.textMuted,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
        ),
      );
}
