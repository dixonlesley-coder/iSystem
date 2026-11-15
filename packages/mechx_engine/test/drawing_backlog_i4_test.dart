// Drawing backlog I-4 (2026-11-13) — reviewer observations closed: a split
// schedule table never strands its last row or two on a page of their own
// (shophouse M-601 p3), and the power one-line keys only the codes it prints.
import 'dart:convert' show latin1;

import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/report_blocks.dart';
import 'package:mechx_engine/report/report_pdf.dart';
import 'package:test/test.dart';

/// The PDF's content streams, one per page in page order.
List<String> _streams(String pdf) => [
      for (final m in RegExp(r'stream\r?\n([\s\S]*?)endstream').allMatches(pdf))
        m.group(1)!,
    ];

void main() {
  test('a split table carries at least three rows to its last page', () {
    for (var n = 30; n <= 130; n += 1) {
      final table = RptTable(
        const ['Tag', 'Service', 'Duty'],
        [
          for (var i = 0; i < n; i++) ['T-$i', 'Service $i', '$i kW'],
        ],
      );
      final pdf = latin1.decode(reportBlocksToPdf(
          [const RptHeading(1, 'Schedule'), table],
          docTitle: 'T',
          projectName: 'P'));
      final pages = [
        for (final s in _streams(pdf))
          if (s.contains('(T-')) s
      ];
      if (pages.length < 2) continue;
      final last = '(T-'.allMatches(pages.last).length;
      expect(last, greaterThanOrEqualTo(kReportTableMinCarryRows),
          reason: '$n rows: last page holds $last');
      // Every row is printed exactly once.
      final total =
          pages.fold<int>(0, (a, s) => a + '(T-'.allMatches(s).length);
      expect(total, n);
    }
  });

  test('a short table is never split', () {
    for (var lead = 0; lead < 80; lead++) {
      final pdf = latin1.decode(reportBlocksToPdf([
        for (var i = 0; i < lead; i++) RptParagraph('Line $i of the lead.'),
        const RptHeading(2, 'Panels'),
        const RptTable(['Tag', 'Duty'], [
          ['P-1', '1 kW'],
          ['P-2', '2 kW'],
          ['P-3', '3 kW'],
        ]),
      ], docTitle: 'T', projectName: 'P'));
      final pages = [
        for (final s in _streams(pdf))
          if (s.contains('(P-')) s
      ];
      expect(pages, hasLength(1), reason: 'lead $lead');
      expect(pages.single, contains('(Panels) Tj'));
    }
  });

  test('the power one-line legend keys only codes it prints', () {
    // The tower's arrangement: MV supply -> transformer -> bus + capacitor
    // bank, genset via ATS (F7 captions the transformer / bank in full).
    final sheet = buildPowerOneLineSheet(const PowerOneLine(nodes: [
      PowerNode(id: 'u', kind: PowerNodeKind.utility, label: 'PLN utility'),
      PowerNode(id: 'tx', kind: PowerNodeKind.transformer, label: 'TX'),
      PowerNode(id: 'g', kind: PowerNodeKind.generator, label: 'Generator'),
      PowerNode(id: 'ats', kind: PowerNodeKind.ats, label: 'ATS'),
      PowerNode(id: 'b', kind: PowerNodeKind.bus, label: 'Main LV bus'),
      PowerNode(id: 'c', kind: PowerNodeKind.capacitor, label: 'CAP'),
    ], edges: [
      PowerEdge(id: 'e1', from: 'u', to: 'tx'),
      PowerEdge(id: 'e2', from: 'tx', to: 'ats'),
      PowerEdge(id: 'e3', from: 'g', to: 'ats'),
      PowerEdge(id: 'e4', from: 'ats', to: 'b'),
      PowerEdge(id: 'e5', from: 'b', to: 'c'),
    ], interlocks: []));
    final printed = sheet.prims.whereType<SldLabel>().map((l) => l.text);
    for (final e in sheet.legend) {
      if (e.code.contains(' ') ||
          const {'Source', 'Board', 'Normal', 'Essential', 'Earth'}
              .contains(e.code)) {
        continue;
      }
      expect(printed.any((t) => RegExp('(?<![A-Za-z])${e.code}(?![A-Za-z])')
              .hasMatch(t)),
          isTrue,
          reason: e.code);
    }
  });
}
