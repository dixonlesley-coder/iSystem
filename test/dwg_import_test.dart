import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/dwg_converter.dart';
import 'package:mechx/data/dwg_import.dart';

/// A [DwgConverter] that "converts" by writing a fixed DXF (or returns a
/// pre-set failure), so the import flow is testable with no ODA binary.
class _FakeConverter implements DwgConverter {
  final DwgConvertResult Function(String dwgPath, String outDir) handler;
  const _FakeConverter(this.handler);
  @override
  Future<DwgConvertResult> toDxf(String dwgPath, String outDir) async =>
      handler(dwgPath, outDir);
}

const _dxf = '0\nSECTION\n2\nENTITIES\n'
    '0\nLINE\n10\n0\n20\n0\n11\n200\n21\n100\n'
    '0\nENDSEC\n0\nEOF\n';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('dwg_test_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a successful conversion yields a DXF-backed sheet keeping dwg provenance',
      () async {
    final dxfFile = File('${tmp.path}/plan.dxf')..writeAsStringSync(_dxf);
    final converter = _FakeConverter((_, _) => DwgConvertResult.ok(dxfFile.path));

    final sheets = await importDwg(
      '/some/where/plan.dwg',
      converter: converter,
      outDir: tmp.path,
    );

    expect(sheets, hasLength(1));
    final s = sheets.single;
    expect(s.name, 'plan');
    expect(s.dwgPath, '/some/where/plan.dwg'); // original kept as provenance
    expect(s.dxfPath, dxfFile.path); // rendered from the converted DXF
    expect(s.pdfPath, isNull);
    expect(s.sizePx.width, greaterThan(0));
    expect(s.sizePx.height, greaterThan(0));
  });

  test('a missing converter throws a user-facing StateError', () async {
    final converter =
        _FakeConverter((_, _) => const DwgConvertResult.notFound('no ODA here'));
    expect(
      () => importDwg('/x/plan.dwg', converter: converter, outDir: tmp.path),
      throwsA(isA<StateError>().having((e) => e.message, 'message',
          contains('no ODA here'))),
    );
  });

  test('a conversion that produced no geometry throws', () async {
    final empty = File('${tmp.path}/empty.dxf')
      ..writeAsStringSync('0\nSECTION\n2\nENTITIES\n0\nENDSEC\n0\nEOF\n');
    final converter = _FakeConverter((_, _) => DwgConvertResult.ok(empty.path));
    expect(
      () => importDwg('/x/empty.dwg', converter: converter, outDir: tmp.path),
      throwsA(isA<StateError>()),
    );
  });

  test('a converter failure surfaces its message', () async {
    final converter =
        _FakeConverter((_, _) => const DwgConvertResult.failed('corrupt dwg'));
    expect(
      () => importDwg('/x/bad.dwg', converter: converter, outDir: tmp.path),
      throwsA(isA<StateError>().having((e) => e.message, 'message',
          contains('corrupt dwg'))),
    );
  });
}
