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
    await tester.pump();

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
