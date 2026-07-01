import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/project_assets.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

ProjectDocument _doc(List<Sheet> sheets) => ProjectDocument(
      projectName: 'P',
      floors: const [Floor('G', Length(3.0))],
      calibrations: const {},
      sheets: sheets,
      network: const Network(nodes: [], edges: []),
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('assets_test_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('gatherSheetAssets embeds each distinct source once (multi-page dedup)',
      () {
    final pdf = File('${tmp.path}/plan.pdf')..writeAsBytesSync([1, 2, 3, 4]);
    final dxf = File('${tmp.path}/plan.dxf')..writeAsStringSync('0\nEOF\n');
    // Two sheets share the same PDF (multi-page) + one DXF sheet.
    final sheets = [
      Sheet(id: 'a', name: 'p1', pdfPath: pdf.path, pageIndex: 0),
      Sheet(id: 'b', name: 'p2', pdfPath: pdf.path, pageIndex: 1),
      Sheet(id: 'c', name: 'cad', dxfPath: dxf.path),
    ];

    final assets = gatherSheetAssets(sheets);
    expect(assets.keys, containsAll([pdf.path, dxf.path]));
    expect(assets.length, 2); // the shared PDF embedded once
    expect(base64Decode(assets[pdf.path]!), [1, 2, 3, 4]);
  });

  test('a missing source file is skipped, not fatal', () {
    final sheets = [
      const Sheet(id: 'x', name: 'gone', pdfPath: '/no/such/plan.pdf'),
    ];
    expect(gatherSheetAssets(sheets), isEmpty);
  });

  test('embed → encode → decode → rehydrate reproduces renderable sheets', () {
    final pdf = File('${tmp.path}/orig.pdf')..writeAsBytesSync([9, 8, 7]);
    final doc = _doc([Sheet(id: 'a', name: 'p', pdfPath: pdf.path)]);

    // Save side: attach assets, encode.
    final portable =
        doc.withSheets(doc.sheets, assets: gatherSheetAssets(doc.sheets));
    final encoded = portable.encode();
    expect(encoded, contains('assets'));

    // Simulate the file arriving on another machine — the original path is gone.
    pdf.deleteSync();

    // Open side: decode + rehydrate.
    final decoded = ProjectDocument.decode(encoded);
    expect(decoded.assets, isNotEmpty);
    final hydrated = rehydrateAssets(decoded);

    final s = hydrated.sheets.single;
    expect(s.pdfPath, isNot(pdf.path)); // repointed to the extracted local file
    final extracted = File(s.pdfPath!);
    expect(extracted.existsSync(), isTrue);
    expect(extracted.readAsBytesSync(), [9, 8, 7]); // original bytes recovered
  });

  test('a DWG-converted sheet embeds its DXF (portable without ODA)', () {
    final dxf = File('${tmp.path}/converted.dxf')..writeAsStringSync('0\nEOF\n');
    final sheets = [
      Sheet(
        id: 'd',
        name: 'dwg',
        dxfPath: dxf.path,
        dwgPath: '/somewhere/original.dwg',
      ),
    ];
    final assets = gatherSheetAssets(sheets);
    // The rendered DXF is embedded (keyed by dxfPath); the DWG is NOT needed.
    expect(assets.keys, [dxf.path]);
    expect(assets.containsKey('/somewhere/original.dwg'), isFalse);
  });

  test('a document with no assets rehydrates to itself (byte-identical)', () {
    final doc = _doc([const Sheet(id: 'a', name: 'ph')]);
    expect(doc.encode(), isNot(contains('"assets"')));
    expect(rehydrateAssets(doc).encode(), doc.encode());
  });
}
