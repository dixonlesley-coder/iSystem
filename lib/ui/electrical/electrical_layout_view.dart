/// The electrical LAYOUT view — the third workspace projection (after
/// Single-line and Power one-line). It places electrical PANELS and LOADS at
/// real positions ON the calibrated PDF floor-plan sheet, so each circuit's
/// cable run length comes from REAL geometry (§10 geometry-is-truth) rather than
/// a typed-in run length.
///
/// It is a CO-EQUAL projection of the SAME `electricalProjectProvider` model as
/// the Single-line canvas: add / move / delete a node in either view mutates the
/// one project, so it shows in both. The two views carry SEPARATE positions —
/// the Single-line abstract schematic `x`/`y`, and the geo `layoutPos`/`loadPos`
/// here — but share identity + feeder topology.
///
/// Anatomy:
///  • a [CanvasView] (reused from the mechanical canvas) hosting the current
///    sheet's PDF page (via [sheetContentBuilderProvider], like `SheetCanvas`)
///    as the background, with a floor / sheet selector (reusing
///    `sheetsControllerProvider`);
///  • placed panels at `layoutPos` + each circuit's load at `loadPos` on the
///    active sheet/floor, with a panel→load cable line labelled with the GEO
///    cable length + size (and a panel→sub-panel feeder line);
///  • zoom-out auto-compact LOD (a marker + tag zoomed out, a fuller node up
///    close);
///  • drag from the Loads palette onto the sheet → a placed load (onto a panel →
///    a way); drag a placed node to move it (length recomputes live);
///    double-click → the circuit/panel inspector; right-click → the menu;
///  • an UNPLACED tray for nodes that exist in the model but aren't on the sheet
///    yet (e.g. added in Single-line) — drag them onto the sheet to place them;
///  • an "Electrical" discipline-layer chip (the broader plumbing/HVAC/electrical
///    layer switcher slots in here later) + an uncalibrated-sheet "set scale"
///    affordance pattern matching the mechanical canvas.
///
/// Styled entirely with MechXTheme (no Material). The pure engine derives the
/// geo length; this only places nodes + drives the store's edit intents.
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

import '../../store/calibration_store.dart';
import '../../store/electrical_store.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import '../canvas/sheet_canvas.dart' show sheetContentBuilderProvider;
import '../canvas/canvas_view.dart';
import '../canvas/viewport.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'electrical_canvas.dart' show phaseColorFor;
import 'electrical_format.dart';
import 'electrical_palette.dart';

/// LOD threshold for the layout markers — at/above this zoom a load/panel shows
/// its fuller node; below it, a compact marker + tag.
const double kLayoutLod = 0.65;

/// Footprint (sheet px) of a placed panel marker at world scale.
const double kLayoutPanelW = 150;
const double kLayoutPanelH = 56;

/// Footprint (sheet px) of a placed load marker at world scale.
const double kLayoutLoadW = 92;
const double kLayoutLoadH = 50;

/// Callbacks the layout canvas raises back to the host [ElectricalView].
typedef LayoutPanelEdit = void Function(String panelId);
typedef LayoutCircuitEdit = void Function(String panelId, String circuitId);
typedef LayoutPanelMenu = void Function(String panelId, Offset globalPos);
typedef LayoutCircuitMenu = void Function(
    String panelId, String circuitId, Offset globalPos);

/// The Layout workspace: the floor selector + the PDF-substrate canvas + the
/// unplaced tray.
class ElectricalLayoutView extends ConsumerWidget {
  final LayoutPanelEdit onEditPanel;
  final LayoutCircuitEdit onEditCircuit;
  final LayoutPanelMenu onPanelMenu;
  final LayoutCircuitMenu onCircuitMenu;

  const ElectricalLayoutView({
    super.key,
    required this.onEditPanel,
    required this.onEditCircuit,
    required this.onPanelMenu,
    required this.onCircuitMenu,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ElectricalPalette(),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _FloorSelector(),
              Container(height: 1, color: colors.border),
              Expanded(
                child: _LayoutCanvas(
                  onEditPanel: onEditPanel,
                  onEditCircuit: onEditCircuit,
                  onPanelMenu: onPanelMenu,
                  onCircuitMenu: onCircuitMenu,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Floor / sheet selector — reuses sheetsControllerProvider (the same multi-sheet
// rail the mechanical canvas drives), so switching shows that floor's placements.
// ════════════════════════════════════════════════════════════════════════════

class _FloorSelector extends ConsumerWidget {
  const _FloorSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final sheets = ref.watch(sheetsControllerProvider);
    final levelCount = ref.watch(projectControllerProvider).building.levelCount;
    final current = sheets.current;

    return Container(
      color: colors.surface,
      padding: const EdgeInsets.symmetric(
          horizontal: MechXSpacing.md, vertical: MechXSpacing.xs + 2),
      child: Row(
        children: [
          // The discipline-layer chip (the future layer switcher slots in here).
          _LayerChip(),
          const SizedBox(width: MechXSpacing.md),
          Text('SHEET',
              style: type.caption.copyWith(
                color: colors.textMuted,
                letterSpacing: 0.8,
                fontWeight: FontWeight.w600,
              )),
          const SizedBox(width: MechXSpacing.sm),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < sheets.sheets.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: MechXSpacing.xs),
                      child: _SheetTab(
                        label: sheets.sheets[i].name,
                        floor: sheets.floorFor(sheets.sheets[i].id, levelCount),
                        selected: i == sheets.currentIndex,
                        onTap: () => ref
                            .read(sheetsControllerProvider.notifier)
                            .selectSheet(i),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (current != null)
            Text(
              'Floor ${sheets.floorFor(current.id, levelCount) + 1} of $levelCount',
              style: type.caption.copyWith(color: colors.textMuted),
            ),
        ],
      ),
    );
  }
}

class _LayerChip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colors.accentMuted,
        borderRadius: MechXRadii.control,
        border: Border.all(color: colors.accent.withAlpha(140)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: colors.accent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: MechXSpacing.xs),
          Text('Electrical layer',
              style: type.caption.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
              )),
        ],
      ),
    );
  }
}

class _SheetTab extends StatelessWidget {
  final String label;
  final int floor;
  final bool selected;
  final VoidCallback onTap;
  const _SheetTab({
    required this.label,
    required this.floor,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.sm, vertical: MechXSpacing.xs),
          decoration: BoxDecoration(
            color: selected ? colors.accentMuted : const Color(0x00000000),
            borderRadius: MechXRadii.control,
            border: Border.all(
                color: selected ? colors.accent : colors.border),
          ),
          child: Text(label,
              style: type.label.copyWith(
                  color:
                      selected ? colors.textPrimary : colors.textSecondary)),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// The PDF-substrate canvas — the current sheet page as background + placed
// electrical nodes in sheet-pixel (world) space, rendered as a screen-space
// overlay sharing the CanvasView's transform.
// ════════════════════════════════════════════════════════════════════════════

class _LayoutCanvas extends ConsumerStatefulWidget {
  final LayoutPanelEdit onEditPanel;
  final LayoutCircuitEdit onEditCircuit;
  final LayoutPanelMenu onPanelMenu;
  final LayoutCircuitMenu onCircuitMenu;

  const _LayoutCanvas({
    required this.onEditPanel,
    required this.onEditCircuit,
    required this.onPanelMenu,
    required this.onCircuitMenu,
  });

  @override
  ConsumerState<_LayoutCanvas> createState() => _LayoutCanvasState();
}

class _LayoutCanvasState extends ConsumerState<_LayoutCanvas> {
  ViewportTransform _transform = const ViewportTransform();

  /// The sheet the current [_transform] belongs to — when the active sheet
  /// changes, the transform is reset so the new (keyed) CanvasView fits the new
  /// page instead of inheriting the old sheet's pan/zoom.
  String? _transformSheetId;
  String? _selectedPanel;

  ElectricalProjectController get _ctrl =>
      ref.read(electricalProjectProvider.notifier);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final sheets = ref.watch(sheetsControllerProvider);
    final sheet = sheets.current;
    final project = ref.watch(electricalProjectProvider);
    final result = ref.watch(electricalResultProvider);

    if (sheet == null) {
      return ColoredBox(
        color: colors.canvas,
        child: Center(
          child: Text('No sheet loaded',
              style: context.type.body.copyWith(color: colors.textMuted)),
        ),
      );
    }

    // Reset the shared transform when the active sheet changes (synchronous —
    // the new keyed CanvasView fits the new page and reports back its fit).
    if (_transformSheetId != sheet.id) {
      _transformSheetId = sheet.id;
      _transform = const ViewportTransform();
    }

    final levelCount = ref.watch(projectControllerProvider).building.levelCount;
    final floorIndex = sheets.floorFor(sheet.id, levelCount);
    final calibrated =
        ref.watch(projectControllerProvider).calibrationFor(sheet.id) != null;
    final content = ref.watch(sheetContentBuilderProvider)(context, sheet);

    final vt = _transform;

    // Nodes placed on THIS sheet + floor.
    final placedPanels = [
      for (final p in project.panels)
        if (_onSheet(p.layoutPos, sheet.id, floorIndex)) p,
    ];

    return Stack(
      children: [
        // The PDF sheet page, pannable/zoomable — REUSING CanvasView. We mirror
        // its transform into our overlay via onTransformChanged.
        Positioned.fill(
          child: CanvasView(
            key: ValueKey('layout-${sheet.id}'),
            contentSize: sheet.sizePx,
            initialTransform: vt == const ViewportTransform() ? null : vt,
            background: colors.canvas,
            onTransformChanged: (t) {
              if (t != _transform) setState(() => _transform = t);
            },
            child: content,
          ),
        ),
        // Wiring (cable + feeder lines) painted in screen space over the sheet.
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _WiringPainter(
                project: project,
                result: result,
                sheetId: sheet.id,
                floorIndex: floorIndex,
                transform: vt,
                detail: vt.scale >= kLayoutLod,
                accent: colors.accent,
                calibrationBySheet:
                    ref.read(projectControllerProvider).calibrations,
                building: ref.read(projectControllerProvider).building,
              ),
            ),
          ),
        ),
        // Palette drop target across the sheet (below the node widgets, so a drop
        // over a placed panel hits its own DragTarget first).
        Positioned.fill(
          child: _SheetDropTarget(
            transform: vt,
            sheetId: sheet.id,
            floorIndex: floorIndex,
            controller: _ctrl,
          ),
        ),
        // Tray drop target (accepts an unplaced-node chip) — overlaid; only the
        // matching payload type is accepted by each.
        Positioned.fill(
          child: _TrayDropTarget(
            transform: vt,
            sheetId: sheet.id,
            floorIndex: floorIndex,
            controller: _ctrl,
          ),
        ),
        // Placed panel + load node widgets (screen space).
        for (final p in placedPanels)
          ..._panelNodes(p, result, vt, sheet.id, floorIndex),
        // Zoom controls (bottom-left).
        Positioned(
          left: MechXSpacing.md,
          bottom: MechXSpacing.md,
          child: _ZoomBar(
            onIn: () => _zoom(1.2),
            onOut: () => _zoom(1 / 1.2),
            onFit: _fit,
          ),
        ),
        // The unplaced tray (right).
        Positioned(
          right: MechXSpacing.md,
          top: MechXSpacing.md,
          bottom: MechXSpacing.md,
          child: _UnplacedTray(
            project: project,
            result: result,
            sheetId: sheet.id,
          ),
        ),
        // Uncalibrated-sheet nudge (same pattern as the mechanical SheetCanvas).
        if (!calibrated)
          const Positioned(
            top: MechXSpacing.md,
            left: 0,
            right: 0,
            child: Center(child: _LayoutCalibrateHint()),
          ),
      ],
    );
  }

  bool _onSheet(LayoutPos? pos, String sheetId, int floor) =>
      pos != null && pos.sheetId == sheetId && pos.floorIndex == floor;

  void _zoom(double factor) {
    final box = context.findRenderObject() as RenderBox?;
    final center =
        (box?.size ?? const Size(800, 600)).center(Offset.zero);
    setState(() => _transform = _transform.zoomedBy(factor, center));
  }

  void _fit() {
    final sheet = ref.read(sheetsControllerProvider).current;
    final box = context.findRenderObject() as RenderBox?;
    if (sheet == null || box == null) return;
    setState(
        () => _transform = ViewportTransform.fit(sheet.sizePx, box.size));
  }

  /// One panel marker + its placed loads (those whose loadPos is on this sheet).
  List<Widget> _panelNodes(
    ElectricalPanel panel,
    ElectricalSystemResult result,
    ViewportTransform vt,
    String sheetId,
    int floor,
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
      child: _LayoutNodeDraggable(
        scale: vt.scale,
        world: Offset(pos.x, pos.y),
        onMove: (w) => _ctrl.setPanelLayoutPos(
            panel.id, pos.copyWith(x: w.dx, y: w.dy)),
        child: _ScaledLayoutChild(
          scale: vt.scale,
          width: kLayoutPanelW,
          height: kLayoutPanelH,
          child: _PanelMarker(
            panel: panel,
            result: pr,
            detail: detail,
            selected: _selectedPanel == panel.id,
            onTap: () => setState(() => _selectedPanel = panel.id),
            onDoubleTap: () => widget.onEditPanel(panel.id),
            onMenu: (gp) => widget.onPanelMenu(panel.id, gp),
            onDropLoad: (load) => _ctrl.addCircuit(
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
    ));

    // Placed loads of this panel on this sheet/floor.
    for (final c in panel.circuits) {
      final lp = c.loadPos;
      if (!_onSheet(lp, sheetId, floor)) continue;
      if (c.loadKind == LoadKind.feeder) continue;
      final cr = pr?.circuits.where((r) => r.circuitId == c.id).firstOrNull;
      final lScreen = vt.worldToScreen(Offset(lp!.x, lp.y));
      widgets.add(Positioned(
        left: lScreen.dx - kLayoutLoadW * vt.scale / 2,
        top: lScreen.dy - kLayoutLoadH * vt.scale / 2,
        width: kLayoutLoadW * vt.scale,
        height: kLayoutLoadH * vt.scale,
        child: _LayoutNodeDraggable(
          scale: vt.scale,
          world: Offset(lp.x, lp.y),
          onMove: (w) => _ctrl.setLoadPos(
              panel.id, c.id, lp.copyWith(x: w.dx, y: w.dy)),
          child: _ScaledLayoutChild(
            scale: vt.scale,
            width: kLayoutLoadW,
            height: kLayoutLoadH,
            child: _LoadMarker(
              circuit: c,
              result: cr,
              detail: detail,
              onTap: () => setState(() => _selectedPanel = null),
              onDoubleTap: () => widget.onEditCircuit(panel.id, c.id),
              onMenu: (gp) => widget.onCircuitMenu(panel.id, c.id, gp),
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

  @override
  void paint(Canvas canvas, Size size) {
    final byId = {for (final p in project.panels) p.id: p};
    for (final p in project.panels) {
      if (!_onSheet(p.layoutPos)) continue;
      final pos = p.layoutPos!;
      final from = transform.worldToScreen(Offset(pos.x, pos.y));
      final pr = result.panels[p.id];
      for (final c in p.circuits) {
        // Feeder → sub-panel line (only when the sub-panel is on this sheet too).
        if (c.feedsPanelId != null) {
          final to = _panelScreen(c.feedsPanelId!);
          if (to == null) continue;
          _line(canvas, from, to, accent, width: 2.2);
          _arrowHead(canvas, from, to, accent);
          if (detail) {
            _lengthLabel(canvas, from, to, _geoLen(c, p, byId), null, null);
          }
          continue;
        }
        if (c.loadKind == LoadKind.feeder) continue;
        // Panel → placed load line.
        if (!_onSheet(c.loadPos)) continue;
        final lp = c.loadPos!;
        final to = transform.worldToScreen(Offset(lp.x, lp.y));
        final cr =
            pr?.circuits.where((r) => r.circuitId == c.id).firstOrNull;
        final color = cr == null
            ? accent
            : phaseColorFor(cr.phase,
                p.system == ElectricalSystem.threePhase);
        _line(canvas, from, to, color, width: 1.8);
        if (detail) {
          _lengthLabel(canvas, from, to, _geoLen(c, p, byId),
              cr?.grounding.cableSpec, _util(cr));
        }
      }
    }
  }

  /// The geo run length the engine sized this circuit against — the SAME
  /// `resolveCircuitLength` the engine calls, so the label never drifts from the
  /// computed result.
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

  /// Label at the run's midpoint: GEO run length (m) + optional cable size +
  /// util %. A zero geo length (panel/load not both placed on a calibrated
  /// sheet) reads "set scale" so the unplaced/uncalibrated case is surfaced, not
  /// silently shown as 0 m.
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
              child: body,
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

    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surface.withAlpha(245),
        borderRadius: MechXRadii.control,
        border: Border.all(color: _hover ? colors.accent : colors.border),
        boxShadow: const [
          BoxShadow(
              color: Color(0x30000000), blurRadius: 4, offset: Offset(0, 1)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 18,
                height: 14,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border.all(color: colors.textMuted.withAlpha(140)),
                  borderRadius: const BorderRadius.all(Radius.circular(3)),
                ),
                child: Text(_glyph(c.loadKind),
                    style: TextStyle(
                      fontFamily: 'Roboto',
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                      color: colors.textSecondary,
                    )),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.caption.copyWith(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 9)),
              ),
            ],
          ),
          if (widget.detail)
            Text(
              util != null
                  ? '${fmtAmp0(rating)}A · ${util.round()}%'
                  : (rating > 0 ? '${fmtAmp0(rating)}A' : 'placed'),
              style: type.caption.copyWith(color: colors.textMuted, fontSize: 8),
            ),
        ],
      ),
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
          child: body,
        ),
      ),
    );
  }

  String _glyph(LoadKind kind) => switch (kind) {
        LoadKind.lighting => 'L',
        LoadKind.socket => 'SO',
        LoadKind.motor => 'M',
        LoadKind.pump => 'P',
        LoadKind.hvac => 'AC',
        LoadKind.heating => 'H',
        LoadKind.ups => 'U',
        LoadKind.evCharger => 'EV',
        LoadKind.welding => 'W',
        LoadKind.spare => 'SP',
        _ => 'G',
      };
}

// ════════════════════════════════════════════════════════════════════════════
// Node drag (move a placed node) — translates a screen-px pan delta into a
// sheet-px (world) move and writes the new layoutPos / loadPos.
// ════════════════════════════════════════════════════════════════════════════

class _LayoutNodeDraggable extends StatefulWidget {
  final double scale;
  final Offset world;
  final ValueChanged<Offset> onMove;
  final Widget child;

  const _LayoutNodeDraggable({
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

// ════════════════════════════════════════════════════════════════════════════
// Scaled-child wrapper (lay out at natural world-px size, then visually scale) —
// the same trick the single-line canvas uses so a node never over-constrains.
// ════════════════════════════════════════════════════════════════════════════

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

// ════════════════════════════════════════════════════════════════════════════
// Sheet-wide palette drop target — drop a card on blank sheet → place a load on
// the panel NEAREST the drop (auto-wiring it to that panel as a placed way); if
// no panel is on the sheet yet, place a panel there.
// ════════════════════════════════════════════════════════════════════════════

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
        if (!_active) return const IgnorePointer(child: SizedBox.expand());
        return DecoratedBox(
          decoration: BoxDecoration(
            color: context.colors.accent.withAlpha(12),
            border: Border.all(
                color: context.colors.accent.withAlpha(110), width: 1.5),
          ),
          child: const SizedBox.expand(),
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
      // A sub-panel dropped on the sheet → a new (utility-fed) board placed here.
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
      // Place it on the layout at the drop point.
      final added = ref.read(electricalProjectProvider).panels.last;
      widget.controller.setPanelLayoutPos(added.id, pos);
      return;
    }

    // A load card → attach to the nearest panel ON THIS sheet/floor, placed at
    // the drop point. With no panel here yet, drop a placed panel instead so the
    // sheet always gets SOMETHING (the user wires it next).
    final nearest = _nearestPanel(project, world);
    if (nearest == null) {
      final n = project.panels.length + 1;
      widget.controller.addPanelAt(
        name: 'Panel $n',
        tag: 'P-$n',
        x: 80 + n * 40,
        y: 80 + n * 40,
      );
      final added = ref.read(electricalProjectProvider).panels.last;
      widget.controller.setPanelLayoutPos(added.id, pos);
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

  /// The panel placed on this sheet/floor nearest [world] (sheet px), or null.
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

// ════════════════════════════════════════════════════════════════════════════
// Unplaced tray — model nodes (panels + loads) NOT on the current sheet/floor.
// Drag one onto the sheet to place it; until placed it sizes on its manual
// length, so nodes are never lost between the Single-line and Layout views.
// ════════════════════════════════════════════════════════════════════════════

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

    // Panels with no geo placement at all.
    final unplacedPanels = [
      for (final p in project.panels)
        if (p.layoutPos == null) p,
    ];
    // Loads (final ways) with no loadPos, on a panel that IS placed (so we know
    // which panel to attach to when dropped).
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

/// A draggable chip representing an unplaced node. Dropping carries a
/// [_TrayPayload] the sheet's drop target turns into a placement.
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

/// The payload a tray chip drops — a closure that, given a target [LayoutPos]
/// + the controller, writes the placement (panel layoutPos or circuit loadPos).
@immutable
class _TrayPayload {
  final void Function(LayoutPos pos, ElectricalProjectController ctrl) place;
  const _TrayPayload(this.place);
}

/// A second drop target across the sheet, accepting an unplaced-tray chip — a
/// `DragTarget<_TrayPayload>` overlaid alongside the `DragTarget<PaletteLoad>`
/// one (each accepts only its own payload type). Dropping places the node at the
/// drop point on this sheet/floor (its run length goes geo immediately).
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
        if (!_active) return const IgnorePointer(child: SizedBox.expand());
        return DecoratedBox(
          decoration: BoxDecoration(
            color: context.colors.success.withAlpha(12),
            border: Border.all(
                color: context.colors.success.withAlpha(120), width: 1.5),
          ),
          child: const SizedBox.expand(),
        );
      },
    );
  }
}

// ── Zoom bar ─────────────────────────────────────────────────────────────────

class _ZoomBar extends StatelessWidget {
  final VoidCallback onIn;
  final VoidCallback onOut;
  final VoidCallback onFit;
  const _ZoomBar({required this.onIn, required this.onOut, required this.onFit});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.control,
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ZoomBtn(glyph: '+', onTap: onIn),
          _ZoomSep(),
          _ZoomBtn(glyph: '-', onTap: onOut),
          _ZoomSep(),
          _ZoomBtn(glyph: 'fit', onTap: onFit),
        ],
      ),
    );
  }
}

class _ZoomSep extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 22, color: context.colors.border);
}

class _ZoomBtn extends StatefulWidget {
  final String glyph;
  final VoidCallback onTap;
  const _ZoomBtn({required this.glyph, required this.onTap});

  @override
  State<_ZoomBtn> createState() => _ZoomBtnState();
}

class _ZoomBtnState extends State<_ZoomBtn> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: widget.glyph.length > 1 ? 34 : 28,
          height: 28,
          alignment: Alignment.center,
          color: _hover ? colors.surfaceHover : const Color(0x00000000),
          child: Text(widget.glyph,
              style:
                  context.type.label.copyWith(color: colors.textSecondary)),
        ),
      ),
    );
  }
}

// ── Uncalibrated-sheet nudge ─────────────────────────────────────────────────

class _LayoutCalibrateHint extends ConsumerWidget {
  const _LayoutCalibrateHint();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => ref.read(calibrationControllerProvider.notifier).start(),
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.sm + 2, vertical: MechXSpacing.xs + 1),
          decoration: BoxDecoration(
            color: colors.surface.withAlpha(240),
            borderRadius: MechXRadii.control,
            border: Border.all(color: colors.warning),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 4)),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.only(right: MechXSpacing.xs),
                decoration: BoxDecoration(
                  color: colors.warning,
                  borderRadius: const BorderRadius.all(Radius.circular(4)),
                ),
              ),
              Text('Set sheet scale so placed runs measure real cable length',
                  style: type.label.copyWith(color: colors.textPrimary)),
            ],
          ),
        ),
      ),
    );
  }
}
