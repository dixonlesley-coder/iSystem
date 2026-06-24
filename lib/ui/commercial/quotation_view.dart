import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/commercial_store.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_text_field.dart';
import 'commercial_table.dart';

/// The priced quotation / proposal: the quote-settings inputs (labour rate +
/// overhead / contingency / margin percentages) over a roll-up table (material
/// subtotal, labour, overhead, contingency, margin, grand total). Recomputes
/// live from the pricelist + settings via [electricalQuotationProvider].
class QuotationView extends ConsumerWidget {
  const QuotationView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final settings = ref.watch(commercialSettingsProvider);
    final ctrl = ref.read(commercialSettingsProvider.notifier);
    final cost = ref.watch(electricalCostProvider);
    final q = ref.watch(electricalQuotationProvider);
    final cur = q.currency;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.strings(StringKey.commercialQuotationTitle),
            style: type.title.copyWith(color: colors.textPrimary)),
        const SizedBox(height: MechXSpacing.xxs),
        Text(
          cost.unmatchedCount > 0
              ? '${cost.unmatchedCount} line(s) are unpriced and excluded from '
                  'the material subtotal.'
              : context.strings(StringKey.commercialAllPriced),
          style: type.caption.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: MechXSpacing.sm),

        // Quote-settings inputs.
        Container(
          padding: const EdgeInsets.all(MechXSpacing.md),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: MechXRadii.card,
            border: Border.all(color: colors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.strings(StringKey.commercialQuoteSettings),
                  style: type.subtitle.copyWith(color: colors.textPrimary)),
              const SizedBox(height: MechXSpacing.sm),
              _NumberRow(
                label: 'Labour rate ($cur / h)',
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
              ),
            ],
          ),
        ),
        const SizedBox(height: MechXSpacing.md),

        // The costed roll-up.
        CommercialTable(
          columns: [
            CommercialColumn(context.strings(StringKey.commercialColItem),
                flex: 6),
            CommercialColumn('Amount ($cur)', flex: 4, alignEnd: true),
          ],
          rows: [
            _money(context.strings(StringKey.commercialItemMaterial),
                q.materialSubtotal),
            _money('Labour (${_fmt(q.labourHours)} h)', q.labourSubtotal),
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
                CommercialCell.text(_fmt(q.grandTotal)),
              ],
            ),
          ],
        ),
      ],
    );
  }

  CommercialRow _money(String label, double amount) => CommercialRow(cells: [
        CommercialCell.text(label),
        CommercialCell.text(_fmt(amount)),
      ]);
}

String _fmt(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

/// A labelled numeric input row used in the quote-settings card.
class _NumberRow extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  const _NumberRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Padding(
      padding: const EdgeInsets.only(bottom: MechXSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: type.body.copyWith(color: colors.textSecondary)),
          ),
          SizedBox(
            width: 160,
            child: MechXTextField(
              value: _fmt(value),
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
}
