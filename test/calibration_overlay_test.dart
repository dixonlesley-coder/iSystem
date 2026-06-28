import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/calibration_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/canvas/calibration_overlay.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/widgets/mechx_text_field.dart';

import 'test_util.dart';

Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final sans = FontLoader('Roboto')
    ..addFont(bytes('assets/fonts/Roboto-Regular.ttf'))
    ..addFont(bytes('assets/fonts/Roboto-Medium.ttf'));
  await sans.load();
  final mono = FontLoader('Roboto Mono')
    ..addFont(bytes('assets/fonts/RobotoMono-Regular.ttf'));
  await mono.load();
}

Widget _host() => ProviderScope(
      child: MechXTheme(
        data: MechXThemeData.dark,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: CalibrationOverlay(sheetId: 's1'),
        ),
      ),
    );

void main() {
  setUpAll(_loadFonts);

  testWidgets(
      'calibration distance starts empty and Set scale is a no-op until a '
      'valid >0 value is entered', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(_host());
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(CalibrationOverlay)),
      listen: false,
    );
    final calCtrl = container.read(calibrationControllerProvider.notifier);

    // Drive the controller to the distance-entry phase with a 200 px span.
    calCtrl.start();
    calCtrl.addWorldPoint(const Offset(0, 0));
    calCtrl.addWorldPoint(const Offset(0, 200));
    await tester.pump();
    expect(find.text('Known distance'), findsOneWidget);

    // The field is EMPTY by default (was a committable '1.0'). Tapping Set scale
    // with no value parses null → no calibration is written.
    await tester.tap(find.text('Set scale'));
    await tester.pump();
    expect(
      container.read(projectControllerProvider).calibrationFor('s1'),
      isNull,
    );

    // Enter a real length, then commit: 5 m / 200 px = 0.025 m/px.
    await tester.enterText(find.byType(MechXTextField), '5.0');
    await tester.pump();
    await tester.tap(find.text('Set scale'));
    await tester.pump();

    final cal = container.read(projectControllerProvider).calibrationFor('s1');
    expect(cal, isNotNull);
    expect(cal!.metersPerPixel, closeTo(0.025, 1e-12));
  });

  testWidgets(
      'a plausible scale shows no warning; an order-of-magnitude slip warns',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(_host());
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(CalibrationOverlay)),
      listen: false,
    );
    final calCtrl = container.read(calibrationControllerProvider.notifier);
    calCtrl.start();
    calCtrl.addWorldPoint(const Offset(0, 0));
    calCtrl.addWorldPoint(const Offset(0, 200));
    await tester.pump();

    // 5 m / 200 px = 0.025 m/px — plausible, no warning.
    await tester.enterText(find.byType(MechXTextField), '5.0');
    await tester.pump();
    expect(find.textContaining('Scale approx'), findsOneWidget);
    expect(find.textContaining('order of magnitude'), findsNothing);

    // 5000 m / 200 px = 25 m/px — implausibly large, warns.
    await tester.enterText(find.byType(MechXTextField), '5000');
    await tester.pump();
    expect(find.textContaining('order of magnitude'), findsOneWidget);
  });
}
