import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/catalog.dart';

import '../../store/commercial_store.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_text_field.dart';
import 'commercial_table.dart';

/// The pricelist editor: every distinct catalogue SKU referenced by the live BOM
/// gets an editable unit-price cell. Prices are persisted with the project (the
/// committed catalogue stays price-free). Editing a cell recomputes the cost +
/// quotation live.
class PricelistScreen extends ConsumerWidget {
  const PricelistScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final bom = ref.watch(electricalBomProvider);
    final settings = ref.watch(commercialSettingsProvider);
    final ctrl = ref.read(commercialSettingsProvider.notifier);
    final parts = _partIndex();

    // Distinct, matched SKUs in BOM order — the lines that can be priced.
    final skus = <String>[];
    for (final l in bom.lines) {
      final sku = l.sku;
      if (sku != null && !skus.contains(sku)) skus.add(sku);
    }

    final priced = skus.where((s) => settings.priceList.containsKey(s)).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.strings(StringKey.commercialPricelistTitle),
            style: type.title.copyWith(color: colors.textPrimary)),
        const SizedBox(height: MechXSpacing.xxs),
        Text(
          context.strings.format(StringKey.commercialPricelistLead,
              {'priced': priced, 'total': skus.length}),
          style: type.caption.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: MechXSpacing.sm),
        CommercialTable(
          columns: [
            CommercialColumn(context.strings(StringKey.commercialColSku),
                flex: 4),
            CommercialColumn(context.strings(StringKey.commercialColPart),
                flex: 8),
            CommercialColumn(context.strings(StringKey.commercialColUnit),
                flex: 2),
            CommercialColumn(context.strings(StringKey.commercialColUnitPrice),
                flex: 4, numeric: true),
          ],
          rows: [
            for (final sku in skus)
              CommercialRow(cells: [
                CommercialCell.text(sku),
                CommercialCell.text(_describe(parts[sku])),
                CommercialCell.text(parts[sku]?.unit ?? 'ea'),
                CommercialCell.widget(
                  _PriceField(
                    key: ValueKey(sku),
                    value: settings.priceList[sku],
                    onChanged: (v) => ctrl.setPrice(sku, v),
                  ),
                ),
              ]),
          ],
        ),
      ],
    );
  }

  String _describe(Part? p) {
    if (p == null) return '-';
    return '${p.manufacturer} ${p.model}';
  }
}

Map<String, Part> _partIndex() => {
      for (final p in fullCatalog()) p.sku: p,
    };

/// A small numeric input for a unit price: parses on change (a blank or invalid
/// value clears the price). The foundation [MechXTextField] supplies the focus
/// animation + ring; a muted "0.00" hint signals an empty, editable cell.
/// Width-capped so the column stays tidy.
class _PriceField extends StatelessWidget {
  final double? value;
  final ValueChanged<double?> onChanged;

  const _PriceField({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      child: MechXTextField(
        value: value == null ? '' : _fmt(value!),
        hint: CommercialFormat.money(0),
        onChanged: (s) {
          final trimmed = s.trim();
          if (trimmed.isEmpty) {
            onChanged(null);
            return;
          }
          final parsed = double.tryParse(trimmed.replaceAll(',', ''));
          onChanged(parsed);
        },
      ),
    );
  }

  // Keep the edit value plain (no grouping) so it round-trips through the
  // parser cleanly; the hint carries the "0.00" formatting cue.
  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();
}
