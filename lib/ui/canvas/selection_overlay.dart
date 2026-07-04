import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

import '../../store/inspector_store.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/selection_store.dart';
import '../../store/sheets_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'drawing_overlay.dart' show RubberBandPainter, snapOrTeePoint;
import 'edge_context_menu.dart';
import 'service_style.dart';
import 'snapping.dart';
import 'viewport.dart';

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

  /// Optional "Fit view" action for the empty-canvas context menu — the host
  /// (which owns the live [CanvasView] handle) passes it; null hides the row.
  final VoidCallback? onFitView;

  const NetworkSelectionOverlay({
    super.key,
    required this.sheetId,
    required this.floorIndex,
    this.onFitView,
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
    final net = ref.read(networkControllerProvider).network;
    final fromNode = net.nodeById(from);
    var world = transform.screenToWorld(now);
    // C5: apply the ortho constraint the preview showed (Shift overrides), so a
    // nub-drawn main lands straight rather than slightly askew.
    final effectiveOrtho =
        ref.read(orthoProvider) ^ HardwareKeyboard.instance.isShiftPressed;
    if (effectiveOrtho && fromNode != null) {
      world = orthoSnap(Offset(fromNode.x, fromNode.y), world);
    }
    final snapWorld = 14 / transform.scale;
    // G2 — a nub-pulled main also honours the magnetic grid (lowest precedence)
    // when ortho/grid is on and the sheet is calibrated.
    final gridMpp = effectiveOrtho
        ? ref.read(projectControllerProvider).calibrationFor(sheetId)?.metersPerPixel
        : null;
    ref
        .read(networkControllerProvider.notifier)
        .drawRunFromNode(from, world,
            snapRadius: snapWorld,
            gridSnap: effectiveOrtho,
            gridMetersPerPixel: gridMpp);
  }

  // ── Double-click → open in the inspector ────────────────────────────────────

  /// Manual double-click tracking (last primary-tap time/place/target), shared
  /// by the gesture layer (edges / ring taps) AND the node drag handles (which
  /// sit above it and own taps on nodes). A GestureDetector double-tap
  /// recognizer would delay every single tap by the disambiguation timeout, so
  /// the second click is detected by hand: the first click selects instantly,
  /// and a second click on the SAME element within [kDoubleTapTimeout] opens
  /// it in the inspector.
  DateTime? _lastTapTime;
  Offset? _lastTapPos;
  String? _lastTapNodeId;
  String? _lastTapEdgeId;

  /// Register a primary tap on a node/edge at overlay-local [local]; a second
  /// tap on the same element close in time + place opens the inspector.
  void registerElementTap(Offset local, {String? nodeId, String? edgeId}) {
    final now = DateTime.now();
    final isDouble = _lastTapTime != null &&
        now.difference(_lastTapTime!) <= kDoubleTapTimeout &&
        _lastTapPos != null &&
        (local - _lastTapPos!).distance <= 24 &&
        _lastTapNodeId == nodeId &&
        _lastTapEdgeId == edgeId;
    if (isDouble) {
      resetTapTracking();
      _openInspectorFor(nodeId: nodeId, edgeId: edgeId);
      return;
    }
    _lastTapTime = now;
    _lastTapPos = local;
    _lastTapNodeId = nodeId;
    _lastTapEdgeId = edgeId;
  }

  /// Forget the last tap (an empty-space tap never opens anything).
  void resetTapTracking() {
    _lastTapTime = null;
    _lastTapPos = null;
    _lastTapNodeId = null;
    _lastTapEdgeId = null;
  }

  /// Double-click "opens the thing": un-collapse the inspector column and
  /// expand the discipline-relevant sizing section (the pinned Selection
  /// editor at the top of the panel already shows the picked element).
  void _openInspectorFor({String? nodeId, String? edgeId}) {
    ref.read(inspectorCollapsedProvider.notifier).set(false);
    final name = _relevantSectionFor(nodeId: nodeId, edgeId: edgeId);
    if (name != null) {
      ref.read(sectionVisibilityProvider.notifier).set(name, true);
    }
  }

  /// The [DisclosureSection] name most relevant to the element (must match the
  /// section names in `project_panel.dart`): air → 'HVAC · ducting', fire →
  /// 'Fire', anything else piped → 'Design inputs'; null (nothing to expand)
  /// for a bare/free node with no service context.
  String? _relevantSectionFor({String? nodeId, String? edgeId}) {
    final net = ref.read(networkControllerProvider).network;
    String? forService(ServiceType s) {
      if (s.regime == FlowRegime.air) return 'HVAC · ducting';
      if (s == ServiceType.fireSprinkler || s == ServiceType.fireHydrant) {
        return 'Fire';
      }
      return 'Design inputs';
    }

    if (edgeId != null) {
      final e = net.edgeById(edgeId);
      return e == null ? null : forService(e.service);
    }
    if (nodeId != null) {
      final n = net.nodeById(nodeId);
      if (n == null) return null;
      // An air terminal is HVAC regardless of wiring.
      if (n.airflow != null ||
          n.component == NodeComponent.supplyDiffuser ||
          n.component == NodeComponent.returnGrille ||
          n.component == NodeComponent.exhaustGrille ||
          n.component == NodeComponent.linearDiffuser) {
        return 'HVAC · ducting';
      }
      for (final e in net.edges) {
        if (e.fromId == nodeId || e.toId == nodeId) {
          return forService(e.service);
        }
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final drawing = ref.watch(networkControllerProvider);
    final net = drawing.network;
    final transform =
        ref.watch(sheetsControllerProvider).viewportFor(sheetId) ??
            const ViewportTransform();
    final selection = ref.watch(selectionProvider);
    final hover = ref.watch(hoverTargetProvider);
    final calibration =
        ref.watch(projectControllerProvider).calibrationFor(sheetId);

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

    // Outlet nubs — the accent handle a mainline is pulled out of. C7: gated to
    // the HOVERED and SELECTED non-fixture nodes only (not every node always),
    // so a dense plan isn't peppered with blue confetti competing with the
    // selection language.
    final hoveredNodeId = hover?.nodeId;
    final outlets = <Widget>[
      for (final n in net.nodes)
        if (_onFloor(n) &&
            n.role != NodeRole.fixture &&
            (n.id == hoveredNodeId ||
                selection.containsNode(n.id) ||
                selection.nodeId == n.id))
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

    // The live "pull a main out of here" preview — C5: reuse the shared
    // rubber-band painter so it carries the LIVE calibrated length chip + the
    // snap/tee ring (parity with the Run tool), instead of a bare dashed line.
    final pullNode =
        _pullFrom == null ? null : net.nodeById(_pullFrom!);
    Offset? pullPendingWorld;
    Offset? pullHoverWorld;
    Offset? pullSnapScreen;
    var pullColor = context.colors.accent;
    if (pullNode != null && _pullNow != null) {
      pullPendingWorld = Offset(pullNode.x, pullNode.y);
      var w = transform.screenToWorld(_pullNow!);
      final effectiveOrtho =
          ref.watch(orthoProvider) ^ HardwareKeyboard.instance.isShiftPressed;
      if (effectiveOrtho) w = orthoSnap(pullPendingWorld, w);
      pullHoverWorld = w;
      // The run inherits the source node's existing service (else the active
      // draw service) — colour the preview to match, like drawRunFromNode.
      ServiceType? incident;
      for (final e in net.edges) {
        if (e.fromId == pullNode.id || e.toId == pullNode.id) {
          incident = e.service;
          break;
        }
      }
      pullColor = serviceColor(incident ?? drawing.service);
      final pt = snapOrTeePoint(net, sheetId, floorIndex, w, snapWorld);
      pullSnapScreen = pt == null ? null : transform.worldToScreen(pt);
    }

    // Translucent (not opaque) so a tap selects, but drag-pan and scroll-zoom
    // still reach the CanvasView underneath.
    return Stack(
      children: [
        Positioned.fill(
          child: _SelectionGestureLayer(
            sheetId: sheetId,
            floorIndex: floorIndex,
            onFitView: widget.onFitView,
            host: this,
          ),
        ),
        ...handles,
        ...outlets,
        ...resizeHandles,
        if (pullPendingWorld != null && pullHoverWorld != null)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: RubberBandPainter(
                  pending: pullPendingWorld,
                  hover: pullHoverWorld,
                  snapScreen: pullSnapScreen,
                  transform: transform,
                  calibration: calibration,
                  color: pullColor,
                  active: true,
                ),
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
        // The opaque handle owns the pointer over a node, so it publishes the
        // hover pre-highlight (the gesture layer below never sees it).
        onEnter: (_) => ref
            .read(hoverTargetProvider.notifier)
            .set((nodeId: id, edgeId: null)),
        onExit: (_) => ref.read(hoverTargetProvider.notifier).clear(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            ref.read(selectionProvider.notifier).selectNode(id);
            // Second click on the same node within the double-tap window opens
            // the inspector (see [registerElementTap]).
            registerElementTap(screen, nodeId: id);
          },
          // Right-click ANY node → its context menu (fitting rows for a bare
          // junction, the face ladder for an air terminal, Select similar +
          // Delete for all) — the handle owns the pointer over the node.
          onSecondaryTapUp: (d) {
            ref.read(selectionProvider.notifier).selectNode(id);
            showNodeContextMenu(context, ref, id, d.globalPosition);
          },
          // E2: when the dragged node is part of a MULTI-selection, KEEP the
          // selection and move the whole group by one delta (moveMany) instead
          // of collapsing to this node and moving it alone. One drag = one undo
          // step, paired with pushUndoSnapshot exactly like the single-node drag.
          onPanStart: (_) {
            final sel = ref.read(selectionProvider);
            if (!(sel.containsNode(id) && sel.nodeIds.length > 1)) {
              ref.read(selectionProvider.notifier).selectNode(id);
            }
            ref.read(networkControllerProvider.notifier).pushUndoSnapshot();
          },
          onPanUpdate: (d) {
            final sel = ref.read(selectionProvider);
            final ctrl = ref.read(networkControllerProvider.notifier);
            final dx = d.delta.dx / scale;
            final dy = d.delta.dy / scale;
            if (sel.containsNode(id) && sel.nodeIds.length > 1) {
              ctrl.moveMany(sel.nodeIds, dx, dy);
              return;
            }
            final node =
                ref.read(networkControllerProvider).network.nodeById(id);
            if (node == null) return;
            ctrl.moveNode(id, node.x + dx, node.y + dy);
          },
          onPanEnd: (_) {
            final sel = ref.read(selectionProvider);
            // A group move is already committed live over the pushUndoSnapshot
            // baseline (one undo step); only a single-node drag snaps/merges its
            // endpoint onto a nearby fitting.
            if (sel.containsNode(id) && sel.nodeIds.length > 1) return;
            // G2 — a dragged node settles onto the magnetic grid (lowest
            // precedence, after fittings) when ortho/grid is on + calibrated.
            final gridOrtho =
                ref.read(orthoProvider) ^ HardwareKeyboard.instance.isShiftPressed;
            final gridMpp = gridOrtho
                ? ref
                    .read(projectControllerProvider)
                    .calibrationFor(sheetId)
                    ?.metersPerPixel
                : null;
            ref.read(networkControllerProvider.notifier).endNodeDragWithSnap(
                id, snapWorld,
                gridSnap: gridOrtho, gridMetersPerPixel: gridMpp);
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  /// The small accent "outlet" nub offset up-right of a node — drag it to pull a
  /// mainline run out of the node. Reports the pull to the host state, which
  /// paints the preview line and lays the run on release.
  Widget _outletNub(String nodeId, Offset screen, ViewportTransform transform) {
    final colors = context.colors;
    const off = 15.0; // up-right of the node, clear of the move handle
    const r = 9.0;
    return Positioned(
      key: ValueKey('outlet-$nodeId'),
      left: screen.dx + off - r,
      top: screen.dy - off - r,
      width: r * 2,
      height: r * 2,
      child: MouseRegion(
        cursor: SystemMouseCursors.precise,
        // Keep this node's hover latched while the pointer is over the nub, so
        // the gated nub (C7) doesn't vanish as you move OFF the node's drag
        // handle to reach for it (the nub sits up-right of the node).
        onEnter: (_) => ref
            .read(hoverTargetProvider.notifier)
            .set((nodeId: nodeId, edgeId: null)),
        onExit: (_) => ref.read(hoverTargetProvider.notifier).clear(),
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
              decoration: BoxDecoration(
                color: colors.accent,
                shape: BoxShape.circle,
                border: Border.fromBorderSide(
                    BorderSide(color: colors.onAccent, width: 1.5)),
                boxShadow: MechXShadow.card,
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
    final colors = context.colors;
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
          // G2 — the resized endpoint also honours the magnetic grid (lowest
          // precedence) when ortho/grid is on + the node's sheet is calibrated.
          final gridOrtho =
              ref.read(orthoProvider) ^ HardwareKeyboard.instance.isShiftPressed;
          final node =
              ref.read(networkControllerProvider).network.nodeById(widget.nodeId);
          final gridMpp = (gridOrtho && node != null)
              ? ref
                  .read(projectControllerProvider)
                  .calibrationFor(node.sheetId)
                  ?.metersPerPixel
              : null;
          ref.read(networkControllerProvider.notifier).endNodeDragWithSnap(
              widget.nodeId, widget.snapWorld,
              gridSnap: gridOrtho, gridMetersPerPixel: gridMpp);
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
                color: colors.accent,
                shape: BoxShape.circle,
                border: Border.fromBorderSide(
                    BorderSide(color: colors.onAccent, width: 1.5)),
                // Shadow only while grabbed (at rest it matches the original
                // flat dot, so no static pixel change).
                boxShadow: _pressing ? MechXShadow.popover : null,
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
  final VoidCallback? onFitView;

  /// The owning overlay state — carries the shared double-click tracker (the
  /// node drag handles above this layer feed the same tracker).
  final _NetworkSelectionOverlayState host;

  const _SelectionGestureLayer({
    required this.sheetId,
    required this.floorIndex,
    required this.host,
    this.onFitView,
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

  /// Whether Shift was held when the marquee STARTED — a Shift-marquee UNIONS
  /// its result into the current selection instead of replacing it.
  bool _bandAdditive = false;

  /// G5: while dragging a RUN by its BODY, the set of node ids being translated
  /// (the run's two endpoints, or — when the run is part of a multi-selection —
  /// every selected node plus every selected run's endpoints). Non-null means
  /// this left-drag is a run move, not a marquee. Null at rest, so an idle
  /// canvas is byte-identical.
  Set<String>? _runMoveNodes;

  String get _sheetId => widget.sheetId;
  int get _floor => widget.floorIndex;

  @override
  Widget build(BuildContext context) {
    final transform = ref.watch(sheetsControllerProvider).viewportFor(_sheetId) ??
        const ViewportTransform();

    return MouseRegion(
      opaque: false,
      // Hover pre-highlight (detection half): publish the element under the
      // cursor so the network painter can halo it. Notifies only on CHANGE and
      // clears on exit, so an untouched canvas is byte-identical.
      onHover: (e) {
        final net = ref.read(networkControllerProvider).network;
        final world = transform.screenToWorld(e.localPosition);
        final node = _nodeAt(net, transform, world, _sheetId, _floor);
        final edge = node == null
            ? _edgeAt(net, transform, world, _sheetId, _floor)
            : null;
        ref.read(hoverTargetProvider.notifier).set(
            node == null && edge == null
                ? null
                : (nodeId: node, edgeId: edge));
      },
      onExit: (_) => ref.read(hoverTargetProvider.notifier).clear(),
      child: GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: (details) {
        final net = ref.read(networkControllerProvider).network;
        final sel = ref.read(selectionProvider.notifier);
        final shift = HardwareKeyboard.instance.isShiftPressed;
        final world = transform.screenToWorld(details.localPosition);
        final node = _nodeAt(net, transform, world, _sheetId, _floor);
        if (node != null) {
          if (shift) {
            sel.toggleNode(node);
          } else {
            sel.selectNode(node);
            widget.host.registerElementTap(details.localPosition, nodeId: node);
          }
          return;
        }
        final edge = _edgeAt(net, transform, world, _sheetId, _floor);
        if (edge != null) {
          if (shift) {
            sel.toggleEdge(edge);
          } else {
            sel.selectEdge(edge);
            widget.host.registerElementTap(details.localPosition, edgeId: edge);
          }
        } else if (!shift) {
          sel.clear();
          // An empty-space tap resets the double-click tracker (never opens).
          widget.host.resetTapTracking();
        }
      },
      // Right-click a node/edge → custom MechXTheme context menu; a right-click
      // on empty space opens the canvas menu (Paste here / Select all / Fit).
      onSecondaryTapUp: (details) {
        final net = ref.read(networkControllerProvider).network;
        final sel = ref.read(selectionProvider.notifier);
        final world = transform.screenToWorld(details.localPosition);
        final nodeId = _nodeAt(net, transform, world, _sheetId, _floor);
        if (nodeId != null) {
          // ANY node gets a menu: fitting rows for a bare junction, the face
          // ladder for an air terminal, Select similar + Delete for all.
          sel.selectNode(nodeId);
          showNodeContextMenu(context, ref, nodeId, details.globalPosition);
          return;
        }
        final edge = _edgeAt(net, transform, world, _sheetId, _floor);
        if (edge == null) {
          sel.clear();
          showCanvasContextMenu(
            context,
            ref,
            details.globalPosition,
            world: world,
            sheetId: _sheetId,
            floorIndex: _floor,
            onFitView: widget.onFitView,
          );
          return;
        }
        // E1: right-clicking an edge that's part of a MULTI-selection keeps the
        // selection intact, so the menu can batch-apply to the whole set; a
        // right-click on an unselected edge selects just that one as before.
        final current = ref.read(selectionProvider);
        if (!(current.containsEdge(edge) && current.edgeIds.length > 1)) {
          sel.selectEdge(edge);
        }
        showEdgeContextMenu(context, ref, edge, details.globalPosition);
      },
      // Left-drag routing:
      //  • on a RUN's BODY (no-Shift)  → MOVE that run (G5, below);
      //  • over EMPTY space, or with Shift → rubber-band marquee;
      //  • on a node / a run's ENDPOINT → owned by the opaque handle above, so
      //    this layer never sees the drag (node-move / endpoint resize-snap).
      // Canvas pan is still available via middle-drag.
      onPanStart: (details) {
        final net = ref.read(networkControllerProvider).network;
        final world = transform.screenToWorld(details.localPosition);
        final nodeHit = _nodeAt(net, transform, world, _sheetId, _floor);
        final edgeHit = nodeHit == null
            ? _edgeAt(net, transform, world, _sheetId, _floor)
            : null;
        final shift = HardwareKeyboard.instance.isShiftPressed;
        // G5: a plain (no-Shift) left-drag starting on a RUN's BODY moves that
        // run — translate its two endpoint nodes (mirroring the node-move
        // gesture: pushUndoSnapshot at start, live moveMany, one undo step). A
        // drag on a run's ENDPOINT is a node/resize drag owned by the handle
        // above; a Shift-drag always marquees; both bypass this branch.
        if (!shift && nodeHit == null && edgeHit != null) {
          final e = net.edgeById(edgeHit);
          if (e != null && e.kind == EdgeKind.run) {
            final sel = ref.read(selectionProvider);
            final partOfMulti = sel.containsEdge(edgeHit) &&
                (sel.nodeIds.length + sel.edgeIds.length) > 1;
            if (!partOfMulti) {
              // Not part of a multi-selection → collapse to just this run
              // (mirrors the node handle's E2 group-vs-single decision).
              ref.read(selectionProvider.notifier).selectEdge(edgeHit);
            }
            // The nodes to translate: the whole selection when this run is part
            // of a multi-selection (every picked node + every selected run's
            // endpoints), else just this run's two endpoints.
            final movers = <String>{};
            if (partOfMulti) {
              movers.addAll(sel.nodeIds);
              for (final eid in sel.edgeIds) {
                final se = net.edgeById(eid);
                if (se != null) {
                  movers.add(se.fromId);
                  movers.add(se.toId);
                }
              }
            } else {
              movers.add(e.fromId);
              movers.add(e.toId);
            }
            ref.read(networkControllerProvider.notifier).pushUndoSnapshot();
            setState(() => _runMoveNodes = movers);
            return;
          }
        }
        final overEmpty = nodeHit == null && edgeHit == null;
        if (overEmpty || shift) {
          setState(() {
            _bandStart = details.localPosition;
            _bandNow = details.localPosition;
            _bandAdditive = shift;
          });
        }
      },
      onPanUpdate: (details) {
        // G5: a run move translates its node set live over the drag-start
        // snapshot (no marquee, no per-frame setState — moveMany drives the
        // repaint through the network provider).
        final movers = _runMoveNodes;
        if (movers != null) {
          ref.read(networkControllerProvider.notifier).moveMany(
                movers,
                details.delta.dx / transform.scale,
                details.delta.dy / transform.scale,
              );
          return;
        }
        if (_bandStart == null) return;
        setState(() => _bandNow = details.localPosition);
      },
      onPanCancel: () {
        // Clear any in-flight drag state (a cancelled run move keeps its live
        // translation + the recorded undo step, exactly like a cancelled
        // node/group drag — Ctrl+Z reverts it).
        if (_runMoveNodes != null || _bandStart != null) {
          setState(() {
            _runMoveNodes = null;
            _bandStart = null;
            _bandNow = null;
            _bandAdditive = false;
          });
        }
      },
      onPanEnd: (_) {
        // G5: a run/group move is already committed live over the
        // pushUndoSnapshot baseline (one undo step); nothing to snap on release
        // (mirrors the node handle's group-move path).
        if (_runMoveNodes != null) {
          setState(() => _runMoveNodes = null);
          return;
        }
        final start = _bandStart;
        final now = _bandNow;
        // Shift held at EITHER end of the drag makes the marquee additive.
        final additive =
            _bandAdditive || HardwareKeyboard.instance.isShiftPressed;
        setState(() {
          _bandStart = null;
          _bandNow = null;
          _bandAdditive = false;
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
        final sel = ref.read(selectionProvider.notifier);
        additive ? sel.addMulti(nodeIds, edgeIds) : sel.setMulti(nodeIds, edgeIds);
      },
      child: CustomPaint(
        size: Size.infinite,
        painter: _MarqueePainter(
            start: _bandStart, now: _bandNow, accent: context.colors.accent),
        child: const SizedBox.expand(),
      ),
      ),
    );
  }
}

/// Paints the translucent rubber-band rectangle (screen space) while dragging.
class _MarqueePainter extends CustomPainter {
  final Offset? start;
  final Offset? now;
  final Color accent;

  _MarqueePainter({required this.start, required this.now, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    if (start == null || now == null) return;
    final rect = Rect.fromPoints(start!, now!);
    canvas.drawRect(rect, Paint()..color = accent.withAlpha(38));
    canvas.drawRect(
      rect,
      Paint()
        ..color = accent
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_MarqueePainter old) =>
      old.start != start || old.now != now || old.accent != accent;
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
