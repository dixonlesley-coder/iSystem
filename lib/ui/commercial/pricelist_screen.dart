import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/bom.dart' as elec show BomLine;
import 'package:mechx_engine/electrical/catalog.dart';

import '../../store/app_state.dart' show AppLocale, localeProvider;
import '../../store/commercial_store.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_text_field.dart';
import 'commercial_table.dart';
import 'money_input.dart';

/// The pricelist editor: every distinct SKU / key referenced by the live BOM
/// gets an editable unit-price cell — a MECHANICAL section (pipe/duct + fittings,
/// H10) above the ELECTRICAL catalogue section. Prices are persisted with the
/// project (the committed catalogue stays price-free). Editing a cell recomputes
/// the cost + quotation live.
class PricelistScreen extends ConsumerWidget {
  const PricelistScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MechanicalPricelist(),
        SizedBox(height: MechXSpacing.xl),
        _ElectricalPricelist(),
      ],
    );
  }
}

/// The mechanical price rows — one per sized pipe/duct line + fitting, keyed by
/// the stable mechanical key. Hidden entirely until something mechanical is sized
/// (so an electrical-only project's pricelist is unchanged).
class _MechanicalPricelist extends ConsumerWidget {
  const _MechanicalPricelist();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final est = ref.watch(mechanicalCostProvider);
    final settings = ref.watch(commercialSettingsProvider);
    final ctrl = ref.read(commercialSettingsProvider.notifier);

    if (est.lines.isEmpty) return const SizedBox.shrink();

    final priced =
        est.lines.where((l) => settings.priceList.containsKey(l.key)).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Mechanical pricelist',
            style: type.title.copyWith(color: colors.textPrimary)),
        const SizedBox(height: MechXSpacing.xxs),
        Text(
          '$priced of ${est.lines.length} priced',
          style: type.caption.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: MechXSpacing.sm),
        CommercialTable(
          columns: const [
            CommercialColumn('Item', flex: 10),
            CommercialColumn('Unit', flex: 2),
            CommercialColumn('Unit price', flex: 4, numeric: true),
          ],
          rows: [
            for (final l in est.lines)
              CommercialRow(cells: [
                CommercialCell.text(l.description),
                CommercialCell.text(l.unit),
                CommercialCell.widget(
                  _PriceField(
                    key: ValueKey(l.key),
                    value: settings.priceList[l.key],
                    onChanged: (v) => ctrl.setPrice(l.key, v),
                  ),
                ),
              ]),
          ],
        ),
      ],
    );
  }
}

/// The electrical catalogue price rows — every distinct matched SKU referenced by
/// the live electrical BOM.
class _ElectricalPricelist extends ConsumerWidget {
  const _ElectricalPricelist();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final bom = ref.watch(electricalBomProvider);
    final settings = ref.watch(commercialSettingsProvider);
    final ctrl = ref.read(commercialSettingsProvider.notifier);
    final parts = _partIndex();

    // Distinct PRICELIST KEYS in BOM order — every line that can be priced:
    // matched SKUs, multi-core cables (`SKU:nC`) and the unmatched enclosure /
    // busbar / RCD / accessory lines' `elec:` keys (audit r8 — these used to
    // be unpriceable, silently leaving the panel box out of the sell price).
    final keys = <String>[];
    final lineFor = <String, elec.BomLine>{};
    for (final l in bom.lines) {
      final k = l.priceKey;
      if (k != null && !keys.contains(k)) {
        keys.add(k);
        lineFor[k] = l;
      }
    }

    final priced = keys
        .where((k) =>
            settings.priceList.containsKey(k) ||
            (lineFor[k]!.sku != null &&
                settings.priceList.containsKey(lineFor[k]!.sku)))
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.strings(StringKey.commercialPricelistTitle),
            style: type.title.copyWith(color: colors.textPrimary)),
        const SizedBox(height: MechXSpacing.xxs),
        Text(
          context.strings.format(StringKey.commercialPricelistLead,
              {'priced': priced, 'total': keys.length}),
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
            for (final k in keys)
              CommercialRow(cells: [
                CommercialCell.text(lineFor[k]!.sku ?? '-'),
                CommercialCell.text(_describe(k, lineFor[k]!, parts)),
                CommercialCell.text(lineFor[k]!.sku != null
                    ? (parts[lineFor[k]!.sku]?.unit ?? 'ea')
                    : (lineFor[k]!.category == PartCategory.cable
                        ? 'm'
                        : 'ea')),
                CommercialCell.widget(
                  _PriceField(
                    key: ValueKey(k),
                    // A legacy bare-SKU price still applies until re-priced.
                    value: settings.priceList[k] ??
                        (lineFor[k]!.sku == null
                            ? null
                            : settings.priceList[lineFor[k]!.sku]),
                    onChanged: (v) => ctrl.setPrice(k, v),
                  ),
                ),
              ]),
          ],
        ),
      ],
    );
  }

  String _describe(String key, elec.BomLine line, Map<String, Part> parts) {
    final p = line.sku == null ? null : parts[line.sku];
    if (p == null) return line.description;
    final cores = RegExp(r':(\d+)C$').firstMatch(key)?.group(1);
    return '${p.manufacturer} ${p.model}${cores != null ? ' · $cores-core' : ''}';
  }
}

Map<String, Part> _partIndex() => {
      for (final p in fullCatalog()) p.sku: p,
    };

/// A small numeric input for a unit price. Parses LOCALE-AWARE
/// ([parseMoneyInput] — `12.500` is twelve thousand five hundred under the
/// Indonesian notation the quotation is issued in); only an explicitly EMPTY
/// field clears the price — an unparseable entry keeps the previous value and
/// shows an inline error instead of silently un-pricing the line (audit r8).
/// The foundation [MechXTextField] supplies the focus animation + ring; a muted
/// "0,00" hint signals an empty, editable cell. Width-capped.
class _PriceField extends ConsumerStatefulWidget {
  final double? value;
  final ValueChanged<double?> onChanged;

  const _PriceField({super.key, required this.value, required this.onChanged});

  @override
  ConsumerState<_PriceField> createState() => _PriceFieldState();
}

class _PriceFieldState extends ConsumerState<_PriceField> {
  bool _invalid = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final indonesian = ref.watch(localeProvider) == AppLocale.id;
    return SizedBox(
      width: 140,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          MechXTextField(
            value: widget.value == null ? '' : _fmt(widget.value!),
            hint: CommercialFormat.money(0),
            // Round 29 — commit on blur / Enter: one price edit = ONE
            // settings undo step (was one per keystroke).
            onCommitted: (s) {
              final trimmed = s.trim();
              if (trimmed.isEmpty) {
                setState(() => _invalid = false);
                widget.onChanged(null);
                return;
              }
              final parsed = parseMoneyInput(trimmed, indonesian: indonesian);
              if (parsed == null) {
                setState(() => _invalid = true);
                return; // keep the previous price
              }
              setState(() => _invalid = false);
              widget.onChanged(parsed);
            },
          ),
          if (_invalid)
            Text(
              context.strings(StringKey.commercialInvalidNumber),
              style: type.caption.copyWith(color: colors.danger),
            ),
        ],
      ),
    );
  }

  // Keep the edit value plain (no grouping) so it round-trips through the
  // parser cleanly; the hint carries the "0,00" formatting cue.
  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();
}
