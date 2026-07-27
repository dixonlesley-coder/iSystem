import 'package:flutter/widgets.dart';

import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

/// Shared number formatting for the commercial tables, so every surface prints
/// quantities, prices and hours with the same decimals + thousands grouping and
/// lines up under right-aligned, tabular-figure columns.
abstract final class CommercialFormat {
  /// Quantity: integer when whole, else one decimal.
  static String qty(double v) =>
      v == v.roundToDouble() ? _grouped(v, 0) : _grouped(v, 1);

  /// Money / amount: always two decimals with thousands grouping.
  static String money(double v) => _grouped(v, 2);

  /// Hours: always one decimal.
  static String hours(double v) => _grouped(v, 1);

  /// Group the integer part with thousands separators and fix [decimals].
  static String _grouped(double v, int decimals) {
    final neg = v < 0;
    final fixed = v.abs().toStringAsFixed(decimals);
    final dot = fixed.indexOf('.');
    final intPart = dot == -1 ? fixed : fixed.substring(0, dot);
    final frac = dot == -1 ? '' : fixed.substring(dot);
    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
      buf.write(intPart[i]);
    }
    return '${neg ? '-' : ''}$buf$frac';
  }
}

/// One column spec for a [CommercialTable]. [numeric] right-aligns the column
/// and renders its cells in tabular-figure mono so digits line up.
class CommercialColumn {
  final String label;
  final int flex;
  final bool numeric;
  const CommercialColumn(this.label, {this.flex = 1, this.numeric = false});

  bool get alignEnd => numeric;
}

/// One cell — either a piece of text or an arbitrary widget (e.g. a price input).
class CommercialCell {
  final String? text;
  final Color? color;
  final Widget? child;

  const CommercialCell._({this.text, this.color, this.child});

  factory CommercialCell.text(String text, {Color? color}) =>
      CommercialCell._(text: text, color: color);
  factory CommercialCell.widget(Widget child) =>
      CommercialCell._(child: child);
}

/// One data row.
class CommercialRow {
  final List<CommercialCell> cells;
  final bool emphasized;
  const CommercialRow({required this.cells, this.emphasized = false});
}

/// A small, custom (non-Material) data table: a weighted header row over a list
/// of data rows on a card surface. The header recedes (muted, w600, generous
/// padding, a hairline beneath) while the body breaks monotony with subtle zebra
/// striping so numeric columns stay scannable. An [CommercialRow.emphasized]
/// row (the grand total) reads as a boxed-out roll-up: a heavier top hairline, a
/// faint accent wash and a larger, bolder figure. Columns share the width by
/// their [CommercialColumn.flex]; numeric columns right-align in tabular mono.
class CommercialTable extends StatelessWidget {
  final List<CommercialColumn> columns;
  final List<CommercialRow> rows;

  const CommercialTable({super.key, required this.columns, required this.rows});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;

    // A low-alpha tint for every other body row — quiet, but enough to anchor
    // the eye across a wide numeric row.
    final zebra = Color.lerp(colors.surface, colors.surfaceHover, 0.45)!;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // Header — muted, w600, with breathing room and a hairline under it.
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.md,
              vertical: MechXSpacing.sm + 4,
            ),
            decoration: BoxDecoration(
              color: colors.surfaceHover,
              border: Border(bottom: BorderSide(color: colors.border)),
            ),
            child: Row(
              children: [
                for (var i = 0; i < columns.length; i++)
                  Expanded(
                    flex: columns[i].flex,
                    child: Padding(
                      // A gutter between columns so a right-aligned numeric cell
                      // (Qty) never butts against the next column's text — the
                      // header otherwise reads "QtyPart"/"QtyUnit" and a row as
                      // "1MCCB"/"14.8m". The last column keeps the row's edge.
                      padding: EdgeInsets.only(
                        right: i == columns.length - 1
                            ? 0
                            : MechXSpacing.sm + 2,
                      ),
                      child: Text(
                        columns[i].label,
                        textAlign: columns[i].alignEnd
                            ? TextAlign.right
                            : TextAlign.left,
                        style: type.caption.copyWith(
                          color: colors.textMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (rows.isEmpty)
            Container(
              constraints: const BoxConstraints(minHeight: 96),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.md,
                vertical: MechXSpacing.lg,
              ),
              child: Text(
                context.strings(StringKey.commercialNoItems),
                textAlign: TextAlign.center,
                style: type.subtitle.copyWith(color: colors.textMuted),
              ),
            ),
          for (var i = 0; i < rows.length; i++)
            _RowView(
              columns: columns,
              row: rows[i],
              zebra: i.isOdd ? zebra : null,
              isLast: i == rows.length - 1,
            ),
        ],
      ),
    );
  }
}

/// A single body row: the padding rhythm, zebra tint, and the emphasized
/// (grand-total) treatment.
class _RowView extends StatelessWidget {
  final List<CommercialColumn> columns;
  final CommercialRow row;
  final Color? zebra;
  final bool isLast;

  const _RowView({
    required this.columns,
    required this.row,
    required this.zebra,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final emph = row.emphasized;

    final Color? bg =
        emph ? Color.lerp(colors.surface, colors.accent, 0.06) : zebra;

    final Border? border = emph
        // A heavier hairline boxes the total out from the lines above.
        ? Border(top: BorderSide(color: colors.border, width: 1.5))
        : (isLast
            ? null
            : Border(bottom: BorderSide(color: colors.border)));

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: MechXSpacing.md,
        vertical: emph ? MechXSpacing.sm + 4 : MechXSpacing.sm + 2,
      ),
      decoration: BoxDecoration(color: bg, border: border),
      child: Row(
        children: [
          for (var j = 0; j < columns.length; j++)
            Expanded(
              flex: columns[j].flex,
              child: Padding(
                // Match the header gutter so numeric cells never touch the next
                // column (see the header note).
                padding: EdgeInsets.only(
                  right: j == columns.length - 1 ? 0 : MechXSpacing.sm + 2,
                ),
                child: _cell(
                  context,
                  row.cells[j],
                  column: columns[j],
                  emphasized: emph,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _cell(BuildContext context, CommercialCell cell,
      {required CommercialColumn column, required bool emphasized}) {
    final colors = context.colors;
    final type = context.type;
    final alignEnd = column.alignEnd;
    if (cell.child != null) {
      return Align(
        alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
        child: cell.child,
      );
    }

    // Numeric cells use the mono face routed through the shared tabular-figure
    // token so right-aligned Qty/price columns line up and never shuffle as a
    // recompute changes digits (M2 — one source for `tnum`, not an inline
    // FontFeature literal).
    final base = column.numeric
        ? MechXTypography.tabular(
            type.mono.copyWith(fontSize: type.body.fontSize))
        : type.body;

    return Text(
      cell.text ?? '',
      textAlign: alignEnd ? TextAlign.right : TextAlign.left,
      style: base.copyWith(
        color: cell.color ?? colors.textPrimary,
        fontWeight: emphasized ? FontWeight.w700 : null,
        fontSize: emphasized ? (base.fontSize ?? 14.5) + 1 : null,
      ),
    );
  }
}
