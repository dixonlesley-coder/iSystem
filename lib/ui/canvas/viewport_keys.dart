/// The shared CANVAS VIEW keyboard vocabulary — one pure mapping from a key
/// event to a viewport intent, so every pannable canvas answers the F1 sheet's
/// 'View (canvas)' rows the same way (F fit, Ctrl +/- zoom, Ctrl 0 actual
/// size, arrows pan, hold Space to pan).
///
/// The values and semantics MIRROR [CanvasView]'s own key handler exactly
/// (`canvas_view.dart` `_onKey`): a 1.2× zoom step about the viewport centre,
/// a 64 px arrow pan (Left moves the CONTENT right, i.e. the view looks left),
/// `F` fits regardless of modifiers, `Ctrl/Cmd 0` is the actual-size
/// framing, both key-down and key-repeat act, and an arrow is a NUDGE
/// candidate only on a fresh, unmodified key-DOWN (a held arrow or a
/// modifier+arrow pans) so a held nudge can never flood the undo stack.
/// CanvasView keeps its own inline copy for now (byte-identical behaviour);
/// it can adopt this helper without a behaviour change.
///
/// Adopters (2026-10-20): the Riser → Auto diagram and the Riser → Edit
/// elevation. The electrical single-line canvas is the next adopter — it maps
/// [ViewportIntent]s through [applyViewportIntent] against its own content
/// extents and eases the [ViewportIntent.eased] ones.
///
/// Usage, in a canvas's `Focus.onKeyEvent`:
///
/// ```dart
/// if (_space.handle(event, textEntryPossible: false)) return handled;
/// final intent = viewportIntentForKey(event, mod: ctrlOrMeta);
/// if (intent is ViewportPan && intent.nudgeCandidate && hostNudges(intent)) {
///   return handled; // a selection consumed the arrow
/// }
/// if (intent != null) {
///   final next = applyViewportIntent(intent, current,
///       contentSize: world, viewportSize: size);
///   intent.eased ? animateTo(next) : emit(next);
///   return handled;
/// }
/// ```
library;

import 'package:flutter/services.dart';

import 'viewport.dart';

/// The keyboard zoom step (×1.2 per press — the on-canvas ZoomControls'
/// step), mirroring [CanvasView].
const double kViewportKeyZoomStep = 1.2;

/// The arrow-key pan step in screen px, mirroring [CanvasView].
const double kViewportKeyPanStep = 64.0;

/// A view change requested from the keyboard. Pure value; resolve it against
/// a live view with [applyViewportIntent].
sealed class ViewportIntent {
  const ViewportIntent();

  /// Whether the change is a DISCRETE programmatic jump that should ease
  /// (zoom / fit / actual size — the G4 rule) rather than track 1:1 (a pan).
  bool get eased;
}

/// Zoom by [factor] about the viewport centre (Ctrl/Cmd + / -).
class ViewportZoomBy extends ViewportIntent {
  final double factor;
  const ViewportZoomBy(this.factor);
  @override
  bool get eased => true;
  @override
  bool operator ==(Object other) =>
      other is ViewportZoomBy && other.factor == factor;
  @override
  int get hashCode => factor.hashCode;
  @override
  String toString() => 'ViewportZoomBy($factor)';
}

/// Frame the content at 100 % (Ctrl/Cmd 0).
class ViewportActualSize extends ViewportIntent {
  const ViewportActualSize();
  @override
  bool get eased => true;
  @override
  bool operator ==(Object other) => other is ViewportActualSize;
  @override
  int get hashCode => 1;
}

/// Fit the content to the viewport (F).
class ViewportFit extends ViewportIntent {
  const ViewportFit();
  @override
  bool get eased => true;
  @override
  bool operator ==(Object other) => other is ViewportFit;
  @override
  int get hashCode => 2;
}

/// Pan by [delta] screen px (an arrow key). [arrow] is the key that asked;
/// [nudgeCandidate] is true only for a fresh, unmodified key-down — the one
/// case a host that owns a selection may consume the arrow as a nudge instead.
class ViewportPan extends ViewportIntent {
  final Offset delta;
  final LogicalKeyboardKey arrow;
  final bool nudgeCandidate;
  const ViewportPan(this.delta, this.arrow, {this.nudgeCandidate = false});
  @override
  bool get eased => false;
  @override
  bool operator ==(Object other) =>
      other is ViewportPan &&
      other.delta == delta &&
      other.arrow == arrow &&
      other.nudgeCandidate == nudgeCandidate;
  @override
  int get hashCode => Object.hash(delta, arrow, nudgeCandidate);
  @override
  String toString() => 'ViewportPan($delta, nudge: $nudgeCandidate)';
}

/// Map [event] to a [ViewportIntent], or null when it is not a view key.
///
/// [mod] is Ctrl OR Cmd held; [shift] / [alt] only matter for the arrow nudge
/// eligibility (any modifier turns a nudge into a pan). Key-up events never
/// map. Pure — the caller reads `HardwareKeyboard` and passes the modifiers,
/// so this is unit-testable without a binding.
ViewportIntent? viewportIntentForKey(
  KeyEvent event, {
  required bool mod,
  bool shift = false,
  bool alt = false,
}) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
  final key = event.logicalKey;
  if (mod &&
      (key == LogicalKeyboardKey.equal ||
          key == LogicalKeyboardKey.add ||
          key == LogicalKeyboardKey.numpadAdd)) {
    return const ViewportZoomBy(kViewportKeyZoomStep);
  }
  if (mod &&
      (key == LogicalKeyboardKey.minus ||
          key == LogicalKeyboardKey.numpadSubtract)) {
    return const ViewportZoomBy(1 / kViewportKeyZoomStep);
  }
  if (mod && key == LogicalKeyboardKey.digit0) return const ViewportActualSize();
  if (key == LogicalKeyboardKey.keyF) return const ViewportFit();
  final Offset? delta = switch (key) {
    LogicalKeyboardKey.arrowLeft => const Offset(kViewportKeyPanStep, 0),
    LogicalKeyboardKey.arrowRight => const Offset(-kViewportKeyPanStep, 0),
    LogicalKeyboardKey.arrowUp => const Offset(0, kViewportKeyPanStep),
    LogicalKeyboardKey.arrowDown => const Offset(0, -kViewportKeyPanStep),
    _ => null,
  };
  if (delta == null) return null;
  return ViewportPan(delta, key,
      nudgeCandidate: event is KeyDownEvent && !mod && !shift && !alt);
}

/// Resolve [intent] against the [current] view: the target transform.
/// [contentSize] is the canvas's world extent (what Fit / actual size frame),
/// [viewportSize] the widget size; [fitPadding] the host's fit padding
/// (CanvasView fits with the [ViewportTransform.fit] default).
ViewportTransform applyViewportIntent(
  ViewportIntent intent,
  ViewportTransform current, {
  required Size contentSize,
  required Size viewportSize,
  double fitPadding = 12,
}) {
  final centre = viewportSize.center(Offset.zero);
  return switch (intent) {
    ViewportZoomBy(:final factor) => current.zoomedBy(factor, centre),
    ViewportActualSize() =>
      ViewportTransform.actualSize(contentSize, viewportSize),
    ViewportFit() =>
      ViewportTransform.fit(contentSize, viewportSize, padding: fitPadding),
    ViewportPan(:final delta) => current.panned(delta),
  };
}

/// The hold-Space pan latch, mirroring the Layout canvas: while Space is held
/// a plain left-drag pans (with the grab cursor) instead of running the
/// canvas's own left-drag gesture. Feed every key event through [handle] —
/// down AND up, since only key-down reaches most handlers — and call
/// [release] when the canvas loses focus (the key-up then lands elsewhere and
/// would leave the latch stuck).
class SpacePanLatch {
  bool _held = false;

  /// Whether Space is currently held.
  bool get held => _held;

  /// Track [event]. Returns true when the event was the Space bar and the
  /// latch consumed it (the caller should return `handled`, and rebuild if it
  /// shows a cursor); false for every other key, and for Space while
  /// [textEntryPossible] (a focused field legitimately wants the space bar).
  bool handle(KeyEvent event, {bool textEntryPossible = false}) {
    if (event.logicalKey != LogicalKeyboardKey.space) return false;
    if (event is KeyUpEvent) {
      if (!_held) return false;
      _held = false;
      return true;
    }
    if (textEntryPossible) return false;
    _held = true;
    return true; // KeyDownEvent + KeyRepeatEvent
  }

  /// Drop the latch (focus left the canvas). Returns whether it was held.
  bool release() {
    final was = _held;
    _held = false;
    return was;
  }
}
