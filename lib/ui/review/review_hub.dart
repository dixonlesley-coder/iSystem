import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/electrical_store.dart';
import '../../store/solve_store.dart';
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

    final warnings = elec.warnings.length;
    final panels = elec.panels.length;

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
        const SizedBox(height: MechXSpacing.lg),
        const HubNote(
          'Export the Markdown calculation report from the top bar for the full '
          'sizing breakdown, including the unverified-standards checklist.',
        ),
        if (warnings > 0) ...[
          const SizedBox(height: MechXSpacing.md),
          _WarningList(),
        ],
      ],
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
                      borderRadius:
                          const BorderRadius.all(Radius.circular(4)),
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
