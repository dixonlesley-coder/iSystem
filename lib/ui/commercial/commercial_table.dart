import 'package:flutter/widgets.dart';

import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

/// One column spec for a [CommercialTable].
class CommercialColumn {
  final String label;
  final int flex;
  final bool alignEnd;
  const CommercialColumn(this.label, {this.flex = 1, this.alignEnd = false});
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

/// A small, custom (non-Material) data table: a header row over a list of data
/// rows on a card surface, with hairline separators. Columns share the width by
/// their [CommercialColumn.flex]. Used by the commercial BOM / pricelist /
/// quotation views.
class CommercialTable extends StatelessWidget {
  final List<CommercialColumn> columns;
  final List<CommercialRow> rows;

  const CommercialTable({super.key, required this.columns, required this.rows});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // Header.
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.md,
              vertical: MechXSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: colors.surfaceHover,
              border: Border(bottom: BorderSide(color: colors.border)),
            ),
            child: Row(
              children: [
                for (final c in columns)
                  Expanded(
                    flex: c.flex,
                    child: Text(
                      c.label,
                      textAlign: c.alignEnd ? TextAlign.right : TextAlign.left,
                      style: type.caption.copyWith(color: colors.textMuted),
                    ),
                  ),
              ],
            ),
          ),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(MechXSpacing.md),
              child: Text(context.strings(StringKey.commercialNoItems),
                  style: type.body.copyWith(color: colors.textMuted)),
            ),
          for (var i = 0; i < rows.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.md,
                vertical: MechXSpacing.sm,
              ),
              decoration: BoxDecoration(
                border: i == rows.length - 1
                    ? null
                    : Border(bottom: BorderSide(color: colors.border)),
              ),
              child: Row(
                children: [
                  for (var j = 0; j < columns.length; j++)
                    Expanded(
                      flex: columns[j].flex,
                      child: _cell(
                        context,
                        rows[i].cells[j],
                        alignEnd: columns[j].alignEnd,
                        emphasized: rows[i].emphasized,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _cell(BuildContext context, CommercialCell cell,
      {required bool alignEnd, required bool emphasized}) {
    final colors = context.colors;
    final type = context.type;
    if (cell.child != null) {
      return Align(
        alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
        child: cell.child,
      );
    }
    return Text(
      cell.text ?? '',
      textAlign: alignEnd ? TextAlign.right : TextAlign.left,
      style: type.body.copyWith(
        color: cell.color ?? colors.textPrimary,
        fontWeight: emphasized ? FontWeight.w700 : null,
      ),
    );
  }
}
