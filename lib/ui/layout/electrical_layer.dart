/// The ELECTRICAL discipline layer for the unified Layout canvas.
///
/// It draws the electrical model's panels / loads / feeders placed on the
/// SHARED PDF sheet (`ElectricalPanel.layoutPos` / `Circuit.loadPos`), using a
/// [ViewportTransform] handed in by the host canvas — so it sits on the ONE
/// viewport the mechanical network shares, not a second nested `CanvasView`.
///
/// It is the same rendering + placement logic the standalone Layout tab used
/// (wiring painter with the engine's geo cable length, panel + load markers,
/// palette drop / drag-to-move, the unplaced tray), refactored to be:
///  • transform-driven (the host owns pan/zoom), and
///  • [interactive]-gated — when this layer is the active discipline it accepts
///    drops / drags / clicks; when it's a faded coordination layer it renders at
///    reduced opacity and is wrapped pointer-ignoring by the host.
///
/// Styled with MechXTheme (no Material). The pure engine derives the geo length.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart'
    show breakerScheduleLabel;
import 'package:mechx_engine/units.dart';

import '../../store/app_state.dart';
import '../../store/electrical_store.dart';
import '../../store/project_store.dart';
import '../canvas/viewport.dart';
import '../electrical/electrical_canvas.dart' show phaseColorFor;
import '../electrical/electrical_format.dart';
import '../electrical/load_symbols.dart';
import '../electrical/electrical_layout_view.dart'
    show
        kLayoutLod,
        kLayoutPanelW,
        kLayoutPanelH,
        kLayoutLoadW,
        kLayoutLoadH,
        LayoutPanelEdit,
        LayoutCircuitEdit,
        LayoutPanelMenu,
        LayoutCircuitMenu;
import '../electrical/electrical_palette.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/glass_surface.dart';
import '../widgets/mechx_scrollbar.dart';

/// Opacity applied when the electrical layer is a faded coordination layer.
const double kElectricalFadedAlpha = 0.34;

/// ≈18 screen px snap radius for the drag-place preview ring — a panel within
/// this distance of the cursor is highlighted as the load's drop parent. Mirrors
/// the mechanical [DropOverlay] preview affordance (its ring is 14px on small
/// nodes; panels are larger, so a slightly wider radius reads right).
const double _kElecSnapScreenPx = 18;

/// Screen-px diameter of the feeder OUTLET grip mounted on the right edge of the
/// SELECTED placed panel marker (drag it onto another board to feed it). Kept
/// screen-constant so it stays grabbable at any zoom — like the single-line
/// canvas's own outlet handle.
const double _kFeederGripScreenPx = 20;

/// Gap (screen px) between the marker's right edge and the grip, so the grip
/// sits fully OUTSIDE the marker's own hit rect and can never steal the marker's
/// move-pan.
const double _kFeederGripGapPx = 3;

/// The nearest PLACED panel on [sheetId]/[floorIndex] whose position is within
/// the drop snap radius of [world], or null.
///
/// ONE helper for both the drag-preview RING and the drop COMMIT: the ring used
/// to promise an [_kElecSnapScreenPx] radius while the commit attached to the
/// nearest panel at ANY distance, so a load dropped on blank plan far from every
/// board silently joined one. Now the ring and the drop read the same rule, and
/// beyond the radius the honest floating-load fallback applies.
({String id, Offset world})? _nearestPanelWithinSnap(
  ElectricalProject project, {
  required String sheetId,
  required int floorIndex,
  required Offset world,
  required double scale,
}) {
  final snapWorld = _kElecSnapScreenPx / (scale <= 0 ? 1.0 : scale);
  var bestD2 = snapWorld * snapWorld;
  String? bestId;
  Offset? bestPos;
  for (final p in project.panels) {
    final pos = p.layoutPos;
    if (pos == null || pos.sheetId != sheetId || pos.floorIndex != floorIndex) {
      continue;
    }
    final dx = pos.x - world.dx;
    final dy = pos.y - world.dy;
    final d2 = dx * dx + dy * dy;
    if (d2 <= bestD2) {
      bestD2 = d2;
      bestId = p.id;
      bestPos = Offset(pos.x, pos.y);
    }
  }
  return bestId == null ? null : (id: bestId, world: bestPos!);
}

/// Toast the SIZED outcome of a way just added by a drop — the same sentence the
/// electrical single-line canvas's `_dropLoadOnPanel` shows, so the two drop
/// surfaces report a drop identically. Silent when the solve carries no record
/// for the new way (nothing is fabricated).
void _toastSizedDrop(
  WidgetRef ref,
  BuildContext context,
  String panelId,
  String circuitId,
  String parentLabel,
) {
  final sized = ref
      .read(electricalResultProvider)
      .panels[panelId]
      ?.circuits
      .where((c) => c.circuitId == circuitId)
      .firstOrNull;
  if (sized == null) return;
  final poles = sized.threePhase ? 3 : 1;
  ref.read(statusMessageProvider.notifier).showStatus(
      context.strings.format(
        StringKey.electricalCircuitAddedTemplate,
        {
          'name': sized.name,
          'parent': parentLabel,
          'breaker': breakerScheduleLabel(sized.breaker, poles),
          'csa': fmtNum(sized.cable.csaMm2),
          'vd': sized.voltageDrop.dropPercent.toStringAsFixed(1),
        },
      ));
}

/// Toast a newly minted board: `fed from <parent>` when a source board was named
/// (the single-line canvas's own feeder-card wording), else a plain `placed` —
/// a blank-plan drop is utility-fed, so claiming a parent would be a lie. Any
/// template ways that arrived with it are counted.
void _toastNewPanel(
  WidgetRef ref,
  BuildContext context,
  String newPanelId, {
  String? fedFrom,
}) {
  final added = ref
      .read(electricalProjectProvider)
      .panels
      .where((p) => p.id == newPanelId)
      .firstOrNull;
  final name = added == null ? 'Sub-panel' : (added.tag ?? added.name);
  final ways = added?.circuits.where((c) => c.loadKind != LoadKind.feeder).length ?? 0;

  if (ways > 0) {
    if (fedFrom == null) {
      ref.read(statusMessageProvider.notifier).showStatus(
        context.strings.format(
          StringKey.electricalPanelPlacedWithWaysTemplate,
          {'panel': name, 'count': ways.toString()},
        ),
      );
    } else {
      ref.read(statusMessageProvider.notifier).showStatus(
        context.strings.format(
          StringKey.electricalPanelFedWithWaysTemplate,
          {'panel': name, 'parent': fedFrom, 'count': ways.toString()},
        ),
      );
    }
  } else if (fedFrom == null) {
    ref.read(statusMessageProvider.notifier).showStatus(
      context.strings.format(
        StringKey.electricalPanelPlacedTemplate,
        {'panel': name},
      ),
    );
  } else {
    ref.read(statusMessageProvider.notifier).showStatus(
      context.strings.format(
        StringKey.electricalFedFromTemplate,
        {'child': name, 'parent': fedFrom},
      ),
    );
  }
}

/// The electrical layer painted over the shared sheet at [transform].
///
/// When [interactive] is true it hosts the drop / drag / tap affordances and
/// the unplaced tray; when false it draws faded markers + wiring only (the host
/// also wraps it in an `IgnorePointer`, so editing routes to the active layer).
class ElectricalLayoutLayer extends ConsumerWidget {
  final ViewportTransform transform;
  final String sheetId;
  final int floorIndex;
  final bool interactive;
  final LayoutPanelEdit onEditPanel;
  final LayoutCircuitEdit onEditCircuit;
  final LayoutPanelMenu onPanelMenu;
  final LayoutCircuitMenu onCircuitMenu;

  const ElectricalLayoutLayer({
    super.key,
    required this.transform,
    required this.sheetId,
    required this.floorIndex,
    required this.interactive,
    required this.onEditPanel,
    required this.onEditCircuit,
    required this.onPanelMenu,
    required this.onCircuitMenu,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Ease the coordination fade: when the active discipline switches, the
    // layer's markers + wiring cross-fade between full opacity and the faded
    // coordination alpha over MechXMotion.appear (instead of snapping). The
    // endpoints are byte-identical to the old instant values.
    // Build the layer ONCE (full opacity) as the tween's `child` and apply the
    // fade with a single outer Opacity in the builder — so the panel/load nodes,
    // wiring painter, drop targets and tray are NOT rebuilt 60×/s during the
    // 220ms cross-fade (only the cheap Opacity wrapper re-runs per frame).
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: interactive ? 1.0 : kElectricalFadedAlpha),
      duration: MechXMotion.appear,
      curve: MechXMotion.standard,
      child: _buildLayer(context, ref, 1.0),
      builder: (context, opacity, child) =>
          Opacity(opacity: opacity, child: child),
    );
  }

  Widget _buildLayer(BuildContext context, WidgetRef ref, double opacity) {
    final colors = context.colors;
    final project = ref.watch(electricalProjectProvider);
    final result = ref.watch(electricalResultProvider);
    final ctrl = ref.read(electricalProjectProvider.notifier);
    // The selected element on this layer (I5) — drives the marker ring; a marker
    // tap sets it, Delete removes it via the existing intents (wired in the host
    // canvas's key handler).
    final selection = ref.watch(electricalSelectionProvider);
    final selectionCtrl = ref.read(electricalSelectionProvider.notifier);
    final vt = transform;

    bool onSheet(LayoutPos? pos) =>
        pos != null && pos.sheetId == sheetId && pos.floorIndex == floorIndex;

    final placedPanels = [
      for (final p in project.panels)
        if (onSheet(p.layoutPos)) p,
    ];

    final nodeWidgets = <Widget>[
      for (final p in placedPanels)
        ..._panelNodes(context, ref, ctrl, selectionCtrl, selection, p, result,
            vt, opacity),
      // Floating loads — placed circuits whose stub board is NOT itself placed
      // on this sheet (drop-on-blank). Render the load icon on its own.
      for (final p in project.panels)
        if (!onSheet(p.layoutPos))
          ..._loadNodes(context, ref, ctrl, selectionCtrl, selection, p, result,
              vt, opacity),
    ];

    return Stack(
      children: [
        // Wiring (cable + feeder lines) painted in screen space over the sheet.
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _WiringPainter(
                project: project,
                result: result,
                sheetId: sheetId,
                floorIndex: floorIndex,
                transform: vt,
                detail: vt.scale >= kLayoutLod,
                accent: colors.accent,
                onAccent: colors.onAccent,
                opacity: opacity,
                calibrationBySheet:
                    ref.read(projectControllerProvider).calibrations,
                building: ref.read(projectControllerProvider).building,
              ),
            ),
          ),
        ),
        // Drop targets + tray only when this layer is the active (editable) one.
        if (interactive) ...[
          Positioned.fill(
            child: _SheetDropTarget(
              transform: vt,
              sheetId: sheetId,
              floorIndex: floorIndex,
              controller: ctrl,
            ),
          ),
          Positioned.fill(
            child: _TrayDropTarget(
              transform: vt,
              sheetId: sheetId,
              floorIndex: floorIndex,
              controller: ctrl,
            ),
          ),
        ],
        // Placed node widgets — pointer-ignored when faded so the active layer
        // (mechanical overlays / drops) receives the gestures.
        if (interactive)
          ...nodeWidgets
        else
          IgnorePointer(child: Stack(children: nodeWidgets)),
        // The feeder OUTLET grip on the SELECTED placed board (+ its in-flight
        // rubber band / hover verdict ring). Mounted ONLY while a whole PANEL is
        // selected, so an idle canvas with nothing selected is byte-identical;
        // the rubber band + rings exist only for the duration of a drag.
        if (interactive && selection != null && !selection.isCircuit)
          Positioned.fill(
            child: _FeederGripLayer(
              transform: vt,
              sheetId: sheetId,
              floorIndex: floorIndex,
              panelId: selection.panelId,
            ),
          ),
        if (interactive)
          // J5: pin the tray to the TOP-RIGHT only (no `bottom`), so the glass
          // slab sizes to its content instead of stretching to full canvas
          // height and occluding the plan it exists to coordinate against.
          // `_UnplacedTray` caps its own scroll region (see `_kTrayMaxHeight`).
          Positioned(
            right: MechXSpacing.md,
            // Sit BELOW the top-right minimap (≤108px tall, pinned at top:sm on
            // the Layout canvas) so the two top-right overlays don't collide —
            // the tray was overlapping and clipping against it.
            top: MechXSpacing.sm + 108 + MechXSpacing.md,
            child: _UnplacedTray(
              project: project,
              result: result,
              sheetId: sheetId,
            ),
          ),
      ],
    );
  }

  List<Widget> _panelNodes(
    BuildContext context,
    WidgetRef ref,
    ElectricalProjectController ctrl,
    ElectricalSelectionController selectionCtrl,
    ElectricalSelection? selection,
    ElectricalPanel panel,
    ElectricalSystemResult result,
    ViewportTransform vt,
    double opacity,
  ) {
    final pos = panel.layoutPos!;
    final pr = result.panels[panel.id];
    final detail = vt.scale >= kLayoutLod;
    final widgets = <Widget>[];

    final pTopLeft = vt.worldToScreen(Offset(pos.x, pos.y));
    widgets.add(Positioned(
      left: pTopLeft.dx - kLayoutPanelW * vt.scale / 2,
      top: pTopLeft.dy - kLayoutPanelH * vt.scale / 2,
      width: kLayoutPanelW * vt.scale,
      height: kLayoutPanelH * vt.scale,
      child: Opacity(
        opacity: opacity,
        child: _LayoutNodeDraggable(
          enabled: interactive,
          scale: vt.scale,
          world: Offset(pos.x, pos.y),
          onDragStart: ctrl.pushUndoSnapshot,
          onMove: (w) =>
              ctrl.setPanelLayoutPos(panel.id, pos.copyWith(x: w.dx, y: w.dy)),
          child: _ScaledLayoutChild(
            scale: vt.scale,
            width: kLayoutPanelW,
            height: kLayoutPanelH,
            child: _PanelMarker(
              panel: panel,
              result: pr,
              detail: detail,
              selected: selection != null &&
                  !selection.isCircuit &&
                  selection.panelId == panel.id,
              onTap: () => selectionCtrl.selectPanel(panel.id),
              onDoubleTap: () => onEditPanel(panel.id),
              onMenu: (gp) => onPanelMenu(panel.id, gp),
              onDropLoad: (load) => _dropOnMarker(ref, context, ctrl, panel, load),
            ),
          ),
        ),
      ),
    ));

    widgets.addAll(_loadNodes(context, ref, ctrl, selectionCtrl, selection,
        panel, result, vt, opacity));
    return widgets;
  }

  /// The placed-LOAD icons for a panel's circuits (those with a `loadPos` on
  /// this sheet). Rendered for EVERY panel — including a floating-load stub
  /// board that has no `layoutPos` — so a load dropped on blank plan shows as
  /// its symbol rather than vanishing or becoming a panel.
  List<Widget> _loadNodes(
    BuildContext context,
    WidgetRef ref,
    ElectricalProjectController ctrl,
    ElectricalSelectionController selectionCtrl,
    ElectricalSelection? selection,
    ElectricalPanel panel,
    ElectricalSystemResult result,
    ViewportTransform vt,
    double opacity,
  ) {
    final pr = result.panels[panel.id];
    final detail = vt.scale >= kLayoutLod;
    final widgets = <Widget>[];
    for (final c in panel.circuits) {
      final lp = c.loadPos;
      if (lp == null ||
          lp.sheetId != sheetId ||
          lp.floorIndex != floorIndex) {
        continue;
      }
      if (c.loadKind == LoadKind.feeder) continue;
      final cr = pr?.circuits.where((r) => r.circuitId == c.id).firstOrNull;
      final lScreen = vt.worldToScreen(Offset(lp.x, lp.y));
      widgets.add(Positioned(
        left: lScreen.dx - kLayoutLoadW * vt.scale / 2,
        top: lScreen.dy - kLayoutLoadH * vt.scale / 2,
        width: kLayoutLoadW * vt.scale,
        height: kLayoutLoadH * vt.scale,
        child: Opacity(
          opacity: opacity,
          child: _LayoutNodeDraggable(
            enabled: interactive,
            scale: vt.scale,
            world: Offset(lp.x, lp.y),
            onDragStart: ctrl.pushUndoSnapshot,
            onMove: (w) =>
                ctrl.setLoadPos(panel.id, c.id, lp.copyWith(x: w.dx, y: w.dy)),
            // Dropped ONTO another load on the SAME panel → CHAIN them (one
            // breaker); otherwise the live onMove already repositioned it.
            onDropAt: (w) {
              final target = _loadDroppedOnto(panel, c.id, w);
              if (target != null) ctrl.mergeCircuit(panel.id, c.id, target);
            },
            child: _ScaledLayoutChild(
              scale: vt.scale,
              width: kLayoutLoadW,
              height: kLayoutLoadH,
              child: _LoadMarker(
                circuit: c,
                result: cr,
                detail: detail,
                selected: selection != null &&
                    selection.isCircuit &&
                    selection.panelId == panel.id &&
                    selection.circuitId == c.id,
                onTap: () => selectionCtrl.selectCircuit(panel.id, c.id),
                onDoubleTap: () => onEditCircuit(panel.id, c.id),
                onMenu: (gp) => onCircuitMenu(panel.id, c.id, gp),
              ),
            ),
          ),
        ),
      ));
    }
    return widgets;
  }

  /// A drop of [load] ONTO a placed panel MARKER.
  ///
  /// The bug this fixes: the marker's drop used to call `addCircuit`, which
  /// creates a way with NO `loadPos` — so aiming a palette card straight at a
  /// board produced an invisible orphan that only reappeared in the "Not on this
  /// sheet" tray. The way is now created ALREADY PLACED beside the marker (and a
  /// sub-board card mints a real fed board, placed), with the same sized-result
  /// toast the single-line canvas gives.
  void _dropOnMarker(
    WidgetRef ref,
    BuildContext context,
    ElectricalProjectController ctrl,
    ElectricalPanel panel,
    PaletteLoad load,
  ) {
    // The machine-owned MEP board is rebuilt from the plan, so a hand-added way
    // there would silently vanish on the next sync (the single-line canvas's
    // `_dropLoadOnPanel` refuses it for the same reason).
    if (panel.id == kMepEquipmentPanelId) {
      ref.read(statusMessageProvider.notifier).showStatus(
            context.strings(StringKey.electricalMepEquipmentGuard),
          );
      return;
    }
    final project = ref.read(electricalProjectProvider);
    final parentLabel = panel.tag ?? panel.name;
    final pos = _besideMarker(project, panel);

    if (load.kind == LoadKind.feeder) {
      // A sub-board card dropped ON a board: mint it ALREADY FED from that board
      // (`addFedPanelAt`, one commit) and then place it beside the marker with
      // the deliberately NON-recording `setPanelLayoutPos` — so the pair is ONE
      // undo step and the result is one visible board, fed and placed, instead
      // of a stranded tray entry.
      final ordinal = nextSubPanelOrdinal(project.panels);
      final newId = ctrl.addFedPanelAt(
        fromPanelId: panel.id,
        x: 80 + ordinal * 40,
        y: 80 + ordinal * 40,
        phases: load.phases,
        templateId: load.panelTemplateId,
      );
      ctrl.setPanelLayoutPos(newId, pos);
      _toastNewPanel(ref, context, newId, fedFrom: parentLabel);
      return;
    }

    final circuitId = ctrl.addLoadAtLayout(
      panel.id,
      kind: load.kind,
      pos: pos,
      phases: load.phases,
      loadW: load.loadW > 0 ? load.loadW : null,
      motorKw: load.motorKw,
    );
    _toastSizedDrop(ref, context, panel.id, circuitId, parentLabel);
  }

  /// A spot on THIS sheet/floor just to the RIGHT of [panel]'s marker for a node
  /// dropped ON that marker — offset by one full marker width so the new icon
  /// never covers the board it belongs to, and stepped DOWN past anything
  /// already parked there so repeat drops fan out instead of stacking.
  LayoutPos _besideMarker(ElectricalProject project, ElectricalPanel panel) {
    final anchor = panel.layoutPos!;
    final taken = <Offset>[];
    for (final p in project.panels) {
      final lp = p.layoutPos;
      if (lp != null && lp.sheetId == sheetId && lp.floorIndex == floorIndex) {
        taken.add(Offset(lp.x, lp.y));
      }
      for (final c in p.circuits) {
        final cp = c.loadPos;
        if (cp != null && cp.sheetId == sheetId && cp.floorIndex == floorIndex) {
          taken.add(Offset(cp.x, cp.y));
        }
      }
    }
    final x = anchor.x + kLayoutPanelW;
    var y = anchor.y;
    for (var i = 0; i < 24; i++) {
      final here = Offset(x, y);
      if (!taken.any((t) => (t - here).distance < kLayoutLoadH)) break;
      y += kLayoutLoadH * 1.4;
    }
    return LayoutPos(
        sheetId: sheetId, floorIndex: floorIndex, x: x, y: y);
  }

  /// The id of another placed load on [panel] (this sheet/floor) whose marker the
  /// dragged load [draggedId] was released over (within ~one load-node width),
  /// or null. Used to CHAIN loads onto one breaker by dropping one onto another.
  String? _loadDroppedOnto(
      ElectricalPanel panel, String draggedId, Offset world) {
    final r = kLayoutLoadW; // ~one node width, in world px
    final r2 = r * r;
    String? best;
    var bestD2 = r2;
    for (final c in panel.circuits) {
      if (c.id == draggedId || c.loadKind == LoadKind.feeder) continue;
      final lp = c.loadPos;
      if (lp == null || lp.sheetId != sheetId || lp.floorIndex != floorIndex) {
        continue;
      }
      final dx = lp.x - world.dx;
      final dy = lp.y - world.dy;
      final d2 = dx * dx + dy * dy;
      if (d2 <= bestD2) {
        bestD2 = d2;
        best = c.id;
      }
    }
    return best;
  }
}

// ── Wiring painter (cable panel→load + feeder panel→sub-panel) ───────────────

class _WiringPainter extends CustomPainter {
  final ElectricalProject project;
  final ElectricalSystemResult result;
  final String sheetId;
  final int floorIndex;
  final ViewportTransform transform;
  final bool detail;
  final Color accent;
  final Color onAccent;
  final double opacity;
  final Map<String, ScaleCalibration> calibrationBySheet;
  final BuildingLevels building;

  _WiringPainter({
    required this.project,
    required this.result,
    required this.sheetId,
    required this.floorIndex,
    required this.transform,
    required this.detail,
    required this.accent,
    required this.onAccent,
    required this.opacity,
    required this.calibrationBySheet,
    required this.building,
  });

  bool _onSheet(LayoutPos? pos) =>
      pos != null && pos.sheetId == sheetId && pos.floorIndex == floorIndex;

  Offset? _panelScreen(String id) {
    final p = project.panels.where((p) => p.id == id).firstOrNull;
    if (p == null || !_onSheet(p.layoutPos)) return null;
    final pos = p.layoutPos!;
    return transform.worldToScreen(Offset(pos.x, pos.y));
  }

  // The wiring colours (accent / phase) are opaque, so scaling the 255 alpha by
  // [opacity] is the fade (avoids the deprecated `.alpha` getter).
  Color _fade(Color base) =>
      opacity >= 1.0 ? base : base.withAlpha((255 * opacity).round());

  @override
  void paint(Canvas canvas, Size size) {
    final byId = {for (final p in project.panels) p.id: p};
    for (final p in project.panels) {
      if (!_onSheet(p.layoutPos)) continue;
      final pos = p.layoutPos!;
      final from = transform.worldToScreen(Offset(pos.x, pos.y));
      final pr = result.panels[p.id];
      for (final c in p.circuits) {
        if (c.feedsPanelId != null) {
          final to = _panelScreen(c.feedsPanelId!);
          if (to == null) continue;
          _line(canvas, from, to, _fade(accent), width: 2.2);
          _arrowHead(canvas, from, to, _fade(accent));
          if (detail && opacity >= 1.0) {
            _lengthLabel(canvas, from, to, _geoLen(c, p, byId), null, null);
          }
          continue;
        }
        if (c.loadKind == LoadKind.feeder) continue;
        if (!_onSheet(c.loadPos)) continue;
        final lp = c.loadPos!;
        final to = transform.worldToScreen(Offset(lp.x, lp.y));
        final cr =
            pr?.circuits.where((r) => r.circuitId == c.id).firstOrNull;
        final color = cr == null
            ? accent
            : phaseColorFor(
                cr.phase, p.system == ElectricalSystem.threePhase);
        _line(canvas, from, to, _fade(color), width: 1.8);
        if (detail && opacity >= 1.0) {
          _lengthLabel(canvas, from, to, _geoLen(c, p, byId),
              cr?.grounding.cableSpec, _util(cr));
        }
      }
    }
  }

  double _geoLen(ElectricalCircuit c, ElectricalPanel panel,
          Map<String, ElectricalPanel> byId) =>
      resolveCircuitLength(
        c,
        panel,
        calibrationBySheet: calibrationBySheet,
        building: building,
        panelById: byId,
      ).meters;

  double? _util(ElectricalCircuitResult? cr) {
    if (cr == null) return null;
    final rating = cr.breaker.ratingA.amperes;
    if (rating <= 0) return null;
    return cr.designCurrent.amperes / rating * 100;
  }

  void _line(Canvas canvas, Offset a, Offset b, Color color,
      {required double width}) {
    canvas.drawLine(
      a,
      b,
      Paint()
        ..color = color
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(b, 3, Paint()..color = color);
  }

  void _arrowHead(Canvas canvas, Offset a, Offset b, Color color) {
    final dir = (b - a);
    final len = dir.distance;
    if (len < 1) return;
    final u = dir / len;
    final back = b - u * 10;
    final perp = Offset(-u.dy, u.dx) * 5;
    final path = Path()
      ..moveTo(b.dx, b.dy)
      ..lineTo(back.dx + perp.dx, back.dy + perp.dy)
      ..lineTo(back.dx - perp.dx, back.dy - perp.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _lengthLabel(Canvas canvas, Offset a, Offset b, double lenM,
      String? cableSpec, double? util) {
    final mid = (a + b) / 2;
    final String lenTxt;
    if (lenM <= 0) {
      lenTxt = 'set scale';
    } else if (lenM >= 10) {
      lenTxt = '${lenM.toStringAsFixed(0)} m';
    } else {
      lenTxt = '${lenM.toStringAsFixed(1)} m';
    }
    final parts = <String>[
      lenTxt,
      ?cableSpec,
      if (util != null) '${util.round()}%',
    ];
    final tp = TextPainter(
      text: TextSpan(
        text: parts.join(' · '),
        style: TextStyle(
          fontFamily: 'Roboto',
          fontSize: 9.5,
          color: onAccent,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect = Rect.fromCenter(
        center: mid, width: tp.width + 10, height: tp.height + 6);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, MechXRadii.xs),
      Paint()..color = const Color(0xE015171B),
    );
    tp.paint(canvas, mid - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_WiringPainter old) =>
      old.project != project ||
      old.result != result ||
      old.sheetId != sheetId ||
      old.floorIndex != floorIndex ||
      old.transform != transform ||
      old.detail != detail ||
      old.opacity != opacity ||
      old.calibrationBySheet != calibrationBySheet ||
      old.building != building;
}

// ── Placed panel marker ──────────────────────────────────────────────────────

class _PanelMarker extends StatefulWidget {
  final ElectricalPanel panel;
  final ElectricalPanelResult? result;
  final bool detail;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final ValueChanged<Offset> onMenu;
  final ValueChanged<PaletteLoad> onDropLoad;

  const _PanelMarker({
    required this.panel,
    required this.result,
    required this.detail,
    required this.selected,
    required this.onTap,
    required this.onDoubleTap,
    required this.onMenu,
    required this.onDropLoad,
  });

  @override
  State<_PanelMarker> createState() => _PanelMarkerState();
}

class _PanelMarkerState extends State<_PanelMarker> {
  bool _hover = false;
  bool _dropHover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final p = widget.panel;
    final r = widget.result;
    final hasError = r != null &&
        r.warnings.any((w) => w.severity == WarningSeverity.error);
    final border = hasError
        ? colors.danger
        : (widget.selected || _hover || _dropHover)
            ? colors.accent
            : colors.border;

    final body = Container(
      decoration: BoxDecoration(
        color: colors.surface.withAlpha(245),
        borderRadius: MechXRadii.card,
        border: Border.all(color: border, width: widget.selected ? 2 : 1.5),
        boxShadow: MechXShadow.card,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(
              color: colors.accent,
              borderRadius: const BorderRadius.all(Radius.circular(2)),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(p.tag ?? p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.label.copyWith(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w700)),
                if (widget.detail && r != null)
                  Text(
                    '${fmtAmp0(r.demandCurrent.amperes)} A · '
                    '${fmtAmp0(r.incomer.breaker.ratingA.amperes)}/${r.incomer.poles}P',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.caption.copyWith(
                        color: colors.textMuted,
                        fontFamily: 'Roboto Mono'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    return DragTarget<PaletteLoad>(
      onWillAcceptWithDetails: (_) {
        setState(() => _dropHover = true);
        return true;
      },
      onLeave: (_) => setState(() => _dropHover = false),
      onAcceptWithDetails: (d) {
        setState(() => _dropHover = false);
        widget.onDropLoad(d.data);
      },
      builder: (context, candidate, rejected) {
        return MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Listener(
            onPointerDown: (e) {
              if (e.buttons == kSecondaryButton) widget.onMenu(e.position);
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              onDoubleTap: widget.onDoubleTap,
              // Subtle hover/drop lift signalling the marker is interactive.
              child: AnimatedScale(
                scale: (_hover || _dropHover) ? MechXMotion.hoverLift : 1.0,
                duration: MechXMotion.hover,
                curve: MechXMotion.standard,
                child: body,
              ),
            ),
          ),
        );
      },
    );
  }
}

// ── Placed load marker ───────────────────────────────────────────────────────

class _LoadMarker extends StatefulWidget {
  final ElectricalCircuit circuit;
  final ElectricalCircuitResult? result;
  final bool detail;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final ValueChanged<Offset> onMenu;

  const _LoadMarker({
    required this.circuit,
    required this.result,
    required this.detail,
    required this.selected,
    required this.onTap,
    required this.onDoubleTap,
    required this.onMenu,
  });

  @override
  State<_LoadMarker> createState() => _LoadMarkerState();
}

class _LoadMarkerState extends State<_LoadMarker> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final c = widget.circuit;
    final r = widget.result;
    final rating = r?.breaker.ratingA.amperes ?? 0;
    final util =
        (r != null && rating > 0) ? (r.designCurrent.amperes / rating * 100) : null;

    // Icon-first: the load's industry-standard symbol in a small chip, with the
    // name (and amps) as a quiet caption below it only when zoomed in.
    final active = _hover || widget.selected;
    final symbolColor = active ? colors.accent : colors.textSecondary;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.surface.withAlpha(245),
            borderRadius: MechXRadii.control,
            border: Border.all(
                color: active ? colors.accent : colors.border,
                width: widget.selected ? 2 : 1),
            boxShadow: MechXShadow.card,
          ),
          child: LoadSymbol(kind: c.loadKind, color: symbolColor, size: 20),
        ),
        if (widget.detail) ...[
          const SizedBox(height: 2),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: colors.surface.withAlpha(220),
              borderRadius: MechXRadii.small,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.caption.copyWith(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 9)),
                if (rating > 0)
                  Text(
                    util != null
                        ? '${fmtAmp0(rating)}A · ${util.round()}%'
                        : '${fmtAmp0(rating)}A',
                    style:
                        type.caption.copyWith(color: colors.textMuted, fontSize: 8),
                  ),
              ],
            ),
          ),
        ],
      ],
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Listener(
        onPointerDown: (e) {
          if (e.buttons == kSecondaryButton) widget.onMenu(e.position);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onDoubleTap: widget.onDoubleTap,
          // Subtle hover lift signalling the marker is interactive.
          child: AnimatedScale(
            scale: _hover ? MechXMotion.hoverLift : 1.0,
            duration: MechXMotion.hover,
            curve: MechXMotion.standard,
            child: body,
          ),
        ),
      ),
    );
  }

}

// ── Node drag (move a placed node) ───────────────────────────────────────────

class _LayoutNodeDraggable extends StatefulWidget {
  final bool enabled;
  final double scale;
  final Offset world;

  /// Fired once at drag start — the host pushes one undo snapshot here so the
  /// whole move (live [onMove] updates don't record) is a single undo step.
  final VoidCallback? onDragStart;
  final ValueChanged<Offset> onMove;

  /// Fired on release with the final world position — lets the host decide
  /// whether the node was dropped ONTO another (e.g. to chain loads).
  final ValueChanged<Offset>? onDropAt;
  final Widget child;

  const _LayoutNodeDraggable({
    required this.enabled,
    required this.scale,
    required this.world,
    this.onDragStart,
    required this.onMove,
    this.onDropAt,
    required this.child,
  });

  @override
  State<_LayoutNodeDraggable> createState() => _LayoutNodeDraggableState();
}

class _LayoutNodeDraggableState extends State<_LayoutNodeDraggable> {
  Offset? _dragWorld;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) {
        widget.onDragStart?.call();
        _dragWorld = widget.world;
      },
      onPanUpdate: (d) {
        final next = (_dragWorld ?? widget.world) + d.delta / widget.scale;
        _dragWorld = next;
        widget.onMove(next);
      },
      onPanEnd: (_) {
        final w = _dragWorld;
        _dragWorld = null;
        if (w != null) widget.onDropAt?.call(w);
      },
      child: widget.child,
    );
  }
}

// ── Scaled-child wrapper (lay out at natural world size, then visually scale) ──

class _ScaledLayoutChild extends StatelessWidget {
  final double scale;
  final double width;
  final double height;
  final Widget child;

  const _ScaledLayoutChild({
    required this.scale,
    required this.width,
    required this.height,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: scale,
      alignment: Alignment.topLeft,
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: 0,
        maxWidth: double.infinity,
        minHeight: 0,
        maxHeight: double.infinity,
        child: SizedBox(width: width, height: height, child: child),
      ),
    );
  }
}

// ── Sheet-wide palette drop target ───────────────────────────────────────────

class _SheetDropTarget extends ConsumerStatefulWidget {
  final ViewportTransform transform;
  final String sheetId;
  final int floorIndex;
  final ElectricalProjectController controller;

  const _SheetDropTarget({
    required this.transform,
    required this.sheetId,
    required this.floorIndex,
    required this.controller,
  });

  @override
  ConsumerState<_SheetDropTarget> createState() => _SheetDropTargetState();
}

class _SheetDropTargetState extends ConsumerState<_SheetDropTarget> {
  bool _active = false;

  /// The live drag position (LOCAL canvas px) and payload, set on move and
  /// cleared on leave/accept. Transient — exists only during a drag gesture.
  Offset? _dragLocal;
  PaletteLoad? _dragLoad;

  Offset? _toLocal(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    return box?.globalToLocal(global);
  }

  void _clearDrag() {
    if (_active || _dragLocal != null || _dragLoad != null) {
      setState(() {
        _active = false;
        _dragLocal = null;
        _dragLoad = null;
      });
    }
  }

  /// The nearest placed panel (this sheet/floor) within the snap radius of
  /// [world] in SCREEN space, or null — so the ring marks the panel a load drop
  /// will attach to. Shares [_nearestPanelWithinSnap] with the drop COMMIT, so
  /// the ring and the drop can never disagree.
  Offset? _nearestPanelScreen(Offset world) {
    final hit = _nearestPanelWithinSnap(
      ref.read(electricalProjectProvider),
      sheetId: widget.sheetId,
      floorIndex: widget.floorIndex,
      world: world,
      scale: widget.transform.scale,
    );
    return hit == null ? null : widget.transform.worldToScreen(hit.world);
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<PaletteLoad>(
      hitTestBehavior: HitTestBehavior.translucent,
      onWillAcceptWithDetails: (d) {
        setState(() {
          _active = true;
          _dragLoad = d.data;
        });
        return true;
      },
      onMove: (d) {
        final local = _toLocal(d.offset);
        if (local == null) return;
        setState(() {
          _active = true;
          _dragLocal = local;
          _dragLoad = d.data;
        });
      },
      onLeave: (_) => _clearDrag(),
      onAcceptWithDetails: (d) {
        final box = context.findRenderObject() as RenderBox?;
        if (box != null) {
          final local = box.globalToLocal(d.offset);
          final world = widget.transform.screenToWorld(local);
          _drop(d.data, world);
        }
        _clearDrag();
      },
      builder: (context, candidate, rejected) {
        final accent = context.colors.accent;
        // Resolve the live snap target (screen space) for the preview paint.
        Offset? snapScreen;
        if (_active && _dragLocal != null) {
          final world = widget.transform.screenToWorld(_dragLocal!);
          snapScreen = _nearestPanelScreen(world);
        }
        final willSnap = snapScreen != null;
        // Cross-fade the drop highlight in/out instead of popping; idle is
        // pointer-ignored so the canvas keeps panning. Tint + radius + the
        // will-snap strengthening MATCH the mechanical DropOverlay.
        return IgnorePointer(
          ignoring: !_active,
          child: Stack(
            children: [
              Positioned.fill(
                child: AnimatedOpacity(
                  opacity: _active ? 1.0 : 0.0,
                  duration: MechXMotion.hover,
                  curve: MechXMotion.standard,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: accent.withAlpha(willSnap ? 35 : 18),
                      border: Border.all(
                          color: accent.withAlpha(willSnap ? 170 : 120),
                          width: 1.5),
                      borderRadius: MechXRadii.card,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              // The drag preview: a faint ghost LOAD symbol at the cursor + a
              // snap ring on the nearest panel. Paints ONLY during a drag.
              if (_active && _dragLocal != null && _dragLoad != null)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _ElecDropPreviewPainter(
                      kind: _dragLoad!.kind,
                      cursorLocal: _dragLocal!,
                      snapScreen: snapScreen,
                      color: accent,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  void _drop(PaletteLoad load, Offset world) {
    final pos = LayoutPos(
      sheetId: widget.sheetId,
      floorIndex: widget.floorIndex,
      x: world.dx,
      y: world.dy,
    );
    final project = ref.read(electricalProjectProvider);

    if (load.kind == LoadKind.feeder) {
      // The designation comes from the SHARED `nextSubPanelOrdinal` mint (max+1
      // across the existing 'Sub-panel N' / 'SP-N' names and tags), not from
      // `panels.length + 1` — deleting SP-2 of three used to re-mint SP-2 and
      // collide with a designation an issued schedule already carried.
      final n = nextSubPanelOrdinal(project.panels);
      final newId = widget.controller.addPanelAt(
        name: 'Sub-panel $n',
        tag: 'SP-$n',
        x: 80 + n * 40,
        y: 80 + n * 40,
        system: load.phases == 1
            ? ElectricalSystem.singlePhase
            : ElectricalSystem.threePhase,
        voltage:
            load.phases == 1 ? const Voltage(220) : const Voltage(400),
        // A template card (lighting / power / mixed board) arrives populated —
        // inside `addPanelAt`'s SINGLE commit, so it stays one undo step.
        templateId: load.panelTemplateId,
      );
      // Non-recording placement paired with that commit ⇒ still ONE undo step.
      widget.controller.setPanelLayoutPos(newId, pos);
      _toastNewPanel(ref, context, newId);
      return;
    }

    final nearest = _nearestPanelWithinSnap(
      project,
      sheetId: widget.sheetId,
      floorIndex: widget.floorIndex,
      world: world,
      scale: widget.transform.scale,
    );
    if (nearest == null) {
      // Nothing within the ring's own radius — drop a floating LOAD (rendered as
      // its icon), not a generic panel. It stays a utility-fed stub until wired
      // to a feeder.
      widget.controller.addFloatingLoadAtLayout(
        kind: load.kind,
        pos: pos,
        phases: load.phases,
        loadW: load.loadW > 0 ? load.loadW : null,
        motorKw: load.motorKw,
      );
      return;
    }
    final parent = project.panels.firstWhere((p) => p.id == nearest.id);
    final circuitId = widget.controller.addLoadAtLayout(
      nearest.id,
      kind: load.kind,
      pos: pos,
      phases: load.phases,
      loadW: load.loadW > 0 ? load.loadW : null,
      motorKw: load.motorKw,
    );
    _toastSizedDrop(ref, context, nearest.id, circuitId, parent.tag ?? parent.name);
  }
}

/// Paints the drag-place preview for the electrical layer: a translucent ghost
/// [LoadSymbol] of the dragged load at the cursor, and (when snapping) a ring +
/// crosshair over the target panel. Drag-only, so it never affects the at-rest
/// canvas — mirrors the mechanical `_DropPreviewPainter`.
class _ElecDropPreviewPainter extends CustomPainter {
  final LoadKind kind;
  final Offset cursorLocal;
  final Offset? snapScreen;
  final Color color;

  _ElecDropPreviewPainter({
    required this.kind,
    required this.cursorLocal,
    required this.snapScreen,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // ── Ghost glyph at the cursor (≈36px box, ~45% opacity) ──────────────────
    const box = 36.0;
    final ghostColor = color.withAlpha(115);
    canvas.save();
    canvas.translate(cursorLocal.dx - box / 2, cursorLocal.dy - box / 2);
    paintLoadSymbol(canvas, const Size(box, box), kind, ghostColor, stroke: 2.0);
    canvas.restore();

    // ── Snap indicator: a ring + crosshair over the target panel ─────────────
    final snap = snapScreen;
    if (snap != null) {
      final ring = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawCircle(snap, _kElecSnapScreenPx, ring);
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

  @override
  bool shouldRepaint(_ElecDropPreviewPainter old) =>
      old.kind != kind ||
      old.cursorLocal != cursorLocal ||
      old.snapScreen != snapScreen ||
      old.color != color;
}

// ── Feeder outlet grip (selected board → the board it will feed) ─────────────

/// The right-edge outlet GRIP of the selected placed board, plus the in-flight
/// feeder rubber band it draws.
///
/// This is the LAYOUT counterpart of the single-line canvas's outlet handle —
/// the plan had no way to create a feeder at all, so a board placed on the plan
/// could only be wired by leaving for the single-line view. Direction matches
/// that canvas: the grip drags FROM the selected board TO the board it will
/// FEED, i.e. `connectFeeder(selected, target)`.
///
/// It is mounted as a `Positioned.fill` SIBLING of the markers (a `Stack` only
/// hit-tests where its children render), and the grip itself sits fully OUTSIDE
/// the marker's rect — so it can never steal the marker's own move-pan.
class _FeederGripLayer extends ConsumerStatefulWidget {
  final ViewportTransform transform;
  final String sheetId;
  final int floorIndex;

  /// The SELECTED board the grip hangs off.
  final String panelId;

  const _FeederGripLayer({
    required this.transform,
    required this.sheetId,
    required this.floorIndex,
    required this.panelId,
  });

  @override
  ConsumerState<_FeederGripLayer> createState() => _FeederGripLayerState();
}

class _FeederGripLayerState extends ConsumerState<_FeederGripLayer> {
  /// The board the in-flight feeder is dragged FROM — null when idle, which is
  /// also what keeps every rubber-band / ring pixel drag-gated.
  String? _from;
  Offset _cursor = Offset.zero;
  String? _hover;

  /// The hover target's VERDICT, resolved once per hover CHANGE from the store's
  /// pure `feederRefusalReason` — so the ring shows the exact rule the release
  /// will apply (never a per-frame topology query).
  bool _hoverRefused = false;

  Offset _toLocal(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    return box?.globalToLocal(global) ?? global;
  }

  bool _onSheet(LayoutPos? pos) =>
      pos != null &&
      pos.sheetId == widget.sheetId &&
      pos.floorIndex == widget.floorIndex;

  /// The screen rect of a placed panel's MARKER (the same geometry `_panelNodes`
  /// lays the marker out with).
  Rect _markerRect(LayoutPos pos) {
    final vt = widget.transform;
    final c = vt.worldToScreen(Offset(pos.x, pos.y));
    return Rect.fromCenter(
      center: c,
      width: kLayoutPanelW * vt.scale,
      height: kLayoutPanelH * vt.scale,
    );
  }

  /// The placed board whose marker contains the screen point [local].
  String? _panelAt(Offset local, {String? exclude}) {
    for (final p in ref.read(electricalProjectProvider).panels) {
      if (p.id == exclude) continue;
      final pos = p.layoutPos;
      if (!_onSheet(pos)) continue;
      if (_markerRect(pos!).contains(local)) return p.id;
    }
    return null;
  }

  void _onDragStart(Offset global) {
    setState(() {
      _from = widget.panelId;
      _cursor = _toLocal(global);
      _hover = null;
      _hoverRefused = false;
    });
  }

  void _onDragUpdate(Offset global) {
    final local = _toLocal(global);
    final hover = _panelAt(local, exclude: _from);
    var refused = _hoverRefused;
    if (hover != _hover) {
      final from = _from;
      refused = hover != null &&
          from != null &&
          ref
                  .read(electricalProjectProvider.notifier)
                  .feederRefusalReason(from, hover) !=
              null;
    }
    setState(() {
      _cursor = local;
      _hover = hover;
      _hoverRefused = refused;
    });
  }

  void _onDragEnd() {
    final from = _from;
    final to = _hover;
    if (from != null && to != null && from != to) {
      // Read the designations BEFORE the commit — the connect appends a way but
      // never renames a board, so the copy stays honest either way.
      final project = ref.read(electricalProjectProvider);
      String label(String id) {
        final p = project.panels.where((p) => p.id == id).firstOrNull;
        return p == null ? 'Panel' : (p.tag ?? p.name);
      }

      final child = label(to);
      final parent = label(from);
      final res =
          ref.read(electricalProjectProvider.notifier).connectFeeder(from, to);
      final status = ref.read(statusMessageProvider.notifier);
      if (!res.connected) {
        if (res.reason != null) status.showStatus(res.reason!);
      } else {
        final was = res.reparentedFromLabel;
        if (was == null) {
          status.showStatus(context.strings.format(
            StringKey.electricalFedFromTemplate,
            {'child': child, 'parent': parent},
          ));
        } else {
          status.showStatus(context.strings.format(
            StringKey.electricalReFedFromTemplate,
            {'child': child, 'parent': parent, 'was': was},
          ));
        }
      }
    }
    setState(() {
      _from = null;
      _hover = null;
      _hoverRefused = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final project = ref.watch(electricalProjectProvider);
    // While a drag is in flight the grip stays anchored to its SOURCE board.
    final anchorId = _from ?? widget.panelId;
    final panel = project.panels.where((p) => p.id == anchorId).firstOrNull;
    if (panel == null || !_onSheet(panel.layoutPos)) {
      return const SizedBox.shrink();
    }
    final rect = _markerRect(panel.layoutPos!);
    final anchor = Offset(rect.right, rect.center.dy);

    Rect? hoverRect;
    if (_hover != null) {
      final hp = project.panels.where((p) => p.id == _hover).firstOrNull;
      if (hp != null && _onSheet(hp.layoutPos)) {
        hoverRect = _markerRect(hp.layoutPos!);
      }
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // KEYED: the rubber band appears at index 0 the moment a drag starts,
        // and without keys the Stack would match that new `Positioned` to the
        // GRIP's `Positioned` (same runtimeType), rebuilding the grip's element
        // and destroying its live gesture recognizer mid-drag.
        if (_from != null)
          Positioned.fill(
            key: const ValueKey('electrical-feeder-band'),
            child: IgnorePointer(
              child: CustomPaint(
                painter: _FeederDragPainter(
                  anchor: anchor,
                  cursor: _cursor,
                  hoverRect: hoverRect,
                  refused: _hoverRefused,
                  accent: colors.accent,
                  danger: colors.danger,
                ),
              ),
            ),
          ),
        Positioned(
          key: const ValueKey('electrical-feeder-grip'),
          left: anchor.dx + _kFeederGripGapPx,
          top: anchor.dy - _kFeederGripScreenPx / 2,
          width: _kFeederGripScreenPx,
          height: _kFeederGripScreenPx,
          child: _FeederGrip(
            active: _from != null,
            onDragStart: _onDragStart,
            onDragUpdate: _onDragUpdate,
            onDragEnd: _onDragEnd,
          ),
        ),
      ],
    );
  }
}

/// The circular outlet dot the user drags to create a feeder. Screen-constant
/// size, so it stays grabbable at any zoom.
class _FeederGrip extends StatelessWidget {
  final bool active;
  final ValueChanged<Offset> onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;

  const _FeederGrip({
    required this.active,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      button: true,
      label: context.strings(StringKey.electricalFeederOutletHint),
      child: MouseRegion(
        cursor: SystemMouseCursors.precise,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => onDragStart(d.globalPosition),
          onPanUpdate: (d) => onDragUpdate(d.globalPosition),
          onPanEnd: (_) => onDragEnd(),
          child: Center(
            child: Container(
              width: _kFeederGripScreenPx * 0.8,
              height: _kFeederGripScreenPx * 0.8,
              decoration: BoxDecoration(
                color: colors.accent,
                shape: BoxShape.circle,
                border: Border.all(color: colors.surface, width: 2),
                boxShadow: MechXShadow.card,
              ),
              child: Center(
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: colors.onAccent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The in-flight feeder rubber band + the hovered board's verdict ring. Painted
/// only while a grip drag is live, so it never affects the at-rest canvas —
/// same discipline as [_ElecDropPreviewPainter].
class _FeederDragPainter extends CustomPainter {
  final Offset anchor;
  final Offset cursor;
  final Rect? hoverRect;
  final bool refused;
  final Color accent;
  final Color danger;

  _FeederDragPainter({
    required this.anchor,
    required this.cursor,
    required this.hoverRect,
    required this.refused,
    required this.accent,
    required this.danger,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final colour = (hoverRect != null && refused) ? danger : accent;
    canvas.drawLine(
      anchor,
      cursor,
      Paint()
        ..color = colour
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(cursor, 5, Paint()..color = colour);

    final hr = hoverRect;
    if (hr != null) {
      final rr = RRect.fromRectAndRadius(hr.inflate(3), MechXRadii.card.topLeft);
      canvas.drawRRect(rr, Paint()..color = colour.withAlpha(28));
      canvas.drawRRect(
        rr,
        Paint()
          ..color = colour
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_FeederDragPainter old) =>
      old.anchor != anchor ||
      old.cursor != cursor ||
      old.hoverRect != hoverRect ||
      old.refused != refused ||
      old.accent != accent ||
      old.danger != danger;
}

// ── Unplaced tray ────────────────────────────────────────────────────────────

/// J5: the tray sizes to its content but never taller than this — so a handful
/// of chips shows a small card, while a long list caps here and scrolls (with a
/// themed scroll indicator) rather than running the full height of the canvas.
const double _kTrayMaxHeight = 360;

class _UnplacedTray extends ConsumerWidget {
  final ElectricalProject project;
  final ElectricalSystemResult result;
  final String sheetId;
  const _UnplacedTray({
    required this.project,
    required this.result,
    required this.sheetId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;

    final unplacedPanels = [
      for (final p in project.panels)
        if (p.layoutPos == null) p,
    ];
    // Loads of EVERY board, not just the placed ones: a way on an unplaced board
    // is just as unplaced, and hiding it made the tray claim the sheet held
    // everything when it didn't. Dragging one out places the LOAD — its board
    // stays in the tray, which is the honest model (a load can sit on the plan
    // while the board it belongs to hasn't been located yet).
    final unplacedLoads = <_TrayLoad>[];
    for (final p in project.panels) {
      for (final c in p.circuits) {
        if (c.loadKind == LoadKind.feeder) continue;
        if (c.loadPos == null) {
          unplacedLoads.add(_TrayLoad(p.id, p.tag ?? p.name, c));
        }
      }
    }

    if (unplacedPanels.isEmpty && unplacedLoads.isEmpty) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      width: 188,
      // Liquid-Glass unplaced tray — floats over the layout canvas.
      child: GlassSurface(
        borderRadius: MechXRadii.card,
        blurSigma: MechXGlass.blurSigmaLight,
        shadow: MechXShadow.popover,
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                MechXSpacing.sm, MechXSpacing.sm, MechXSpacing.sm, MechXSpacing.xs),
            child: Text('Not on this sheet',
                style: type.label.copyWith(
                    color: colors.textPrimary, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: MechXSpacing.xs),
          // Cap the scroll region: a `SingleChildScrollView` under a bounded
          // `maxHeight` shrinks to its content when short and scrolls when tall
          // (J5), with a themed scroll indicator (J1).
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: _kTrayMaxHeight),
            child: MechXScrollbar(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(MechXSpacing.sm, 0,
                    MechXSpacing.sm, MechXSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final p in unplacedPanels)
                      _TrayItem(
                        label: p.tag ?? p.name,
                        kind: _TrayKind.panel,
                        // One-shot placement of a live-drag intent — snapshot
                        // first so the placement is a single undo step.
                        onPlaced: (pos, ctrl) => ctrl
                          ..pushUndoSnapshot()
                          ..setPanelLayoutPos(p.id, pos),
                        // A board with NO ways and no placement is a dead stub
                        // (an aborted drop / a deleted-out board). Offer to
                        // remove it, so the tray can be cleaned up instead of
                        // accumulating boards that will never be drawn. Boards
                        // that still carry ways are NOT removable here — that
                        // would be a destructive edit hidden on a chip.
                        onRemove: p.circuits.isEmpty &&
                                p.id != kMepEquipmentPanelId
                            ? () => _removeStub(ref, p)
                            : null,
                      ),
                    for (final t in unplacedLoads)
                      _TrayItem(
                        // Prefixed with its board's designation — with loads of
                        // UNPLACED boards listed too, a bare way name ('Lighting')
                        // no longer says which board it belongs to.
                        label: '${t.panelLabel} · ${t.circuit.name}',
                        kind: _TrayKind.load,
                        onPlaced: (pos, ctrl) => ctrl
                          ..pushUndoSnapshot()
                          ..setLoadPos(t.panelId, t.circuit.id, pos),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }
}

/// Delete an empty, unplaced stub board and say so. One [deletePanel] commit ⇒
/// one undo step (its feeder ways, if any, are swept inside the same commit).
void _removeStub(WidgetRef ref, ElectricalPanel panel) {
  final label = panel.tag ?? panel.name;
  ref.read(electricalProjectProvider.notifier).deletePanel(panel.id);
  ref.read(statusMessageProvider.notifier).showStatus('$label removed.');
}

enum _TrayKind { panel, load }

class _TrayLoad {
  final String panelId;

  /// The owning board's designation (tag, else name) — shown on the chip so a
  /// way of an unplaced board still names its parent.
  final String panelLabel;
  final ElectricalCircuit circuit;
  const _TrayLoad(this.panelId, this.panelLabel, this.circuit);
}

class _TrayItem extends StatelessWidget {
  final String label;
  final _TrayKind kind;
  final void Function(LayoutPos pos, ElectricalProjectController ctrl) onPlaced;

  /// Remove this entry from the project entirely (empty stub boards only).
  /// Null ⇒ no remove affordance, which is the case for everything real.
  final VoidCallback? onRemove;

  const _TrayItem({
    required this.label,
    required this.kind,
    required this.onPlaced,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final chip = _chip(context, dragging: false);
    return Padding(
      padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
      child: Draggable<_TrayPayload>(
        data: _TrayPayload(onPlaced),
        dragAnchorStrategy: pointerDragAnchorStrategy,
        // The drag AVATAR never carries the remove affordance (it isn't
        // tappable), so it stays the plain chip.
        feedback: _chip(context, dragging: true, withRemove: false),
        childWhenDragging:
            Opacity(opacity: 0.4, child: _chip(context, dragging: false,
                withRemove: false)),
        child: MouseRegion(cursor: SystemMouseCursors.grab, child: chip),
      ),
    );
  }

  Widget _chip(BuildContext context,
      {required bool dragging, bool withRemove = true}) {
    final colors = context.colors;
    final type = context.type;
    final dot = kind == _TrayKind.panel ? colors.accent : colors.success;
    final remove = withRemove ? onRemove : null;
    return Container(
      padding: EdgeInsets.fromLTRB(8, 5, remove == null ? 8 : 3, 5),
      decoration: BoxDecoration(
        color: dragging ? colors.surfaceHover : colors.background,
        borderRadius: MechXRadii.control,
        border: Border.all(color: dragging ? colors.accent : colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: type.label.copyWith(color: colors.textSecondary)),
          ),
          if (remove != null) ...[
            const SizedBox(width: 4),
            Semantics(
              button: true,
              label: 'Remove $label',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: remove,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: Center(
                      child: Text('×',
                          style: type.label.copyWith(color: colors.textMuted)),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

@immutable
class _TrayPayload {
  final void Function(LayoutPos pos, ElectricalProjectController ctrl) place;
  const _TrayPayload(this.place);
}

class _TrayDropTarget extends ConsumerStatefulWidget {
  final ViewportTransform transform;
  final String sheetId;
  final int floorIndex;
  final ElectricalProjectController controller;

  const _TrayDropTarget({
    required this.transform,
    required this.sheetId,
    required this.floorIndex,
    required this.controller,
  });

  @override
  ConsumerState<_TrayDropTarget> createState() => _TrayDropTargetState();
}

class _TrayDropTargetState extends ConsumerState<_TrayDropTarget> {
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    return DragTarget<_TrayPayload>(
      hitTestBehavior: HitTestBehavior.translucent,
      onWillAcceptWithDetails: (_) {
        setState(() => _active = true);
        return true;
      },
      onLeave: (_) => setState(() => _active = false),
      onAcceptWithDetails: (d) {
        setState(() => _active = false);
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final world = widget.transform.screenToWorld(box.globalToLocal(d.offset));
        final pos = LayoutPos(
          sheetId: widget.sheetId,
          floorIndex: widget.floorIndex,
          x: world.dx,
          y: world.dy,
        );
        d.data.place(pos, widget.controller);
      },
      builder: (context, candidate, rejected) {
        // Cross-fade the tray drop highlight in/out instead of popping.
        return IgnorePointer(
          ignoring: !_active,
          child: AnimatedOpacity(
            opacity: _active ? 1.0 : 0.0,
            duration: MechXMotion.hover,
            curve: MechXMotion.standard,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.colors.success.withAlpha(18),
                border: Border.all(
                    color: context.colors.success.withAlpha(120), width: 1.5),
                borderRadius: MechXRadii.card,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );
      },
    );
  }
}
