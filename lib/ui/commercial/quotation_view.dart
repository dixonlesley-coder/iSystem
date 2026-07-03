import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/commercial_store.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_text_field.dart';
import 'commercial_table.dart';

/// The priced quotation / proposal: the quote-settings inputs (labour rate +
/// overhead / contingency / margin percentages) over the unified M+E+P roll-up
/// table (per-discipline material subtotals, labour, overhead, contingency,
/// margin, grand total). Recomputes live from the pricelist + settings via
/// [mepQuotationProvider].
class QuotationView extends ConsumerWidget {
  const QuotationView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final settings = ref.watch(commercialSettingsProvider);
    final ctrl = ref.read(commercialSettingsProvider.notifier);
    final q = ref.watch(mepQuotationProvider);
    final cur = q.currency;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.strings(StringKey.commercialQuotationTitle),
            style: type.title.copyWith(color: colors.textPrimary)),
        const SizedBox(height: MechXSpacing.xxs),
        Text(
          q.unpricedCount > 0
              ? context.strings.format(StringKey.commercialUnpricedExcluded,
                  {'n': q.unpricedCount})
              : context.strings(StringKey.commercialAllPriced),
          style: type.caption.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: MechXSpacing.sm),

        // Quote-settings inputs — a lifted card (shadow + generous padding) so
        // it reads as the "user input area" floating above the flush roll-up.
        Container(
          padding: const EdgeInsets.all(MechXSpacing.lg),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: MechXRadii.card,
            border: Border.all(color: colors.border),
            boxShadow: MechXShadow.card,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.strings(StringKey.commercialQuoteSettings),
                  style: type.subtitle.copyWith(color: colors.textPrimary)),
              const SizedBox(height: MechXSpacing.md),
              _NumberRow(
                label: context.strings
                    .format(StringKey.commercialLabourRate, {'cur': cur}),
                value: settings.labourRatePerHour,
                onChanged: ctrl.setLabourRate,
              ),
              _NumberRow(
                label: context.strings(StringKey.commercialOverheadPct),
                value: settings.overheadPct,
                onChanged: ctrl.setOverheadPct,
              ),
              _NumberRow(
                label: context.strings(StringKey.commercialContingencyPct),
                value: settings.contingencyPct,
                onChanged: ctrl.setContingencyPct,
              ),
              _NumberRow(
                label: context.strings(StringKey.commercialMarginPct),
                value: settings.marginPct,
                onChanged: ctrl.setMarginPct,
                last: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: MechXSpacing.md),

        // The costed roll-up — the emphasized grand-total row is boxed out by
        // the table (heavier top hairline + accent wash + larger bold figure).
        CommercialTable(
          columns: [
            CommercialColumn(context.strings(StringKey.commercialColItem),
                flex: 6),
            CommercialColumn(
                context.strings
                    .format(StringKey.commercialColAmount, {'cur': cur}),
                flex: 4,
                numeric: true),
          ],
          rows: [
            _money('Mechanical material', q.mechanicalMaterial),
            _money('Electrical material', q.electricalMaterial),
            _money(context.strings(StringKey.commercialItemMaterial),
                q.materialSubtotal),
            _money(
                context.strings.format(StringKey.commercialLabourHours,
                    {'hours': CommercialFormat.hours(q.labourHours)}),
                q.labourSubtotal),
            _money(context.strings(StringKey.commercialItemOverhead),
                q.overhead),
            _money(context.strings(StringKey.commercialItemContingency),
                q.contingency),
            _money(context.strings(StringKey.commercialItemMargin), q.margin),
            CommercialRow(
              emphasized: true,
              cells: [
                CommercialCell.text(
                    context.strings(StringKey.commercialItemGrandTotal)),
                CommercialCell.text(CommercialFormat.money(q.grandTotal)),
              ],
            ),
          ],
        ),
      ],
    );
  }

  CommercialRow _money(String label, double amount) => CommercialRow(cells: [
        CommercialCell.text(label),
        CommercialCell.text(CommercialFormat.money(amount)),
      ]);
}

/// A labelled numeric input row used in the quote-settings card.
class _NumberRow extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final bool last;

  const _NumberRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : MechXSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: type.body.copyWith(color: colors.textSecondary)),
          ),
          SizedBox(
            width: 160,
            child: MechXTextField(
              value: _editValue(value),
              onChanged: (s) {
                final parsed = double.tryParse(s.trim().replaceAll(',', ''));
                if (parsed != null) onChanged(parsed);
              },
            ),
          ),
        ],
      ),
    );
  }

  // Plain (un-grouped) edit value so it parses back cleanly.
  static String _editValue(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
}
