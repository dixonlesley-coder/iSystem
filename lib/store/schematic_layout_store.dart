/// B3 — DIAGRAM-ONLY horizontal placement for the Riser → Edit elevation.
///
/// The elevation is a generated RENDER of the one solve (golden rule 5), not a
/// second drawing. Sliding a riser sideways on it is a decluttering gesture:
/// it must change where the symbol sits on the DIAGRAM and nothing else. It used
/// to write the elevation's world x straight onto the plan nodes, silently
/// relocating the riser away from its shaft on the plan and every plan export.
///
/// This store holds those diagram positions instead: a per-node x override the
/// elevation view (and only the elevation view) reads. Plan geometry — and so
/// every §10 length, the plan canvas and every export — is untouched.
///
/// TRANSIENT by design: the overrides are NOT written to `.mechx`, so reopening
/// a project re-lays the elevation out from the plan geometry. That is the
/// honest default for a purely visual gesture and keeps the project file (and
/// its version) unchanged.
///
/// UNDOABLE (riser drafting-feel R3): a drag, an arrow nudge or a 'Reset
/// position' is ONE [UndoDomain.riserLayout] step on the global timeline. The
/// controller keeps its own snapshot stack of the override map (the
/// reference-line local-stack pattern); a gesture brackets its frames with
/// [SchematicLayoutController.beginGesture] / [SchematicLayoutController.endGesture]
/// so a whole drag is one step and a drag that ends where it began records
/// nothing.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

import 'history_store.dart';

/// The diagram-only horizontal positions, keyed by NODE id. A node with no entry
/// simply uses its plan x, so an untouched project renders exactly as before.
@immutable
class SchematicLayoutState {
  /// Node id → the elevation-view world x the engineer dragged it to.
  final Map<String, double> schematicXOverrides;

  const SchematicLayoutState({this.schematicXOverrides = const {}});

  /// The x to DRAW [node] at in the elevation: its override when it carries
  /// one, else its plan x.
  double xFor(NetNode node) => schematicXOverrides[node.id] ?? node.x;

  /// The x to draw the node [nodeId] at, given its plan [planX].
  double xForId(String nodeId, double planX) =>
      schematicXOverrides[nodeId] ?? planX;

  bool get isEmpty => schematicXOverrides.isEmpty;
}

class SchematicLayoutController extends Notifier<SchematicLayoutState> {
  @override
  SchematicLayoutState build() => const SchematicLayoutState();

  final List<Map<String, double>> _undo = [];
  final List<Map<String, double>> _redo = [];

  /// The pre-gesture override map while a [beginGesture] is open, else null.
  Map<String, double>? _gestureBase;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Open a gesture (a drag): every [setNodesX] until [endGesture] folds into
  /// ONE undo step. Re-opening an open gesture keeps the original base.
  void beginGesture() => _gestureBase ??= state.schematicXOverrides;

  /// Close the gesture opened by [beginGesture]: records one
  /// [UndoDomain.riserLayout] step when the overrides actually changed, else
  /// nothing (a click without a move is never an undo entry).
  void endGesture() {
    final base = _gestureBase;
    _gestureBase = null;
    if (base == null || mapEquals(base, state.schematicXOverrides)) return;
    _pushUndo(base);
  }

  void _pushUndo(Map<String, double> before) {
    _undo.add(before);
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
    ref.read(historyProvider.notifier).record(UndoDomain.riserLayout);
  }

  /// Run [mutate] as ONE undoable step (outside a drag gesture): an arrow
  /// nudge, a 'Reset position'. No-op mutations record nothing.
  void _step(void Function() mutate) {
    if (_gestureBase != null) {
      mutate();
      return;
    }
    final before = state.schematicXOverrides;
    mutate();
    if (!identical(before, state.schematicXOverrides) &&
        !mapEquals(before, state.schematicXOverrides)) {
      _pushUndo(before);
    }
  }

  /// [setNodesX] as its own undo step (an arrow nudge).
  void setNodesXUndoable(Map<String, double> xByNodeId) =>
      _step(() => setNodesX(xByNodeId));

  /// [clearNodes] as its own undo step — the riser context menu's 'Reset
  /// position' (the riser returns to its plan x).
  void resetNodes(Iterable<String> nodeIds) =>
      _step(() => clearNodes(nodeIds));

  /// Revert the most recent layout step. Driven by the global history.
  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(state.schematicXOverrides);
    state = SchematicLayoutState(schematicXOverrides: _undo.removeLast());
  }

  /// Replay the most recently undone layout step.
  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(state.schematicXOverrides);
    state = SchematicLayoutState(schematicXOverrides: _redo.removeLast());
  }

  /// Drop both stacks (a document open / restore — called by the history
  /// reset, like the other domain coordinators).
  void resetHistory() {
    _undo.clear();
    _redo.clear();
    _gestureBase = null;
  }

  /// Set the elevation x of every node in [xByNodeId] (both endpoints of a
  /// dragged riser, or a whole multi-selection moved by one delta). A no-op —
  /// leaving the state identical — when nothing would change, so a drag that
  /// ends where it started never notifies.
  void setNodesX(Map<String, double> xByNodeId) {
    if (xByNodeId.isEmpty) return;
    var changed = false;
    for (final entry in xByNodeId.entries) {
      if (state.schematicXOverrides[entry.key] != entry.value) {
        changed = true;
        break;
      }
    }
    if (!changed) return;
    state = SchematicLayoutState(schematicXOverrides: {
      ...state.schematicXOverrides,
      ...xByNodeId,
    });
  }

  /// Drop the override for [nodeIds] — the nodes fall back to their plan x.
  void clearNodes(Iterable<String> nodeIds) {
    final next = Map<String, double>.from(state.schematicXOverrides);
    var changed = false;
    for (final id in nodeIds) {
      if (next.remove(id) != null) changed = true;
    }
    if (!changed) return;
    state = SchematicLayoutState(schematicXOverrides: next);
  }

  /// Drop every override (a fresh project / a reset of the elevation layout).
  void clear() {
    if (state.isEmpty) return;
    state = const SchematicLayoutState();
  }
}

/// The elevation's diagram-only node positions. Read by the Riser → Edit view;
/// written by `NetworkController.moveRiserHorizontal` (inside a drag gesture)
/// and the undoable nudge / reset intents above.
final schematicLayoutProvider =
    NotifierProvider<SchematicLayoutController, SchematicLayoutState>(
        SchematicLayoutController.new);
