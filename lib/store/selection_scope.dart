/// C3 — the SCOPE PRECONDITION for a mutating operation on a canvas selection.
///
/// A [Selection] outlives sheet and workspace switches: switch floors and the
/// nodes/edges you picked upstairs are still selected, still shown in a full
/// inspector editor, and still the target of Delete or a batch property apply.
/// The result was a silent cross-sheet edit — the destructive half of the
/// finding — plus an editor happily mutating something the engineer cannot see.
///
/// This module answers ONE question, purely (no Flutter, no Riverpod, so the
/// rule is unit-testable and the two call sites — the canvas Delete path and
/// the inspector's batch appliers — can never drift): which members of a
/// selection are IN SCOPE right now?
///
/// A member is in scope when it is
///  * on the CURRENT sheet, and
///  * on a VISIBLE, UNLOCKED (non-inert) service.
///
/// "Inert" is the existing `inertServicesProvider` union (locked discipline
/// layers + individually hidden services) that already governs hit-testing, so
/// a mutating op honours exactly the same filter a click does.
///
/// Empty `inertServices` + a selection wholly on the current sheet ⇒ everything
/// is in scope and the caller behaves exactly as before (byte-identical).
library;

import 'package:mechx_engine/network/network.dart';

/// The in-scope split of a selection, plus how many members were excluded (so
/// the caller can say so instead of silently doing less than the user asked).
class SelectionScope {
  /// Node ids that may be mutated now.
  final Set<String> nodeIds;

  /// Edge ids that may be mutated now.
  final Set<String> edgeIds;

  /// How many selected members were EXCLUDED (off-sheet, or on a hidden/locked
  /// service). Zero ⇒ the operation covers the whole selection.
  final int excludedCount;

  const SelectionScope({
    required this.nodeIds,
    required this.edgeIds,
    required this.excludedCount,
  });

  /// True when some selected members were left out of the operation.
  bool get hasExcluded => excludedCount > 0;

  /// True when NOTHING is in scope (every member is off-sheet / inert).
  bool get isEmpty => nodeIds.isEmpty && edgeIds.isEmpty;
}

/// Whether [edge] is in scope: both its endpoints resolve, its FROM endpoint
/// sits on [sheetId], and its service is not inert. (A run's two endpoints
/// always share a sheet; a riser spans floors of the SAME sheet.)
bool edgeInScope(
  Network net,
  NetEdge edge,
  String? sheetId,
  Set<ServiceType> inertServices,
) {
  if (inertServices.contains(edge.service)) return false;
  final from = net.nodeById(edge.fromId);
  if (from == null) return false;
  return sheetId == null || from.sheetId == sheetId;
}

/// Whether the node [nodeId] is in scope: it exists, sits on [sheetId], and is
/// not inert. A node is inert when it has at least one incident edge AND EVERY
/// incident edge's service is inert — a free (unwired) node is never inert, so
/// loose equipment is not stranded. This mirrors the canvas hit-test rule
/// exactly (see `selection_overlay.dart` `_nodeInert`).
bool nodeInScope(
  Network net,
  String nodeId,
  String? sheetId,
  Set<ServiceType> inertServices,
) {
  final node = net.nodeById(nodeId);
  if (node == null) return false;
  if (sheetId != null && node.sheetId != sheetId) return false;
  if (inertServices.isEmpty) return true;
  var touched = false;
  for (final e in net.edges) {
    if (e.fromId != nodeId && e.toId != nodeId) continue;
    touched = true;
    if (!inertServices.contains(e.service)) return true;
  }
  return !touched;
}

/// Split a selection into the members a mutating operation may touch now, and
/// count the ones it must leave alone.
///
/// [sheetId] null (no sheet open) skips the sheet test — the service filter
/// still applies. A member whose node/edge no longer exists in [net] is counted
/// as excluded (it cannot be mutated either way).
SelectionScope scopeSelection({
  required Network net,
  required Set<String> nodeIds,
  required Set<String> edgeIds,
  required String? sheetId,
  Set<ServiceType> inertServices = const {},
}) {
  final okNodes = <String>{};
  final okEdges = <String>{};
  var excluded = 0;
  for (final id in nodeIds) {
    if (nodeInScope(net, id, sheetId, inertServices)) {
      okNodes.add(id);
    } else {
      excluded++;
    }
  }
  for (final id in edgeIds) {
    final e = net.edgeById(id);
    if (e != null && edgeInScope(net, e, sheetId, inertServices)) {
      okEdges.add(id);
    } else {
      excluded++;
    }
  }
  return SelectionScope(
    nodeIds: okNodes,
    edgeIds: okEdges,
    excludedCount: excluded,
  );
}

/// C3 (inspector half) — the sheet a SINGLE selected element lives on, or null
/// when it is on [currentSheetId] (nothing to badge) or cannot be resolved.
/// Drives the `On sheet: <name>` header badge + the read-only editor state.
String? owningSheetIfElsewhere(
  Network net, {
  String? nodeId,
  String? edgeId,
  required String? currentSheetId,
}) {
  String? owner;
  if (nodeId != null) {
    owner = net.nodeById(nodeId)?.sheetId;
  } else if (edgeId != null) {
    final e = net.edgeById(edgeId);
    if (e != null) owner = net.nodeById(e.fromId)?.sheetId;
  }
  if (owner == null) return null;
  if (currentSheetId != null && owner == currentSheetId) return null;
  return owner;
}
