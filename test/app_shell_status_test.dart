import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/calibration_store.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/shell/nav_rail.dart';
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
      'sheet calibration is stated ONCE: the Layout breadcrumb carries it '
      '(status slot empty); the status bar carries it on Riser/Electrical',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    // Production launches with NO sheets (A1); seed the demo sheets so there is
    // a current sheet whose (missing) calibration is reported.
    seedDemoSheets(container);
    await tester.pump();

    // Layout: the status-bar sheet slot is an empty spacer; the breadcrumb
    // after the layer row carries the tappable 'Not calibrated' tail.
    expect(find.byKey(const ValueKey('status-sheet-slot')), findsNothing);
    expect(find.text('Uncalibrated'), findsNothing);
    expect(find.byKey(const ValueKey('breadcrumb-calibrate')), findsOneWidget);
    expect(find.bySemanticsLabel('Calibrate scale'), findsWidgets);

    // Tapping the breadcrumb tail starts calibration like the top-centre pill.
    await tester.tap(find.byKey(const ValueKey('breadcrumb-calibrate')));
    await tester.pump();
    expect(container.read(calibrationControllerProvider).isActive, isTrue);
    container.read(calibrationControllerProvider.notifier).cancel();
    await tester.pump();

    // Calibrate the current sheet → the breadcrumb reads the quiet scale.
    container
        .read(projectControllerProvider.notifier)
        .setCalibration('s1', const ScaleCalibration(0.025));
    await tester.pump();
    expect(find.byKey(const ValueKey('breadcrumb-calibrate')), findsNothing);
    expect(find.byKey(const ValueKey('breadcrumb-scale')), findsOneWidget);

    // Riser workspace (no sheet rail): the status bar now names the sheet.
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.schematic);
    await tester.pump();
    expect(find.byKey(const ValueKey('status-sheet-slot')), findsOneWidget);
    expect(find.text('Calibrated'), findsOneWidget);
    expect(find.text('Uncalibrated'), findsNothing);

    // A hub section: empty again.
    container.read(shellSectionProvider.notifier).set(ShellSection.review);
    await tester.pump();
    expect(find.byKey(const ValueKey('status-sheet-slot')), findsNothing);
  });

  testWidgets('the top bar no longer carries a theme toggle (work item 9)',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    // Theme switching lives in Preferences + the palette 'theme.toggle'
    // command; the top bar is trimmed to title / palette hint / Open / Save /
    // Export.
    expect(find.bySemanticsLabel(RegExp('Switch to (light|dark)')),
        findsNothing);
  });

  testWidgets(
      'standards-provenance dot is lit once unverified values are present',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    // Round 31 — the PUIL // VERIFY debt surfaces once the project has an
    // electrical panel (a fresh project carries none), so add one: the dot's
    // gate is then open and the caption renders.
    container.read(electricalProjectProvider.notifier).addPanel(name: 'DB');
    await tester.pump();
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
