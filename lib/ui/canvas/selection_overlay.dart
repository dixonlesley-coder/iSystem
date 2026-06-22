import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

import '../../store/network_store.dart';
import '../../store/selection_store.dart';
import '../../store/sheets_store.dart';
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

    // On-floor node drag handles (opaque, small) sit above the translucent tap
    // layer: dragging a handle moves the node; tapping it selects it; anywhere
    // else, the tap layer selects/clears and drags fall through to canvas pan.
    final handles = <Widget>[
      for (final n in net.nodes)
        if (_onFloor(n))
          _dragHandle(ref, n.id, transform.worldToScreen(Offset(n.x, n.y)),
              transform.scale),
    ];

    // Translucent (not opaque) so a tap selects, but drag-pan and scroll-zoom
    // still reach the CanvasView underneath.
    return Stack(
      children: [
        Positioned.fill(child: _tapLayer(net, transform, sel)),
        ...handles,
      ],
    );
  }

  Widget _dragHandle(
      WidgetRef ref, String id, Offset screen, double scale) {
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
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  Widget _tapLayer(Network net, ViewportTransform transform,
      SelectionController sel) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: (details) {
        final world = transform.screenToWorld(details.localPosition);
        final nodeHitR = 13 / transform.scale; // ≈13 screen px
        final edgeHitR = 8 / transform.scale;

        // 1. Nearest node on this floor.
        String? node;
        var bestNode = nodeHitR * nodeHitR;
        for (final n in net.nodes) {
          if (!_onFloor(n)) continue;
          final dx = n.x - world.dx;
          final dy = n.y - world.dy;
          final d2 = dx * dx + dy * dy;
          if (d2 <= bestNode) {
            bestNode = d2;
            node = n.id;
          }
        }
        if (node != null) {
          sel.selectNode(node);
          return;
        }

        // 2. Nearest edge (runs by segment distance; risers by their marker).
        String? edge;
        var bestEdge = edgeHitR;
        for (final e in net.edges) {
          final a = net.nodeById(e.fromId);
          final b = net.nodeById(e.toId);
          if (a == null || b == null) continue;
          if (e.kind == EdgeKind.run) {
            if (!_onFloor(a) || !_onFloor(b)) continue;
            final d = _distToSegment(
                world, Offset(a.x, a.y), Offset(b.x, b.y));
            if (d <= bestEdge) {
              bestEdge = d;
              edge = e.id;
            }
          } else {
            for (final n in [a, b]) {
              if (!_onFloor(n)) continue;
              final d = (Offset(n.x, n.y) - world).distance;
              if (d <= bestEdge) {
                bestEdge = d;
                edge = e.id;
              }
            }
          }
        }
        if (edge != null) {
          sel.selectEdge(edge);
        } else {
          sel.clear();
        }
      },
      child: const SizedBox.expand(),
    );
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
