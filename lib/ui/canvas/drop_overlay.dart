import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

import '../../data/project_document.dart' show SavedAssembly;
import '../../store/network_store.dart';
import '../../store/sheets_store.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'segment_palette.dart';
import 'segment_symbols.dart';
import 'underlay_snap_service.dart';
import 'viewport.dart';

/// ≈14 screen px snap radius — the same value the store's add-actions use, so
/// the preview ring highlights exactly the node a drop will attach to.
const double _kSnapScreenPx = 14;

/// Half the default dropped-segment span (world px) — mirrors the store's
/// `NetworkController._defaultSegmentSpanPx` (120) so the SEGMENT preview rings
/// the endpoint that `addSegment` will actually snap. Preview-only; a small
/// drift here never affects the committed geometry.
const double _kSegmentHalfSpanPx = 60;

/// A [DragTarget] spanning the canvas: a [PaletteItem] dropped here is mapped
/// from the local drop offset to sheet/world coordinates (via the live
/// [ViewportTransform]) and routed to the matching add-action on the network
/// store. Pointer-translucent so the canvas keeps panning/zooming when nothing
/// is being dragged. Mounted only while NOT calibrating and NOT drawing.
///
/// While a palette card hovers, it paints a faint GHOST of the node at the
/// cursor and a SNAP ring on the nearest fitting within the 14px snap radius;
/// when a snap is live the canvas tint strengthens to a "will-snap" state. This
/// preview paints ONLY during a drag — at rest the overlay is fully transparent
/// and pointer-ignored, so goldens are unchanged.
class DropOverlay extends ConsumerStatefulWidget {
  final String sheetId;
  final int floorIndex;

  const DropOverlay({
    super.key,
    required this.sheetId,
    required this.floorIndex,
  });

  @override
  ConsumerState<DropOverlay> createState() => _DropOverlayState();
}

class _DropOverlayState extends ConsumerState<DropOverlay> {
  /// The live drag position (LOCAL canvas px) and payload, set on enter/move and
  /// cleared on leave/accept. Transient — exists only during a drag gesture.
  Offset? _dragLocal;
  PaletteItem? _dragItem;

  Offset? _toLocal(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    return box?.globalToLocal(global);
  }

  ViewportTransform get _transform =>
      ref.read(sheetsControllerProvider).viewportFor(widget.sheetId) ??
      const ViewportTransform();

  /// The nearest node (same sheet/floor) within the snap radius of [worldP], or
  /// null — mirrors the store's `_snap`. Used for a SEGMENT drop, whose two
  /// endpoints snap to nodes (there is no tee for a segment).
  NetNode? _snapTarget(Offset worldP, double snapWorld) {
    final nodes = ref.read(networkControllerProvider).network.nodes;
    final r2 = snapWorld * snapWorld;
    NetNode? best;
    var bestD2 = r2;
    for (final n in nodes) {
      if (n.sheetId != widget.sheetId || n.floorIndex != widget.floorIndex) {
        continue;
      }
      final dx = n.x - worldP.dx;
      final dy = n.y - worldP.dy;
      final d2 = dx * dx + dy * dy;
      if (d2 <= bestD2) {
        bestD2 = d2;
        best = n;
      }
    }
    return best;
  }

  /// Where a POINT drop at [world] will MERGE within [radius] (mirrors the
  /// store's `_dropTarget` that `mergeOrAdd*` uses): a NODE (adopt) takes
  /// precedence over a run EDGE (tee at the projection). Both null ⇒ a free
  /// drop, so the ring is suppressed and its promise stays honest (C2).
  ({Offset? point, bool isTee}) _mergeTarget(Offset world, double radius) {
    final net = ref.read(networkControllerProvider).network;
    final r2 = radius * radius;
    NetNode? bestNode;
    var bestNodeD2 = r2;
    for (final n in net.nodes) {
      if (n.sheetId != widget.sheetId || n.floorIndex != widget.floorIndex) {
        continue;
      }
      final dx = n.x - world.dx;
      final dy = n.y - world.dy;
      final d2 = dx * dx + dy * dy;
      if (d2 <= bestNodeD2) {
        bestNodeD2 = d2;
        bestNode = n;
      }
    }
    if (bestNode != null) {
      return (point: Offset(bestNode.x, bestNode.y), isTee: false);
    }
    Offset? bestP;
    var bestED2 = r2;
    for (final e in net.edges) {
      if (e.kind == EdgeKind.riser) continue; // risers are not teed into
      final a = net.nodeById(e.fromId);
      final b = net.nodeById(e.toId);
      if (a == null || b == null) continue;
      if (a.sheetId != widget.sheetId || a.floorIndex != widget.floorIndex) {
        continue;
      }
      if (b.sheetId != widget.sheetId || b.floorIndex != widget.floorIndex) {
        continue;
      }
      final p = _closestPointOnSegment(
          world, Offset(a.x, a.y), Offset(b.x, b.y));
      final d2 = (p - world).distanceSquared;
      if (d2 <= bestED2) {
        bestED2 = d2;
        bestP = p;
      }
    }
    return (point: bestP, isTee: bestP != null);
  }

  void _clearDrag() {
    if (_dragLocal != null || _dragItem != null) {
      setState(() {
        _dragLocal = null;
        _dragItem = null;
      });
    }
  }

  /// The live drag position (LOCAL px) of a hovering ASSEMBLY card — a separate
  /// slot from [_dragLocal] because assemblies are a distinct payload type
  /// (`SavedAssembly`), routed through their own [DragTarget] below.
  Offset? _assemblyLocal;

  void _clearAssemblyDrag() {
    if (_assemblyLocal != null) setState(() => _assemblyLocal = null);
  }

  /// Route a [PaletteItem] to its matching store add-action at [world] — the
  /// ONE placement path shared by a drag-drop (`onAcceptWithDetails`) and an
  /// F5 armed click, so both use the identical merge/snap behaviour.
  void _placeItem(PaletteItem data, Offset world) {
    final transform = _transform;
    final ctrl = ref.read(networkControllerProvider.notifier);
    final snapWorld = _kSnapScreenPx / transform.scale; // ≈14 screen px
    // B12: for a POINT drop with no node/edge merge target, snap the free drop
    // position onto the plan underlay (a DXF wall / reference line / PDF ink
    // ridge) so a placed fixture/fitting lands on the architecture. The merge
    // (node/edge) path always takes precedence — underlay only moves a free
    // drop; a segment drop keeps its two-endpoint node snap unchanged.
    Offset pointWorld(Offset w) {
      if (_mergeTarget(w, snapWorld).point != null) return w;
      return underlaySnapFor(ref, widget.sheetId, transform.scale)?.call(w) ?? w;
    }

    switch (data.kind) {
      case PaletteItemKind.pipeSegment:
      case PaletteItemKind.ductSegment:
        // A segment snaps its two endpoints to nearby nodes (addSegment).
        ctrl.addSegment(
          widget.sheetId,
          widget.floorIndex,
          world,
          service: data.service,
          snapRadius: snapWorld,
        );
      // C2: point drops go through the MERGE intents so the snap ring's promise
      // is TRUE — adopt the ringed node / tee into the ringed run, never a
      // coincident free twin that carries demand the solve misses.
      case PaletteItemKind.fitting:
        ctrl.mergeOrAddFitting(
            widget.sheetId, widget.floorIndex, pointWorld(world),
            snapRadius: snapWorld);
      case PaletteItemKind.terminal:
        ctrl.mergeOrAddTerminal(
            widget.sheetId, widget.floorIndex, pointWorld(world),
            snapRadius: snapWorld);
      case PaletteItemKind.component:
        final c = data.component;
        if (c != null) {
          ctrl.mergeOrAddComponent(
              widget.sheetId, widget.floorIndex, pointWorld(world), c,
              snapRadius: snapWorld);
        }
    }
  }

  /// The human label of an armed item for the hint pill.
  String _armedLabel(PaletteItem item) => switch (item.kind) {
        PaletteItemKind.pipeSegment ||
        PaletteItemKind.ductSegment =>
          'Segment',
        PaletteItemKind.fitting => 'Fitting',
        PaletteItemKind.terminal => 'Terminal',
        PaletteItemKind.component => item.component?.label ?? 'Component',
      };

  @override
  Widget build(BuildContext context) {
    // F5 — while a palette card is ARMED, a canvas tap places another instance
    // (right-click / Esc disarms). The capture layer sits ABOVE the drop
    // targets; it is translucent, so a palette DRAG still reaches the drop
    // target beneath and middle-drag pan / scroll-zoom still reach the canvas.
    // Null when nothing is armed ⇒ the overlay is byte-identical.
    final armed = ref.watch(armedPlacementProvider);
    return Stack(
      children: [
        _buildDropTargets(context),
        if (armed != null) _buildArmedCapture(context, armed),
      ],
    );
  }

  Widget _buildDropTargets(BuildContext context) {
    // Outer target: a SAVED ASSEMBLY card. It stamps the block CENTRED at the
    // cursor (fresh ids, one undo step, no merge — an assembly is placed whole,
    // it does not tee/adopt), so the preview is a simple drop-zone tint + a
    // centroid crosshair, not a snap ring. A `PaletteItem` drag is the wrong
    // type here, so it falls through to the inner palette target unchanged.
    return DragTarget<SavedAssembly>(
      hitTestBehavior: HitTestBehavior.translucent,
      onMove: (details) {
        final local = _toLocal(details.offset);
        if (local == null) return;
        setState(() => _assemblyLocal = local);
      },
      onLeave: (_) => _clearAssemblyDrag(),
      onAcceptWithDetails: (details) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final world = _transform.screenToWorld(box.globalToLocal(details.offset));
        ref.read(networkControllerProvider.notifier).stampAssembly(
              details.data.nodes,
              details.data.edges,
              sheetId: widget.sheetId,
              floorIndex: widget.floorIndex,
              world: world,
            );
        _clearAssemblyDrag();
      },
      builder: (context, candidate, rejected) {
        final active = candidate.isNotEmpty;
        return Stack(
          children: [
            _buildPaletteTarget(context),
            if (active)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.colors.accent.withAlpha(18),
                      border: Border.all(
                          color: context.colors.accent.withAlpha(120),
                          width: 1.5),
                      borderRadius: MechXRadii.card,
                    ),
                    child: _assemblyLocal == null
                        ? const SizedBox.expand()
                        : CustomPaint(
                            painter: _AssemblyPreviewPainter(
                              cursorLocal: _assemblyLocal!,
                              color: context.colors.accent,
                            ),
                          ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// F5 — the armed click-to-place capture layer + a hint pill. Translucent so
  /// palette drag-drop and canvas pan/zoom still work; a primary tap places
  /// another instance, a secondary tap disarms.
  Widget _buildArmedCapture(BuildContext context, PaletteItem armed) {
    final colors = context.colors;
    final type = context.type;
    return Positioned.fill(
      child: MouseRegion(
        cursor: SystemMouseCursors.precise,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapUp: (d) =>
              _placeItem(armed, _transform.screenToWorld(d.localPosition)),
          onSecondaryTap: () =>
              ref.read(armedPlacementProvider.notifier).disarm(),
          child: Stack(
            children: [
              // The cursor-hint pill (top-centre) — mirrors the draw-tool mode
              // pill so an armed placement mode reads on the canvas itself.
              Positioned(
                top: MechXSpacing.md + 40,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: MechXSpacing.sm + 2,
                        vertical: MechXSpacing.xs + 1),
                    decoration: BoxDecoration(
                      color: colors.surface.withAlpha(240),
                      borderRadius: MechXRadii.control,
                      border: Border.all(color: colors.accent),
                      boxShadow: MechXShadow.card,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          margin: const EdgeInsets.only(right: MechXSpacing.xs),
                          decoration: BoxDecoration(
                            color: colors.accent,
                            borderRadius: MechXRadii.small,
                          ),
                        ),
                        Text(
                          context.strings.format(StringKey.placementArmedHint,
                              {'item': _armedLabel(armed)}),
                          style: type.label.copyWith(color: colors.textPrimary),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPaletteTarget(BuildContext context) {
    return DragTarget<PaletteItem>(
      hitTestBehavior: HitTestBehavior.translucent,
      onMove: (details) {
        final local = _toLocal(details.offset);
        if (local == null) return;
        setState(() {
          _dragLocal = local;
          _dragItem = details.data;
        });
      },
      onLeave: (_) => _clearDrag(),
      onAcceptWithDetails: (details) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final world = _transform.screenToWorld(box.globalToLocal(details.offset));
        _placeItem(details.data, world);
        _clearDrag();
      },
      builder: (context, candidate, rejected) {
        final active = candidate.isNotEmpty;
        // Resolve the live merge/tee target (in screen space) for the preview
        // paint — kind-aware so the ring only shows when the drop WILL attach
        // (C2). A point drop adopts a node or tees an edge; a segment drop snaps
        // its two endpoints to nodes.
        final transform = _transform;
        final snapWorld = _kSnapScreenPx / transform.scale;
        Offset? ringScreen;
        var ringIsTee = false;
        if (active && _dragLocal != null && _dragItem != null) {
          final world = transform.screenToWorld(_dragLocal!);
          switch (_dragItem!.kind) {
            case PaletteItemKind.pipeSegment:
            case PaletteItemKind.ductSegment:
              final hit = _snapTarget(
                      Offset(world.dx - _kSegmentHalfSpanPx, world.dy),
                      snapWorld) ??
                  _snapTarget(
                      Offset(world.dx + _kSegmentHalfSpanPx, world.dy),
                      snapWorld);
              if (hit != null) {
                ringScreen = transform.worldToScreen(Offset(hit.x, hit.y));
              }
            case PaletteItemKind.fitting:
            case PaletteItemKind.terminal:
            case PaletteItemKind.component:
              final t = _mergeTarget(world, snapWorld);
              if (t.point != null) {
                ringScreen = transform.worldToScreen(t.point!);
                ringIsTee = t.isTee;
              } else {
                // B12: no merge target — preview the plan-underlay snap the drop
                // will use, so the ring matches where the point will land.
                final u = underlaySnapFor(ref, widget.sheetId, transform.scale)
                    ?.call(world);
                if (u != null) ringScreen = transform.worldToScreen(u);
              }
          }
        }
        final willSnap = ringScreen != null;

        // Translucent fill while a card hovers, so the user sees the canvas is a
        // valid drop zone; cross-fades in/out (rather than popping) and is
        // pointer-ignored when idle so the canvas keeps panning/zooming. The
        // fill STRENGTHENS to a "will-snap" state when a fitting is in range.
        return IgnorePointer(
          ignoring: !active,
          child: Stack(
            children: [
              Positioned.fill(
                child: AnimatedOpacity(
                  opacity: active ? 1.0 : 0.0,
                  duration: MechXMotion.hover,
                  curve: MechXMotion.standard,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.colors.accent.withAlpha(willSnap ? 35 : 18),
                      border: Border.all(
                        color: context.colors.accent
                            .withAlpha(willSnap ? 170 : 120),
                        width: 1.5,
                      ),
                      borderRadius: MechXRadii.card,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              // The drag preview: a faint ghost node at the cursor + a snap/tee
              // ring on the genuine attach point. Paints ONLY during a drag.
              if (active && _dragLocal != null && _dragItem != null)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _DropPreviewPainter(
                      item: _dragItem!,
                      cursorLocal: _dragLocal!,
                      snapScreen: ringScreen,
                      isTee: ringIsTee,
                      color: context.colors.accent,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Paints the drag-place preview: a translucent ghost glyph of the dragged
/// palette item at the cursor, and (when snapping) a ring + crosshair over the
/// target fitting. Drag-only, so it never affects the at-rest canvas.
class _DropPreviewPainter extends CustomPainter {
  final PaletteItem item;
  final Offset cursorLocal;
  final Offset? snapScreen;

  /// True when [snapScreen] is a TEE projection onto a run edge (not a node) —
  /// drawn with an extra filled dot so a tee-in reads distinctly from a node
  /// adopt (C2: "show the edge-projection point when a tee will land").
  final bool isTee;
  final Color color;

  _DropPreviewPainter({
    required this.item,
    required this.cursorLocal,
    required this.snapScreen,
    required this.isTee,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // ── Ghost glyph at the cursor (≈36px box, ~45% opacity) ──────────────────
    const box = 36.0;
    final ghostColor = color.withAlpha(115);
    canvas.save();
    canvas.translate(cursorLocal.dx - box / 2, cursorLocal.dy - box / 2);
    final c = item.component;
    if (c != null) {
      paintComponentSymbol(canvas, const Size(box, box), c, ghostColor,
          stroke: 2.0);
    } else {
      paintSegmentSymbol(canvas, const Size(box, box), item.kind, ghostColor,
          stroke: 2.0);
    }
    canvas.restore();

    // ── Snap/tee indicator: a ring over the genuine attach point ─────────────
    final snap = snapScreen;
    if (snap != null) {
      final ring = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawCircle(snap, _kSnapScreenPx, ring);
      if (isTee) {
        // A tee lands ON a run edge (not at a node): mark the projection point
        // with a filled dot so it reads as "connect here on this pipe".
        canvas.drawCircle(snap, 3.0, Paint()..color = color);
      } else {
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
    }
  }

  @override
  bool shouldRepaint(_DropPreviewPainter old) =>
      old.item != item ||
      old.cursorLocal != cursorLocal ||
      old.snapScreen != snapScreen ||
      old.isTee != isTee ||
      old.color != color;
}

/// Paints the ASSEMBLY drop preview: a crosshair at the cursor marking where
/// the block's centroid will land. Deliberately lighter than the segment/point
/// preview — an assembly stamps whole (no snap/merge), so there is no ring.
class _AssemblyPreviewPainter extends CustomPainter {
  final Offset cursorLocal;
  final Color color;

  _AssemblyPreviewPainter({required this.cursorLocal, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cross = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    const arm = 8.0;
    canvas.drawLine(cursorLocal + const Offset(-arm, 0),
        cursorLocal + const Offset(arm, 0), cross);
    canvas.drawLine(cursorLocal + const Offset(0, -arm),
        cursorLocal + const Offset(0, arm), cross);
    canvas.drawCircle(cursorLocal, 4.0, cross);
  }

  @override
  bool shouldRepaint(_AssemblyPreviewPainter old) =>
      old.cursorLocal != cursorLocal || old.color != color;
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
