import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/catalog.dart';

import '../../store/commercial_store.dart';
import '../strings/app_strings.dart';
import '../strings/plural.dart';
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
          context.strings.format(StringKey.commercialBomLead,
              {'lines': bom.lines.length, 'unmatched': unmatched}),
          style: type.caption.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: MechXSpacing.sm),
        CommercialTable(
          columns: [
            CommercialColumn(context.strings(StringKey.commercialColQty),
                flex: 2, numeric: true),
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
    final matched = line.sku != null;
    return CommercialRow(cells: [
      CommercialCell.text(CommercialFormat.qty(line.qty)),
      CommercialCell.text(line.description),
      CommercialCell.text(part?.manufacturer ?? '-'),
      CommercialCell.text(line.sku ?? '-'),
      CommercialCell.widget(_MatchBadge(matched: matched)),
    ]);
  }
}

/// A small pill that flags whether a BOM line matched the catalogue: a tinted
/// success / warning fill with the label in the full-strength tier colour and a
/// hairline of the same hue — legible in both light and dark (the old flat
/// warning text was too faint on the light surface).
class _MatchBadge extends StatelessWidget {
  final bool matched;
  const _MatchBadge({required this.matched});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final color = matched ? colors.success : colors.warning;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MechXSpacing.sm,
        vertical: MechXSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: color.withAlpha(38),
        borderRadius: const BorderRadius.all(MechXRadii.pill),
        border: Border.all(color: color.withAlpha(122)),
      ),
      child: Text(
        matched
            ? context.strings(StringKey.commercialMatched)
            : context.strings(StringKey.commercialUnmatched),
        style: type.caption.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Build a `sku → Part` index over the full catalogue (for brand / unit display).
Map<String, Part> _partIndex() => {
      for (final p in fullCatalog()) p.sku: p,
    };

/// The MECHANICAL bill of materials table (H10): one row per priced mechanical
/// line (pipe/duct length priced per metre, fittings per piece), with qty, unit,
/// item and a priced / unpriced flag. Read-only — derived from the sized
/// mechanical network + fittings; prices live with the project.
class MechanicalBomView extends ConsumerWidget {
  const MechanicalBomView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final est = ref.watch(mechanicalCostProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Mechanical BOM',
            style: type.title.copyWith(color: colors.textPrimary)),
        const SizedBox(height: MechXSpacing.xxs),
        Text(
          est.lines.isEmpty
              ? 'Size a mechanical network to price its pipe, duct and fittings.'
              : '${pluralCount(est.lines.length, 'line', 'lines')}, ${est.unpricedCount} unpriced',
          style: type.caption.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: MechXSpacing.sm),
        CommercialTable(
          columns: const [
            CommercialColumn('Qty', flex: 2, numeric: true),
            CommercialColumn('Unit', flex: 2),
            CommercialColumn('Item', flex: 9),
            CommercialColumn('Priced', flex: 3),
          ],
          rows: [
            for (final l in est.lines)
              CommercialRow(cells: [
                CommercialCell.text(CommercialFormat.qty(l.qty)),
                CommercialCell.text(l.unit),
                CommercialCell.text(l.description),
                CommercialCell.widget(_PricedBadge(priced: l.priced)),
              ]),
          ],
        ),
      ],
    );
  }
}

/// A small pill flagging whether a mechanical line carries a price (green) or is
/// still unpriced (warning) — mirrors the electrical match badge.
class _PricedBadge extends StatelessWidget {
  final bool priced;
  const _PricedBadge({required this.priced});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final color = priced ? colors.success : colors.warning;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MechXSpacing.sm,
        vertical: MechXSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: color.withAlpha(38),
        borderRadius: const BorderRadius.all(MechXRadii.pill),
        border: Border.all(color: color.withAlpha(122)),
      ),
      child: Text(
        priced ? 'priced' : 'unpriced',
        style: type.caption.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
