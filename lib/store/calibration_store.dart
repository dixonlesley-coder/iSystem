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

  /// True only in the distance-entry phase — the ONE phase with a text field
  /// (the "Known distance" input). The layout-canvas Space-pan guard scopes off
  /// this so Space still pans while merely placing the two reference points
  /// (D3): its rationale — "a field might want the space bar" — holds only here.
  bool get isEnteringDistance => phase == CalibrationPhase.awaitingDistance;

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
  ///
  /// A misclick doesn't force a restart (D3): if [snapRadius] > 0 and the tap
  /// lands within that many sheet-pixels of an ALREADY-placed marker, that
  /// marker is re-placed at the tap instead of advancing the flow — so an
  /// engineer can nudge either end (even after both are down, in the
  /// distance-entry phase) without cancelling. Away from an existing marker the
  /// tap advances the flow exactly as before; the default `snapRadius: 0`
  /// disables re-placing so existing callers are unchanged.
  void addWorldPoint(Offset point, {double snapRadius = 0}) {
    if (snapRadius > 0 && _replaceNearestMarker(point, snapRadius)) return;
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

  /// If [point] is within [snapRadius] of an existing marker, move the NEAREST
  /// such marker to [point] (keeping the current phase) and return true; else
  /// return false. Lets a click near either reference dot re-place it (D3).
  bool _replaceNearestMarker(Offset point, double snapRadius) {
    final first = state.first;
    final second = state.second;
    final dFirst = first == null ? null : (point - first).distance;
    final dSecond = second == null ? null : (point - second).distance;
    // Pick the closer marker that is within range.
    final firstInRange = dFirst != null && dFirst <= snapRadius;
    final secondInRange = dSecond != null && dSecond <= snapRadius;
    if (!firstInRange && !secondInRange) return false;
    final replaceFirst =
        firstInRange && (!secondInRange || dFirst! <= dSecond!);
    state = CalibrationState(
      phase: state.phase,
      first: replaceFirst ? point : first,
      second: replaceFirst ? second : point,
    );
    return true;
  }

  /// Undo the last placed point (D3) — a back-step, so a misclick that advanced
  /// the flow doesn't force a full restart. `awaitingDistance` → drop the second
  /// point back to `awaitingSecond`; `awaitingSecond` → drop the first back to
  /// `awaitingFirst`. A no-op at `awaitingFirst` / `idle` (nothing to undo).
  void back() {
    switch (state.phase) {
      case CalibrationPhase.awaitingDistance:
        state = CalibrationState(
          phase: CalibrationPhase.awaitingSecond,
          first: state.first,
        );
      case CalibrationPhase.awaitingSecond:
        state = const CalibrationState(phase: CalibrationPhase.awaitingFirst);
      case CalibrationPhase.awaitingFirst:
      case CalibrationPhase.idle:
        break;
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
