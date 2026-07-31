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
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

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
/// written by `NetworkController.moveRiserHorizontal`.
final schematicLayoutProvider =
    NotifierProvider<SchematicLayoutController, SchematicLayoutState>(
        SchematicLayoutController.new);
