import 'package:mechx/data/dwg_converter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OdaDwgConverter.odaArgs', () {
    test('positional args match the ODA File Converter CLI contract', () {
      final args = OdaDwgConverter.odaArgs('/in', '/out');
      expect(args, [
        '/in', // input folder
        '/out', // output folder
        OdaDwgConverter.outputVersion, // output DXF version
        'DXF', // output type
        '0', // recurse off
        '1', // audit on
        '*.DWG', // filter
      ]);
    });
  });

  group('OdaDwgConverter.resolveBinary', () {
    test('prefers the ODA_CONVERTER env var when it points at a real file', () {
      final p = OdaDwgConverter.resolveBinary(
        environment: const {'ODA_CONVERTER': '/opt/oda/conv'},
        appDir: '/app',
        exists: (path) => path == '/opt/oda/conv',
      );
      expect(p, '/opt/oda/conv');
    });

    test('falls back to a bundled binary beside the app', () {
      final p = OdaDwgConverter.resolveBinary(
        environment: const {},
        appDir: '/app',
        exists: (path) => path.startsWith('/app/oda/ODAFileConverter'),
      );
      expect(p, isNotNull);
      expect(p, contains('/app/oda/ODAFileConverter'));
    });

    test('returns null (→ bare PATH name) when nothing is found', () {
      final p = OdaDwgConverter.resolveBinary(
        environment: const {},
        appDir: '/app',
        exists: (_) => false,
      );
      expect(p, isNull);
    });

    test('an env var pointing at a missing file is ignored', () {
      final p = OdaDwgConverter.resolveBinary(
        environment: const {'ODA_CONVERTER': '/nope'},
        appDir: '/app',
        exists: (_) => false,
      );
      expect(p, isNull);
    });
  });
}
