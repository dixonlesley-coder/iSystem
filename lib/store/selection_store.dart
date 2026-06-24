import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The currently selected network element(s). The single [nodeId]/[edgeId] are
/// the PRIMARY (last-clicked) element that drives the inspector edit panel and
/// canvas highlight; [nodeIds]/[edgeIds] are the full multi-selection sets (a
/// plain click holds one id, a marquee / shift-click can hold many).
@immutable
class Selection {
  final String? nodeId;
  final String? edgeId;

  /// The full multi-selection sets. A single click collapses these to the one
  /// clicked id; the marquee / shift-click grow them. The primary [nodeId] /
  /// [edgeId] is always one of these (the last toggled).
  final Set<String> nodeIds;
  final Set<String> edgeIds;

  const Selection({
    this.nodeId,
    this.edgeId,
    this.nodeIds = const {},
    this.edgeIds = const {},
  });

  static const none = Selection();

  bool get isEmpty => nodeId == null && edgeId == null;
  bool get isNode => nodeId != null;
  bool get isEdge => edgeId != null;

  /// Whether more than one element is selected (drives the multi inspector).
  bool get isMulti => nodeIds.length + edgeIds.length > 1;

  /// Whether anything at all is selected (across the sets).
  bool get hasSelection => nodeIds.isNotEmpty || edgeIds.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is Selection &&
      other.nodeId == nodeId &&
      other.edgeId == edgeId &&
      setEquals(other.nodeIds, nodeIds) &&
      setEquals(other.edgeIds, edgeIds);

  @override
  int get hashCode => Object.hash(
        nodeId,
        edgeId,
        Object.hashAllUnordered(nodeIds),
        Object.hashAllUnordered(edgeIds),
      );
}

class SelectionController extends Notifier<Selection> {
  @override
  Selection build() => Selection.none;

  /// Plain click on a node — replace the whole selection with this single node.
  void selectNode(String id) => state = Selection(nodeId: id, nodeIds: {id});

  /// Plain click on an edge — replace the whole selection with this single edge.
  void selectEdge(String id) => state = Selection(edgeId: id, edgeIds: {id});

  /// Shift-click a node: add it if absent, remove it if present. The toggled id
  /// becomes the primary when added; when removed, the primary collapses to any
  /// remaining selected element (or nothing).
  void toggleNode(String id) {
    final nodes = {...state.nodeIds};
    if (nodes.contains(id)) {
      nodes.remove(id);
      state = _afterRemove(nodes, state.edgeIds);
    } else {
      nodes.add(id);
      state = Selection(nodeId: id, nodeIds: nodes, edgeIds: state.edgeIds);
    }
  }

  /// Shift-click an edge — add/remove, mirroring [toggleNode].
  void toggleEdge(String id) {
    final edges = {...state.edgeIds};
    if (edges.contains(id)) {
      edges.remove(id);
      state = _afterRemove(state.nodeIds, edges);
    } else {
      edges.add(id);
      state = Selection(edgeId: id, nodeIds: state.nodeIds, edgeIds: edges);
    }
  }

  /// After removing an id, pick a new primary from whatever remains.
  Selection _afterRemove(Set<String> nodes, Set<String> edges) {
    if (nodes.isEmpty && edges.isEmpty) return Selection.none;
    if (nodes.isNotEmpty) {
      return Selection(nodeId: nodes.first, nodeIds: nodes, edgeIds: edges);
    }
    return Selection(edgeId: edges.first, nodeIds: nodes, edgeIds: edges);
  }

  /// Set the full multi-selection (e.g. a rubber-band result). The primary is
  /// set to one of the members (a node first, else an edge); empty input clears.
  void setMulti(Set<String> nodeIds, Set<String> edgeIds) {
    if (nodeIds.isEmpty && edgeIds.isEmpty) {
      clear();
      return;
    }
    if (nodeIds.isNotEmpty) {
      state = Selection(
          nodeId: nodeIds.first, nodeIds: {...nodeIds}, edgeIds: {...edgeIds});
    } else {
      state = Selection(
          edgeId: edgeIds.first, nodeIds: {...nodeIds}, edgeIds: {...edgeIds});
    }
  }

  void clear() {
    if (state != Selection.none) state = Selection.none;
  }
}

final selectionProvider =
    NotifierProvider<SelectionController, Selection>(SelectionController.new);
