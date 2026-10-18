// Round 13 (2026-10-18) — export-file findings in the pure engine:
//   export-files-1  safeFileStem: no '/', ':', '?' … ever reaches a file name;
//   export-files-5  one CSV byte-order policy (UTF-8 BOM) for Excel;
//   export-files-6  Markdown table cells escape '|';
//   export-files-7  PDF text passes every WinAnsi glyph (é, en/em dash, curly
//                   quotes …), '?' only outside WinAnsi.
import 'dart:convert';
import 'dart:math' as math;

import 'package:mechx_engine/report/csv_text.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/file_names.dart';
import 'package:mechx_engine/report/report_blocks.dart';
import 'package:test/test.dart';

void main() {
  group('export-files-1 — safeFileStem', () {
    test('realistic Indonesian project names become valid stems', () {
      expect(safeFileStem('Ruko A/B'), 'Ruko A_B');
      expect(safeFileStem('Tower 1/2'), 'Tower 1_2');
      expect(safeFileStem('Proyek: Tahap 1'), 'Proyek_ Tahap 1');
      expect(safeFileStem('Gedung "Utama"?'), 'Gedung _Utama__');
      expect(safeFileStem('GF\\LG'), 'GF_LG');
      // Trailing dots / spaces are stripped (Win32 drops them silently).
      expect(safeFileStem('Lantai 1. '), 'Lantai 1');
      // Reserved device names and empty input.
      expect(safeFileStem('con'), '_con');
      expect(safeFileStem('NUL.txt'), '_NUL.txt');
      expect(safeFileStem('  '), 'project');
      expect(safeFileStem('///', fallback: 'sheet'), '___');
      // An already-safe name is byte-identical.
      expect(safeFileStem('Tower'), 'Tower');
      expect(safeFileStem('Gedung Café – Utama'), 'Gedung Café – Utama');
    });

    test('property: no illegal character ever survives (seeded)', () {
      const alphabet = 'aZ09 -_.,()/\\:*?"<>|\t\néé–';
      final rnd = math.Random(1313);
      final illegal = RegExp(r'[\\/:*?"<>|\x00-\x1F]');
      for (var trial = 0; trial < 500; trial++) {
        final raw = String.fromCharCodes([
          for (var i = 0; i < rnd.nextInt(16); i++)
            alphabet.codeUnitAt(rnd.nextInt(alphabet.length)),
        ]);
        final stem = safeFileStem(raw);
        expect(stem, isNotEmpty, reason: raw);
        expect(illegal.hasMatch(stem), isFalse, reason: raw);
        expect(stem.endsWith('.') || stem.endsWith(' '), isFalse, reason: raw);
        expect(safeFileStem(stem), stem, reason: 'idempotent: $raw');
      }
    });
  });

  test('export-files-5 — excelCsv prefixes exactly one UTF-8 BOM', () {
    const csv = 'tag,model_spec\nG-01,—\n';
    final out = excelCsv(csv);
    expect(utf8.encode(out).take(3), [0xEF, 0xBB, 0xBF]);
    expect(out.substring(1), csv);
    expect(excelCsv(out), out); // idempotent
  });

  test('export-files-6 — a "|" in a cell never adds a column', () {
    final md = renderRptMarkdown([
      const RptTable(
        ['Tag', 'Model / spec', 'Qty'],
        [
          ['TX-01', 'Trafindo 630 kVA | Dyn5 | 20/0.4 kV', '1'],
          ['P-01', r'already \| escaped', '2'],
          ['F-01', 'two\nlines', '1'],
        ],
      ),
    ]);
    // Count the UNESCAPED column separators per line: header == every row.
    int cols(String line) =>
        RegExp(r'(?<!\\)\|').allMatches(line).length;
    final lines = md.trim().split('\n');
    final header = cols(lines.first);
    for (final l in lines) {
      expect(cols(l), header, reason: l);
    }
    expect(md, contains(r'Trafindo 630 kVA \| Dyn5 \| 20/0.4 kV'));
    expect(md, contains(r'already \| escaped'));
    expect(md, isNot(contains(r'\\|')));
    expect(md, contains('two lines'));
  });

  group('export-files-7 — WinAnsi PDF text', () {
    test('Latin-1 and the cp1252 typographic slots pass through', () {
      // é U+00E9 → 0xE9; – U+2013 → 0x96; — U+2014 → 0x97; “ ” → 0x93/0x94.
      expect(pdfWinAnsiText('PT Café “Maju”').codeUnits,
          [...'PT Caf'.codeUnits, 0xE9, 0x20, 0x93, ...'Maju'.codeUnits, 0x94]);
      expect(pdfWinAnsiText('Gedung – Utama').codeUnitAt(7), 0x96);
      expect(pdfWinAnsiText('Lantai 1 — Utama').codeUnitAt(9), 0x97);
      expect(winAnsiByte(0x2019), 0x92);
      expect(winAnsiByte(0x2022), 0x95);
      expect(winAnsiByte(0x2026), 0x85);
      // Outside WinAnsi only → '?'.
      expect(pdfWinAnsiText('φ'), '?');
      // Metacharacters still escaped; ASCII byte-identical.
      expect(pdfWinAnsiText(r'a(b)\c'), r'a\(b\)\\c');
    });

    test('property: every output char is one WinAnsi byte (seeded)', () {
      final rnd = math.Random(7);
      for (var trial = 0; trial < 300; trial++) {
        final raw = String.fromCharCodes([
          for (var i = 0; i < rnd.nextInt(20); i++)
            switch (rnd.nextInt(4)) {
              0 => 0x20 + rnd.nextInt(0x5f),
              1 => 0xA0 + rnd.nextInt(0x60),
              2 => 0x2010 + rnd.nextInt(0x20),
              _ => 0x3B1 + rnd.nextInt(20), // Greek: outside WinAnsi
            },
        ]);
        final out = pdfWinAnsiText(raw);
        // latin1-encodable (one byte per char) — the exporters' contract.
        expect(() => latin1.encode(out), returnsNormally, reason: raw);
        for (final rune in raw.runes) {
          final b = winAnsiByte(rune);
          if (b != null) {
            expect(out.codeUnits, contains(b), reason: 'U+${rune.toRadixString(16)}');
          }
        }
      }
    });
  });

  test('pdf exporters share the WinAnsi rule (no "?" for a curly quote)', () {
    // The title-block helper is used by every exporter; a quick end-to-end
    // pin through the public sheet-number + text path.
    expect(pdfWinAnsiText('‘M-101’'), '\u0091M-101\u0092');
  });
}
