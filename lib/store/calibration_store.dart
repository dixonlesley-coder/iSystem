import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/units.dart';

/// Steps of the on-canvas "mark a known distance" calibration flow.
enum CalibrationPhase {
  idle,
  awaitingFirst, // mode active, no points yet
  awaitingSecond, // first point placed
  awaitingDistance, // both points placed; ask for the real length
}

/// Calibration interaction state. [first]/[second] are in SHEET (world) pixels,
/// so [pixelDistance] is measured in the sheet's own pixel space regardless of
/// the current pan/zoom.
@immutable
class CalibrationState {
  final CalibrationPhase phase;
  final Offset? first;
  final Offset? second;

  const CalibrationState({
    this.phase = CalibrationPhase.idle,
    this.first,
    this.second,
  });

  bool get isActive => phase != CalibrationPhase.idle;

  double? get pixelDistance => (first != null && second != null)
      ? (second! - first!).distance
      : null;
}

class CalibrationController extends Notifier<CalibrationState> {
  @override
  CalibrationState build() => const CalibrationState();

  void start() =>
      state = const CalibrationState(phase: CalibrationPhase.awaitingFirst);

  void cancel() => state = const CalibrationState();

  /// Place the next reference point (a tap converted to sheet/world coords).
  void addWorldPoint(Offset point) {
    switch (state.phase) {
      case CalibrationPhase.awaitingFirst:
        state = CalibrationState(
          phase: CalibrationPhase.awaitingSecond,
          first: point,
        );
      case CalibrationPhase.awaitingSecond:
        state = CalibrationState(
          phase: CalibrationPhase.awaitingDistance,
          first: state.first,
          second: point,
        );
      case CalibrationPhase.idle:
      case CalibrationPhase.awaitingDistance:
        break; // ignore stray points
    }
  }

  /// Build the calibration from the marked span + a known [realDistance].
  /// Returns null if the two points aren't placed (or are coincident).
  ScaleCalibration? resolve(Length realDistance) {
    final pixels = state.pixelDistance;
    if (pixels == null || pixels <= 0) return null;
    return ScaleCalibration.fromReference(
      pixelDistance: pixels,
      realDistance: realDistance,
    );
  }
}

final calibrationControllerProvider =
    NotifierProvider<CalibrationController, CalibrationState>(
  CalibrationController.new,
);
