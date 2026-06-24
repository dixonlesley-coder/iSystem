import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/catalog.dart';

import '../../store/commercial_store.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'commercial_table.dart';

/// The electrical bill of materials table: one row per consolidated line with
/// qty, description, matched brand / series and a matched / unmatched flag.
/// Read-only (the BOM is generated from the sized result + catalogue).
class ElectricalBomView extends ConsumerWidget {
  const ElectricalBomView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final bom = ref.watch(electricalBomProvider);
    final parts = _partIndex();

    final unmatched = bom.lines.where((l) => l.sku == null).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.strings(StringKey.commercialBomTitle),
            style: type.title.copyWith(color: colors.textPrimary)),
        const SizedBox(height: MechXSpacing.xxs),
        Text(
          '${bom.lines.length} line(s) from the sized electrical model, matched '
          'to the parts catalogue. $unmatched line(s) have no catalogue match.',
          style: type.caption.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: MechXSpacing.sm),
        CommercialTable(
          columns: [
            CommercialColumn(context.strings(StringKey.commercialColQty),
                flex: 2, alignEnd: true),
            CommercialColumn(context.strings(StringKey.commercialColPart),
                flex: 8),
            CommercialColumn(context.strings(StringKey.commercialColBrand),
                flex: 4),
            CommercialColumn(context.strings(StringKey.commercialColSku),
                flex: 4),
            CommercialColumn(context.strings(StringKey.commercialColMatch),
                flex: 3),
          ],
          rows: [
            for (final l in bom.lines) _row(context, l, parts[l.sku]),
          ],
        ),
      ],
    );
  }

  CommercialRow _row(BuildContext context, BomLine line, Part? part) {
    final colors = context.colors;
    final matched = line.sku != null;
    return CommercialRow(cells: [
      CommercialCell.text(_qty(line.qty)),
      CommercialCell.text(line.description),
      CommercialCell.text(part?.manufacturer ?? '-'),
      CommercialCell.text(line.sku ?? '-'),
      CommercialCell.text(
        matched
            ? context.strings(StringKey.commercialMatched)
            : context.strings(StringKey.commercialUnmatched),
        color: matched ? colors.success : colors.warning,
      ),
    ]);
  }
}

/// Build a `sku → Part` index over the full catalogue (for brand / unit display).
Map<String, Part> _partIndex() => {
      for (final p in fullCatalog()) p.sku: p,
    };

String _qty(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
