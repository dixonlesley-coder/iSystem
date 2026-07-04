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

import '../ui/canvas/canvas_grid.dart' show nearestGridIntersection;
import 'annotation_store.dart' show RoomArea;
import 'history_store.dart';
import 'selection_store.dart';

/// Active canvas tool.
enum DrawTool { select, drawRun, drawRiser }

/// The outcome of a [NetworkController.placeRiser] attempt, so the UI can
/// confirm or explain rather than silently no-op (C6). [up] connected to the
/// floor ABOVE (the normal case); [down] connected DOWNWARD from the top floor
/// (roof-plan downfeed work, where there is no floor above); [none] means the
/// building has a single floor, so a riser has no adjacent floor to span.
enum RiserPlacement { up, down, none }

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

  /// True between a [pushUndoSnapshot] (drag start) and the next commit: the
  /// pre-drag network is ALREADY on the undo stack + global timeline, so the
  /// commit that ENDS the drag ([_commitDragEnd] — the snap/merge or tap-in)
  /// must replace the working state without pushing a second snapshot — one
  /// drag = one undo step. Any ordinary [_commit] consumes the flag (its own
  /// snapshot push stands alone), so a drag that ends without a merge never
  /// bleeds into the next edit.
  bool _dragSnapshotPending = false;

  @override
  DrawingState build() => const DrawingState();

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Whether the clipboard holds something to paste.
  bool get hasClipboard => _clipboard != null && _clipboard!.nodes.isNotEmpty;

  String _id(String prefix) => '$prefix${_seq++}';

  void _commit(Network next, {Offset? pendingPoint}) {
    _dragSnapshotPending = false; // a normal commit stands on its own snapshot
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

  /// Commit [next] as the END of a drag. When [pushUndoSnapshot] began the
  /// drag (the pre-drag network is already on the undo stack + timeline) the
  /// state is replaced WITHOUT pushing a second snapshot or timeline entry —
  /// so the whole drag-and-snap is ONE undo step back to the pre-drag network.
  /// A caller that never snapshotted (programmatic use) falls back to a full
  /// [_commit] so the change stays safely undoable.
  void _commitDragEnd(Network next) {
    if (!_dragSnapshotPending) {
      _commit(next);
      return;
    }
    _dragSnapshotPending = false;
    state = DrawingState(
      network: next,
      service: state.service,
      tool: state.tool,
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

  /// Snap to the NEAREST existing node on [sheetId]/[floorIndex] within
  /// [snapRadius] (world px), or return null if none. Adds nothing. Nearest (not
  /// first-in-list) so a drop/draw adopts the node the on-canvas snap ring
  /// highlights — the ring's promise stays honest when two nodes sit inside the
  /// radius (the ring paints the nearest).
  String? _snap(
    List<NetNode> nodes,
    String sheetId,
    int floorIndex,
    Offset p,
    double snapRadius,
  ) {
    final r2 = snapRadius * snapRadius;
    String? best;
    var bestD2 = r2;
    for (final n in nodes) {
      if (n.sheetId != sheetId || n.floorIndex != floorIndex) continue;
      final dx = n.x - p.dx;
      final dy = n.y - p.dy;
      final d2 = dx * dx + dy * dy;
      if (d2 <= bestD2) {
        bestD2 = d2;
        best = n.id;
      }
    }
    return best;
  }

  /// Place the next point of a run. First call sets the pending start; the
  /// second creates the segment and chains. Each endpoint resolves through the
  /// SHARED [_resolveDrawEndpoint] (C1): it snaps to a nearby existing node
  /// (node hit wins), else TEES into a nearby run EDGE (splitting it at the
  /// projection so the branch's demand actually joins the network), else drops
  /// a fresh junction — so ending a run on an existing main connects instead of
  /// silently building a disconnected crossing. Byte-identical when both clicks
  /// land away from any edge (the split path never fires ⇒ fresh nodes as
  /// before).
  void placeRunPoint(
    String sheetId,
    int floorIndex,
    Offset world, {
    double snapRadius = 12,
    double? endSnapRadius,
    bool gridSnap = false,
    double? gridMetersPerPixel,
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
    final edges = [...state.network.edges];
    // The START always resolves at the normal [snapRadius] so it connects to the
    // network; only the END honours [endSnapRadius] (the smart-input typed-length
    // path passes 0 so an EXACT length lands precisely, but the start must still
    // tee/adopt — else the run silently disconnects at its source).
    final aId = _resolveDrawEndpoint(nodes, edges, sheetId, floorIndex,
        state.pendingPoint!, snapRadius, state.service,
        gridSnap: gridSnap, gridMetersPerPixel: gridMetersPerPixel);
    final bId = _resolveDrawEndpoint(nodes, edges, sheetId, floorIndex, world,
        endSnapRadius ?? snapRadius, state.service,
        gridSnap: gridSnap, gridMetersPerPixel: gridMetersPerPixel);
    if (aId == bId) {
      // zero-length / same node — just advance the pending point. Any split the
      // resolve did was on a LOCAL copy; discarding it leaves state untouched.
      state = DrawingState(
        network: state.network,
        service: state.service,
        tool: state.tool,
        pendingPoint: world,
      );
      return;
    }
    edges.add(NetEdge(id: _id('e'), fromId: aId, toId: bId, service: state.service));
    _commit(
      Network(nodes: nodes, edges: edges),
      pendingPoint: world, // chain from here
    );
  }

  /// Drop a riser at [world] spanning to an ADJACENT floor. Normally connects to
  /// the floor ABOVE ([RiserPlacement.up]); on the TOP floor (no floor above)
  /// it connects DOWNWARD to the floor below instead ([RiserPlacement.down]) —
  /// so an engineer on the roof plan, where downfeed work happens, can still
  /// draw a riser rather than getting a silent no-op (C6). Returns which way it
  /// went, or [RiserPlacement.none] when the building has a single floor (no
  /// adjacent floor to span) so the UI can fire a status message. The riser's
  /// length is the §10 elevation delta, never a pixel distance.
  RiserPlacement placeRiser(
    String sheetId,
    int floorIndex,
    Offset world,
    int levelCount, {
    double snapRadius = 12,
  }) {
    if (state.tool != DrawTool.drawRiser) return RiserPlacement.none;

    // Prefer spanning up; fall back to down on the top floor. A single-floor
    // building has neither, so there is nothing to draw.
    final RiserPlacement result;
    final int otherFloor;
    if (floorIndex + 1 < levelCount) {
      result = RiserPlacement.up;
      otherFloor = floorIndex + 1;
    } else if (floorIndex - 1 >= 0) {
      result = RiserPlacement.down;
      otherFloor = floorIndex - 1;
    } else {
      return RiserPlacement.none;
    }

    final nodes = [...state.network.nodes];
    final thisSnap = _snap(nodes, sheetId, floorIndex, world, snapRadius);
    final String thisId;
    if (thisSnap != null) {
      thisId = thisSnap;
    } else {
      thisId = _id('n');
      nodes.add(NetNode(
          id: thisId, sheetId: sheetId, x: world.dx, y: world.dy, floorIndex: floorIndex));
    }
    final otherId = _id('n');
    nodes.add(NetNode(
        id: otherId, sheetId: sheetId, x: world.dx, y: world.dy, floorIndex: otherFloor));
    final edge = NetEdge(
      id: _id('e'),
      fromId: thisId,
      toId: otherId,
      service: state.service,
      kind: EdgeKind.riser,
    );
    _commit(Network(nodes: nodes, edges: [...state.network.edges, edge]));
    return result;
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

  /// Connect two EXISTING nodes with a riser edge of [service] — used by the
  /// single-line to COMMIT an inferred vertical (the engineer hasn't routed it,
  /// the SLD suggested it, one click makes it real). No new nodes; the riser's
  /// length is the §10 elevation delta of the two nodes (via `edgeLength`), so
  /// it sizes exactly like a drawn riser. No-op if either node is missing, they
  /// share a floor, or an edge already joins them. Returns the new edge id (or
  /// null), records one undo step.
  String? connectRiser(String fromId, String toId, ServiceType service) {
    final a = state.network.nodeById(fromId);
    final b = state.network.nodeById(toId);
    if (a == null || b == null || a.floorIndex == b.floorIndex) return null;
    final exists = state.network.edges.any((e) =>
        (e.fromId == fromId && e.toId == toId) ||
        (e.fromId == toId && e.toId == fromId));
    if (exists) return null;
    final edgeId = _id('e');
    _commit(Network(
      nodes: state.network.nodes,
      edges: [
        ...state.network.edges,
        NetEdge(
          id: edgeId,
          fromId: fromId,
          toId: toId,
          service: service,
          kind: EdgeKind.riser,
        ),
      ],
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

  /// Remap node `floorIndex` after the building floor STACK changed, in ONE
  /// undo step, so drawn work is never left referencing a floor that no longer
  /// exists — which would either crash the always-on solve (pre-clamp) or
  /// silently re-elevate a node (§10 lengths rewritten under the engineer's
  /// feet). Called by [ProjectController.setFloors]/[removeFloor].
  ///
  /// [levelCount] is the NEW floor count. When [removedIndex] is non-null a
  /// floor at that index was DELETED: nodes ABOVE it drop one index (so they
  /// stay on their own physical floor — their §10 elevation is preserved),
  /// nodes ON the removed floor rehome to the floor now occupying that slot
  /// (clamped to the top), nodes below are untouched. When [removedIndex] is
  /// null the stack was REPLACED wholesale (e.g. a template): every node's
  /// `floorIndex` is simply CLAMPED into `[0, levelCount)` — a node above the
  /// new top drops to the new top floor; a stack that only grew leaves
  /// everything unchanged.
  ///
  /// No-op — changes nothing, byte-identical — when no node's `floorIndex`
  /// actually changes (an empty network, or a stack that only grew).
  ///
  /// When [record] is true (the default, for a direct/programmatic call) the
  /// change is committed as its own [UndoDomain.network] undo step. When false —
  /// as [ProjectController.setFloors]/[removeFloor] call it — the network is
  /// changed WITHOUT recording, because the compound floor-stack edit already
  /// captured the pre-change network in ONE [UndoDomain.structural] entry that
  /// reverts the floors AND the nodes together.
  void remapNodesForFloorChange({
    required int levelCount,
    int? removedIndex,
    bool record = true,
  }) {
    if (levelCount < 1) return;
    final maxIndex = levelCount - 1;
    var changed = false;
    final nodes = <NetNode>[];
    for (final n in state.network.nodes) {
      var fi = n.floorIndex;
      // A node above a removed floor shifts down one index to keep its own
      // physical floor; a node on/below the removed floor keeps its index.
      if (removedIndex != null && fi > removedIndex) fi -= 1;
      // Clamp into the new range (nodes on/above a removed top, or a wholesale
      // shrink).
      if (fi < 0) fi = 0;
      if (fi > maxIndex) fi = maxIndex;
      if (fi != n.floorIndex) {
        changed = true;
        nodes.add(n.copyWith(floorIndex: fi));
      } else {
        nodes.add(n);
      }
    }
    if (!changed) return;
    final next = Network(nodes: nodes, edges: state.network.edges);
    record ? _commit(next) : _setNetworkNoRecord(next);
  }

  /// Shift every node on [sheetId] by [floorDelta] floors, in ONE undo step —
  /// called when that sheet is re-mapped to a different building floor
  /// ([SheetsController.setSheetFloor]) so the work drawn on it MOVES WITH the
  /// mapping instead of silently vanishing (the canvas overlays filter on BOTH
  /// sheetId AND floorIndex, so a frozen floorIndex left behind hides
  /// everything drawn there while it keeps feeding sizing at the old elevation).
  ///
  /// A riser drawn on the plan has BOTH endpoints on this sheet, so the whole
  /// vertical shifts together and its §10 elevation-delta length is preserved.
  /// (A riser whose two endpoints live on DIFFERENT sheets — rare — has only
  /// this sheet's endpoint shifted, which changes its span: the honest
  /// consequence of moving one of its floors.) Results are clamped into
  /// `[0, levelCount)`, so a remap toward the top never leaves a node
  /// referencing a missing floor; remapping a floor-spanning riser ONTO the top
  /// floor collapses it (its upper endpoint has nowhere above to go).
  ///
  /// No-op — changes nothing, byte-identical — when [floorDelta] is 0 or no
  /// node lives on [sheetId].
  ///
  /// When [record] is true (the default) the change is committed as its own
  /// [UndoDomain.network] step; when false — as [SheetsController.setSheetFloor]
  /// calls it — the network is changed WITHOUT recording, because the compound
  /// mapping edit already captured the pre-change network in ONE
  /// [UndoDomain.structural] entry reverting the mapping AND the nodes together.
  void remapSheetFloor(
    String sheetId,
    int floorDelta, {
    required int levelCount,
    bool record = true,
  }) {
    if (floorDelta == 0 || levelCount < 1) return;
    final maxIndex = levelCount - 1;
    var changed = false;
    final nodes = <NetNode>[];
    for (final n in state.network.nodes) {
      if (n.sheetId != sheetId) {
        nodes.add(n);
        continue;
      }
      var fi = n.floorIndex + floorDelta;
      if (fi < 0) fi = 0;
      if (fi > maxIndex) fi = maxIndex;
      if (fi != n.floorIndex) {
        changed = true;
        nodes.add(n.copyWith(floorIndex: fi));
      } else {
        nodes.add(n);
      }
    }
    if (!changed) return;
    final next = Network(nodes: nodes, edges: state.network.edges);
    record ? _commit(next) : _setNetworkNoRecord(next);
  }

  /// Drop every drawn node whose [sheetId] is NOT in [liveSheetIds] (and every
  /// edge touching a dropped node), in ONE undo step — the active fix on the
  /// explicit Replace-all import path (A5). When Import REPLACES the sheet list,
  /// nodes drawn on the now-gone sheets are ORPHANED: they no longer render, but
  /// still pad the BOM / pressures / reports invisibly. (P3 SURFACES such
  /// orphans as a critical Design Issue; this is the active prune on the replace
  /// path.) [liveSheetIds] is the post-replace live sheet set — an empty set
  /// therefore prunes every node (a replace with no sheets), which is correct.
  ///
  /// No-op — records nothing, byte-identical — when every node is already on a
  /// live sheet (including an empty network).
  void pruneNodesNotOnSheets(Set<String> liveSheetIds) {
    final net = state.network;
    final orphans = <String>{
      for (final n in net.nodes)
        if (!liveSheetIds.contains(n.sheetId)) n.id,
    };
    if (orphans.isEmpty) return;
    final nodes = net.nodes.where((n) => !orphans.contains(n.id)).toList();
    final edges = net.edges
        .where((e) =>
            !orphans.contains(e.fromId) && !orphans.contains(e.toId))
        .toList();
    _commit(Network(nodes: nodes, edges: edges));
  }

  void undo() {
    if (_undo.isEmpty) return;
    _dragSnapshotPending = false;
    final current = state.network;
    final previous = _undo.removeLast();
    _redo.add(current);
    // C8: while chaining a run, undoing the last segment must KEEP the rubber
    // band so drawing continues — re-anchor the pending point at the segment's
    // OTHER endpoint (the prior chain anchor) instead of dropping the chain.
    final pending = (state.tool == DrawTool.drawRun && state.pendingPoint != null)
        ? _chainAnchorAfterUndo(current, previous, state.pendingPoint!)
        : null;
    state = DrawingState(
      network: previous,
      service: state.service,
      tool: state.tool,
      pendingPoint: pending,
    );
  }

  /// The chain anchor to re-pend after undoing a drawn segment: find the tip
  /// node nearest the live [pending] point in [current], then the just-undone
  /// run edge (present in [current] but not [previous]) touching it, and return
  /// its OTHER endpoint's position (read from [current], where it still exists).
  /// Null when no such segment is found — undoing the only/first segment ends
  /// the chain (nothing to anchor to).
  Offset? _chainAnchorAfterUndo(
      Network current, Network previous, Offset pending) {
    NetNode? tip;
    var best = double.infinity;
    for (final n in current.nodes) {
      final dx = n.x - pending.dx;
      final dy = n.y - pending.dy;
      final d2 = dx * dx + dy * dy;
      if (d2 < best) {
        best = d2;
        tip = n;
      }
    }
    if (tip == null) return null;
    final prevEdgeIds = {for (final e in previous.edges) e.id};
    for (final e in current.edges) {
      if (e.kind != EdgeKind.run || prevEdgeIds.contains(e.id)) continue;
      final String? otherId = e.fromId == tip.id
          ? e.toId
          : (e.toId == tip.id ? e.fromId : null);
      if (otherId == null) continue;
      final anchor = current.nodeById(otherId);
      if (anchor != null) return Offset(anchor.x, anchor.y);
    }
    return null;
  }

  void redo() {
    if (_redo.isEmpty) return;
    _dragSnapshotPending = false;
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
    _replaceNode(_applyFixture(node, fixture));
  }

  /// A copy of [node] with the built-in plumbing [fixture] set (marking it a
  /// fixture terminal, clearing any custom fixture — the two are mutually
  /// exclusive), or — when [fixture] is null — a copy with BOTH the built-in and
  /// the custom fixture cleared (the fresh construction is how we null `fixture`
  /// / `customFixtureId`; every other field is preserved). Shared by the single
  /// [setNodeFixture], the batch [setNodesFixture] and the merge-on-drop path.
  NetNode _applyFixture(NetNode node, PlumbingFixture? fixture) {
    if (fixture == null) {
      return NetNode(
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
      );
    }
    return node.copyWith(
      role: NodeRole.fixture,
      fixture: fixture,
      clearCustomFixtureId: true,
    );
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
    if (node.faceWidthMm == widthMm && node.faceHeightMm == heightMm) return;
    _replaceNode(_applyFace(node, widthMm, heightMm));
  }

  /// A copy of [node] with the grille/diffuser FACE size set, or cleared when
  /// either dimension is null. Shared by [setNodeFace] and [setNodesFaceSize].
  NetNode _applyFace(NetNode node, double? widthMm, double? heightMm) =>
      (widthMm == null || heightMm == null)
          ? node.copyWith(clearFace: true)
          : node.copyWith(faceWidthMm: widthMm, faceHeightMm: heightMm);

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

  // ── E1: batch property setters (one undo step, mirroring deleteMany) ────────
  // Each plural setter mirrors its single-id sibling but applies to EVERY id in
  // one commit, so a multi-selection edited from the inspector / context menu is
  // ONE undo step — and the selection is left untouched (the setter never
  // touches it), so a batch edit doesn't collapse the selection back to one.

  /// Set (or clear, with null) the manual nominal-size override on every edge in
  /// [ids] in ONE undo step. No-op when nothing actually changes.
  void setEdgesSizeOverride(Set<String> ids, Diameter? size) {
    if (ids.isEmpty) return;
    var changed = false;
    final edges = <NetEdge>[];
    for (final e in state.network.edges) {
      if (ids.contains(e.id) && e.sizeOverride?.meters != size?.meters) {
        changed = true;
        edges.add(size == null
            ? e.copyWith(clearSizeOverride: true)
            : e.copyWith(sizeOverride: size));
      } else {
        edges.add(e);
      }
    }
    if (changed) _commit(Network(nodes: state.network.nodes, edges: edges));
  }

  /// Set (or clear, with null) the pipe product on every edge in [ids], one
  /// undo step. No-op when nothing changes.
  void setEdgesPipeProduct(Set<String> ids, PipeProduct? product) {
    if (ids.isEmpty) return;
    var changed = false;
    final edges = <NetEdge>[];
    for (final e in state.network.edges) {
      if (ids.contains(e.id) && e.pipeProduct != product) {
        changed = true;
        edges.add(product == null
            ? e.copyWith(clearPipeProduct: true)
            : e.copyWith(pipeProduct: product));
      } else {
        edges.add(e);
      }
    }
    if (changed) _commit(Network(nodes: state.network.nodes, edges: edges));
  }

  /// Set (or clear, with null) the duct product on every edge in [ids], one undo
  /// step. No-op when nothing changes.
  void setEdgesDuctProduct(Set<String> ids, DuctProduct? product) {
    if (ids.isEmpty) return;
    var changed = false;
    final edges = <NetEdge>[];
    for (final e in state.network.edges) {
      if (ids.contains(e.id) && e.ductProduct != product) {
        changed = true;
        edges.add(product == null
            ? e.copyWith(clearDuctProduct: true)
            : e.copyWith(ductProduct: product));
      } else {
        edges.add(e);
      }
    }
    if (changed) _commit(Network(nodes: state.network.nodes, edges: edges));
  }

  /// Re-service every edge in [ids] in ONE undo step. No-op when nothing changes.
  void setEdgesService(Set<String> ids, ServiceType service) {
    if (ids.isEmpty) return;
    var changed = false;
    final edges = <NetEdge>[];
    for (final e in state.network.edges) {
      if (ids.contains(e.id) && e.service != service) {
        changed = true;
        edges.add(e.copyWith(service: service));
      } else {
        edges.add(e);
      }
    }
    if (changed) _commit(Network(nodes: state.network.nodes, edges: edges));
  }

  /// Assign (or clear, with null) the built-in plumbing fixture on every node in
  /// [ids] in ONE undo step (mirrors [setNodeFixture]). No-op when no id matches.
  void setNodesFixture(Set<String> ids, PlumbingFixture? fixture) {
    if (ids.isEmpty) return;
    var changed = false;
    final nodes = <NetNode>[];
    for (final n in state.network.nodes) {
      // Value-guard (like the sibling batch setters) so re-picking the fixture a
      // node already carries records no phantom undo step. A node is unchanged
      // when its fixture matches, it holds no custom-fixture id to clear, and
      // (for a real fixture) its role is already `fixture`.
      final already = ids.contains(n.id) &&
          n.fixture == fixture &&
          n.customFixtureId == null &&
          (fixture == null || n.role == NodeRole.fixture);
      if (ids.contains(n.id) && !already) {
        changed = true;
        nodes.add(_applyFixture(n, fixture));
      } else {
        nodes.add(n);
      }
    }
    if (changed) _commit(Network(nodes: nodes, edges: state.network.edges));
  }

  /// Set (or clear, with a null dimension) the grille/diffuser FACE size on every
  /// node in [ids] in ONE undo step (mirrors [setNodeFace]). No-op when nothing
  /// changes.
  void setNodesFaceSize(Set<String> ids, double? widthMm, double? heightMm) {
    if (ids.isEmpty) return;
    var changed = false;
    final nodes = <NetNode>[];
    for (final n in state.network.nodes) {
      if (ids.contains(n.id) &&
          (n.faceWidthMm != widthMm || n.faceHeightMm != heightMm)) {
        changed = true;
        nodes.add(_applyFace(n, widthMm, heightMm));
      } else {
        nodes.add(n);
      }
    }
    if (changed) _commit(Network(nodes: nodes, edges: state.network.edges));
  }

  /// Create a PARALLEL run offset from edge [id] by [distancePixels], on the
  /// [leftSide] of the edge's `from`→`to` heading (left = the heading rotated a
  /// quarter-turn anticlockwise on screen). Adds two nodes + one run edge of the
  /// same service in a single undo step — the simpler-than-AutoCAD OFFSET: one
  /// action, no separate trim/extend. No-op for a riser, a missing/zero-length
  /// edge, or a non-positive distance. The UI converts a real distance to pixels
  /// via the sheet calibration, so the controller stays calibration-agnostic
  /// (like [placeRunPoint]). Returns the new edge id, or null on a no-op.
  String? offsetEdgeParallel(
    String id,
    double distancePixels, {
    required bool leftSide,
  }) {
    if (distancePixels <= 0) return null;
    final edge = state.network.edgeById(id);
    if (edge == null || edge.kind != EdgeKind.run) return null;
    final a = state.network.nodeById(edge.fromId);
    final b = state.network.nodeById(edge.toId);
    if (a == null || b == null) return null;
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1e-6) return null;

    // Perpendicular unit vector: left of the a→b heading is (dy, -dx)/len on a
    // y-down screen. Right flips the sign.
    final sign = leftSide ? 1.0 : -1.0;
    final ox = (dy / len) * distancePixels * sign;
    final oy = (-dx / len) * distancePixels * sign;

    final na = NetNode(
      id: _id('n'),
      sheetId: a.sheetId,
      x: a.x + ox,
      y: a.y + oy,
      floorIndex: a.floorIndex,
    );
    final nb = NetNode(
      id: _id('n'),
      sheetId: b.sheetId,
      x: b.x + ox,
      y: b.y + oy,
      floorIndex: b.floorIndex,
    );
    final newEdge = NetEdge(
      id: _id('e'),
      fromId: na.id,
      toId: nb.id,
      service: edge.service,
    );
    _commit(Network(
      nodes: [...state.network.nodes, na, nb],
      edges: [...state.network.edges, newEdge],
    ));
    return newEdge.id;
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

  // ── C2: merge-on-drop (adopt a node / tee into an edge, never a twin) ───────

  /// The element a palette drop at [world] on [sheetId]/[floorIndex] should
  /// merge with, within [radius] world px: a NODE (id) takes precedence over an
  /// EDGE (id + the split point on it). Both null ⇒ nothing in range (drop
  /// free). Runs only — risers are not teed into (a riser is a vertical span).
  ({String? nodeId, String? edgeId, Offset? split}) _dropTarget(
      String sheetId, int floorIndex, Offset world, double radius) {
    final nodeId = _snap(state.network.nodes, sheetId, floorIndex, world, radius);
    if (nodeId != null) {
      return (nodeId: nodeId, edgeId: null, split: null);
    }
    final r2 = radius * radius;
    NetEdge? bestEdge;
    var bestD2 = r2;
    var bestP = world;
    for (final e in state.network.edges) {
      if (e.kind == EdgeKind.riser) continue;
      final a = state.network.nodeById(e.fromId);
      final b = state.network.nodeById(e.toId);
      if (a == null || b == null) continue;
      if (a.sheetId != sheetId || a.floorIndex != floorIndex) continue;
      if (b.sheetId != sheetId || b.floorIndex != floorIndex) continue;
      final p = _closestPointOnSegment(world, Offset(a.x, a.y), Offset(b.x, b.y));
      final d2 = (p - world).distanceSquared;
      if (d2 <= bestD2) {
        bestD2 = d2;
        bestEdge = e;
        bestP = p;
      }
    }
    if (bestEdge != null) {
      return (nodeId: null, edgeId: bestEdge.id, split: bestP);
    }
    return (nodeId: null, edgeId: null, split: null);
  }

  /// Split run [edgeId] at the point [insert] sits on, replacing the edge with
  /// two halves (a→insert, insert→b) that BOTH inherit its service / kind /
  /// pipeProduct / ductProduct / sizeOverride, and returns fresh (nodes, edges)
  /// lists with [insert] added. The caller commits.
  (List<NetNode>, List<NetEdge>) _splitEdgeInserting(
      String edgeId, NetNode insert) {
    final nodes = [...state.network.nodes, insert];
    final edges = <NetEdge>[];
    for (final e in state.network.edges) {
      if (e.id != edgeId) {
        edges.add(e);
        continue;
      }
      edges.add(e.copyWith(toId: insert.id));
      edges.add(NetEdge(
        id: _id('e'),
        fromId: insert.id,
        toId: e.toId,
        service: e.service,
        kind: e.kind,
        pipeProduct: e.pipeProduct,
        ductProduct: e.ductProduct,
        sizeOverride: e.sizeOverride,
      ));
    }
    return (nodes, edges);
  }

  /// Drop a FITTING (a bare junction) at [world], but MERGE within [snapRadius]:
  /// if a node is already there ADOPT it (no coincident twin — a bare fitting
  /// carries no payload, so the node is returned unchanged), else if it lands on
  /// a run TEE in (split it, inserting the junction), else drop a free junction.
  /// Returns the resulting node id. Records one undo step (none when adopting an
  /// existing node — there is nothing to change).
  String mergeOrAddFitting(
    String sheetId,
    int floorIndex,
    Offset world, {
    double snapRadius = 12,
  }) {
    final t = _dropTarget(sheetId, floorIndex, world, snapRadius);
    if (t.nodeId != null) return t.nodeId!; // adopt: already a node here
    if (t.edgeId != null) {
      final node = NetNode(
          id: _id('n'),
          sheetId: sheetId,
          x: t.split!.dx,
          y: t.split!.dy,
          floorIndex: floorIndex);
      final (nodes, edges) = _splitEdgeInserting(t.edgeId!, node);
      _commit(Network(nodes: nodes, edges: edges));
      return node.id;
    }
    final node = NetNode(
        id: _id('n'), sheetId: sheetId, x: world.dx, y: world.dy, floorIndex: floorIndex);
    _commit(Network(nodes: [...state.network.nodes, node], edges: state.network.edges));
    return node.id;
  }

  /// Drop a TERMINAL (a fixture node, optionally carrying [fixture]) at [world],
  /// merging within [snapRadius]: ADOPT a node already there (making it a
  /// fixture terminal — no twin), else TEE into a run (inserting the terminal
  /// inline on it), else drop a free terminal. Returns the resulting node id;
  /// records one undo step.
  String mergeOrAddTerminal(
    String sheetId,
    int floorIndex,
    Offset world, {
    PlumbingFixture? fixture,
    double snapRadius = 12,
  }) {
    final t = _dropTarget(sheetId, floorIndex, world, snapRadius);
    if (t.nodeId != null) {
      final existing = state.network.nodeById(t.nodeId!)!;
      _replaceNode(fixture != null
          ? _applyFixture(existing, fixture)
          : existing.copyWith(role: NodeRole.fixture));
      return existing.id;
    }
    NetNode terminalAt(double x, double y) => NetNode(
          id: _id('n'),
          sheetId: sheetId,
          x: x,
          y: y,
          floorIndex: floorIndex,
          role: NodeRole.fixture,
          fixture: fixture,
        );
    if (t.edgeId != null) {
      final node = terminalAt(t.split!.dx, t.split!.dy);
      final (nodes, edges) = _splitEdgeInserting(t.edgeId!, node);
      _commit(Network(nodes: nodes, edges: edges));
      return node.id;
    }
    final node = terminalAt(world.dx, world.dy);
    _commit(Network(nodes: [...state.network.nodes, node], edges: state.network.edges));
    return node.id;
  }

  /// Drop an EQUIPMENT / COMPONENT node at [world], merging within [snapRadius]:
  /// ADOPT a node already there (setting its [component] + implied role — no
  /// twin), else TEE into a run (inserting the component inline), else drop it
  /// free. Returns the resulting node id; records one undo step.
  String mergeOrAddComponent(
    String sheetId,
    int floorIndex,
    Offset world,
    NodeComponent component, {
    double snapRadius = 12,
  }) {
    final t = _dropTarget(sheetId, floorIndex, world, snapRadius);
    if (t.nodeId != null) {
      final existing = state.network.nodeById(t.nodeId!)!;
      _replaceNode(existing.copyWith(component: component, role: component.role));
      return existing.id;
    }
    NetNode componentAt(double x, double y) => NetNode(
          id: _id('n'),
          sheetId: sheetId,
          x: x,
          y: y,
          floorIndex: floorIndex,
          role: component.role,
          component: component,
        );
    if (t.edgeId != null) {
      final node = componentAt(t.split!.dx, t.split!.dy);
      final (nodes, edges) = _splitEdgeInserting(t.edgeId!, node);
      _commit(Network(nodes: nodes, edges: edges));
      return node.id;
    }
    final node = componentAt(world.dx, world.dy);
    _commit(Network(nodes: [...state.network.nodes, node], edges: state.network.edges));
    return node.id;
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

    // Idempotence (E8): drop THIS room's previously-placed supply diffusers /
    // return grilles (those inside its footprint) — and any edges touching them
    // — before re-placing, so re-running the button re-generates the terminals
    // instead of stacking a second generation atop the first (which silently
    // doubled the carried airflow). All in the SAME undo step as the placement.
    final priorIds = <String>{
      for (final node in state.network.nodes)
        if ((node.component == NodeComponent.supplyDiffuser ||
                node.component == NodeComponent.returnGrille) &&
            room.containsNode(
                node.sheetId, node.floorIndex, node.x, node.y))
          node.id,
    };
    final nodes = [
      for (final node in state.network.nodes)
        if (!priorIds.contains(node.id)) node,
    ];
    final priorEdges = [
      for (final e in state.network.edges)
        if (!priorIds.contains(e.fromId) && !priorIds.contains(e.toId)) e,
    ];
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

    _commit(Network(nodes: nodes, edges: priorEdges));
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
    bool gridSnap = false,
    double? gridMetersPerPixel,
  }) {
    final from = state.network.nodeById(fromId);
    if (from == null) return null;
    final sheetId = from.sheetId;
    final floorIndex = from.floorIndex;
    final svc = service ?? _serviceOf(fromId) ?? state.service;

    final nodes = [...state.network.nodes];
    final edges = [...state.network.edges];
    final farId = _resolveDrawEndpoint(
        nodes, edges, sheetId, floorIndex, world, snapRadius, svc,
        gridSnap: gridSnap, gridMetersPerPixel: gridMetersPerPixel);
    if (farId == fromId) return null; // collapsed onto the source — nothing laid

    final edgeId = _id('e');
    edges.add(NetEdge(id: edgeId, fromId: fromId, toId: farId, service: svc));
    _commit(Network(nodes: nodes, edges: edges));
    return edgeId;
  }

  /// Resolve a drawn run's far endpoint to a node id, MUTATING [nodes]/[edges]:
  /// snap to an existing node, else split the nearest run at the projection (the
  /// new junction), else append a fresh junction node at [world]. The tee-in
  /// (step 2) is scoped to runs of the SAME [service] — a cold-water run never
  /// silently splits a drainage pipe it happens to cross; each service is its
  /// own network.
  String _resolveDrawEndpoint(
    List<NetNode> nodes,
    List<NetEdge> edges,
    String sheetId,
    int floorIndex,
    Offset world,
    double snapRadius,
    ServiceType service, {
    bool gridSnap = false,
    double? gridMetersPerPixel,
  }) {
    // 1) snap to an existing node on this floor.
    final snapped = _snap(nodes, sheetId, floorIndex, world, snapRadius);
    if (snapped != null) return snapped;

    // 2) tap into the nearest SAME-SERVICE run on this floor (split at the
    // projection). A cross-service run is skipped — never teed into.
    final r2 = snapRadius * snapRadius;
    NetEdge? bestEdge;
    var bestD2 = r2;
    var bestP = world;
    for (final e in edges) {
      if (e.kind == EdgeKind.riser) continue;
      if (e.service != service) continue;
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
        sizeOverride: e.sizeOverride,
      ));
      return jId;
    }

    // 3) a fresh junction node at the release point — but if grid-snapping is
    // armed (the ortho/grid is on) and nothing above adopted the point, let the
    // VISIBLE metre grid attract it: drop the node on the nearest painted grid
    // intersection when that crossing lies within the SAME snap radius. This is
    // the LOWEST-precedence snap (a node hit in step 1 / a same-service tee in
    // step 2 always wins); beyond the radius the exact point stands, so mid-cell
    // drawing is never yanked to a line. Default off ⇒ byte-identical.
    var point = world;
    if (gridSnap && gridMetersPerPixel != null) {
      final g = nearestGridIntersection(world, gridMetersPerPixel);
      if ((g - world).distanceSquared <= r2) point = g;
    }
    final id = _id('n');
    nodes.add(NetNode(
        id: id, sheetId: sheetId, x: point.dx, y: point.dy, floorIndex: floorIndex));
    return id;
  }

  /// Call at the END of a node drag: if the node now lands within
  /// [snapRadiusWorld] of ANOTHER node on the same sheet/floor, MERGE the two —
  /// re-point every edge that referenced the dragged node to the target, drop
  /// the dragged node, and drop any edge that became a self-loop (zero length).
  /// This is how a dragged segment endpoint "connects/snaps to a fitting".
  /// Records one undo step (pair with [pushUndoSnapshot]/[moveNode] live drag).
  void endNodeDragWithSnap(
    String nodeId,
    double snapRadiusWorld, {
    bool gridSnap = false,
    double? gridMetersPerPixel,
  }) {
    final dragged = state.network.nodeById(nodeId);
    if (dragged == null) {
      // A drag that ends with nothing to commit must not leave the pending
      // flag armed for a later unrelated commit-path call.
      _dragSnapshotPending = false;
      return;
    }

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
      // No node to merge onto. If the dragged node landed near a mainline pipe,
      // TAP it in: split the main at the nearest point and draw a new branch
      // pipe from the dragged node to that junction (the node itself stays put).
      // This teed-in connect works for a FREE node just dropped from the palette
      // AND for an already-CONNECTED node whose endpoint is dragged onto another
      // run (C1) — the tap never targets the dragged node's own edges.
      _tapNodeIntoNearestEdge(dragged, snapRadiusWorld,
          gridSnap: gridSnap, gridMetersPerPixel: gridMetersPerPixel);
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
    _commitDragEnd(Network(nodes: nodes, edges: edges));
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

  /// If [dragged] lies within [radiusWorld] of a horizontal RUN on the same
  /// sheet/floor, connect it: split that run at the nearest point (or reuse an
  /// endpoint if very close) and add a new branch pipe from the dragged node to
  /// that junction, carrying the main's service. One undo step. Works for a FREE
  /// node (a just-dropped fixture) AND a CONNECTED node dragged onto another run
  /// (C1); the search SKIPS the dragged node's own edges so a node is never teed
  /// into a pipe it already belongs to.
  void _tapNodeIntoNearestEdge(
    NetNode dragged,
    double radiusWorld, {
    bool gridSnap = false,
    double? gridMetersPerPixel,
  }) {
    final net = state.network;

    NetEdge? bestEdge;
    var bestD2 = radiusWorld * radiusWorld;
    var bestP = Offset.zero;
    final dp = Offset(dragged.x, dragged.y);
    for (final e in net.edges) {
      if (e.kind == EdgeKind.riser) continue; // tap onto horizontal runs only
      if (e.fromId == dragged.id || e.toId == dragged.id) {
        continue; // never split the dragged node's own edge
      }
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
    if (e == null) {
      // No node to merge onto (checked by the caller) and no run to tap into —
      // the drag's LAST resort is the grid: if grid-snapping is armed and the
      // node landed within the radius of a painted grid intersection, nudge it
      // exactly onto that crossing (the magnetic-grid analogue of merge/tap, and
      // its lowest precedence). Otherwise leave the node where it fell and disarm
      // the pending snapshot. Default off ⇒ byte-identical.
      if (gridSnap && gridMetersPerPixel != null) {
        final g = nearestGridIntersection(dp, gridMetersPerPixel);
        if ((g - dp).distanceSquared <= radiusWorld * radiusWorld &&
            (g.dx != dragged.x || g.dy != dragged.y)) {
          final moved = [
            for (final n in net.nodes)
              n.id == dragged.id ? n.copyWith(x: g.dx, y: g.dy) : n,
          ];
          _commitDragEnd(Network(nodes: moved, edges: net.edges));
          return;
        }
      }
      _dragSnapshotPending = false; // no commit — disarm (see endNodeDragWithSnap)
      return;
    }
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
            sizeOverride: e.sizeOverride,
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
    _commitDragEnd(Network(nodes: newNodes, edges: newEdges));
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

  /// A fresh node with a new [id] carrying EVERY [n] field, at ([x], [y]) on
  /// [sheetId]/[floorIndex] (copyWith can't change the id, so we construct
  /// directly). Shared by [paste] / [pasteNCopies] / [duplicateFloor]-style
  /// clones so the field set can never drift between them.
  NetNode _cloneNodeAt(
    NetNode n,
    String id,
    String sheetId,
    int floorIndex,
    double x,
    double y,
  ) =>
      NetNode(
        id: id,
        sheetId: sheetId,
        x: x,
        y: y,
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
      );

  /// A fresh edge with a new [id] and remapped [fromId]/[toId], carrying [e]'s
  /// service/kind/products/sizeOverride. Shared by the clipboard clones.
  NetEdge _cloneEdge(NetEdge e, String id, String fromId, String toId) =>
      NetEdge(
        id: id,
        fromId: fromId,
        toId: toId,
        service: e.service,
        kind: e.kind,
        pipeProduct: e.pipeProduct,
        ductProduct: e.ductProduct,
        sizeOverride: e.sizeOverride,
      );

  /// Clone ONE generation of [clip] onto [sheetId]/[floorIndex] at [offset],
  /// with fresh ids (mirrors [duplicateFloor]'s clone-map pattern). Returns the
  /// new nodes/edges + their ids; the caller commits (so N copies can land in
  /// one undo step).
  ///
  /// [preserveRelativeFloor] keeps each node's floor RELATIVE to the block's
  /// lowest floor (dropped-floor + delta) instead of flattening onto
  /// [floorIndex] — so a stamped multi-floor ASSEMBLY (a shaft riser set) keeps
  /// its vertical span, and its riser edges keep a real §10 elevation-delta
  /// length. Paste keeps the default (false ⇒ flatten to the paste floor,
  /// byte-identical); a single-floor block is identical either way.
  ({
    List<NetNode> nodes,
    List<NetEdge> edges,
    Set<String> nodeIds,
    Set<String> edgeIds,
  }) _cloneClipboard(
      _Clipboard clip, String sheetId, int floorIndex, Offset offset,
      {bool preserveRelativeFloor = false}) {
    final baseFloor = preserveRelativeFloor
        ? clip.nodes
            .map((n) => n.floorIndex)
            .reduce((a, b) => a < b ? a : b)
        : 0;
    final clones = <String, String>{}; // old node id → new node id
    final nodes = <NetNode>[];
    final nodeIds = <String>{};
    for (final n in clip.nodes) {
      final id = _id('n');
      clones[n.id] = id;
      nodeIds.add(id);
      final f = preserveRelativeFloor
          ? floorIndex + (n.floorIndex - baseFloor)
          : floorIndex;
      nodes.add(_cloneNodeAt(
          n, id, sheetId, f, n.x + offset.dx, n.y + offset.dy));
    }
    final edges = <NetEdge>[];
    final edgeIds = <String>{};
    for (final e in clip.edges) {
      final from = clones[e.fromId];
      final to = clones[e.toId];
      if (from == null || to == null) continue;
      final eid = _id('e');
      edgeIds.add(eid);
      edges.add(_cloneEdge(e, eid, from, to));
    }
    return (nodes: nodes, edges: edges, nodeIds: nodeIds, edgeIds: edgeIds);
  }

  /// Paste the clipboard onto [sheetId]/[floorIndex], offset by [offsetWorld],
  /// with fresh ids. Records ONE undo step, sets the new ids as the multi-
  /// selection and returns them (empty when nothing pasted). After pasting, the
  /// clipboard is RE-BASED to the pasted generation, so a repeated Ctrl+V
  /// CASCADES (each paste steps one offset further) instead of stacking
  /// byte-identical copies invisibly atop the first (E3).
  ({Set<String> nodeIds, Set<String> edgeIds}) paste({
    required String sheetId,
    required int floorIndex,
    Offset offsetWorld = const Offset(24, 24),
  }) {
    final clip = _clipboard;
    if (clip == null || clip.nodes.isEmpty) {
      return (nodeIds: <String>{}, edgeIds: <String>{});
    }
    final gen = _cloneClipboard(clip, sheetId, floorIndex, offsetWorld);
    _commit(Network(
      nodes: [...state.network.nodes, ...gen.nodes],
      edges: [...state.network.edges, ...gen.edges],
    ));
    // Re-base: the next default paste offsets from this generation, not the
    // original — so Ctrl+V, Ctrl+V, Ctrl+V walks diagonally.
    _clipboard = _Clipboard(
      [for (final n in gen.nodes) n.copyWith()],
      [for (final e in gen.edges) e.copyWith()],
    );
    ref.read(selectionProvider.notifier).setMulti(gen.nodeIds, gen.edgeIds);
    return (nodeIds: gen.nodeIds, edgeIds: gen.edgeIds);
  }

  /// Paste [count] copies of the clipboard in ONE undo step — the "Paste N
  /// copies…" array for the 20-identical-toilets job — each copy stepped a
  /// further [spacing] from the clipboard originals (generation g at g·spacing).
  /// Sets the whole array as the multi-selection and returns every new id. No-op
  /// (empty result) when the clipboard is empty or [count] <= 0. Does NOT re-base
  /// the clipboard (the array is a one-shot from the originals).
  ({Set<String> nodeIds, Set<String> edgeIds}) pasteNCopies(
    int count,
    Offset spacing, {
    required String sheetId,
    required int floorIndex,
  }) {
    final clip = _clipboard;
    if (clip == null || clip.nodes.isEmpty || count <= 0) {
      return (nodeIds: <String>{}, edgeIds: <String>{});
    }
    final addedNodes = <NetNode>[];
    final addedEdges = <NetEdge>[];
    final allNodeIds = <String>{};
    final allEdgeIds = <String>{};
    for (var g = 1; g <= count; g++) {
      final gen = _cloneClipboard(
          clip, sheetId, floorIndex, Offset(spacing.dx * g, spacing.dy * g));
      addedNodes.addAll(gen.nodes);
      addedEdges.addAll(gen.edges);
      allNodeIds.addAll(gen.nodeIds);
      allEdgeIds.addAll(gen.edgeIds);
    }
    _commit(Network(
      nodes: [...state.network.nodes, ...addedNodes],
      edges: [...state.network.edges, ...addedEdges],
    ));
    ref.read(selectionProvider.notifier).setMulti(allNodeIds, allEdgeIds);
    return (nodeIds: allNodeIds, edgeIds: allEdgeIds);
  }

  /// Paste the clipboard CENTRED at [world] (sheet px) on [sheetId]/
  /// [floorIndex] — the "Paste here" of the canvas context menu. Computes the
  /// offset from the clipboard nodes' centroid and delegates to [paste] (one
  /// undo step, fresh ids, selection set to the pasted elements). Returns the
  /// new ids; empty when the clipboard is empty.
  ({Set<String> nodeIds, Set<String> edgeIds}) pasteAt({
    required String sheetId,
    required int floorIndex,
    required Offset world,
  }) {
    final clip = _clipboard;
    if (clip == null || clip.nodes.isEmpty) {
      return (nodeIds: <String>{}, edgeIds: <String>{});
    }
    var cx = 0.0, cy = 0.0;
    for (final n in clip.nodes) {
      cx += n.x;
      cy += n.y;
    }
    cx /= clip.nodes.length;
    cy /= clip.nodes.length;
    return paste(
      sheetId: sheetId,
      floorIndex: floorIndex,
      offsetWorld: Offset(world.dx - cx, world.dy - cy),
    );
  }

  /// Stamp a SAVED ASSEMBLY ([nodes]/[edges]) centred at [world] (sheet px) on
  /// [sheetId]/[floorIndex] — the drop of an assembly card from the palette.
  /// Mirrors [pasteAt] but seeds the clone from the passed lists instead of the
  /// clipboard (so dropping an assembly never disturbs the real copy/paste
  /// clipboard). Fresh ids, ONE undo step, sets the new elements as the multi-
  /// selection, returns their ids. No-op (empty result) when [nodes] is empty.
  ({Set<String> nodeIds, Set<String> edgeIds}) stampAssembly(
    List<NetNode> nodes,
    List<NetEdge> edges, {
    required String sheetId,
    required int floorIndex,
    required Offset world,
  }) {
    if (nodes.isEmpty) {
      return (nodeIds: <String>{}, edgeIds: <String>{});
    }
    var cx = 0.0, cy = 0.0;
    for (final n in nodes) {
      cx += n.x;
      cy += n.y;
    }
    cx /= nodes.length;
    cy /= nodes.length;
    final source = _Clipboard(nodes, edges);
    // Preserve the block's vertical span so a saved multi-floor riser set keeps
    // real elevation-delta riser lengths (a single-floor block is unaffected).
    final gen = _cloneClipboard(
        source, sheetId, floorIndex, Offset(world.dx - cx, world.dy - cy),
        preserveRelativeFloor: true);
    _commit(Network(
      nodes: [...state.network.nodes, ...gen.nodes],
      edges: [...state.network.edges, ...gen.edges],
    ));
    ref.read(selectionProvider.notifier).setMulti(gen.nodeIds, gen.edgeIds);
    return (nodeIds: gen.nodeIds, edgeIds: gen.edgeIds);
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
  /// of a drag so the whole move collapses into a single undo step. The
  /// drag-end merge/tap-in ([endNodeDragWithSnap]) then commits WITHOUT a
  /// second snapshot (see [_commitDragEnd]).
  void pushUndoSnapshot() {
    _undo.add(state.network);
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
    _dragSnapshotPending = true;
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

  /// Translate EVERY node in [nodeIds] by ([dx], [dy]) sheet/world px WITHOUT
  /// recording undo (a live GROUP drag) — pair with [pushUndoSnapshot] at drag
  /// start exactly like [moveNode], so the whole group move is ONE undo step
  /// (E2). No-op when the set is empty, the delta is zero, or nothing matches.
  void moveMany(Set<String> nodeIds, double dx, double dy) {
    if (nodeIds.isEmpty || (dx == 0 && dy == 0)) return;
    var changed = false;
    final nodes = <NetNode>[];
    for (final n in state.network.nodes) {
      if (nodeIds.contains(n.id)) {
        changed = true;
        nodes.add(n.copyWith(x: n.x + dx, y: n.y + dy));
      } else {
        nodes.add(n);
      }
    }
    if (!changed) return;
    state = DrawingState(
      network: Network(nodes: nodes, edges: state.network.edges),
      service: state.service,
      tool: state.tool,
      pendingPoint: state.pendingPoint,
    );
  }

  /// Set the network WITHOUT recording an undo step, preserving the active
  /// service/tool (pendingPoint is cleared, matching [_commit]). Used by the
  /// non-recording floor/sheet remaps and by [restoreNetwork]. The id counter
  /// (`_seq`) is untouched — these paths only re-index / restore existing nodes,
  /// never mint new ids.
  void _setNetworkNoRecord(Network net) {
    state = DrawingState(
      network: net,
      service: state.service,
      tool: state.tool,
    );
  }

  /// Restore a captured [Network] WITHOUT recording undo — the
  /// [StructuralHistoryController]'s restore path for the compound floor/sheet
  /// edits. Preserves the current service/tool (unlike [loadNetwork], it does
  /// NOT reset the local undo stacks or the id counter). Not for widgets.
  void restoreNetwork(Network net) => _setNetworkNoRecord(net);

  /// Replace the network (used when opening a saved document). Resets history
  /// and advances the id counter past any loaded ids to avoid collisions.
  void loadNetwork(Network net) {
    _undo.clear();
    _redo.clear();
    _dragSnapshotPending = false;
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
