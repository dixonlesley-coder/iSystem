import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/dxf_import.dart';
import 'package:mechx/data/dxf_text.dart';

/// A pre-2007 DXF is written in its $DWGCODEPAGE (e.g. ANSI_1252), so a label
/// like "12 m²" carries a raw 0xB2 byte that strict UTF-8 refuses. The
/// geometry must still import.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('dxf_enc_'));
  tearDown(() => dir.deleteSync(recursive: true));

  // A 100 x 50 LINE plus a TEXT whose value ends in a latin1 '²' (0xB2).
  List<int> latin1Dxf() => [
        ...ascii.encode('0\nSECTION\n2\nENTITIES\n'
            '0\nTEXT\n10\n0\n20\n0\n40\n2.5\n1\n12 m'),
        0xB2,
        ...ascii.encode('\n'
            '0\nLINE\n10\n0\n20\n0\n11\n100\n21\n50\n'
            '0\nENDSEC\n0\nEOF\n'),
      ];

  test('strict UTF-8 really does refuse the file (the bug being fixed)', () {
    final f = File('${dir.path}/plan.dxf')..writeAsBytesSync(latin1Dxf());
    expect(() => f.readAsStringSync(), throwsA(isA<FileSystemException>()));
  });

  test('importDxf reads a latin1-encoded DXF into one sheet', () async {
    final path = '${dir.path}/plan.dxf';
    File(path).writeAsBytesSync(latin1Dxf());
    final sheets = await importDxf(path);
    expect(sheets, hasLength(1));
    // Bounds 100 x 50: the longest side normalises to kDxfTargetExtent, the
    // other scales by the same factor (50/100 · 1684 = 842).
    expect(sheets.single.sizePx.width, closeTo(kDxfTargetExtent, 1e-9));
    expect(sheets.single.sizePx.height, closeTo(kDxfTargetExtent / 2, 1e-9));
  });

  test('the sync reader decodes the same bytes without throwing', () {
    final path = '${dir.path}/plan.dxf';
    File(path).writeAsBytesSync(latin1Dxf());
    final text = readDxfTextSync(path);
    expect(text, contains('LINE'));
    expect(text, contains('12 m�')); // the bad byte -> U+FFFD
  });
}
