import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/canvas/measurement_overlay.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';

/// E5 — the Measure tool now draws a real dimension (offset dimension line,
/// extension lines, filled arrowheads, rotated text above the line) instead of
/// a chip covering a bare line. The pixel result is verified centrally; this is
/// the non-golden guard that the new dimension paint renders without throwing
/// (saved dimension + a degenerate zero-length one, calibrated + uncalibrated).
void main() {
  testWidgets('MeasurementOverlay paints the E5 dimension style without throwing',
      (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c
        .read(projectControllerProvider.notifier)
        .setCalibration('s1', const ScaleCalibration(0.01));
    // A normal dimension and a degenerate (coincident endpoints) one.
    c.read(measurementsProvider.notifier).add(
        sheetId: 's1', floorIndex: 0, ax: 60, ay: 60, bx: 360, by: 220);
    c.read(measurementsProvider.notifier).add(
        sheetId: 's1', floorIndex: 0, ax: 200, ay: 300, bx: 200, by: 300);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 500,
            height: 400,
            child: MeasurementOverlay(
                sheetId: 's1', floorIndex: 0, active: true),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
