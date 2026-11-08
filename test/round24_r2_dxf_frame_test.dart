// Round 24 review follow-up (import-2-3): a DXF revised in place flags its
// calibration stale ONCE per real change. 'Scale confirmed' must survive a
// canvas remount (Layout <-> Riser disposes the canvas) and a reopen, and a
// DXF -> DXF replace must change the Layout content cache key.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/canvas/dxf_sheet_page.dart';
import 'package:mechx/ui/canvas/hosted_dxf_sheet_page.dart';
import 'package:mechx/ui/layout/layout_canvas.dart' show layoutContentCacheKey;
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/dxf_drawing.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

const _path = '/fake/r24r2/plan.dxf';

DxfDrawing _line(int maxX) => parseDxf(
      '0\nSECTION\n2\nENTITIES\n'
      '0\nLINE\n10\n0\n20\n0\n11\n$maxX\n21\n20000\n'
      '0\nENDSEC\n0\nEOF\n',
    )!;

// Imported from a 40 x 20 drawing (its stored frame); the file on disk has
// since been revised.
const _sheet = Sheet(
  id: 'd#0',
  name: 'd',
  dxfPath: _path,
  sizePx: Size(1684, 842),
  dxfFrame: DxfBounds(0, 0, 40000, 20000),
);

Future<void> _mount(WidgetTester t, ProviderContainer c) async {
  final sheet = c.read(sheetsControllerProvider).sheets.single;
  await t.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 400,
        height: 200,
        child: HostedDxfSheetPage(key: UniqueKey(), sheet: sheet),
      ),
    ),
  ));
  await t.pump();
}

Future<void> _unmount(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump();
}

bool _stale(ProviderContainer c) =>
    c.read(projectControllerProvider).isCalibrationStale('d#0');

ProviderContainer _project(Sheet sheet) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(sheetsControllerProvider.notifier).loadSheets([sheet]);
  c
      .read(projectControllerProvider.notifier)
      .setCalibration('d#0', const ScaleCalibration(40 / 1684));
  return c;
}

void main() {
  testWidgets('confirm -> remount -> no re-flag; a further change re-flags',
      (t) async {
    DxfSheetPage.cacheForTest(_path, _line(48000));
    final c = _project(_sheet);

    // First mount sees the changed extent: flagged + the live extent recorded.
    await _mount(t, c);
    expect(_stale(c), isTrue);
    expect(
        c.read(sheetsControllerProvider).sheets.single.dxfLiveFrameAck!.maxX,
        48000);

    // The engineer confirms the old scale still holds.
    c.read(projectControllerProvider.notifier).confirmCalibration('d#0');
    expect(_stale(c), isFalse);

    // Layout -> Riser -> Layout: the canvas is disposed and rebuilt.
    await _unmount(t);
    await _mount(t, c);
    expect(_stale(c), isFalse);

    // Reopen: the acknowledged extent round-trips in .mechx.
    final doc = ProjectDocument(
      projectName: 'R',
      floors: const [Floor('G', Length(3))],
      calibrations: const {},
      sheets: c.read(sheetsControllerProvider).sheets,
      network: Network(),
    );
    final back = ProjectDocument.decode(doc.encode()).sheets.single;
    expect(back.dxfLiveFrameAck!.maxX, 48000);
    final c2 = _project(back);
    await _unmount(t);
    await _mount(t, c2);
    expect(_stale(c2), isFalse);

    // The file is revised AGAIN (a different extent): flagged once more.
    DxfSheetPage.cacheForTest(_path, _line(52000));
    await _unmount(t);
    await _mount(t, c2);
    expect(_stale(c2), isTrue);
    expect(
        c2.read(sheetsControllerProvider).sheets.single.dxfLiveFrameAck!.maxX,
        52000);
  });

  test('a legacy sheet without the ack decodes as null', () {
    final doc = ProjectDocument(
      projectName: 'R',
      floors: const [Floor('G', Length(3))],
      calibrations: const {},
      sheets: const [_sheet],
      network: Network(),
    );
    expect(ProjectDocument.decode(doc.encode()).sheets.single.dxfLiveFrameAck,
        isNull);
  });

  test('the Layout content cache key follows the DXF source', () {
    const rev = Sheet(
      id: 'd#0',
      name: 'd',
      dxfPath: '/fake/r24r2/rev.dxf',
      sizePx: Size(1684, 842),
      dxfFrame: DxfBounds(0, 0, 40000, 20000),
    );
    expect(layoutContentCacheKey(rev), isNot(layoutContentCacheKey(_sheet)));
    expect(
        layoutContentCacheKey(_sheet.copyWith()), layoutContentCacheKey(_sheet));
    expect(
        layoutContentCacheKey(
            _sheet.copyWith(dxfFrame: const DxfBounds(0, 0, 48000, 20000))),
        isNot(layoutContentCacheKey(_sheet)));
  });
}
