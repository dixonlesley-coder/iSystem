import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/calibration_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/canvas/calibration_overlay.dart';
import 'package:mechx/ui/canvas/text_entry_guard.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/widgets/mechx_button.dart';
import 'package:mechx/ui/widgets/mechx_text_field.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';

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
      'calibration distance starts empty and Set scale is DISABLED until a '
      'valid >0 value is entered (G7)', (tester) async {
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

    // The field is EMPTY by default (was a committable '1.0'). G7: the button
    // is now DISABLED rather than live-and-silently-no-op — the click that used
    // to read as "the app ignored me" cannot happen.
    MechXButton setScale() => tester.widget<MechXButton>(find.ancestor(
          of: find.text('Set scale'),
          matching: find.byType(MechXButton),
        ));
    expect(setScale().onPressed, isNull);
    await tester.tap(find.text('Set scale'));
    await tester.pump();
    expect(
      container.read(projectControllerProvider).calibrationFor('s1'),
      isNull,
    );

    // A garbled / non-positive length keeps it disabled too.
    await tester.enterText(find.byType(MechXTextField), 'abc');
    await tester.pump();
    expect(setScale().onPressed, isNull);
    await tester.enterText(find.byType(MechXTextField), '0');
    await tester.pump();
    expect(setScale().onPressed, isNull);

    // Enter a real length, then commit: 5 m / 200 px = 0.025 m/px.
    await tester.enterText(find.byType(MechXTextField), '5.0');
    await tester.pump();
    expect(setScale().onPressed, isNotNull); // live once a length parses
    await tester.tap(find.text('Set scale'));
    await tester.pump();

    final cal = container.read(projectControllerProvider).calibrationFor('s1');
    expect(cal, isNotNull);
    expect(cal!.metersPerPixel, closeTo(0.025, 1e-12));

    // J2: the commit confirms the resolved scale and points at the next
    // workflow step. 0.025 m/px -> 1 / 0.025 = 40 px per metre exactly.
    expect(
      container.read(statusMessageProvider),
      'Scale set: 1 m = 40 px - next: set floor heights (Building)',
    );
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

    // 5 m / 200 px = 0.025 m/px = 40 px/m — plausible, no warning. The readout
    // is the ONE shared human formatter now (D1): a non-PDF sheet (this host has
    // no sheets loaded) reads `1 m = N px`.
    await tester.enterText(find.byType(MechXTextField), '5.0');
    await tester.pump();
    expect(find.textContaining('1 m = 40 px'), findsOneWidget);
    expect(find.textContaining('order of magnitude'), findsNothing);

    // 5000 m / 200 px = 25 m/px — implausibly large, warns.
    await tester.enterText(find.byType(MechXTextField), '5000');
    await tester.pump();
    expect(find.textContaining('order of magnitude'), findsOneWidget);
  });

  testWidgets(
      'F1: the Known-distance field takes focus the moment the second point '
      'lands', (tester) async {
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
    await tester.pump();
    // No card yet — nothing to focus.
    expect(isTextEntryFocused(), isFalse);

    calCtrl.addWorldPoint(const Offset(0, 200));
    await tester.pump();

    // The card mounted AND took the keyboard: the engineer types the length
    // straight away. This is also what closes the bare-digit hole — the canvas
    // key handler gates its tool/service shortcuts on `!isTextEntryFocused()`,
    // which is now false for the whole distance-entry phase.
    expect(find.text('Known distance'), findsOneWidget);
    expect(isTextEntryFocused(), isTrue);
  });

  testWidgets(
      'F4: with other sheets still uncalibrated the baton names the remainder, '
      'not Building', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(_host());
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(CalibrationOverlay)),
      listen: false,
    );
    // Three loaded sheets (s1/s2/s3); this overlay calibrates s1, so two are
    // left without a scale — their runs would still measure 0.0 m.
    seedDemoSheets(container);
    final calCtrl = container.read(calibrationControllerProvider.notifier);
    calCtrl.start();
    calCtrl.addWorldPoint(const Offset(0, 0));
    calCtrl.addWorldPoint(const Offset(0, 200));
    await tester.pump();

    await tester.enterText(find.byType(MechXTextField), '5.0');
    await tester.pump();
    await tester.tap(find.text('Set scale'));
    await tester.pump();

    expect(
      container.read(statusMessageProvider),
      'Scale set: 1 m = 40 px - 2 sheets still uncalibrated (apply to all in '
      'the Scale panel)',
    );

    // Calibrating the LAST outstanding sheet restores the Building baton: with
    // nothing left uncalibrated, that genuinely is the next step.
    container
        .read(projectControllerProvider.notifier)
        .setCalibration('s2', const ScaleCalibration(0.02));
    container
        .read(projectControllerProvider.notifier)
        .setCalibration('s3', const ScaleCalibration(0.02));
    calCtrl.start();
    calCtrl.addWorldPoint(const Offset(0, 0));
    calCtrl.addWorldPoint(const Offset(0, 100));
    await tester.pump();
    await tester.enterText(find.byType(MechXTextField), '5.0');
    await tester.pump();
    await tester.tap(find.text('Set scale'));
    await tester.pump();

    expect(
      container.read(statusMessageProvider),
      'Scale set: 1 m = 20 px - next: set floor heights (Building)',
    );
  });

  testWidgets(
      'F4: the singular reads "1 sheet still uncalibrated"', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(_host());
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(CalibrationOverlay)),
      listen: false,
    );
    seedDemoSheets(container);
    container
        .read(projectControllerProvider.notifier)
        .setCalibration('s3', const ScaleCalibration(0.02));
    final calCtrl = container.read(calibrationControllerProvider.notifier);
    calCtrl.start();
    calCtrl.addWorldPoint(const Offset(0, 0));
    calCtrl.addWorldPoint(const Offset(0, 200));
    await tester.pump();
    await tester.enterText(find.byType(MechXTextField), '5.0');
    await tester.pump();
    await tester.tap(find.text('Set scale'));
    await tester.pump();

    expect(
      container.read(statusMessageProvider),
      'Scale set: 1 m = 40 px - 1 sheet still uncalibrated (apply to all in '
      'the Scale panel)',
    );
  });

  testWidgets('Enter in the Known-distance field sets the scale (I3)',
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

    // Type a length and press Enter — no mouse trip to "Set scale".
    await tester.enterText(find.byType(MechXTextField), '5.0');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    final cal = container.read(projectControllerProvider).calibrationFor('s1');
    expect(cal, isNotNull);
    expect(cal!.metersPerPixel, closeTo(0.025, 1e-12));
  });
}
