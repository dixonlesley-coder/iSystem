import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

import '../../store/app_state.dart';
import '../../store/layer_store.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/route_geometry.dart';
import '../../store/sheets_store.dart';
import '../../store/smart_input_store.dart';
import '../../store/reference_line_store.dart';
import '../../store/snap_settings_store.dart';
import '../strings/app_strings.dart';
import 'canvas_grid.dart' show calibratedGridWorldStep, nearestGridIntersection;
import 'service_style.dart';
import 'snapping.dart';
import 'underlay_snap_service.dart';
import 'viewport.dart';

/// Interaction layer active while a draw tool is selected. Maps taps to
/// sheet/world coordinates (via the live viewport), places run points / risers,
/// and shows a rubber-band preview from the pending point to the cursor with
/// the LIVE calibrated run length (the primary gesture gets the same feedback
/// immediacy the Measure tool already has) and a snap ring over the node the
/// next click would land on (mirrors the palette drop preview). A
/// secondary-click finishes the run (first click ends the pending chain, a
/// second returns to Select) — the CAD right-click-to-finish convention.
///
/// It also carries the draw-time CAD affordances (all gesture-time only, so an
/// idle canvas is byte-identical):
///   * B17 — two-click ORTHO ROUTING: with ortho on (Shift off), the second
///     click auto-routes an L/Z between the two points ([orthoRoute]); Tab
///     cycles the leg order; a tiny mode chip rides the head.
///   * B21 — a cursor-following polar readout ('3.24 m @ 45', or 'NNN px' when
///     uncalibrated).
///   * B29 — a live invert-level line ('IL -0.42') on gravity services.
///   * B23 — smart alignment guides (dashed lines through an aligned node).
///   * B24 — the OSNAP marker vocabulary (square / triangle / x / perp foot).
///   * B25 — Alt parallel-offset lock onto a reference line.
///   * B30 — auto-pan when the cursor reaches the viewport edge band.
class DrawingOverlay extends ConsumerStatefulWidget {
  final String sheetId;
  final int floorIndex;
  final int levelCount;

  const DrawingOverlay({
    super.key,
    required this.sheetId,
    required this.floorIndex,
    required this.levelCount,
  });

  @override
  ConsumerState<DrawingOverlay> createState() => _DrawingOverlayState();
}

class _DrawingOverlayState extends ConsumerState<DrawingOverlay> {
  Offset? _hoverWorld;

  /// The B30 auto-pan probe notifier, captured in [build] so [deactivate] can
  /// clear it without touching `ref` during teardown (a finished run unmounts
  /// this overlay — the probe must not stay latched and keep the canvas panning).
  CanvasAutoPanController? _autoPan;

  // ── The resolved commit decision, computed each build from the live hover so
  //    the tap commits EXACTLY what the preview showed (WYSIWYG). ────────────────

  /// The ortho route polyline to commit (B17), or null for the single-segment
  /// path.
  List<Offset>? _routePts;

  /// The exact END world point to land on when [_endExact] is true (align /
  /// midpoint / parallel-lock — snaps the store can't reproduce); else null and
  /// the store resolves the raw tap itself (node/tee/underlay/grid, unchanged).
  Offset? _commitWorld;
  bool _endExact = false;

  @override
  void deactivate() {
    _autoPan?.set(null);
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) {
    _autoPan = ref.read(canvasAutoPanProbeProvider.notifier);
    final drawing = ref.watch(networkControllerProvider);
    final notifier = ref.read(networkControllerProvider.notifier);
    final ortho = ref.watch(orthoProvider);
    final routeKindPref = ref.watch(orthoRouteKindProvider);
    final transform =
        ref.watch(sheetsControllerProvider).viewportFor(widget.sheetId) ??
            const ViewportTransform();
    final project = ref.watch(projectControllerProvider);
    final calibration = project.calibrationFor(widget.sheetId);
    final building = project.building;
    // H5 — the LAID drainage design slope the sizer + calc report use (the
    // Building-page input), feeding the live invert readout below.
    final drainageSlope = ref.watch(drainageSlopeProvider);
    // E1 — the services currently INERT to canvas interaction (a locked
    // discipline layer's services + the individually hidden ones). Threaded into
    // every draw COMMIT below so a run can never latch onto a node the engineer
    // cannot see or unpick. Empty by default ⇒ byte-identical.
    final inertServices = ref.watch(inertServicesProvider);
    final snapWorld = 12 / transform.scale; // keep snap ≈12 screen px
    final pickWorld = 14 / transform.scale; // the standard pick radius

    final shift = HardwareKeyboard.instance.isShiftPressed;
    final alt = HardwareKeyboard.instance.isAltPressed;
    // C9: hold-Shift toggles the ortho constraint for THIS gesture — effective
    // ortho = the setting XOR Shift, applied to the single-segment preview.
    final effectiveOrtho = ortho ^ shift;
    // B1: a run started on another sheet/floor does NOT belong on this one.
    final pending = drawing.pendingOnSheet(widget.sheetId, widget.floorIndex)
        ? drawing.pendingPoint
        : null;

    // B17 — two-click ortho routing is active with ortho ON, Shift OFF, and a
    // pending start. Shift keeps the free single-segment path.
    final routeActive =
        drawing.tool == DrawTool.drawRun && pending != null && ortho && !shift;

    final sheet = ref.watch(sheetsControllerProvider).sheetById(widget.sheetId);
    final snapToPlan = ref.watch(snapToPlanProvider);
    final refLines = ref.watch(referenceLinesProvider);
    final underlaySvc = ref.read(underlaySnapServiceProvider);
    final gridMpp = calibration?.metersPerPixel;
    final gridEligible = gridMpp != null &&
        calibratedGridWorldStep(gridMpp) * transform.scale >= 6.0;

    // Resolve the END snap for a raw world point, in the store's precedence
    // (node/tee > midpoint > underlay > align > grid). [orthoAnchor] keeps a
    // straight run on-axis for the underlay perpendicular/on-line candidates.
    _EndSnap resolveEnd(Offset raw, {Offset? orthoAnchor}) {
      // 1) Network node / tee (the store's own resolution) — classify it.
      final teed = snapOrTeeMarked(
          drawing.network, widget.sheetId, widget.floorIndex, raw, snapWorld);
      if (teed != null && teed.kind == SnapKind.node) {
        return _EndSnap(teed.point, SnapKind.node);
      }
      // 2) Exact run MIDPOINT (B24) — beats a plain tee when nearer.
      final runs = <(Offset, Offset)>[
        for (final e in drawing.network.edges)
          if (e.kind != EdgeKind.riser)
            if (drawing.network.nodeById(e.fromId) case final a?)
              if (drawing.network.nodeById(e.toId) case final b?)
                if (a.sheetId == widget.sheetId &&
                    a.floorIndex == widget.floorIndex &&
                    b.sheetId == widget.sheetId &&
                    b.floorIndex == widget.floorIndex)
                  (Offset(a.x, a.y), Offset(b.x, b.y)),
      ];
      final mid = nearestRunMidpoint(runs, raw, pickWorld);
      if (mid != null &&
          (teed == null || mid.distance <= (teed.point - raw).distance)) {
        return _EndSnap(mid.point, SnapKind.midpoint);
      }
      if (teed != null) return _EndSnap(teed.point, teed.kind);
      // 3) Plan underlay (DXF wall / reference line / PDF ink) — carries its own
      // SnapKind (endpoint / intersection / perpendicular / refline / ink).
      if (sheet != null) {
        final u = underlaySvc.snap(sheet, refLines, raw, pickWorld,
            enabled: snapToPlan, orthoAnchor: orthoAnchor, anchor: pending);
        if (u != null) {
          return _EndSnap(u.point, u.kind, segments: u.segments);
        }
      }
      // 4) Alignment guide against existing nodes (B23) — low precedence.
      final nodeOffsets = <Offset>[
        for (final n in drawing.network.nodes)
          if (n.sheetId == widget.sheetId && n.floorIndex == widget.floorIndex)
            Offset(n.x, n.y),
      ];
      final g = nearestAlignment(nodeOffsets, raw, pickWorld);
      if (g != null) {
        return _EndSnap(g.point, SnapKind.align, guide: g);
      }
      // 5) Magnetic grid (lowest) — only when its minors are visible + on-axis.
      if (effectiveOrtho && gridEligible) {
        final grid = nearestGridIntersection(raw, gridMpp);
        if ((grid - raw).distance <= snapWorld) {
          return _EndSnap(grid, SnapKind.grid);
        }
      }
      return _EndSnap(raw, null);
    }

    // B25 — Alt over a reference line locks the band to a parallel track at the
    // smart-bar offset. Overrides all other snapping while held.
    _ParallelLock? parallelLock;
    if (alt && pending != null && _hoverWorld != null) {
      final seg = _nearestReferenceLine(refLines, widget.sheetId, _hoverWorld!,
          pickWorld * 2); // a generous grab so the wall is easy to catch
      if (seg != null) {
        final offMm = ref.watch(parallelOffsetProvider);
        final offPx = calibration != null
            ? calibration.pixelsForLength(Length.mm(offMm))
            : offMm; // uncalibrated: treat the mm value as pixels
        final track =
            parallelTrackProjection(seg.$1, seg.$2, offPx, _hoverWorld!);
        if (track != null) parallelLock = _ParallelLock(track, seg.$1, seg.$2);
      }
    }

    // Resolve the live preview end.
    _EndSnap? end;
    if (parallelLock != null) {
      end = _EndSnap(parallelLock.track.point, SnapKind.refline);
      _commitWorld = parallelLock.track.point;
      _endExact = true;
      _routePts = null;
    } else if (_hoverWorld != null) {
      if (routeActive) {
        end = resolveEnd(_hoverWorld!);
        final kind = routeKindPref ?? autoRouteKind(pending, end.point);
        _routePts = orthoRoute(pending, end.point, kind: kind);
        _endExact = _isExact(end.kind);
        _commitWorld = _endExact ? end.point : null;
      } else {
        _routePts = null;
        final base = (effectiveOrtho && pending != null)
            ? orthoSnap(pending, _hoverWorld!)
            : _hoverWorld!;
        end = resolveEnd(base,
            orthoAnchor: effectiveOrtho ? pending : null);
        _endExact = _isExact(end.kind);
        _commitWorld = _endExact ? end.point : null;
      }
    } else {
      _routePts = null;
      _commitWorld = null;
      _endExact = false;
    }

    // ── Build the painter inputs ────────────────────────────────────────────────
    Offset? endHover = end?.point;
    Offset? previewBend;
    List<Offset>? routeScreen;
    // Only mark a snap when a real feature latched (kind != null).
    final ringPt = (end != null && end.kind != null) ? end.point : null;
    final ringKind = end?.kind ?? SnapKind.refline;
    // The plan wall/line(s) under the latched snap, mapped to screen so the
    // preview can highlight which part of the plan is being snapped to.
    final snapSegmentsScreen = <(Offset, Offset)>[
      if (ringPt != null && end != null)
        for (final (a, b) in end.segments)
          (transform.worldToScreen(a), transform.worldToScreen(b)),
    ];

    if (routeActive && _routePts != null && _routePts!.length >= 2) {
      routeScreen = [for (final p in _routePts!) transform.worldToScreen(p)];
      endHover = _routePts!.last;
    } else if (effectiveOrtho &&
        pending != null &&
        _hoverWorld != null &&
        end != null &&
        end.kind != null) {
      // B13 — reach an off-ray snap target as an L (dominant leg on the ray +
      // short correcting leg). The ray points along the ortho-snapped hover.
      final base = orthoSnap(pending, _hoverWorld!);
      final b = orthoElbow(pending, base, end.point);
      if (b != null) previewBend = b;
    }

    // B21 polar chip + B29 invert-level line.
    String? polarText;
    String? ilText;
    if (pending != null && endHover != null) {
      polarText = polarLabel(pending, endHover, calibration);
      // B29 — a live invert-level readout on a gravity service, only when the
      // sheet is calibrated AND the run starts on a known node (honest omission
      // otherwise: the invert can't be derived without a start elevation).
      if (drawing.service.regime == FlowRegime.gravity && calibration != null) {
        final startNode = _nodeNear(drawing.network, widget.sheetId,
            widget.floorIndex, pending, snapWorld);
        if (startNode != null) {
          final startElev = nodeElevation(startNode, building).meters;
          final devLenM =
              calibration.lengthForPixels((endHover - pending).distance).meters;
          // H5 — the LAID design slope from `drainageSlopeProvider`, never the
          // dark `SizingContext` default: the live invert readout must agree
          // with the fall stamped on the issued sheet. // VERIFY the gradient.
          final slope = drainageSlope; // m/m // VERIFY
          ilText = invertLevelLabel(startElev, devLenM, slope);
        }
      }
    }

    // B17 mode chip.
    String? routeLabel;
    if (routeActive && _routePts != null) {
      routeLabel = context.strings(_routeLabelKey(routeKindPref));
    }

    // B23 alignment guide (screen-space endpoints spanning the viewport).
    DrawGuideMark? guideScreen;
    final activeGuide = end?.guide;
    if (activeGuide != null && routeScreen == null) {
      guideScreen = DrawGuideMark(
        transform.worldToScreen(activeGuide.node),
        activeGuide.horizontal,
      );
    }

    // B25 parallel-track render (the reference wall highlighted + the dashed
    // parallel track).
    DrawParallelMark? parallelScreen;
    if (parallelLock != null) {
      parallelScreen = DrawParallelMark(
        transform.worldToScreen(parallelLock.a),
        transform.worldToScreen(parallelLock.b),
        transform.worldToScreen(parallelLock.track.base),
        transform.worldToScreen(parallelLock.track.point),
      );
    }

    return MouseRegion(
      cursor: SystemMouseCursors.precise,
      onHover: (e) {
        final world = transform.screenToWorld(e.localPosition);
        ref.read(drawHoverProvider.notifier).set(world);
        // B30 — publish the screen-local pointer so the canvas can auto-pan.
        _autoPan?.set(e.localPosition);
        setState(() => _hoverWorld = world);
      },
      onExit: (_) {
        ref.read(drawHoverProvider.notifier).set(null);
        _autoPan?.set(null);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) {
          var world = transform.screenToWorld(details.localPosition);
          final effOrtho = ortho ^ HardwareKeyboard.instance.isShiftPressed;
          switch (drawing.tool) {
            case DrawTool.drawRun:
              final underlayCb = sheet == null
                  ? null
                  : underlaySvc.callback(sheet, refLines, transform.scale,
                      enabled: snapToPlan,
                      orthoAnchor: effOrtho ? pending : null,
                      anchor: pending);
              final routing = _routePts != null &&
                  ortho &&
                  !HardwareKeyboard.instance.isShiftPressed &&
                  pending != null;
              if (routing) {
                // B17 — commit the whole L/Z route as one undo step, then reset
                // the mode to Auto for the next run.
                notifier.commitRoute(
                  widget.sheetId,
                  widget.floorIndex,
                  _routePts!,
                  drawing.service,
                  snapRadius: snapWorld,
                  endSnapRadius: _endExact ? 0.5 : null,
                  gridSnap: !_endExact && effOrtho && gridEligible,
                  gridMetersPerPixel: gridMpp,
                  underlaySnap: _endExact ? null : underlayCb,
                  ortho: true,
                  // E1 — the draw endpoint must not latch onto a node that only
                  // belongs to a HIDDEN or LOCKED service: the engineer cannot
                  // see it and cannot unpick it. Same inert set the marquee and
                  // hit-test already honour; empty ⇒ byte-identical.
                  avoidServices: inertServices,
                );
                ref.read(orthoRouteKindProvider.notifier).reset();
              } else if (_endExact && _commitWorld != null) {
                // Align / midpoint / parallel-lock — land precisely (the store
                // can't reproduce these snaps, so feed the resolved point with a
                // tight end radius).
                notifier.placeRunPoint(
                  widget.sheetId,
                  widget.floorIndex,
                  _commitWorld!,
                  snapRadius: snapWorld,
                  endSnapRadius: 0.5,
                  ortho: effOrtho && pending != null,
                  avoidServices: inertServices, // E1
                );
              } else {
                if (effOrtho && pending != null) {
                  world = orthoSnap(pending, world);
                }
                notifier.placeRunPoint(
                  widget.sheetId,
                  widget.floorIndex,
                  world,
                  snapRadius: snapWorld,
                  gridSnap: effOrtho && gridEligible,
                  gridMetersPerPixel: gridMpp,
                  underlaySnap: underlayCb,
                  ortho: effOrtho && pending != null,
                  avoidServices: inertServices, // E1
                );
              }
            case DrawTool.drawRiser:
              final placement = notifier.placeRiser(
                widget.sheetId,
                widget.floorIndex,
                world,
                widget.levelCount,
                snapRadius: snapWorld,
              );
              if (placement == RiserPlacement.none) {
                ref
                    .read(statusMessageProvider.notifier)
                    .showStatus('Add a floor above to draw a riser');
              }
            case DrawTool.select:
              break;
          }
        },
        onSecondaryTapUp: (_) {
          if (drawing.pendingPoint != null) {
            notifier.cancelPending();
            ref.read(orthoRouteKindProvider.notifier).reset();
          } else {
            notifier.setTool(DrawTool.select);
          }
        },
        child: CustomPaint(
          size: Size.infinite,
          painter: RubberBandPainter(
            pending: pending,
            hover: endHover,
            bend: previewBend,
            snapScreen: ringPt != null ? transform.worldToScreen(ringPt) : null,
            snapKind: ringKind,
            snapSegmentsScreen: snapSegmentsScreen,
            routeScreen: routeScreen,
            routeLabel: routeLabel,
            guide: guideScreen,
            parallel: parallelScreen,
            polarText: polarText,
            ilText: ilText,
            transform: transform,
            calibration: calibration,
            color: serviceColor(drawing.service),
            active: drawing.tool == DrawTool.drawRun,
          ),
        ),
      ),
    );
  }

  /// Whether [kind] is a snap the store can't reproduce and so must be committed
  /// at the pre-resolved point.
  static bool _isExact(SnapKind? kind) =>
      kind == SnapKind.align || kind == SnapKind.midpoint;
}

/// The label key for the current route mode (B17).
StringKey _routeLabelKey(OrthoRouteKind? kind) => switch (kind) {
      null => StringKey.drawRouteModeAuto,
      OrthoRouteKind.horizontalFirst => StringKey.drawRouteModeHFirst,
      OrthoRouteKind.verticalFirst => StringKey.drawRouteModeVFirst,
      OrthoRouteKind.diagonalZ => StringKey.drawRouteModeZ,
    };

/// A resolved END snap: the point, its [SnapKind] (marker), and (when it came
/// from an alignment guide) the guide for rendering the dashed line.
class _EndSnap {
  final Offset point;

  /// The OSNAP feature latched, or null when nothing snapped (a raw point).
  final SnapKind? kind;
  final AlignGuide? guide;

  /// The plan geometry this snap latched onto (world-space wall/line segments,
  /// 0–2), so the preview can HIGHLIGHT which part of the plan is being snapped
  /// to. Empty for a network/grid/ink snap with no straight source segment.
  final List<(Offset, Offset)> segments;

  const _EndSnap(this.point, this.kind, {this.guide, this.segments = const []});
}

/// A live B25 parallel-lock: the projected track plus the reference segment it
/// runs parallel to.
class _ParallelLock {
  final ParallelTrack track;
  final Offset a;
  final Offset b;
  const _ParallelLock(this.track, this.a, this.b);
}

/// The B23 alignment guide in screen space: the aligned node and whether the
/// dashed guide is horizontal (shared Y) or vertical (shared X). Public because
/// it rides the public [RubberBandPainter] API.
class DrawGuideMark {
  final Offset node;
  final bool horizontal;
  const DrawGuideMark(this.node, this.horizontal);
}

/// The B25 parallel render in screen space: the highlighted reference segment
/// and the dashed parallel track through the locked point.
class DrawParallelMark {
  final Offset segA;
  final Offset segB;
  final Offset base;
  final Offset point;
  const DrawParallelMark(this.segA, this.segB, this.base, this.point);
}

/// The nearest reference line on [sheetId] within [radius] of [probe], as its
/// two endpoints, or null. (B25 — the parallel-lock reference.)
(Offset, Offset)? _nearestReferenceLine(
  List<ReferenceLine> lines,
  String sheetId,
  Offset probe,
  double radius,
) {
  (Offset, Offset)? best;
  var bestD2 = radius * radius;
  for (final l in lines) {
    if (l.sheetId != sheetId) continue;
    final a = Offset(l.x1, l.y1);
    final b = Offset(l.x2, l.y2);
    final p = _closestPointOnSegment(probe, a, b);
    final d2 = (p - probe).distanceSquared;
    if (d2 <= bestD2) {
      bestD2 = d2;
      best = (a, b);
    }
  }
  return best;
}

/// The nearest network node to [world] within [radius], on [sheetId]/[floor], or
/// null (B29 — the pending run's start node, for its elevation).
NetNode? _nodeNear(
  Network net,
  String sheetId,
  int floor,
  Offset world,
  double radius,
) {
  NetNode? best;
  var bestD2 = radius * radius;
  for (final n in net.nodes) {
    if (n.sheetId != sheetId || n.floorIndex != floor) continue;
    final d2 = (Offset(n.x, n.y) - world).distanceSquared;
    if (d2 <= bestD2) {
      bestD2 = d2;
      best = n;
    }
  }
  return best;
}

/// The B29 invert-level readout: the start node elevation minus the drop over
/// the developed length so far (slope × length). Formatted 'IL -0.42'.
String invertLevelLabel(double startElevM, double devLenM, double slope) {
  final il = startElevM - slope * devLenM;
  return 'IL ${il.toStringAsFixed(2)}';
}

/// The B21 polar readout for the rubber band [pending]→[head]: calibrated
/// metres (or raw pixels when uncalibrated) at the screen bearing (0 = East, CCW
/// positive; screen Y is down so the sign of dy is flipped).
String polarLabel(Offset pending, Offset head, ScaleCalibration? cal) {
  final v = head - pending;
  final lenPx = v.distance;
  final deg = (math.atan2(-v.dy, v.dx) * 180.0 / math.pi).round();
  // Normalise to 0..359 for a clean readout.
  final ang = ((deg % 360) + 360) % 360;
  if (cal == null) return '${lenPx.round()} px @ $ang';
  final m = cal.lengthForPixels(lenPx).meters;
  final len = m >= 10 ? m.toStringAsFixed(1) : m.toStringAsFixed(2);
  return '$len m @ $ang';
}

/// The world point a drawn/pulled endpoint at [world] would attach to on
/// [sheetId]/[floorIndex] within [radiusWorld]: an existing NODE (node hit
/// wins), else the projection onto the nearest run EDGE (a tee-in), else null.
/// Mirrors the store's `_resolveDrawEndpoint` precedence so the on-canvas snap
/// ring marks the genuine attach point (a node OR the tee projection, C1/C5).
/// Shared by the [DrawingOverlay] rubber-band and the outlet-nub pull.
Offset? snapOrTeePoint(
  Network net,
  String sheetId,
  int floorIndex,
  Offset world,
  double radiusWorld,
) =>
    snapOrTeeMarked(net, sheetId, floorIndex, world, radiusWorld)?.point;

/// As [snapOrTeePoint] but carrying the [SnapKind] the attach point represents:
/// [SnapKind.node] for a real node, else [SnapKind.perpendicular] for a tee
/// projection onto a run (the foot of the perpendicular). Used by the drawing
/// overlay to pick the OSNAP marker (B24).
({Offset point, SnapKind kind})? snapOrTeeMarked(
  Network net,
  String sheetId,
  int floorIndex,
  Offset world,
  double radiusWorld,
) {
  final r2 = radiusWorld * radiusWorld;
  NetNode? bestNode;
  var bestNodeD2 = r2;
  for (final n in net.nodes) {
    if (n.sheetId != sheetId || n.floorIndex != floorIndex) continue;
    final dx = n.x - world.dx;
    final dy = n.y - world.dy;
    final d2 = dx * dx + dy * dy;
    if (d2 <= bestNodeD2) {
      bestNodeD2 = d2;
      bestNode = n;
    }
  }
  if (bestNode != null) {
    return (point: Offset(bestNode.x, bestNode.y), kind: SnapKind.node);
  }
  Offset? bestP;
  var bestD2 = r2;
  for (final e in net.edges) {
    if (e.kind == EdgeKind.riser) continue;
    final a = net.nodeById(e.fromId);
    final b = net.nodeById(e.toId);
    if (a == null || b == null) continue;
    if (a.sheetId != sheetId || a.floorIndex != floorIndex) continue;
    if (b.sheetId != sheetId || b.floorIndex != floorIndex) continue;
    final p = _closestPointOnSegment(world, Offset(a.x, a.y), Offset(b.x, b.y));
    final d2 = (p - world).distanceSquared;
    if (d2 <= bestD2) {
      bestD2 = d2;
      bestP = p;
    }
  }
  return bestP == null ? null : (point: bestP, kind: SnapKind.perpendicular);
}

/// Closest point on segment a→b to p (all world px).
Offset _closestPointOnSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final len2 = ab.distanceSquared;
  if (len2 == 0) return a;
  final t = (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / len2)
      .clamp(0.0, 1.0);
  return a + ab * t;
}

/// Rubber-band preview painter for a run being drawn (or a mainline being pulled
/// out of a node, C5): the pending→cursor line with a LIVE polar readout chip,
/// plus an OSNAP marker over the point the next endpoint would attach to. Public
/// so the outlet-nub pull reuses the exact same feedback.
class RubberBandPainter extends CustomPainter {
  final Offset? pending;
  final Offset? hover;

  /// B13 — the auto-elbow bend (world). When set the band draws as an L:
  /// pending→bend (dominant leg) then bend→hover (correcting leg).
  final Offset? bend;
  final Offset? snapScreen;

  /// The OSNAP feature the [snapScreen] point represents (B24) — picks the
  /// marker shape. Defaults to [SnapKind.refline] (the ring + crosshair) so
  /// callers that don't pass one (the outlet-nub pull) keep the exact original
  /// marker.
  final SnapKind snapKind;

  /// The plan wall/line(s) the snap latched onto, in SCREEN space (0–2), drawn
  /// highlighted so the user sees WHICH part of the plan is being snapped to.
  /// Empty ⇒ nothing extra drawn (byte-identical for callers that don't pass it,
  /// e.g. the outlet-nub pull).
  final List<(Offset, Offset)> snapSegmentsScreen;

  /// B17 — the multi-leg ortho route in screen space (>=2 points). When set the
  /// band draws the route polyline instead of a single segment / elbow.
  final List<Offset>? routeScreen;

  /// B17 — the route-mode chip text (already localized), or null.
  final String? routeLabel;

  /// B23 — the alignment guide to flash (dashed), or null.
  final DrawGuideMark? guide;

  /// B25 — the parallel-lock reference + track to render, or null.
  final DrawParallelMark? parallel;

  /// B21 — the polar readout ('3.24 m @ 45'), or null.
  final String? polarText;

  /// B29 — the invert-level line ('IL -0.42'), or null.
  final String? ilText;

  final ViewportTransform transform;
  final ScaleCalibration? calibration;
  final Color color;
  final bool active;

  RubberBandPainter({
    required this.pending,
    required this.hover,
    required this.snapScreen,
    required this.transform,
    required this.calibration,
    required this.color,
    required this.active,
    this.bend,
    this.snapKind = SnapKind.refline,
    this.snapSegmentsScreen = const [],
    this.routeScreen,
    this.routeLabel,
    this.guide,
    this.parallel,
    this.polarText,
    this.ilText,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // B23 — the alignment guide spans the viewport through the aligned node.
    final g = guide;
    if (g != null) {
      final gp = Paint()
        ..color = color.withAlpha(120)
        ..strokeWidth = 1.0;
      if (g.horizontal) {
        _dashedLine(
            canvas, Offset(0, g.node.dy), Offset(size.width, g.node.dy), gp);
      } else {
        _dashedLine(
            canvas, Offset(g.node.dx, 0), Offset(g.node.dx, size.height), gp);
      }
    }

    // B25 — the highlighted reference wall + the dashed parallel track.
    final par = parallel;
    if (par != null) {
      canvas.drawLine(
        par.segA,
        par.segB,
        Paint()
          ..color = color.withAlpha(90)
          ..strokeWidth = 2.5,
      );
      // Extend the dashed track well past the locked point along the segment.
      final dir = (par.segB - par.segA);
      final len = dir.distance;
      if (len > 0) {
        final u = dir / len;
        final half = math.max(size.width, size.height);
        _dashedLine(canvas, par.point - u * half, par.point + u * half,
            Paint()
              ..color = color.withAlpha(160)
              ..strokeWidth = 1.2);
      }
    }

    // Highlight the plan wall/line the snap latched onto (under the marker), so
    // it's obvious WHICH part of the plan is being snapped to — same accent
    // treatment as the B25 parallel-reference highlight.
    if (snapSegmentsScreen.isNotEmpty) {
      final hp = Paint()
        ..color = color.withAlpha(90)
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round;
      for (final (a, b) in snapSegmentsScreen) {
        canvas.drawLine(a, b, hp);
      }
    }

    // The OSNAP marker over the attach point.
    final snap = snapScreen;
    if (snap != null) _paintMarker(canvas, snap, snapKind, color);

    if (!active || pending == null) return;
    final a = transform.worldToScreen(pending!);
    canvas.drawCircle(a, 3.5, Paint()..color = color);

    final line = Paint()
      ..color = color.withAlpha(150)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    // B17 — the multi-leg route polyline.
    final route = routeScreen;
    if (route != null && route.length >= 2) {
      for (var i = 0; i < route.length - 1; i++) {
        canvas.drawLine(route[i], route[i + 1], line);
      }
    } else if (hover != null) {
      final b = transform.worldToScreen(hover!);
      final bendScreen = bend == null ? null : transform.worldToScreen(bend!);
      if (bendScreen != null) {
        canvas.drawLine(a, bendScreen, line);
        canvas.drawLine(bendScreen, b, line);
      } else {
        canvas.drawLine(a, b, line);
      }
    }

    // B21/B29 — the polar readout + invert line, riding the head. B17 — the
    // route-mode chip below it.
    if (hover != null) {
      final head = transform.worldToScreen(hover!);
      final lines = <String>[
        ?polarText,
        ?ilText,
      ];
      if (lines.isNotEmpty) {
        _paintChip(canvas, head.translate(12, -10), lines, color,
            const Color(0xFFFFFFFF));
      }
      final rl = routeLabel;
      if (rl != null) {
        _paintChip(canvas, head.translate(12, 16), [rl], color.withAlpha(210),
            const Color(0xFFFFFFFF));
      }
    }
  }

  // ── OSNAP marker vocabulary (B24) ───────────────────────────────────────────

  void _paintMarker(Canvas canvas, Offset c, SnapKind kind, Color color) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    const s = 6.0; // half-size
    switch (kind) {
      case SnapKind.node:
      case SnapKind.endpoint:
        // Square (a run endpoint / node).
        canvas.drawRect(Rect.fromCenter(center: c, width: s * 2, height: s * 2),
            stroke);
      case SnapKind.midpoint:
        // Upward triangle.
        final p = Path()
          ..moveTo(c.dx, c.dy - s)
          ..lineTo(c.dx + s, c.dy + s)
          ..lineTo(c.dx - s, c.dy + s)
          ..close();
        canvas.drawPath(p, stroke);
      case SnapKind.intersection:
        // An X.
        canvas.drawLine(c + const Offset(-s, -s), c + const Offset(s, s),
            stroke);
        canvas.drawLine(c + const Offset(-s, s), c + const Offset(s, -s),
            stroke);
      case SnapKind.perpendicular:
        // A right-angle foot ⊾.
        final p = Path()
          ..moveTo(c.dx - s, c.dy - s)
          ..lineTo(c.dx - s, c.dy + s)
          ..lineTo(c.dx + s, c.dy + s);
        canvas.drawPath(p, stroke);
        canvas.drawRect(
            Rect.fromLTWH(c.dx - s, c.dy + s - 3, 3, 3), stroke);
      case SnapKind.refline:
      case SnapKind.ink:
        // A ring + crosshair (a generic on-a-line snap).
        canvas.drawCircle(c, s + 6, stroke);
        final cross = Paint()
          ..color = color
          ..strokeWidth = 1.5;
        canvas.drawLine(c + const Offset(-5, 0), c + const Offset(5, 0), cross);
        canvas.drawLine(c + const Offset(0, -5), c + const Offset(0, 5), cross);
      case SnapKind.grid:
        final cross = Paint()
          ..color = color
          ..strokeWidth = 1.5;
        canvas.drawLine(c + const Offset(-s, 0), c + const Offset(s, 0), cross);
        canvas.drawLine(c + const Offset(0, -s), c + const Offset(0, s), cross);
      case SnapKind.align:
        canvas.drawCircle(c, s, stroke);
    }
  }

  void _paintChip(
      Canvas canvas, Offset at, List<String> lines, Color bg, Color fg) {
    final painters = [
      for (final t in lines)
        TextPainter(
          text: TextSpan(
            text: t,
            style: TextStyle(
              color: fg,
              fontSize: 11,
              fontFamily: 'Roboto',
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(),
    ];
    var w = 0.0;
    var h = 0.0;
    for (final p in painters) {
      w = math.max(w, p.width);
      h += p.height;
    }
    final rect = Rect.fromLTWH(at.dx, at.dy, w + 10, h + 6);
    canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)), Paint()..color = bg);
    var y = rect.top + 3;
    for (final p in painters) {
      p.paint(canvas, Offset(rect.left + 5, y));
      y += p.height;
    }
  }

  void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 5.0, gap = 4.0;
    final total = (b - a).distance;
    if (total <= 0) return;
    final dir = (b - a) / total;
    var d = 0.0;
    while (d < total) {
      final start = a + dir * d;
      final end = a + dir * math.min(d + dash, total);
      canvas.drawLine(start, end, paint);
      d += dash + gap;
    }
  }

  @override
  bool shouldRepaint(RubberBandPainter old) =>
      old.pending != pending ||
      old.hover != hover ||
      old.bend != bend ||
      old.snapScreen != snapScreen ||
      old.snapKind != snapKind ||
      !listEquals(old.snapSegmentsScreen, snapSegmentsScreen) ||
      old.routeScreen != routeScreen ||
      old.routeLabel != routeLabel ||
      old.guide != guide ||
      old.parallel != parallel ||
      old.polarText != polarText ||
      old.ilText != ilText ||
      old.transform != transform ||
      old.calibration != calibration ||
      old.color != color ||
      old.active != active;
}
