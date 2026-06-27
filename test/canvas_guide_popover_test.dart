import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/widgets/canvas_guide_popover.dart';

import 'test_util.dart';

Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final sans = FontLoader('Roboto')
    ..addFont(bytes('assets/fonts/Roboto-Regular.ttf'))
    ..addFont(bytes('assets/fonts/Roboto-Medium.ttf'));
  await sans.load();
}

Widget _host(Widget child) => MechXTheme(
      data: MechXThemeData.dark,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Align(alignment: Alignment.topLeft, child: child),
      ),
    );

void main() {
  setUpAll(_loadFonts);

  testWidgets('CanvasGuideLegend renders its items and a title', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(_host(
      CanvasGuideLegend(
        items: const ['First gesture', 'Second gesture'],
        onClose: () {},
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Canvas guide'), findsOneWidget);
    expect(find.text('First gesture'), findsOneWidget);
    expect(find.text('Second gesture'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
  });

  testWidgets('tapping Close fires onClose', (tester) async {
    setDesktopSurface(tester);
    var closed = false;
    await tester.pumpWidget(_host(
      CanvasGuideLegend(
        items: const ['One'],
        onClose: () => closed = true,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Close'));
    await tester.pump();
    expect(closed, isTrue);
  });

  testWidgets('CanvasGuideButton toggles via onToggle', (tester) async {
    setDesktopSurface(tester);
    var toggles = 0;
    await tester.pumpWidget(_host(
      CanvasGuideButton(open: false, onToggle: () => toggles++),
    ));
    await tester.pumpAndSettle();

    expect(find.text('?'), findsOneWidget);
    await tester.tap(find.text('?'));
    await tester.pump();
    expect(toggles, 1);
  });
}
