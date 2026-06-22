import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The currently selected network element (a node, an edge, or nothing). Used
/// by the select tool to drive the inspector edit panel and canvas highlight.
@immutable
class Selection {
  final String? nodeId;
  final String? edgeId;

  const Selection({this.nodeId, this.edgeId});

  static const none = Selection();

  bool get isEmpty => nodeId == null && edgeId == null;
  bool get isNode => nodeId != null;
  bool get isEdge => edgeId != null;

  @override
  bool operator ==(Object other) =>
      other is Selection && other.nodeId == nodeId && other.edgeId == edgeId;

  @override
  int get hashCode => Object.hash(nodeId, edgeId);
}

class SelectionController extends Notifier<Selection> {
  @override
  Selection build() => Selection.none;

  void selectNode(String id) => state = Selection(nodeId: id);
  void selectEdge(String id) => state = Selection(edgeId: id);
  void clear() {
    if (!state.isEmpty) state = Selection.none;
  }
}

final selectionProvider =
    NotifierProvider<SelectionController, Selection>(SelectionController.new);
