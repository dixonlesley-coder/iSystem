/// A1 floor-plan underlay — the app-side gather (`buildPlanUnderlay`): a
/// DXF-backed sheet yields the VECTOR underlay in the exact canvas frame, any
/// unreadable source yields null (the export proceeds underlay-less, never
/// throws), and the raster fade blends BGRA → RGB toward white.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/dxf_import.dart' show dxfContentSize;
import 'package:mechx/data/plan_underlay.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx_engine/geometry/dxf_drawing.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';

/// A minimal DXF: one LINE (0,0)→(100,50) — bounds 100 × 50.
const _fixtureDxf = '0\n'
    'SECTION\n'
    '2\n'
    'ENTITIES\n'
    '0\n'
    'LINE\n'
    '8\n'
    '0\n'
    '10\n'
    '0.0\n'
    '20\n'
    '0.0\n'
    '11\n'
    '100.0\n'
    '21\n'
    '50.0\n'
    '0\n'
    'ENDSEC\n'
    '0\n'
    'EOF\n';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('plan_underlay_test');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a DXF-backed sheet yields a vector underlay in the canvas frame',
      () async {
    final path = '${tmp.path}/plan.dxf';
    File(path).writeAsStringSync(_fixtureDxf);

    // The importer's frame for a 100 × 50 bounds: longest side normalised to
    // 1684 → sheet 1684 × 842 (hand-computed dxfContentSize).
    const sheetSize = Size(1684, 842);
    expect(dxfContentSize(const DxfBounds(0, 0, 100, 50)), sheetSize);

    final u = await buildPlanUnderlay(Sheet(
      id: 'plan#0',
      name: 'plan',
      dxfPath: path,
      sizePx: sheetSize,
    ));
    expect(u, isA<VectorPlanUnderlay>());
    final v = u! as VectorPlanUnderlay;
    expect(v.sheetWidthPx, 1684);
    expect(v.sheetHeightPx, 842);
    expect(v.drawing.polylines, hasLength(1));

    // The canvas fit, hand-computed: k = 1684 / 100 = 16.84; world (x, y-up)
    // → sheet px (y-down): (0,0) → (0, 842) and (100,50) → (1684, 0).
    expect(v.worldToSheetScale, closeTo(16.84, 1e-9));
    final (x0, y0) = v.toSheetPx(0, 0);
    expect(x0, closeTo(0, 1e-9));
    expect(y0, closeTo(842, 1e-9));
    final (x1, y1) = v.toSheetPx(100, 50);
    expect(x1, closeTo(1684, 1e-9));
    expect(y1, closeTo(0, 1e-9));
  });

  test('a missing DXF file yields null (export proceeds underlay-less)',
      () async {
    final u = await buildPlanUnderlay(Sheet(
      id: 'gone#0',
      name: 'gone',
      dxfPath: '${tmp.path}/does-not-exist.dxf',
    ));
    expect(u, isNull);
  });

  test('a missing PDF file yields null, never throws', () async {
    final u = await buildPlanUnderlay(Sheet(
      id: 'gone#0',
      name: 'gone',
      pdfPath: '${tmp.path}/does-not-exist.pdf',
    ));
    expect(u, isNull);
  });

  test('a placeholder sheet (no substrate) yields null', () async {
    final u = await buildPlanUnderlay(const Sheet(id: 'p0', name: 'p0'));
    expect(u, isNull);
  });

  test('fadeBgraToRgb blends BGRA toward white (hand-computed 60 % fade)',
      () {
    // One pure-red pixel in BGRA: B=0, G=0, R=255, A=255. At the default 60 %
    // fade: c' = c·0.4 + 255·0.6 → R' = 255, G' = B' = 153.
    final rgb = fadeBgraToRgb(
        Uint8List.fromList([0, 0, 255, 255]), 1, 1);
    expect(rgb, equals([255, 153, 153]));
    // Black stays 60 % white (153,153,153); white stays white.
    expect(
        fadeBgraToRgb(Uint8List.fromList([0, 0, 0, 255]), 1, 1),
        equals([153, 153, 153]));
    expect(
        fadeBgraToRgb(Uint8List.fromList([255, 255, 255, 255]), 1, 1),
        equals([255, 255, 255]));
  });
}
