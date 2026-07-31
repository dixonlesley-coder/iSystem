import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/riser_tags.dart' show fflLabel;
import 'package:mechx_engine/sizing/network_sizing.dart' show EdgeSizing;

import '../../store/app_state.dart' show statusMessageProvider;
import '../../store/inspector_store.dart';
import '../../store/layer_store.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/selection_store.dart';
import '../../store/sheets_store.dart';
import '../../store/sizing_store.dart' show sizingProvider;
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/stepped_value_field.dart';
import 'canvas_grid.dart' show calibratedGridWorldStep;
import 'drawing_overlay.dart' show RubberBandPainter, snapOrTeePoint;
import 'edge_context_menu.dart';
import 'network_layer.dart' show pipeOuterPx;
import 'service_style.dart';
import 'snapping.dart';
import 'underlay_snap_service.dart';
import 'viewport.dart';

/// B28 — a lightweight, LOCAL "something is being dragged on this overlay"
/// signal (node drag, endpoint resize, segment grip, outlet-nub pull, run
/// move, or the marquee), used only to suppress the hover-measurement chip
/// while a gesture is live. `dragSessionProvider` isn't a reliable proxy here
/// (the mechanical canvas never calls its `beginDrag`); this is UI-only —
/// never read by the engine or any sizing path.
final canvasGestureActiveProvider =
    NotifierProvider<CanvasGestureActiveController, bool>(
  CanvasGestureActiveController.new,
);

class CanvasGestureActiveController extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) {
    if (state != value) state = value;
  }
}

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
/// pre-made segments. The one exception is a **free run endpoint** (a bare
/// `main` node at the loose end of a single run): there the on-node grip
/// STRETCHES instead — grabbing the point drags it to EXTEND/TRIM the run (the
/// CAD stretch-grip convention) rather than pulling a new branch out of it.
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

  /// B10: the UNSNAPPED world position accumulated over a single-node drag —
  /// the ortho snap is applied to this (a degree-1 node), never to the
  /// already-snapped node position. Null at rest / during a group drag.
  Offset? _nodeDragRaw;

  /// B28 — the hover-measurement-chip debounce: true once the CURRENT hover
  /// target has been stable for the wait window, so the chip may show. Reset
  /// (and re-timed) on every hover-target change via the [ref.listen] in
  /// [build]; never true while nothing is hovered.
  bool _hoverChipDue = false;
  Timer? _hoverChipTimer;

  @override
  void dispose() {
    _hoverChipTimer?.cancel();
    super.dispose();
  }

  bool _onFloor(NetNode n) => n.sheetId == sheetId && n.floorIndex == floorIndex;

  /// World position of the SOLE neighbour of a DEGREE-1 node — the anchor for
  /// the ortho constraint on a plain node drag. Null when the node has 0 or
  /// >= 2 incident edges (a junction drag stays free — snapping one edge would
  /// un-straighten the other) or the neighbour is missing.
  Offset? _singleNeighbourOf(Network net, String nodeId) {
    String? otherId;
    var count = 0;
    for (final e in net.edges) {
      if (e.fromId == nodeId) {
        otherId = e.toId;
        count++;
      } else if (e.toId == nodeId) {
        otherId = e.fromId;
        count++;
      }
      if (count > 1) return null;
    }
    if (count != 1 || otherId == null) return null;
    final other = net.nodeById(otherId);
    return other == null ? null : Offset(other.x, other.y);
  }

  /// Whether [nodeId] is the FREE END of exactly one run — a bare `main` node
  /// (no equipment component) with a single incident edge, and that edge is a
  /// run ([EdgeKind.run]). Dragging such a loose endpoint should EXTEND/TRIM the
  /// run (MOVE the node) rather than pull a NEW mainline out of it, so its grip
  /// stretches instead of spawning a branch. A riser end (its incident edge is a
  /// riser), a mid-run / branch junction (degree >= 2), a lone dropped fitting
  /// (degree 0, still a bootstrap pull point), and any plant / equipment / valve
  /// node all fall through to the normal pull nub.
  bool _isFreeRunEndpoint(Network net, String nodeId) {
    final node = net.nodeById(nodeId);
    if (node == null || node.role != NodeRole.main || node.component != null) {
      return false;
    }
    EdgeKind? kind;
    var count = 0;
    for (final e in net.edges) {
      if (e.fromId == nodeId || e.toId == nodeId) {
        if (++count > 1) return false;
        kind = e.kind;
      }
    }
    return count == 1 && kind == EdgeKind.run;
  }

  // ── Free-run-endpoint STRETCH (extend/trim) ─────────────────────────────────
  // The on-node grip of a free run endpoint moves the node instead of pulling a
  // new run. These mirror [_dragHandle]'s single-node path (degree-1 ortho
  // against the sole neighbour so the run stays straight; snap/merge onto a
  // nearby fitting + the magnetic grid / plan underlay on release) but are driven
  // by the grip so grabbing a loose end drags it to extend/trim.

  void _beginEndpointStretch(String id) {
    ref.read(canvasGestureActiveProvider.notifier).set(true);
    ref.read(selectionProvider.notifier).selectNode(id);
    ref.read(networkControllerProvider.notifier).pushUndoSnapshot();
    final node = ref.read(networkControllerProvider).network.nodeById(id);
    _nodeDragRaw = node == null ? null : Offset(node.x, node.y);
  }

  void _updateEndpointStretch(String id, double dxWorld, double dyWorld) {
    final net = ref.read(networkControllerProvider).network;
    final node = net.nodeById(id);
    if (node == null) return;
    final raw = (_nodeDragRaw ?? Offset(node.x, node.y)) + Offset(dxWorld, dyWorld);
    _nodeDragRaw = raw;
    // A degree-1 endpoint ortho-snaps (Ortho ^ Shift) against its single
    // neighbour, so a stretch keeps the run straight (extend/trim along axis).
    final effectiveOrtho =
        ref.read(orthoProvider) ^ HardwareKeyboard.instance.isShiftPressed;
    final anchor = _singleNeighbourOf(net, id);
    final target =
        (effectiveOrtho && anchor != null) ? orthoSnap(anchor, raw) : raw;
    ref.read(networkControllerProvider.notifier).moveNode(id, target.dx, target.dy);
  }

  void _endEndpointStretch(String id, double scale, double snapWorld) {
    ref.read(canvasGestureActiveProvider.notifier).set(false);
    _nodeDragRaw = null;
    final gridOrtho =
        ref.read(orthoProvider) ^ HardwareKeyboard.instance.isShiftPressed;
    final gridMpp = ref
        .read(projectControllerProvider)
        .calibrationFor(sheetId)
        ?.metersPerPixel;
    final gridSnap = gridOrtho &&
        gridMpp != null &&
        calibratedGridWorldStep(gridMpp) * scale >= 6.0;
    final anchor =
        _singleNeighbourOf(ref.read(networkControllerProvider).network, id);
    ref.read(networkControllerProvider.notifier).endNodeDragWithSnap(id, snapWorld,
        gridSnap: gridSnap,
        gridMetersPerPixel: gridMpp,
        underlaySnap: underlaySnapFor(ref, sheetId, scale,
            orthoAnchor: gridOrtho ? anchor : null));
  }

  Offset _toLocal(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    return box?.globalToLocal(global) ?? global;
  }

  void _startPull(String nodeId) {
    ref.read(canvasGestureActiveProvider.notifier).set(true);
    setState(() {
      _pullFrom = nodeId;
      _pullNow = null;
    });
  }

  void _updatePull(Offset global) =>
      setState(() => _pullNow = _toLocal(global));

  void _endPull(ViewportTransform transform) {
    final from = _pullFrom;
    final now = _pullNow;
    ref.read(canvasGestureActiveProvider.notifier).set(false);
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
    // when ortho is on, the sheet is calibrated, AND the minor grid is visible
    // at this zoom (so it never snaps to an invisible crossing).
    final gridMpp =
        ref.read(projectControllerProvider).calibrationFor(sheetId)?.metersPerPixel;
    final gridSnap = effectiveOrtho &&
        gridMpp != null &&
        calibratedGridWorldStep(gridMpp) * transform.scale >= 6.0;
    ref
        .read(networkControllerProvider.notifier)
        .drawRunFromNode(from, world,
            snapRadius: snapWorld,
            gridSnap: gridSnap,
            gridMetersPerPixel: gridMpp,
            // B13 — auto-elbow an off-ray snap target so the pulled main lands as
            // an L rather than askew (source node anchors the ray).
            ortho: effectiveOrtho && fromNode != null,
            // B12 — snap the pulled main's far end onto a plan wall / reference
            // line / PDF ink ridge (between node/tee and grid precedence); the
            // source node anchors the ortho ray so the main stays straight.
            underlaySnap: underlaySnapFor(ref, sheetId, transform.scale,
                orthoAnchor: (effectiveOrtho && fromNode != null)
                    ? Offset(fromNode.x, fromNode.y)
                    : null));
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
  /// 'Fire', anything else piped → 'Results' (the plumbing sizing surface; the
  /// design INPUTS moved to the Building page); null (nothing to expand) for a
  /// bare/free node with no service context.
  String? _relevantSectionFor({String? nodeId, String? edgeId}) {
    final net = ref.read(networkControllerProvider).network;
    String? forService(ServiceType s) {
      if (s.regime == FlowRegime.air) return 'HVAC · ducting';
      if (s == ServiceType.fireSprinkler || s == ServiceType.fireHydrant) {
        return 'Fire';
      }
      return 'Results';
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
    final project = ref.watch(projectControllerProvider);
    final calibration = project.calibrationFor(sheetId);

    // B28 — restart the ~500ms hover-measurement-chip debounce whenever the
    // hovered element actually changes (a stable HoverTarget record compares
    // equal, so re-hovering the SAME element never restarts the timer).
    ref.listen<HoverTarget?>(hoverTargetProvider, (previous, next) {
      _hoverChipTimer?.cancel();
      if (_hoverChipDue) setState(() => _hoverChipDue = false);
      final hasTarget = next != null && (next.nodeId != null || next.edgeId != null);
      if (!hasTarget) return;
      _hoverChipTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted) setState(() => _hoverChipDue = true);
      });
    });

    // F1/F4 — services made INERT by a locked reference layer or the per-service
    // view filter: their nodes carry no drag handle / outlet nub and never
    // hit-test, so a faded coordination element is visible-but-inert. Empty by
    // default ⇒ every node handled exactly as before (byte-identical).
    final inert = ref.watch(inertServicesProvider);

    // On-floor node drag handles (opaque, small) sit above the translucent tap
    // layer: dragging a handle moves the node; tapping it selects it; anywhere
    // else, the tap layer selects/clears and drags fall through to canvas pan.
    // Drag-end snaps the node to a nearby node (merge) so a segment endpoint
    // "connects" to a fitting. A node whose every incident edge is inert gets no
    // handle (F1/F4).
    final snapWorld = 14 / transform.scale;
    final handles = <Widget>[
      for (final n in net.nodes)
        if (_onFloor(n) && !_nodeInert(net, n.id, inert))
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
            !_nodeInert(net, n.id, inert) &&
            (n.id == hoveredNodeId ||
                selection.containsNode(n.id) ||
                selection.nodeId == n.id ||
                // B11: keep the nub mounted while ITS pull is active, so the
                // pointer leaving the 18px nub mid-pull never unmounts it (and
                // kills the live pan gesture).
                _pullFrom == n.id))
          _outletNub(n.id, transform.worldToScreen(Offset(n.x, n.y)), transform,
              isHovered: n.id == hoveredNodeId,
              // A free run endpoint's grip stretches (extend/trim) rather than
              // pulling a new mainline out.
              stretch: _isFreeRunEndpoint(net, n.id)),
    ];

    // A selected run's two endpoints get larger, accented resize handles — the
    // direct way to stretch a dropped segment until it snaps to a fitting.
    final resizeHandles = <Widget>[];
    if (selection.isEdge) {
      for (final e in net.edges) {
        if (e.id != selection.edgeId || e.kind != EdgeKind.run) continue;
        // A selected run whose service was just locked/hidden loses its
        // resize handles too (F1/F4).
        if (inert.contains(e.service)) continue;
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

    // B20/B22 — the same selected run also gets a mid-segment drag grip
    // (translate the whole segment along its normal) and, on a calibrated
    // sheet, an inline-editable length label at the midpoint (offset from the
    // grip so the two never overlap).
    Widget? midGrip;
    Widget? runLengthLabel;
    if (selection.isEdge) {
      for (final e in net.edges) {
        if (e.id != selection.edgeId || e.kind != EdgeKind.run) continue;
        if (inert.contains(e.service)) continue;
        final a = net.nodeById(e.fromId);
        final b = net.nodeById(e.toId);
        if (a == null || b == null || !_onFloor(a) || !_onFloor(b)) continue;
        final midWorld = Offset((a.x + b.x) / 2, (a.y + b.y) / 2);
        final midScreen = transform.worldToScreen(midWorld);
        midGrip = _midSegmentGrip(
            e.id, midScreen, transform.scale, Offset(b.x - a.x, b.y - a.y));
        if (calibration != null) {
          final dx = b.x - a.x;
          final dy = b.y - a.y;
          final pixelLen = math.sqrt(dx * dx + dy * dy);
          runLengthLabel = _RunLengthLabel(
            edgeId: e.id,
            screen: midScreen,
            lengthMeters: calibration.lengthForPixels(pixelLen).meters,
            metersPerPixel: calibration.metersPerPixel,
          );
        }
        break;
      }
    }

    // B18/B27 — the armed-mode status pill: which action is armed and how to
    // act on / exit it. Null when nothing is armed (no extra chrome at rest).
    final trimArmed = ref.watch(trimExtendArmedProvider);
    final brushArmed = ref.watch(matchPropertiesArmedProvider);
    String? armedHint;
    if (trimArmed != null) {
      armedHint = context.strings(StringKey.trimExtendArmedHint);
    } else if (brushArmed != null) {
      armedHint = context.strings.format(StringKey.matchPropertiesArmedHint,
          {'service': serviceLabel(brushArmed.service)});
    }

    // B28 — the transient hover-measurement chip: 'DN50 - 3.2 m' on a hovered
    // run, 'FFL +2.70' on a hovered node with an elevation. Suppressed while
    // any gesture on this overlay is live, or an armed mode is active (its own
    // status pill already communicates enough).
    Widget? hoverChip;
    final gestureActive = ref.watch(canvasGestureActiveProvider);
    if (_hoverChipDue && !gestureActive && trimArmed == null && brushArmed == null) {
      final hoveredNode = hover?.nodeId == null ? null : net.nodeById(hover!.nodeId!);
      if (hoveredNode != null && _onFloor(hoveredNode)) {
        final elev = nodeElevation(
            hoveredNode, project.building, ref.watch(mountingProvider));
        hoverChip = _HoverMeasurementChip(
          screen: transform.worldToScreen(Offset(hoveredNode.x, hoveredNode.y)),
          text: fflLabel(elev.meters),
        );
      } else {
        final hoveredEdge = hover?.edgeId == null ? null : net.edgeById(hover!.edgeId!);
        if (hoveredEdge != null && hoveredEdge.kind == EdgeKind.run) {
          final a = net.nodeById(hoveredEdge.fromId);
          final b = net.nodeById(hoveredEdge.toId);
          if (a != null && b != null) {
            final dx = b.x - a.x;
            final dy = b.y - a.y;
            final pixelLen = math.sqrt(dx * dx + dy * dy);
            final s = ref.watch(sizingProvider)[hoveredEdge.id];
            String? sizeLabel;
            if (s != null) {
              if (s.isRectangular) {
                sizeLabel = '${s.width!.inMillimeters.round()}'
                    'x${s.height!.inMillimeters.round()}';
              } else {
                final mm = s.diameter.inMillimeters.round();
                sizeLabel = hoveredEdge.service.regime == FlowRegime.air
                    ? 'Ø$mm'
                    : 'DN$mm';
              }
            }
            final lengthPart = calibration == null
                ? 'set scale'
                : _formatMeters(calibration.lengthForPixels(pixelLen).meters);
            hoverChip = _HoverMeasurementChip(
              screen: transform
                  .worldToScreen(Offset((a.x + b.x) / 2, (a.y + b.y) / 2)),
              text: sizeLabel == null ? lengthPart : '$sizeLabel - $lengthPart',
            );
          }
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
    Offset? pullBend;
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
      // B13 — preview the auto-elbow L when ortho reaches an off-ray snap target
      // (matches the drawRunFromNode commit).
      if (effectiveOrtho && pt != null) {
        final b = orthoElbow(pullPendingWorld, w, pt);
        if (b != null) {
          pullBend = b;
          pullHoverWorld = pt; // close the L at the latched target
        }
      }
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
        ?midGrip,
        ?runLengthLabel,
        if (pullPendingWorld != null && pullHoverWorld != null)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: RubberBandPainter(
                  pending: pullPendingWorld,
                  hover: pullHoverWorld,
                  bend: pullBend,
                  snapScreen: pullSnapScreen,
                  transform: transform,
                  calibration: calibration,
                  color: pullColor,
                  active: true,
                ),
              ),
            ),
          ),
        ?hoverChip,
        if (armedHint != null) _ArmedHintPill(text: armedHint),
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
            ref.read(canvasGestureActiveProvider.notifier).set(true);
            final sel = ref.read(selectionProvider);
            if (!(sel.containsNode(id) && sel.nodeIds.length > 1)) {
              ref.read(selectionProvider.notifier).selectNode(id);
            }
            ref.read(networkControllerProvider.notifier).pushUndoSnapshot();
            // B10: seed the raw-drag tracker (only consumed by the single,
            // degree-1 ortho path below).
            final node =
                ref.read(networkControllerProvider).network.nodeById(id);
            _nodeDragRaw = node == null ? null : Offset(node.x, node.y);
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
            final net = ref.read(networkControllerProvider).network;
            final node = net.nodeById(id);
            if (node == null) return;
            final raw =
                (_nodeDragRaw ?? Offset(node.x, node.y)) + Offset(dx, dy);
            _nodeDragRaw = raw;
            // B10: a DEGREE-1 node ortho-snaps against its single neighbour
            // (Ortho ^ Shift); a degree>=2 junction (no single anchor) or a
            // free orphan drags freely, exactly as before.
            final effectiveOrtho = ref.read(orthoProvider) ^
                HardwareKeyboard.instance.isShiftPressed;
            final anchor = _singleNeighbourOf(net, id);
            final target = (effectiveOrtho && anchor != null)
                ? orthoSnap(anchor, raw)
                : raw;
            ctrl.moveNode(id, target.dx, target.dy);
          },
          onPanEnd: (_) {
            ref.read(canvasGestureActiveProvider.notifier).set(false);
            _nodeDragRaw = null; // B10: end the raw-drag tracking
            final sel = ref.read(selectionProvider);
            // A group move is already committed live over the pushUndoSnapshot
            // baseline (one undo step); only a single-node drag snaps/merges its
            // endpoint onto a nearby fitting.
            if (sel.containsNode(id) && sel.nodeIds.length > 1) return;
            // G2 — a dragged node settles onto the magnetic grid (lowest
            // precedence, after fittings) when ortho is on, the sheet is
            // calibrated, AND the minor grid is visible at this zoom.
            final gridOrtho =
                ref.read(orthoProvider) ^ HardwareKeyboard.instance.isShiftPressed;
            final gridMpp = ref
                .read(projectControllerProvider)
                .calibrationFor(sheetId)
                ?.metersPerPixel;
            final gridSnap = gridOrtho &&
                gridMpp != null &&
                calibratedGridWorldStep(gridMpp) * scale >= 6.0;
            // B12 — a dragged node also settles onto the plan underlay (above the
            // grid). A degree-1 node keeps its ortho anchor so the run stays
            // straight; a junction/orphan drags free (anchor null).
            final anchor = _singleNeighbourOf(
                ref.read(networkControllerProvider).network, id);
            ref.read(networkControllerProvider.notifier).endNodeDragWithSnap(
                id, snapWorld,
                gridSnap: gridSnap,
                gridMetersPerPixel: gridMpp,
                underlaySnap: underlaySnapFor(ref, sheetId, scale,
                    orthoAnchor: gridOrtho ? anchor : null));
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  /// The small accent "outlet" grip that sits ON the node (the CAD endpoint-grip
  /// convention) — drag it to pull a mainline run out of the node. Reports the
  /// pull to the host state, which paints the preview line and lays the run on
  /// release.
  ///
  /// B14: the grip is CONCENTRIC with the node, layered ABOVE the 24px move
  /// handle (r=12 in [_dragHandle]). Hit disambiguation is by radius — this nub
  /// is a small inner box (r=7 ⇒ a ~7 screen-px pull zone) that, being LAST in
  /// the Stack, wins the pointer at the node centre (a pull); a drag started
  /// outside that inner box misses it and falls through to the move handle
  /// behind it (a move). The precise (pull) cursor shows on inner hover while the
  /// surrounding ring keeps the handle's move cursor. [isHovered] drives a subtle
  /// non-idle scale/shadow cue (also shown mid-pull) so the grip visibly reads as
  /// "grabbed" — never painted at rest, so an idle canvas stays byte-identical.
  ///
  /// [stretch] flips the grip's DRAG action from "pull a new mainline out" to
  /// "MOVE this node" (extend/trim the run) — used for a free run endpoint (see
  /// [_isFreeRunEndpoint]); tap-to-select and the right-click menu are unchanged.
  Widget _outletNub(String nodeId, Offset screen, ViewportTransform transform,
      {required bool isHovered, bool stretch = false}) {
    final colors = context.colors;
    const r = 7.0; // inner pull zone: ~7 screen px, inside the 12px move handle
    final pulling = _pullFrom == nodeId;
    final active = isHovered || pulling;
    return Positioned(
      key: ValueKey('outlet-$nodeId'),
      left: screen.dx - r,
      top: screen.dy - r,
      width: r * 2,
      height: r * 2,
      child: MouseRegion(
        // A stretch grip reads as "grab & move" (extend/trim); the pull nub
        // keeps the precise cross-hair of "pull a new line out".
        cursor: stretch ? SystemMouseCursors.move : SystemMouseCursors.precise,
        // Keep this node's hover latched while the pointer is over the grip, so
        // the gated nub (C7) doesn't vanish as the pointer sits on the node.
        onEnter: (_) => ref
            .read(hoverTargetProvider.notifier)
            .set((nodeId: nodeId, edgeId: null)),
        // B11: while a pull is in flight the pointer leaves the nub bounds
        // immediately — DON'T clear the hover latch then (a rebuild would
        // unmount the nub and kill the active pan gesture). The gesture layer
        // re-establishes hover after release.
        onExit: (_) {
          // Keep the hover latch while a pull OR a stretch (_nodeDragRaw set) is
          // live, so leaving the small grip mid-drag doesn't clear the halo /
          // rebuild it away.
          if (_pullFrom != null || _nodeDragRaw != null) return;
          ref.read(hoverTargetProvider.notifier).clear();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // B14: the grip is CONCENTRIC with (and opaque ABOVE) the node's move
          // handle, so once the node is selected the grip owns the pointer at the
          // node centre — it must therefore carry the handle's TAP behaviour too
          // (select + the manual double-click-to-open path), or a second click on
          // a selected node would land on the grip and never reach the handle.
          onTap: () {
            ref.read(selectionProvider.notifier).selectNode(nodeId);
            registerElementTap(screen, nodeId: nodeId);
          },
          onSecondaryTapUp: (d) {
            ref.read(selectionProvider.notifier).selectNode(nodeId);
            showNodeContextMenu(context, ref, nodeId, d.globalPosition);
          },
          // A free run endpoint (stretch) MOVES its node to extend/trim the run;
          // every other node PULLS a new mainline out of the grip.
          onPanStart: stretch
              ? (_) => _beginEndpointStretch(nodeId)
              : (d) {
                  _startPull(nodeId);
                  _updatePull(d.globalPosition);
                },
          onPanUpdate: stretch
              ? (d) => _updateEndpointStretch(nodeId,
                  d.delta.dx / transform.scale, d.delta.dy / transform.scale)
              : (d) => _updatePull(d.globalPosition),
          onPanEnd: stretch
              ? (_) => _endEndpointStretch(
                  nodeId, transform.scale, 14 / transform.scale)
              : (_) => _endPull(transform),
          onPanCancel: stretch
              ? () {
                  ref.read(canvasGestureActiveProvider.notifier).set(false);
                  _nodeDragRaw = null;
                }
              : () {
                  ref.read(canvasGestureActiveProvider.notifier).set(false);
                  setState(() {
                    _pullFrom = null;
                    _pullNow = null;
                  });
                },
          child: Center(
            child: AnimatedContainer(
              duration: MechXMotion.press,
              curve: MechXMotion.standard,
              width: active ? 13 : 11,
              height: active ? 13 : 11,
              decoration: BoxDecoration(
                color: colors.accent,
                shape: BoxShape.circle,
                border: Border.fromBorderSide(
                    BorderSide(color: colors.onAccent, width: 1.5)),
                boxShadow: pulling ? MechXShadow.popover : MechXShadow.card,
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

  /// B20 — the mid-segment drag grip for a selected run: a small square at
  /// the segment's midpoint that translates the WHOLE segment along its
  /// normal.
  Widget _midSegmentGrip(
      String edgeId, Offset screen, double scale, Offset direction) {
    const r = 6.0;
    return Positioned(
      key: ValueKey('midgrip-$edgeId'),
      left: screen.dx - r,
      top: screen.dy - r,
      width: r * 2,
      height: r * 2,
      child: _SegmentGrip(edgeId: edgeId, scale: scale, direction: direction),
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

  /// B10: the UNSNAPPED endpoint world position accumulated over the drag —
  /// the ortho snap is applied to this, never to the already-snapped node
  /// position (which would discard perpendicular motion each frame and stick
  /// the endpoint on its starting ray). Null at rest.
  Offset? _rawWorld;

  /// World position of the run's OTHER endpoint — the anchor the ortho 45°
  /// constraint snaps against; null if the edge/other node is gone.
  Offset? _otherEnd(Network net) {
    final e = net.edgeById(widget.edgeId);
    if (e == null) return null;
    final otherId = e.fromId == widget.nodeId ? e.toId : e.fromId;
    final other = net.nodeById(otherId);
    return other == null ? null : Offset(other.x, other.y);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpLeftDownRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) {
          ref.read(canvasGestureActiveProvider.notifier).set(true);
          setState(() => _pressing = true);
          ref.read(networkControllerProvider.notifier).pushUndoSnapshot();
          final node = ref
              .read(networkControllerProvider)
              .network
              .nodeById(widget.nodeId);
          _rawWorld = node == null ? null : Offset(node.x, node.y);
        },
        onPanUpdate: (d) {
          final net = ref.read(networkControllerProvider).network;
          final node = net.nodeById(widget.nodeId);
          if (node == null) return;
          final raw = (_rawWorld ?? Offset(node.x, node.y)) +
              Offset(d.delta.dx / widget.scale, d.delta.dy / widget.scale);
          _rawWorld = raw;
          // B10: apply the effective-ortho 45° snap (Ortho ^ Shift) against the
          // run's other endpoint, so stretching an endpoint keeps the run
          // straight (matches the nub-pull preview/release).
          final effectiveOrtho = ref.read(orthoProvider) ^
              HardwareKeyboard.instance.isShiftPressed;
          final anchor = _otherEnd(net);
          final target = (effectiveOrtho && anchor != null)
              ? orthoSnap(anchor, raw)
              : raw;
          ref.read(networkControllerProvider.notifier).moveNode(
                widget.nodeId,
                target.dx,
                target.dy,
              );
        },
        onPanEnd: (_) {
          ref.read(canvasGestureActiveProvider.notifier).set(false);
          setState(() => _pressing = false);
          _rawWorld = null;
          // G2 — the resized endpoint also honours the magnetic grid (lowest
          // precedence) when ortho is on, the node's sheet is calibrated, AND
          // the minor grid is visible at this zoom.
          final gridOrtho =
              ref.read(orthoProvider) ^ HardwareKeyboard.instance.isShiftPressed;
          final node =
              ref.read(networkControllerProvider).network.nodeById(widget.nodeId);
          final gridMpp = node == null
              ? null
              : ref
                  .read(projectControllerProvider)
                  .calibrationFor(node.sheetId)
                  ?.metersPerPixel;
          final gridSnap = gridOrtho &&
              gridMpp != null &&
              calibratedGridWorldStep(gridMpp) * widget.scale >= 6.0;
          // B12 — the resized endpoint also snaps onto the plan underlay (above
          // the grid); the run's OTHER endpoint anchors the ortho ray so the run
          // stays straight when Ortho is on.
          final anchor = _otherEnd(
              ref.read(networkControllerProvider).network);
          ref.read(networkControllerProvider.notifier).endNodeDragWithSnap(
              widget.nodeId, widget.snapWorld,
              gridSnap: gridSnap,
              gridMetersPerPixel: gridMpp,
              // B13 — resizing an endpoint onto an off-ray node keeps the run
              // straight: bend on the ray + a short correcting leg (the other
              // endpoint anchors the ray), rather than merging askew.
              orthoAnchor: gridOrtho ? anchor : null,
              underlaySnap: node == null
                  ? null
                  : underlaySnapFor(ref, node.sheetId, widget.scale,
                      orthoAnchor: gridOrtho ? anchor : null));
          // Keep the (still-present) edge selected after a snap/merge.
          if (ref
              .read(networkControllerProvider)
              .network
              .edges
              .any((e) => e.id == widget.edgeId)) {
            ref.read(selectionProvider.notifier).selectEdge(widget.edgeId);
          }
        },
        onPanCancel: () {
          ref.read(canvasGestureActiveProvider.notifier).set(false);
          _rawWorld = null;
          setState(() => _pressing = false);
        },
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

/// B20 — the resize cursor for the mid-segment grip, chosen from the
/// segment's own bearing so the drag direction (its normal) reads correctly:
/// a mostly-horizontal segment perpendicular-drags vertically and vice versa;
/// a diagonal segment picks the matching "/" or "\" resize cursor.
MouseCursor _segmentGripCursor(double dx, double dy) {
  final ax = dx.abs();
  final ay = dy.abs();
  if (ax == 0 && ay == 0) return SystemMouseCursors.move;
  if (ay <= ax * 0.20) return SystemMouseCursors.resizeUpDown;
  if (ax <= ay * 0.20) return SystemMouseCursors.resizeLeftRight;
  return (dx * dy > 0)
      ? SystemMouseCursors.resizeUpRightDownLeft
      : SystemMouseCursors.resizeUpLeftDownRight;
}

/// B20 — the mid-segment drag grip widget: a small square that translates the
/// WHOLE run along its normal (`NetworkController.dragSegment`), stretching
/// any adjacent collinear segments; ortho is preserved by construction (the
/// normal is fixed by the segment's own bearing). One undo step per drag
/// session (`pushUndoSnapshot` at drag start, matching every other live-drag
/// handle in this file).
class _SegmentGrip extends ConsumerStatefulWidget {
  final String edgeId;
  final double scale;

  /// World-space (b - a) direction of the segment; any non-zero magnitude.
  final Offset direction;

  const _SegmentGrip({
    required this.edgeId,
    required this.scale,
    required this.direction,
  });

  @override
  ConsumerState<_SegmentGrip> createState() => _SegmentGripState();
}

class _SegmentGripState extends ConsumerState<_SegmentGrip> {
  bool _pressing = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MouseRegion(
      cursor: _segmentGripCursor(widget.direction.dx, widget.direction.dy),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Right-click the grip like any other point on the run: the edge's
        // own context menu (mirrors the node handles' explicit ownership of
        // their secondary-tap — an opaque Pan-only target left unclaimed
        // would otherwise leave a right-click here ambiguously resolved).
        // E1: preserve a multi-selection the grip's run is already part of,
        // exactly like the gesture layer's own edge right-click.
        onSecondaryTapUp: (d) {
          final sel = ref.read(selectionProvider);
          if (!(sel.containsEdge(widget.edgeId) && sel.edgeIds.length > 1)) {
            ref.read(selectionProvider.notifier).selectEdge(widget.edgeId);
          }
          showEdgeContextMenu(context, ref, widget.edgeId, d.globalPosition);
        },
        onPanStart: (_) {
          ref.read(canvasGestureActiveProvider.notifier).set(true);
          setState(() => _pressing = true);
          ref.read(networkControllerProvider.notifier).pushUndoSnapshot();
        },
        onPanUpdate: (d) => ref
            .read(networkControllerProvider.notifier)
            .dragSegment(widget.edgeId, d.delta / widget.scale),
        onPanEnd: (_) {
          ref.read(canvasGestureActiveProvider.notifier).set(false);
          setState(() => _pressing = false);
        },
        onPanCancel: () {
          ref.read(canvasGestureActiveProvider.notifier).set(false);
          setState(() => _pressing = false);
        },
        child: Center(
          child: AnimatedContainer(
            duration: MechXMotion.press,
            curve: MechXMotion.standard,
            width: _pressing ? 11 : 9,
            height: _pressing ? 11 : 9,
            decoration: BoxDecoration(
              color: colors.accent,
              borderRadius: MechXRadii.small,
              border: Border.fromBorderSide(
                  BorderSide(color: colors.onAccent, width: 1.5)),
              boxShadow: _pressing ? MechXShadow.popover : MechXShadow.card,
            ),
          ),
        ),
      ),
    );
  }
}

/// B22 — the calibrated length label at a selected run's midpoint: reading it
/// shows the run's current length; clicking it (the shared `SteppedValueField`
/// inline-edit idiom) opens a numeric field. Committing — or the +/- glyphs —
/// moves the run's free endpoint via `NetworkController.setRunLength`; Esc
/// cancels (the field's own local Escape handler). Only rendered on a
/// calibrated sheet (nothing meaningful to type otherwise).
class _RunLengthLabel extends ConsumerWidget {
  final String edgeId;
  final Offset screen;
  final double lengthMeters;
  final double metersPerPixel;

  const _RunLengthLabel({
    required this.edgeId,
    required this.screen,
    required this.lengthMeters,
    required this.metersPerPixel,
  });

  /// The run's CURRENT length, read fresh from the live network (not a
  /// captured build-time value) so repeated +/- taps — which may fire faster
  /// than a rebuild — always nudge from the real current length.
  double? _liveLengthMeters(WidgetRef ref) {
    final net = ref.read(networkControllerProvider).network;
    final e = net.edgeById(edgeId);
    if (e == null) return null;
    final a = net.nodeById(e.fromId);
    final b = net.nodeById(e.toId);
    if (a == null || b == null) return null;
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    return math.sqrt(dx * dx + dy * dy) * metersPerPixel;
  }

  void _nudge(WidgetRef ref, double deltaMeters) {
    final cur = _liveLengthMeters(ref);
    if (cur == null) return;
    final next = cur + deltaMeters;
    if (next <= 0) return;
    ref
        .read(networkControllerProvider.notifier)
        .setRunLength(edgeId, next, metersPerPixel);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final display = _formatMeters(lengthMeters);
    return Positioned(
      left: screen.dx,
      top: screen.dy + 10,
      child: FractionalTranslation(
        translation: const Offset(-0.5, 0),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: MechXSpacing.xs,
            vertical: MechXSpacing.xxs,
          ),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: MechXRadii.control,
            border: Border.all(color: colors.border),
            boxShadow: MechXShadow.card,
          ),
          child: SteppedValueField(
            display: display,
            editSeed: lengthMeters.toStringAsFixed(2),
            label: context.strings(StringKey.a11yFieldRunLength),
            gap: MechXSpacing.xxs,
            valueAlign: TextAlign.center,
            min: 0.05,
            onDecrement: () => _nudge(ref, -0.1),
            onIncrement: () => _nudge(ref, 0.1),
            onSubmit: (v) {
              if (v != null && v > 0) {
                ref
                    .read(networkControllerProvider.notifier)
                    .setRunLength(edgeId, v, metersPerPixel);
              }
            },
          ),
        ),
      ),
    );
  }
}

/// Formats a length in metres the way the run tools do: 1 decimal >= 10 m,
/// else 2.
String _formatMeters(double m) =>
    m >= 10 ? '${m.toStringAsFixed(1)} m' : '${m.toStringAsFixed(2)} m';

/// B18/B27 — the armed-mode status pill (top-centre, mirroring the F5 armed-
/// placement hint): names which action is armed and how to act on / exit it.
class _ArmedHintPill extends StatelessWidget {
  final String text;
  const _ArmedHintPill({required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Positioned(
      top: MechXSpacing.md + 40,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.sm + 2,
              vertical: MechXSpacing.xs + 1,
            ),
            decoration: BoxDecoration(
              color: colors.surface.withAlpha(240),
              borderRadius: MechXRadii.control,
              border: Border.all(color: colors.accent),
              boxShadow: MechXShadow.card,
            ),
            child:
                Text(text, style: type.label.copyWith(color: colors.textPrimary)),
          ),
        ),
      ),
    );
  }
}

/// B28 — the transient hover-measurement chip (a run's size + length, or a
/// node's FFL), positioned at the hovered element's screen anchor. Pointer-
/// transparent so it never steals the hover that spawned it.
class _HoverMeasurementChip extends StatelessWidget {
  final Offset screen;
  final String text;
  const _HoverMeasurementChip({required this.screen, required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Positioned(
      left: screen.dx,
      top: screen.dy,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -1.6),
        child: IgnorePointer(
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.sm,
              vertical: MechXSpacing.xxs,
            ),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: MechXRadii.control,
              border: Border.all(color: colors.border),
              boxShadow: MechXShadow.popover,
            ),
            child: Text(text, style: type.caption.copyWith(color: colors.textPrimary)),
          ),
        ),
      ),
    );
  }
}

/// Whether [n] lives on this sheet/floor.
bool _isOnFloor(NetNode n, String sheetId, int floorIndex) =>
    n.sheetId == sheetId && n.floorIndex == floorIndex;

/// F1/F4 — whether a node is INERT to canvas interaction: it has at least one
/// incident edge AND every incident edge's service is in [inert] (a locked
/// reference layer's service or an individually hidden one). A node touched by
/// any active/visible edge, or a free (unwired) node, is NOT inert — so a
/// coordination pipe becomes visible-but-inert without stranding loose
/// equipment. Empty [inert] ⇒ always false (byte-identical, zero extra cost).
bool _nodeInert(Network net, String nodeId, Set<ServiceType> inert) {
  if (inert.isEmpty) return false;
  var touched = false;
  for (final e in net.edges) {
    if (e.fromId != nodeId && e.toId != nodeId) continue;
    touched = true;
    if (!inert.contains(e.service)) return false;
  }
  return touched;
}

/// Nearest node id on this floor within the node hit radius, or null. [inert]
/// services (F1 locked layer / F4 hidden) are skipped so a faded coordination
/// element can't be clicked.
String? _nodeAt(Network net, ViewportTransform transform, Offset world,
    String sheetId, int floorIndex,
    {Set<ServiceType> inertServices = const {}}) {
  final nodeHitR = 13 / transform.scale; // ≈13 screen px
  String? node;
  var best = nodeHitR * nodeHitR;
  for (final n in net.nodes) {
    if (!_isOnFloor(n, sheetId, floorIndex)) continue;
    if (_nodeInert(net, n.id, inertServices)) continue;
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
///
/// B5: a RUN's clickable corridor tracks the true-width rendered pipe/duct
/// body ([pipeOuterPx] — the SAME formula the painter draws, via [sizing] +
/// [metersPerPixel]) instead of staying a fixed ~8px hairline once a
/// calibrated duct/pipe renders up to 120 screen px wide — `max(8px,
/// renderedHalfWidth + 4px)` so a fat duct is clickable across its visible
/// body. An unsized/uncalibrated run still resolves to the original 8px band
/// (byte-identical). Riser endpoint-marker hit-testing is unaffected.
String? _edgeAt(Network net, ViewportTransform transform, Offset world,
    String sheetId, int floorIndex,
    {Map<String, EdgeSizing>? sizing,
    double? metersPerPixel,
    Set<ServiceType> inertServices = const {}}) {
  final riserHitR = 8 / transform.scale;
  String? edge;
  var bestDist = double.infinity;
  for (final e in net.edges) {
    // F1/F4 — a locked-layer / hidden-service edge is inert to clicks.
    if (inertServices.contains(e.service)) continue;
    final a = net.nodeById(e.fromId);
    final b = net.nodeById(e.toId);
    if (a == null || b == null) continue;
    if (e.kind == EdgeKind.run) {
      if (!_isOnFloor(a, sheetId, floorIndex) ||
          !_isOnFloor(b, sheetId, floorIndex)) {
        continue;
      }
      final outer = pipeOuterPx(sizing?[e.id], e.service,
          scale: transform.scale, metersPerPixel: metersPerPixel);
      final edgeHitR = math.max(8.0, outer / 2 + 4.0) / transform.scale;
      final d = _distToSegment(world, Offset(a.x, a.y), Offset(b.x, b.y));
      if (d <= edgeHitR && d < bestDist) {
        bestDist = d;
        edge = e.id;
      }
    } else {
      for (final n in [a, b]) {
        if (!_isOnFloor(n, sheetId, floorIndex)) continue;
        final d = (Offset(n.x, n.y) - world).distance;
        if (d <= riserHitR && d < bestDist) {
          bestDist = d;
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

  /// B18/B27 — Esc cancels an armed boundary pick / match-properties brush
  /// from anywhere (no text field needs to hold focus for it). A plain
  /// `HardwareKeyboard` handler mirrors the app shell's own global-shortcut
  /// mechanism (`app_shell.dart`) rather than stealing Flutter focus.
  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    var handled = false;
    if (ref.read(matchPropertiesArmedProvider) != null) {
      ref.read(matchPropertiesArmedProvider.notifier).disarm();
      handled = true;
    }
    if (ref.read(trimExtendArmedProvider) != null) {
      ref.read(trimExtendArmedProvider.notifier).disarm();
      handled = true;
    }
    return handled;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    super.dispose();
  }

  /// B5: the live sizing map + this sheet's calibration, read fresh at each
  /// gesture (not watched) so `_edgeAt`'s hit corridor matches what the
  /// painter currently draws without adding a rebuild dependency here.
  Map<String, EdgeSizing> get _sizing => ref.read(sizingProvider);
  double? get _mpp => ref
      .read(projectControllerProvider)
      .calibrationFor(_sheetId)
      ?.metersPerPixel;

  /// F1/F4 — the services currently inert to canvas interaction (locked layer /
  /// hidden service), read fresh at each gesture. Empty ⇒ byte-identical.
  Set<ServiceType> get _inert => ref.read(inertServicesProvider);

  @override
  Widget build(BuildContext context) {
    final transform = ref.watch(sheetsControllerProvider).viewportFor(_sheetId) ??
        const ViewportTransform();
    // B18/B27 — an armed boundary pick or match-properties brush swaps the
    // cursor to a crosshair, mirroring the CAD "something is armed" cue.
    final trimArmed = ref.watch(trimExtendArmedProvider);
    final brushArmed = ref.watch(matchPropertiesArmedProvider);
    final armedCursor = (trimArmed != null || brushArmed != null)
        ? SystemMouseCursors.precise
        : MouseCursor.defer;

    return MouseRegion(
      opaque: false,
      cursor: armedCursor,
      // Hover pre-highlight (detection half): publish the element under the
      // cursor so the network painter can halo it. Notifies only on CHANGE and
      // clears on exit, so an untouched canvas is byte-identical.
      onHover: (e) {
        final net = ref.read(networkControllerProvider).network;
        final world = transform.screenToWorld(e.localPosition);
        final node = _nodeAt(net, transform, world, _sheetId, _floor,
            inertServices: _inert);
        final edge = node == null
            ? _edgeAt(net, transform, world, _sheetId, _floor,
                sizing: _sizing, metersPerPixel: _mpp, inertServices: _inert)
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
        // B27 — an armed match-properties brush: a click on a run applies the
        // captured source's size/material/service (same discipline family
        // only); a miss (empty space / a node) is ignored and the brush stays
        // armed for the next click.
        final brush = ref.read(matchPropertiesArmedProvider);
        if (brush != null) {
          final edgeHit = _edgeAt(net, transform, world, _sheetId, _floor,
              sizing: _sizing, metersPerPixel: _mpp, inertServices: _inert);
          if (edgeHit != null && edgeHit != brush.sourceEdgeId) {
            final target = net.edgeById(edgeHit);
            if (target != null && target.kind == EdgeKind.run) {
              applyMatchProperties(
                  ref.read(networkControllerProvider.notifier), brush, target);
            }
          }
          return;
        }
        // B18 — an armed 'Trim/Extend to...' boundary pick: the NEXT click on
        // a run resolves the pick (success or refusal both disarm — it is a
        // single pick, not a repeating brush); a miss keeps it armed.
        final trim = ref.read(trimExtendArmedProvider);
        if (trim != null) {
          final edgeHit = _edgeAt(net, transform, world, _sheetId, _floor,
              sizing: _sizing, metersPerPixel: _mpp, inertServices: _inert);
          if (edgeHit != null) {
            ref.read(trimExtendArmedProvider.notifier).disarm();
            final ok = ref
                .read(networkControllerProvider.notifier)
                .trimExtendEdge(trim.edgeId, trim.endNodeId, edgeHit);
            if (!ok) {
              ref.read(statusMessageProvider.notifier).showStatus(
                  context.strings(StringKey.trimExtendNoIntersection));
            }
          }
          return;
        }
        final node = _nodeAt(net, transform, world, _sheetId, _floor,
            inertServices: _inert);
        if (node != null) {
          if (shift) {
            sel.toggleNode(node);
          } else {
            sel.selectNode(node);
            widget.host.registerElementTap(details.localPosition, nodeId: node);
          }
          return;
        }
        final edge = _edgeAt(net, transform, world, _sheetId, _floor,
            sizing: _sizing, metersPerPixel: _mpp, inertServices: _inert);
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
        // B18/B27 — a right-click while a boundary pick / brush is armed
        // disarms it instead of opening a context menu (the F5 armed-
        // placement convention).
        if (ref.read(trimExtendArmedProvider) != null ||
            ref.read(matchPropertiesArmedProvider) != null) {
          ref.read(trimExtendArmedProvider.notifier).disarm();
          ref.read(matchPropertiesArmedProvider.notifier).disarm();
          return;
        }
        final net = ref.read(networkControllerProvider).network;
        final sel = ref.read(selectionProvider.notifier);
        final world = transform.screenToWorld(details.localPosition);
        final nodeId = _nodeAt(net, transform, world, _sheetId, _floor,
            inertServices: _inert);
        if (nodeId != null) {
          // ANY node gets a menu: fitting rows for a bare junction, the face
          // ladder for an air terminal, Select similar + Delete for all. F2:
          // right-clicking a node that's part of a MULTI-selection keeps the
          // whole set alive (mirroring E1 for edges) so the menu can rotate /
          // mirror / delete the group; an unselected node collapses to just it.
          final current = ref.read(selectionProvider);
          if (!(current.containsNode(nodeId) && current.isMulti)) {
            sel.selectNode(nodeId);
          }
          showNodeContextMenu(context, ref, nodeId, details.globalPosition);
          return;
        }
        final edge = _edgeAt(net, transform, world, _sheetId, _floor,
            sizing: _sizing, metersPerPixel: _mpp, inertServices: _inert);
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
        showEdgeContextMenu(context, ref, edge, details.globalPosition,
            world: world);
      },
      // Left-drag routing:
      //  • on a RUN's BODY (no-Shift)  → MOVE that run (G5, below);
      //  • over EMPTY space, or with Shift → rubber-band marquee;
      //  • on a node / a run's ENDPOINT → owned by the opaque handle above, so
      //    this layer never sees the drag (node-move / endpoint resize-snap).
      // Canvas pan is still available via middle-drag.
      onPanStart: (details) {
        // B18/B27 — while a boundary pick / brush is armed, a drag is a no-op
        // (armed mode only reacts to plain clicks via onTapUp above); this
        // keeps a click-drag jitter from moving a run or opening a marquee.
        if (ref.read(trimExtendArmedProvider) != null ||
            ref.read(matchPropertiesArmedProvider) != null) {
          return;
        }
        final net = ref.read(networkControllerProvider).network;
        final world = transform.screenToWorld(details.localPosition);
        final nodeHit = _nodeAt(net, transform, world, _sheetId, _floor,
            inertServices: _inert);
        final edgeHit = nodeHit == null
            ? _edgeAt(net, transform, world, _sheetId, _floor,
                sizing: _sizing, metersPerPixel: _mpp, inertServices: _inert)
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
            ref.read(canvasGestureActiveProvider.notifier).set(true);
            ref.read(networkControllerProvider.notifier).pushUndoSnapshot();
            setState(() => _runMoveNodes = movers);
            return;
          }
        }
        final overEmpty = nodeHit == null && edgeHit == null;
        if (overEmpty || shift) {
          ref.read(canvasGestureActiveProvider.notifier).set(true);
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
        ref.read(canvasGestureActiveProvider.notifier).set(false);
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
        ref.read(canvasGestureActiveProvider.notifier).set(false);
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
        // B26 — AutoCAD-style direction-sensitive marquee: dragging LEFT-TO-
        // RIGHT on screen is a WINDOW (only elements fully enclosed by the
        // rect qualify, matching the pre-existing behaviour); dragging RIGHT-
        // TO-LEFT is a CROSSING (anything the rect merely TOUCHES qualifies —
        // any node inside it, or a run with at least one endpoint inside it).
        // A dead-even drag (same x) counts as a window (ties favour the
        // stricter, pre-existing behaviour).
        final windowMode = now.dx >= start.dx;
        final net = ref.read(networkControllerProvider).network;
        final a = transform.screenToWorld(start);
        final b = transform.screenToWorld(now);
        final rect = Rect.fromPoints(a, b);
        final inert = _inert;
        final nodeIds = <String>{};
        for (final n in net.nodes) {
          if (!_isOnFloor(n, _sheetId, _floor)) continue;
          // F1/F4 — a rubber-band never grabs a locked-layer / hidden-service
          // node (parity with tap-select).
          if (_nodeInert(net, n.id, inert)) continue;
          if (rect.contains(Offset(n.x, n.y))) nodeIds.add(n.id);
        }
        // A run edge is captured when BOTH endpoints fall inside the rect
        // (window) or AT LEAST ONE does (crossing).
        final edgeIds = <String>{};
        for (final e in net.edges) {
          if (e.kind != EdgeKind.run) continue;
          // F1/F4 — a rubber-band never grabs a locked-layer / hidden-service
          // run, even when both endpoints are shared with visible edges and
          // thus land in nodeIds (parity with _edgeAt tap-select).
          if (inert.contains(e.service)) continue;
          final fromIn = nodeIds.contains(e.fromId);
          final toIn = nodeIds.contains(e.toId);
          if (windowMode ? (fromIn && toIn) : (fromIn || toIn)) {
            edgeIds.add(e.id);
          }
        }
        final sel = ref.read(selectionProvider.notifier);
        additive ? sel.addMulti(nodeIds, edgeIds) : sel.setMulti(nodeIds, edgeIds);
      },
      child: CustomPaint(
        size: Size.infinite,
        painter: _MarqueePainter(
          start: _bandStart,
          now: _bandNow,
          accent: context.colors.accent,
          // B26 — the live preview reads the same direction the release will
          // commit with, so the border style (solid vs dashed) is an honest
          // preview of window-vs-crossing while still dragging.
          windowMode: _bandStart == null ||
              _bandNow == null ||
              _bandNow!.dx >= _bandStart!.dx,
        ),
        child: const SizedBox.expand(),
      ),
      ),
    );
  }
}

/// Paints the translucent rubber-band rectangle (screen space) while dragging.
/// B26: [windowMode] draws a SOLID border (left-to-right drag — a window,
/// fully-enclosed-only); false draws a DASHED border (right-to-left — a
/// crossing, touch-selects), the AutoCAD muscle-memory convention.
class _MarqueePainter extends CustomPainter {
  final Offset? start;
  final Offset? now;
  final Color accent;
  final bool windowMode;

  _MarqueePainter({
    required this.start,
    required this.now,
    required this.accent,
    this.windowMode = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (start == null || now == null) return;
    final rect = Rect.fromPoints(start!, now!);
    canvas.drawRect(rect, Paint()..color = accent.withAlpha(38));
    final border = Paint()
      ..color = accent
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    if (windowMode) {
      canvas.drawRect(rect, border);
    } else {
      _drawDashedRect(canvas, rect, border);
    }
  }

  /// A dashed rectangle outline (Canvas has no built-in dashed stroke): walk
  /// each of the 4 sides in fixed on/off increments.
  void _drawDashedRect(Canvas canvas, Rect rect, Paint paint) {
    const dash = 5.0;
    const gap = 3.0;
    void dashedLine(Offset a, Offset b) {
      final total = (b - a).distance;
      if (total == 0) return;
      final dir = (b - a) / total;
      var walked = 0.0;
      while (walked < total) {
        final segEnd = math.min(walked + dash, total);
        canvas.drawLine(a + dir * walked, a + dir * segEnd, paint);
        walked += dash + gap;
      }
    }

    dashedLine(rect.topLeft, rect.topRight);
    dashedLine(rect.topRight, rect.bottomRight);
    dashedLine(rect.bottomRight, rect.bottomLeft);
    dashedLine(rect.bottomLeft, rect.topLeft);
  }

  @override
  bool shouldRepaint(_MarqueePainter old) =>
      old.start != start ||
      old.now != now ||
      old.accent != accent ||
      old.windowMode != windowMode;
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
