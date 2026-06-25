import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

import '../../store/network_store.dart';
import '../../store/selection_store.dart';
import '../../store/sheets_store.dart';
import '../theme/design_tokens.dart';
import 'edge_context_menu.dart';
import 'viewport.dart';

/// Accent used for the rubber-band marquee fill/stroke (matches the drawing
/// overlay's band painter + the selection highlight).
const Color _kBand = Color(0xFF4C8DFF);

/// Interaction layer active while the Select tool is chosen: a tap picks the
/// nearest node (then edge) on this floor and writes it to [selectionProvider];
/// a plain tap on empty space clears the selection; a Shift-tap toggles an
/// element in/out of the multi-selection. A left-drag STARTING OVER EMPTY SPACE
/// (or with Shift held) draws a rubber-band marquee that multi-selects every
/// on-floor node + run edge inside it. (Canvas panning still works via
/// middle-drag; only empty-space left-drag is repurposed as the marquee.)
///
/// Every non-fixture node (riser / fitting / plant) also carries a small
/// **outlet nub**: dragging a line out of it LAYS A MAINLINE RUN to where you
/// release (snapping to a node, tapping into an existing main, or a fresh
/// junction) — so mains are drawn by pulling out of a riser, not by dropping
/// pre-made segments.
class NetworkSelectionOverlay extends ConsumerStatefulWidget {
  final String sheetId;
  final int floorIndex;

  const NetworkSelectionOverlay({
    super.key,
    required this.sheetId,
    required this.floorIndex,
  });

  @override
  ConsumerState<NetworkSelectionOverlay> createState() =>
      _NetworkSelectionOverlayState();
}

class _NetworkSelectionOverlayState
    extends ConsumerState<NetworkSelectionOverlay> {
  String get sheetId => widget.sheetId;
  int get floorIndex => widget.floorIndex;

  /// While pulling a main out of a node: the source node id and the current
  /// pointer position (local to this overlay, screen px). Null when idle.
  String? _pullFrom;
  Offset? _pullNow;

  bool _onFloor(NetNode n) => n.sheetId == sheetId && n.floorIndex == floorIndex;

  Offset _toLocal(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    return box?.globalToLocal(global) ?? global;
  }

  void _startPull(String nodeId) => setState(() {
        _pullFrom = nodeId;
        _pullNow = null;
      });

  void _updatePull(Offset global) =>
      setState(() => _pullNow = _toLocal(global));

  void _endPull(ViewportTransform transform) {
    final from = _pullFrom;
    final now = _pullNow;
    setState(() {
      _pullFrom = null;
      _pullNow = null;
    });
    if (from == null || now == null) return;
    final world = transform.screenToWorld(now);
    final snapWorld = 14 / transform.scale;
    ref
        .read(networkControllerProvider.notifier)
        .drawRunFromNode(from, world, snapRadius: snapWorld);
  }

  @override
  Widget build(BuildContext context) {
    final net = ref.watch(networkControllerProvider).network;
    final transform =
        ref.watch(sheetsControllerProvider).viewportFor(sheetId) ??
            const ViewportTransform();
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

    // Outlet nubs — one per non-fixture node (mains/plant/risers, the sources a
    // mainline is pulled out of). Sit above the move handle so a drag from the
    // nub lays a run rather than moving the node.
    final outlets = <Widget>[
      for (final n in net.nodes)
        if (_onFloor(n) && n.role != NodeRole.fixture)
          _outletNub(n.id, transform.worldToScreen(Offset(n.x, n.y)), transform),
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

    // The live "pull a main out of here" preview line, node → cursor.
    final pullNode =
        _pullFrom == null ? null : net.nodeById(_pullFrom!);
    final pullFromScreen = pullNode == null
        ? null
        : transform.worldToScreen(Offset(pullNode.x, pullNode.y));

    // Translucent (not opaque) so a tap selects, but drag-pan and scroll-zoom
    // still reach the CanvasView underneath.
    return Stack(
      children: [
        Positioned.fill(
          child: _SelectionGestureLayer(
            sheetId: sheetId,
            floorIndex: floorIndex,
          ),
        ),
        ...handles,
        ...outlets,
        ...resizeHandles,
        if (pullFromScreen != null && _pullNow != null)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _PullPainter(from: pullFromScreen, to: _pullNow!),
              ),
            ),
          ),
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

  /// The small accent "outlet" nub offset up-right of a node — drag it to pull a
  /// mainline run out of the node. Reports the pull to the host state, which
  /// paints the preview line and lays the run on release.
  Widget _outletNub(String nodeId, Offset screen, ViewportTransform transform) {
    const off = 15.0; // up-right of the node, clear of the move handle
    const r = 9.0;
    return Positioned(
      left: screen.dx + off - r,
      top: screen.dy - off - r,
      width: r * 2,
      height: r * 2,
      child: MouseRegion(
        cursor: SystemMouseCursors.precise,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) {
            _startPull(nodeId);
            _updatePull(d.globalPosition);
          },
          onPanUpdate: (d) => _updatePull(d.globalPosition),
          onPanEnd: (_) => _endPull(transform),
          onPanCancel: () => setState(() {
            _pullFrom = null;
            _pullNow = null;
          }),
          child: Center(
            child: Container(
              width: 11,
              height: 11,
              decoration: const BoxDecoration(
                color: _kBand,
                shape: BoxShape.circle,
                border: Border.fromBorderSide(
                    BorderSide(color: Color(0xFFFFFFFF), width: 1.5)),
                boxShadow: [
                  BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 3,
                      offset: Offset(0, 1)),
                ],
              ),
            ),
          ),
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
      child: _ResizeHandle(
        nodeId: nodeId,
        edgeId: edgeId,
        scale: scale,
        snapWorld: snapWorld,
      ),
    );
  }
}

/// Paints the live preview line while a mainline run is being pulled out of a
/// node — a dashed accent line from the source node to the cursor, with a small
/// target ring at the release end.
class _PullPainter extends CustomPainter {
  final Offset from;
  final Offset to;

  _PullPainter({required this.from, required this.to});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = _kBand
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    // A dashed line so the in-progress run reads as a preview, not committed.
    const dash = 7.0, gap = 5.0;
    final dir = to - from;
    final len = dir.distance;
    if (len > 0.0) {
      final unit = dir / len;
      var d = 0.0;
      while (d < len) {
        final a = from + unit * d;
        final b = from + unit * math.min(d + dash, len);
        canvas.drawLine(a, b, paint);
        d += dash + gap;
      }
    }
    canvas.drawCircle(to, 4, paint);
  }

  @override
  bool shouldRepaint(_PullPainter old) => old.from != from || old.to != to;
}

/// The draggable endpoint dot for a selected run. Tracks its own press state so
/// it scales down a touch (with a deeper shadow) on grab — a tactile "I've got
/// it" cue — then settles back on release. Press feedback is transient motion;
/// the at-rest dot is identical to before.
class _ResizeHandle extends ConsumerStatefulWidget {
  final String nodeId;
  final String edgeId;
  final double scale;
  final double snapWorld;

  const _ResizeHandle({
    required this.nodeId,
    required this.edgeId,
    required this.scale,
    required this.snapWorld,
  });

  @override
  ConsumerState<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends ConsumerState<_ResizeHandle> {
  bool _pressing = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpLeftDownRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) {
          setState(() => _pressing = true);
          ref.read(networkControllerProvider.notifier).pushUndoSnapshot();
        },
        onPanUpdate: (d) {
          final node = ref
              .read(networkControllerProvider)
              .network
              .nodeById(widget.nodeId);
          if (node == null) return;
          ref.read(networkControllerProvider.notifier).moveNode(
                widget.nodeId,
                node.x + d.delta.dx / widget.scale,
                node.y + d.delta.dy / widget.scale,
              );
        },
        onPanEnd: (_) {
          setState(() => _pressing = false);
          ref
              .read(networkControllerProvider.notifier)
              .endNodeDragWithSnap(widget.nodeId, widget.snapWorld);
          // Keep the (still-present) edge selected after a snap/merge.
          if (ref
              .read(networkControllerProvider)
              .network
              .edges
              .any((e) => e.id == widget.edgeId)) {
            ref.read(selectionProvider.notifier).selectEdge(widget.edgeId);
          }
        },
        onPanCancel: () => setState(() => _pressing = false),
        child: Center(
          child: AnimatedScale(
            scale: _pressing ? 0.85 : 1.0,
            duration: MechXMotion.press,
            curve: MechXMotion.standard,
            child: AnimatedContainer(
              duration: MechXMotion.press,
              curve: MechXMotion.standard,
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: const Color(0xFF4C8DFF),
                shape: BoxShape.circle,
                border: const Border.fromBorderSide(
                    BorderSide(color: Color(0xFFFFFFFF), width: 1.5)),
                // Shadow only while grabbed (at rest it matches the original
                // flat dot, so no static pixel change).
                boxShadow: _pressing
                    ? const [
                        BoxShadow(
                          color: Color(0x55000000),
                          blurRadius: 6,
                          offset: Offset(0, 1),
                        ),
                      ]
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Whether [n] lives on this sheet/floor.
bool _isOnFloor(NetNode n, String sheetId, int floorIndex) =>
    n.sheetId == sheetId && n.floorIndex == floorIndex;

/// Nearest node id on this floor within the node hit radius, or null.
String? _nodeAt(Network net, ViewportTransform transform, Offset world,
    String sheetId, int floorIndex) {
  final nodeHitR = 13 / transform.scale; // ≈13 screen px
  String? node;
  var best = nodeHitR * nodeHitR;
  for (final n in net.nodes) {
    if (!_isOnFloor(n, sheetId, floorIndex)) continue;
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
String? _edgeAt(Network net, ViewportTransform transform, Offset world,
    String sheetId, int floorIndex) {
  final edgeHitR = 8 / transform.scale;
  String? edge;
  var best = edgeHitR;
  for (final e in net.edges) {
    final a = net.nodeById(e.fromId);
    final b = net.nodeById(e.toId);
    if (a == null || b == null) continue;
    if (e.kind == EdgeKind.run) {
      if (!_isOnFloor(a, sheetId, floorIndex) ||
          !_isOnFloor(b, sheetId, floorIndex)) {
        continue;
      }
      final d = _distToSegment(world, Offset(a.x, a.y), Offset(b.x, b.y));
      if (d <= best) {
        best = d;
        edge = e.id;
      }
    } else {
      for (final n in [a, b]) {
        if (!_isOnFloor(n, sheetId, floorIndex)) continue;
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

/// The tap + secondary-tap + rubber-band marquee gesture layer. Translucent so
/// scroll-zoom + middle-drag pan still reach the CanvasView beneath; a left-drag
/// starting over empty space (or with Shift) draws the marquee.
class _SelectionGestureLayer extends ConsumerStatefulWidget {
  final String sheetId;
  final int floorIndex;

  const _SelectionGestureLayer({
    required this.sheetId,
    required this.floorIndex,
  });

  @override
  ConsumerState<_SelectionGestureLayer> createState() =>
      _SelectionGestureLayerState();
}

class _SelectionGestureLayerState
    extends ConsumerState<_SelectionGestureLayer> {
  /// The marquee anchor + current corner in screen px while dragging, else null.
  Offset? _bandStart;
  Offset? _bandNow;

  String get _sheetId => widget.sheetId;
  int get _floor => widget.floorIndex;

  @override
  Widget build(BuildContext context) {
    final transform = ref.watch(sheetsControllerProvider).viewportFor(_sheetId) ??
        const ViewportTransform();

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: (details) {
        final net = ref.read(networkControllerProvider).network;
        final sel = ref.read(selectionProvider.notifier);
        final shift = HardwareKeyboard.instance.isShiftPressed;
        final world = transform.screenToWorld(details.localPosition);
        final node = _nodeAt(net, transform, world, _sheetId, _floor);
        if (node != null) {
          shift ? sel.toggleNode(node) : sel.selectNode(node);
          return;
        }
        final edge = _edgeAt(net, transform, world, _sheetId, _floor);
        if (edge != null) {
          shift ? sel.toggleEdge(edge) : sel.selectEdge(edge);
        } else if (!shift) {
          sel.clear();
        }
      },
      // Right-click an edge → custom MechXTheme context menu (size / material /
      // delete). A right-click on empty space just clears the selection.
      onSecondaryTapUp: (details) {
        final net = ref.read(networkControllerProvider).network;
        final sel = ref.read(selectionProvider.notifier);
        final world = transform.screenToWorld(details.localPosition);
        if (_nodeAt(net, transform, world, _sheetId, _floor) != null) return;
        final edge = _edgeAt(net, transform, world, _sheetId, _floor);
        if (edge == null) {
          sel.clear();
          return;
        }
        sel.selectEdge(edge);
        showEdgeContextMenu(context, ref, edge, details.globalPosition);
      },
      // Rubber-band marquee — only starts over EMPTY space (or with Shift), so a
      // left-drag on a populated area doesn't accidentally marquee. Canvas pan is
      // still available via middle-drag.
      onPanStart: (details) {
        final net = ref.read(networkControllerProvider).network;
        final world = transform.screenToWorld(details.localPosition);
        final overEmpty =
            _nodeAt(net, transform, world, _sheetId, _floor) == null &&
                _edgeAt(net, transform, world, _sheetId, _floor) == null;
        if (overEmpty || HardwareKeyboard.instance.isShiftPressed) {
          setState(() {
            _bandStart = details.localPosition;
            _bandNow = details.localPosition;
          });
        }
      },
      onPanUpdate: (details) {
        if (_bandStart == null) return;
        setState(() => _bandNow = details.localPosition);
      },
      onPanEnd: (_) {
        final start = _bandStart;
        final now = _bandNow;
        setState(() {
          _bandStart = null;
          _bandNow = null;
        });
        if (start == null || now == null) return;
        final net = ref.read(networkControllerProvider).network;
        final a = transform.screenToWorld(start);
        final b = transform.screenToWorld(now);
        final rect = Rect.fromPoints(a, b);
        final nodeIds = <String>{};
        for (final n in net.nodes) {
          if (!_isOnFloor(n, _sheetId, _floor)) continue;
          if (rect.contains(Offset(n.x, n.y))) nodeIds.add(n.id);
        }
        // A run edge is captured when BOTH endpoints fall inside the rect.
        final edgeIds = <String>{};
        for (final e in net.edges) {
          if (e.kind != EdgeKind.run) continue;
          if (nodeIds.contains(e.fromId) && nodeIds.contains(e.toId)) {
            edgeIds.add(e.id);
          }
        }
        ref.read(selectionProvider.notifier).setMulti(nodeIds, edgeIds);
      },
      child: CustomPaint(
        size: Size.infinite,
        painter: _MarqueePainter(start: _bandStart, now: _bandNow),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Paints the translucent rubber-band rectangle (screen space) while dragging.
class _MarqueePainter extends CustomPainter {
  final Offset? start;
  final Offset? now;

  _MarqueePainter({required this.start, required this.now});

  @override
  void paint(Canvas canvas, Size size) {
    if (start == null || now == null) return;
    final rect = Rect.fromPoints(start!, now!);
    canvas.drawRect(rect, Paint()..color = _kBand.withAlpha(38));
    canvas.drawRect(
      rect,
      Paint()
        ..color = _kBand
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_MarqueePainter old) =>
      old.start != start || old.now != now;
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
