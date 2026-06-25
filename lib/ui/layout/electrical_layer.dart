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
import 'package:mechx_engine/units.dart';

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
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

/// Opacity applied when the electrical layer is a faded coordination layer.
const double kElectricalFadedAlpha = 0.34;

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
    final vt = transform;

    bool onSheet(LayoutPos? pos) =>
        pos != null && pos.sheetId == sheetId && pos.floorIndex == floorIndex;

    final placedPanels = [
      for (final p in project.panels)
        if (onSheet(p.layoutPos)) p,
    ];

    final nodeWidgets = <Widget>[
      for (final p in placedPanels)
        ..._panelNodes(context, ref, ctrl, p, result, vt, opacity),
      // Floating loads — placed circuits whose stub board is NOT itself placed
      // on this sheet (drop-on-blank). Render the load icon on its own.
      for (final p in project.panels)
        if (!onSheet(p.layoutPos))
          ..._loadNodes(context, ref, ctrl, p, result, vt, opacity),
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
        if (interactive)
          Positioned(
            right: MechXSpacing.md,
            top: MechXSpacing.md,
            bottom: MechXSpacing.md,
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
              onTap: () {},
              onDoubleTap: () => onEditPanel(panel.id),
              onMenu: (gp) => onPanelMenu(panel.id, gp),
              onDropLoad: (load) => ctrl.addCircuit(
                panel.id,
                kind: load.kind == LoadKind.feeder
                    ? LoadKind.general
                    : load.kind,
                phases: load.phases,
                loadW: load.loadW > 0 ? load.loadW : null,
                motorKw: load.motorKw,
              ),
            ),
          ),
        ),
      ),
    ));

    widgets.addAll(_loadNodes(context, ref, ctrl, panel, result, vt, opacity));
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
            onMove: (w) =>
                ctrl.setLoadPos(panel.id, c.id, lp.copyWith(x: w.dx, y: w.dy)),
            child: _ScaledLayoutChild(
              scale: vt.scale,
              width: kLayoutLoadW,
              height: kLayoutLoadH,
              child: _LoadMarker(
                circuit: c,
                result: cr,
                detail: detail,
                onTap: () {},
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
        style: const TextStyle(
          fontFamily: 'Roboto',
          fontSize: 9.5,
          color: Color(0xFFFFFFFF),
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect = Rect.fromCenter(
        center: mid, width: tp.width + 10, height: tp.height + 6);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
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
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final ValueChanged<Offset> onMenu;
  final ValueChanged<PaletteLoad> onDropLoad;

  const _PanelMarker({
    required this.panel,
    required this.result,
    required this.detail,
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
        : (_hover || _dropHover)
            ? colors.accent
            : colors.border;

    final body = Container(
      decoration: BoxDecoration(
        color: colors.surface.withAlpha(245),
        borderRadius: MechXRadii.card,
        border: Border.all(color: border, width: 1.5),
        boxShadow: const [
          BoxShadow(
              color: Color(0x40000000), blurRadius: 8, offset: Offset(0, 2)),
        ],
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
                scale: (_hover || _dropHover) ? 1.03 : 1.0,
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
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final ValueChanged<Offset> onMenu;

  const _LoadMarker({
    required this.circuit,
    required this.result,
    required this.detail,
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
    final symbolColor = _hover ? colors.accent : colors.textSecondary;
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
            border: Border.all(color: _hover ? colors.accent : colors.border),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x30000000), blurRadius: 4, offset: Offset(0, 1)),
            ],
          ),
          child: LoadSymbol(kind: c.loadKind, color: symbolColor, size: 20),
        ),
        if (widget.detail) ...[
          const SizedBox(height: 2),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: colors.surface.withAlpha(220),
              borderRadius: const BorderRadius.all(Radius.circular(3)),
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
            scale: _hover ? 1.03 : 1.0,
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
  final ValueChanged<Offset> onMove;
  final Widget child;

  const _LayoutNodeDraggable({
    required this.enabled,
    required this.scale,
    required this.world,
    required this.onMove,
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
      onPanStart: (_) => _dragWorld = widget.world,
      onPanUpdate: (d) {
        final next = (_dragWorld ?? widget.world) + d.delta / widget.scale;
        _dragWorld = next;
        widget.onMove(next);
      },
      onPanEnd: (_) => _dragWorld = null,
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

  @override
  Widget build(BuildContext context) {
    return DragTarget<PaletteLoad>(
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
        final local = box.globalToLocal(d.offset);
        final world = widget.transform.screenToWorld(local);
        _drop(d.data, world);
      },
      builder: (context, candidate, rejected) {
        // Cross-fade the drop highlight in/out instead of popping; idle is
        // pointer-ignored so the canvas keeps panning.
        return IgnorePointer(
          ignoring: !_active,
          child: AnimatedOpacity(
            opacity: _active ? 1.0 : 0.0,
            duration: MechXMotion.hover,
            curve: MechXMotion.standard,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.colors.accent.withAlpha(12),
                border: Border.all(
                    color: context.colors.accent.withAlpha(110), width: 1.5),
              ),
              child: const SizedBox.expand(),
            ),
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
      final n = project.panels.length + 1;
      widget.controller.addPanelAt(
        name: 'Sub-panel $n',
        tag: 'SP-$n',
        x: 80 + n * 40,
        y: 80 + n * 40,
        system: load.phases == 1
            ? ElectricalSystem.singlePhase
            : ElectricalSystem.threePhase,
        voltage:
            load.phases == 1 ? const Voltage(220) : const Voltage(400),
      );
      final added = ref.read(electricalProjectProvider).panels.last;
      widget.controller.setPanelLayoutPos(added.id, pos);
      return;
    }

    final nearest = _nearestPanel(project, world);
    if (nearest == null) {
      // No board placed yet — drop a floating LOAD (rendered as its icon), not
      // a generic panel. It stays a utility-fed stub until wired to a feeder.
      widget.controller.addFloatingLoadAtLayout(
        kind: load.kind,
        pos: pos,
        phases: load.phases,
        loadW: load.loadW > 0 ? load.loadW : null,
        motorKw: load.motorKw,
      );
      return;
    }
    widget.controller.addLoadAtLayout(
      nearest,
      kind: load.kind,
      pos: pos,
      phases: load.phases,
      loadW: load.loadW > 0 ? load.loadW : null,
      motorKw: load.motorKw,
    );
  }

  String? _nearestPanel(ElectricalProject project, Offset world) {
    String? best;
    var bestD = double.infinity;
    for (final p in project.panels) {
      final pos = p.layoutPos;
      if (pos == null ||
          pos.sheetId != widget.sheetId ||
          pos.floorIndex != widget.floorIndex) {
        continue;
      }
      final d = (Offset(pos.x, pos.y) - world).distanceSquared;
      if (d < bestD) {
        bestD = d;
        best = p.id;
      }
    }
    return best;
  }
}

// ── Unplaced tray ────────────────────────────────────────────────────────────

class _UnplacedTray extends StatelessWidget {
  final ElectricalProject project;
  final ElectricalSystemResult result;
  final String sheetId;
  const _UnplacedTray({
    required this.project,
    required this.result,
    required this.sheetId,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;

    final unplacedPanels = [
      for (final p in project.panels)
        if (p.layoutPos == null) p,
    ];
    final unplacedLoads = <_TrayLoad>[];
    for (final p in project.panels) {
      if (p.layoutPos == null) continue;
      for (final c in p.circuits) {
        if (c.loadKind == LoadKind.feeder) continue;
        if (c.loadPos == null) {
          unplacedLoads.add(_TrayLoad(p.id, c));
        }
      }
    }

    if (unplacedPanels.isEmpty && unplacedLoads.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      width: 188,
      decoration: BoxDecoration(
        color: colors.surface.withAlpha(245),
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.border),
        boxShadow: const [
          BoxShadow(
              color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: MechXSpacing.sm),
            child: Text('Drag onto the plan to place; until placed it uses its '
                'typed run length',
                style: type.caption.copyWith(color: colors.textMuted)),
          ),
          const SizedBox(height: MechXSpacing.xs),
          Flexible(
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
                      onPlaced: (pos, ctrl) =>
                          ctrl.setPanelLayoutPos(p.id, pos),
                    ),
                  for (final t in unplacedLoads)
                    _TrayItem(
                      label: t.circuit.name,
                      kind: _TrayKind.load,
                      onPlaced: (pos, ctrl) =>
                          ctrl.setLoadPos(t.panelId, t.circuit.id, pos),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _TrayKind { panel, load }

class _TrayLoad {
  final String panelId;
  final ElectricalCircuit circuit;
  const _TrayLoad(this.panelId, this.circuit);
}

class _TrayItem extends StatelessWidget {
  final String label;
  final _TrayKind kind;
  final void Function(LayoutPos pos, ElectricalProjectController ctrl) onPlaced;
  const _TrayItem({
    required this.label,
    required this.kind,
    required this.onPlaced,
  });

  @override
  Widget build(BuildContext context) {
    final chip = _chip(context, dragging: false);
    return Padding(
      padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
      child: Draggable<_TrayPayload>(
        data: _TrayPayload(onPlaced),
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: _chip(context, dragging: true),
        childWhenDragging: Opacity(opacity: 0.4, child: chip),
        child: MouseRegion(cursor: SystemMouseCursors.grab, child: chip),
      ),
    );
  }

  Widget _chip(BuildContext context, {required bool dragging}) {
    final colors = context.colors;
    final type = context.type;
    final dot = kind == _TrayKind.panel ? colors.accent : colors.success;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
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
                color: context.colors.success.withAlpha(12),
                border: Border.all(
                    color: context.colors.success.withAlpha(120), width: 1.5),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );
      },
    );
  }
}
