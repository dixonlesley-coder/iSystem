import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/standards/pipe_products.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

import 'history_store.dart';

/// Active canvas tool.
enum DrawTool { select, drawRun, drawRiser }

/// Editable drawing state: the [network], the active [tool] + [service], and
/// the transient [pendingPoint] (the first endpoint of a run being drawn, in
/// sheet/world pixels).
@immutable
class DrawingState {
  final Network network;
  final ServiceType service;
  final DrawTool tool;
  final Offset? pendingPoint;

  const DrawingState({
    this.network = const Network(),
    this.service = ServiceType.coldWater,
    this.tool = DrawTool.select,
    this.pendingPoint,
  });

  bool get isDrawing => tool != DrawTool.select;
}

class NetworkController extends Notifier<DrawingState> {
  final List<Network> _undo = [];
  final List<Network> _redo = [];
  int _seq = 0;

  @override
  DrawingState build() => const DrawingState();

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  String _id(String prefix) => '$prefix${_seq++}';

  void _commit(Network next, {Offset? pendingPoint}) {
    _undo.add(state.network);
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
    ref.read(historyProvider.notifier).record(UndoDomain.network);
    state = DrawingState(
      network: next,
      service: state.service,
      tool: state.tool,
      pendingPoint: pendingPoint,
    );
  }

  void setTool(DrawTool tool) => state = DrawingState(
        network: state.network,
        service: state.service,
        tool: tool, // pendingPoint cleared
      );

  void setService(ServiceType service) => state = DrawingState(
        network: state.network,
        service: service,
        tool: state.tool, // pendingPoint cleared
      );

  void cancelPending() => state = DrawingState(
        network: state.network,
        service: state.service,
        tool: state.tool,
      );

  /// Snap to an existing node on [sheetId]/[floorIndex] within [snapRadius]
  /// (world px), or return null if none. Adds nothing.
  String? _snap(
    List<NetNode> nodes,
    String sheetId,
    int floorIndex,
    Offset p,
    double snapRadius,
  ) {
    final r2 = snapRadius * snapRadius;
    for (final n in nodes) {
      if (n.sheetId != sheetId || n.floorIndex != floorIndex) continue;
      final dx = n.x - p.dx;
      final dy = n.y - p.dy;
      if (dx * dx + dy * dy <= r2) return n.id;
    }
    return null;
  }

  /// Place the next point of a run. First call sets the pending start; the
  /// second creates the segment (snapping to existing nodes) and chains.
  void placeRunPoint(
    String sheetId,
    int floorIndex,
    Offset world, {
    double snapRadius = 12,
  }) {
    if (state.tool != DrawTool.drawRun) return;
    if (state.pendingPoint == null) {
      state = DrawingState(
        network: state.network,
        service: state.service,
        tool: state.tool,
        pendingPoint: world,
      );
      return;
    }

    final nodes = [...state.network.nodes];
    String resolve(Offset p) {
      final snapped = _snap(nodes, sheetId, floorIndex, p, snapRadius);
      if (snapped != null) return snapped;
      final id = _id('n');
      nodes.add(NetNode(id: id, sheetId: sheetId, x: p.dx, y: p.dy, floorIndex: floorIndex));
      return id;
    }

    final aId = resolve(state.pendingPoint!);
    final bId = resolve(world);
    if (aId == bId) {
      // zero-length / same node — just advance the pending point
      state = DrawingState(
        network: state.network,
        service: state.service,
        tool: state.tool,
        pendingPoint: world,
      );
      return;
    }
    final edge = NetEdge(id: _id('e'), fromId: aId, toId: bId, service: state.service);
    _commit(
      Network(nodes: nodes, edges: [...state.network.edges, edge]),
      pendingPoint: world, // chain from here
    );
  }

  /// Drop a riser at [world] connecting this floor to the one above. No-op if
  /// there is no floor above ([levelCount]).
  void placeRiser(
    String sheetId,
    int floorIndex,
    Offset world,
    int levelCount, {
    double snapRadius = 12,
  }) {
    if (state.tool != DrawTool.drawRiser) return;
    if (floorIndex + 1 >= levelCount) return;

    final nodes = [...state.network.nodes];
    final lowerSnap = _snap(nodes, sheetId, floorIndex, world, snapRadius);
    final String lowerId;
    if (lowerSnap != null) {
      lowerId = lowerSnap;
    } else {
      lowerId = _id('n');
      nodes.add(NetNode(id: lowerId, sheetId: sheetId, x: world.dx, y: world.dy, floorIndex: floorIndex));
    }
    final upperId = _id('n');
    nodes.add(NetNode(id: upperId, sheetId: sheetId, x: world.dx, y: world.dy, floorIndex: floorIndex + 1));
    final edge = NetEdge(
      id: _id('e'),
      fromId: lowerId,
      toId: upperId,
      service: state.service,
      kind: EdgeKind.riser,
    );
    _commit(Network(nodes: nodes, edges: [...state.network.edges, edge]));
  }

  /// Place a riser of [service] at horizontal position [worldX] on [floorIndex]
  /// spanning to the floor ABOVE, INDEPENDENT of the active tool (used by the
  /// editable vertical/elevation view's palette drop). Both endpoint nodes share
  /// [worldX]; the riser's vertical length is the §10 floor-to-floor elevation
  /// delta (computed by `edgeLength`), NOT a pixel distance. Returns the new
  /// edge id, or null when there is no floor above. Records one undo step.
  String? placeRiserAt(
    String sheetId,
    int floorIndex,
    double worldX,
    int levelCount, {
    ServiceType? service,
    double y = 0,
  }) {
    if (floorIndex < 0 || floorIndex + 1 >= levelCount) return null;
    final svc = service ?? state.service;
    final lowerId = _id('n');
    final upperId = _id('n');
    final lower = NetNode(
        id: lowerId,
        sheetId: sheetId,
        x: worldX,
        y: y,
        floorIndex: floorIndex);
    final upper = NetNode(
        id: upperId,
        sheetId: sheetId,
        x: worldX,
        y: y,
        floorIndex: floorIndex + 1);
    final edgeId = _id('e');
    final edge = NetEdge(
      id: edgeId,
      fromId: lowerId,
      toId: upperId,
      service: svc,
      kind: EdgeKind.riser,
    );
    _commit(Network(
      nodes: [...state.network.nodes, lower, upper],
      edges: [...state.network.edges, edge],
    ));
    return edgeId;
  }

  /// Move BOTH endpoint nodes of a riser [edgeId] to horizontal [worldX] WITHOUT
  /// recording undo (live drag — pair with [pushUndoSnapshot] at drag start).
  /// Only the x changes: the floors (and so the §10 elevation delta that is the
  /// riser's true length) are untouched, so dragging a riser sideways never
  /// alters its length.
  void moveRiserHorizontal(String edgeId, double worldX) {
    final idx = state.network.edges.indexWhere((e) => e.id == edgeId);
    if (idx < 0) return;
    final edge = state.network.edges[idx];
    if (edge.kind != EdgeKind.riser) return;
    final nodes = [
      for (final n in state.network.nodes)
        if (n.id == edge.fromId || n.id == edge.toId)
          n.copyWith(x: worldX)
        else
          n,
    ];
    state = DrawingState(
      network: Network(nodes: nodes, edges: state.network.edges),
      service: state.service,
      tool: state.tool,
      pendingPoint: state.pendingPoint,
    );
  }

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(state.network);
    state = DrawingState(
      network: _undo.removeLast(),
      service: state.service,
      tool: state.tool,
    );
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(state.network);
    state = DrawingState(
      network: _redo.removeLast(),
      service: state.service,
      tool: state.tool,
    );
  }

  void clear() {
    if (state.network.nodes.isEmpty && state.network.edges.isEmpty) return;
    _commit(const Network());
  }

  // ── Editing (used by the select tool) ───────────────────────────────────────

  /// Remove [id] and every edge touching it.
  void deleteNode(String id) {
    if (state.network.nodeById(id) == null) return;
    final nodes = state.network.nodes.where((n) => n.id != id).toList();
    final edges = state.network.edges
        .where((e) => e.fromId != id && e.toId != id)
        .toList();
    _commit(Network(nodes: nodes, edges: edges));
  }

  /// Remove edge [id], pruning any junction ([NodeRole.main]) node it leaves
  /// isolated. Fixture/plant nodes are kept (they carry meaning on their own).
  void deleteEdge(String id) {
    if (!state.network.edges.any((e) => e.id == id)) return;
    final edges = state.network.edges.where((e) => e.id != id).toList();
    final used = <String>{
      for (final e in edges) ...[e.fromId, e.toId],
    };
    final nodes = state.network.nodes
        .where((n) => used.contains(n.id) || n.role != NodeRole.main)
        .toList();
    _commit(Network(nodes: nodes, edges: edges));
  }

  /// Change a node's vertical [role]. Leaving [NodeRole.fixture] clears the
  /// terminal payload (plumbing fixture AND air-terminal airflow); both denote a
  /// terminal, so neither survives a switch to a main/plant role.
  void setNodeRole(String id, NodeRole role) {
    final node = state.network.nodeById(id);
    if (node == null || node.role == role) return;
    final keepTerminal = role == NodeRole.fixture;
    _replaceNode(NetNode(
      id: node.id,
      sheetId: node.sheetId,
      x: node.x,
      y: node.y,
      floorIndex: node.floorIndex,
      role: role,
      elevation: node.elevation,
      fixture: keepTerminal ? node.fixture : null,
      airflow: keepTerminal ? node.airflow : null,
    ));
  }

  /// Assign (or clear) the built-in plumbing [fixture] at a node, marking it a
  /// fixture. Selecting a built-in fixture clears any custom fixture (the two
  /// are mutually exclusive); copyWith preserves the node's other fields.
  void setNodeFixture(String id, PlumbingFixture? fixture) {
    final node = state.network.nodeById(id);
    if (node == null) return;
    if (fixture == null) {
      // Clear the built-in fixture (and any custom fixture): the constructor
      // default for `fixture` is null. Preserve roofAreaM2.
      _replaceNode(NetNode(
        id: node.id,
        sheetId: node.sheetId,
        x: node.x,
        y: node.y,
        floorIndex: node.floorIndex,
        role: node.role,
        elevation: node.elevation,
        airflow: node.airflow,
        roofAreaM2: node.roofAreaM2,
      ));
      return;
    }
    _replaceNode(node.copyWith(
      role: NodeRole.fixture,
      fixture: fixture,
      clearCustomFixtureId: true,
    ));
  }

  /// Assign the design [airflow] at a node, marking it an air terminal
  /// (diffuser/grille). Pass null to clear it.
  void setNodeAirflow(String id, FlowRate? airflow) {
    final node = state.network.nodeById(id);
    if (node == null) return;
    _replaceNode(NetNode(
      id: node.id,
      sheetId: node.sheetId,
      x: node.x,
      y: node.y,
      floorIndex: node.floorIndex,
      role: airflow == null ? node.role : NodeRole.fixture,
      elevation: node.elevation,
      fixture: node.fixture,
      airflow: airflow,
    ));
  }

  /// Set an explicit absolute [elevation] override on a node (e.g. a roof tank
  /// on a stand, or a basement plant). Pass null to revert to the role default.
  void setNodeElevation(String id, Length? elevation) {
    final node = state.network.nodeById(id);
    if (node == null) return;
    _replaceNode(NetNode(
      id: node.id,
      sheetId: node.sheetId,
      x: node.x,
      y: node.y,
      floorIndex: node.floorIndex,
      role: node.role,
      elevation: elevation,
      fixture: node.fixture,
      airflow: node.airflow,
    ));
  }

  /// Assign a user-defined custom fixture type [customFixtureId] to a node (the
  /// app resolves the id to its UBAP load). Pass null to clear it. Marks the node
  /// a fixture terminal when set. Uses copyWith so other node fields survive.
  void setNodeCustomFixture(String id, String? customFixtureId) {
    final node = state.network.nodeById(id);
    if (node == null) return;
    // Assigning a custom fixture clears the built-in [fixture] (mutual
    // exclusivity). The fresh constructor (with `fixture` omitted) is how we
    // clear it — copyWith has no clear-fixture flag — while preserving the
    // node's other fields (roofAreaM2, airflow, elevation).
    _replaceNode(NetNode(
      id: node.id,
      sheetId: node.sheetId,
      x: node.x,
      y: node.y,
      floorIndex: node.floorIndex,
      role: customFixtureId == null ? node.role : NodeRole.fixture,
      elevation: node.elevation,
      fixture: customFixtureId == null ? node.fixture : null,
      airflow: node.airflow,
      customFixtureId: customFixtureId,
      roofAreaM2: node.roofAreaM2,
    ));
  }

  /// Set the catchment [roofAreaM2] (m²) draining to a rainwater outlet node, for
  /// storm sizing. Pass null to revert to the flat default catchment.
  void setNodeRoofArea(String id, double? roofAreaM2) {
    final node = state.network.nodeById(id);
    if (node == null) return;
    _replaceNode(node.copyWith(
      roofAreaM2: roofAreaM2,
      clearRoofAreaM2: roofAreaM2 == null,
    ));
  }

  /// Change the service an edge carries.
  void setEdgeService(String id, ServiceType service) {
    final idx = state.network.edges.indexWhere((e) => e.id == id);
    if (idx < 0 || state.network.edges[idx].service == service) return;
    final e = state.network.edges[idx];
    _replaceEdge(e.copyWith(service: service));
  }

  /// Replace an edge in-place (one undo step). No-op if [updated]'s id is gone.
  void _replaceEdge(NetEdge updated) {
    final idx = state.network.edges.indexWhere((e) => e.id == updated.id);
    if (idx < 0) return;
    final edges = [...state.network.edges];
    edges[idx] = updated;
    _commit(Network(nodes: state.network.nodes, edges: edges));
  }

  /// Set (or clear, with null) the pipe **product** for a segment — a per-edge
  /// material label / BOM concern (sizing routing is unchanged).
  void setEdgePipeProduct(String id, PipeProduct? product) {
    final idx = state.network.edges.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    final e = state.network.edges[idx];
    if (e.pipeProduct == product) return;
    _replaceEdge(
      product == null
          ? e.copyWith(clearPipeProduct: true)
          : e.copyWith(pipeProduct: product),
    );
  }

  /// Set (or clear, with null) the duct **product** for an air segment.
  void setEdgeDuctProduct(String id, DuctProduct? product) {
    final idx = state.network.edges.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    final e = state.network.edges[idx];
    if (e.ductProduct == product) return;
    _replaceEdge(
      product == null
          ? e.copyWith(clearDuctProduct: true)
          : e.copyWith(ductProduct: product),
    );
  }

  /// Set (or clear, with null) the manual nominal-size override for a segment.
  void setEdgeSizeOverride(String id, Diameter? size) {
    final idx = state.network.edges.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    final e = state.network.edges[idx];
    if (e.sizeOverride?.meters == size?.meters) return;
    _replaceEdge(
      size == null
          ? e.copyWith(clearSizeOverride: true)
          : e.copyWith(sizeOverride: size),
    );
  }

  // ── Drag-and-drop palette (drop a segment / fitting / terminal) ─────────────

  /// Default horizontal span (world px) of a dropped segment, before snapping.
  static const double _defaultSegmentSpanPx = 120;

  /// Drop a default-length horizontal SEGMENT of [service] centred on [world]:
  /// two nodes a default span apart joined by a run, each endpoint snapping to a
  /// nearby existing node within [snapRadius]. Records one undo step.
  void addSegment(
    String sheetId,
    int floorIndex,
    Offset world, {
    ServiceType? service,
    double snapRadius = 12,
    double? spanPx,
  }) {
    final svc = service ?? state.service;
    final half = (spanPx ?? _defaultSegmentSpanPx) / 2;
    final aWorld = Offset(world.dx - half, world.dy);
    final bWorld = Offset(world.dx + half, world.dy);

    final nodes = [...state.network.nodes];
    String resolve(Offset p) {
      final snapped = _snap(nodes, sheetId, floorIndex, p, snapRadius);
      if (snapped != null) return snapped;
      final id = _id('n');
      nodes.add(
          NetNode(id: id, sheetId: sheetId, x: p.dx, y: p.dy, floorIndex: floorIndex));
      return id;
    }

    final aId = resolve(aWorld);
    final bId = resolve(bWorld);
    if (aId == bId) return; // both snapped to the same node — nothing to add
    final edge = NetEdge(id: _id('e'), fromId: aId, toId: bId, service: svc);
    _commit(Network(nodes: nodes, edges: [...state.network.edges, edge]));
  }

  /// Drop a FITTING — a bare junction ([NodeRole.main]) — at [world]. Records
  /// one undo step.
  void addFitting(String sheetId, int floorIndex, Offset world) {
    final node = NetNode(
      id: _id('n'),
      sheetId: sheetId,
      x: world.dx,
      y: world.dy,
      floorIndex: floorIndex,
    );
    _commit(Network(
      nodes: [...state.network.nodes, node],
      edges: state.network.edges,
    ));
  }

  /// Drop a TERMINAL — a [NodeRole.fixture] node, optionally carrying a
  /// [fixture] so it bears demand — at [world]. Records one undo step.
  void addTerminal(
    String sheetId,
    int floorIndex,
    Offset world, {
    PlumbingFixture? fixture,
  }) {
    final node = NetNode(
      id: _id('n'),
      sheetId: sheetId,
      x: world.dx,
      y: world.dy,
      floorIndex: floorIndex,
      role: NodeRole.fixture,
      fixture: fixture,
    );
    _commit(Network(
      nodes: [...state.network.nodes, node],
      edges: state.network.edges,
    ));
  }

  /// Call at the END of a node drag: if the node now lands within
  /// [snapRadiusWorld] of ANOTHER node on the same sheet/floor, MERGE the two —
  /// re-point every edge that referenced the dragged node to the target, drop
  /// the dragged node, and drop any edge that became a self-loop (zero length).
  /// This is how a dragged segment endpoint "connects/snaps to a fitting".
  /// Records one undo step (pair with [pushUndoSnapshot]/[moveNode] live drag).
  void endNodeDragWithSnap(String nodeId, double snapRadiusWorld) {
    final dragged = state.network.nodeById(nodeId);
    if (dragged == null) return;

    // Nearest OTHER node on the same sheet/floor within the snap radius.
    final r2 = snapRadiusWorld * snapRadiusWorld;
    String? targetId;
    var best = r2;
    for (final n in state.network.nodes) {
      if (n.id == nodeId) continue;
      if (n.sheetId != dragged.sheetId || n.floorIndex != dragged.floorIndex) {
        continue;
      }
      final dx = n.x - dragged.x;
      final dy = n.y - dragged.y;
      final d2 = dx * dx + dy * dy;
      if (d2 <= best) {
        best = d2;
        targetId = n.id;
      }
    }
    if (targetId == null) return; // nothing to snap to

    final target = targetId;
    // Re-point edges, dropping self-loops left by the merge.
    final edges = <NetEdge>[];
    for (final e in state.network.edges) {
      final from = e.fromId == nodeId ? target : e.fromId;
      final to = e.toId == nodeId ? target : e.toId;
      if (from == to) continue; // collapsed self-loop — drop it
      edges.add(
          (from == e.fromId && to == e.toId) ? e : e.copyWith(fromId: from, toId: to));
    }
    final nodes = state.network.nodes.where((n) => n.id != nodeId).toList();
    _commit(Network(nodes: nodes, edges: edges));
  }

  /// Copy every horizontal RUN (and the nodes it touches) on
  /// [fromSheetId]/[fromFloor] onto [toSheetId]/[toFloor] with fresh ids —
  /// "same layout on the next floor". Risers are not copied (they span floors).
  /// No-op if the source floor has no runs.
  void duplicateFloor({
    required String fromSheetId,
    required int fromFloor,
    required String toSheetId,
    required int toFloor,
  }) {
    final old = state.network;
    final clones = <String, String>{}; // old node id → new node id
    final addedNodes = <NetNode>[];
    final addedEdges = <NetEdge>[];

    String cloneNode(NetNode n) {
      final existing = clones[n.id];
      if (existing != null) return existing;
      final id = _id('n');
      clones[n.id] = id;
      addedNodes.add(NetNode(
        id: id,
        sheetId: toSheetId,
        x: n.x,
        y: n.y,
        floorIndex: toFloor,
        role: n.role,
        elevation: n.elevation,
        fixture: n.fixture,
        airflow: n.airflow,
      ));
      return id;
    }

    for (final e in old.edges) {
      if (e.kind != EdgeKind.run) continue;
      final a = old.nodeById(e.fromId);
      final b = old.nodeById(e.toId);
      if (a == null || b == null) continue;
      if (a.sheetId != fromSheetId || a.floorIndex != fromFloor) continue;
      if (b.sheetId != fromSheetId || b.floorIndex != fromFloor) continue;
      addedEdges.add(NetEdge(
        id: _id('e'),
        fromId: cloneNode(a),
        toId: cloneNode(b),
        service: e.service,
        kind: EdgeKind.run,
      ));
    }
    if (addedEdges.isEmpty) return;
    _commit(Network(
      nodes: [...old.nodes, ...addedNodes],
      edges: [...old.edges, ...addedEdges],
    ));
  }

  void _replaceNode(NetNode updated) {
    final nodes = [
      for (final n in state.network.nodes)
        if (n.id == updated.id) updated else n,
    ];
    _commit(Network(nodes: nodes, edges: state.network.edges));
  }

  /// Snapshot the current network onto the undo stack — call once at the start
  /// of a drag so the whole move collapses into a single undo step.
  void pushUndoSnapshot() {
    _undo.add(state.network);
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
    ref.read(historyProvider.notifier).record(UndoDomain.network);
  }

  /// Move a node to ([x], [y]) in sheet/world pixels WITHOUT recording undo
  /// (live drag). Pair with [pushUndoSnapshot] at drag start.
  void moveNode(String id, double x, double y) {
    final node = state.network.nodeById(id);
    if (node == null) return;
    final nodes = [
      for (final n in state.network.nodes)
        if (n.id == id) n.copyWith(x: x, y: y) else n,
    ];
    state = DrawingState(
      network: Network(nodes: nodes, edges: state.network.edges),
      service: state.service,
      tool: state.tool,
      pendingPoint: state.pendingPoint,
    );
  }

  /// Replace the network (used when opening a saved document). Resets history
  /// and advances the id counter past any loaded ids to avoid collisions.
  void loadNetwork(Network net) {
    _undo.clear();
    _redo.clear();
    _seq = _maxLoadedSeq(net) + 1;
    state = DrawingState(network: net, service: state.service);
  }

  int _maxLoadedSeq(Network net) {
    var max = -1;
    for (final id in [
      ...net.nodes.map((n) => n.id),
      ...net.edges.map((e) => e.id),
    ]) {
      final value = int.tryParse(id.replaceAll(RegExp(r'[^0-9]'), ''));
      if (value != null && value > max) max = value;
    }
    return max;
  }
}

final networkControllerProvider =
    NotifierProvider<NetworkController, DrawingState>(NetworkController.new);

/// Whether run drawing snaps to the nearest 45° (ortho). Default on.
final orthoProvider =
    NotifierProvider<OrthoController, bool>(OrthoController.new);

class OrthoController extends Notifier<bool> {
  @override
  bool build() => true;

  void toggle() => state = !state;
}
