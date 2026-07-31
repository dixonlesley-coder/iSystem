/// Transient UI state for the ELECTRICAL single-line CANVAS (J1) — the viewport,
/// the one-shot initial-fit flag and the canvas selection.
///
/// These three lived in `ElectricalCanvasState`'s widget `State`, which the
/// shell DESTROYS every time the user hops to another workspace (Layout / Riser)
/// or to a read-only electrical tab and back: the canvas was the one workspace
/// that forgot where you were, re-fitting from scratch and dropping the
/// selection mid-task. The Riser fixed exactly this in `schematic_view_store`;
/// this mirrors that shape.
///
/// Deliberately TRANSIENT — session-only, never written to the `.mechx` file (a
/// viewport is not project data), so a fresh launch starts from these defaults
/// and the golden screenshots are unchanged. The canvas keeps a local mirror of
/// each field as its per-frame fast path and publishes every change here; it
/// re-seeds from this provider in `initState`.
///
/// NOT the same thing as `electricalSelectionProvider` (the LAYOUT electrical
/// layer's single-marker selection): this canvas selects a SET of boards
/// (shift-click / marquee / group nudge), which a single-selection provider
/// cannot represent. The two surfaces therefore still track selection
/// separately — see the J1 note in the review.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/canvas/viewport.dart';

/// One selected WAY (schedule row) on the single-line canvas — a circuit within
/// a board. Mutually exclusive with a panel selection.
@immutable
class ElectricalWaySelection {
  final String panelId;
  final String circuitId;
  const ElectricalWaySelection(this.panelId, this.circuitId);

  @override
  bool operator ==(Object other) =>
      other is ElectricalWaySelection &&
      other.panelId == panelId &&
      other.circuitId == circuitId;

  @override
  int get hashCode => Object.hash(panelId, circuitId);
}

/// The sticky (session-only) view state of the electrical single-line canvas.
@immutable
class ElectricalCanvasViewState {
  /// The canvas viewport. Null ⇒ the canvas's own default framing (which the
  /// one-shot initial fit then replaces on the first frame that has content).
  final ViewportTransform? transform;

  /// Whether the ONE-SHOT initial fit has been consumed (or forfeited by an
  /// explicit transform). Sticky, so hopping away and back restores the view
  /// instead of re-framing it.
  final bool didInitialFit;

  /// The multi-selected boards (shift-click / marquee / group nudge).
  final Set<String> selectedPanels;

  /// The selected way, when a schedule row (not a board) is selected.
  final ElectricalWaySelection? waySelection;

  const ElectricalCanvasViewState({
    this.transform,
    this.didInitialFit = false,
    this.selectedPanels = const {},
    this.waySelection,
  });
}

class ElectricalCanvasViewController
    extends Notifier<ElectricalCanvasViewState> {
  @override
  ElectricalCanvasViewState build() => const ElectricalCanvasViewState();

  /// Publish an explicit viewport (a user zoom / pan, the fit button, or a
  /// programmatic focus). An explicit transform always consumes the one-shot
  /// initial fit — the same rule the canvas applies locally.
  void setTransform(ViewportTransform t) {
    if (state.transform == t && state.didInitialFit) return;
    state = ElectricalCanvasViewState(
      transform: t,
      didInitialFit: true,
      selectedPanels: state.selectedPanels,
      waySelection: state.waySelection,
    );
  }

  /// Replace the selected boards (empty ⇒ nothing selected). Clears any way
  /// selection — the two are mutually exclusive.
  void selectPanels(Set<String> ids) {
    state = ElectricalCanvasViewState(
      transform: state.transform,
      didInitialFit: state.didInitialFit,
      selectedPanels: ids,
    );
  }

  /// Select ONE way (schedule row); clears the board selection.
  void selectWay(String panelId, String circuitId) {
    state = ElectricalCanvasViewState(
      transform: state.transform,
      didInitialFit: state.didInitialFit,
      waySelection: ElectricalWaySelection(panelId, circuitId),
    );
  }

  /// Clear both selections, leaving the viewport untouched.
  void clearSelection() {
    if (state.selectedPanels.isEmpty && state.waySelection == null) return;
    state = ElectricalCanvasViewState(
      transform: state.transform,
      didInitialFit: state.didInitialFit,
    );
  }
}

/// Transient (session-only, never `.mechx`-persisted) electrical-canvas view
/// state — see the library doc.
final electricalCanvasViewProvider =
    NotifierProvider<ElectricalCanvasViewController, ElectricalCanvasViewState>(
  ElectricalCanvasViewController.new,
);
