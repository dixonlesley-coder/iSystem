import 'dart:async';
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
import '../ui/canvas/snapping.dart' show orthoElbow;
import 'annotation_store.dart' show RoomArea;
import 'history_store.dart';
import 'route_geometry.dart';
import 'schematic_layout_store.dart';
import 'selection_store.dart';
import 'sheets_store.dart';

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

  /// The sheet + floor the [pendingPoint] was placed on (B1). [pendingPoint] is
  /// a bare pixel offset that only means anything against ITS sheet's geometry;
  /// if the engineer switches the active sheet/floor mid-run, the next click
  /// would otherwise resolve this stale offset against the NEW sheet, planting a
  /// phantom junction there. [placeRunPoint] compares these to the click's
  /// sheet/floor and RESTARTS the run on the new sheet instead of committing a
  /// cross-sheet edge. Both null whenever [pendingPoint] is null.
  final String? pendingSheetId;
  final int? pendingFloorIndex;

  const DrawingState({
    this.network = const Network(),
    this.service = ServiceType.coldWater,
    this.tool = DrawTool.select,
    this.pendingPoint,
    this.pendingSheetId,
    this.pendingFloorIndex,
  });

  bool get isDrawing => tool != DrawTool.select;

  /// Whether [pendingPoint] belongs to [sheetId]/[floorIndex] — i.e. the run in
  /// progress was started on the sheet/floor the caller is now acting on. True
  /// when there is no pending run. Used to gate a cross-sheet placement (B1) and
  /// the on-canvas rubber band so neither leaks onto the wrong sheet.
  bool pendingOnSheet(String sheetId, int floorIndex) =>
      pendingPoint == null ||
      (pendingSheetId == sheetId && pendingFloorIndex == floorIndex);
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

  void _commit(Network next,
      {Offset? pendingPoint, String? pendingSheetId, int? pendingFloorIndex}) {
    // K1 safety-net: any committing edit ends a live drag session, so a missed
    // endDrag can never leave the heavy chain frozen (no-op when none is open).
    ref.read(dragSessionProvider.notifier).endDrag();
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
      // The origin only travels with a live pending point (a chained run).
      pendingSheetId: pendingPoint == null ? null : pendingSheetId,
      pendingFloorIndex: pendingPoint == null ? null : pendingFloorIndex,
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
    // K1: end the throttle session on the drag's terminal commit (final refresh).
    ref.read(dragSessionProvider.notifier).endDrag();
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

  /// E1 — whether a snap/drop may ADOPT node [node], given the services the
  /// caller is scoped away from ([avoidServices] — the hidden / locked / inert
  /// set) and, for a DRAW endpoint, the service being drawn ([drawService]).
  ///
  /// Two rules, both of which used to be missing (the snap filtered on sheet +
  /// floor only, so a cold-water run silently latched onto a duct or a drainage
  /// node — including one on a service the engineer had hidden or locked and so
  /// could neither see nor unpick):
  ///
  ///   * a node whose incident edges are ALL on an avoided service is not
  ///     adoptable — it belongs to a network the caller is not editing;
  ///   * a PLAIN junction (no component, `main` role) whose incident edges are
  ///     all a DIFFERENT service is not adoptable by a draw endpoint — each
  ///     service is its own network. Equipment / plant / fixture nodes stay
  ///     adoptable across services on purpose: a roof tank legitimately feeds
  ///     cold AND hot water, and a WC carries both its supply and its drain at
  ///     one point.
  ///
  /// A node with NO incident edge (a free fitting just dropped from the palette,
  /// the bootstrap pull point) is always adoptable — it belongs to no service
  /// yet. Both defaults off ⇒ every existing caller is byte-identical.
  bool _nodeAdoptable(
    NetNode node,
    List<NetEdge> edges, {
    Set<ServiceType> avoidServices = const {},
    ServiceType? drawService,
  }) {
    if (avoidServices.isEmpty && drawService == null) return true;
    var incident = 0;
    var allAvoided = true;
    var anyDrawService = false;
    for (final e in edges) {
      if (e.fromId != node.id && e.toId != node.id) continue;
      incident++;
      if (!avoidServices.contains(e.service)) allAvoided = false;
      if (e.service == drawService) anyDrawService = true;
    }
    if (incident == 0) return true; // bare junction — belongs to no service yet
    if (avoidServices.isNotEmpty && allAvoided) return false;
    if (drawService != null &&
        !anyDrawService &&
        node.component == null &&
        node.role == NodeRole.main) {
      return false; // a plain junction of another service — never latch onto it
    }
    return true;
  }

  /// Snap to the NEAREST existing node on [sheetId]/[floorIndex] within
  /// [snapRadius] (world px), or return null if none. Adds nothing. Nearest (not
  /// first-in-list) so a drop/draw adopts the node the on-canvas snap ring
  /// highlights — the ring's promise stays honest when two nodes sit inside the
  /// radius (the ring paints the nearest).
  ///
  /// E1 — [avoidServices] / [drawService] scope which nodes may be adopted (see
  /// [_nodeAdoptable]); [edges] is the edge list to read incidence from (the
  /// caller's working copy during a draw, else the live network). Defaults ⇒
  /// byte-identical.
  String? _snap(
    List<NetNode> nodes,
    String sheetId,
    int floorIndex,
    Offset p,
    double snapRadius, {
    List<NetEdge>? edges,
    Set<ServiceType> avoidServices = const {},
    ServiceType? drawService,
  }) {
    final r2 = snapRadius * snapRadius;
    final scoped = avoidServices.isNotEmpty || drawService != null;
    final edgeList = edges ?? state.network.edges;
    String? best;
    var bestD2 = r2;
    for (final n in nodes) {
      if (n.sheetId != sheetId || n.floorIndex != floorIndex) continue;
      final dx = n.x - p.dx;
      final dy = n.y - p.dy;
      final d2 = dx * dx + dy * dy;
      if (d2 <= bestD2) {
        if (scoped &&
            !_nodeAdoptable(n, edgeList,
                avoidServices: avoidServices, drawService: drawService)) {
          continue;
        }
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
    Offset? Function(Offset world)? underlaySnap,
    bool ortho = false,
    Set<ServiceType> avoidServices = const {},
  }) {
    if (state.tool != DrawTool.drawRun) return;
    if (state.pendingPoint == null) {
      state = DrawingState(
        network: state.network,
        service: state.service,
        tool: state.tool,
        pendingPoint: world,
        pendingSheetId: sheetId,
        pendingFloorIndex: floorIndex,
      );
      return;
    }

    // B1: the pending point belongs to the sheet/floor it was placed on. If the
    // engineer switched the active sheet (or its floor mapping) mid-run, that
    // pixel offset is meaningless here — committing an edge would resolve it
    // against THIS sheet's geometry and plant a phantom junction. Restart the
    // run at this click on the new sheet instead of drawing a cross-sheet edge.
    if (!state.pendingOnSheet(sheetId, floorIndex)) {
      state = DrawingState(
        network: state.network,
        service: state.service,
        tool: state.tool,
        pendingPoint: world,
        pendingSheetId: sheetId,
        pendingFloorIndex: floorIndex,
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
        gridSnap: gridSnap,
        gridMetersPerPixel: gridMetersPerPixel,
        underlaySnap: underlaySnap,
        avoidServices: avoidServices);
    final bId = _resolveDrawEndpoint(nodes, edges, sheetId, floorIndex, world,
        endSnapRadius ?? snapRadius, state.service,
        gridSnap: gridSnap,
        gridMetersPerPixel: gridMetersPerPixel,
        underlaySnap: underlaySnap,
        avoidServices: avoidServices);
    if (aId == bId) {
      // zero-length / same node — just advance the pending point. Any split the
      // resolve did was on a LOCAL copy; discarding it leaves state untouched.
      state = DrawingState(
        network: state.network,
        service: state.service,
        tool: state.tool,
        pendingPoint: world,
        pendingSheetId: sheetId,
        pendingFloorIndex: floorIndex,
      );
      return;
    }
    // B13: with ortho on, a snap to a node/tee/underlay candidate OFF the
    // constrained ray would tilt the segment. Instead reach it as an L — the
    // leading edge runs to a BEND on the ray, a short correcting leg closes onto
    // the target — all in this one committed edit (one undo step).
    final aNode = nodes.firstWhere((n) => n.id == aId);
    final connectTo = _autoElbowEndpoint(nodes, edges, sheetId, floorIndex,
        Offset(aNode.x, aNode.y), world, bId, state.service, ortho: ortho);
    edges.add(NetEdge(id: _id('e'), fromId: aId, toId: connectTo, service: state.service));
    _commit(
      Network(nodes: nodes, edges: edges),
      pendingPoint: world, // chain from here
      pendingSheetId: sheetId,
      pendingFloorIndex: floorIndex,
    );
  }

  /// The sheet id mapped to [floorIndex], or null when NO loaded sheet maps to
  /// that floor. The reverse of `SheetsState.floorFor` — the same lookup the
  /// Building page does to show a level's assigned plan. When [override] is
  /// given (tests / a caller that already resolved the mapping) it wins, so this
  /// never has to read the sheets store.
  String? sheetIdForFloor(
    int floorIndex,
    int levelCount, {
    String? Function(int floorIndex)? override,
  }) {
    if (override != null) return override(floorIndex);
    final sheets = ref.read(sheetsControllerProvider);
    for (final s in sheets.sheets) {
      if (sheets.floorFor(s.id, levelCount) == floorIndex) return s.id;
    }
    return null;
  }

  /// Drop a riser at [world] spanning to an ADJACENT floor. Normally connects to
  /// the floor ABOVE ([RiserPlacement.up]); on the TOP floor (no floor above)
  /// it connects DOWNWARD to the floor below instead ([RiserPlacement.down]) —
  /// so an engineer on the roof plan, where downfeed work happens, can still
  /// draw a riser rather than getting a silent no-op (C6). Returns which way it
  /// went, or [RiserPlacement.none] when the building has a single floor (no
  /// adjacent floor to span) so the UI can fire a status message. The riser's
  /// length is the §10 elevation delta, never a pixel distance.
  ///
  /// B1 — the FAR (other-floor) node lands on the sheet MAPPED TO THAT FLOOR,
  /// not on the sheet the riser was drawn from. Every canvas overlay filters on
  /// sheet AND floor, so a far node stamped with the SOURCE sheet id is
  /// invisible on the floor above: the engineer cannot branch off the riser
  /// there, draws a disconnected island instead, and meets it later as a Review
  /// connectivity warning. When the destination floor has NO plan assigned the
  /// far node falls back to the source sheet (today's behaviour — there is
  /// nowhere better to put it, and it still spans the real elevation delta).
  /// [sheetIdForFloorOverride] injects the mapping for tests / callers that
  /// already resolved it.
  RiserPlacement placeRiser(
    String sheetId,
    int floorIndex,
    Offset world,
    int levelCount, {
    double snapRadius = 12,
    String? Function(int floorIndex)? sheetIdForFloorOverride,
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
    // B1: the far node belongs to the DESTINATION floor's plan when it has one.
    final otherSheetId = sheetIdForFloor(otherFloor, levelCount,
            override: sheetIdForFloorOverride) ??
        sheetId;
    final otherId = _id('n');
    nodes.add(NetNode(
        id: otherId,
        sheetId: otherSheetId,
        x: world.dx,
        y: world.dy,
        floorIndex: otherFloor));
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
  ///
  /// B1 — the UPPER node lands on the sheet MAPPED to the floor above (falling
  /// back to [sheetId] when that floor carries no plan), so a riser placed from
  /// the elevation is visible and branchable on BOTH floors' plans.
  String? placeRiserAt(
    String sheetId,
    int floorIndex,
    double worldX,
    int levelCount, {
    ServiceType? service,
    double y = 0,
    String? Function(int floorIndex)? sheetIdForFloorOverride,
  }) {
    if (floorIndex < 0 || floorIndex + 1 >= levelCount) return null;
    final svc = service ?? state.service;
    final upperSheetId = sheetIdForFloor(floorIndex + 1, levelCount,
            override: sheetIdForFloorOverride) ??
        sheetId;
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
        sheetId: upperSheetId,
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

  /// Move riser [edgeId] sideways in the Riser → Edit ELEVATION — a
  /// DIAGRAM-ONLY declutter gesture (B3).
  ///
  /// It used to write the elevation's world x straight onto both endpoint nodes,
  /// i.e. onto the PLAN geometry: sliding a riser along the elevation to untangle
  /// the diagram silently relocated it away from its shaft on the plan and on
  /// every plan export, with no warning and nothing on screen (in the elevation)
  /// to show that anything but the diagram had changed. The elevation is a
  /// GENERATED RENDER of the solve (golden rule 5); moving a symbol on it must
  /// not edit the drawing.
  ///
  /// It now writes both endpoints' x into the transient
  /// [schematicLayoutProvider] override map, which ONLY the elevation reads.
  /// Plan geometry — and therefore every §10 length, the plan canvas and every
  /// plan export — is untouched. The overrides are deliberately NOT persisted:
  /// reopening a project re-lays the elevation out from the plan geometry, which
  /// is the honest default for a decluttering gesture and keeps `.mechx`
  /// unchanged.
  ///
  /// No-op for a missing / non-riser edge id. Records no undo step (the network
  /// does not change).
  void moveRiserHorizontal(String edgeId, double worldX) {
    final idx = state.network.edges.indexWhere((e) => e.id == edgeId);
    if (idx < 0) return;
    final edge = state.network.edges[idx];
    if (edge.kind != EdgeKind.riser) return;
    ref.read(schematicLayoutProvider.notifier).setNodesX({
      edge.fromId: worldX,
      edge.toId: worldX,
    });
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
  /// nodes ON the removed floor are DELETED WITH IT (C2 — they have no home;
  /// see [elementsOnFloor]), together with every edge touching them, and nodes
  /// below are untouched. When [removedIndex] is
  /// null the stack was REPLACED wholesale (e.g. a template): every node's
  /// `floorIndex` is simply CLAMPED into `[0, levelCount)` — a node above the
  /// new top drops to the new top floor; a stack that only grew leaves
  /// everything unchanged. When [insertedCount] floors were INSERTED at
  /// [insertedIndex] (e.g. basements at index 0) every node at/above that slot
  /// shifts UP by [insertedCount] first, so it keeps its own physical floor.
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
    int? insertedIndex,
    int insertedCount = 0,
    bool record = true,
  }) {
    if (levelCount < 1) return;
    final maxIndex = levelCount - 1;
    var changed = false;
    // C2: a node ON the removed floor is deleted with it. It cannot keep its
    // index (the floor above slides down INTO that slot, silently FUSING two
    // floors' drawn work at the wrong elevation — in range, so no orphan check
    // fires and nothing warns), and it has no physical floor left to sit on.
    final removedNodeIds = <String>{};
    if (removedIndex != null) {
      for (final n in state.network.nodes) {
        if (n.floorIndex == removedIndex) removedNodeIds.add(n.id);
      }
    }
    final nodes = <NetNode>[];
    for (final n in state.network.nodes) {
      if (removedNodeIds.contains(n.id)) {
        changed = true;
        continue;
      }
      var fi = n.floorIndex;
      // [insertedCount] floors inserted at [insertedIndex] push every node
      // AT/ABOVE that slot up, so a node keeps its own physical floor (adding a
      // basement at index 0 shifts the whole drawing up by that many levels).
      if (insertedIndex != null && insertedCount > 0 && fi >= insertedIndex) {
        fi += insertedCount;
      }
      // A node above a removed floor shifts down one index to keep its own
      // physical floor; a node below it keeps its index (nodes ON it were
      // already dropped above).
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
    // C2: drop every edge that touched a deleted node (a run wholly on the
    // removed floor, and the riser leg that landed on it).
    final edges = removedNodeIds.isEmpty
        ? state.network.edges
        : [
            for (final e in state.network.edges)
              if (!removedNodeIds.contains(e.fromId) &&
                  !removedNodeIds.contains(e.toId))
                e,
          ];
    final next = Network(nodes: nodes, edges: edges);
    record ? _commit(next) : _setNetworkNoRecord(next);
  }

  /// How many drawn elements live on [floorIndex] — nodes on that floor plus
  /// every edge with an endpoint there (C2). This is exactly what
  /// [remapNodesForFloorChange] deletes when that floor is removed, so the
  /// confirm dialog can name a real count instead of asking blind. Read-only.
  int elementsOnFloor(int floorIndex) {
    final onFloor = <String>{};
    for (final n in state.network.nodes) {
      if (n.floorIndex == floorIndex) onFloor.add(n.id);
    }
    if (onFloor.isEmpty) return 0;
    var count = onFloor.length;
    for (final e in state.network.edges) {
      if (onFloor.contains(e.fromId) || onFloor.contains(e.toId)) count++;
    }
    return count;
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
      // The re-anchored chain point stays on the run's originating sheet/floor.
      pendingSheetId: pending == null ? null : state.pendingSheetId,
      pendingFloorIndex: pending == null ? null : state.pendingFloorIndex,
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

  /// Apply a matched set of an edge's properties — [service], the manual
  /// nominal-size override [sizeOverride], and the regime-appropriate material
  /// ([pipeProduct] / [ductProduct]) — in ONE undo step (a single [_commit] /
  /// one timeline entry), mirroring the E1 batch setters' "one undo step"
  /// discipline. This exists so the B27 'Match properties' brush can't push up
  /// to three timeline entries (size + material + service) per click. Passing
  /// null for a size/material CLEARS it. No-op when the edge is gone or nothing
  /// actually changes (so a target that already matches is byte-identical).
  void setEdgeProperties(
    String id, {
    required ServiceType service,
    Diameter? sizeOverride,
    PipeProduct? pipeProduct,
    DuctProduct? ductProduct,
  }) {
    final idx = state.network.edges.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    final e = state.network.edges[idx];
    final changed = e.service != service ||
        e.sizeOverride?.meters != sizeOverride?.meters ||
        e.pipeProduct != pipeProduct ||
        e.ductProduct != ductProduct;
    if (!changed) return;
    _replaceEdge(e.copyWith(
      service: service,
      sizeOverride: sizeOverride,
      clearSizeOverride: sizeOverride == null,
      pipeProduct: pipeProduct,
      clearPipeProduct: pipeProduct == null,
      ductProduct: ductProduct,
      clearDuctProduct: ductProduct == null,
    ));
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
    Set<ServiceType> avoidServices = const {},
  }) {
    final svc = service ?? state.service;
    final half = (spanPx ?? _defaultSegmentSpanPx) / 2;
    final aWorld = Offset(world.dx - half, world.dy);
    final bWorld = Offset(world.dx + half, world.dy);

    final nodes = [...state.network.nodes];
    String resolve(Offset p) {
      final snapped = _snap(nodes, sheetId, floorIndex, p, snapRadius,
          avoidServices: avoidServices, drawService: svc);
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
      String sheetId, int floorIndex, Offset world, double radius,
      {Set<ServiceType> avoidServices = const {}}) {
    final nodeId = _snap(state.network.nodes, sheetId, floorIndex, world, radius,
        avoidServices: avoidServices);
    if (nodeId != null) {
      return (nodeId: nodeId, edgeId: null, split: null);
    }
    final r2 = radius * radius;
    NetEdge? bestEdge;
    var bestD2 = r2;
    var bestP = world;
    for (final e in state.network.edges) {
      if (e.kind == EdgeKind.riser) continue;
      // E1: never tee into a run on a service the caller is scoped away from
      // (a hidden or locked layer the engineer can neither see nor unpick).
      if (avoidServices.contains(e.service)) continue;
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
    Set<ServiceType> avoidServices = const {},
  }) {
    final t = _dropTarget(sheetId, floorIndex, world, snapRadius,
        avoidServices: avoidServices);
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
    Set<ServiceType> avoidServices = const {},
  }) {
    final t = _dropTarget(sheetId, floorIndex, world, snapRadius,
        avoidServices: avoidServices);
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
    Set<ServiceType> avoidServices = const {},
  }) {
    final t = _dropTarget(sheetId, floorIndex, world, snapRadius,
        avoidServices: avoidServices);
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

    // M10 — the return bank on its OWN grid, one node per sized grille.
    // Previously exactly ONE return grille was placed carrying `airflowEach`,
    // so whenever the engine split the return across N faces (a 400 m² hall
    // sizes 4) the placed network carried 1/N of the room's return air into the
    // duct solve AND the BOM — a silent 75 % under-return. The supply branch
    // already looped its count; this mirrors it exactly.
    //
    // The grid formula is the supply branch's: for the overwhelmingly common
    // count == 1 it yields cols = rows = 1 ⇒ the single cell centre
    // (loX + w/2, loY + h/2) — the exact position placed before — so a
    // single-return room is byte-identical.
    final rn = s.return_.count;
    final rCols = math.max(1, math.sqrt(rn).ceil());
    final rRows = (rn / rCols).ceil();
    var placedReturns = 0;
    for (var ry = 0; ry < rRows && placedReturns < rn; ry++) {
      for (var cx = 0; cx < rCols && placedReturns < rn; cx++) {
        nodes.add(NetNode(
          id: _id('n'),
          sheetId: room.sheetId,
          x: loX + w * (cx + 0.5) / rCols,
          y: loY + h * (ry + 0.5) / rRows,
          floorIndex: room.floorIndex,
          role: NodeComponent.returnGrille.role,
          component: NodeComponent.returnGrille,
          airflow: s.return_.airflowEach,
          faceWidthMm: returnFace.$1,
          faceHeightMm: returnFace.$2,
        ));
        placedReturns++;
      }
    }

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
    Offset? Function(Offset world)? underlaySnap,
    bool ortho = false,
    Set<ServiceType> avoidServices = const {},
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
        gridSnap: gridSnap,
        gridMetersPerPixel: gridMetersPerPixel,
        underlaySnap: underlaySnap,
        avoidServices: avoidServices);
    if (farId == fromId) return null; // collapsed onto the source — nothing laid

    // B13: auto-elbow an off-ray connection so a nub-pulled main stays straight
    // (the source node anchors the constrained ray; one undo step).
    final connectTo = _autoElbowEndpoint(nodes, edges, sheetId, floorIndex,
        Offset(from.x, from.y), world, farId, svc, ortho: ortho);
    final edgeId = _id('e');
    edges.add(NetEdge(id: edgeId, fromId: fromId, toId: connectTo, service: svc));
    _commit(Network(nodes: nodes, edges: edges));
    return edgeId;
  }

  /// B17 — commit a whole two-click ORTHO route (a polyline of [points], from
  /// [orthoRoute]) as ONE undo step. The FIRST point resolves into the network
  /// (snap to a node / tee into a same-service run / adopt), each interior point
  /// becomes an exact bend junction (kept precise so the ortho geometry the
  /// caller computed is never re-snapped askew), and the LAST point resolves
  /// like a normal draw END — so it may itself auto-elbow onto an off-ray snap
  /// target (composes with B13). Consecutive duplicate points are skipped.
  /// Records nothing and returns null when the route collapses to no edge
  /// (fewer than 2 distinct points, or every leg zero-length). Returns the id
  /// the route ENDS on. Clears any pending run (the route is a finished draw).
  String? commitRoute(
    String sheetId,
    int floorIndex,
    List<Offset> points,
    ServiceType service, {
    double snapRadius = 12,
    double? endSnapRadius,
    bool gridSnap = false,
    double? gridMetersPerPixel,
    Offset? Function(Offset world)? underlaySnap,
    bool ortho = true,
    Set<ServiceType> avoidServices = const {},
  }) {
    // Drop consecutive duplicates so a degenerate route never mints a zero-leg.
    final pts = <Offset>[];
    for (final p in points) {
      if (pts.isEmpty || (p - pts.last).distance > kRouteStraightEpsilonPx) {
        pts.add(p);
      }
    }
    if (pts.length < 2) return null;

    final nodes = [...state.network.nodes];
    final edges = [...state.network.edges];
    // The start resolves into the network so the route actually connects to its
    // source (snap/tee/adopt at the normal radius, like placeRunPoint's start).
    var prevId = _resolveDrawEndpoint(nodes, edges, sheetId, floorIndex,
        pts.first, snapRadius, service,
        gridSnap: gridSnap,
        gridMetersPerPixel: gridMetersPerPixel,
        underlaySnap: underlaySnap,
        avoidServices: avoidServices);
    var addedAny = false;
    for (var i = 1; i < pts.length; i++) {
      final isLast = i == pts.length - 1;
      final String toId;
      if (isLast) {
        final resolved = _resolveDrawEndpoint(nodes, edges, sheetId, floorIndex,
            pts[i], endSnapRadius ?? snapRadius, service,
            gridSnap: gridSnap,
            gridMetersPerPixel: gridMetersPerPixel,
            underlaySnap: underlaySnap,
            avoidServices: avoidServices);
        if (resolved == prevId) continue; // collapsed onto the previous node
        final anchor = nodes.firstWhere((n) => n.id == prevId);
        toId = _autoElbowEndpoint(nodes, edges, sheetId, floorIndex,
            Offset(anchor.x, anchor.y), pts[i], resolved, service,
            ortho: ortho);
      } else {
        // An interior BEND — an exact fresh junction at the computed corner.
        final jId = _id('n');
        nodes.add(NetNode(
            id: jId,
            sheetId: sheetId,
            x: pts[i].dx,
            y: pts[i].dy,
            floorIndex: floorIndex));
        toId = jId;
      }
      if (toId == prevId) continue;
      edges.add(NetEdge(
          id: _id('e'), fromId: prevId, toId: toId, service: service));
      addedAny = true;
      prevId = toId;
    }
    if (!addedAny) return null;
    _commit(Network(nodes: nodes, edges: edges));
    return prevId;
  }

  /// B18 — TRIM/EXTEND run [edgeId]'s endpoint [endNodeId] to where the run's
  /// line meets boundary run [boundaryEdgeId]. Moves that endpoint to the
  /// intersection; if it lands MID-SPAN on the boundary the boundary is split
  /// into a TEE there (the moved endpoint becomes the junction); if it lands on
  /// a boundary end node the two nodes MERGE. Returns true (one undo step) on a
  /// real change; false — mutating NOTHING — when the runs are parallel, the
  /// crossing is off the boundary segment, or the inputs are invalid (missing /
  /// riser / cross-sheet / the endpoint already sits on the boundary).
  bool trimExtendEdge(
      String edgeId, String endNodeId, String boundaryEdgeId) {
    if (edgeId == boundaryEdgeId) return false;
    final net = state.network;
    final e = net.edgeById(edgeId);
    final b = net.edgeById(boundaryEdgeId);
    if (e == null || b == null) return false;
    if (e.kind == EdgeKind.riser || b.kind == EdgeKind.riser) return false;
    if (endNodeId != e.fromId && endNodeId != e.toId) return false;
    // The moving end already belonging to the boundary is a no-op.
    if (endNodeId == b.fromId || endNodeId == b.toId) return false;
    final anchorId = endNodeId == e.fromId ? e.toId : e.fromId;
    final mover = net.nodeById(endNodeId);
    final anchor = net.nodeById(anchorId);
    final q0 = net.nodeById(b.fromId);
    final q1 = net.nodeById(b.toId);
    if (mover == null || anchor == null || q0 == null || q1 == null) {
      return false;
    }
    if (mover.sheetId != q0.sheetId || mover.floorIndex != q0.floorIndex) {
      return false;
    }
    final a0 = Offset(anchor.x, anchor.y);
    final da = Offset(mover.x - anchor.x, mover.y - anchor.y);
    final bPos = Offset(q0.x, q0.y);
    final db = Offset(q1.x - q0.x, q1.y - q0.y);
    if ((da.dx == 0 && da.dy == 0) || (db.dx == 0 && db.dy == 0)) return false;
    final params = lineIntersectionParams(a0, da, bPos, db);
    if (params == null) return false; // parallel
    final (tA, sB) = params;
    const segTol = 1e-9;
    if (sB < -segTol || sB > 1 + segTol) return false; // off the boundary span
    final inter = Offset(a0.dx + da.dx * tA, a0.dy + da.dy * tA);

    // Landed on a boundary end node -> merge the two nodes cleanly.
    const mergePx = 0.5;
    String? mergeTarget;
    if ((inter - Offset(q0.x, q0.y)).distance <= mergePx) {
      mergeTarget = q0.id;
    } else if ((inter - Offset(q1.x, q1.y)).distance <= mergePx) {
      mergeTarget = q1.id;
    }
    if (mergeTarget != null && mergeTarget != endNodeId) {
      final finalNodes =
          net.nodes.where((n) => n.id != endNodeId).toList();
      final finalEdges = <NetEdge>[];
      for (final ed in net.edges) {
        final from = ed.fromId == endNodeId ? mergeTarget : ed.fromId;
        final to = ed.toId == endNodeId ? mergeTarget : ed.toId;
        if (from == to) continue; // collapsed self-loop
        finalEdges.add((from == ed.fromId && to == ed.toId)
            ? ed
            : ed.copyWith(fromId: from, toId: to));
      }
      _commit(Network(nodes: finalNodes, edges: finalEdges));
      return true;
    }

    // Mid-span -> move the endpoint to the crossing and TEE the boundary there
    // (the moved endpoint becomes the boundary's split junction).
    final nodes = [
      for (final n in net.nodes)
        n.id == endNodeId ? n.copyWith(x: inter.dx, y: inter.dy) : n,
    ];
    final edges = <NetEdge>[];
    for (final ed in net.edges) {
      if (ed.id != boundaryEdgeId) {
        edges.add(ed);
        continue;
      }
      edges.add(ed.copyWith(toId: endNodeId));
      edges.add(NetEdge(
        id: _id('e'),
        fromId: endNodeId,
        toId: ed.toId,
        service: ed.service,
        kind: ed.kind,
        pipeProduct: ed.pipeProduct,
        ductProduct: ed.ductProduct,
        sizeOverride: ed.sizeOverride,
      ));
    }
    _commit(Network(nodes: nodes, edges: edges));
    return true;
  }

  /// B19 — CORNER-JOIN two dangling degree-1 ends [endNodeIdA]/[endNodeIdB] of
  /// the SAME service: extend both their segments to their lines' intersection,
  /// then merge the two nodes into ONE bend junction there (each segment keeps
  /// its exact bearing, so a clean right-angle/45 corner results). Returns true
  /// (one undo step) on success; false — mutating NOTHING — when the ends are
  /// the same node, either isn't a lone same-sheet run end, the services differ,
  /// the segments are parallel, or the intersection is absurdly far (beyond ~3x
  /// the longer segment — a near-parallel meeting off in space).
  bool joinCorner(String endNodeIdA, String endNodeIdB) {
    if (endNodeIdA == endNodeIdB) return false;
    final net = state.network;
    final na = net.nodeById(endNodeIdA);
    final nb = net.nodeById(endNodeIdB);
    if (na == null || nb == null) return false;
    if (na.sheetId != nb.sheetId || na.floorIndex != nb.floorIndex) {
      return false;
    }
    final ea = _soleRunEdge(endNodeIdA);
    final eb = _soleRunEdge(endNodeIdB);
    if (ea == null || eb == null || ea.id == eb.id) return false;
    if (ea.service != eb.service) return false;
    final anchorAId = ea.fromId == endNodeIdA ? ea.toId : ea.fromId;
    final anchorBId = eb.fromId == endNodeIdB ? eb.toId : eb.fromId;
    final aa = net.nodeById(anchorAId);
    final ab = net.nodeById(anchorBId);
    if (aa == null || ab == null) return false;
    final a0 = Offset(aa.x, aa.y);
    final da = Offset(na.x - aa.x, na.y - aa.y);
    final b0 = Offset(ab.x, ab.y);
    final db = Offset(nb.x - ab.x, nb.y - ab.y);
    if ((da.dx == 0 && da.dy == 0) || (db.dx == 0 && db.dy == 0)) return false;
    final params = lineIntersectionParams(a0, da, b0, db);
    if (params == null) return false; // parallel
    final inter = Offset(a0.dx + da.dx * params.$1, a0.dy + da.dy * params.$1);
    final maxLen = math.max(da.distance, db.distance);
    final reach = math.max((inter - Offset(na.x, na.y)).distance,
        (inter - Offset(nb.x, nb.y)).distance);
    if (reach > 3 * maxLen) return false; // absurdly far — refuse honestly

    // Merge: move A's node to the corner, re-point B's edge from B's node onto
    // A's node, drop B's node (and any self-loop the merge would form).
    final nodes = <NetNode>[];
    for (final n in net.nodes) {
      if (n.id == endNodeIdB) continue; // dropped into A
      nodes.add(n.id == endNodeIdA ? n.copyWith(x: inter.dx, y: inter.dy) : n);
    }
    final edges = <NetEdge>[];
    for (final ed in net.edges) {
      final from = ed.fromId == endNodeIdB ? endNodeIdA : ed.fromId;
      final to = ed.toId == endNodeIdB ? endNodeIdA : ed.toId;
      if (from == to) continue;
      edges.add((from == ed.fromId && to == ed.toId)
          ? ed
          : ed.copyWith(fromId: from, toId: to));
    }
    _commit(Network(nodes: nodes, edges: edges));
    return true;
  }

  /// The single RUN edge incident to [nodeId] when the node is a lone (degree-1)
  /// run end, else null — a node with no edge, more than one edge, or whose sole
  /// edge is a riser is NOT a plan-view dangling end.
  NetEdge? _soleRunEdge(String nodeId) {
    NetEdge? found;
    for (final e in state.network.edges) {
      if (e.fromId == nodeId || e.toId == nodeId) {
        if (found != null) return null; // degree > 1
        found = e;
      }
    }
    if (found == null || found.kind == EdgeKind.riser) return null;
    return found;
  }

  /// B20 — SEGMENT grip-drag: translate BOTH endpoints of run [edgeId] along the
  /// segment's NORMAL by the normal-component of [delta] (world px), so the
  /// segment slides parallel to itself (ortho preserved by construction) and any
  /// neighbour segments sharing an endpoint stretch to follow. A LIVE,
  /// non-recording mutation (pair with [pushUndoSnapshot] at drag start + the
  /// throttle — exactly like [moveNode]/[moveMany]); one undo step per drag
  /// session. No-op for a missing/riser/zero-length edge or a zero normal push.
  void dragSegment(String edgeId, Offset delta) {
    final edge = state.network.edgeById(edgeId);
    if (edge == null || edge.kind == EdgeKind.riser) return;
    final a = state.network.nodeById(edge.fromId);
    final b = state.network.nodeById(edge.toId);
    if (a == null || b == null) return;
    final vx = b.x - a.x;
    final vy = b.y - a.y;
    final len = math.sqrt(vx * vx + vy * vy);
    if (len == 0) return; // degenerate — no defined normal
    // Unit normal (perpendicular to the segment) and the signed push along it.
    final nx = -vy / len;
    final ny = vx / len;
    final proj = delta.dx * nx + delta.dy * ny;
    if (proj == 0) return;
    final mx = nx * proj;
    final my = ny * proj;
    final moved = {edge.fromId, edge.toId};
    final nodes = [
      for (final n in state.network.nodes)
        if (moved.contains(n.id)) n.copyWith(x: n.x + mx, y: n.y + my) else n,
    ];
    state = DrawingState(
      network: Network(nodes: nodes, edges: state.network.edges),
      service: state.service,
      tool: state.tool,
      pendingPoint: state.pendingPoint,
      pendingSheetId: state.pendingSheetId,
      pendingFloorIndex: state.pendingFloorIndex,
    );
    // K1: coalesce the heavy chain to the throttle cadence during the drag.
    ref.read(dragSessionProvider.notifier).tickDrag();
  }

  /// B22 — DIMENSION-DRIVEN edit: move run [edgeId]'s free end along the run's
  /// bearing so its calibrated length becomes exactly [metres]. The mover is the
  /// degree-1 endpoint (the free end) when there is a unique one, else the
  /// caller-picked [moveEndId]; the OTHER end anchors the bearing. [metersPerPixel]
  /// is the sheet's calibration (kept UI/clock-free — passed in). Returns true
  /// (one undo step) on success; false — mutating NOTHING — for a missing/riser
  /// edge, a non-positive length or scale, a degenerate (zero-length) run, or an
  /// ambiguous mover (both/neither end free and no valid [moveEndId]).
  bool setRunLength(String edgeId, double metres, double metersPerPixel,
      {String? moveEndId}) {
    if (metres <= 0 || metersPerPixel <= 0) return false;
    final net = state.network;
    final e = net.edgeById(edgeId);
    if (e == null || e.kind == EdgeKind.riser) return false;

    String moverId;
    if (moveEndId != null) {
      if (moveEndId != e.fromId && moveEndId != e.toId) return false;
      moverId = moveEndId;
    } else {
      final fromFree = net.edgesAt(e.fromId).length == 1;
      final toFree = net.edgesAt(e.toId).length == 1;
      if (fromFree && !toFree) {
        moverId = e.fromId;
      } else if (toFree && !fromFree) {
        moverId = e.toId;
      } else {
        return false; // ambiguous — caller must pick moveEndId
      }
    }
    final anchorId = moverId == e.fromId ? e.toId : e.fromId;
    final mover = net.nodeById(moverId);
    final anchor = net.nodeById(anchorId);
    if (mover == null || anchor == null) return false;
    final vx = mover.x - anchor.x;
    final vy = mover.y - anchor.y;
    final len = math.sqrt(vx * vx + vy * vy);
    if (len == 0) return false; // no bearing to move along
    final targetPx = metres / metersPerPixel;
    final nxpos = anchor.x + vx / len * targetPx;
    final nypos = anchor.y + vy / len * targetPx;
    if (nxpos == mover.x && nypos == mover.y) return false; // already exact
    final nodes = [
      for (final n in net.nodes)
        n.id == moverId ? n.copyWith(x: nxpos, y: nypos) : n,
    ];
    _commit(Network(nodes: nodes, edges: net.edges));
    return true;
  }

  /// B13 — the CAD auto-elbow. When [ortho] is on and the resolved far endpoint
  /// [farId] lies off the constrained 45°-multiple ray from [startPos] toward
  /// [through] beyond the epsilon, insert a BEND junction so the run reaches
  /// [farId] as TWO axis/45-aligned segments: the caller's LEADING edge runs
  /// [startPos]→bend (the dominant leg along the constraint) and this method
  /// adds the short bend→[farId] correcting leg (carrying [service]). Returns
  /// the id the leading edge should connect to — the bend when one was inserted,
  /// else [farId] unchanged (ortho off, missing node, or an on-ray target that
  /// absorbs straight). Mutates [nodes]/[edges] so the whole L commits in the
  /// caller's single [_commit] (one undo step). The geometry mirrors the live
  /// preview's `orthoElbow` — the same shared helper decides the bend.
  String _autoElbowEndpoint(
    List<NetNode> nodes,
    List<NetEdge> edges,
    String sheetId,
    int floorIndex,
    Offset startPos,
    Offset through,
    String farId,
    ServiceType service, {
    required bool ortho,
  }) {
    if (!ortho) return farId;
    final far = nodes.where((n) => n.id == farId).firstOrNull;
    if (far == null) return farId;
    final bend = orthoElbow(startPos, through, Offset(far.x, far.y));
    if (bend == null) return farId; // on-ray / absorbed — single straight segment
    final bId = _id('n');
    nodes.add(NetNode(
        id: bId,
        sheetId: sheetId,
        x: bend.dx,
        y: bend.dy,
        floorIndex: floorIndex));
    edges.add(NetEdge(id: _id('e'), fromId: bId, toId: farId, service: service));
    return bId;
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
    Offset? Function(Offset world)? underlaySnap,
    Set<ServiceType> avoidServices = const {},
  }) {
    // 1) snap to an existing node on this floor — scoped (E1) to nodes this
    // service may legitimately adopt, never one belonging solely to a hidden /
    // locked / foreign-service network.
    final snapped = _snap(nodes, sheetId, floorIndex, world, snapRadius,
        edges: edges, avoidServices: avoidServices, drawService: service);
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
      if (avoidServices.contains(e.service)) continue;
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

    // 3) a fresh junction node at the release point — but first offer the point
    // to the PLAN UNDERLAY (B12): a DXF wall/shaft line, a traced reference line,
    // or a PDF ink ridge near the release attracts the node. Underlay outranks
    // the grid (a real architectural edge beats an abstract metre crossing) but
    // sits BELOW node/tee snap (steps 1-2 already returned). Null ⇒ no underlay.
    // Then the VISIBLE metre grid as the lowest-precedence snap (unchanged). Both
    // default off/absent ⇒ byte-identical.
    var point = world;
    final u = underlaySnap?.call(world);
    if (u != null) {
      point = u;
    } else if (gridSnap && gridMetersPerPixel != null) {
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
    Offset? Function(Offset world)? underlaySnap,
    Offset? orthoAnchor,
    Set<ServiceType> avoidServices = const {},
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
      // E1: never merge onto a node that belongs solely to an avoided (hidden /
      // locked) service — the engineer could neither see nor unpick the join.
      if (avoidServices.isNotEmpty &&
          !_nodeAdoptable(n, state.network.edges,
              avoidServices: avoidServices)) {
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
          gridSnap: gridSnap,
          gridMetersPerPixel: gridMetersPerPixel,
          underlaySnap: underlaySnap,
          avoidServices: avoidServices);
      return;
    }

    // B13: an endpoint resized under ortho onto an OFF-ray node would tilt the
    // run. Instead of merging the endpoint onto that node (which drags the whole
    // segment askew), keep the dominant leg straight: reposition this endpoint
    // to the BEND on the constrained ray and add a short correcting leg to the
    // target — the two axis/45-aligned segments, one undo step.
    if (orthoAnchor != null) {
      final tnode = state.network.nodeById(targetId);
      if (tnode != null) {
        final bend = orthoElbow(orthoAnchor, Offset(dragged.x, dragged.y),
            Offset(tnode.x, tnode.y));
        if (bend != null) {
          final svc = _serviceOf(nodeId) ?? state.service;
          final nodes = [
            for (final n in state.network.nodes)
              if (n.id == nodeId) n.copyWith(x: bend.dx, y: bend.dy) else n,
          ];
          final edges = [
            ...state.network.edges,
            NetEdge(id: _id('e'), fromId: nodeId, toId: targetId, service: svc),
          ];
          _commitDragEnd(Network(nodes: nodes, edges: edges));
          return;
        }
      }
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
    Offset? Function(Offset world)? underlaySnap,
    Set<ServiceType> avoidServices = const {},
  }) {
    final net = state.network;

    NetEdge? bestEdge;
    var bestD2 = radiusWorld * radiusWorld;
    var bestP = Offset.zero;
    final dp = Offset(dragged.x, dragged.y);
    for (final e in net.edges) {
      if (e.kind == EdgeKind.riser) continue; // tap onto horizontal runs only
      // E1: never tap into a run on an avoided (hidden / locked) service.
      if (avoidServices.contains(e.service)) continue;
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
      // the drag's LAST resorts are, in precedence: the PLAN UNDERLAY (B12 — a
      // DXF wall / reference line / PDF ink ridge near the drop) then the metre
      // GRID. Underlay outranks grid; both leave the node where it fell when
      // nothing is in range. Default absent/off ⇒ byte-identical.
      final u = underlaySnap?.call(dp);
      final Offset? target;
      if (u != null) {
        target = u;
      } else if (gridSnap && gridMetersPerPixel != null) {
        final g = nearestGridIntersection(dp, gridMetersPerPixel);
        target = ((g - dp).distanceSquared <= radiusWorld * radiusWorld) ? g : null;
      } else {
        target = null;
      }
      if (target != null && (target.dx != dragged.x || target.dy != dragged.y)) {
        final moved = [
          for (final n in net.nodes)
            n.id == dragged.id ? n.copyWith(x: target.dx, y: target.dy) : n,
        ];
        _commitDragEnd(Network(nodes: moved, edges: net.edges));
        return;
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
  ///
  /// J4: also carries FREE-STANDING nodes — equipment/fixtures/terminals placed
  /// on the source floor but not yet wired into any run (a fire extinguisher,
  /// hose reel, or AC unit dropped before its pipe/duct is routed). Without this
  /// they vanish floor-by-floor on a multi-target duplicate, only noticed later
  /// when the BOM / fire review comes up short. A node is loose when NO edge
  /// (run OR riser) touches it; risers exclude their own endpoints (they span
  /// floors and aren't copied). No-op only if the floor has neither runs nor
  /// loose nodes.
  void duplicateFloor({
    required String fromSheetId,
    required int fromFloor,
    required String toSheetId,
    required int toFloor,
  }) {
    final old = state.network;
    final addedNodes = <NetNode>[];
    final addedEdges = <NetEdge>[];
    _appendFloorClones(old, fromSheetId, fromFloor, toSheetId, toFloor,
        addedNodes, addedEdges);
    if (addedNodes.isEmpty && addedEdges.isEmpty) return;
    _commit(Network(
      nodes: [...old.nodes, ...addedNodes],
      edges: [...old.edges, ...addedEdges],
    ));
  }

  /// F3 — batch-duplicate one source floor's runs + loose equipment onto SEVERAL
  /// target `(sheetId, floor)` pairs in ONE commit, so a range-duplicate is a
  /// SINGLE undo step (not one per target floor). Every target's clones
  /// accumulate into the same nodes/edges list before a single [_commit], so
  /// Ctrl+Z restores the whole pre-duplicate state at once. Clone rules mirror
  /// [duplicateFloor] exactly (per-target fresh ids, risers excluded, loose
  /// free-standing equipment carried). A source == target pair is skipped; an
  /// empty / duplicate-only batch commits nothing.
  void duplicateFloorToTargets({
    required String fromSheetId,
    required int fromFloor,
    required List<({String sheetId, int floor})> targets,
  }) {
    final old = state.network;
    final addedNodes = <NetNode>[];
    final addedEdges = <NetEdge>[];
    for (final t in targets) {
      if (t.sheetId == fromSheetId && t.floor == fromFloor) continue;
      _appendFloorClones(old, fromSheetId, fromFloor, t.sheetId, t.floor,
          addedNodes, addedEdges);
    }
    if (addedNodes.isEmpty && addedEdges.isEmpty) return;
    _commit(Network(
      nodes: [...old.nodes, ...addedNodes],
      edges: [...old.edges, ...addedEdges],
    ));
  }

  /// Append the clones of [fromSheetId]/[fromFloor]'s runs + loose equipment
  /// onto [toSheetId]/[toFloor] into [addedNodes]/[addedEdges] with fresh ids —
  /// the shared clone core of [duplicateFloor] (single target) and
  /// [duplicateFloorToTargets] (a batch that shares ONE undo step). Does NOT
  /// commit: the caller decides how many targets fold into a single commit.
  /// Each call uses its OWN old→new id map, so the same source node clones
  /// independently onto every target floor.
  void _appendFloorClones(
    Network old,
    String fromSheetId,
    int fromFloor,
    String toSheetId,
    int toFloor,
    List<NetNode> addedNodes,
    List<NetEdge> addedEdges,
  ) {
    final clones = <String, String>{}; // old node id → new node id (this target)

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
    // Loose nodes: everything on the source floor no edge touches (J4). The run
    // loop already cloned every wired node, so these are the free-standing
    // equipment/fixtures — copy them so the floor's content moves intact.
    final touched = <String>{};
    for (final e in old.edges) {
      touched
        ..add(e.fromId)
        ..add(e.toId);
    }
    for (final n in old.nodes) {
      if (n.sheetId != fromSheetId || n.floorIndex != fromFloor) continue;
      if (touched.contains(n.id)) continue;
      cloneNode(n); // adds to addedNodes on the target floor with a fresh id
    }
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

  /// I4 — paste the clipboard onto SEVERAL floors at once, in ONE undo step:
  /// the shaft group that repeats up six levels is one gesture, not six sheet
  /// switches and six pastes.
  ///
  /// Each entry of [targets] is a (sheetId, floor) destination; every target
  /// receives its own fresh-id clone of the SAME clipboard generation, landing
  /// at the clipboard's own plan position ([offsetWorld], zero by default) —
  /// a riser group must stack directly above itself, so the cascade offset a
  /// repeated Ctrl+V uses would be wrong here. Duplicate targets are collapsed.
  ///
  /// The whole fan-out is committed once, so ONE Ctrl+Z removes every floor's
  /// copy; the new elements across all floors become the multi-selection and are
  /// returned. Like [pasteNCopies] this does NOT re-base the clipboard (the
  /// fan-out is a one-shot from the originals, so a following Ctrl+V still
  /// pastes the original block). No-op (empty result) when the clipboard is
  /// empty or [targets] is empty.
  ({Set<String> nodeIds, Set<String> edgeIds}) pasteToTargets(
    List<({String sheetId, int floor})> targets, {
    Offset offsetWorld = Offset.zero,
  }) {
    final clip = _clipboard;
    if (clip == null || clip.nodes.isEmpty || targets.isEmpty) {
      return (nodeIds: <String>{}, edgeIds: <String>{});
    }
    final seen = <String>{};
    final addedNodes = <NetNode>[];
    final addedEdges = <NetEdge>[];
    final allNodeIds = <String>{};
    final allEdgeIds = <String>{};
    for (final t in targets) {
      if (!seen.add('${t.sheetId}#${t.floor}')) continue;
      final gen = _cloneClipboard(clip, t.sheetId, t.floor, offsetWorld);
      addedNodes.addAll(gen.nodes);
      addedEdges.addAll(gen.edges);
      allNodeIds.addAll(gen.nodeIds);
      allEdgeIds.addAll(gen.edgeIds);
    }
    if (addedNodes.isEmpty) {
      return (nodeIds: <String>{}, edgeIds: <String>{});
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

  // ── Multi-select transforms (rotate / mirror) ───────────────────────────────

  /// The EFFECTIVE node set of a [nodeIds]/[edgeIds] selection: the chosen nodes
  /// PLUS both endpoints of every chosen edge (edges follow their endpoints —
  /// mirrors [copySelection]'s kept-node rule), keeping only ids that exist in
  /// the live network. So `select-similar` (which yields edges only) still
  /// transforms every touched node.
  Set<String> _selectionNodeSet(Set<String> nodeIds, Set<String> edgeIds) {
    final net = state.network;
    final present = {for (final n in net.nodes) n.id};
    final ids = <String>{
      for (final id in nodeIds)
        if (present.contains(id)) id,
    };
    for (final e in net.edges) {
      if (!edgeIds.contains(e.id)) continue;
      if (present.contains(e.fromId)) ids.add(e.fromId);
      if (present.contains(e.toId)) ids.add(e.toId);
    }
    return ids;
  }

  /// Rotate every node in the [nodeIds]/[edgeIds] selection 90 degrees about the
  /// selection's bounding-box centre, in ONE undo step. [clockwise] picks the
  /// visual direction on the plan (screen space has +y DOWN, so a clockwise turn
  /// maps a delta (dx,dy) -> (-dy, dx); counter-clockwise -> (dy, -dx)). Edges
  /// follow their endpoints automatically (they reference node ids, and the
  /// positions live on the nodes). Axis-aligned and 45-degree geometry stay
  /// EXACT — a right-angle turn only swaps/negates coordinate deltas, no trig.
  /// Node ELEVATIONS / floor indices are untouched (a plan-view turn is
  /// horizontal only, so §10 vertical/riser length is unaffected). No-op when
  /// the effective set has fewer than two nodes, or when every node sits on the
  /// centre (a degenerate box — e.g. a single stacked riser column at one x,y),
  /// so a no-change turn never pushes an empty undo step.
  void rotateSelection(Set<String> nodeIds, Set<String> edgeIds,
      {required bool clockwise}) {
    final net = state.network;
    final ids = _selectionNodeSet(nodeIds, edgeIds);
    if (ids.length < 2) return;
    final (cx, cy) = _selectionCentre(net, ids);
    var moved = false;
    final nodes = <NetNode>[];
    for (final n in net.nodes) {
      if (!ids.contains(n.id)) {
        nodes.add(n);
        continue;
      }
      final dx = n.x - cx;
      final dy = n.y - cy;
      final nx = clockwise ? cx - dy : cx + dy;
      final ny = clockwise ? cy + dx : cy - dx;
      if (nx != n.x || ny != n.y) moved = true;
      nodes.add(n.copyWith(x: nx, y: ny));
    }
    if (!moved) return;
    _commit(Network(nodes: nodes, edges: net.edges));
  }

  /// Mirror every node in the [nodeIds]/[edgeIds] selection about the selection's
  /// bounding-box centre, in ONE undo step. [horizontal] flips LEFT/RIGHT across
  /// the vertical centre line (x -> 2·cx − x); otherwise flips TOP/BOTTOM across
  /// the horizontal centre line (y -> 2·cy − y). The centre is preserved by the
  /// reflection, so mirroring the same axis TWICE is an exact identity. Edges
  /// follow their endpoints; elevations / floor indices are untouched; a 45-degree
  /// diagonal stays exact (one coordinate is negated about the centre). Same
  /// effective-set / no-op guards as [rotateSelection].
  void mirrorSelection(Set<String> nodeIds, Set<String> edgeIds,
      {required bool horizontal}) {
    final net = state.network;
    final ids = _selectionNodeSet(nodeIds, edgeIds);
    if (ids.length < 2) return;
    final (cx, cy) = _selectionCentre(net, ids);
    var moved = false;
    final nodes = <NetNode>[];
    for (final n in net.nodes) {
      if (!ids.contains(n.id)) {
        nodes.add(n);
        continue;
      }
      final nx = horizontal ? (2 * cx - n.x) : n.x;
      final ny = horizontal ? n.y : (2 * cy - n.y);
      if (nx != n.x || ny != n.y) moved = true;
      nodes.add(n.copyWith(x: nx, y: ny));
    }
    if (!moved) return;
    _commit(Network(nodes: nodes, edges: net.edges));
  }

  /// The bounding-box centre (in sheet/world px) of the nodes whose ids are in
  /// [ids]. [ids] is assumed non-empty and to reference live nodes.
  (double, double) _selectionCentre(Network net, Set<String> ids) {
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final n in net.nodes) {
      if (!ids.contains(n.id)) continue;
      minX = math.min(minX, n.x);
      minY = math.min(minY, n.y);
      maxX = math.max(maxX, n.x);
      maxY = math.max(maxY, n.y);
    }
    return ((minX + maxX) / 2, (minY + maxY) / 2);
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
      pendingSheetId: state.pendingSheetId,
      pendingFloorIndex: state.pendingFloorIndex,
    );
    // K1: coalesce the heavy sizing/solve chain to the throttle cadence while a
    // drag is active (no-op when it isn't, so a programmatic move is unchanged).
    ref.read(dragSessionProvider.notifier).tickDrag();
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
      pendingSheetId: state.pendingSheetId,
      pendingFloorIndex: state.pendingFloorIndex,
    );
    // K1: same throttle gate as moveNode for a live GROUP drag.
    ref.read(dragSessionProvider.notifier).tickDrag();
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

/// Transient live-drag session state (K1 — performance-feel). A node drag
/// mutates the canonical [Network] on every pointer-move frame (see
/// [NetworkController.moveNode]); the cheap geometry/paint path watches
/// [networkControllerProvider] directly and stays per-frame live. The HEAVY
/// sizing/solve/BOM chain, however, watches the THROTTLED [sizingNetworkProvider]
/// instead, so during an active drag it recomputes at most once per
/// [DragSessionController.throttleInterval] (a coalesced timer tick) plus exactly
/// once on drag end — never once per frame. At rest (no active drag) the throttle
/// is inert and [sizingNetworkProvider] mirrors the live network, so results are
/// byte-identical.
@immutable
class DragSession {
  /// True between [DragSessionController.beginDrag] and [endDrag].
  final bool active;

  /// Bumps once on each drag close (settle or [endDrag]) so a downstream read
  /// can observe that a session ended even if the network object is unchanged.
  final int tick;

  /// The network snapshot the heavy chain sizes against WHILE a drag is active
  /// — captured at drag start so per-frame [NetworkController.moveNode] updates
  /// (which the cheap paint path still sees live) do NOT re-run the pipeline.
  /// The active branch returning this fixed snapshot (rather than reading the
  /// live network) also makes the freeze robust to Riverpod's lazy rebuild: a
  /// stale live-network invalidation just re-yields the same snapshot. Null when
  /// no drag is active.
  final Network? frozen;

  const DragSession({this.active = false, this.tick = 0, this.frozen});
}

final dragSessionProvider =
    NotifierProvider<DragSessionController, DragSession>(
        DragSessionController.new);

class DragSessionController extends Notifier<DragSession> {
  Timer? _throttle;

  /// The maximum cadence at which the heavy sizing/solve chain refreshes while a
  /// drag is in flight. ~150 ms keeps the pipeline responsive without re-running
  /// the whole multi-floor solve on every pointer-move frame. Settable so tests
  /// can pin it deterministically.
  Duration throttleInterval = const Duration(milliseconds: 150);

  @override
  DragSession build() {
    ref.onDispose(() {
      _throttle?.cancel();
      _throttle = null;
    });
    return const DragSession();
  }

  /// Open a drag session (call at a genuine pointer-drag START): the heavy chain
  /// freezes on the CURRENT network snapshot while the drag runs. Idempotent;
  /// cancels any stale settle tick.
  void beginDrag() {
    _throttle?.cancel();
    _throttle = null;
    if (state.active) return;
    state = DragSession(
      active: true,
      tick: state.tick,
      frozen: ref.read(networkControllerProvider).network,
    );
  }

  /// Record a drag frame. Debounces the settle: while the drag keeps moving (a
  /// fresh frame within [throttleInterval]) the heavy chain stays frozen on the
  /// drag-start snapshot; once the pointer SETTLES (no frame for
  /// [throttleInterval]) the session closes and the chain refreshes against the
  /// live network. This self-heals a missed [endDrag] (a cancelled/early-returned
  /// drag can never leave the heavy chain permanently frozen). No-op when no drag
  /// is active (so a keyboard nudge or a programmatic [moveNode] — which never
  /// [beginDrag] — is byte-identical).
  void tickDrag() {
    if (!state.active) return;
    _throttle?.cancel();
    _throttle = Timer(throttleInterval, () {
      _throttle = null;
      if (state.active) _close();
    });
  }

  /// Close the drag session (call at pointer-drag END): the heavy chain refreshes
  /// once against the settled live network. Cancels any pending settle tick.
  /// No-op when nothing is open (safety-net callers).
  void endDrag() {
    _throttle?.cancel();
    _throttle = null;
    if (state.active) _close();
  }

  void _close() =>
      state = DragSession(active: false, tick: state.tick + 1, frozen: null);
}

/// The network the HEAVY sizing/solve/BOM providers size against. At rest this
/// mirrors the live [networkControllerProvider] network reactively (byte-
/// identical to reading it directly). During an active drag it samples the live
/// network only when the throttle advances (or the session opens/closes), so the
/// per-frame position updates that keep the canvas paint live do NOT re-run the
/// whole pipeline every frame (K1).
final sizingNetworkProvider = Provider<Network>((ref) {
  final drag = ref.watch(dragSessionProvider);
  if (!drag.active || drag.frozen == null) {
    // At rest: watch the live network so any edit recomputes immediately.
    return ref.watch(networkControllerProvider).network;
  }
  // During a drag: return the fixed drag-start snapshot (the ONLY reactive input
  // is `drag`). A per-frame moveNode changes the live network but NOT this value,
  // so the heavy sizing/solve/BOM chain stays frozen until the drag settles or
  // ends — while the canvas paint path, which watches networkControllerProvider
  // directly, stays per-frame live.
  return drag.frozen!;
});

/// Whether run drawing snaps to the nearest 45° (ortho). Default on.
final orthoProvider =
    NotifierProvider<OrthoController, bool>(OrthoController.new);

class OrthoController extends Notifier<bool> {
  @override
  bool build() => true;

  void toggle() => state = !state;
}
