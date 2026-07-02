import 'dart:convert';
import 'dart:typed_data';

import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/report/report_blocks.dart';
import 'package:mechx_engine/report/report_pdf.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:test/test.dart';

import 'report_test_fixtures.dart';

void main() {
  // The rich mechanical report is the long fixture (12 sections, 5 tables).
  Uint8List buildRich() => reportBlocksToPdf(
        buildCalcReportBlocks(richMechData()),
        docTitle: 'MEP Calculation Report',
        projectName: 'Menara Kencana',
        documentNumber: 'RPT-M-001',
        revisionTag: 'Rev. B',
        dateString: '2026-07-02',
        standardsLine: 'SNI plumbing pack (test rev)',
        preparedBy: 'A. Engineer',
      );

  test('emits a well-formed multi-page PDF', () {
    final bytes = buildRich();
    expect(bytes, isNotEmpty);
    final s = latin1.decode(bytes);
    expect(s.startsWith('%PDF-1.4'), isTrue);
    expect(s.trimRight().endsWith('%%EOF'), isTrue);
    expect(s, contains('/Type /Catalog'));
    expect(s, contains('/BaseFont /Helvetica'));
    expect(s, contains('/BaseFont /Helvetica-Bold'));
    // Cover + at least one content page.
    final count = RegExp(r'/Count (\d+)').firstMatch(s)!;
    expect(int.parse(count.group(1)!), greaterThanOrEqualTo(2));
  });

  test('running footer stamps project - doc no - Page X of Y', () {
    final s = latin1.decode(buildRich());
    // Total content pages from the /Count minus the cover.
    final total =
        int.parse(RegExp(r'/Count (\d+)').firstMatch(s)!.group(1)!) - 1;
    expect(total, greaterThanOrEqualTo(1));
    expect(s, contains('(Menara Kencana - RPT-M-001 - Page 1 of $total)'));
    // Every content page is numbered; the last one exists too.
    expect(
        s, contains('(Menara Kencana - RPT-M-001 - Page $total of $total)'));
    // The cover (first page stream) carries NO footer.
    final firstStream = s.substring(
        s.indexOf('stream\n') + 7, s.indexOf('endstream'));
    expect(firstStream, isNot(contains('Page 1 of')));
  });

  test('cover carries the title, project, doc number and Prepared-by only',
      () {
    final s = latin1.decode(buildRich());
    final firstStream =
        s.substring(s.indexOf('stream\n') + 7, s.indexOf('endstream'));
    expect(firstStream, contains('(MEP Calculation Report) Tj'));
    expect(firstStream, contains('(Menara Kencana) Tj'));
    expect(firstStream, contains('(RPT-M-001 - Rev. B) Tj'));
    expect(firstStream, contains('(2026-07-02) Tj'));
    expect(firstStream, contains('(SNI plumbing pack \\(test rev\\)) Tj'));
    // Only the supplied approval role is drawn — no empty signed-looking boxes.
    expect(firstStream, contains('(Prepared by) Tj'));
    expect(firstStream, contains('(A. Engineer) Tj'));
    expect(firstStream, isNot(contains('(Checked by) Tj')));
    expect(firstStream, isNot(contains('(Approved by) Tj')));
  });

  test('no approval roles at all means no approval table', () {
    final bytes = reportBlocksToPdf(
      const [RptParagraph('body')],
      docTitle: 'T',
      projectName: 'P',
    );
    final s = latin1.decode(bytes);
    expect(s, isNot(contains('(Prepared by) Tj')));
    expect(s, isNot(contains('(Checked by) Tj')));
    expect(s, isNot(contains('(Approved by) Tj')));
    // Footer degrades to `project - Page X of Y` when doc number is null.
    expect(s, contains('(P - Page 1 of 1)'));
  });

  test('non-ASCII typography is transliterated, not dropped', () {
    final s = latin1.decode(buildRich());
    // `52 °C` → `52 degC`, `k·Q²` → `k.Q2`, `×` → `x` (the operating-point
    // caveat line from the rich fixture).
    expect(s, contains('52 degC'));
    expect(s, contains('k.Q2 x pump curve'));
    // Markdown bold/emphasis markers are stripped for typesetting.
    expect(s, isNot(contains('**')));
  });

  test('a table taller than one page repeats its header band', () {
    // 120 rows × ~13.5 pt ≫ one A4 page, so the table MUST split. The header
    // cell name is unique so occurrences count header bands.
    final longTable = RptTable(
      const ['TagColX', 'DescriptionColX'],
      [
        for (var i = 0; i < 120; i++) ['T-$i', 'Row $i description text'],
      ],
    );
    final s = latin1.decode(reportBlocksToPdf(
      [const RptHeading(1, 'Long schedule'), longTable],
      docTitle: 'T',
      projectName: 'P',
    ));
    final headerCount = '(TagColX)'.allMatches(s).length;
    expect(headerCount, greaterThanOrEqualTo(2),
        reason: 'the split table must re-draw its header band on every page');
    // Both the first and the last row landed.
    expect(s, contains('(T-0)'));
    expect(s, contains('(T-119)'));
  });

  test('an RptFigure renders the sheet primitives + caption', () {
    const sheet = SldSheet(
      prims: [
        SldLine(0, 0, 100, 0),
        SldRect(10, 10, 40, 20),
        SldCircle(70, 20, 6),
        SldLabel(12, 8, 'CW-R1'),
      ],
      minX: 0,
      minY: 0,
      maxX: 100,
      maxY: 40,
      legend: [],
      supplyNote: '',
    );
    final s = latin1.decode(reportBlocksToPdf(
      const [RptFigure(sheet, caption: 'Figure 1 - riser single-line')],
      docTitle: 'T',
      projectName: 'P',
    ));
    expect(s, contains(' l S')); // the stroked line
    expect(s, contains(' re S')); // the stroked rect
    expect(s, contains(' c\n')); // the circle beziers
    expect(s, contains('(CW-R1) Tj')); // the label
    expect(s, contains('(Figure 1 - riser single-line) Tj')); // the caption
  });

  test('the cross-reference offsets actually point at their objects', () {
    // Mirrors plan_pdf_export_test: startxref → xref table → object 1 offset.
    final bytes = buildRich();
    final s = latin1.decode(bytes);
    final sx = s.lastIndexOf('startxref');
    final xrefOffset = int.parse(
        s.substring(sx + 'startxref'.length, s.indexOf('%%EOF', sx)).trim());
    expect(s.substring(xrefOffset, xrefOffset + 4), 'xref');
    final lines = s.substring(xrefOffset).split('\n');
    // lines[0] = 'xref', lines[1] = '0 N', lines[2] = free entry, lines[3] = obj1
    final obj1Offset = int.parse(lines[3].substring(0, 10));
    expect(s.substring(obj1Offset).startsWith('1 0 obj'), isTrue);
    // And the LAST object too (the Helvetica-Bold font).
    final lastEntry = lines[2 + int.parse(lines[1].split(' ')[1]) - 1];
    final lastOffset = int.parse(lastEntry.substring(0, 10));
    expect(s.substring(lastOffset), contains('Helvetica-Bold'));
  });

  test('same input, same bytes (deterministic)', () {
    expect(buildRich(), equals(buildRich()));
  });
}
