/// WORKFLOW-FRICTION-REVIEW — F1 (the calibration length field) and F12 (the
/// stepper's Calibrate chip with no plan loaded).
///
/// F1 has two halves and ONE mechanism: the "Known distance" field autofocuses
/// the moment the second reference point lands, which both saves the mouse trip
/// AND closes the bare-digit hole by construction — the Layout canvas gates its
/// single-key tool/service shortcuts on `!isTextEntryFocused()`, and a focused
/// field makes that false for the whole distance-entry phase. This test proves
/// the mechanism end-to-end on the real app: the digit switches the service
/// BEFORE calibration starts (so the handler is genuinely live in this harness)
/// and does not once the card is up.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/calibration_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/canvas/text_entry_guard.dart';
import 'package:mechx/ui/shell/workflow_stepper.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

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
      'F1: a digit typed right after the second calibration click does NOT '
      'switch the draw service', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedDemoSheets(container);
    await tester.pumpAndSettle();

    ServiceType service() => container.read(networkControllerProvider).service;

    // Give the canvas the keyboard, then prove the bare-digit shortcut is LIVE
    // in this harness: '3' picks the plumbing layer's third service.
    await tester.tapAt(const Offset(700, 400));
    await tester.pump();
    expect(service(), ServiceType.coldWater);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.pump();
    final switched = service();
    expect(switched, isNot(ServiceType.coldWater),
        reason: 'the bare-digit service shortcut must be live for this test '
            'to mean anything');

    // Now run the two calibration clicks.
    await tester.ensureVisible(find.text('Calibrate scale'));
    await tester.tap(find.text('Calibrate scale'));
    await tester.pump();
    await tester.tapAt(const Offset(600, 400));
    await tester.pump();
    await tester.tapAt(const Offset(720, 400));
    await tester.pump();
    expect(find.text('Known distance'), findsOneWidget);

    // The length field owns the keyboard...
    expect(isTextEntryFocused(), isTrue);

    // ...so the digits of a length ("5") fall into the field, not onto the
    // drawing: the service the engineer was working in is untouched.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pump();
    expect(service(), switched);
    // And calibration is still up — nothing swallowed the mode either.
    expect(container.read(calibrationControllerProvider).phase,
        CalibrationPhase.awaitingDistance);
  });

  testWidgets(
      'F12: the stepper Calibrate chip asks for a plan when none is loaded',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    // Production launches with NO sheets. Make the project dirty so the Import
    // path stops at its unsaved-work guard — that dialog is the observable
    // proof we routed to Import instead of arming an invisible mode (the real
    // OS file picker cannot be driven headlessly).
    container
        .read(projectControllerProvider.notifier)
        .setFloors(const [Floor('Only', Length(3.0))]);
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
        of: find.byType(WorkflowStepper), matching: find.text('Calibrate')));
    await tester.pumpAndSettle();

    // No invisible calibration mode was armed (the Layout empty state
    // early-returns before the overlay would ever mount).
    expect(container.read(calibrationControllerProvider).phase,
        CalibrationPhase.idle);
    // Import ran: its dirty-work guard is on screen.
    expect(find.text('Unsaved changes'), findsOneWidget);

    // Unwind before the picker is ever reached.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Unsaved changes'), findsNothing);
  });

  testWidgets(
      'F12: with a plan loaded the Calibrate chip still arms calibration',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedDemoSheets(container);
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
        of: find.byType(WorkflowStepper), matching: find.text('Calibrate')));
    await tester.pumpAndSettle();

    expect(container.read(calibrationControllerProvider).phase,
        CalibrationPhase.awaitingFirst);
  });
}
