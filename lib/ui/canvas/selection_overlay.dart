import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

import '../../store/network_store.dart';
import '../../store/selection_store.dart';
import '../../store/sheets_store.dart';
import 'edge_context_menu.dart';
import 'viewport.dart';

/// Interaction layer active while the Select tool is chosen: a tap picks the
/// nearest node (then edge) on this floor and writes it to [selectionProvider];
/// a tap on empty space clears the selection.
class NetworkSelectionOverlay extends ConsumerWidget {
  final String sheetId;
  final int floorIndex;

  const NetworkSelectionOverlay({
    super.key,
    required this.sheetId,
    required this.floorIndex,
  });

  bool _onFloor(NetNode n) => n.sheetId == sheetId && n.floorIndex == floorIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final net = ref.watch(networkControllerProvider).network;
    final transform =
        ref.watch(sheetsControllerProvider).viewportFor(sheetId) ??
            const ViewportTransform();
    final sel = ref.read(selectionProvider.notifier);
    final selection = ref.watch(selectionProvider);

    // On-floor node drag handles (opaque, small) sit above the translucent tap
    // layer: dragging a handle moves the node; tapping it selects it; anywhere
    // else, the tap layer selects/clears and drags fall through to canvas pan.
    // Drag-end snaps the node to a nearby node (merge) so a segment endpoint
    // "connects" to a fitting.
    final snapWorld = 14 / transform.scale;
    final handles = <Widget>[
      for (final n in net.nodes)
        if (_onFloor(n))
          _dragHandle(ref, n.id, transform.worldToScreen(Offset(n.x, n.y)),
              transform.scale, snapWorld),
    ];

    // A selected run's two endpoints get larger, accented resize handles — the
    // direct way to stretch a dropped segment until it snaps to a fitting.
    final resizeHandles = <Widget>[];
    if (selection.isEdge) {
      for (final e in net.edges) {
        if (e.id != selection.edgeId || e.kind != EdgeKind.run) continue;
        for (final nid in [e.fromId, e.toId]) {
          final n = net.nodeById(nid);
          if (n == null || !_onFloor(n)) continue;
          resizeHandles.add(_resizeHandle(
            ref,
            n.id,
            e.id,
            transform.worldToScreen(Offset(n.x, n.y)),
            transform.scale,
            snapWorld,
          ));
        }
      }
    }

    // Translucent (not opaque) so a tap selects, but drag-pan and scroll-zoom
    // still reach the CanvasView underneath.
    return Stack(
      children: [
        Positioned.fill(child: _tapLayer(context, ref, net, transform, sel)),
        ...handles,
        ...resizeHandles,
      ],
    );
  }

  Widget _dragHandle(
      WidgetRef ref, String id, Offset screen, double scale, double snapWorld) {
    const r = 12.0;
    return Positioned(
      left: screen.dx - r,
      top: screen.dy - r,
      width: r * 2,
      height: r * 2,
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => ref.read(selectionProvider.notifier).selectNode(id),
          onPanStart: (_) {
            ref.read(selectionProvider.notifier).selectNode(id);
            ref.read(networkControllerProvider.notifier).pushUndoSnapshot();
          },
          onPanUpdate: (d) {
            final node =
                ref.read(networkControllerProvider).network.nodeById(id);
            if (node == null) return;
            ref.read(networkControllerProvider.notifier).moveNode(
                  id,
                  node.x + d.delta.dx / scale,
                  node.y + d.delta.dy / scale,
                );
          },
          onPanEnd: (_) => ref
              .read(networkControllerProvider.notifier)
              .endNodeDragWithSnap(id, snapWorld),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  /// A larger accented endpoint handle for a selected run: live drag moves the
  /// endpoint node; drag-end snaps/merges it onto a nearby node (connecting the
  /// segment to a fitting). Keeps the edge selected.
  Widget _resizeHandle(WidgetRef ref, String nodeId, String edgeId,
      Offset screen, double scale, double snapWorld) {
    const r = 9.0;
    return Positioned(
      left: screen.dx - r,
      top: screen.dy - r,
      width: r * 2,
      height: r * 2,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeUpLeftDownRight,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) =>
              ref.read(networkControllerProvider.notifier).pushUndoSnapshot(),
          onPanUpdate: (d) {
            final node =
                ref.read(networkControllerProvider).network.nodeById(nodeId);
            if (node == null) return;
            ref.read(networkControllerProvider.notifier).moveNode(
                  nodeId,
                  node.x + d.delta.dx / scale,
                  node.y + d.delta.dy / scale,
                );
          },
          onPanEnd: (_) {
            ref
                .read(networkControllerProvider.notifier)
                .endNodeDragWithSnap(nodeId, snapWorld);
            // Keep the (still-present) edge selected after a snap/merge.
            if (ref.read(networkControllerProvider).network.edges
                .any((e) => e.id == edgeId)) {
              ref.read(selectionProvider.notifier).selectEdge(edgeId);
            }
          },
          child: Center(
            child: Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: Color(0xFF4C8DFF),
                shape: BoxShape.circle,
                border: Border.fromBorderSide(
                    BorderSide(color: Color(0xFFFFFFFF), width: 1.5)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tapLayer(BuildContext context, WidgetRef ref, Network net,
      ViewportTransform transform, SelectionController sel) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: (details) {
        final world = transform.screenToWorld(details.localPosition);
        final node = _nodeAt(net, transform, world);
        if (node != null) {
          sel.selectNode(node);
          return;
        }
        final edge = _edgeAt(net, transform, world);
        if (edge != null) {
          sel.selectEdge(edge);
        } else {
          sel.clear();
        }
      },
      // Right-click an edge → custom MechXTheme context menu (size / material /
      // delete). A right-click on empty space just clears the selection.
      onSecondaryTapUp: (details) {
        final world = transform.screenToWorld(details.localPosition);
        if (_nodeAt(net, transform, world) != null) return;
        final edge = _edgeAt(net, transform, world);
        if (edge == null) {
          sel.clear();
          return;
        }
        sel.selectEdge(edge);
        showEdgeContextMenu(context, ref, edge, details.globalPosition);
      },
      child: const SizedBox.expand(),
    );
  }

  /// Nearest node id on this floor within the node hit radius, or null.
  String? _nodeAt(Network net, ViewportTransform transform, Offset world) {
    final nodeHitR = 13 / transform.scale; // ≈13 screen px
    String? node;
    var best = nodeHitR * nodeHitR;
    for (final n in net.nodes) {
      if (!_onFloor(n)) continue;
      final dx = n.x - world.dx;
      final dy = n.y - world.dy;
      final d2 = dx * dx + dy * dy;
      if (d2 <= best) {
        best = d2;
        node = n.id;
      }
    }
    return node;
  }

  /// Nearest edge id within the edge hit radius (runs by segment distance,
  /// risers by their endpoint marker), or null.
  String? _edgeAt(Network net, ViewportTransform transform, Offset world) {
    final edgeHitR = 8 / transform.scale;
    String? edge;
    var best = edgeHitR;
    for (final e in net.edges) {
      final a = net.nodeById(e.fromId);
      final b = net.nodeById(e.toId);
      if (a == null || b == null) continue;
      if (e.kind == EdgeKind.run) {
        if (!_onFloor(a) || !_onFloor(b)) continue;
        final d = _distToSegment(world, Offset(a.x, a.y), Offset(b.x, b.y));
        if (d <= best) {
          best = d;
          edge = e.id;
        }
      } else {
        for (final n in [a, b]) {
          if (!_onFloor(n)) continue;
          final d = (Offset(n.x, n.y) - world).distance;
          if (d <= best) {
            best = d;
            edge = e.id;
          }
        }
      }
    }
    return edge;
  }
}

/// Shortest distance from [p] to the segment [a]–[b] (world units).
double _distToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final lenSq = ab.dx * ab.dx + ab.dy * ab.dy;
  if (lenSq == 0) return (p - a).distance;
  var t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / lenSq;
  t = t.clamp(0.0, 1.0);
  final proj = Offset(a.dx + t * ab.dx, a.dy + t * ab.dy);
  return math.sqrt(
      (p.dx - proj.dx) * (p.dx - proj.dx) + (p.dy - proj.dy) * (p.dy - proj.dy));
}
