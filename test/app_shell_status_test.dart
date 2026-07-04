import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/project_store.dart';
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

void main() {
  setUpAll(_loadFonts);

  testWidgets(
      'status bar reads Uncalibrated by default and Calibrated once the '
      'current sheet has a calibration', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    // Production launches with NO sheets (A1); seed the demo sheets so there is
    // a current sheet whose (missing) calibration the status bar reports.
    seedDemoSheets(container);
    await tester.pump();

    // The demo current sheet (s1) is uncalibrated at launch.
    expect(find.text('Uncalibrated'), findsOneWidget);
    expect(find.text('Calibrated'), findsNothing);

    // Calibrate the current sheet → the status bar must flip to Calibrated.
    container
        .read(projectControllerProvider.notifier)
        .setCalibration('s1', const ScaleCalibration(0.025));
    await tester.pump();

    expect(find.text('Calibrated'), findsOneWidget);
    expect(find.text('Uncalibrated'), findsNothing);
  });

  testWidgets('theme toggle labels the action, not the current mode',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    final startedDark =
        container.read(brightnessProvider) == Brightness.dark;

    // F6: the theme toggle is a compact icon control that NAMES its action to a
    // screen reader (a Semantics label — act toward the opposite mode) instead
    // of a visible text label. In light mode it acts toward dark; in dark,
    // toward light.
    expect(
        find.bySemanticsLabel(
            startedDark ? 'Switch to light' : 'Switch to dark'),
        findsOneWidget);

    await tester.tap(find.bySemanticsLabel(
        startedDark ? 'Switch to light' : 'Switch to dark'));
    await tester.pump();

    // After the flip the label names the NEW action (the opposite mode).
    expect(
        find.bySemanticsLabel(
            startedDark ? 'Switch to dark' : 'Switch to light'),
        findsOneWidget);
  });

  testWidgets(
      'standards-provenance dot is lit by default (unverified values present)',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    // The const standards profiles carry // VERIFY items, so the dot's gate is
    // open and the caption renders.
    expect(
      container
          .read(designIssuesProvider)
          .any((i) => i.isVerify),
      isTrue,
      reason: 'the default standards profiles should surface VERIFY items',
    );
    expect(find.text('SNI 8153:2015 (draft)'), findsOneWidget);
    // The warning dot beside the caption is present (lit).
    expect(find.byKey(const ValueKey('provenance-warning-dot')),
        findsOneWidget);
  });

  testWidgets(
      'standards-provenance dot goes dark when there are no unverified values',
      (tester) async {
    setDesktopSurface(tester);
    // Override designIssuesProvider to empty from the start → no 'Unverified
    // standard' issues, so the conditional warning dot must NOT render while the
    // provenance caption stays visible.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          designIssuesProvider.overrideWithValue(const <DesignIssue>[]),
        ],
        child: const MechXApp(),
      ),
    );
    await tester.pump();

    expect(find.text('SNI 8153:2015 (draft)'), findsOneWidget);
    // The conditional provenance warning dot is absent now.
    expect(find.byKey(const ValueKey('provenance-warning-dot')), findsNothing);
  });
}
