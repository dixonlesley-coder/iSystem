/// Transient UI state for the B12 plan-underlay snap surface: a global
/// **'Snap to plan'** toggle (gates every underlay snap source — DXF vector,
/// reference lines, PDF ink — but never the node/grid snap) and the **Ref line**
/// trace-tool mode (a two-click construction-line drawing mode, the sibling of
/// [measureModeProvider]). Neither is persisted to `.mechx` — like Ortho and the
/// Measure mode they are session-only UI state.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the plan underlay contributes snap candidates. Default ON — a drafter
/// expects to latch onto the imported architecture. Gates ALL underlay sources
/// (DXF vector geometry, traced reference lines, PDF ink ridges); the existing
/// node-snap and magnetic-grid snap are never affected by it.
final snapToPlanProvider =
    NotifierProvider<SnapToPlanController, bool>(SnapToPlanController.new);

class SnapToPlanController extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool value) => state = value;
  void toggle() => state = !state;
}

/// Whether the **Ref line** trace tool is active. Mutually exclusive with the
/// network draw tools + the other annotation tools — the toolbar collapses the
/// draw tool to Select when this turns on, and clears it when another tool is
/// chosen (mirrors [measureModeProvider]).
final refLineModeProvider =
    NotifierProvider<RefLineModeController, bool>(RefLineModeController.new);

class RefLineModeController extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
  void toggle() => state = !state;
}

/// M5 — whether the magnetic calibrated GRID contributes a snap (F9). Default
/// ON. The grid stays the LOWEST-precedence snap and keeps its ortho gate: the
/// effective grid snap is `gridSnap && effective ortho` (the B13/G2 contract —
/// a free-angle Shift draw is never yanked onto a grid crossing), so with the
/// default ON every drawing behaves exactly as before; F9 lets a drafter keep
/// ortho while switching the grid pull off. Session-only, like Ortho.
final gridSnapProvider =
    NotifierProvider<GridSnapController, bool>(GridSnapController.new);

class GridSnapController extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool value) => state = value;
  void toggle() => state = !state;
}
