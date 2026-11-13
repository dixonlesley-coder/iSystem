// Drawing review F8 follow-up (2026-11-13) — every SLD-family LEGEND entry
// stays inside its box: a long entry wraps onto following lines (hanging
// after its `CODE  -  ` lead) and the box grows a row per printed line, in
// the PDF and the DXF alike. 7 pt minimum unchanged (rows print at 7.5 pt).
import 'dart:convert';

import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/electrical_pdf_export.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:test/test.dart';

void main() {
  const long = SldLegendEntry('TERPASANG / KEBUTUHAN',
      'TOTAL: connected = sum of the DAYA rows; demand = DAYA x DF x board div, standby ways excluded');
  const short = SldLegendEntry('MCB', 'Miniature circuit breaker');
  const sheet = SldSheet(
    prims: [SldRect(0, 0, 400, 200), SldLabel(10, 20, 'BOARD', size: 13)],
    minX: 0,
    minY: 0,
    maxX: 400,
    maxY: 200,
    legend: [short, long],
    supplyNote: '3-phase 400V demand 10 kW',
  );

  test('a long entry wraps, hanging after its lead; a short one does not', () {
    final s = sldLegendEntryLines(short);
    expect(s.lines, ['MCB  -  Miniature circuit breaker']);
    final l = sldLegendEntryLines(long);
    expect(l.lines.length, greaterThan(1));
    expect(l.lines.first, startsWith('TERPASANG / KEBUTUHAN  -  TOTAL:'));
    // Nothing lost: the wrapped words re-join to the one-line entry.
    expect(l.lines.join(' ').replaceAll(RegExp(r'\s+'), ' '),
        '${long.code} - ${long.meaning}'.replaceAll(RegExp(r'\s+'), ' '));
    for (var k = 0; k < l.lines.length; k++) {
      final w = helveticaTextWidth(l.lines[k], 1) + (k == 0 ? 0 : l.indentEm);
      expect(w, lessThanOrEqualTo(kSldLegendWrapEm + 1e-9), reason: l.lines[k]);
    }
    expect(sldLegendLineCount(sheet.legend), 1 + l.lines.length);
  });

  test('PDF: no legend text extends beyond its box', () {
    final pdf = latin1.decode(electricalSldSheetsToPdf(
        sheets: [sheet], chrome: const DrawingChrome(drawingNumber: 'E-1')));
    // The legend box: the rect stroked right after the 0.8 w legend pen.
    final box = RegExp(r'0\.8 w\n([\d.]+) ([\d.]+) ([\d.]+) ([\d.]+) re S')
        .firstMatch(pdf)!;
    final bx = double.parse(box[1]!), by = double.parse(box[2]!);
    final bw = double.parse(box[3]!), bh = double.parse(box[4]!);
    final rows = RegExp(r'BT /F1 7\.5 Tf [\d. ]+rg ([\d.]+) ([\d.]+) Td '
            r'\((.*)\) Tj ET')
        .allMatches(pdf)
        .toList();
    expect(rows.length, sldLegendLineCount(sheet.legend));
    for (final m in rows) {
      final x = double.parse(m[1]!), y = double.parse(m[2]!);
      final right = x + helveticaTextWidth(m[3]!, 7.5);
      expect(right, lessThanOrEqualTo(bx + bw), reason: m[3]);
      expect(y, inInclusiveRange(by, by + bh), reason: m[3]);
    }
    // The wrapped continuation hangs after the lead (indented).
    expect(double.parse(rows.last[1]!), greaterThan(double.parse(rows[0][1]!)));
  });
}
