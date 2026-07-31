/// C4 — the shared "armed tool" secondary-click DELETE contract for the canvas
/// annotation overlays (room / tank / measurement / reference line).
///
/// Those four tools used to delete the nearest item on pointer-DOWN, with no
/// menu and no confirmation — while everywhere else on the canvas a secondary
/// click means "open a context menu". Two problems: the gesture fired before the
/// button was released (so it could not be aborted), and a mis-click destroyed
/// drawn work silently.
///
/// This resolves both without inventing a new idiom: the delete now completes on
/// pointer-UP, and the FIRST secondary-click only ARMS it — the caller shows a
/// status pill naming the target ("Right-click again to delete Room 3"), and a
/// second secondary-click on the SAME target performs it. This mirrors the
/// app's existing "Tap again to discard" confirmation rather than adding a modal
/// dialog to a drafting gesture. Moving to a different target re-arms on that
/// one; a drag (beyond [ArmedSecondaryDelete.slopPx]) or a click on empty canvas
/// disarms. Undo behaviour is untouched — the delete the caller runs is the same
/// one-step, undoable removal as before.
///
/// Pure gesture bookkeeping: no Riverpod, no widgets, so it is unit-testable.
library;

import 'package:flutter/gestures.dart'
    show PointerDownEvent, PointerUpEvent, kSecondaryButton;
import 'package:flutter/painting.dart' show Offset;

/// What a resolved secondary pointer-up means.
enum ArmedDeleteAction {
  /// Nothing to do (not a secondary click, a drag, or nothing under the cursor).
  none,

  /// The first click on a target — the caller should confirm ("click again").
  armed,

  /// The second click on the SAME target — the caller should delete it.
  deleted,
}

/// The outcome of [ArmedSecondaryDelete.pointerUp]: an action plus the target it
/// applies to (null for [ArmedDeleteAction.none]).
typedef ArmedDeleteOutcome = ({ArmedDeleteAction action, String? id});

const ArmedDeleteOutcome _none = (action: ArmedDeleteAction.none, id: null);

/// Tracks the two-click confirmation for one overlay. Hold ONE per overlay
/// state; call [pointerDown] from the overlay's `Listener.onPointerDown` and
/// [pointerUp] from `onPointerUp`.
class ArmedSecondaryDelete {
  /// How far the pointer may travel between down and up and still count as a
  /// click rather than a drag (screen px).
  static const double slopPx = 6;

  /// The target currently armed (awaiting its confirming second click), or null.
  String? armedId;

  bool _secondaryDown = false;
  Offset? _downAt;

  void pointerDown(PointerDownEvent e) {
    _secondaryDown = e.buttons == kSecondaryButton;
    _downAt = _secondaryDown ? e.localPosition : null;
  }

  /// Resolve a pointer-up. [hitId] is the delete candidate under the pointer at
  /// release (null when the click landed on nothing).
  ArmedDeleteOutcome pointerUp(PointerUpEvent e, String? hitId) {
    final wasSecondary = _secondaryDown;
    final downAt = _downAt;
    _secondaryDown = false;
    _downAt = null;
    if (!wasSecondary || downAt == null) return _none;
    // A drag with the secondary button held is not a click — abort quietly.
    if ((e.localPosition - downAt).distance > slopPx) return _none;
    if (hitId == null) {
      // Clicking empty canvas cancels a pending confirmation.
      armedId = null;
      return _none;
    }
    if (armedId == hitId) {
      armedId = null;
      return (action: ArmedDeleteAction.deleted, id: hitId);
    }
    armedId = hitId;
    return (action: ArmedDeleteAction.armed, id: hitId);
  }

  /// Drop any pending confirmation (e.g. the tool was switched off).
  void disarm() {
    armedId = null;
    _secondaryDown = false;
    _downAt = null;
  }
}
