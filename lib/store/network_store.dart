import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/grille_sizing.dart' show standardGrilleFacesMm;
import 'package:mechx_engine/sizing/network_sizing.dart'
    show DuctShape, DuctSizingMethod;
import 'package:mechx_engine/sizing/room_air.dart' show TerminalBank;
import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/standards/pipe_products.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

import 'annotation_store.dart' show RoomArea;
import 'history_store.dart';
import 'selection_store.dart';

/// Active canvas tool.
enum DrawTool { select, drawRun, drawRiser }

/// A value-copy of a slice of the network held on the in-memory clipboard for
/// copy/paste. Holds deep copies of the chosen nodes and the edges among them.
@immutable
class _Clipboard {
  final List<NetNode> nodes;
  final List<NetEdge> edges;
  const _Clipboard(this.nodes, this.edges);
}

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

  /// In-memory copy/paste clipboard (NOT persisted to the .mechx file).
  _Clipboard? _clipboard;

  @override
  DrawingState build() => const DrawingState();

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Whether the clipboard holds something to paste.
  bool get hasClipboard => _clipboard != null && _clipboard!.nodes.isNotEmpty;

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
      mountHeight: node.mountHeight,
      component: node.component,
      tankCapacityLitres: node.tankCapacityLitres,
      electricalLoadW: node.electricalLoadW,
      faceWidthMm: node.faceWidthMm,
      faceHeightMm: node.faceHeightMm,
      fittingType: node.fittingType,
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
        mountHeight: node.mountHeight,
      component: node.component,
      tankCapacityLitres: node.tankCapacityLitres,
      electricalLoadW: node.electricalLoadW,
      faceWidthMm: node.faceWidthMm,
      faceHeightMm: node.faceHeightMm,
      fittingType: node.fittingType,
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
      mountHeight: node.mountHeight,
      component: node.component,
      tankCapacityLitres: node.tankCapacityLitres,
      electricalLoadW: node.electricalLoadW,
      faceWidthMm: node.faceWidthMm,
      faceHeightMm: node.faceHeightMm,
      fittingType: node.fittingType,
      fixture: node.fixture,
      airflow: airflow,
      customFixtureId: node.customFixtureId,
      roofAreaM2: node.roofAreaM2,
    ));
  }

  /// Set (or clear, with null) the manually chosen grille/diffuser FACE size
  /// (gross width × height, mm) at an air terminal. The velocity-warning layer
  /// judges the resulting face velocity against the recommended band.
  void setNodeFace(String id, double? widthMm, double? heightMm) {
    final node = state.network.nodeById(id);
    if (node == null) return;
    final clear = widthMm == null || heightMm == null;
    if (node.faceWidthMm == widthMm && node.faceHeightMm == heightMm) return;
    _replaceNode(clear
        ? node.copyWith(clearFace: true)
        : node.copyWith(faceWidthMm: widthMm, faceHeightMm: heightMm));
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
      customFixtureId: node.customFixtureId,
      roofAreaM2: node.roofAreaM2,
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
      mountHeight: node.mountHeight,
      component: node.component,
      tankCapacityLitres: node.tankCapacityLitres,
      electricalLoadW: node.electricalLoadW,
      faceWidthMm: node.faceWidthMm,
      faceHeightMm: node.faceHeightMm,
      fittingType: node.fittingType,
      fixture: customFixtureId == null ? node.fixture : null,
      airflow: node.airflow,
      customFixtureId: customFixtureId,
      roofAreaM2: node.roofAreaM2,
    ));
  }

  /// Set this node's [mountHeight] above its own floor — "how high on the wall"
  /// the fixture/outlet sits — which drives its true elevation and therefore its
  /// vertical run. Pass null to revert to the role default (fixture height /
  /// ceiling / roof). copyWith preserves the node's other fields.
  void setNodeMountHeight(String id, Length? mountHeight) {
    final node = state.network.nodeById(id);
    if (node == null) return;
    _replaceNode(node.copyWith(
      mountHeight: mountHeight,
      clearMountHeight: mountHeight == null,
    ));
  }

  /// Set (or clear, with null) the equipment [component] a node represents.
  /// Clearing reverts it to an ordinary node (its role is left as-is).
  void setNodeComponent(String id, NodeComponent? component) {
    final node = state.network.nodeById(id);
    if (node == null) return;
    _replaceNode(node.copyWith(
      component: component,
      clearComponent: component == null,
    ));
  }

  /// Set (or clear, with null/[JunctionFitting.auto]) the fitting-type override on a
  /// junction node — right-click → Fitting (Tee / Wye / Tee-wye / …). Clearing
  /// reverts to the geometry-derived fitting. copyWith preserves other fields.
  void setNodeFittingType(String id, JunctionFitting? fitting) {
    final node = state.network.nodeById(id);
    if (node == null) return;
    final clear = fitting == null || fitting == JunctionFitting.auto;
    _replaceNode(node.copyWith(
      fittingType: clear ? null : fitting,
      clearJunctionFitting: clear,
    ));
  }

  /// Set the stored tank [capacityLitres] on a tank component node (a prebuilt
  /// tank bought at a fixed size). Pass null to clear it.
  void setNodeTankCapacity(String id, double? capacityLitres) {
    final node = state.network.nodeById(id);
    if (node == null) return;
    _replaceNode(node.copyWith(
      tankCapacityLitres: capacityLitres,
      clearTankCapacity: capacityLitres == null,
    ));
  }

  /// Set the explicit electrical load (W) on a motorised equipment node (pump /
  /// fan / air unit) — its draw on the electrical panel. Pass null to revert to
  /// the component's default rating.
  void setNodeElectricalLoad(String id, double? watts) {
    final node = state.network.nodeById(id);
    if (node == null) return;
    _replaceNode(node.copyWith(
      electricalLoadW: watts,
      clearElectricalLoad: watts == null,
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

  /// Drop an EQUIPMENT / COMPONENT node (pump, roof tank, valve, roof drain,
  /// meter…) at [world]. The component sets the node's [NodeRole] (plant for
  /// pumps/tanks, fixture for drains, main for inline valves/meters), so a pump
  /// or tank feeds the pressure solve as a plant source with no extra wiring.
  /// Records one undo step.
  void addComponentNode(
    String sheetId,
    int floorIndex,
    Offset world,
    NodeComponent component,
  ) {
    final node = NetNode(
      id: _id('n'),
      sheetId: sheetId,
      x: world.dx,
      y: world.dy,
      floorIndex: floorIndex,
      role: component.role,
      component: component,
    );
    _commit(Network(
      nodes: [...state.network.nodes, node],
      edges: state.network.edges,
    ));
  }

  /// Auto-place the air terminals a [room] needs — closing the room→network
  /// loop. Runs the room's ACH air-side sizing ([RoomArea.sizing]) to get the
  /// supply-diffuser COUNT + per-terminal airflow + chosen face, then drops that
  /// many [NodeComponent.supplyDiffuser] nodes on a simple grid inside the room's
  /// footprint rectangle (on the room's own sheet/floor), each carrying the
  /// per-terminal [FlowRate] airflow + `faceWidthMm`/`faceHeightMm`; plus one
  /// [NodeComponent.returnGrille] node carrying the return bank's airflow + face.
  ///
  /// All nodes land in ONE undo step. A null/degenerate sizing (no scale, zero
  /// footprint) is a no-op (nothing recorded). Returns the new supply-diffuser
  /// node ids (for optional trunk wiring); empty on a no-op.
  List<String> autoPlaceRoomTerminals({
    required RoomArea room,
    required double metersPerPixel,
    DuctShape ductShape = DuctShape.round,
    DuctSizingMethod ductMethod = DuctSizingMethod.velocity,
  }) {
    final s = room.sizing(metersPerPixel,
        ductShape: ductShape, ductMethod: ductMethod);
    if (s == null) return const [];

    final loX = room.ax < room.bx ? room.ax : room.bx;
    final hiX = room.ax < room.bx ? room.bx : room.ax;
    final loY = room.ay < room.by ? room.ay : room.by;
    final hiY = room.ay < room.by ? room.by : room.ay;
    final w = hiX - loX;
    final h = hiY - loY;
    if (w <= 0 || h <= 0) return const [];

    // Lay the supply diffusers out on a near-square grid inside the footprint,
    // each cell's centre giving the node position (inset off the room edge).
    final n = s.supply.count;
    final cols = math.max(1, math.sqrt(n).ceil());
    final rows = (n / cols).ceil();
    final supplyFace = _faceMm(s.supply);
    final returnFace = _faceMm(s.return_);

    final nodes = [...state.network.nodes];
    final ids = <String>[];
    var placed = 0;
    for (var ry = 0; ry < rows && placed < n; ry++) {
      for (var cx = 0; cx < cols && placed < n; cx++) {
        final px = loX + w * (cx + 0.5) / cols;
        final py = loY + h * (ry + 0.5) / rows;
        final id = _id('n');
        ids.add(id);
        nodes.add(NetNode(
          id: id,
          sheetId: room.sheetId,
          x: px,
          y: py,
          floorIndex: room.floorIndex,
          role: NodeComponent.supplyDiffuser.role,
          component: NodeComponent.supplyDiffuser,
          airflow: s.supply.airflowEach,
          faceWidthMm: supplyFace.$1,
          faceHeightMm: supplyFace.$2,
        ));
        placed++;
      }
    }

    // One return grille near the room centre.
    nodes.add(NetNode(
      id: _id('n'),
      sheetId: room.sheetId,
      x: loX + w * 0.5,
      y: loY + h * 0.5,
      floorIndex: room.floorIndex,
      role: NodeComponent.returnGrille.role,
      component: NodeComponent.returnGrille,
      airflow: s.return_.airflowEach,
      faceWidthMm: returnFace.$1,
      faceHeightMm: returnFace.$2,
    ));

    _commit(Network(nodes: nodes, edges: state.network.edges));
    return ids;
  }

  /// The standard rectangular face (width, height in mm) the engine chose for a
  /// [bank], recovered by matching the bank's chosen gross face area against the
  /// standard catalogue (see [standardGrilleFacesMm]).
  (double, double) _faceMm(TerminalBank bank) {
    final targetM2 = bank.each.grossFaceArea.squareMeters;
    var best = standardGrilleFacesMm.first;
    var bestErr = double.infinity;
    for (final f in standardGrilleFacesMm) {
      final grossM2 = (f.$1 / 1000.0) * (f.$2 / 1000.0);
      final err = (grossM2 - targetM2).abs();
      if (err < bestErr) {
        bestErr = err;
        best = f;
      }
    }
    return best;
  }

  /// The service an existing run incident to [nodeId] carries (so a main pulled
  /// out of a node inherits its service), or null if the node has no run yet.
  ServiceType? _serviceOf(String nodeId) {
    for (final e in state.network.edges) {
      if (e.fromId == nodeId || e.toId == nodeId) return e.service;
    }
    return null;
  }

  /// Pull a NEW run OUT of an existing node [fromId] to [world] (sheet/world px)
  /// — the way mains are laid: place a riser/fitting, then drag a line out of it.
  /// The far end SNAPS to an existing node within [snapRadius], else TAPS into a
  /// nearby run (splitting it at the nearest point), else becomes a fresh
  /// junction node. The run carries [service] (explicit), else the source node's
  /// existing run service, else the active draw service. Records one undo step.
  /// Returns the new edge id, or null if it would be zero-length / invalid.
  String? drawRunFromNode(
    String fromId,
    Offset world, {
    ServiceType? service,
    double snapRadius = 12,
  }) {
    final from = state.network.nodeById(fromId);
    if (from == null) return null;
    final sheetId = from.sheetId;
    final floorIndex = from.floorIndex;
    final svc = service ?? _serviceOf(fromId) ?? state.service;

    final nodes = [...state.network.nodes];
    final edges = [...state.network.edges];
    final farId = _resolveDrawEndpoint(
        nodes, edges, sheetId, floorIndex, world, snapRadius);
    if (farId == fromId) return null; // collapsed onto the source — nothing laid

    final edgeId = _id('e');
    edges.add(NetEdge(id: edgeId, fromId: fromId, toId: farId, service: svc));
    _commit(Network(nodes: nodes, edges: edges));
    return edgeId;
  }

  /// Resolve a drawn run's far endpoint to a node id, MUTATING [nodes]/[edges]:
  /// snap to an existing node, else split the nearest run at the projection (the
  /// new junction), else append a fresh junction node at [world].
  String _resolveDrawEndpoint(
    List<NetNode> nodes,
    List<NetEdge> edges,
    String sheetId,
    int floorIndex,
    Offset world,
    double snapRadius,
  ) {
    // 1) snap to an existing node on this floor.
    final snapped = _snap(nodes, sheetId, floorIndex, world, snapRadius);
    if (snapped != null) return snapped;

    // 2) tap into the nearest run on this floor (split it at the projection).
    final r2 = snapRadius * snapRadius;
    NetEdge? bestEdge;
    var bestD2 = r2;
    var bestP = world;
    for (final e in edges) {
      if (e.kind == EdgeKind.riser) continue;
      final a = nodes.where((n) => n.id == e.fromId).firstOrNull;
      final b = nodes.where((n) => n.id == e.toId).firstOrNull;
      if (a == null || b == null) continue;
      if (a.sheetId != sheetId || a.floorIndex != floorIndex) continue;
      if (b.sheetId != sheetId || b.floorIndex != floorIndex) continue;
      final p =
          _closestPointOnSegment(world, Offset(a.x, a.y), Offset(b.x, b.y));
      final d2 = (p - world).distanceSquared;
      if (d2 <= bestD2) {
        bestD2 = d2;
        bestEdge = e;
        bestP = p;
      }
    }
    final e = bestEdge;
    if (e != null) {
      final a = nodes.firstWhere((n) => n.id == e.fromId);
      final b = nodes.firstWhere((n) => n.id == e.toId);
      if ((bestP - Offset(a.x, a.y)).distanceSquared <= r2) return a.id;
      if ((bestP - Offset(b.x, b.y)).distanceSquared <= r2) return b.id;
      final jId = _id('n');
      nodes.add(NetNode(
          id: jId,
          sheetId: sheetId,
          x: bestP.dx,
          y: bestP.dy,
          floorIndex: floorIndex));
      final idx = edges.indexWhere((x) => x.id == e.id);
      edges[idx] = e.copyWith(toId: jId);
      edges.add(NetEdge(
        id: _id('e'),
        fromId: jId,
        toId: e.toId,
        service: e.service,
        kind: e.kind,
        pipeProduct: e.pipeProduct,
        ductProduct: e.ductProduct,
      ));
      return jId;
    }

    // 3) a fresh junction node at the release point.
    final id = _id('n');
    nodes.add(NetNode(
        id: id, sheetId: sheetId, x: world.dx, y: world.dy, floorIndex: floorIndex));
    return id;
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
    if (targetId == null) {
      // No node to merge onto. If the dragged node is FREE (no edges) — e.g. a
      // fixture just dropped from the palette — and it landed near a mainline
      // pipe, TAP it in: draw a new branch pipe from the fixture to the main
      // (splitting the main at the nearest point). The fixture itself stays put.
      _tapFreeNodeIntoNearestEdge(dragged, snapRadiusWorld);
      return;
    }

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

  /// Closest point on segment a→b to p (all in world px).
  static Offset _closestPointOnSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.distanceSquared;
    if (len2 == 0) return a;
    final t = (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / len2)
        .clamp(0.0, 1.0);
    return a + ab * t;
  }

  /// If [dragged] has NO edges and lies within [radiusWorld] of a horizontal RUN
  /// on the same sheet/floor, connect it: split that run at the nearest point
  /// (or reuse an endpoint if very close) and add a new branch pipe from the
  /// dragged node to that junction, carrying the main's service. One undo step.
  void _tapFreeNodeIntoNearestEdge(NetNode dragged, double radiusWorld) {
    final net = state.network;
    final connected =
        net.edges.any((e) => e.fromId == dragged.id || e.toId == dragged.id);
    if (connected) return; // only auto-connect a free node

    NetEdge? bestEdge;
    var bestD2 = radiusWorld * radiusWorld;
    var bestP = Offset.zero;
    final dp = Offset(dragged.x, dragged.y);
    for (final e in net.edges) {
      if (e.kind == EdgeKind.riser) continue; // tap onto horizontal runs only
      final a = net.nodeById(e.fromId);
      final b = net.nodeById(e.toId);
      if (a == null || b == null) continue;
      if (a.sheetId != dragged.sheetId || a.floorIndex != dragged.floorIndex) {
        continue;
      }
      if (b.sheetId != dragged.sheetId || b.floorIndex != dragged.floorIndex) {
        continue;
      }
      final p = _closestPointOnSegment(
          dp, Offset(a.x, a.y), Offset(b.x, b.y));
      final d2 = (p - dp).distanceSquared;
      if (d2 <= bestD2) {
        bestD2 = d2;
        bestEdge = e;
        bestP = p;
      }
    }
    final e = bestEdge;
    if (e == null) return;
    final a = net.nodeById(e.fromId)!;
    final b = net.nodeById(e.toId)!;
    final snap2 = radiusWorld * radiusWorld;

    final newNodes = [...net.nodes];
    final newEdges = <NetEdge>[];
    final String junctionId;
    if ((bestP - Offset(a.x, a.y)).distanceSquared <= snap2) {
      junctionId = a.id; // near the start node — connect straight to it
      newEdges.addAll(net.edges);
    } else if ((bestP - Offset(b.x, b.y)).distanceSquared <= snap2) {
      junctionId = b.id; // near the end node
      newEdges.addAll(net.edges);
    } else {
      // Split the main at the projection: a→J (keeps the edge's material), J→b.
      junctionId = _id('n');
      newNodes.add(NetNode(
        id: junctionId,
        sheetId: dragged.sheetId,
        x: bestP.dx,
        y: bestP.dy,
        floorIndex: dragged.floorIndex,
      ));
      for (final edge in net.edges) {
        if (edge.id == e.id) {
          newEdges.add(e.copyWith(toId: junctionId));
          newEdges.add(NetEdge(
            id: _id('e'),
            fromId: junctionId,
            toId: e.toId,
            service: e.service,
            kind: e.kind,
            pipeProduct: e.pipeProduct,
            ductProduct: e.ductProduct,
          ));
        } else {
          newEdges.add(edge);
        }
      }
    }
    // The new branch pipe from the fixture to the main, carrying its service.
    newEdges.add(NetEdge(
      id: _id('e'),
      fromId: dragged.id,
      toId: junctionId,
      service: e.service,
    ));
    _commit(Network(nodes: newNodes, edges: newEdges));
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
        mountHeight: n.mountHeight,
        component: n.component,
        tankCapacityLitres: n.tankCapacityLitres,
        electricalLoadW: n.electricalLoadW,
        faceWidthMm: n.faceWidthMm,
        faceHeightMm: n.faceHeightMm,
        fittingType: n.fittingType,
        fixture: n.fixture,
        airflow: n.airflow,
        customFixtureId: n.customFixtureId,
        roofAreaM2: n.roofAreaM2,
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

  // ── Multi-select copy / paste / delete ──────────────────────────────────────

  /// Copy the [nodeIds]/[edgeIds] selection onto the in-memory clipboard. The
  /// node set is the chosen nodes PLUS both endpoints of every chosen edge; only
  /// edges whose BOTH endpoints fall in that node set are kept (danglers — and a
  /// riser with only one endpoint selected — are dropped). Deep value-copies are
  /// stored so later edits don't mutate the clipboard. No-op (clears nothing)
  /// when the selection has no nodes/edges to copy.
  void copySelection(Set<String> nodeIds, Set<String> edgeIds) {
    final net = state.network;
    // The node set: the chosen nodes PLUS both endpoints of each chosen edge.
    final keptIds = <String>{...nodeIds};
    for (final e in net.edges) {
      if (!edgeIds.contains(e.id)) continue;
      keptIds.add(e.fromId);
      keptIds.add(e.toId);
    }
    // Keep only chosen edges whose BOTH endpoints are in the node set (drop
    // danglers; a riser counts only when both its endpoints are selected).
    final keptEdges = <NetEdge>[
      for (final e in net.edges)
        if (edgeIds.contains(e.id) &&
            keptIds.contains(e.fromId) &&
            keptIds.contains(e.toId))
          e.copyWith(),
    ];
    final keptNodes = <NetNode>[
      for (final n in net.nodes)
        if (keptIds.contains(n.id)) n.copyWith(),
    ];
    if (keptNodes.isEmpty) {
      _clipboard = null;
      return;
    }
    _clipboard = _Clipboard(keptNodes, keptEdges);
  }

  /// Paste the clipboard onto [sheetId]/[floorIndex], offset by [offsetWorld],
  /// with fresh ids (mirrors [duplicateFloor]'s clone-map pattern). Every
  /// NetNode field is carried via copyWith. Records ONE undo step. Sets the new
  /// ids as the multi-selection and returns them (empty when nothing pasted).
  ({Set<String> nodeIds, Set<String> edgeIds}) paste({
    required String sheetId,
    required int floorIndex,
    Offset offsetWorld = const Offset(24, 24),
  }) {
    final clip = _clipboard;
    if (clip == null || clip.nodes.isEmpty) {
      return (nodeIds: <String>{}, edgeIds: <String>{});
    }
    final clones = <String, String>{}; // old node id → new node id
    final addedNodes = <NetNode>[];
    for (final n in clip.nodes) {
      final id = _id('n');
      clones[n.id] = id;
      // Build a fresh node with the new id, carrying EVERY NetNode field
      // (copyWith can't change the id, so construct directly).
      addedNodes.add(NetNode(
        id: id,
        sheetId: sheetId,
        x: n.x + offsetWorld.dx,
        y: n.y + offsetWorld.dy,
        floorIndex: floorIndex,
        role: n.role,
        elevation: n.elevation,
        mountHeight: n.mountHeight,
        component: n.component,
        tankCapacityLitres: n.tankCapacityLitres,
        electricalLoadW: n.electricalLoadW,
        faceWidthMm: n.faceWidthMm,
        faceHeightMm: n.faceHeightMm,
        fittingType: n.fittingType,
        fixture: n.fixture,
        airflow: n.airflow,
        customFixtureId: n.customFixtureId,
        roofAreaM2: n.roofAreaM2,
      ));
    }
    final addedEdges = <NetEdge>[];
    final newEdgeIds = <String>{};
    for (final e in clip.edges) {
      final from = clones[e.fromId];
      final to = clones[e.toId];
      if (from == null || to == null) continue;
      final eid = _id('e');
      newEdgeIds.add(eid);
      addedEdges.add(NetEdge(
        id: eid,
        fromId: from,
        toId: to,
        service: e.service,
        kind: e.kind,
        pipeProduct: e.pipeProduct,
        ductProduct: e.ductProduct,
        sizeOverride: e.sizeOverride,
      ));
    }
    _commit(Network(
      nodes: [...state.network.nodes, ...addedNodes],
      edges: [...state.network.edges, ...addedEdges],
    ));
    final newNodeIds = clones.values.toSet();
    ref.read(selectionProvider.notifier).setMulti(newNodeIds, newEdgeIds);
    return (nodeIds: newNodeIds, edgeIds: newEdgeIds);
  }

  /// Remove every node in [nodeIds] (and all edges touching them) PLUS every
  /// edge in [edgeIds], in ONE undo step. No-op when nothing matches.
  void deleteMany(Set<String> nodeIds, Set<String> edgeIds) {
    if (nodeIds.isEmpty && edgeIds.isEmpty) return;
    final net = state.network;
    final hasNode = net.nodes.any((n) => nodeIds.contains(n.id));
    final hasEdge = net.edges.any((e) => edgeIds.contains(e.id));
    if (!hasNode && !hasEdge) return;
    final nodes = net.nodes.where((n) => !nodeIds.contains(n.id)).toList();
    final edges = net.edges
        .where((e) =>
            !edgeIds.contains(e.id) &&
            !nodeIds.contains(e.fromId) &&
            !nodeIds.contains(e.toId))
        .toList();
    _commit(Network(nodes: nodes, edges: edges));
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
