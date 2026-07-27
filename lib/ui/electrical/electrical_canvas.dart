/// The electrical SINGLE-LINE spatial canvas — a faithful Flutter port of
/// PanelMaker's `BuildingSingleLine.tsx`. Panels are boxes on a pannable /
/// zoomable canvas, wired by feeder lines, with a **zoom-driven
/// level-of-detail across THREE honest bands** ([PanelLod]), separated by two
/// thresholds:
///
///  • below [kMicroThreshold] — **micro**: a plan-reading chip (designation,
///    connected kW, a proportional R/S/T bar). No badges, no stats, no merged
///    loads node, no outlet handle, no expand chevron — at that zoom none of
///    them are legible OR grabbable, so offering them would be a lie. Selection,
///    tap-select and double-click-to-edit still work.
///  • [kMicroThreshold] … [kLodThreshold] — **summary**: the compact stats card
///    (kW / demand / incomer / bus / system / ways / placed) + its merged
///    "N loads" node, with the outlet handle and expand chevron live.
///  • at/above [kLodThreshold] — **schedule**: the full engine board schedule
///    (the same geometry the PDF / DXF export draws; the way rows ARE the
///    loads).
///
/// (The old mid-detail hand-painted busbar was an unreachable middle tier and
/// was removed — I7; the micro band added here is a genuinely reachable tier,
/// with its own honest content.) A summary card carries an explicit expand
/// chevron (frames its board schedule); a tap on empty schedule chrome zooms
/// back out to the summary.
///
/// Anatomy (mirrors the reference):
///  • a [ViewportTransform]-driven canvas (reusing the mechanical canvas's
///    zoom-to-cursor / middle-drag-pan / scroll math) with a dark grid;
///  • panel nodes positioned at their `x,y` (auto-layout when null — service
///    root left, fed panels by depth to the right, grid-snapped);
///  • the real engine board schedule (`buildElectricalPanelDetail`) drawn past
///    the LOD threshold — the same geometry the PDF / DXF export draws;
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
import 'package:mechx_engine/electrical/panel_templates.dart'
    show panelTemplateById;
import 'package:mechx_engine/electrical/results.dart' show BreakerResult;
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/units.dart';

import '../../store/app_state.dart';
import '../../store/electrical_store.dart';
import '../../store/history_store.dart';
import '../canvas/canvas_grid.dart';
import '../canvas/text_entry_guard.dart';
import '../canvas/viewport.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'electrical_export.dart' show breakerIcuKaByPanel;
import 'electrical_format.dart';
import 'electrical_palette.dart';
import 'load_symbols.dart';
import 'panel_geometry.dart';
import 'sld_sheet_painter.dart';

/// LOD threshold — at/above this zoom each panel shows its full internal
/// schematic; below it, a compact summary card (PanelMaker `transform[2] >=
/// 0.72`).
const double kLodThreshold = 0.72;

/// The lower LOD boundary — below this zoom a panel collapses to the MICRO chip
/// (identity + kW + phase bar). Chosen so the summary card's smallest text
/// (9 px caption) is still ~3 px on screen at the boundary: below it the stats
/// are unreadable and the 26-screen-px outlet band would have to eat a third of
/// the card, so the micro tier honestly drops both.
const double kMicroThreshold = 0.30;

/// The panel LOD for a canvas [scale] — the ONE mapping every call site uses so
/// the painted card, the hit-test rect and the feeder endpoints can never
/// disagree about which tier is on screen.
PanelLod panelLodFor(double scale) => scale < kMicroThreshold
    ? PanelLod.micro
    : (scale < kLodThreshold ? PanelLod.summary : PanelLod.schedule);

/// Every panel id that some circuit, on some board, actually FEEDS — the honest
/// answer to "is this board connected?".
///
/// Read from the live feeder ways rather than the target's own
/// `fedByCircuitId` back-pointer: the back-pointer is a convenience mirror that
/// a sanitised / hand-edited / partially-migrated project can desync from the
/// ways, and a board with no incoming way is NOT fed however its own field
/// reads. The canvas badge, the body-drop gate and the re-feed hint all share
/// this one source.
Set<String> fedPanelIds(ElectricalProject project) => {
      for (final p in project.panels)
        for (final c in p.circuits)
          if (c.feedsPanelId != null) c.feedsPanelId!,
    };

/// Screen-px grab width the outlet band guarantees at ANY zoom (the band's
/// LOGICAL width is this divided by the current scale, capped at a third of the
/// card so it never eats the schedule's way-row tap targets).
const double kOutletBandScreenPx = 26;

/// Diameter of the visual outlet dot; half of it overhangs the card's right
/// edge (painted through the card Stack's `Clip.none`, while the HIT area stays
/// wholly inside the card so no RenderBox rejects it).
const double kOutletDotSize = 22;

/// How far the outlet dot's paint overhangs the card edge.
const double kOutletDotOverhang = kOutletDotSize / 2;

/// The outlet band's LOGICAL (world-px) width on a [cardWidth]-wide card at
/// [scale] — at least [kOutletBandScreenPx] on screen, never more than a third
/// of the card.
double outletBandWidth(double cardWidth, double scale) => math.min(
      cardWidth / 3,
      math.max(kOutletBandScreenPx, kOutletBandScreenPx / math.max(scale, 0.01)),
    );

/// The zoom the "focus this panel" gesture ([ElectricalCanvasState.focusPanelSchedule])
/// frames a board at — a comfortable schedule-reading scale, well above
/// [kLodThreshold] (which is the ONE tier boundary between the summary card and
/// the board schedule). No longer a separate rendering threshold: the board
/// schedule now renders for any zoom at/above [kLodThreshold] (I7 removed the
/// dead mid-detail tier); this is purely the focus/deep-zoom target.
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

/// The canvas's live viewport (transform + widget size), published to the host
/// (the minimap, I8) via a [ValueNotifier] so the minimap can draw a truthful
/// viewport rectangle and pan-to-tap without the host rebuilding on every pan.
typedef CanvasViewport = ({ViewportTransform transform, Size size});

/// A selected element on the single-line canvas — a panel, or one way within a
/// panel. Selecting a way (schedule row) highlights it and lets Delete remove
/// the circuit (I5); at most one of [panelId]-only or [panelId]+[circuitId].
@immutable
class _CanvasSelection {
  final String panelId;
  final String? circuitId;
  const _CanvasSelection.circuit(this.panelId, String this.circuitId);
  bool get isCircuit => circuitId != null;
}

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

  /// Published each frame with the live transform + viewport size so the host's
  /// minimap (I8) tracks the real view. Optional; null ⇒ nothing published.
  final ValueNotifier<CanvasViewport?>? viewport;

  const ElectricalCanvas({
    super.key,
    required this.onEditPanel,
    required this.onEditCircuit,
    required this.onPanelMenu,
    required this.onCircuitMenu,
    required this.onRequestService,
    required this.onRequestSources,
    this.viewport,
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

  // The hover target's VERDICT, resolved once per hover CHANGE (not per paint
  // frame) from the store's pure [feederRefusalReason] — so the ring the user
  // sees is the exact rule the drop will apply.
  bool _feederHoverRefused = false;

  /// True when dropping on the hover target would RE-PARENT it (it is already
  /// fed) — drives the small "re-feed" pill beside the cursor.
  bool _feederHoverReparent = false;

  // The selected WAY within a panel (a schedule row) — drives the row highlight
  // + the Delete key (I5). Panel selection is the separate [_selectedPanels] set
  // (D2 multi-select) so shift-click / marquee can select several boards; at
  // most one of the two is active at a time.
  _CanvasSelection? _selection;

  // D2: the multi-selected panels (shift-click toggles, marquee unions, a plain
  // click replaces). Drives the selection ring, group move / arrow-nudge, and
  // multi-Delete.
  Set<String> _selectedPanels = const {};

  // D2: the in-flight marquee (screen-space rectangle) drawn by an empty-canvas
  // left-drag; null when not marqueeing.
  Offset? _marqueeStart;
  Offset? _marqueeCurrent;

  // D2: live group-drag world positions (id → world) captured at drag start;
  // null when no panel body drag is in flight.
  Map<String, Offset>? _panelDragWorld;

  void _selectPanel(String id) {
    final shift = HardwareKeyboard.instance.isShiftPressed;
    setState(() {
      _selection = null;
      if (shift) {
        final next = {..._selectedPanels};
        if (!next.add(id)) next.remove(id);
        _selectedPanels = next;
      } else {
        _selectedPanels = {id};
      }
    });
  }

  void _selectCircuit(String panelId, String circuitId) => setState(() {
        _selection = _CanvasSelection.circuit(panelId, circuitId);
        _selectedPanels = const {};
      });

  void _clearSelection() {
    if (_selection != null || _selectedPanels.isNotEmpty) {
      setState(() {
        _selection = null;
        _selectedPanels = const {};
      });
    }
  }

  double _snapGrid(double v) => (v / kGrid).round() * kGrid.toDouble();

  // ── D2: panel body drag (single or group move) ──────────────────────────────

  void _beginPanelDrag(String panelId, Map<String, Offset> positions) {
    _ctrl.pushUndoSnapshot();
    // Drag the whole selection when the grabbed panel is part of a multi-select;
    // otherwise just this panel (and make it the selection, so the ring tracks).
    final group = (_selectedPanels.contains(panelId) && _selectedPanels.length > 1)
        ? _selectedPanels
        : {panelId};
    if (!_selectedPanels.contains(panelId)) {
      setState(() {
        _selectedPanels = {panelId};
        _selection = null;
      });
    }
    _panelDragWorld = {
      for (final id in group) id: positions[id] ?? Offset.zero,
    };
  }

  void _updatePanelDrag(Offset worldDelta) {
    final map = _panelDragWorld;
    if (map == null) return;
    map.updateAll((id, w) => w + worldDelta);
    map.forEach((id, w) => _ctrl.setPanelPosition(id, w.dx, w.dy));
  }

  void _endPanelDrag() {
    final map = _panelDragWorld;
    _panelDragWorld = null;
    if (map == null) return;
    map.forEach((id, w) =>
        _ctrl.setPanelPosition(id, _snapGrid(w.dx), _snapGrid(w.dy)));
    _tryBodyDropConnect(map);
  }

  /// BODY-DROP CONNECT — dropping an UNFED board on top of another board wires
  /// it as that board's sub-panel, the direct-manipulation counterpart of
  /// dragging the outlet handle.
  ///
  /// Deliberately narrow so it can never surprise: it fires only for a SINGLE
  /// panel drag, only when the dragged board is genuinely unfed (and is not the
  /// machine-owned MEP board), only when the released card actually OVERLAPS
  /// another board's card, and only when the store's own
  /// [ElectricalProjectController.feederRefusalReason] says the feeder is legal.
  /// Any gate missed ⇒ today's plain move, silently.
  ///
  /// The drag already pushed its undo snapshot at [_beginPanelDrag], so the
  /// connect + the tidy reposition compose with `record: false` — move + connect
  /// is ONE undo step.
  void _tryBodyDropConnect(Map<String, Offset> moved) {
    if (moved.length != 1 || !mounted) return;
    final draggedId = moved.keys.first;
    if (draggedId == kMepEquipmentPanelId) return;
    final project = ref.read(electricalProjectProvider);
    final result = ref.read(electricalResultProvider);
    if (fedPanelIds(project).contains(draggedId)) return;
    final dragged = result.panels[draggedId];
    if (dragged == null) return;

    final lod = panelLodFor(_current.scale);
    // Below the micro boundary a card is a chip — too coarse a target for an
    // implicit topology edit, so the gesture is simply unavailable there.
    if (lod == PanelLod.micro) return;

    final positions = _positions(project, result);
    Rect worldRect(String id) {
      final p = result.panels[id]!;
      final at = positions[id] ?? Offset.zero;
      return Rect.fromLTWH(at.dx, at.dy, panelCardWidthLod(p, lod),
          panelFootprintLod(p, lod));
    }

    final draggedRect = worldRect(draggedId);
    String? targetId;
    for (final id in result.order) {
      if (id == draggedId || result.panels[id] == null) continue;
      if (!worldRect(id).overlaps(draggedRect)) continue;
      if (_ctrl.feederRefusalReason(id, draggedId) != null) continue;
      targetId = id;
      break;
    }
    if (targetId == null) return;

    _ctrl.connectFeeder(targetId, draggedId, record: false);
    final slot = _freeSlotRightOf(targetId, draggedId, positions, result);
    _ctrl.setPanelPosition(draggedId, slot.dx, slot.dy);
    final labels = _panelLabels(ref.read(electricalProjectProvider));
    ref.read(statusMessageProvider.notifier).showStatus(
          context.strings.format(StringKey.electricalFedFromTemplate, {
            'child': labels[draggedId] ?? 'Panel',
            'parent': labels[targetId] ?? 'panel',
          }),
        );
  }

  /// A tidy, grid-snapped world slot immediately to the RIGHT of [targetId] for
  /// a freshly-parented / freshly-created board, nudged DOWN past any sibling
  /// already sitting there so boards never land on top of each other.
  ///
  /// The column pitch uses the SCHEDULE footprint (the widest/tallest tier), so
  /// the slot is stable whatever zoom the gesture happened at — world positions
  /// must never depend on the LOD.
  Offset _freeSlotRightOf(
    String targetId,
    String? skipId,
    Map<String, Offset> positions,
    ElectricalSystemResult result,
  ) {
    final target = result.panels[targetId];
    final at = positions[targetId] ?? Offset.zero;
    final targetW = target == null
        ? kMinPanelWidth
        : panelCardWidthLod(target, PanelLod.schedule);
    final x = _snapGrid(at.dx + targetW + 60);
    var y = _snapGrid(at.dy);
    // The height to keep clear: the moving board's own (when it exists yet),
    // else a representative card.
    final moving = skipId == null ? null : result.panels[skipId];
    final ownH = moving == null
        ? 160.0
        : panelFootprintLod(moving, PanelLod.schedule);
    // Push down past anything already occupying the column.
    var guard = 0;
    bool clashes(double candidateY) {
      for (final entry in positions.entries) {
        if (entry.key == targetId || entry.key == skipId) continue;
        final p = result.panels[entry.key];
        if (p == null) continue;
        final r = Rect.fromLTWH(
          entry.value.dx,
          entry.value.dy,
          panelCardWidthLod(p, PanelLod.schedule),
          panelFootprintLod(p, PanelLod.schedule),
        );
        if (r.overlaps(Rect.fromLTWH(x, candidateY, targetW, ownH))) return true;
      }
      return false;
    }

    while (clashes(y) && guard++ < 64) {
      y = _snapGrid(y + ownH + 40);
    }
    return Offset(x, y);
  }

  /// id → the board's human designation (tag, else name) for status copy.
  Map<String, String> _panelLabels(ElectricalProject project) => {
        for (final p in project.panels) p.id: p.tag ?? p.name,
      };

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

  /// Panels some way actually feeds (recomputed each build) — see [fedPanelIds].
  Set<String> _fedPanels = const {};

  ViewportTransform get _current =>
      _transform ?? const ViewportTransform(scale: 0.8);

  void _setTransform(ViewportTransform next) {
    if (next == _transform) return;
    setState(() => _transform = next);
  }

  // ── Layout ─────────────────────────────────────────────────────────────────

  /// Resolve each panel's world position: saved `x,y` wins, else the
  /// deterministic tidy-tree auto-layout. Delegates to the shared
  /// [resolvePanelPositions] (so the minimap tracks the same dragged positions).
  Map<String, Offset> _positions(
    ElectricalProject project,
    ElectricalSystemResult result,
  ) =>
      resolvePanelPositions(project, result);

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
      return;
    }
    // D2: a primary-button drag on BLANK canvas starts a marquee (a panel body /
    // feeder drag owns its own gesture, so a hit on a panel leaves the drag to
    // pan / move it). Middle-drag still pans; pinch still zooms.
    if (event.buttons & kPrimaryButton != 0) {
      // A feeder drag already owns the pointer — arming a marquee under it made
      // the release both connect a feeder AND rubber-band-select whatever the
      // band swept (the two gestures raced).
      if (_feederFrom != null) return;
      final project = ref.read(electricalProjectProvider);
      final result = ref.read(electricalResultProvider);
      final positions = _positions(project, result);
      // The outlet band (and the dot half that overhangs the card edge) belongs
      // to the feeder gesture, so a down there must never arm a marquee — even
      // where it falls outside the card rect [_panelAt] tests.
      if (_outletBandAt(event.localPosition, positions, result.panels) != null) {
        return;
      }
      if (_panelAt(event.localPosition, positions, result.panels) == null) {
        _marqueeStart = event.localPosition;
        _marqueeCurrent = event.localPosition;
      }
    }
  }

  /// Which panel's OUTLET BAND (if any) contains the screen point [local] —
  /// the right-edge grab strip, widened outward by the half-dot that visually
  /// overhangs the card edge. Shares the exact positions/footprint geometry the
  /// cards are laid out with, so the guard can't drift from the widget.
  /// Null at the micro LOD (no outlet handle is mounted there).
  String? _outletBandAt(
    Offset local,
    Map<String, Offset> positions,
    Map<String, ElectricalPanelResult> panels,
  ) {
    final vt = _current;
    final lod = panelLodFor(vt.scale);
    if (lod == PanelLod.micro) return null;
    for (final entry in positions.entries) {
      final panel = panels[entry.key];
      if (panel == null) continue;
      final w = panelCardWidthLod(panel, lod);
      final h = panelFootprintLod(panel, lod);
      final band = outletBandWidth(w, vt.scale);
      final tl = vt.worldToScreen(entry.value);
      final rect = Rect.fromLTWH(
        tl.dx + (w - band) * vt.scale,
        tl.dy,
        (band + kOutletDotOverhang) * vt.scale,
        h * vt.scale,
      );
      if (rect.contains(local)) return entry.key;
    }
    return null;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_panning) {
      _setTransform(_current.panned(event.localPosition - _lastPanPoint));
      _lastPanPoint = event.localPosition;
      return;
    }
    if (_marqueeStart != null) {
      setState(() => _marqueeCurrent = event.localPosition);
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    _panning = false;
    final start = _marqueeStart;
    final current = _marqueeCurrent;
    if (start != null && current != null) {
      final rect = Rect.fromPoints(start, current);
      // A tiny box is a click (onTap clears); only a real drag marquee-selects.
      if (rect.width > 4 || rect.height > 4) _selectPanelsInRect(rect);
      setState(() {
        _marqueeStart = null;
        _marqueeCurrent = null;
      });
    }
  }

  /// D2: union of the panels whose screen footprint overlaps the marquee [rect]
  /// (shift-held extends the current selection, else replaces it).
  void _selectPanelsInRect(Rect rect) {
    final project = ref.read(electricalProjectProvider);
    final result = ref.read(electricalResultProvider);
    final positions = _positions(project, result);
    final vt = _current;
    final lod = panelLodFor(vt.scale);
    final hit = <String>{};
    positions.forEach((id, world) {
      final panel = result.panels[id];
      if (panel == null) return;
      final w = panelCardWidthLod(panel, lod);
      final h = panelFootprintLod(panel, lod);
      final tl = vt.worldToScreen(world);
      final r = Rect.fromLTWH(tl.dx, tl.dy, w * vt.scale, h * vt.scale);
      if (r.overlaps(rect)) hit.add(id);
    });
    final shift = HardwareKeyboard.instance.isShiftPressed;
    setState(() {
      _selection = null;
      _selectedPanels = shift ? {..._selectedPanels, ...hit} : hit;
    });
  }

  void _onScaleStart(ScaleStartDetails details) => _lastScale = 1.0;

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // D2: don't pan while a marquee is being drawn (the Listener drives it).
    if (_marqueeStart != null) return;
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
    // B4 — while the user is typing in a text field, every canvas shortcut
    // (Delete/Backspace on the selection, Ctrl+Z/Y, Esc) belongs to the field:
    // never let an editing keystroke mutate the drawing.
    if (isTextEntryFocused()) return KeyEventResult.ignored;
    final key = event.logicalKey;
    // Undo / redo route through the GLOBAL timeline (history_store), matching
    // the Layout canvas — so Ctrl+Z reverts the genuinely most-recent edit
    // across domains, never silently undoing another workspace's work.
    final mod = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (mod && key == LogicalKeyboardKey.keyZ && !shift) {
      ref.read(historyProvider.notifier).undo();
      return KeyEventResult.handled;
    }
    if (mod &&
        ((key == LogicalKeyboardKey.keyZ && shift) ||
            key == LogicalKeyboardKey.keyY)) {
      ref.read(historyProvider.notifier).redo();
      return KeyEventResult.handled;
    }
    // D2: arrow keys nudge the selected panel(s) by one grid step, one undo step.
    final isArrow = key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown;
    if (_selectedPanels.isNotEmpty && isArrow) {
      final dx = key == LogicalKeyboardKey.arrowLeft
          ? -kGrid.toDouble()
          : key == LogicalKeyboardKey.arrowRight
              ? kGrid.toDouble()
              : 0.0;
      final dy = key == LogicalKeyboardKey.arrowUp
          ? -kGrid.toDouble()
          : key == LogicalKeyboardKey.arrowDown
              ? kGrid.toDouble()
              : 0.0;
      final project = ref.read(electricalProjectProvider);
      final result = ref.read(electricalResultProvider);
      final positions = _positions(project, result);
      final targets = <String, Offset>{
        for (final id in _selectedPanels)
          if (positions[id] != null)
            id: Offset(
              _snapGrid(positions[id]!.dx + dx),
              _snapGrid(positions[id]!.dy + dy),
            ),
      };
      if (targets.isNotEmpty) _ctrl.movePanels(targets);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      // D2: a multi-panel selection deletes together (one undo step).
      if (_selectedPanels.isNotEmpty) {
        _ctrl.deletePanels(_selectedPanels);
        setState(() => _selectedPanels = const {});
        return KeyEventResult.handled;
      }
      final sel = _selection;
      if (sel != null) {
        if (sel.isCircuit) {
          _ctrl.deleteCircuit(sel.panelId, sel.circuitId!);
        } else {
          _ctrl.deletePanel(sel.panelId);
        }
        setState(() => _selection = null);
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_marqueeStart != null) {
        setState(() {
          _marqueeStart = null;
          _marqueeCurrent = null;
        });
        return KeyEventResult.handled;
      }
      if (_selection != null || _selectedPanels.isNotEmpty) {
        _clearSelection();
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
      _feederHoverRefused = false;
      _feederHoverReparent = false;
      // Defensive: the pointer-down guard already declines to arm a marquee
      // over the outlet band, but a marquee started a frame earlier (or from a
      // host that re-dispatches) must not survive into the feeder gesture.
      _marqueeStart = null;
      _marqueeCurrent = null;
    });
  }

  void _onFeederDragUpdate(
    Offset globalPos,
    Map<String, Offset> positions,
    Map<String, ElectricalPanelResult> panels,
  ) {
    final box = context.findRenderObject() as RenderBox?;
    final local = box?.globalToLocal(globalPos) ?? globalPos;
    final hover = _panelAt(local, positions, panels, exclude: _feederFrom);
    // Resolve the verdict once per hover CHANGE — the painter must never run a
    // topology query per frame.
    var refused = _feederHoverRefused;
    var reparent = _feederHoverReparent;
    if (hover != _feederHoverPanel) {
      final from = _feederFrom;
      refused = hover != null &&
          from != null &&
          _ctrl.feederRefusalReason(from, hover) != null;
      reparent = hover != null &&
          fedPanelIds(ref.read(electricalProjectProvider)).contains(hover);
    }
    setState(() {
      _feederCursor = local;
      _feederHoverPanel = hover;
      _feederHoverRefused = refused;
      _feederHoverReparent = reparent;
    });
  }

  void _onFeederDragEnd() {
    final from = _feederFrom;
    final to = _feederHoverPanel;
    if (from != null && to != null && from != to) {
      // Read the designations BEFORE the commit — the connect appends a way but
      // never renames a board, so either side is equivalent; taking them first
      // keeps the copy honest even if the target vanished mid-drag.
      final labels = _panelLabels(ref.read(electricalProjectProvider));
      final res = _ctrl.connectFeeder(from, to);
      if (mounted) {
        final status = ref.read(statusMessageProvider.notifier);
        if (!res.connected) {
          // Route refusals through the shared status pill (status bar) like the
          // rest of the app — one feedback primitive, no bespoke per-canvas
          // toast.
          if (res.reason != null) status.showStatus(res.reason!);
        } else {
          final child = labels[to] ?? 'Panel';
          final parent = labels[from] ?? 'panel';
          final was = res.reparentedFromLabel;
          status.showStatus(was == null
              ? '$child fed from $parent'
              : '$child re-fed from $parent (was $was)');
        }
      }
    }
    setState(() {
      _feederFrom = null;
      _feederHoverPanel = null;
      _feederHoverRefused = false;
      _feederHoverReparent = false;
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
    final lod = panelLodFor(vt.scale);
    for (final entry in positions.entries) {
      if (entry.key == exclude) continue;
      final panel = panels[entry.key];
      if (panel == null) continue;
      final w = panelCardWidthLod(panel, lod);
      final h = panelFootprintLod(panel, lod);
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
    // H3: the same per-panel breaking-capacity (Icu, kA) map the PDF/DXF export
    // threads into the board schedule, so the live canvas + the exported sheet
    // agree (the export builds the sheet with this map; the canvas previously
    // called buildElectricalPanelDetail with none, leaving every on-screen kA
    // suffix blank).
    final icuKaByPanel = breakerIcuKaByPanel(ref);
    final positions = _positions(project, result);
    final rootId = serviceRootId(project, result);
    // ESSENTIAL (genset-backed / emergency) boards — propagated down the
    // emergency sub-tree — drive the red border + feeder colour, the riser
    // convention folded in from the removed Overview tab.
    _essential = essentialPanelIds(project, result);
    // The honest "is this board connected?" set — every panel some way actually
    // feeds (never the target's own back-pointer, which a desynced project can
    // contradict). Drives the fed / not-connected badge.
    _fedPanels = fedPanelIds(project);

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
          onTap: _clearSelection,
          child: LayoutBuilder(
            builder: (context, constraints) {
              _viewportSize = constraints.biggest;
              _ensureInitialTransform(positions);
              final vt = _current;
              // Compute LOD from the RESOLVED viewport (after the initial fit),
              // so the board schedule tracks the real zoom from the first frame.
              // THREE bands (see the library doc): the micro chip below
              // [kMicroThreshold], the summary card up to [kLodThreshold], the
              // real engine board schedule at/above it (the way rows ARE the
              // loads, feeders branch right to sub-panels).
              final lod = panelLodFor(vt.scale);
              // Publish the live viewport for the minimap (I8). Deferred to after
              // the frame — the minimap's ValueListenableBuilder is a SIBLING (not
              // a descendant of this LayoutBuilder), so notifying it mid-build
              // would markNeedsBuild during build; a post-frame set is safe, and
              // record equality means an unchanged view never notifies.
              final vpNotifier = widget.viewport;
              if (vpNotifier != null) {
                final nextVp = (transform: vt, size: _viewportSize);
                if (vpNotifier.value != nextVp) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) vpNotifier.value = nextVp;
                  });
                }
              }
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
                          lod: lod,
                          gridLine: colors.gridLine,
                          background: colors.canvas,
                          feederFrom: _feederFrom,
                          feederCursor: _feederCursor,
                          feederHover: _feederHoverPanel,
                          feederHoverRefused: _feederHoverRefused,
                          feederHoverReparent: _feederHoverReparent,
                          accent: colors.accent,
                          onAccent: colors.onAccent,
                          essential: _essential,
                          essentialColor: colors.danger,
                          dangerColor: colors.danger,
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
                        nextPanelOrdinal: nextSubPanelOrdinal(project.panels),
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
                        lod,
                        project,
                        result,
                        rootId,
                        positions,
                        result.panels,
                        icuKaByPanel,
                      ),
                    // D2: the marquee rectangle (empty-canvas left-drag), same
                    // translucent-accent visual language as the mechanical
                    // canvas's rubber-band. Ignores pointers so it never eats
                    // the drag it is tracking.
                    if (_marqueeStart != null && _marqueeCurrent != null)
                      Positioned.fromRect(
                        rect: Rect.fromPoints(_marqueeStart!, _marqueeCurrent!),
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.accent.withAlpha(28),
                              border: Border.all(color: colors.accent),
                            ),
                          ),
                        ),
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

  /// The card footprint at the current LOD (full schedule when zoomed in, the
  /// compact summary band in the middle, the micro chip when zoomed far out) —
  /// so loads sit a fixed gap below the ACTUAL card height, not a reserved band
  /// of empty space.
  double cardFootprint(ElectricalPanelResult panel) =>
      panelFootprintLod(panel, panelLodFor(currentScale));

  /// Build the panel card + its PLN head (root only). Below [kMicroThreshold]
  /// the card is a micro chip; below [kLodThreshold] a summary + a merged
  /// "N loads" node; at/above it the card is the engine board schedule (the way
  /// rows ARE the loads).
  List<Widget> _panelWidgets(
    ElectricalPanelResult panel,
    Offset world,
    ViewportTransform vt,
    PanelLod lod,
    ElectricalProject project,
    ElectricalSystemResult result,
    String? rootId,
    Map<String, Offset> positions,
    Map<String, ElectricalPanelResult> panels,
    Map<String, double> icuKaByPanel,
  ) {
    final scale = vt.scale;
    final tl = vt.worldToScreen(world);
    final w = panelCardWidthLod(panel, lod);
    final cardH = panelFootprintLod(panel, lod);
    final modelPanel = project.panels
        .where((p) => p.id == panel.panelId)
        .firstOrNull;
    final isRoot = panel.panelId == rootId;
    // Honest connectivity: a board is fed when some way FEEDS it, not when its
    // own back-pointer says so (see [fedPanelIds]).
    final fed = _fedPanels.contains(panel.panelId);
    final unfed = !isRoot && !fed;

    final widgets = <Widget>[];

    // To the LEFT of the service-root board: the SOURCE CHAIN drawn as real
    // single-line SYMBOLS, flowing left-to-right INTO the root board (matching
    // the canvas's left-to-right flow). A DECLARED MV service (explicit
    // transformer kVA / dual-tx) draws PLN -> MVMDP -> TRAFO -> LVMDP; an LV
    // direct service draws only the honest supply head (+ genset / capacitor /
    // solar / battery / earth). A bare project shows the PLN grid head
    // (byte-identical). Double-click either to open the Sources / Service
    // editor.
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
              // The supply chain is the project's SUPPLY NODE — one tap opens
              // its editor (source kind / capacity / genset / solar /
              // battery), the same surface the toolbar Sources button opens.
              onTap: widget.onRequestSources,
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
              // One tap = the supply node's editor (add a genset / solar /
              // battery, set the source kind + capacity); double-tap keeps
              // the historic Service & Earthing shortcut.
              onTap: widget.onRequestSources,
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

    // The panel card.
    widgets.add(
      Positioned(
        left: tl.dx,
        top: tl.dy,
        width: w * scale,
        height: cardH * scale,
        child: _PanelDraggable(
          // D2: route the body drag through the state so a grabbed panel that is
          // part of a multi-selection moves the WHOLE selection in one undo step.
          onDragStart: () => _beginPanelDrag(panel.panelId, positions),
          onDragUpdate: (screenDelta) => _updatePanelDrag(screenDelta / scale),
          onDragEnd: _endPanelDrag,
          child: _ScaledChild(
            scale: scale,
            width: w,
            height: cardH,
            child: _PanelCardNode(
              panel: panel,
              lod: lod,
              scale: scale,
              cardWidth: w,
              project: project,
              result: result,
              breakerIcuKaByPanelId: icuKaByPanel,
              selected: _selectedPanels.contains(panel.panelId),
              selectedCircuitId:
                  (_selection?.isCircuit ?? false) &&
                          _selection!.panelId == panel.panelId
                      ? _selection!.circuitId
                      : null,
              unfed: unfed,
              essential: _essential.contains(panel.panelId),
              upsBacked: modelPanel?.upsBacked ?? false,
              submeter: modelPanel?.submeter ?? false,
              // The MEP Equipment board is machine-owned (auto-synced from the
              // plan). Badge it + reject palette drops (a dropped way would be
              // wiped on the next plan change) — G2.
              autoOwned: panel.panelId == kMepEquipmentPanelId,
              onTap: () => _selectPanel(panel.panelId),
              onDoubleTap: () => widget.onEditPanel(panel.panelId),
              onMenu: (gp) => widget.onPanelMenu(panel.panelId, gp),
              // Summary card → expand chevron frames the board schedule (I7).
              onExpandSchedule: () => focusPanelSchedule(panel.panelId),
              // A way row → select it (ring / row highlight, Delete removes);
              // the header band selects the whole board; nothing collapses on a
              // stray tap (collapse is zoom-out only — G6).
              onSelectWay: (cid) => _selectCircuit(panel.panelId, cid),
              onWayDoubleTap: (cid) => widget.onEditCircuit(panel.panelId, cid),
              onWayMenu: (cid, gp) =>
                  widget.onCircuitMenu(panel.panelId, cid, gp),
              onDropLoad: (load) => _dropLoadOnPanel(panel, load, positions),
              onOutletDragStart: (gp) => _onFeederDragStart(panel.panelId, gp),
              onOutletDragUpdate: (gp) =>
                  _onFeederDragUpdate(gp, positions, panels),
              onOutletDragEnd: _onFeederDragEnd,
            ),
          ),
        ),
      ),
    );

    // Loads beside the panel. In the SUMMARY band they MERGE into one compact
    // node so the panel reads as a tidy block instead of fanning every load out
    // beside it; they break out into the schedule's way rows when zoomed in. At
    // the MICRO tier the node is dropped entirely (its "N loads" caption is
    // unreadable there, and the chip is the whole point of that band).
    // Double-tap the merged node to zoom in + expand.
    if (lod == PanelLod.summary) {
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
        widgets.add(
          Positioned(
            left: mp.dx,
            top: mp.dy,
            width: kLoadW * scale,
            height: kLoadNodeH * scale,
            child: _ScaledTap(
              onTap: _clearSelection,
              // D9: this used to zoom to the bare kLodThreshold tier-crossing
              // minimum (0.78) — far short of the schedule's "comfortable
              // reading" scale the chevron gesture (focusPanelSchedule) frames.
              // Converge both "reveal panel detail" gestures on the SAME
              // framing so a double-tap here lands exactly where the summary
              // card's expand chevron would.
              onDoubleTap: () => focusPanelSchedule(panel.panelId),
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
    }
    // At the board-schedule LOD (detail) the way rows ARE the loads — no
    // separate hanging load nodes (the old mid-detail tier was removed, I7).
    return widgets;
  }

  /// A palette card dropped ON a panel card.
  ///
  /// Two outcomes, and both now REPORT WHAT THEY SIZED instead of silently
  /// mutating the board:
  ///  • a FEEDER / template card mints a real fed SUB-PANEL beside the parent
  ///    (`addFedPanelAt`, one undo step, template applied) — it used to be
  ///    downgraded to a plain "general" way, which quietly threw away the whole
  ///    point of dragging a sub-panel onto a board;
  ///  • any other card adds a way and toasts the sizing the engine just
  ///    produced for it (breaker · cable · Vd), read back from the freshly
  ///    recomputed result so the number is the real one, not a guess.
  void _dropLoadOnPanel(
    ElectricalPanelResult panel,
    PaletteLoad load,
    Map<String, Offset> positions,
  ) {
    // Reject a drop onto the machine-owned MEP board — it is rebuilt from the
    // plan, so a hand-added way would silently vanish (G2).
    if (panel.panelId == kMepEquipmentPanelId) {
      ref.read(statusMessageProvider.notifier).showStatus(
            context.strings(StringKey.electricalMepEquipmentHint),
          );
      return;
    }
    final status = ref.read(statusMessageProvider.notifier);
    final parentLabel = panel.tag ?? panel.name;

    if (load.kind == LoadKind.feeder) {
      final result = ref.read(electricalResultProvider);
      final slot = _freeSlotRightOf(panel.panelId, null, positions, result);
      final newId = _ctrl.addFedPanelAt(
        fromPanelId: panel.panelId,
        x: slot.dx,
        y: slot.dy,
        phases: load.phases,
        templateId: load.panelTemplateId,
      );
      final fresh = ref.read(electricalProjectProvider);
      final added = fresh.panels.where((p) => p.id == newId).firstOrNull;
      final name = added == null ? 'Sub-panel' : (added.tag ?? added.name);
      final ways = added?.circuits.length ?? 0;
      if (ways > 0) {
        status.showStatus(context.strings.format(
          StringKey.electricalFedFromWaysTemplate,
          {
            'name': name,
            'parentLabel': parentLabel,
            'ways': ways.toString(),
          },
        ));
      } else {
        status.showStatus(context.strings.format(
          StringKey.electricalFedFromTemplate,
          {
            'child': name,
            'parent': parentLabel,
          },
        ));
      }
      return;
    }

    final circuitId = _ctrl.addCircuit(
      panel.panelId,
      kind: load.kind,
      phases: load.phases,
      loadW: load.loadW > 0 ? load.loadW : null,
      motorKw: load.motorKw,
    );
    // The result provider recomputes synchronously, so the way is already sized.
    final sized = ref
        .read(electricalResultProvider)
        .panels[panel.panelId]
        ?.circuits
        .where((c) => c.circuitId == circuitId)
        .firstOrNull;
    if (sized == null) return;
    final poles = sized.threePhase ? 3 : 1;
    status.showStatus(context.strings.format(
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
  ///
  /// B9: the "comfortable reading" scale is a FIXED [kBoardScheduleThreshold]
  /// `+ 0.3`, but the schedule card is [panelCardWidthAt] world units wide — at
  /// common laptop widths (once the nav rail + inspector are subtracted) that
  /// fixed scale needs more horizontal room than the canvas actually has, and
  /// the schedule clips at both edges (its GRUP column, name, incomer line and
  /// TOTAL footer all fall off-screen; golden 11 shipped this). Clamp the
  /// scale to whatever actually fits the viewport width (94%, leaving a slim
  /// margin), floored at [kLodThreshold] so the schedule LOD itself never
  /// drops back to the summary card even on a narrow canvas.
  void focusPanelSchedule(String panelId, {double? scale}) {
    final project = ref.read(electricalProjectProvider);
    final result = ref.read(electricalResultProvider);
    final pos = _positions(project, result)[panelId];
    final panel = result.panels[panelId];
    if (pos == null || panel == null || _viewportSize.isEmpty) return;
    final w = panelCardWidthAt(panel, true);
    final h = panelFootprint(panel, true);
    final desired = scale ?? (kBoardScheduleThreshold + 0.3);
    final fitWidthScale = _viewportSize.width * 0.94 / w;
    final s = math.max(kLodThreshold, math.min(desired, fitWidthScale));
    final worldCentre = Offset(pos.dx + w / 2, pos.dy + h / 2);
    _setTransform(ViewportTransform(
      scale: s,
      offset: _viewportSize.center(Offset.zero) - worldCentre * s,
    ));
  }

  /// Frame [panelId]'s board schedule AND select the offending element — the G5
  /// Issues-drawer "locate" action. A non-null [circuitId] rings that way's
  /// schedule row (Delete then removes it); a null [circuitId] selects the whole
  /// board. Framing no-ops when the panel / viewport isn't ready yet, but the
  /// selection is still applied so a subsequent frame lands on it.
  void focusIssue(String panelId, {String? circuitId}) {
    focusPanelSchedule(panelId);
    setState(() {
      if (circuitId == null) {
        // A whole-board locate rings the panel (D2: panel selection is the
        // multi-select set, not the way [_selection]).
        _selection = null;
        _selectedPanels = {panelId};
      } else {
        _selection = _CanvasSelection.circuit(panelId, circuitId);
        _selectedPanels = const {};
      }
    });
  }

  /// Zoom back OUT to the summary card for [panelId] (I7) — frame it just below
  /// [kLodThreshold], the collapse counterpart of [focusPanelSchedule]. No-op if
  /// the panel / viewport isn't ready.
  void collapseToSummary(String panelId) {
    final project = ref.read(electricalProjectProvider);
    final result = ref.read(electricalResultProvider);
    final pos = _positions(project, result)[panelId];
    final panel = result.panels[panelId];
    if (pos == null || panel == null || _viewportSize.isEmpty) return;
    // Below the schedule boundary but comfortably ABOVE the micro one, so the
    // collapse lands on the summary card — never on the micro chip.
    const s = kLodThreshold - 0.12;
    assert(s > kMicroThreshold && s < kLodThreshold,
        'collapseToSummary must land inside the SUMMARY band');
    final w = panelCardWidthLod(panel, PanelLod.summary);
    final h = panelFootprintLod(panel, PanelLod.summary);
    final worldCentre = Offset(pos.dx + w / 2, pos.dy + h / 2);
    _setTransform(ViewportTransform(
      scale: s,
      offset: _viewportSize.center(Offset.zero) - worldCentre * s,
    ));
  }

  /// Pan (keeping the current zoom) so [world] lands at the viewport centre —
  /// the minimap tap-to-navigate target (I8). No-op before the first layout.
  void centreOn(Offset world) {
    if (_viewportSize.isEmpty) return;
    final s = _current.scale;
    _setTransform(ViewportTransform(
      scale: s,
      offset: _viewportSize.center(Offset.zero) - world * s,
    ));
  }

  ViewportTransform get transform => _current;

  /// D2: the current multi-selected panels (test-only observation hook).
  @visibleForTesting
  Set<String> get selectedPanelIds => _selectedPanels;
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

  /// The active detail band (micro / summary / schedule) — every card rect the
  /// painter derives (feeder endpoints, the merged-node connector, the hover
  /// ring) reads its geometry from this, so the wiring lands on the card the
  /// user is actually looking at.
  final PanelLod lod;
  final Color gridLine;
  final Color background;
  final String? feederFrom;
  final Offset feederCursor;
  final String? feederHover;

  /// Verdict for [feederHover], resolved by the host on each hover CHANGE from
  /// the store's own refusal rule (never recomputed per frame).
  final bool feederHoverRefused;

  /// True when dropping on [feederHover] would RE-PARENT an already-fed board.
  final bool feederHoverReparent;
  final Color accent;
  final Color onAccent;
  final Set<String> essential;
  final Color essentialColor;

  /// Refusal tint for the hover ring (a would-be-illegal feeder target).
  final Color dangerColor;

  _CanvasPainter({
    required this.project,
    required this.result,
    required this.positions,
    required this.transform,
    required this.rootId,
    required this.lod,
    required this.gridLine,
    required this.background,
    required this.feederFrom,
    required this.feederCursor,
    required this.feederHover,
    required this.feederHoverRefused,
    required this.feederHoverReparent,
    required this.accent,
    required this.onAccent,
    required this.essential,
    required this.essentialColor,
    required this.dangerColor,
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
        final fromCardH = panelFootprintLod(fromPanel, lod);
        final fromW = panelCardWidthLod(fromPanel, lod);
        final start = transform.worldToScreen(
          Offset(fromPos.dx + fromW, fromPos.dy + fromCardH / 2),
        );
        final toPanel = result.panels[fed];
        final toH =
            toPanel == null ? 160.0 : panelFootprintLod(toPanel, lod);
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
          // Clear the parent's outlet handle (which sits ~13 px past the right
          // edge, scaled with the card) so the label never overlaps the dot.
          _label(canvas, Offset(midX, start.dy - 7), label, transform.scale,
              color: isEss ? essentialColor : onAccent,
              minLeftX: start.dx + 26 * transform.scale);
        }
      }
    }

    // The connector from each summary card's right edge to its merged "N loads"
    // node. ONLY in the summary band — the schedule lists every way itself (so
    // the connector would be redundant), and the micro tier carries no merged
    // node at all (so the connector would point at nothing).
    if (lod == PanelLod.summary) {
      for (final id in result.order) {
        final panel = result.panels[id];
        final pos = positions[id];
        if (panel == null || pos == null) continue;
        _loadDrops(canvas, panel, pos);
      }
    }

    // In-flight feeder rubber-band.
    if (feederFrom != null) {
      // The hover TARGET ring — the drop verdict, shown on the board itself
      // rather than left for the user to discover on release. Accent = this
      // connect is legal; danger = the store would refuse it (self-feed /
      // loop). Same rounded translucent language as the marquee.
      _paintHoverRing(canvas);
      final fromPos = positions[feederFrom];
      final fromPanel = result.panels[feederFrom];
      if (fromPos != null && fromPanel != null) {
        final w = panelCardWidthLod(fromPanel, lod);
        final h = panelFootprintLod(fromPanel, lod);
        final anchor = transform.worldToScreen(
          Offset(fromPos.dx + w, fromPos.dy + h / 2),
        );
        final bandColour = feederHover != null && feederHoverRefused
            ? dangerColor
            : accent;
        canvas.drawLine(
          anchor,
          feederCursor,
          Paint()
            ..color = bandColour
            ..strokeWidth = 2.5
            ..strokeCap = StrokeCap.round,
        );
        canvas.drawCircle(feederCursor, 5, Paint()..color = bandColour);
      }
      // Dropping on an already-fed board MOVES it under the new parent — say so
      // before the release, not after.
      if (feederHover != null && !feederHoverRefused && feederHoverReparent) {
        _label(canvas, feederCursor + const Offset(0, -18), 're-feed',
            transform.scale, color: onAccent);
      }
    }
  }

  /// The rounded ring + translucent wash over the panel the feeder drag is
  /// hovering, tinted by the pre-resolved [feederHoverRefused] verdict.
  void _paintHoverRing(Canvas canvas) {
    final id = feederHover;
    if (id == null) return;
    final panel = result.panels[id];
    final pos = positions[id];
    if (panel == null || pos == null) return;
    final tl = transform.worldToScreen(pos);
    final rect = Rect.fromLTWH(
      tl.dx,
      tl.dy,
      panelCardWidthLod(panel, lod) * transform.scale,
      panelFootprintLod(panel, lod) * transform.scale,
    );
    final colour = feederHoverRefused ? dangerColor : accent;
    final rr = RRect.fromRectAndRadius(
      rect.inflate(2),
      Radius.circular(8 * transform.scale),
    );
    canvas.drawRRect(rr, Paint()..color = colour.withAlpha(28));
    canvas.drawRRect(
      rr,
      Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
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
    // Anchors within ONE GRID CELL of each other are treated as aligned: the
    // two mid-height anchors of different-height cards often sit a few px
    // apart, and the mid-channel jog that would join them reads as a rendering
    // glitch, not routing (user-reported). Snap to the parent's row so the run
    // stays glued to the visible outlet grip; a genuine row difference (more
    // than a grid cell) keeps the orthogonal channel below.
    if ((a.dy - b.dy).abs() <= kGrid * transform.scale) {
      final landing = Offset(b.dx, a.dy);
      canvas.drawPath(
        Path()
          ..moveTo(a.dx, a.dy)
          ..lineTo(landing.dx, landing.dy),
        paint,
      );
      canvas.drawCircle(landing, 3, Paint()..color = col);
      return;
    }
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

  /// The single connector from a SUMMARY card's right edge to its merged
  /// "N loads" node (only called in the summary view — the board-schedule LOD
  /// lists every way itself, so per-way stems would be redundant).
  void _loadDrops(Canvas canvas, ElectricalPanelResult panel, Offset world) {
    final s = transform.scale;
    final cardH = panelFootprintLod(panel, PanelLod.summary);
    final w = panelCardWidthLod(panel, PanelLod.summary);
    final rightEdge = world.dx + w;
    final loadLeft = world.dx + w + kLoadGapX;
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
  }

  void _label(Canvas canvas, Offset center, String text, double s,
      {Color? color, double? minLeftX}) {
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
    // Keep the pill's LEFT edge clear of [minLeftX] (e.g. a panel's outlet
    // handle), shifting the whole label right so it never overlaps it.
    final halfW = (tp.width + 8 * s) / 2;
    var cx = center.dx;
    if (minLeftX != null && cx - halfW < minLeftX) cx = minLeftX + halfW;
    final at = Offset(cx, center.dy);
    final rect = Rect.fromCenter(
      center: at,
      width: tp.width + 8 * s,
      height: tp.height + 4 * s,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(3 * s)),
      Paint()..color = const Color(0xD915171B),
    );
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_CanvasPainter old) =>
      old.project != project ||
      old.result != result ||
      old.transform != transform ||
      old.lod != lod ||
      old.feederFrom != feederFrom ||
      old.feederCursor != feederCursor ||
      // feederHover (+ its two pre-resolved verdict flags) now genuinely PAINT
      // — the hover ring / band tint / re-feed pill — so they belong here.
      old.feederHover != feederHover ||
      old.feederHoverRefused != feederHoverRefused ||
      old.feederHoverReparent != feederHoverReparent ||
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

/// The in-card board-schedule surface: paints the real engine board
/// schedule (`buildElectricalPanelDetail` — the SAME geometry the PDF / DXF
/// export draws) fitted into the card body via [SldBoardSchedulePainter], and
/// maps a double-click / right-click to the way under the local y (the engine
/// lays one schedule ROW per circuit, so a local-y → row-index hit-test reaches
/// the same `onWayDoubleTap` / `onWayMenu` as the mid-detail schematic).
class _PanelScheduleBody extends StatefulWidget {
  final ElectricalPanelResult panel;
  final ElectricalProject project;
  final ElectricalSystemResult result;

  /// The per-panel breaking-capacity (Icu, kA) map (H3) — see the matching
  /// field doc on [_PanelCardNode].
  final Map<String, double>? breakerIcuKaByPanelId;
  final ValueChanged<String> onWayDoubleTap;
  final void Function(String, Offset) onWayMenu;

  /// A single tap on a real way ROW selects that circuit (ring / row highlight,
  /// Delete removes it — I5); a tap in the HEADER band selects the whole board
  /// ([onSelectPanel] — G6, the only way to select a panel at the detail LOD,
  /// whose card chrome is dropped); a tap on a reserved CADANGAN spare row / the
  /// TOTAL footer / empty chrome is a NO-OP (no surprise camera collapse — G6).
  final ValueChanged<String> onSelectWay;
  final VoidCallback onSelectPanel;

  /// The currently-selected circuit id (drives the row selection band).
  final String? selectedCircuitId;

  const _PanelScheduleBody({
    required this.panel,
    required this.project,
    required this.result,
    required this.breakerIcuKaByPanelId,
    required this.onWayDoubleTap,
    required this.onWayMenu,
    required this.onSelectWay,
    required this.onSelectPanel,
    required this.selectedCircuitId,
  });

  @override
  State<_PanelScheduleBody> createState() => _PanelScheduleBodyState();
}

class _PanelScheduleBodyState extends State<_PanelScheduleBody> {
  /// The way ROW index the pointer is over (null = none) — drives the highlight.
  int? _hoveredRow;

  /// The board-schedule sheet for this one panel, re-origined to (0,0).
  SldSheet get _sheet => buildElectricalPanelDetail(
        project: widget.project,
        result: widget.result,
        panelId: widget.panel.panelId,
        breakerIcuKaByPanelId: widget.breakerIcuKaByPanelId,
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

  /// The RAW schedule row index under the body-local point — negative for the
  /// HEADER band (name / tag / incomer line, above the first way row), 0 …
  /// circuits.length-1 for the real ways, and >= circuits.length for the
  /// reserved CADANGAN spare rows / the TOTAL footer. Shared row geometry
  /// (`scheduleRowTop`) so it agrees with the painter's highlight.
  int _rawRowAt(Offset local, SldSheet sheet, Size size) {
    final t = _fitTransform(sheet, size);
    final world = t.screenToWorld(local);
    return ((world.dy - scheduleRowTop(0)) / kScheduleRowH).floor();
  }

  /// The way ROW index under the body-local point, or null (header / spare /
  /// footer / empty panel). Clamped to the REAL circuits so a tap on a reserved
  /// spare row never resolves to a way.
  int? _wayIndexAt(Offset local, SldSheet sheet, Size size) {
    if (widget.panel.circuits.isEmpty) return null;
    final i = _rawRowAt(local, sheet, size);
    if (i < 0 || i >= widget.panel.circuits.length) return null;
    return i;
  }

  String? _wayAt(Offset local, SldSheet sheet, Size size) {
    final i = _wayIndexAt(local, sheet, size);
    return i == null ? null : widget.panel.circuits[i].circuitId;
  }

  /// The row index of the selected circuit on this panel, or null.
  int? get _selectedRow {
    final id = widget.selectedCircuitId;
    if (id == null) return null;
    final i = widget.panel.circuits.indexWhere((c) => c.circuitId == id);
    return i < 0 ? null : i;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final sheet = _sheet;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        void updateHover(Offset local) {
          final i = _wayIndexAt(local, sheet, size);
          if (i != _hoveredRow) setState(() => _hoveredRow = i);
        }

        return MouseRegion(
          onHover: (e) => updateHover(e.localPosition),
          onExit: (_) {
            if (_hoveredRow != null) setState(() => _hoveredRow = null);
          },
          child: Listener(
            onPointerDown: (e) {
              if (e.buttons == kSecondaryButton) {
                final box = context.findRenderObject() as RenderBox?;
                final local = box?.globalToLocal(e.position) ?? Offset.zero;
                final id = _wayAt(local, sheet, size);
                if (id != null) widget.onWayMenu(id, e.position);
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // Predictable detail-LOD tap semantics (G6): a tap on a real way
              // ROW selects that circuit; a tap in the HEADER band selects the
              // whole board (the card's own header chrome is dropped at detail,
              // so this is the only way to select a panel here); a tap on a
              // reserved CADANGAN spare row / the TOTAL footer / empty chrome
              // does NOTHING — it no longer yanks the camera out to the summary
              // (collapse is via zoom-out only, never a stray tap).
              onTapUp: (d) {
                final i = _rawRowAt(d.localPosition, sheet, size);
                if (i < 0) {
                  widget.onSelectPanel();
                } else if (i < widget.panel.circuits.length) {
                  widget.onSelectWay(widget.panel.circuits[i].circuitId);
                }
              },
              onDoubleTapDown: (d) {
                final id = _wayAt(d.localPosition, sheet, size);
                if (id != null) widget.onWayDoubleTap(id);
              },
              onDoubleTap: () {},
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: SldBoardSchedulePainter(
                        sheet: sheet,
                        ink: colors.textPrimary,
                        essential: colors.danger,
                        hoveredRow: _hoveredRow,
                        highlight: colors.accent,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                  // The selection ring for the chosen way row (I5) — a stronger
                  // accent band than the hover highlight, drawn as a foreground
                  // overlay so the shared read-only schedule painter is untouched.
                  if (_selectedRow != null)
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _RowSelectionPainter(
                          transform: _fitTransform(sheet, size),
                          sheet: sheet,
                          row: _selectedRow!,
                          color: colors.accent,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Paints the selection ring for one board-schedule row (a stroked accent band
/// over the row), placed with the SAME fit transform + row geometry the
/// [SldBoardSchedulePainter] uses so it lands exactly on the selected way.
class _RowSelectionPainter extends CustomPainter {
  final ViewportTransform transform;
  final SldSheet sheet;
  final int row;
  final Color color;

  _RowSelectionPainter({
    required this.transform,
    required this.sheet,
    required this.row,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final top = scheduleRowTop(row);
    final tl = transform.worldToScreen(Offset(sheet.minX + 2, top));
    final w = (sheet.maxX - sheet.minX - 4) * transform.scale;
    final h = kScheduleRowH * transform.scale;
    final rect = Rect.fromLTWH(tl.dx, tl.dy, w, h);
    final r = Radius.circular(3 * transform.scale);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, r),
      Paint()..color = color.withAlpha(28),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, r),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_RowSelectionPainter old) =>
      old.transform != transform ||
      old.sheet != sheet ||
      old.row != row ||
      old.color != color;
}


// ════════════════════════════════════════════════════════════════════════════
// Panel card node (micro chip / summary card / board schedule).
// ════════════════════════════════════════════════════════════════════════════

class _PanelCardNode extends StatefulWidget {
  final ElectricalPanelResult panel;

  /// Which detail band to render: the micro chip, the summary card (header +
  /// stats), or the real engine board schedule.
  final PanelLod lod;

  /// The live canvas zoom. The card is laid out in WORLD px inside a
  /// [_ScaledChild], so anything that must keep a fixed SCREEN size (the outlet
  /// grab band) divides by this.
  final double scale;

  /// The card's world-px width at [lod] — the outlet band is capped against it.
  final double cardWidth;
  final ElectricalProject project;
  final ElectricalSystemResult result;

  /// The per-panel breaking-capacity (Icu, kA) map (H3) — the SAME map the
  /// PDF/DXF export threads into the board schedule, so the on-canvas detail
  /// schedule's kA suffix agrees with the exported sheet. Null/empty ⇒ no kA
  /// suffix (matches `buildElectricalPanelDetail`'s own null-safe fallback).
  final Map<String, double>? breakerIcuKaByPanelId;
  final bool selected;

  /// The selected WAY on this panel (its schedule row is ringed — I5), or null.
  final String? selectedCircuitId;
  final bool unfed;
  final bool essential;
  final bool upsBacked;
  final bool submeter;

  /// This board is machine-owned (the auto-synced MEP Equipment panel): it shows
  /// an "auto — from plan" badge and rejects palette drops (G2).
  final bool autoOwned;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final ValueChanged<Offset> onMenu;

  /// Summary card → the expand chevron frames the board schedule (I7).
  final VoidCallback onExpandSchedule;

  /// A schedule way row → select it (I5).
  final ValueChanged<String> onSelectWay;
  final ValueChanged<String> onWayDoubleTap;
  final void Function(String, Offset) onWayMenu;
  final ValueChanged<PaletteLoad> onDropLoad;
  final ValueChanged<Offset> onOutletDragStart;
  final ValueChanged<Offset> onOutletDragUpdate;
  final VoidCallback onOutletDragEnd;

  const _PanelCardNode({
    required this.panel,
    required this.lod,
    required this.scale,
    required this.cardWidth,
    required this.project,
    required this.result,
    required this.breakerIcuKaByPanelId,
    required this.selected,
    required this.selectedCircuitId,
    required this.unfed,
    required this.essential,
    required this.upsBacked,
    required this.submeter,
    required this.autoOwned,
    required this.onTap,
    required this.onDoubleTap,
    required this.onMenu,
    required this.onExpandSchedule,
    required this.onSelectWay,
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

    final micro = widget.lod == PanelLod.micro;
    final detail = widget.lod == PanelLod.schedule;

    // The card reserves the full band height for its LOD (see
    // [panelFootprintLod]), so the merged loads node sits a fixed distance to
    // its right regardless of zoom and the card never grows over it when the
    // tier changes.
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
          // Header chrome — a fixed band (kPanelChrome). Only in the SUMMARY
          // band: at the board-schedule LOD the engine schedule draws its OWN
          // header (name [tag] + incomer line) so the card chrome would just
          // repeat the panel name, and at MICRO the chip IS the identity.
          if (widget.lod == PanelLod.summary)
            SizedBox(
              height: kPanelChrome,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                child: _header(context),
              ),
            ),
          Expanded(
            // Cross-fade between the bodies across a tier boundary instead of
            // an instant swap — EXCEPT across the MICRO boundary, where the
            // switcher is re-keyed so the old body is discarded outright. A
            // cross-fade lays both bodies out in the SAME box, and the chip's
            // box (64 px tall) cannot hold the summary card's stats: the
            // outgoing card would spend the whole transition overflowing. A
            // tier that different swaps rather than fades.
            child: AnimatedSwitcher(
              key: ValueKey(micro),
              duration: MechXMotion.appear,
              switchInCurve: MechXMotion.standard,
              switchOutCurve: MechXMotion.standard,
              child: micro
                  ? KeyedSubtree(
                      key: const ValueKey('micro'),
                      child: _PanelMicroBody(
                        panel: panel,
                        onTap: widget.onTap,
                        onDoubleTap: widget.onDoubleTap,
                        onMenu: widget.onMenu,
                      ),
                    )
                  : detail
                      ? KeyedSubtree(
                          key: const ValueKey('schedule'),
                          child: _PanelScheduleBody(
                            panel: panel,
                            project: widget.project,
                            result: widget.result,
                            breakerIcuKaByPanelId: widget.breakerIcuKaByPanelId,
                            selectedCircuitId: widget.selectedCircuitId,
                            onSelectWay: widget.onSelectWay,
                            // Header-band tap selects the whole board — reuses
                            // the card's select intent (G6).
                            onSelectPanel: widget.onTap,
                            onWayDoubleTap: widget.onWayDoubleTap,
                            onWayMenu: widget.onWayMenu,
                          ),
                        )
                      : Padding(
                          key: const ValueKey('summary'),
                          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                          child: _PanelSummaryBody(
                            panel: panel,
                            modelPanel: _modelPanel,
                          ),
                        ),
            ),
          ),
        ],
      ),
    );

    return DragTarget<PaletteLoad>(
      onWillAcceptWithDetails: (_) {
        // Still accept the drop so the reject-toast fires (see onDropLoad), but
        // a machine-owned board shows NO will-accept highlight — the drop is a
        // no-op there (G2).
        if (!widget.autoOwned) setState(() => _dropHover = true);
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
          // Hover shows the border/shadow highlight only (the card decoration) —
          // NO scale/zoom animation (it read as the panel jumping at the user).
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(child: card),
              // The outlet GRAB BAND (drag → feeder) — the full-height strip
              // down the card's RIGHT edge, since the tree flows left-to-right
              // and feeders exit a panel's right side toward its sub-panels.
              //
              // The band is what you GRAB and it lies wholly INSIDE the card:
              // the old mount hung the 26-px dot half outside (`right: -13`),
              // and a RenderBox rejects a hit outside its own bounds, so half
              // the visible handle was dead — a drag started there fell through
              // to the canvas and armed a marquee instead. The dot still paints
              // half-out (through this Stack's `Clip.none`); only the hit area
              // moved. Not mounted at MICRO — a 26-screen-px band would be a
              // third of the chip, and there is nothing legible to aim at.
              if (!micro)
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: outletBandWidth(widget.cardWidth, widget.scale),
                  child: _OutletHandle(
                    onDragStart: widget.onOutletDragStart,
                    onDragUpdate: widget.onOutletDragUpdate,
                    onDragEnd: widget.onOutletDragEnd,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// This board's MODEL record (the editable inputs beside the solved result).
  ElectricalPanel? get _modelPanel => widget.project.panels
      .where((p) => p.id == widget.panel.panelId)
      .firstOrNull;

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
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
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
              // Trailing controls: the status badges + the expand-schedule
              // chevron. NON-FLEX, so the [Expanded] name stays greedy and the
              // cluster sits flush-right at its natural width — byte-identical to
              // a plain trailing Row when it fits. The [ConstrainedBox] caps it at
              // half the header width, so a NARROW summary card (the auto MEP
              // board's stacked badges on a single-way 280-px card) SCALES the
              // cluster down via the scale-down FittedBox instead of overflowing
              // the fixed card width; on a roomy card the natural width is under
              // the cap, so the FittedBox never scales and the layout is
              // unchanged (unlike a Flexible, which would pin the name to half and
              // let the cluster drift off the right edge).
              ConstrainedBox(
                constraints:
                    BoxConstraints(maxWidth: constraints.maxWidth * 0.5),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ..._badges(context),
                      // Explicit expand affordance (I7) — frames this board's
                      // schedule (the LOD flip was previously an invisible zoom
                      // threshold).
                      const SizedBox(width: MechXSpacing.xxs),
                      _ExpandChevron(onTap: widget.onExpandSchedule),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _badges(BuildContext context) {
    final colors = context.colors;
    final badges = <Widget>[];
    // The machine-owned MEP board leads with an explicit "auto — from plan" cue
    // so the engineer knows it is regenerated (and never hand-edits it) — G2.
    if (widget.autoOwned) {
      badges.add(
        _Badge(label: 'auto — from plan', color: colors.accent, subtle: true),
      );
    }
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
    // The engine's own phase-imbalance verdict, surfaced ON the board it applies
    // to instead of only in the Review list — an unbalanced 3-phase board is a
    // re-phasing job, and the card is where the engineer is looking. Driven by
    // the WARNING (not a hand-picked threshold), so the badge and the issue list
    // can never disagree about what counts as imbalanced.
    if (widget.panel.warnings.any((w) => w.code == 'phase-imbalance')) {
      badges.add(_Badge(
        label: 'imbalance ${widget.panel.imbalancePercent.round()}%',
        color: colors.warning,
      ));
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

  /// The board's MODEL record beside the solved result — the source of the
  /// PLACED count (a way is placed when it carries a `loadPos` on the plan).
  /// Null when the result outlives its model for a frame.
  final ElectricalPanel? modelPanel;

  const _PanelSummaryBody({required this.panel, this.modelPanel});

  @override
  Widget build(BuildContext context) {
    final spares = panel.circuits
        .where((c) => c.loadKind == LoadKind.spare)
        .length;
    // How much of this board is actually SET OUT on the plan — the ways whose
    // load carries a layout position size their cable off real geometry, the
    // rest off the unmeasured-stub default. A board reading "2/9 placed" is
    // telling the engineer seven of its printed lengths are still assumptions.
    final ways = modelPanel?.circuits ?? const <ElectricalCircuit>[];
    final placed = ways.where((c) => c.loadPos != null).length;
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
            // The sized busbar — the one incomer-side number the summary was
            // missing (it drives the enclosure and the copper order).
            _Stat(value: fmtBusbar(panel.busbar), label: 'bus'),
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
            if (ways.isNotEmpty)
              _Stat(value: '$placed/${ways.length}', label: 'placed'),
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

// ════════════════════════════════════════════════════════════════════════════
// Micro chip body — the far-zoomed-out tier.
// ════════════════════════════════════════════════════════════════════════════

/// The MICRO body: designation, connected kW, and a proportional R/S/T bar.
///
/// Three facts, chosen because they are the only ones that survive the zoom:
/// WHICH board this is, HOW BIG it is, and whether its phases are anywhere near
/// even. Everything the summary card adds (badges, the incomer/bus/ways stats,
/// the merged loads node, the outlet handle, the expand chevron) is dropped —
/// at this scale it is neither readable nor grabbable, and drawing an
/// ungrabbable handle would be a lie. Selection, tap-select and
/// double-click-to-edit still work, so the chip stays a real object.
class _PanelMicroBody extends StatelessWidget {
  final ElectricalPanelResult panel;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final ValueChanged<Offset> onMenu;

  const _PanelMicroBody({
    required this.panel,
    required this.onTap,
    required this.onDoubleTap,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Listener(
      onPointerDown: (e) {
        if (e.buttons == kSecondaryButton) onMenu(e.position);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                panel.tag ?? panel.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: type.label.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                fmtKw(panel.connectedW),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: type.caption.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: 5),
              SizedBox(
                height: 5,
                child: _MicroPhaseBar(
                  balance: panel.phaseBalance,
                  threePhase: panel.system == ElectricalSystem.threePhase,
                  singleColour: colors.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The micro chip's phase bar: three R/S/T segments whose WIDTHS are
/// proportional to the balanced line currents, so an unbalanced board is
/// visible as a lopsided bar at a zoom where no number is readable. All-zero
/// (an empty board) falls back to equal thirds rather than dividing by zero, and
/// a single-phase board draws ONE accent bar — it has no lines to compare.
class _MicroPhaseBar extends StatelessWidget {
  final PhaseBalanceResult balance;
  final bool threePhase;
  final Color singleColour;

  const _MicroPhaseBar({
    required this.balance,
    required this.threePhase,
    required this.singleColour,
  });

  @override
  Widget build(BuildContext context) {
    if (!threePhase) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: singleColour,
          borderRadius: const BorderRadius.all(Radius.circular(2)),
        ),
        child: const SizedBox.expand(),
      );
    }
    final total = balance.l1 + balance.l2 + balance.l3;
    final flex = total <= 0
        ? const [1, 1, 1]
        : [
            math.max(1, (balance.l1 / total * 100).round()),
            math.max(1, (balance.l2 / total * 100).round()),
            math.max(1, (balance.l3 / total * 100).round()),
          ];
    const colours = [kRailR, kRailS, kRailT];
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(2)),
      child: Row(
        children: [
          for (var i = 0; i < 3; i++)
            Expanded(
              flex: flex[i],
              child: ColoredBox(
                color: colours[i],
                child: const SizedBox.expand(),
              ),
            ),
        ],
      ),
    );
  }
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
// Expand chevron — the summary card's explicit "open the board schedule"
// affordance (I7), replacing the old invisible zoom threshold.
// ════════════════════════════════════════════════════════════════════════════

class _ExpandChevron extends StatelessWidget {
  final VoidCallback onTap;
  const _ExpandChevron({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: CustomPaint(
            size: const Size(12, 12),
            painter: _ExpandChevronGlyph(colors.textMuted),
          ),
        ),
      ),
    );
  }
}

/// Two chevrons pointing apart — a plain "expand / zoom in" glyph (ASCII-free,
/// so no tofu risk).
class _ExpandChevronGlyph extends CustomPainter {
  final Color color;
  const _ExpandChevronGlyph(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final w = size.width, h = size.height;
    // Top chevron pointing up.
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.28, h * 0.42)
        ..lineTo(w * 0.5, h * 0.2)
        ..lineTo(w * 0.72, h * 0.42),
      p,
    );
    // Bottom chevron pointing down.
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.28, h * 0.58)
        ..lineTo(w * 0.5, h * 0.8)
        ..lineTo(w * 0.72, h * 0.58),
      p,
    );
  }

  @override
  bool shouldRepaint(_ExpandChevronGlyph old) => old.color != color;
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
// Outlet handle — the right-edge grab BAND the user drags to create a feeder.
// ════════════════════════════════════════════════════════════════════════════

/// The feeder grab band: it FILLS the strip it is given (which the card sizes to
/// at least [kOutletBandScreenPx] on screen at any zoom, capped at a third of
/// the card), so the whole strip is grabbable and the whole strip is INSIDE the
/// card — no out-of-bounds half that a RenderBox silently rejects.
///
/// The visible dot is a separate, smaller affordance drawn centred on the card's
/// right EDGE (half of it overhanging, painted through the card Stack's
/// `Clip.none`) — the classic node-graph outlet look, without pretending the
/// grab target is only that dot.
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
        child: Align(
          alignment: Alignment.centerRight,
          child: Transform.translate(
            offset: const Offset(kOutletDotOverhang, 0),
            child: Container(
              width: kOutletDotSize,
              height: kOutletDotSize,
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
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Panel body drag (move) — wraps the card so a body drag repositions the panel.
// ════════════════════════════════════════════════════════════════════════════

/// Wraps a panel card so a body drag repositions the panel(s). The actual move
/// is driven by the host state (D2): [onDragUpdate] carries the raw SCREEN delta
/// (`d.delta`), letting the host move a whole multi-selection together in one
/// undo step, snapping to the grid on release.
class _PanelDraggable extends StatelessWidget {
  final VoidCallback onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;
  final Widget child;

  const _PanelDraggable({
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => onDragStart(),
      onPanUpdate: (d) => onDragUpdate(d.delta),
      onPanEnd: (_) => onDragEnd(),
      child: child,
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Scaled-child wrapper — lays the node out at its NATURAL (world-px) size then
// scales it visually to fill the (already-scaled) `Positioned` box.
// ════════════════════════════════════════════════════════════════════════════

/// Lays [child] out at its natural world-px size ([width] x [height]) and scales
/// it to fill the box it is given (which the caller sizes to `width * scale` x
/// `height * scale`, so both axes scale by exactly `scale` — the paint is
/// identical to a `Transform.scale`).
///
/// Implemented with a [FittedBox] rather than `Transform.scale` + `OverflowBox`
/// because HIT TESTING has to survive the scale. `RenderBox.hitTest` refuses any
/// position outside the box's OWN size, and an `OverflowBox` under tight
/// constraints is sized to the SCALED box (e.g. 168 px) while its child is laid
/// out at the natural size (e.g. 280 px) — so every pointer landing on the
/// painted right-hand ~40 % of a zoomed-out node was silently dropped before it
/// reached the child. That is what made the outlet handle feel half-dead and
/// what leaked those drags to the canvas marquee. [FittedBox] carries a real
/// paint transform that `hitTestChildren` inverts, so the whole painted node is
/// live at every zoom. `clipBehavior` stays [Clip.none] (the default) so a node
/// may still paint outside its box.
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
    return FittedBox(
      fit: BoxFit.fill,
      alignment: Alignment.topLeft,
      child: SizedBox(width: width, height: height, child: child),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Scaled tap wrapper (double-click / right-click on a transformed child).
// ════════════════════════════════════════════════════════════════════════════

class _ScaledTap extends StatelessWidget {
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final Widget child;

  const _ScaledTap({
    this.onTap,
    this.onDoubleTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      child: child,
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Canvas-wide palette drop target.
// ════════════════════════════════════════════════════════════════════════════

class _CanvasDropTarget extends StatefulWidget {
  final ViewportTransform transform;

  /// The first free 'Sub-panel N' / 'SP-N' ordinal (G8) — minted by the shared
  /// [nextSubPanelOrdinal] at build time so a feeder drop never re-mints a
  /// designation an existing (or previously issued) board already carries.
  final int nextPanelOrdinal;
  final ElectricalProjectController controller;
  final ValueChanged<String> onToast;

  const _CanvasDropTarget({
    required this.transform,
    required this.nextPanelOrdinal,
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
          final n = widget.nextPanelOrdinal;
          // A TEMPLATE card (Lighting / Power / Mixed panel) carries its preset
          // through to the new board — dropping one on blank canvas used to
          // create an EMPTY panel, silently discarding the whole reason the
          // engineer picked that card over the plain sub-panel one.
          final template = load.panelTemplateId == null
              ? null
              : panelTemplateById(load.panelTemplateId!);
          widget.controller.addPanelAt(
            name: 'Sub-panel $n',
            tag: 'SP-$n',
            x: x,
            y: y,
            system: load.phases == 1
                ? ElectricalSystem.singlePhase
                : ElectricalSystem.threePhase,
            voltage: load.phases == 1 ? const Voltage(220) : const Voltage(400),
            templateId: load.panelTemplateId,
          );
          widget.onToast(template == null
              ? context.strings(StringKey.electricalPanelAddedNotFed)
              : context.strings.format(
                  StringKey.electricalPanelAddedTemplateTemplate,
                  {
                    'n': n.toString(),
                    'template': template.label,
                  },
                ));
        } else {
          widget.controller.addFloatingLoad(
            kind: load.kind,
            x: x,
            y: y,
            phases: load.phases,
            loadW: load.loadW > 0 ? load.loadW : null,
            motorKw: load.motorKw,
          );
          widget.onToast(context.strings(StringKey.electricalLoadDropped));
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

