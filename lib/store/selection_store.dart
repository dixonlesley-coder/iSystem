import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

import 'network_store.dart';

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

  /// Whether [id] is part of the current multi-selection. Lets a context-menu /
  /// inspector edit decide to apply a BATCH setter to the whole selection (which
  /// leaves the selection alive) rather than collapsing to the one target — the
  /// store side of E1's "batch survives a property edit".
  bool containsEdge(String id) => edgeIds.contains(id);
  bool containsNode(String id) => nodeIds.contains(id);

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

  /// UNION [nodeIds]/[edgeIds] into the current selection (a Shift-marquee
  /// ADDS to the selection instead of replacing it). Empty input is a no-op —
  /// an additive gesture never clears what's already picked.
  void addMulti(Set<String> nodeIds, Set<String> edgeIds) {
    if (nodeIds.isEmpty && edgeIds.isEmpty) return;
    setMulti({...state.nodeIds, ...nodeIds}, {...state.edgeIds, ...edgeIds});
  }

  /// Select EVERYTHING on [sheetId]/[floorIndex] — every run edge (both
  /// endpoints on the floor) plus every on-floor node — optionally filtered to
  /// [services] (the active discipline layer's services, so Ctrl+A on the
  /// Plumbing layer doesn't grab the HVAC ducts). A node carries no service,
  /// so its membership mirrors the layer painter: it matches when ANY incident
  /// edge's service passes the filter, and a FREE node (no edges) always
  /// belongs (freestanding fittings/fixtures aren't lost). No-op when the
  /// floor is empty. A pure selection change — records no undo step.
  void selectAllOnFloor(
    String sheetId,
    int floorIndex, {
    Set<ServiceType>? services,
  }) {
    final net = ref.read(networkControllerProvider).network;
    bool serviceOk(ServiceType s) => services == null || services.contains(s);
    bool onFloor(NetNode n) =>
        n.sheetId == sheetId && n.floorIndex == floorIndex;

    final edgeIds = <String>{};
    for (final e in net.edges) {
      if (e.kind != EdgeKind.run || !serviceOk(e.service)) continue;
      final a = net.nodeById(e.fromId);
      final b = net.nodeById(e.toId);
      if (a == null || b == null || !onFloor(a) || !onFloor(b)) continue;
      edgeIds.add(e.id);
    }
    final nodeIds = <String>{};
    for (final n in net.nodes) {
      if (!onFloor(n)) continue;
      var touched = false;
      var matches = false;
      for (final e in net.edges) {
        if (e.fromId != n.id && e.toId != n.id) continue;
        touched = true;
        if (serviceOk(e.service)) {
          matches = true;
          break;
        }
      }
      if (!touched || matches) nodeIds.add(n.id);
    }
    if (nodeIds.isEmpty && edgeIds.isEmpty) return;
    setMulti(nodeIds, edgeIds);
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

  /// Select every EDGE that carries the same service as [edgeId] (e.g. all
  /// cold-water runs), so the drafter can batch-edit size/material/delete in one
  /// gesture. A pure selection change — records no undo step. No-op if the seed
  /// edge is gone. "Similar" = same [ServiceType]; deliberately not size/product
  /// (matching the whole service is the predictable, useful default).
  ///
  /// E2 — SCOPE. By default the match is confined to the seed's own sheet AND
  /// floor: a drafter picking "select similar" on a floor plan means the runs
  /// in front of them, and a building-wide DN change made from a "14 selected"
  /// header they never saw the span of is a silent, expensive mistake. Pass
  /// [allFloors] `true` for the explicit whole-building variant (the second menu
  /// row). An edge belongs to the scope when BOTH its endpoints do — a riser,
  /// which by definition spans two floors, is therefore only ever caught by the
  /// all-floors variant.
  void selectSimilarEdges(String edgeId, {bool allFloors = false}) {
    final net = ref.read(networkControllerProvider).network;
    final seed = net.edgeById(edgeId);
    if (seed == null) return;
    final anchor = net.nodeById(seed.fromId);
    bool inScope(NetEdge e) {
      if (allFloors || anchor == null) return true;
      final a = net.nodeById(e.fromId);
      final b = net.nodeById(e.toId);
      if (a == null || b == null) return false;
      return a.sheetId == anchor.sheetId &&
          a.floorIndex == anchor.floorIndex &&
          b.sheetId == anchor.sheetId &&
          b.floorIndex == anchor.floorIndex;
    }

    final ids = <String>{
      for (final e in net.edges)
        if (e.service == seed.service && inScope(e)) e.id,
    };
    if (ids.isEmpty) return;
    setMulti(const {}, ids);
  }

  /// Select every NODE of the same component kind as [nodeId] (all pumps, all
  /// gate valves, …; a plain junction with no component matches other plain
  /// junctions). A pure selection change — no undo step. No-op if the seed node
  /// is gone.
  ///
  /// E2 — scoped to the seed's own sheet+floor by default; [allFloors] `true`
  /// is the explicit whole-building variant.
  void selectSimilarNodes(String nodeId, {bool allFloors = false}) {
    final net = ref.read(networkControllerProvider).network;
    final seed = net.nodeById(nodeId);
    if (seed == null) return;
    final ids = <String>{
      for (final n in net.nodes)
        if (n.component == seed.component &&
            (allFloors ||
                (n.sheetId == seed.sheetId &&
                    n.floorIndex == seed.floorIndex)))
          n.id,
    };
    if (ids.isEmpty) return;
    setMulti(ids, const {});
  }
}

final selectionProvider =
    NotifierProvider<SelectionController, Selection>(SelectionController.new);

/// The single node/edge under the cursor while the Select tool hovers — the
/// DETECTION half of hover pre-highlight. The selection gesture layer runs its
/// hit-test on pointer hover and publishes the hit here; the network painter
/// reads it to draw a subtle rollover halo. At most one of the two ids is set.
/// Null when nothing is under the cursor (and on pointer exit), so an idle
/// canvas is byte-identical. Record equality makes [set] notify only on CHANGE
/// — per-frame hover churn over the same element never rebuilds a watcher.
typedef HoverTarget = ({String? nodeId, String? edgeId});

class HoverTargetController extends Notifier<HoverTarget?> {
  @override
  HoverTarget? build() => null;

  void set(HoverTarget? target) {
    if (state != target) state = target;
  }

  void clear() => set(null);
}

final hoverTargetProvider =
    NotifierProvider<HoverTargetController, HoverTarget?>(
        HoverTargetController.new);
