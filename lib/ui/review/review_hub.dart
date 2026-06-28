import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

import '../../store/electrical_store.dart';
import '../../store/solve_store.dart';
import '../canvas/service_style.dart';
import '../inspector/project_panel.dart' show buildComplianceSummary;
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/hub_scaffold.dart';
import '../widgets/severity_glyph.dart';
import 'issues_card.dart';

/// The Review hub — a calm landing for checking the design before issue.
///
/// For this pass it surfaces what the engine already computes (electrical
/// warnings, the BOM line count) and points at the existing calc-report export.
/// The detailed Review tabs come together in a later wave; this is the durable
/// shell PanelMaker's "Review" group maps onto.
class ReviewHub extends ConsumerWidget {
  const ReviewHub({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final elec = ref.watch(electricalResultProvider);
    final bom = ref.watch(bomProvider);
    final cutPlan = ref.watch(pipeCutPlanProvider);

    final warnings = elec.warnings.length;
    final panels = elec.panels.length;

    // Overall pipe efficiency across all (service, diameter) groups.
    var totalBars = 0;
    var purchased = 0.0, required = 0.0;
    for (final g in cutPlan) {
      totalBars += g.plan.totalBars;
      purchased += g.plan.purchasedM;
      required += g.plan.requiredM;
    }
    final wastePct = purchased <= 0 ? 0.0 : 100 * (purchased - required) / purchased;

    return HubScaffold(
      title: 'Review',
      lead: 'Check the design before you issue it.',
      children: [
        const _ComplianceCard(),
        const SizedBox(height: MechXSpacing.md),
        HubStatRow(
          stats: [
            ('Panels sized', '$panels'),
            ('Electrical warnings', '$warnings'),
            ('BOM line items', '${bom.length}'),
          ],
        ),
        if (cutPlan.isNotEmpty) ...[
          const SizedBox(height: MechXSpacing.md),
          HubStatRow(
            stats: [
              ('Stock pipes', '$totalBars'),
              ('Pipe required', '${required.toStringAsFixed(1)} m'),
              ('Offcut waste', '${wastePct.toStringAsFixed(0)}%'),
            ],
          ),
          const SizedBox(height: MechXSpacing.md),
          _CutPlanCard(),
        ],
        const SizedBox(height: MechXSpacing.md),
        const IssuesCard(),
        const SizedBox(height: MechXSpacing.md),
        _ConsumablesCard(),
        const SizedBox(height: MechXSpacing.lg),
        const HubNote(
          'Stock lengths: 4 m PVC/PPR, 6 m steel (sprinkler/hydrant), and duct '
          'sections 1.2 m BJLS / 4 m PU. The cut plan reuses offcuts to minimise '
          'waste; couplings and duct flanges on the canvas fall at these '
          'boundaries. Export the Markdown calc report for the full breakdown.',
        ),
      ],
    );
  }
}

/// The pre-issue compliance roll-up: an overall PASS / REVIEW REQUIRED verdict
/// plus the three category rows (air velocities / sheet calibration / standards
/// verification) the unified MEP report also prints. Read-only over the shared
/// [buildComplianceSummary] (which derives from `designIssuesProvider`) — it
/// invents no new checks, so the Review hub and the exported report always agree.
class _ComplianceCard extends ConsumerWidget {
  const _ComplianceCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final summary = buildComplianceSummary(ref);
    final allPass = summary.allPass;
    final headlineColor = allPass ? colors.success : colors.warning;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.border),
      ),
      padding: const EdgeInsets.all(MechXSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Overall verdict headline with a redundant glyph (check / "!") so it
          // reads without hue alone.
          Row(
            children: [
              CustomPaint(
                size: const Size(16, 16),
                painter: SeverityGlyph(
                  kind: allPass
                      ? SeverityGlyphKind.check
                      : SeverityGlyphKind.warn,
                  color: headlineColor,
                ),
              ),
              const SizedBox(width: MechXSpacing.sm),
              Text(
                allPass ? 'PASS' : 'REVIEW REQUIRED',
                style: type.subtitle.copyWith(color: headlineColor),
              ),
              const SizedBox(width: MechXSpacing.sm),
              Text('design sign-off',
                  style: type.caption.copyWith(color: colors.textMuted)),
            ],
          ),
          const SizedBox(height: MechXSpacing.sm),
          for (final item in summary.items)
            Padding(
              padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: MechXSpacing.sm),
                    child: CustomPaint(
                      size: const Size(11, 11),
                      painter: SeverityGlyph(
                        kind: item.pass
                            ? SeverityGlyphKind.check
                            : SeverityGlyphKind.warn,
                        color: item.pass ? colors.success : colors.warning,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(item.category,
                        style: type.caption
                            .copyWith(color: colors.textPrimary)),
                  ),
                  Text(
                    item.pass ? 'PASS' : 'REVIEW',
                    style: type.caption.copyWith(
                      color: item.pass ? colors.success : colors.warning,
                    ),
                  ),
                  if (item.detail.isNotEmpty) ...[
                    const SizedBox(width: MechXSpacing.sm),
                    Flexible(
                      child: Text(
                        item.detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style:
                            type.caption.copyWith(color: colors.textMuted),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The pipe cut plan: per (service, diameter), how many stock bars are needed
/// (with offcut reuse) and the resulting waste — the efficiency engine's output.
class _CutPlanCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final plan = ref.watch(pipeCutPlanProvider);
    if (plan.isEmpty) return const SizedBox.shrink();

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
          Text('Pipe cut plan',
              style: type.subtitle.copyWith(color: colors.textPrimary)),
          const SizedBox(height: MechXSpacing.sm),
          for (final g in plan)
            Padding(
              padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      // Ducts size by Ø + the BJLS/PU section; pipes by DN.
                      g.service.isAir
                          ? '${serviceLabel(g.service)}  Ø${g.diameterMm}  '
                              '${g.stockLengthM == 4.0 ? 'PU' : 'BJLS'}'
                          : '${serviceLabel(g.service)}  DN${g.diameterMm}',
                      style:
                          type.caption.copyWith(color: colors.textSecondary),
                    ),
                  ),
                  Text(
                    '${g.plan.totalBars} x '
                    '${g.stockLengthM.toStringAsFixed(g.service.isAir ? 1 : 0)} m'
                    '  ·  ${g.plan.wastePercent.toStringAsFixed(0)}% waste',
                    style: type.mono.copyWith(color: colors.textPrimary),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Jointing-consumables estimate — cans of PVC cement, tubes of duct sealant,
/// rolls of thread tape — for the quotation. Hidden until something needs them.
class _ConsumablesCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final e = ref.watch(consumablesProvider);
    if (e.isEmpty) return const SizedBox.shrink();

    final rows = <(String, String)>[
      if (e.pvcCementCans > 0)
        ('PVC solvent cement', '${e.pvcCementCans} can'
            '${e.pvcCementCans == 1 ? '' : 's'}  (${e.solventJoints} joints)'),
      if (e.ductSealantCartridges > 0)
        ('Duct joint sealant', '${e.ductSealantCartridges} cartridge'
            '${e.ductSealantCartridges == 1 ? '' : 's'}  '
            '(${e.ductSealMetres.toStringAsFixed(1)} m)'),
      if (e.threadTapeRolls > 0)
        ('Thread-seal tape', '${e.threadTapeRolls} roll'
            '${e.threadTapeRolls == 1 ? '' : 's'}  (${e.threadedJoints} joints)'),
    ];

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
          Text('Consumables (estimate)',
              style: type.subtitle.copyWith(color: colors.textPrimary)),
          const SizedBox(height: MechXSpacing.sm),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
              child: Row(
                children: [
                  Expanded(
                    child: Text(r.$1,
                        style: type.caption
                            .copyWith(color: colors.textSecondary)),
                  ),
                  Text(r.$2,
                      style: type.mono.copyWith(color: colors.textPrimary)),
                ],
              ),
            ),
          Text(
            'Estimate — coverage assumes ~1 L cement tins, 300 ml sealant '
            'cartridges, 30 joints/tape roll (verify per datasheet). PPR water '
            'pipe is heat-fused (no cement).',
            style: type.caption.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

