import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

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
