/// The electrical SINGLE-LINE spatial canvas — a faithful Flutter port of
/// PanelMaker's `BuildingSingleLine.tsx`. Panels are boxes on a pannable /
/// zoomable canvas, wired by feeder lines, with each panel's loads hanging as
/// nodes below it and a **zoom-driven level-of-detail** (a summary card when
/// zoomed out → the full internal R-S-T busbar + breakers when zoomed in).
///
/// Anatomy (mirrors the reference):
///  • a [ViewportTransform]-driven canvas (reusing the mechanical canvas's
///    zoom-to-cursor / middle-drag-pan / scroll math) with a dark grid;
///  • panel nodes positioned at their `x,y` (auto-layout when null — service
///    root left, fed panels by depth to the right, grid-snapped);
///  • the internal R-S-T / N / PE busbar (colourised) drawn past the LOD
///    threshold, with each way as a breaker tapping the bus + a load node on a
///    drop line a fixed distance below;
///  • a PLN grid-supply node above the service-root panel;
///  • a left Loads palette ([Draggable]) — drop on a panel adds a way, drop on
///    blank canvas adds a floating load / sub-panel;
///  • double-click → edit, right-click → context menu, drag a panel's round
///    outlet onto another panel → feeder, Delete → disconnect / delete;
///  • a minimap (bottom-right), zoom +/-/fit (bottom-left), gesture help (?).
///
/// Styled with MechXTheme (no Material). The pure A4 engine does all sizing;
/// this only reads its result records + drives the store's edit intents.
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/results.dart' show BreakerResult;
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/units.dart';

import '../../store/app_state.dart';
import '../../store/electrical_store.dart';
import '../canvas/canvas_grid.dart';
import '../canvas/viewport.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'electrical_format.dart';
import 'electrical_palette.dart';
import 'load_symbols.dart';
import 'panel_geometry.dart';
import 'sld_sheet_painter.dart';

/// LOD threshold — at/above this zoom each panel shows its full internal
/// schematic; below it, a compact summary card (PanelMaker `transform[2] >=
/// 0.72`).
const double kLodThreshold = 0.72;

/// DEEP-zoom LOD threshold — at/above this zoom each panel's body swaps the
/// hand-painted R-S-T busbar for the REAL engine board schedule
/// (`buildElectricalPanelDetail`, the same geometry the PDF / DXF export draws),
/// painted read-only via [SldBoardSchedulePainter]. Set well above the LOD
/// threshold (and above the zoom golden 05 reaches) so the mid-detail schematic
/// — which keeps the per-way edit hit-test — stays the default, and the board
/// schedule is a deliberate "zoom right in" representation.
const double kBoardScheduleThreshold = 1.35;

/// Indonesian R-S-T / N / PE rail colours (hard hex, ported verbatim).
const Color kRailR = Color(0xFFC92A2A); // L1 / R / single-phase live
const Color kRailS = Color(0xFFE8990C); // L2 / S
const Color kRailT = Color(0xFF1971C2); // L3 / T
const Color kRailN = Color(0xFF4DABF7); // neutral
const Color kRailPE = Color(0xFF2F9E44); // protective earth

/// A request from the canvas back to the host view.
typedef PanelTap = void Function(String panelId);
typedef CircuitEdit = void Function(String panelId, String circuitId);
typedef PanelMenu = void Function(String panelId, Offset globalPos);
typedef CircuitMenu =
    void Function(String panelId, String circuitId, Offset globalPos);

/// The spatial single-line canvas. Stateful: it owns the [ViewportTransform]
/// (electrical has no per-sheet viewport store) and the in-flight feeder-drag.
class ElectricalCanvas extends ConsumerStatefulWidget {
  /// Open the panel inspector (double-click a panel body).
  final PanelTap onEditPanel;

  /// Open the circuit editor (double-click a way / load node).
  final CircuitEdit onEditCircuit;

  /// Panel right-click context menu.
  final PanelMenu onPanelMenu;

  /// Way / load right-click context menu.
  final CircuitMenu onCircuitMenu;

  /// Open the Service & Earthing editor (double-click the PLN grid node).
  final VoidCallback onRequestService;

  /// Open the Sources editor (double-click the source-spine strip).
  final VoidCallback onRequestSources;

  const ElectricalCanvas({
    super.key,
    required this.onEditPanel,
    required this.onEditCircuit,
    required this.onPanelMenu,
    required this.onCircuitMenu,
    required this.onRequestService,
    required this.onRequestSources,
  });

  @override
  ConsumerState<ElectricalCanvas> createState() => ElectricalCanvasState();
}

class ElectricalCanvasState extends ConsumerState<ElectricalCanvas> {
  ViewportTransform? _transform;
  Size _viewportSize = Size.zero;
  final FocusNode _focus = FocusNode(debugLabel: 'electrical-canvas');

  // Middle-button pan tracking.
  bool _panning = false;
  Offset _lastPanPoint = Offset.zero;
  double _lastScale = 1.0;

  // In-flight feeder drag from a panel outlet.
  String? _feederFrom;
  Offset _feederCursor = Offset.zero;
  String? _feederHoverPanel;

  // The selected panel (for the Delete key + selection ring).
  String? _selectedPanel;

  /// Frame the content on the first layout — computed SYNCHRONOUSLY (assigning
  /// the field, not via setState) so even a single-frame render is framed, not
  /// clipped at the origin. After this the user owns the viewport.
  void _ensureInitialTransform(Map<String, Offset> positions) {
    if (_transform != null || _viewportSize.isEmpty || positions.isEmpty) {
      return;
    }
    final t = _fitTransform(positions);
    if (t != null) _transform = t;
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  ElectricalProjectController get _ctrl =>
      ref.read(electricalProjectProvider.notifier);

  /// Propagated essential-board id set (recomputed each build); drives the red
  /// essential colouring on cards + feeders.
  Set<String> _essential = const {};

  ViewportTransform get _current =>
      _transform ?? const ViewportTransform(scale: 0.8);

  void _setTransform(ViewportTransform next) {
    if (next == _transform) return;
    setState(() => _transform = next);
  }

  // ── Layout ─────────────────────────────────────────────────────────────────

  /// Resolve each panel's world position: saved `x,y` wins, else the
  /// deterministic tidy-tree auto-layout.
  Map<String, Offset> _positions(
    ElectricalProject project,
    ElectricalSystemResult result,
  ) {
    final auto = autoLayout(project, result);
    return {
      for (final p in project.panels)
        p.id: (p.x != null && p.y != null)
            ? Offset(p.x!, p.y!)
            : (auto[p.id] ?? Offset.zero),
    };
  }

  void _fit(Map<String, Offset> positions) {
    final t = _fitTransform(positions);
    if (t != null) _setTransform(t);
  }

  /// The fit transform framing all panels + their PLN heads + load nodes within
  /// the viewport (null when nothing to frame).
  ViewportTransform? _fitTransform(Map<String, Offset> positions) {
    if (positions.isEmpty || _viewportSize.isEmpty) return null;
    final project = ref.read(electricalProjectProvider);
    final result = ref.read(electricalResultProvider);
    final panels = result.panels;
    // The horizontal source chain extends LEFT of the service-root board; reserve
    // room for it so it isn't clipped off the canvas's left edge.
    final rootId = serviceRootId(project, result);
    final spine = buildElectricalSourceSpine(
        project: project, result: result, horizontal: true);
    final spineW = spine.isEmpty ? 0.0 : (spine.maxX - spine.minX) + 14;
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    positions.forEach((id, p) {
      final panel = panels[id];
      final w = panel == null
          ? 280.0
          : math.max(panelCardWidth(panel.circuits.length), panelDetailWidth());
      final h = panel == null
          ? 160.0
          : panelCardHeight(panel) + kPanelChrome + kLoadDropGap + kLoadNodeH;
      // The root carries the source chain to its left (else the PLN head above).
      final leftExtent = id == rootId ? spineW : 0.0;
      minX = math.min(minX, p.dx - leftExtent);
      minY = math.min(minY, p.dy - kGridSrcH - 30);
      maxX = math.max(maxX, p.dx + w);
      maxY = math.max(maxY, p.dy + h);
    });
    if (!minX.isFinite) return null;
    final content = Size(maxX - minX + 80, maxY - minY + 80);
    final fitted = ViewportTransform.fit(content, _viewportSize, padding: 40);
    // Re-anchor to the content's top-left (auto-layout starts near 0,0 but a
    // saved layout may be offset).
    return ViewportTransform(
      scale: fitted.scale,
      offset: fitted.offset - Offset(minX - 40, minY - 40) * fitted.scale,
    );
  }

  // ── Pointer / zoom ───────────────────────────────────────────────────────────

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final factor = math.pow(1.0015, -event.scrollDelta.dy).toDouble();
      _setTransform(_current.zoomedBy(factor, event.localPosition));
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    _focus.requestFocus();
    if (event.buttons & kMiddleMouseButton != 0) {
      _panning = true;
      _lastPanPoint = event.localPosition;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_panning) return;
    _setTransform(_current.panned(event.localPosition - _lastPanPoint));
    _lastPanPoint = event.localPosition;
  }

  void _onPointerUp(PointerUpEvent event) => _panning = false;

  // Left-drag on blank canvas pans (no box-select for this pass — matches the
  // reference's panOnDrag default behaviour).
  void _onScaleStart(ScaleStartDetails details) => _lastScale = 1.0;

  void _onScaleUpdate(ScaleUpdateDetails details) {
    var vt = _current;
    if (details.focalPointDelta != Offset.zero) {
      vt = vt.panned(details.focalPointDelta);
    }
    final incremental = details.scale / _lastScale;
    _lastScale = details.scale;
    if (incremental != 1.0) {
      vt = vt.zoomedBy(incremental, details.localFocalPoint);
    }
    _setTransform(vt);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      final sel = _selectedPanel;
      if (sel != null) {
        _ctrl.deletePanel(sel);
        setState(() => _selectedPanel = null);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  // ── Feeder drag (panel outlet → another panel) ──────────────────────────────

  void _onFeederDragStart(String fromId, Offset globalPos) {
    final box = context.findRenderObject() as RenderBox?;
    setState(() {
      _feederFrom = fromId;
      _feederCursor = box?.globalToLocal(globalPos) ?? globalPos;
      _feederHoverPanel = null;
    });
  }

  void _onFeederDragUpdate(
    Offset globalPos,
    Map<String, Offset> positions,
    Map<String, ElectricalPanelResult> panels,
  ) {
    final box = context.findRenderObject() as RenderBox?;
    final local = box?.globalToLocal(globalPos) ?? globalPos;
    setState(() {
      _feederCursor = local;
      _feederHoverPanel = _panelAt(
        local,
        positions,
        panels,
        exclude: _feederFrom,
      );
    });
  }

  void _onFeederDragEnd() {
    final from = _feederFrom;
    final to = _feederHoverPanel;
    if (from != null && to != null && from != to) {
      final res = _ctrl.connectFeeder(from, to);
      if (!res.connected && res.reason != null && mounted) {
        // Route through the shared status pill (status bar) like the rest of
        // the app — one feedback primitive, no bespoke per-canvas toast.
        ref.read(statusMessageProvider.notifier).showStatus(res.reason!);
      }
    }
    setState(() {
      _feederFrom = null;
      _feederHoverPanel = null;
    });
  }

  /// Which panel (if any) contains the screen point [local].
  String? _panelAt(
    Offset local,
    Map<String, Offset> positions,
    Map<String, ElectricalPanelResult> panels, {
    String? exclude,
  }) {
    final vt = _current;
    for (final entry in positions.entries) {
      if (entry.key == exclude) continue;
      final panel = panels[entry.key];
      if (panel == null) continue;
      final detail = vt.scale >= kLodThreshold;
      final w = panelCardWidthAt(panel, detail);
      final h = panelFootprint(panel, detail);
      final tl = vt.worldToScreen(entry.value);
      final rect = Rect.fromLTWH(tl.dx, tl.dy, w * vt.scale, h * vt.scale);
      if (rect.contains(local)) return entry.key;
    }
    return null;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final project = ref.watch(electricalProjectProvider);
    final result = ref.watch(electricalResultProvider);
    final positions = _positions(project, result);
    final rootId = serviceRootId(project, result);
    // ESSENTIAL (genset-backed / emergency) boards — propagated down the
    // emergency sub-tree — drive the red border + feeder colour, the riser
    // convention folded in from the removed Overview tab.
    _essential = essentialPanelIds(project, result);

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Listener(
        onPointerSignal: _onPointerSignal,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onTap: () => setState(() => _selectedPanel = null),
          child: LayoutBuilder(
            builder: (context, constraints) {
              _viewportSize = constraints.biggest;
              _ensureInitialTransform(positions);
              final vt = _current;
              // Compute LOD from the RESOLVED viewport (after the initial fit),
              // so the panel-internal schematic + the load break-out/merge track
              // the real zoom from the first frame — not the pre-fit default.
              final detail = vt.scale >= kLodThreshold;
              // Detail = the real engine BOARD SCHEDULE (vertical bus, way rows
              // reading left-to-right) — the same geometry the PDF/DXF export
              // draws. The whole panel reads left-to-right, so the way rows ARE
              // the loads (no separate hanging load symbols) and feeders branch
              // right to sub-panels. (One detail tier now; the summary card is
              // the only other tier.)
              final scheduleDetail = detail;
              return ClipRect(
                child: Stack(
                  children: [
                    // Grid + wiring (feeders, buses, drop lines) in screen space.
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _CanvasPainter(
                          project: project,
                          result: result,
                          positions: positions,
                          transform: vt,
                          rootId: rootId,
                          detail: detail,
                          scheduleDetail: scheduleDetail,
                          gridLine: colors.gridLine,
                          background: colors.canvas,
                          feederFrom: _feederFrom,
                          feederCursor: _feederCursor,
                          feederHover: _feederHoverPanel,
                          accent: colors.accent,
                          onAccent: colors.onAccent,
                          essential: _essential,
                          essentialColor: colors.danger,
                        ),
                      ),
                    ),
                    // Palette-drop target across blank canvas — sits BELOW the
                    // panels so a drop over a panel hits the panel's own
                    // DragTarget (no double-add); a drop on blank canvas falls
                    // through to here (floating load / sub-panel).
                    Positioned.fill(
                      child: _CanvasDropTarget(
                        transform: vt,
                        panelCount: project.panels.length,
                        controller: _ctrl,
                        onToast: (m) =>
                            ref.read(statusMessageProvider.notifier).showStatus(m),
                      ),
                    ),
                    // Panel cards + their load nodes + PLN heads (Flutter widgets
                    // so they capture pointer events for edit/drag/menu).
                    for (final panel in [
                      for (final id in result.order)
                        if (result.panels[id] != null) result.panels[id]!,
                    ])
                      ..._panelWidgets(
                        panel,
                        positions[panel.panelId] ?? Offset.zero,
                        vt,
                        detail,
                        scheduleDetail,
                        project,
                        result,
                        rootId,
                        positions,
                        result.panels,
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// The card footprint at the current LOD (full schematic when zoomed in, the
  /// compact summary band when zoomed out) — so loads sit a fixed gap below the
  /// ACTUAL card height, not a reserved schematic band of empty space.
  double cardFootprint(ElectricalPanelResult panel) =>
      panelFootprint(panel, currentScale >= kLodThreshold);

  /// Build the panel card, its PLN head (root only) and one load node per
  /// non-feeder / non-spare way.
  List<Widget> _panelWidgets(
    ElectricalPanelResult panel,
    Offset world,
    ViewportTransform vt,
    bool detail,
    bool scheduleDetail,
    ElectricalProject project,
    ElectricalSystemResult result,
    String? rootId,
    Map<String, Offset> positions,
    Map<String, ElectricalPanelResult> panels,
  ) {
    final scale = vt.scale;
    final tl = vt.worldToScreen(world);
    final w = panelCardWidthAt(panel, detail);
    final cardH = panelFootprint(panel, detail);
    final modelPanel = project.panels
        .where((p) => p.id == panel.panelId)
        .firstOrNull;
    final isRoot = panel.panelId == rootId;
    final fed = modelPanel?.fedByCircuitId != null;
    final unfed = !isRoot && !fed;

    final widgets = <Widget>[];

    // To the LEFT of the service-root board: the SOURCE CHAIN (PLN -> MV ->
    // transformer -> LV main + genset / capacitor) drawn as real single-line
    // SYMBOLS, flowing left-to-right INTO the root board (matching the canvas's
    // left-to-right flow) when the project carries any sources / dual-tx /
    // explicit transformer / capacitor. Otherwise the bare PLN grid head (so a
    // default project is byte-identical). Double-click either to open the
    // Sources / Service editor.
    if (isRoot) {
      final spine = buildElectricalSourceSpine(
          project: project, result: result, horizontal: true);
      if (!spine.isEmpty) {
        // Place the chain's right edge a small gap LEFT of the root's left edge,
        // its baseline (y=0, the LV-main feed) on the board's vertical centre, so
        // the LV-main bus feeds rightward into the board.
        const gap = 14.0;
        final offset = Offset(
          (world.dx - gap) - spine.maxX,
          world.dy + cardH / 2,
        );
        final bandTl = vt.worldToScreen(
          Offset(spine.minX + offset.dx, spine.minY + offset.dy),
        );
        final bandW = (spine.maxX - spine.minX) * scale;
        final bandH = (spine.maxY - spine.minY) * scale;
        final colors = context.colors;
        widgets.add(
          Positioned(
            left: bandTl.dx,
            top: bandTl.dy,
            width: bandW,
            height: bandH,
            child: _ScaledTap(
              onDoubleTap: widget.onRequestSources,
              child: CustomPaint(
                painter: _SourceSpinePainter(
                  sheet: spine,
                  origin: Offset(spine.minX + offset.dx, spine.minY + offset.dy),
                  scale: scale,
                  ink: colors.textPrimary,
                  source: colors.accent,
                  essential: colors.danger,
                  rectFill: colors.surface,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );
      } else {
        final headWorld = Offset(
          world.dx + w / 2 - kGridSrcW / 2,
          world.dy - kGridSrcH - 30,
        );
        final hp = vt.worldToScreen(headWorld);
        widgets.add(
          Positioned(
            left: hp.dx,
            top: hp.dy,
            width: kGridSrcW * scale,
            height: kGridSrcH * scale,
            child: _ScaledTap(
              onDoubleTap: widget.onRequestService,
              child: _ScaledChild(
                scale: scale,
                width: kGridSrcW,
                height: kGridSrcH,
                child: _GridSourceNode(voltage: panel.system),
              ),
            ),
          ),
        );
      }
    }

    // The panel card. Also a DROP TARGET for a load node dragged off another
    // panel — re-parenting that circuit here.
    widgets.add(
      Positioned(
        left: tl.dx,
        top: tl.dy,
        width: w * scale,
        height: cardH * scale,
        child: DragTarget<_LoadRef>(
          onAcceptWithDetails: (d) => _ctrl.moveCircuit(
              d.data.fromPanelId, d.data.circuitId, panel.panelId),
          builder: (ctx, cand, rej) => _PanelDraggable(
          panelId: panel.panelId,
          world: world,
          scale: scale,
          controller: _ctrl,
          child: _ScaledChild(
            scale: scale,
            width: w,
            height: cardH,
            child: _PanelCardNode(
              panel: panel,
              detail: detail,
              scheduleDetail: scheduleDetail,
              project: project,
              result: result,
              selected: _selectedPanel == panel.panelId,
              unfed: unfed,
              essential: _essential.contains(panel.panelId),
              upsBacked: modelPanel?.upsBacked ?? false,
              submeter: modelPanel?.submeter ?? false,
              onTap: () => setState(() => _selectedPanel = panel.panelId),
              onDoubleTap: () => widget.onEditPanel(panel.panelId),
              onMenu: (gp) => widget.onPanelMenu(panel.panelId, gp),
              onWayDoubleTap: (cid) => widget.onEditCircuit(panel.panelId, cid),
              onWayMenu: (cid, gp) =>
                  widget.onCircuitMenu(panel.panelId, cid, gp),
              onDropLoad: (load) => _ctrl.addCircuit(
                panel.panelId,
                kind: load.kind == LoadKind.feeder
                    ? LoadKind.general
                    : load.kind,
                phases: load.phases,
                loadW: load.loadW > 0 ? load.loadW : null,
                motorKw: load.motorKw,
              ),
              onOutletDragStart: (gp) => _onFeederDragStart(panel.panelId, gp),
              onOutletDragUpdate: (gp) =>
                  _onFeederDragUpdate(gp, positions, panels),
              onOutletDragEnd: _onFeederDragEnd,
            ),
          ),
          ),
        ),
      ),
    );

    // Loads below the panel. Zoomed OUT (summary view) they MERGE into one
    // compact node so the panel reads as a tidy block instead of fanning every
    // load out below it; they break out into the individual load nodes only
    // when zoomed in (detail). Double-tap the merged node to zoom in + expand.
    if (!detail) {
      final loadCount = panel.circuits
          .where((c) =>
              c.loadKind != LoadKind.feeder && c.loadKind != LoadKind.spare)
          .length;
      if (loadCount > 0) {
        // The merged "N loads" node sits to the RIGHT of the card (vertically
        // centred) — the collapsed form of the right-hand load column, so a
        // zoom-in breaks it out into that column / the schedule rows in place.
        final mergedWorld = Offset(
          world.dx + w + kLoadGapX,
          world.dy + cardH / 2 - kLoadNodeH / 2,
        );
        final mp = vt.worldToScreen(mergedWorld);
        final focal = mp + Offset(kLoadW * scale / 2, kLoadNodeH * scale / 2);
        widgets.add(
          Positioned(
            left: mp.dx,
            top: mp.dy,
            width: kLoadW * scale,
            height: kLoadNodeH * scale,
            child: _ScaledTap(
              onTap: () => setState(() => _selectedPanel = null),
              onDoubleTap: () => _expandLoadsAt(focal),
              child: _ScaledChild(
                scale: scale,
                width: kLoadW,
                height: kLoadNodeH,
                child: _MergedLoadsNode(count: loadCount),
              ),
            ),
          ),
        );
      }
      return widgets;
    }

    // Load nodes branch to the RIGHT of the panel, stacked top-to-bottom (one
    // per non-feeder/non-spare way) — a left-to-right column aligned with the
    // board-schedule rows. SUPPRESSED at the board-schedule LOD, where the
    // schedule lists every way itself, so zooming in morphs the column straight
    // into the schedule rows. `j` indexes only the rendered loads (no gaps).
    final loadsRightX = world.dx + w + kLoadGapX;
    var j = -1;
    for (var i = 0; !scheduleDetail && i < panel.circuits.length; i++) {
      final c = panel.circuits[i];
      if (c.loadKind == LoadKind.feeder || c.loadKind == LoadKind.spare) {
        continue;
      }
      j++;
      final loadWorld = Offset(
        loadsRightX,
        world.dy + kPanelChrome + j * kLoadRowH,
      );
      final lp = vt.worldToScreen(loadWorld);
      final loadNode = _ScaledChild(
        scale: scale,
        width: kLoadW,
        height: kLoadNodeH,
        child: _LoadNode(circuit: c),
      );
      widgets.add(
        Positioned(
          left: lp.dx,
          top: lp.dy,
          width: kLoadW * scale,
          height: kLoadNodeH * scale,
          // Drop another load HERE to CHAIN them onto one breaker (same panel),
          // or drag a load onto a panel to RE-PARENT the circuit there.
          child: DragTarget<_LoadRef>(
            onWillAcceptWithDetails: (d) => d.data.circuitId != c.circuitId,
            onAcceptWithDetails: (d) {
              if (d.data.fromPanelId == panel.panelId) {
                _ctrl.mergeCircuit(
                    panel.panelId, d.data.circuitId, c.circuitId);
              } else {
                _ctrl.moveCircuit(
                    d.data.fromPanelId, d.data.circuitId, panel.panelId);
              }
            },
            builder: (ctx, cand, rej) => Draggable<_LoadRef>(
              data: _LoadRef(panel.panelId, c.circuitId),
              dragAnchorStrategy: childDragAnchorStrategy,
              feedback: Opacity(
                opacity: 0.85,
                child: SizedBox(
                  width: kLoadW * scale,
                  height: kLoadNodeH * scale,
                  child: loadNode,
                ),
              ),
              childWhenDragging: Opacity(opacity: 0.35, child: loadNode),
              child: _ScaledTap(
                onTap: () => setState(() => _selectedPanel = null),
                onDoubleTap: () =>
                    widget.onEditCircuit(panel.panelId, c.circuitId),
                onMenu: (gp) =>
                    widget.onCircuitMenu(panel.panelId, c.circuitId, gp),
                child: loadNode,
              ),
            ),
          ),
        ),
      );
    }

    return widgets;
  }

  // Helpers exposed to the host view's zoom controls.

  /// Current zoom scale (exposed for tests / host LOD checks).
  double get currentScale => _current.scale;

  void zoomIn() =>
      _setTransform(_current.zoomedBy(1.2, _viewportSize.center(Offset.zero)));
  void zoomOut() => _setTransform(
    _current.zoomedBy(1 / 1.2, _viewportSize.center(Offset.zero)),
  );
  void fitView() {
    final project = ref.read(electricalProjectProvider);
    final result = ref.read(electricalResultProvider);
    _fit(_positions(project, result));
  }

  /// Frame a single panel's BOARD SCHEDULE — centre [panelId] at a scale past
  /// [kBoardScheduleThreshold] so the deep-zoom engine schedule renders. No-op
  /// if the panel/viewport isn't available yet. (Powers a "focus this panel"
  /// gesture and the deep-zoom golden.)
  void focusPanelSchedule(String panelId, {double? scale}) {
    final project = ref.read(electricalProjectProvider);
    final result = ref.read(electricalResultProvider);
    final pos = _positions(project, result)[panelId];
    final panel = result.panels[panelId];
    if (pos == null || panel == null || _viewportSize.isEmpty) return;
    final s = scale ?? (kBoardScheduleThreshold + 0.3);
    final w = panelCardWidthAt(panel, true);
    final h = panelFootprint(panel, true);
    final worldCentre = Offset(pos.dx + w / 2, pos.dy + h / 2);
    _setTransform(ViewportTransform(
      scale: s,
      offset: _viewportSize.center(Offset.zero) - worldCentre * s,
    ));
  }

  /// Zoom in just past the LOD threshold, anchored at [focalScreen], so a
  /// merged-loads node breaks out into its individual loads (double-tap to
  /// expand). No-op if already in detail.
  void _expandLoadsAt(Offset focalScreen) {
    if (_current.scale >= kLodThreshold) return;
    _setTransform(_current.zoomedTo(kLodThreshold + 0.06, focalScreen));
  }

  ViewportTransform get transform => _current;
}

/// Drag payload for re-parenting a load: which circuit, off which panel.
@immutable
class _LoadRef {
  final String fromPanelId;
  final String circuitId;
  const _LoadRef(this.fromPanelId, this.circuitId);
}

// ════════════════════════════════════════════════════════════════════════════
// Painter — grid + wiring (feeders, buses, drop lines) in screen space.
// ════════════════════════════════════════════════════════════════════════════

class _CanvasPainter extends CustomPainter {
  final ElectricalProject project;
  final ElectricalSystemResult result;
  final Map<String, Offset> positions;
  final ViewportTransform transform;
  final String? rootId;
  final bool detail;
  final bool scheduleDetail;
  final Color gridLine;
  final Color background;
  final String? feederFrom;
  final Offset feederCursor;
  final String? feederHover;
  final Color accent;
  final Color onAccent;
  final Set<String> essential;
  final Color essentialColor;

  _CanvasPainter({
    required this.project,
    required this.result,
    required this.positions,
    required this.transform,
    required this.rootId,
    required this.detail,
    required this.scheduleDetail,
    required this.gridLine,
    required this.background,
    required this.feederFrom,
    required this.feederCursor,
    required this.feederHover,
    required this.accent,
    required this.onAccent,
    required this.essential,
    required this.essentialColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    _grid(canvas, size);

    // Feeder lines: parent RIGHT edge → fed-panel LEFT edge (left-to-right tree,
    // like the CAD building single-line). The whole canvas flows left-to-right:
    // bus on the left, loads + feeders branch right, sub-panels step rightward.
    for (final p in project.panels) {
      for (final c in p.circuits) {
        final fed = c.feedsPanelId;
        if (fed == null) continue;
        final fromPanel = result.panels[p.id];
        final toPos = positions[fed];
        final fromPos = positions[p.id];
        if (fromPanel == null || toPos == null || fromPos == null) continue;
        final fromCardH = panelFootprint(fromPanel, detail);
        final fromW = panelCardWidthAt(fromPanel, detail);
        final start = transform.worldToScreen(
          Offset(fromPos.dx + fromW, fromPos.dy + fromCardH / 2),
        );
        final toPanel = result.panels[fed];
        final toH = toPanel == null ? 160.0 : panelFootprint(toPanel, detail);
        final end = transform.worldToScreen(
          Offset(toPos.dx, toPos.dy + toH / 2),
        );
        // Essential (emergency) feeders read red; the label carries the feeder's
        // sized cable + breaker (folded in from the old Overview).
        final isEss = essential.contains(fed);
        final colour = isEss ? essentialColor : accent;
        _smoothFeeder(canvas, start, end, colour: colour);
        final cr = fromPanel.circuits
            .where((r) => r.circuitId == c.id)
            .firstOrNull;
        if (cr != null) {
          final poles = cr.threePhase ? 3 : 1;
          final label = '${cableLabel(c, cr.cable.csaMm2, cr.threePhase)} mm2'
              ' · ${breakerScheduleLabel(cr.breaker, poles)}';
          final midX = (start.dx + end.dx) / 2;
          _label(canvas, Offset(midX, start.dy - 7), label, transform.scale,
              color: isEss ? essentialColor : onAccent);
        }
      }
    }

    // Drop lines from each card's bottom to its load node (the segment OUTSIDE
    // the card — the in-card schematic is painted by the card widget itself so
    // the card's opaque surface doesn't cover it). A label carries cable + util.
    // Skipped at the board-schedule LOD — the schedule lists every way itself,
    // so the hanging loads + their drop lines would be redundant.
    if (!scheduleDetail) {
      for (final id in result.order) {
        final panel = result.panels[id];
        final pos = positions[id];
        if (panel == null || pos == null) continue;
        _loadDrops(canvas, panel, pos);
      }
    }

    // In-flight feeder rubber-band.
    if (feederFrom != null) {
      final fromPos = positions[feederFrom];
      final fromPanel = result.panels[feederFrom];
      if (fromPos != null && fromPanel != null) {
        final w = panelCardWidthAt(fromPanel, detail);
        final h = panelFootprint(fromPanel, detail);
        final anchor = transform.worldToScreen(
          Offset(fromPos.dx + w, fromPos.dy + h / 2),
        );
        canvas.drawLine(
          anchor,
          feederCursor,
          Paint()
            ..color = accent
            ..strokeWidth = 2.5
            ..strokeCap = StrokeCap.round,
        );
        canvas.drawCircle(feederCursor, 5, Paint()..color = accent);
      }
    }
  }

  void _grid(Canvas canvas, Size size) =>
      paintCanvasGrid(canvas, size, transform, gridLine);

  /// Orthogonal LEFT-TO-RIGHT feeder from a parent's right edge [a] to a
  /// fed-panel's left edge [b]: right to a mid-X channel, vertical to the child's
  /// row, then right into it (the transpose of a top-down riser drop).
  void _smoothFeeder(Canvas canvas, Offset a, Offset b, {Color? colour}) {
    final col = colour ?? accent;
    final paint = Paint()
      ..color = col
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final midX = (a.dx + b.dx) / 2;
    final path = Path()
      ..moveTo(a.dx, a.dy)
      ..lineTo(midX, a.dy)
      ..lineTo(midX, b.dy)
      ..lineTo(b.dx, b.dy);
    canvas.drawPath(path, paint);
    // Tap dot at the fed panel incomer.
    canvas.drawCircle(b, 3, Paint()..color = col);
  }

  /// Connectors from the card's RIGHT edge to each load node in the right-hand
  /// column (the run OUTSIDE the card), labelled with cable + util. The in-card
  /// schematic itself is drawn by the card widget (see [SchematicPainter]).
  void _loadDrops(Canvas canvas, ElectricalPanelResult panel, Offset world) {
    final s = transform.scale;
    final cardH = panelFootprint(panel, detail);
    final w = panelCardWidth(panel.circuits.length);
    final rightEdge = world.dx + w;
    final loadLeft = world.dx + w + kLoadGapX;
    final threePhase = panel.system == ElectricalSystem.threePhase;
    // Collapsed (summary) view: one tidy connector from the card's right edge to
    // the merged loads node (centred), instead of a stem per way.
    if (!detail) {
      final hasLoads = panel.circuits.any((c) =>
          c.loadKind != LoadKind.feeder && c.loadKind != LoadKind.spare);
      if (!hasLoads) return;
      final midY = world.dy + cardH / 2;
      canvas.drawLine(
        transform.worldToScreen(Offset(rightEdge, midY)),
        transform.worldToScreen(Offset(loadLeft, midY)),
        Paint()
          ..color = accent
          ..strokeWidth = 1.6 * s,
      );
      return;
    }
    var j = -1;
    for (var i = 0; i < panel.circuits.length; i++) {
      final c = panel.circuits[i];
      if (c.loadKind == LoadKind.feeder || c.loadKind == LoadKind.spare) {
        continue;
      }
      j++;
      final rowY = world.dy + kPanelChrome + j * kLoadRowH + kLoadNodeH / 2;
      final phaseColor = phaseColorFor(c.phase, threePhase);
      canvas.drawLine(
        transform.worldToScreen(Offset(rightEdge, rowY)),
        transform.worldToScreen(Offset(loadLeft, rowY)),
        Paint()
          ..color = phaseColor
          ..strokeWidth = 1.6 * s,
      );
      // Cable label (size · util%) — only when zoomed enough to read.
      final util = _utilPct(c);
      final lbl = util != null
          ? '${c.grounding.cableSpec} · ${util.round()}%'
          : c.grounding.cableSpec;
      _label(
        canvas,
        transform.worldToScreen(Offset(rightEdge + 6, rowY - 9)),
        lbl,
        s,
      );
    }
  }

  void _label(Canvas canvas, Offset center, String text, double s,
      {Color? color}) {
    if (s < 0.4) return;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'Roboto',
          fontSize: 9 * s,
          color: color ?? onAccent,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect = Rect.fromCenter(
      center: center,
      width: tp.width + 8 * s,
      height: tp.height + 4 * s,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(3 * s)),
      Paint()..color = const Color(0xD915171B),
    );
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  double? _utilPct(ElectricalCircuitResult c) {
    final rating = c.breaker.ratingA.amperes;
    if (rating <= 0) return null;
    return (c.designCurrent.amperes / rating) * 100;
  }

  @override
  bool shouldRepaint(_CanvasPainter old) =>
      old.project != project ||
      old.result != result ||
      old.transform != transform ||
      old.detail != detail ||
      old.scheduleDetail != scheduleDetail ||
      old.feederFrom != feederFrom ||
      old.feederCursor != feederCursor ||
      old.feederHover != feederHover ||
      old.essential.length != essential.length ||
      !old.essential.containsAll(essential);
}

// ── Shared rail / phase colour helpers ───────────────────────────────────────

Color railColorFor(String key) => switch (key) {
  'L1' => kRailR,
  'L2' => kRailS,
  'L3' => kRailT,
  'L' => kRailR,
  'N' => kRailN,
  'PE' => kRailPE,
  _ => kRailR,
};

String railLetterFor(String key) => switch (key) {
  'L1' => 'R',
  'L2' => 'S',
  'L3' => 'T',
  'L' => 'R',
  'N' => 'N',
  'PE' => 'PE',
  _ => key,
};

String phaseKeyFor(PhaseAssignment phase) => switch (phase) {
  PhaseAssignment.l1 => 'L1',
  PhaseAssignment.l2 => 'L2',
  PhaseAssignment.l3 => 'L3',
  PhaseAssignment.threePhase => 'L1',
};

Color phaseColorFor(PhaseAssignment phase, bool threePhase) => switch (phase) {
  PhaseAssignment.l1 => kRailR,
  PhaseAssignment.l2 => kRailS,
  PhaseAssignment.l3 => kRailT,
  PhaseAssignment.threePhase => const Color(0xFFAAB2BD),
};

String amp0(double a) =>
    a == a.roundToDouble() ? a.toInt().toString() : a.toStringAsFixed(0);

/// The in-card schematic surface: paints the busbar + breakers and maps a
/// double-click / right-click to the way under the local x (column hit-test).
class _SchematicSurface extends StatelessWidget {
  final ElectricalPanelResult panel;
  final Color accent;
  final ValueChanged<String> onWayDoubleTap;
  final void Function(String, Offset) onWayMenu;

  const _SchematicSurface({
    required this.panel,
    required this.accent,
    required this.onWayDoubleTap,
    required this.onWayMenu,
  });

  /// The way whose column contains the local x, or null.
  String? _wayAt(double localX) {
    if (panel.circuits.isEmpty) return null;
    final i = ((localX - kLeft) / kWayW).floor();
    if (i < 0 || i >= panel.circuits.length) return null;
    return panel.circuits[i].circuitId;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) {
        if (e.buttons == kSecondaryButton) {
          final box = context.findRenderObject() as RenderBox?;
          final local = box?.globalToLocal(e.position) ?? Offset.zero;
          final id = _wayAt(local.dx);
          if (id != null) onWayMenu(id, e.position);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTapDown: (d) {
          final id = _wayAt(d.localPosition.dx);
          if (id != null) onWayDoubleTap(id);
        },
        onDoubleTap: () {},
        child: CustomPaint(
          painter: SchematicPainter(panel: panel, accent: accent),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// The in-card DEEP-zoom board-schedule surface: paints the real engine board
/// schedule (`buildElectricalPanelDetail` — the SAME geometry the PDF / DXF
/// export draws) fitted into the card body via [SldBoardSchedulePainter], and
/// maps a double-click / right-click to the way under the local y (the engine
/// lays one schedule ROW per circuit, so a local-y → row-index hit-test reaches
/// the same `onWayDoubleTap` / `onWayMenu` as the mid-detail schematic).
class _PanelScheduleBody extends StatelessWidget {
  final ElectricalPanelResult panel;
  final ElectricalProject project;
  final ElectricalSystemResult result;
  final ValueChanged<String> onWayDoubleTap;
  final void Function(String, Offset) onWayMenu;

  const _PanelScheduleBody({
    required this.panel,
    required this.project,
    required this.result,
    required this.onWayDoubleTap,
    required this.onWayMenu,
  });

  /// The board-schedule sheet for this one panel, re-origined to (0,0).
  SldSheet get _sheet => buildElectricalPanelDetail(
        project: project,
        result: result,
        panelId: panel.panelId,
      );

  /// Fit transform mapping the sheet bounds into [size] (matching
  /// [SldBoardSchedulePainter] so the hit-test agrees with the paint).
  ViewportTransform _fitTransform(SldSheet sheet, Size size) {
    final content = Size(
      math.max(1.0, sheet.maxX - sheet.minX),
      math.max(1.0, sheet.maxY - sheet.minY),
    );
    final fitted = ViewportTransform.fit(content, size, padding: 6);
    return ViewportTransform(
      scale: fitted.scale,
      offset: fitted.offset - Offset(sheet.minX, sheet.minY) * fitted.scale,
    );
  }

  /// The circuit id whose schedule row contains the body-local point, or null.
  /// Engine row geometry (re-origined): header band `_headerH = 46`, then the
  /// column-header row, then one `_rowH = 20` row per circuit — so way `i` starts
  /// at `headerH + 6 + (1 + i) * rowH` (the +1 skips the column-header row).
  String? _wayAt(Offset local, SldSheet sheet, Size size) {
    if (panel.circuits.isEmpty) return null;
    final t = _fitTransform(sheet, size);
    final world = t.screenToWorld(local);
    const headerH = 46.0, rowH = 20.0, rowTop = headerH + 6.0 + rowH;
    final i = ((world.dy - rowTop) / rowH).floor();
    if (i < 0 || i >= panel.circuits.length) return null;
    return panel.circuits[i].circuitId;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final sheet = _sheet;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return Listener(
          onPointerDown: (e) {
            if (e.buttons == kSecondaryButton) {
              final box = context.findRenderObject() as RenderBox?;
              final local = box?.globalToLocal(e.position) ?? Offset.zero;
              final id = _wayAt(local, sheet, size);
              if (id != null) onWayMenu(id, e.position);
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTapDown: (d) {
              final id = _wayAt(d.localPosition, sheet, size);
              if (id != null) onWayDoubleTap(id);
            },
            onDoubleTap: () {},
            child: CustomPaint(
              painter: SldBoardSchedulePainter(
                sheet: sheet,
                ink: colors.textPrimary,
                essential: colors.danger,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );
      },
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// In-card schematic painter — the R-S-T / N / PE busbar + breaker taps, drawn
// INSIDE the panel card at detail LOD (so the card's opaque surface doesn't
// cover it). Local (card) coordinates; the card reserves the full schematic
// height so it doesn't grow over the load nodes.
// ════════════════════════════════════════════════════════════════════════════

class SchematicPainter extends CustomPainter {
  final ElectricalPanelResult panel;
  final Color accent;

  SchematicPainter({required this.panel, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    final geom = panelGeometry(panel);
    final bars = geom.bars;
    final right = panelCardWidth(panel.circuits.length) - kRightPad;
    final threePhase = panel.system == ElectricalSystem.threePhase;

    // Rails + left identity pills.
    bars.forEach((key, ly) {
      final color = railColorFor(key);
      canvas.drawLine(
        Offset(kLeft.toDouble(), ly),
        Offset(right, ly),
        Paint()
          ..color = color
          ..strokeWidth = key == 'PE'
              ? 3.5
              : key == 'N'
              ? 4.0
              : 5.0
          ..strokeCap = StrokeCap.round,
      );
      _pill(canvas, Offset(6, ly), railLetterFor(key), color);
    });

    // Incomer head.
    final incRect = Rect.fromLTWH(
      kLeft.toDouble(),
      kIncomerY.toDouble(),
      148,
      kIncomerH.toDouble(),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(incRect, const Radius.circular(4)),
      Paint()..color = accent.withAlpha(40),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(incRect, const Radius.circular(4)),
      Paint()
        ..color = accent
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke,
    );
    _text(
      canvas,
      incRect.topLeft + const Offset(6, 6),
      'INC ${amp0(panel.incomer.breaker.ratingA.amperes)}/${panel.incomer.poles}P',
      9.5,
      accent,
      bold: true,
    );
    canvas.drawLine(
      Offset(incRect.left + 16, incRect.bottom),
      Offset(kLeft + 16, bars['N'] ?? bars.values.last),
      Paint()
        ..color = accent.withAlpha(150)
        ..strokeWidth = 2,
    );

    final lastBarY = bars.values.reduce(math.max);
    final brkTop = lastBarY + kBrkGap;
    final outY = geom.outY;

    for (var i = 0; i < panel.circuits.length; i++) {
      final c = panel.circuits[i];
      final cx = wayColumnX(i).toDouble();
      final isSpare = c.loadKind == LoadKind.spare;
      final phaseColor = phaseColorFor(c.phase, threePhase);

      final liveBars = c.phase == PhaseAssignment.threePhase
          ? const ['L1', 'L2', 'L3']
          : [phaseKeyFor(c.phase)];
      var j = 0;
      for (final k in liveBars) {
        final by = bars[k] ?? bars['L1'] ?? lastBarY;
        final offX = liveBars.length == 3 ? (j - 1) * 5.0 : 0.0;
        canvas.drawLine(
          Offset(cx + offX, by),
          Offset(cx + offX, brkTop),
          Paint()
            ..color = railColorFor(k)
            ..strokeWidth = 1.8,
        );
        j++;
      }
      // PE drop.
      final peY = bars['PE'];
      if (peY != null) {
        _dashed(canvas, Offset(cx + 12, peY), Offset(cx + 12, outY), kRailPE);
      }
      // Breaker glyph + run + terminal + rating.
      _breaker(canvas, Offset(cx, brkTop), phaseColor);
      canvas.drawLine(
        Offset(cx, brkTop + kBrkH),
        Offset(cx, outY),
        Paint()
          ..color = isSpare
              ? const Color(0x66888888)
              : (c.phase == PhaseAssignment.threePhase
                    ? const Color(0xFFAAB2BD)
                    : phaseColor)
          ..strokeWidth = 1.8,
      );
      canvas.drawCircle(Offset(cx, outY), 2.4, Paint()..color = phaseColor);
      _text(
        canvas,
        Offset(cx + 9, brkTop + 4),
        '${amp0(c.breaker.ratingA.amperes)}A',
        9,
        accent,
        bold: true,
      );
    }
  }

  void _pill(Canvas canvas, Offset at, String letter, Color color) {
    final rect = Rect.fromLTWH(at.dx, at.dy - 6, 16, 12);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()..color = color,
    );
    _text(
      canvas,
      rect.topLeft + const Offset(3, 0.5),
      letter,
      8.5,
      const Color(0xFFFFFFFF),
      bold: true,
    );
  }

  void _breaker(Canvas canvas, Offset top, Color color) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(top + const Offset(0, 2), 1.6, Paint()..color = color);
    canvas.drawLine(top + const Offset(0, 2), top + const Offset(7, 12), p);
    canvas.drawCircle(top + const Offset(0, 16), 1.4, Paint()..color = color);
    canvas.drawLine(
      top + const Offset(0, 16),
      top + Offset(0, kBrkH.toDouble()),
      p,
    );
    canvas.drawRect(
      Rect.fromLTWH(top.dx + 4, top.dy + 6, 5, 5),
      p..style = PaintingStyle.stroke,
    );
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Color color) {
    final total = (b - a).distance;
    final dir = (b - a) / (total == 0 ? 1 : total);
    const dash = 4.0, gap = 2.0;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.4;
    var t = 0.0;
    while (t < total) {
      canvas.drawLine(a + dir * t, a + dir * math.min(t + dash, total), paint);
      t += dash + gap;
    }
  }

  void _text(
    Canvas canvas,
    Offset at,
    String text,
    double size,
    Color color, {
    bool bold = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'Roboto',
          fontSize: size,
          color: color,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(SchematicPainter old) =>
      old.panel != panel || old.accent != accent;
}

// ════════════════════════════════════════════════════════════════════════════
// Panel card node (summary + detail share the same header chrome).
// ════════════════════════════════════════════════════════════════════════════

class _PanelCardNode extends StatefulWidget {
  final ElectricalPanelResult panel;
  final bool detail;

  /// DEEP zoom — render the real engine board schedule in the card body instead
  /// of the hand-painted R-S-T busbar. Requires [project] / [result] to build
  /// the single-panel detail [SldSheet].
  final bool scheduleDetail;
  final ElectricalProject project;
  final ElectricalSystemResult result;
  final bool selected;
  final bool unfed;
  final bool essential;
  final bool upsBacked;
  final bool submeter;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final ValueChanged<Offset> onMenu;
  final ValueChanged<String> onWayDoubleTap;
  final void Function(String, Offset) onWayMenu;
  final ValueChanged<PaletteLoad> onDropLoad;
  final ValueChanged<Offset> onOutletDragStart;
  final ValueChanged<Offset> onOutletDragUpdate;
  final VoidCallback onOutletDragEnd;

  const _PanelCardNode({
    required this.panel,
    required this.detail,
    required this.scheduleDetail,
    required this.project,
    required this.result,
    required this.selected,
    required this.unfed,
    required this.essential,
    required this.upsBacked,
    required this.submeter,
    required this.onTap,
    required this.onDoubleTap,
    required this.onMenu,
    required this.onWayDoubleTap,
    required this.onWayMenu,
    required this.onDropLoad,
    required this.onOutletDragStart,
    required this.onOutletDragUpdate,
    required this.onOutletDragEnd,
  });

  @override
  State<_PanelCardNode> createState() => _PanelCardNodeState();
}

class _PanelCardNodeState extends State<_PanelCardNode> {
  bool _hover = false;
  bool _dropHover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final panel = widget.panel;
    final hasError = panel.warnings.any(
      (w) => w.severity == WarningSeverity.error,
    );
    // Essential (genset-backed / emergency) boards read RED — the riser-drawing
    // convention, folded in from the old Overview tab; error/selection/hover win.
    final borderColor = hasError
        ? colors.danger
        : (widget.selected || _hover || _dropHover)
        ? colors.accent
        : widget.essential
        ? colors.danger
        : colors.border;

    // The card reserves the full schematic height at BOTH LOD levels (header
    // chrome of kPanelChrome + the schematic band), so the load nodes sit a
    // fixed distance below regardless of zoom and the card never grows over
    // them when it switches to the detail schematic.
    final card = AnimatedContainer(
      duration: MechXMotion.hover,
      curve: MechXMotion.standard,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: borderColor, width: widget.selected ? 2 : 1),
        // Soft iOS elevation; lifts a touch on hover / selection.
        boxShadow: (_hover || widget.selected)
            ? MechXShadow.popover
            : MechXShadow.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header chrome — a fixed band (kPanelChrome) so the SVG below lines
          // up summary-or-detail. DROPPED at the board-schedule LOD, where the
          // engine schedule draws its OWN header (name [tag] + incomer line), so
          // the card chrome would just repeat the panel name.
          if (!widget.scheduleDetail)
            SizedBox(
              height: kPanelChrome,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                child: _header(context),
              ),
            ),
          Expanded(
            // Cross-fade the summary ↔ detail schematic at the LOD threshold
            // instead of an instant swap.
            child: AnimatedSwitcher(
              duration: MechXMotion.appear,
              switchInCurve: MechXMotion.standard,
              switchOutCurve: MechXMotion.standard,
              child: widget.scheduleDetail
                  ? KeyedSubtree(
                      key: const ValueKey('schedule'),
                      child: _PanelScheduleBody(
                        panel: panel,
                        project: widget.project,
                        result: widget.result,
                        onWayDoubleTap: widget.onWayDoubleTap,
                        onWayMenu: widget.onWayMenu,
                      ),
                    )
                  : widget.detail
                      ? KeyedSubtree(
                          key: const ValueKey('detail'),
                          child: _SchematicSurface(
                            panel: panel,
                            accent: colors.accent,
                            onWayDoubleTap: widget.onWayDoubleTap,
                            onWayMenu: widget.onWayMenu,
                          ),
                        )
                      : Padding(
                          key: const ValueKey('summary'),
                          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                          child: _PanelSummaryBody(panel: panel),
                        ),
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
          // Subtle hover lift — a pre-click affordance.
          child: AnimatedScale(
            scale: (_hover && !widget.selected) ? MechXMotion.hoverLift : 1.0,
            duration: MechXMotion.hover,
            curve: MechXMotion.standard,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(child: card),
                // The round outlet handle (drag → feeder) — on the RIGHT edge,
                // vertically centred, since the tree flows left-to-right and
                // feeders exit a panel's right side toward its sub-panels.
                Positioned(
                  right: -13,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _OutletHandle(
                      onDragStart: widget.onOutletDragStart,
                      onDragUpdate: widget.onOutletDragUpdate,
                      onDragEnd: widget.onOutletDragEnd,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final panel = widget.panel;
    final tag = panel.tag;
    return Listener(
      onPointerDown: (e) {
        if (e.buttons == kSecondaryButton) widget.onMenu(e.position);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: MechXSpacing.xs),
              decoration: BoxDecoration(
                color: colors.accent,
                borderRadius: const BorderRadius.all(Radius.circular(2)),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (tag != null && tag.isNotEmpty)
                    Text(
                      tag,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.caption.copyWith(
                        color: colors.accent,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'Roboto Mono',
                      ),
                    ),
                  Text(
                    panel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.label.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: MechXSpacing.xs),
            ..._badges(context),
          ],
        ),
      ),
    );
  }

  List<Widget> _badges(BuildContext context) {
    final colors = context.colors;
    final badges = <Widget>[];
    if (widget.unfed) {
      badges.add(_Badge(label: 'not connected', color: colors.warning));
    } else {
      badges.add(
        _Badge(
          label: widget.panel.tag != null ? 'supply' : 'fed',
          color: colors.accent,
          subtle: true,
        ),
      );
    }
    if (widget.essential) {
      badges.add(_Badge(label: 'essential', color: colors.warning, subtle: true));
    }
    if (widget.upsBacked) {
      badges.add(_Badge(label: 'UPS', color: colors.accent, subtle: true));
    }
    if (widget.submeter) {
      badges.add(_Badge(label: 'kWh', color: colors.success, subtle: true));
    }
    return [
      for (final b in badges)
        Padding(padding: const EdgeInsets.only(left: 3), child: b),
    ];
  }
}

class _PanelSummaryBody extends StatelessWidget {
  final ElectricalPanelResult panel;
  const _PanelSummaryBody({required this.panel});

  @override
  Widget build(BuildContext context) {
    final spares = panel.circuits
        .where((c) => c.loadKind == LoadKind.spare)
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 6,
          children: [
            _Stat(value: fmtKw(panel.connectedW), label: 'load'),
            _Stat(value: fmtAmp(panel.demandCurrent.amperes), label: 'demand'),
            _Stat(
              value:
                  '${_cls(panel.incomer.breaker)} ${fmtAmp0(panel.incomer.breaker.ratingA.amperes)}/${panel.incomer.poles}P',
              label: 'incomer',
            ),
            _Stat(
              value:
                  '${panel.system == ElectricalSystem.threePhase ? '3' : '1'}φ',
              label: 'system',
            ),
            _Stat(
              value: spares > 0
                  ? '${panel.circuits.length} (+$spares sp)'
                  : '${panel.circuits.length}',
              label: 'ways',
            ),
          ],
        ),
        if (panel.system == ElectricalSystem.threePhase)
          _PhaseStrip(balance: panel.phaseBalance),
      ],
    );
  }

  String _cls(BreakerResult b) =>
      b.deviceClass.name.toUpperCase() == 'MCCB' ? 'MCCB' : 'MCB';
}

class _PhaseStrip extends StatelessWidget {
  final PhaseBalanceResult balance;
  const _PhaseStrip({required this.balance});

  @override
  Widget build(BuildContext context) {
    final type = context.type;
    Widget cell(String letter, Color color, double amps) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            borderRadius: const BorderRadius.all(Radius.circular(4)),
          ),
          child: Text(
            letter,
            style: const TextStyle(
              fontFamily: 'Roboto',
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: Color(0xFFFFFFFF),
            ),
          ),
        ),
        const SizedBox(width: 3),
        Text(
          fmtAmp0(amps),
          style: type.caption.copyWith(
            color: context.colors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 12,
        children: [
          cell('R', kRailR, balance.l1),
          cell('S', kRailS, balance.l2),
          cell('T', kRailT, balance.l3),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String value;
  final String label;
  const _Stat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: type.label.copyWith(
            color: colors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          label.toUpperCase(),
          style: type.caption.copyWith(
            color: colors.textMuted,
            fontSize: 9,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  final bool subtle;
  const _Badge({required this.label, required this.color, this.subtle = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: subtle ? color.withAlpha(36) : color,
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        border: Border.all(color: color.withAlpha(subtle ? 90 : 255)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'Roboto',
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: subtle ? color : const Color(0xFFFFFFFF),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Load node (hangs below the panel).
// ════════════════════════════════════════════════════════════════════════════

class _LoadNode extends StatefulWidget {
  final ElectricalCircuitResult circuit;
  const _LoadNode({required this.circuit});

  @override
  State<_LoadNode> createState() => _LoadNodeState();
}

class _LoadNodeState extends State<_LoadNode> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final c = widget.circuit;
    final rating = c.breaker.ratingA.amperes;
    final util = rating > 0 ? (c.designCurrent.amperes / rating * 100) : null;
    final utilColor = util == null
        ? colors.textMuted
        : util >= 100
        ? colors.danger
        : util >= 85
        ? colors.warning
        : colors.textMuted;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      // Subtle hover lift + an accent ring preview.
      child: AnimatedScale(
        scale: _hover ? MechXMotion.hoverLift : 1.0,
        duration: MechXMotion.hover,
        curve: MechXMotion.standard,
        child: AnimatedContainer(
          duration: MechXMotion.hover,
          curve: MechXMotion.standard,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: MechXRadii.control,
            border: Border.all(color: _hover ? colors.accent : colors.border),
            boxShadow: _hover
                ? MechXShadow.card
                : const [
                    BoxShadow(
                      color: Color(0x22000000),
                      blurRadius: 4,
                      offset: Offset(0, 1),
                    ),
                  ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LoadSymbol(
                kind: c.loadKind,
                color: colors.textSecondary,
                size: 22,
              ),
              const SizedBox(height: 2),
              Text(
                c.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'Roboto',
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                util != null
                    ? '${fmtAmp0(rating)}A · ${util.round()}%'
                    : '${fmtAmp0(rating)}A',
                textAlign: TextAlign.center,
                style: type.caption.copyWith(fontSize: 9, color: utilColor),
              ),
            ],
          ),
        ),
      ),
    );
  }

}

// ════════════════════════════════════════════════════════════════════════════
// Merged loads node — the zoomed-out summary that stands in for a panel's
// individual load nodes (they break out when zoomed in past the LOD threshold).
// ════════════════════════════════════════════════════════════════════════════

class _MergedLoadsNode extends StatelessWidget {
  final int count;
  const _MergedLoadsNode({required this.count});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Container(
      padding: const EdgeInsets.all(5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.control,
        border: Border.all(color: colors.border),
        boxShadow: const [
          BoxShadow(color: Color(0x22000000), blurRadius: 4, offset: Offset(0, 1)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CustomPaint(
            size: const Size(22, 20),
            painter: _StackedLoadsGlyph(colors.textSecondary, colors.surface),
          ),
          const SizedBox(height: 3),
          Text(
            '$count ${count == 1 ? 'load' : 'loads'}',
            textAlign: TextAlign.center,
            style: type.caption.copyWith(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Three offset rounded cards — a "stack", conveying several loads collapsed
/// into one. Each is filled (with the node surface) so it occludes the one
/// behind, then outlined, so the layering reads cleanly.
class _StackedLoadsGlyph extends CustomPainter {
  final Color color;
  final Color fill;
  const _StackedLoadsGlyph(this.color, this.fill);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final cardW = w * 0.6, cardH = h * 0.62;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeJoin = StrokeJoin.round;
    final fillP = Paint()..color = fill;
    for (var i = 2; i >= 0; i--) {
      final dx = i * (w - cardW) / 2;
      final dy = i * (h - cardH) / 2;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(dx, dy, cardW, cardH),
        const Radius.circular(2.5),
      );
      canvas.drawRRect(rect, fillP);
      canvas.drawRRect(rect, stroke);
    }
  }

  @override
  bool shouldRepaint(_StackedLoadsGlyph old) =>
      old.color != color || old.fill != fill;
}

// ════════════════════════════════════════════════════════════════════════════
// Source-spine strip painter — the read-only PLN/MV/transformer/LV-main +
// genset/capacitor chain (`buildElectricalSourceSpine`) drawn ABOVE the root
// panel, sharing the canvas zoom. The SAME geometry the overview / riser /
// export draw — one source of truth (project guardrail 5).
// ════════════════════════════════════════════════════════════════════════════

class _SourceSpinePainter extends CustomPainter {
  final SldSheet sheet;

  /// World position of the band's top-left (= sheet (minX,minY) + placement
  /// offset). Unused for the paint math (it cancels) but kept for clarity /
  /// repaint identity.
  final Offset origin;
  final double scale;
  final Color ink;
  final Color source;
  final Color essential;
  final Color rectFill;

  _SourceSpinePainter({
    required this.sheet,
    required this.origin,
    required this.scale,
    required this.ink,
    required this.source,
    required this.essential,
    required this.rectFill,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // A transform mapping sheet-space directly into the band's local screen
    // space: worldToScreen(p) = (p - sheet.min) * scale.
    final transform = ViewportTransform(
      scale: scale,
      offset: -Offset(sheet.minX, sheet.minY) * scale,
    );
    paintSldPrims(
      canvas,
      sheet,
      transform,
      ink: ink,
      essential: essential,
      source: source,
      rectFill: rectFill,
    );
  }

  @override
  bool shouldRepaint(_SourceSpinePainter old) =>
      old.sheet != sheet ||
      old.origin != origin ||
      old.scale != scale ||
      old.ink != ink ||
      old.source != source ||
      old.essential != essential ||
      old.rectFill != rectFill;
}

// ════════════════════════════════════════════════════════════════════════════
// PLN grid-supply head (above the service-root panel).
// ════════════════════════════════════════════════════════════════════════════

class _GridSourceNode extends StatelessWidget {
  final ElectricalSystem voltage;
  const _GridSourceNode({required this.voltage});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.accent.withAlpha(160), width: 1.5),
      ),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: kRailR, width: 2),
            ),
            child: Text(
              '~',
              style: TextStyle(
                fontFamily: 'Roboto',
                fontSize: 12,
                color: kRailR,
              ),
            ),
          ),
          const SizedBox(width: MechXSpacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'PLN grid supply',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.label.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'Low voltage (direct PLN)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.caption.copyWith(color: colors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Outlet handle (round dot the user drags to create a feeder).
// ════════════════════════════════════════════════════════════════════════════

class _OutletHandle extends StatelessWidget {
  final ValueChanged<Offset> onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;

  const _OutletHandle({
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.precise,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) => onDragStart(d.globalPosition),
        onPanUpdate: (d) => onDragUpdate(d.globalPosition),
        onPanEnd: (_) => onDragEnd(),
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: colors.accent,
            shape: BoxShape.circle,
            border: Border.all(color: colors.surface, width: 3),
            boxShadow: const [
              BoxShadow(
                color: Color(0x40000000),
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: Center(
            child: Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: Color(0xFFFFFFFF),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Panel body drag (move) — wraps the card so a body drag repositions the panel.
// ════════════════════════════════════════════════════════════════════════════

class _PanelDraggable extends StatefulWidget {
  final String panelId;
  final Offset world;
  final double scale;
  final ElectricalProjectController controller;
  final Widget child;

  const _PanelDraggable({
    required this.panelId,
    required this.world,
    required this.scale,
    required this.controller,
    required this.child,
  });

  @override
  State<_PanelDraggable> createState() => _PanelDraggableState();
}

class _PanelDraggableState extends State<_PanelDraggable> {
  Offset? _dragWorld;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => _dragWorld = widget.world,
      onPanUpdate: (d) {
        final next = (_dragWorld ?? widget.world) + d.delta / widget.scale;
        _dragWorld = next;
        widget.controller.setPanelPosition(widget.panelId, next.dx, next.dy);
      },
      onPanEnd: (_) {
        final w = _dragWorld;
        if (w != null) {
          // Snap to the 16px world grid on release.
          widget.controller.setPanelPosition(
            widget.panelId,
            _snap(w.dx),
            _snap(w.dy),
          );
        }
        _dragWorld = null;
      },
      child: widget.child,
    );
  }

  double _snap(double v) => (v / kGrid).round() * kGrid.toDouble();
}

// ════════════════════════════════════════════════════════════════════════════
// Scaled-child wrapper — lays the node out at its NATURAL (world-px) size then
// scales it visually, regardless of the (already-scaled) `Positioned` box. An
// `OverflowBox` frees the child from the tight scaled constraints (the same
// trick `CanvasView` uses) so a node never over-constrains and overflows.
// ════════════════════════════════════════════════════════════════════════════

class _ScaledChild extends StatelessWidget {
  final double scale;
  final double width;
  final double height;
  final Widget child;

  const _ScaledChild({
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
// Scaled tap wrapper (double-click / right-click on a transformed child).
// ════════════════════════════════════════════════════════════════════════════

class _ScaledTap extends StatelessWidget {
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final ValueChanged<Offset>? onMenu;
  final Widget child;

  const _ScaledTap({
    this.onTap,
    this.onDoubleTap,
    this.onMenu,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) {
        if (e.buttons == kSecondaryButton && onMenu != null) {
          onMenu!(e.position);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        child: child,
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Canvas-wide palette drop target.
// ════════════════════════════════════════════════════════════════════════════

class _CanvasDropTarget extends StatefulWidget {
  final ViewportTransform transform;
  final int panelCount;
  final ElectricalProjectController controller;
  final ValueChanged<String> onToast;

  const _CanvasDropTarget({
    required this.transform,
    required this.panelCount,
    required this.controller,
    required this.onToast,
  });

  @override
  State<_CanvasDropTarget> createState() => _CanvasDropTargetState();
}

class _CanvasDropTargetState extends State<_CanvasDropTarget> {
  bool _active = false;

  /// The live drag position (LOCAL canvas px) and payload — set on move and
  /// cleared on leave/accept. Transient (drag-only), so idle is byte-identical.
  Offset? _dragLocal;
  PaletteLoad? _dragLoad;

  void _clearDrag() {
    if (_active || _dragLocal != null || _dragLoad != null) {
      setState(() {
        _active = false;
        _dragLocal = null;
        _dragLoad = null;
      });
    }
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
        final box = context.findRenderObject() as RenderBox?;
        final local = box?.globalToLocal(d.offset);
        if (local == null) return;
        setState(() {
          _active = true;
          _dragLocal = local;
          _dragLoad = d.data;
        });
      },
      onLeave: (_) => _clearDrag(),
      onAcceptWithDetails: (details) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) {
          _clearDrag();
          return;
        }
        final local = box.globalToLocal(details.offset);
        final load = details.data;
        // Blank canvas → floating load (or a sub-panel for the feeder kind).
        // A drop over a panel is consumed by the panel's own DragTarget above.
        final world = widget.transform.screenToWorld(local);
        final x = (world.dx / kGrid).round() * kGrid.toDouble();
        final y = (world.dy / kGrid).round() * kGrid.toDouble();
        if (load.kind == LoadKind.feeder) {
          final n = widget.panelCount + 1;
          widget.controller.addPanelAt(
            name: 'Sub-panel $n',
            tag: 'SP-$n',
            x: x,
            y: y,
            system: load.phases == 1
                ? ElectricalSystem.singlePhase
                : ElectricalSystem.threePhase,
            voltage: load.phases == 1 ? const Voltage(220) : const Voltage(400),
          );
          widget.onToast('Panel added — not fed yet.');
        } else {
          widget.controller.addFloatingLoad(
            kind: load.kind,
            x: x,
            y: y,
            phases: load.phases,
            loadW: load.loadW > 0 ? load.loadW : null,
            motorKw: load.motorKw,
          );
          widget.onToast('Load dropped — wire it to a panel.');
        }
        _clearDrag();
      },
      builder: (context, candidate, rejected) {
        if (!_active) return const IgnorePointer(child: SizedBox.expand());
        final accent = context.colors.accent;
        // Matches the mechanical drop overlay's tint + rounded affordance, plus
        // a cursor-following ghost of the dragged load. Drag-only (mounted only
        // while `_active`), so the at-rest canvas is byte-identical.
        return IgnorePointer(
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: accent.withAlpha(18),
                    borderRadius: MechXRadii.card,
                    border: Border.all(color: accent.withAlpha(110), width: 1.5),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
              if (_dragLocal != null && _dragLoad != null)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _CanvasDropPreviewPainter(
                      kind: _dragLoad!.kind,
                      cursorLocal: _dragLocal!,
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
}

/// Paints the cursor-following ghost [LoadSymbol] while a palette card hovers
/// the blank single-line canvas. Blank-canvas drops always create a floating
/// load / sub-panel (never attach to a panel), so there is no snap ring — just
/// the ghost. Drag-only; never affects the at-rest canvas.
class _CanvasDropPreviewPainter extends CustomPainter {
  final LoadKind kind;
  final Offset cursorLocal;
  final Color color;

  _CanvasDropPreviewPainter({
    required this.kind,
    required this.cursorLocal,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const box = 36.0;
    final ghostColor = color.withAlpha(115);
    canvas.save();
    canvas.translate(cursorLocal.dx - box / 2, cursorLocal.dy - box / 2);
    paintLoadSymbol(canvas, const Size(box, box), kind, ghostColor, stroke: 2.0);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CanvasDropPreviewPainter old) =>
      old.kind != kind ||
      old.cursorLocal != cursorLocal ||
      old.color != color;
}

