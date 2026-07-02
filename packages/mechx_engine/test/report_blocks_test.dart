import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/report/report_blocks.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:test/test.dart';

import 'report_test_fixtures.dart';

void main() {
  group('renderRptMarkdown per-block behaviour', () {
    test('heading levels emit #-runs with a trailing blank line', () {
      expect(renderRptMarkdown(const [RptHeading(1, 'Title')]), '# Title\n\n');
      expect(renderRptMarkdown(const [RptHeading(2, 'Sec')]), '## Sec\n\n');
      expect(renderRptMarkdown(const [RptHeading(3, 'Sub')]), '### Sub\n\n');
    });

    test('a tight heading emits NO blank line after itself', () {
      expect(
        renderRptMarkdown(
            const [RptHeading(2, 'T', tight: true), RptParagraph('p')]),
        '## T\np\n\n',
      );
    });

    test('key-value rows render as bullets; empty key is a plain bullet', () {
      expect(
        renderRptMarkdown(const [
          RptKeyValue([('Feed:', '**pump**'), ('', 'plain bullet')]),
        ]),
        '- Feed: **pump**\n- plain bullet\n\n',
      );
    });

    test('table renders pipes with its exact custom separator', () {
      expect(
        renderRptMarkdown(const [
          RptTable(
            ['A', 'B'],
            [
              ['1', '2'],
            ],
            mdSeparator: '|---|---:|',
          ),
        ]),
        '| A | B |\n|---|---:|\n| 1 | 2 |\n\n',
      );
    });

    test('table synthesizes a default separator when none is given', () {
      expect(
        renderRptMarkdown(const [
          RptTable(['A', 'B', 'C'], []),
        ]),
        '| A | B | C |\n| --- | --- | --- |\n\n',
      );
    });

    test('note emits its text WITHOUT a trailing blank line', () {
      expect(renderRptMarkdown(const [RptNote('_closing note_')]),
          '_closing note_\n');
    });

    test('figure emits only its caption (Markdown carries no vectors)', () {
      const sheet = SldSheet(
        prims: [SldLine(0, 0, 10, 0)],
        minX: 0,
        minY: 0,
        maxX: 10,
        maxY: 1,
        legend: [],
        supplyNote: '',
      );
      expect(
        renderRptMarkdown(const [RptFigure(sheet, caption: 'Riser diagram')]),
        '_Riser diagram_\n\n',
      );
    });

    test('raw markdown is emitted verbatim, no added spacing', () {
      expect(renderRptMarkdown(const [RptMarkdown('a\n\nb\n')]), 'a\n\nb\n');
    });
  });

  group('block builders (structure feeding the PDF typesetter)', () {
    test('the mechanical report decomposes into real typed blocks', () {
      final blocks = buildCalcReportBlocks(richMechData());
      // First block is the H1 title (the unified report demotes on this).
      expect(blocks.first, isA<RptHeading>());
      expect((blocks.first as RptHeading).level, 1);
      // All five data tables came through as real RptTable blocks.
      final tables = blocks.whereType<RptTable>().toList();
      expect(tables.map((t) => t.headers.first),
          containsAll(['Date', 'Floor', 'Zone (floors)', 'Service']));
      // Key-value registers exist (design basis, fire, HVAC, storm).
      expect(blocks.whereType<RptKeyValue>(), isNotEmpty);
      // The closing advisory is a note.
      expect(blocks.last, isA<RptNote>());
    });
  });
}
