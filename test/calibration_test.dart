import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/calibration_store.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

void main() {
  group('CalibrationController', () {
    ProviderContainer makeContainer() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('idle by default; stray points are ignored', () {
      final c = makeContainer();
      expect(c.read(calibrationControllerProvider).phase, CalibrationPhase.idle);
      expect(c.read(calibrationControllerProvider).isActive, isFalse);
      c
          .read(calibrationControllerProvider.notifier)
          .addWorldPoint(const Offset(1, 1));
      expect(c.read(calibrationControllerProvider).phase, CalibrationPhase.idle);
    });

    test('two-point flow yields the pixel span', () {
      final c = makeContainer();
      final n = c.read(calibrationControllerProvider.notifier);
      n.start();
      expect(c.read(calibrationControllerProvider).phase,
          CalibrationPhase.awaitingFirst);
      n.addWorldPoint(const Offset(0, 0));
      expect(c.read(calibrationControllerProvider).phase,
          CalibrationPhase.awaitingSecond);
      n.addWorldPoint(const Offset(3, 4));
      final s = c.read(calibrationControllerProvider);
      expect(s.phase, CalibrationPhase.awaitingDistance);
      expect(s.pixelDistance, closeTo(5.0, 1e-12));
    });

    test('resolve builds a ScaleCalibration from the known distance', () {
      final c = makeContainer();
      final n = c.read(calibrationControllerProvider.notifier);
      n.start();
      n.addWorldPoint(const Offset(0, 0));
      n.addWorldPoint(const Offset(0, 200));
      final cal = n.resolve(const Length(5.0));
      expect(cal, isNotNull);
      expect(cal!.metersPerPixel, closeTo(0.025, 1e-12)); // 5 m / 200 px
    });

    test('resolve is null before two points; cancel resets', () {
      final c = makeContainer();
      final n = c.read(calibrationControllerProvider.notifier);
      n.start();
      expect(n.resolve(const Length(5)), isNull);
      n.addWorldPoint(const Offset(0, 0));
      n.cancel();
      expect(c.read(calibrationControllerProvider).phase, CalibrationPhase.idle);
    });

    // ── D3: back-step, re-place, phase scoping ────────────────────────────────

    test('isEnteringDistance is true ONLY in the distance-entry phase', () {
      final c = makeContainer();
      final n = c.read(calibrationControllerProvider.notifier);
      expect(c.read(calibrationControllerProvider).isEnteringDistance, isFalse);
      n.start();
      expect(c.read(calibrationControllerProvider).isEnteringDistance, isFalse);
      n.addWorldPoint(const Offset(0, 0));
      expect(c.read(calibrationControllerProvider).isEnteringDistance, isFalse);
      n.addWorldPoint(const Offset(0, 200));
      expect(c.read(calibrationControllerProvider).isEnteringDistance, isTrue);
    });

    test('back() steps one point back without a full restart', () {
      final c = makeContainer();
      final n = c.read(calibrationControllerProvider.notifier);
      n.start();
      n.addWorldPoint(const Offset(0, 0));
      n.addWorldPoint(const Offset(0, 200));
      expect(c.read(calibrationControllerProvider).phase,
          CalibrationPhase.awaitingDistance);

      // Drop the second point → back to awaiting the second, first preserved.
      n.back();
      var s = c.read(calibrationControllerProvider);
      expect(s.phase, CalibrationPhase.awaitingSecond);
      expect(s.first, const Offset(0, 0));
      expect(s.second, isNull);

      // Drop the first point → back to awaiting the first (both cleared).
      n.back();
      s = c.read(calibrationControllerProvider);
      expect(s.phase, CalibrationPhase.awaitingFirst);
      expect(s.first, isNull);

      // A further back() at the first phase is a no-op.
      n.back();
      expect(c.read(calibrationControllerProvider).phase,
          CalibrationPhase.awaitingFirst);
    });

    test('a tap within snapRadius of a marker re-places it, not advances', () {
      final c = makeContainer();
      final n = c.read(calibrationControllerProvider.notifier);
      n.start();
      n.addWorldPoint(const Offset(0, 0));
      // A near tap re-places the FIRST marker (stays in awaitingSecond).
      n.addWorldPoint(const Offset(3, 0), snapRadius: 5);
      var s = c.read(calibrationControllerProvider);
      expect(s.phase, CalibrationPhase.awaitingSecond);
      expect(s.first, const Offset(3, 0));

      // A far tap places the second point and advances.
      n.addWorldPoint(const Offset(0, 200), snapRadius: 5);
      s = c.read(calibrationControllerProvider);
      expect(s.phase, CalibrationPhase.awaitingDistance);
      expect(s.second, const Offset(0, 200));

      // In the distance phase, a near tap re-places the nearest marker (here
      // the second), keeping the phase — a misclick fix, not a restart.
      n.addWorldPoint(const Offset(2, 200), snapRadius: 5);
      s = c.read(calibrationControllerProvider);
      expect(s.phase, CalibrationPhase.awaitingDistance);
      expect(s.second, const Offset(2, 200));
      expect(s.first, const Offset(3, 0));
    });

    test('re-place picks the nearest marker when both are in range', () {
      final c = makeContainer();
      final n = c.read(calibrationControllerProvider.notifier);
      n.start();
      n.addWorldPoint(const Offset(0, 0));
      n.addWorldPoint(const Offset(10, 0));
      // A tap at x=7 is nearer the second (10) than the first (0).
      n.addWorldPoint(const Offset(7, 0), snapRadius: 100);
      final s = c.read(calibrationControllerProvider);
      expect(s.first, const Offset(0, 0)); // untouched
      expect(s.second, const Offset(7, 0)); // nearer marker moved
    });
  });

  testWidgets('calibrate tool: button → overlay → two taps → distance card',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump(); // first-layout fit

    // Production launches with NO sheets (A1); calibration needs a drawable
    // sheet, so seed the demo sheets before starting the calibrate flow.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedDemoSheets(container);
    // Seeding grows the inspector sections; their DisclosureSection bodies
    // ease size changes (C3), so settle before locating the button — a tap
    // mid-slide lands where the button was a frame ago.
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Calibrate scale'));
    await tester.tap(find.text('Calibrate scale'));
    await tester.pump();
    expect(find.textContaining('first point'), findsOneWidget);

    // Two taps at distinct points inside the canvas overlay. The canvas now sits
    // right of the navigation rail + sheet rail (≈ x > 482 on the test surface),
    // so the points are chosen well inside that region.
    await tester.tapAt(const Offset(600, 400));
    await tester.pump();
    await tester.tapAt(const Offset(720, 400));
    await tester.pump();

    expect(find.text('Known distance'), findsOneWidget);
    expect(find.text('Set scale'), findsOneWidget);
  });
}
