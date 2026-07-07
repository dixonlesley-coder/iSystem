import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';

import '../../store/app_state.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import '../../store/smart_input_store.dart';
import '../../store/reference_line_store.dart';
import '../../store/snap_settings_store.dart';
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

  @override
  Widget build(BuildContext context) {
    final drawing = ref.watch(networkControllerProvider);
    final notifier = ref.read(networkControllerProvider.notifier);
    final ortho = ref.watch(orthoProvider);
    final transform = ref.watch(sheetsControllerProvider).viewportFor(widget.sheetId) ??
        const ViewportTransform();
    final calibration =
        ref.watch(projectControllerProvider).calibrationFor(widget.sheetId);
    final snapWorld = 12 / transform.scale; // keep snap ≈12 screen px

    // C9: hold-Shift toggles the ortho constraint for THIS gesture (a one-off
    // free-angle run without four inspector trips) — effective ortho = the
    // setting XOR Shift, applied to BOTH the preview and the tap commit.
    final effectiveOrtho = ortho ^ HardwareKeyboard.instance.isShiftPressed;
    // B1: a run started on another sheet/floor does NOT belong on this one — its
    // pixel offset would resolve against this sheet's geometry. Ignore it for the
    // rubber band here; the next click restarts the run on this sheet (the store
    // refuses the cross-sheet commit) so no phantom node is planted.
    final pending = drawing.pendingOnSheet(widget.sheetId, widget.floorIndex)
        ? drawing.pendingPoint
        : null;
    final previewHover = (effectiveOrtho && pending != null && _hoverWorld != null)
        ? orthoSnap(pending, _hoverWorld!)
        : _hoverWorld;
    // Where the NEXT click would attach — a node hit OR the tee-in projection
    // onto a nearby run (mirrors the store's `_resolveDrawEndpoint`, C1), so the
    // ring marks the genuine connect point rather than nodes only.
    final snapPt = previewHover != null
        ? snapOrTeePoint(drawing.network, widget.sheetId, widget.floorIndex,
            previewHover, snapWorld)
        : null;
    // G2 — the calibrated grid is MAGNETIC, but only when its minor lines are
    // actually visible at this zoom (the painter hides them below 6 screen-px),
    // so the snap can never target an invisible crossing. Lowest precedence: a
    // node/tee snap always wins. When it applies, the ring + rubber-band land on
    // the grid point so the commit is WYSIWYG (the store snaps to the same point).
    final gridMpp = calibration?.metersPerPixel;
    final gridEligible = gridMpp != null &&
        calibratedGridWorldStep(gridMpp) * transform.scale >= 6.0;
    // B12: the plan underlay is a snap surface too — offered AFTER a node/tee
    // snap (snapPt) and BEFORE the grid, so the ring preview matches the store's
    // commit precedence (node/tee > underlay > grid). Gated by 'Snap to plan'.
    final sheet = ref.watch(sheetsControllerProvider).sheetById(widget.sheetId);
    final snapToPlan = ref.watch(snapToPlanProvider);
    final refLines = ref.watch(referenceLinesProvider);
    final underlaySvc = ref.read(underlaySnapServiceProvider);
    var endHover = previewHover;
    var ringPt = snapPt;
    if (snapPt == null && previewHover != null) {
      final u = (sheet != null)
          ? underlaySvc.snap(
              sheet, refLines, previewHover, 14 / transform.scale,
              enabled: snapToPlan,
              orthoAnchor: effectiveOrtho ? pending : null)
          : null;
      if (u != null) {
        endHover = u.point;
        ringPt = u.point;
      } else if (effectiveOrtho && gridEligible) {
        final g = nearestGridIntersection(previewHover, gridMpp);
        if ((g - previewHover).distance <= snapWorld) {
          endHover = g;
          ringPt = g;
        }
      }
    }

    // B13 — once a snap candidate is latched under ortho, preview the CAD L: the
    // rubber band runs pending→bend (dominant leg on the constrained ray) then
    // bend→target (short correcting leg), matching what the commit will draw. An
    // on-ray target (within epsilon) yields no bend ⇒ the existing straight band.
    Offset? previewBend;
    if (effectiveOrtho &&
        pending != null &&
        ringPt != null &&
        previewHover != null) {
      final b = orthoElbow(pending, previewHover, ringPt);
      if (b != null) {
        previewBend = b;
        endHover = ringPt; // the L closes AT the latched target
      }
    }

    return MouseRegion(
      cursor: SystemMouseCursors.precise,
      onHover: (e) {
        final world = transform.screenToWorld(e.localPosition);
        // Publish the live cursor so the smart input bar can place a
        // length-only entry along the current pointing direction.
        ref.read(drawHoverProvider.notifier).set(world);
        setState(() => _hoverWorld = world);
      },
      onExit: (_) => ref.read(drawHoverProvider.notifier).set(null),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) {
          var world = transform.screenToWorld(details.localPosition);
          // Re-read Shift at commit time so the constraint matches what the
          // preview just showed (C9).
          final effOrtho = ortho ^ HardwareKeyboard.instance.isShiftPressed;
          switch (drawing.tool) {
            case DrawTool.drawRun:
              if (effOrtho && pending != null) world = orthoSnap(pending, world);
              notifier.placeRunPoint(
                widget.sheetId,
                widget.floorIndex,
                world,
                snapRadius: snapWorld,
                // G2 — grid-intersection snapping (lowest precedence; nodes/edges
                // still win), on only when ortho is on AND the minor grid is
                // visible at this zoom, so the commit matches the WYSIWYG ring
                // preview above. Off when Shift frees the angle.
                gridSnap: effOrtho && gridEligible,
                gridMetersPerPixel: gridMpp,
                // B12 — the plan underlay snap (DXF wall / reference line / PDF
                // ink), between node/tee and grid precedence. The anchor keeps a
                // straight run on-axis when ortho constrains the angle.
                underlaySnap: sheet == null
                    ? null
                    : underlaySvc.callback(
                        sheet, refLines, transform.scale,
                        enabled: snapToPlan,
                        orthoAnchor: effOrtho ? pending : null),
                // B13 — with ortho on, reach an off-ray snap target as an L
                // (bend on the ray + short correcting leg) rather than a tilted
                // segment; matches the live preview below.
                ortho: effOrtho && pending != null,
              );
            case DrawTool.drawRiser:
              // C6: consume the placement result — a single-floor building has
              // no adjacent floor, so tell the user instead of a silent no-op.
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
          // Right-click finishes: end the pending run first, then a second
          // right-click steps back to Select.
          if (drawing.pendingPoint != null) {
            notifier.cancelPending();
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
            snapScreen:
                ringPt != null ? transform.worldToScreen(ringPt) : null,
            transform: transform,
            calibration: calibration,
            color: serviceColor(drawing.service),
            active: drawing.tool == DrawTool.drawRun,
          ),
        ),
      ),
    );
  }
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
  if (bestNode != null) return Offset(bestNode.x, bestNode.y);
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
  return bestP;
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
/// out of a node, C5): the pending→cursor line with a LIVE calibrated length
/// chip, plus a snap/tee ring over the point the next endpoint would attach to.
/// Public so the outlet-nub pull reuses the exact same feedback.
class RubberBandPainter extends CustomPainter {
  final Offset? pending;
  final Offset? hover;

  /// B13 — the auto-elbow bend (world). When set the band draws as an L:
  /// pending→bend (dominant leg) then bend→hover (correcting leg), so the
  /// preview matches the commit when ortho reaches an off-ray snap target.
  final Offset? bend;
  final Offset? snapScreen;
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
  });

  /// The live run length: calibrated metres, or an honest 'set scale' nudge
  /// (the same wording the Measure tool uses when the sheet is uncalibrated).
  String _label(double pixelLength) {
    final cal = calibration;
    if (cal == null) return 'set scale';
    final m = cal.lengthForPixels(pixelLength).meters;
    return m >= 10 ? '${m.toStringAsFixed(1)} m' : '${m.toStringAsFixed(2)} m';
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Snap ring + crosshair over the node the next click lands on — shown for
    // run AND riser placement (both snap), mirroring the drop preview.
    final snap = snapScreen;
    if (snap != null) {
      final ring = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawCircle(snap, 12, ring);
      final cross = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      const arm = 5.0;
      canvas.drawLine(
          snap + const Offset(-arm, 0), snap + const Offset(arm, 0), cross);
      canvas.drawLine(
          snap + const Offset(0, -arm), snap + const Offset(0, arm), cross);
    }

    if (!active || pending == null) return;
    final a = transform.worldToScreen(pending!);
    canvas.drawCircle(a, 3.5, Paint()..color = color);
    if (hover != null) {
      final b = transform.worldToScreen(hover!);
      final line = Paint()
        ..color = color.withAlpha(150)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      // B13 — draw the L (pending→bend→hover) when an elbow was resolved, else
      // the single straight band.
      final bendScreen = bend == null ? null : transform.worldToScreen(bend!);
      if (bendScreen != null) {
        canvas.drawLine(a, bendScreen, line);
        canvas.drawLine(bendScreen, b, line);
      } else {
        canvas.drawLine(a, b, line);
      }

      // Live length chip at the DOMINANT-leg midpoint (the Measure tool's idiom,
      // in the service colour so it reads as part of the run being drawn). With
      // an elbow the dominant leg is pending→bend; else the whole segment.
      final legEnd = bendScreen ?? b;
      final legEndWorld = bend ?? hover!;
      final dx = legEndWorld.dx - pending!.dx;
      final dy = legEndWorld.dy - pending!.dy;
      final tp = TextPainter(
        text: TextSpan(
          text: _label(math.sqrt(dx * dx + dy * dy)),
          style: const TextStyle(
            color: Color(0xFFFFFFFF),
            fontSize: 11,
            fontFamily: 'Roboto',
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final mid = Offset((a.dx + legEnd.dx) / 2, (a.dy + legEnd.dy) / 2);
      final rect = Rect.fromCenter(
        center: mid.translate(0, -14),
        width: tp.width + 10,
        height: tp.height + 6,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        Paint()..color = color,
      );
      tp.paint(canvas, Offset(rect.left + 5, rect.top + 3));
    }
  }

  @override
  bool shouldRepaint(RubberBandPainter old) =>
      old.pending != pending ||
      old.hover != hover ||
      old.bend != bend ||
      old.snapScreen != snapScreen ||
      old.transform != transform ||
      old.calibration != calibration ||
      old.color != color ||
      old.active != active;
}
