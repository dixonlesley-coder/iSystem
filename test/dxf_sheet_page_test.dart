import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/dxf_import.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/ui/canvas/dxf_sheet_page.dart';
import 'package:mechx_engine/geometry/dxf_drawing.dart';

void main() {
  testWidgets('DxfSheetPage paints a cached drawing without throwing',
      (tester) async {
    const path = '/fake/plan.dxf';
    final drawing = parseDxf(
      '0\nSECTION\n2\nENTITIES\n'
      '0\nLINE\n10\n0\n20\n0\n11\n100\n21\n80\n'
      '0\nCIRCLE\n10\n50\n20\n40\n40\n10\n'
      '0\nARC\n10\n0\n20\n0\n40\n20\n50\n0\n51\n90\n'
      '0\nENDSEC\n0\nEOF\n',
    );
    expect(drawing, isNotNull);
    DxfSheetPage.cacheForTest(path, drawing);

    final sheet = Sheet(
      id: 'cad#0',
      name: 'cad',
      dxfPath: path,
      sizePx: dxfContentSize(drawing!.bounds),
    );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: sheet.sizePx.width,
            height: sheet.sizePx.height,
            child: DxfSheetPage(sheet: sheet),
          ),
        ),
      ),
    );

    expect(find.byType(DxfSheetPage), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed/empty DXF renders an inline message, not a throw',
      (tester) async {
    const path = '/fake/empty.dxf';
    DxfSheetPage.cacheForTest(path, null);
    const sheet = Sheet(id: 'e#0', name: 'e', dxfPath: path);

    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: DxfSheetPage(sheet: sheet),
      ),
    );

    expect(find.textContaining('DXF'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
