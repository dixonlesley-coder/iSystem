import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/electrical_store.dart';
import '../../store/solve_store.dart';
import '../canvas/service_style.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/hub_scaffold.dart';

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
      lead: 'Check the design before you issue it. The detailed review tabs are '
          'coming together; for now this surfaces what the engine already knows.',
      children: [
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
        const SizedBox(height: MechXSpacing.lg),
        const HubNote(
          'Stock pipes assume 4 m PVC/PPR and 6 m steel (sprinkler/hydrant); the '
          'cut plan reuses offcuts to minimise waste. Couplings on the canvas '
          'fall at these stock boundaries. Export the Markdown calc report from '
          'the top bar for the full sizing breakdown.',
        ),
        if (warnings > 0) ...[
          const SizedBox(height: MechXSpacing.md),
          _WarningList(),
        ],
      ],
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
                      '${serviceLabel(g.service)}  DN${g.diameterMm}',
                      style:
                          type.caption.copyWith(color: colors.textSecondary),
                    ),
                  ),
                  Text(
                    '${g.plan.totalBars} x ${g.stockLengthM.toStringAsFixed(0)} m'
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

/// Lists the electrical warnings the A4 engine raised, so Review is not a blank
/// placeholder when the model has something worth flagging.
class _WarningList extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final elec = ref.watch(electricalResultProvider);

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
          Text('Electrical warnings',
              style: type.subtitle.copyWith(color: colors.textPrimary)),
          const SizedBox(height: MechXSpacing.sm),
          for (final w in elec.warnings)
            Padding(
              padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.only(
                        top: 5, right: MechXSpacing.sm),
                    decoration: BoxDecoration(
                      color: colors.warning,
                      borderRadius: const BorderRadius.all(MechXRadii.xs),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      w.message,
                      style:
                          type.caption.copyWith(color: colors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
