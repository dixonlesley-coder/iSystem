import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A one-shot request to bring a world-space point on a given sheet into view
/// (A2 — Review Locate must centre its target). Producers (the Review hub's
/// `locate()`, or any programmatic selection) set it; the Layout canvas
/// consumes it post-frame via `CanvasViewState.centreOnWorld` and clears it.
/// Null at rest, never persisted.
class RevealTarget {
  const RevealTarget({required this.sheetId, required this.x, required this.y});

  final String sheetId;

  /// World (sheet pixel) coordinates of the point to centre.
  final double x;
  final double y;
}

final revealTargetProvider =
    NotifierProvider<RevealTargetController, RevealTarget?>(
        RevealTargetController.new);

class RevealTargetController extends Notifier<RevealTarget?> {
  @override
  RevealTarget? build() => null;

  void request(RevealTarget target) => state = target;

  /// Consumed by the canvas after centring — one-shot semantics.
  void clear() => state = null;
}
