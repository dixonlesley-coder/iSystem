/// The UNIFIED Layout canvas — the convergence piece. ONE pannable/zoomable PDF
/// sheet (the shared substrate), with the plumbing, HVAC and electrical
/// disciplines drawn as LAYERS on it. A layer switcher picks the ACTIVE
/// (editable) discipline; the others render faded for coordination (or are
/// hidden when toggled off).
///
/// "Same PDF, work on it at different layers": the active discipline's overlays
/// are interactive (the mechanical drawing/selection/drop overlays scoped to its
/// services, or the electrical palette-drop + drag-to-place); the faded layers
/// are display-only.
///
/// It REUSES the mechanical [CanvasView] + sheet content + the mechanical
/// overlays (driving the shared `sheetsControllerProvider` viewport, so the
/// electrical layer rides the SAME pan/zoom), and the electrical-on-PDF
/// rendering ([ElectricalLayoutLayer]). The electrical edit overlays (the
/// circuit inspector + context menus) are hosted here, mirroring the standalone
/// electrical view.
///
/// Styled with MechXTheme — no Material.
library;

import 'package:flutter/gestures.dart'
    show kMiddleMouseButton, PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/load_kind.dart';

import '../../data/app_settings.dart';
import '../../store/annotation_store.dart';
import '../../store/calibration_store.dart';
import '../../store/electrical_store.dart';
import '../../store/history_store.dart';
import '../../store/inspector_store.dart';
import '../../store/layer_store.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/selection_store.dart';
import '../../store/models/sheet.dart';
import '../../store/sheets_store.dart';
import '../../store/solve_store.dart';
import '../canvas/calibration_overlay.dart';
import '../canvas/canvas_grid.dart' show calibratedGridWorldStep;
import '../canvas/canvas_minimap.dart';
import '../canvas/canvas_tool_cluster.dart';
import '../canvas/canvas_view.dart';
import '../canvas/text_entry_guard.dart';
import '../canvas/drawing_overlay.dart';
import '../canvas/drop_overlay.dart';
import '../canvas/heatmap_layer.dart';
import '../canvas/measurement_overlay.dart';
import '../canvas/mode_pill.dart';
import '../canvas/smart_input_bar.dart';
import '../canvas/tank_overlay.dart';
import '../canvas/room_overlay.dart';
import '../canvas/network_layer.dart';
import '../canvas/selection_overlay.dart';
import '../canvas/sheet_canvas.dart' show sheetContentBuilderProvider;
import '../canvas/viewport.dart';
import '../canvas/zoom_controls.dart';
import '../electrical/electrical_inspector.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../shell/project_io.dart';
import '../shell/templates_dialog.dart';
import '../widgets/canvas_guide_popover.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_empty_state_card.dart';
import 'electrical_layer.dart';
import 'first_run_guide.dart';
import 'layer_switcher.dart';

/// The unified Layout workspace: a top bar (layer switcher + sheet/floor
/// selector) over the shared-substrate canvas, with the electrical edit overlays
/// hosted on top.
class LayoutCanvas extends ConsumerStatefulWidget {
  const LayoutCanvas({super.key});

  @override
  ConsumerState<LayoutCanvas> createState() => _LayoutCanvasState();
}

/// The canvas tools/modes a single-key shortcut can arm (C3), so Enter can
/// repeat the last one after a run finishes (the CAD "repeat last command").
enum _CanvasTool { run, riser, measure, tank, room }

class _LayoutCanvasState extends ConsumerState<LayoutCanvas> {
  /// The last tool/mode armed via a shortcut, re-armed by Enter when idle (C3).
  _CanvasTool? _lastTool;

  /// Whether the persistent "(?) Canvas guide" popover is open. Transient UI
  /// chrome — never persisted; the (?) button is a small edge affordance, so the
  /// idle canvas stays byte-identical.
  bool _showGuide = false;
  void toggleGuide() => setState(() => _showGuide = !_showGuide);
  void closeGuide() => setState(() => _showGuide = false);

  /// The electrical circuit/panel open in the inspector / a context menu.
  ElectricalEditTarget? _editing;

  /// The panel whose PROPERTIES drawer is open (null = closed).
  String? _panelEditing;
  ElectricalPanelMenuTarget? _panelMenu;
  ElectricalEditTarget? _circuitMenu;
  Offset _menuAt = Offset.zero;

  /// One [CanvasView] key per sheet id (so switching sheets still resets the
  /// per-sheet viewport) — gives the on-canvas zoom controls an imperative
  /// handle to the live canvas transform.
  final Map<String, GlobalKey<CanvasViewState>> _canvasKeys = {};
  GlobalKey<CanvasViewState> canvasKeyFor(String id) =>
      _canvasKeys.putIfAbsent(id, () => GlobalKey<CanvasViewState>());

  /// The live canvas viewport (transform + size) the [CanvasView] publishes,
  /// listened to by the on-canvas minimap (G1). A single sink for the current
  /// sheet — the minimap only ever shows the active sheet, and switching sheets
  /// re-publishes on the next frame.
  final ValueNotifier<MinimapViewport?> _minimapViewport = ValueNotifier(null);

  @override
  void dispose() {
    _minimapViewport.dispose();
    super.dispose();
  }

  // Middle-button PAN, handled here (an ancestor of the sheet's overlays) so it
  // works even though the overlays are opaque and would swallow the drag at the
  // CanvasView below. Drives the live canvas via [canvasKeyFor].
  bool _midPanning = false;
  Offset _midLast = Offset.zero;

  /// Hold-Space pan: while the space bar is held the interactive overlays
  /// ignore pointers, so a plain left-drag falls through to the CanvasView's
  /// pan (with the grab cursor) — the CAD-standard answer to "left-drag never
  /// pans with a mechanical layer active". Tracked from the canvas key handler;
  /// disengaged whenever a text-entry surface could own the space bar
  /// (drawing's smart input bar, calibration's length field, the electrical
  /// edit overlays).
  bool _spaceHeld = false;

  void midPanDown(PointerDownEvent e) {
    if (e.buttons & kMiddleMouseButton != 0) {
      _midPanning = true;
      _midLast = e.localPosition;
    }
  }

  void midPanMove(PointerMoveEvent e, String sheetId) {
    if (!_midPanning) return;
    canvasKeyFor(sheetId).currentState?.panByScreen(e.localPosition - _midLast);
    _midLast = e.localPosition;
  }

  void midPanEnd() => _midPanning = false;

  /// Mouse-wheel zoom, handled here (above the overlays) so the wheel signal
  /// isn't swallowed by an opaque overlay before it reaches the canvas.
  void scrollZoom(PointerSignalEvent e, String sheetId) {
    if (e is! PointerScrollEvent) return;
    canvasKeyFor(sheetId)
        .currentState
        ?.zoomByScroll(e.localPosition, e.scrollDelta.dy);
  }

  /// The PDF page widget per sheet, built ONCE and cached. The shared sheet
  /// rebuilds on every viewport change (it watches the sheets controller for
  /// the live transform), and rebuilding the content re-instantiated the pdfrx
  /// page — which flashed its white placeholder while it re-resolved, so any
  /// pan/zoom/edit blanked the drawing. Returning the same instance lets the
  /// framework skip the PDF subtree entirely, so it stays put.
  final Map<String, Widget> _contentCache = {};
  Widget contentFor(Sheet sheet) {
    final key = '${sheet.id}:${sheet.pageIndex}:${sheet.pdfPath}';
    return _contentCache.putIfAbsent(
        key, () => ref.read(sheetContentBuilderProvider)(context, sheet));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) => _onKey(event),
      // If focus leaves this subtree while Space is held (a click into an
      // inspector text field, an Alt+Tab away), the KeyUp is delivered
      // elsewhere and the overlays would stay trapped in IgnorePointer with
      // no on-screen cue — release the pan latch whenever focus departs.
      onFocusChange: (has) {
        if (!has && _spaceHeld) setState(() => _spaceHeld = false);
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(
              color: colors.canvas,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The chrome bar floats a hair above the sheet: a hairline
                  // separator plus a soft downward shadow (Apple-style depth) so
                  // it never blends into the canvas below.
                  DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(
                          bottom: BorderSide(color: colors.border)),
                      boxShadow: MechXShadow.card,
                    ),
                    child: const _LayoutTopBar(),
                  ),
                  Expanded(child: _SharedSheet(host: this)),
                ],
              ),
            ),
          ),
          // Electrical edit overlays (scrim + menus + inspector), hosted here.
          if (_editing != null ||
              _panelEditing != null ||
              _panelMenu != null ||
              _circuitMenu != null)
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) => _closeOverlays(),
                child: const SizedBox.expand(),
              ),
            ),
          if (_circuitMenu != null) _buildCircuitMenu(),
          if (_panelMenu != null) _buildPanelMenu(),
          if (_editing != null) _buildInspector(),
          if (_panelEditing != null) _buildPanelInspector(),
        ],
      ),
    );
  }

  // ── Electrical edit-overlay callbacks (handed to the electrical layer) ──────

  ElectricalProjectController get _ctrl =>
      ref.read(electricalProjectProvider.notifier);

  Offset _toLocal(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    return box?.globalToLocal(global) ?? global;
  }

  void _closeOverlays() {
    if (_editing != null ||
        _panelEditing != null ||
        _panelMenu != null ||
        _circuitMenu != null) {
      setState(() {
        _editing = null;
        _panelEditing = null;
        _panelMenu = null;
        _circuitMenu = null;
      });
    }
  }

  /// Panel double-click opens the panel PROPERTIES drawer (name / tag /
  /// diversity / headroom); a way / load double-click keeps opening the
  /// circuit editor via [onEditCircuit].
  void onEditPanel(String panelId) =>
      setState(() => _panelEditing = panelId);

  void onEditCircuit(String panelId, String circuitId) =>
      setState(() => _editing = ElectricalEditTarget(panelId, circuitId));

  void onPanelMenu(String panelId, Offset globalPos) {
    setState(() {
      _panelMenu = ElectricalPanelMenuTarget(panelId);
      _circuitMenu = null;
      _editing = null;
      _panelEditing = null;
      _menuAt = _toLocal(globalPos);
    });
  }

  void onCircuitMenu(String panelId, String circuitId, Offset globalPos) {
    setState(() {
      _circuitMenu = ElectricalEditTarget(panelId, circuitId);
      _panelMenu = null;
      _editing = null;
      _panelEditing = null;
      _menuAt = _toLocal(globalPos);
    });
  }

  Widget _buildCircuitMenu() => Positioned(
        left: _menuAt.dx,
        top: _menuAt.dy,
        child: _EntranceScaleFade(
          alignment: Alignment.topLeft,
          child: ElectricalCircuitMenu(
            target: _circuitMenu!,
            controller: _ctrl,
            onEdit: () => setState(() {
              _editing = _circuitMenu;
              _circuitMenu = null;
            }),
            onDone: () => setState(() => _circuitMenu = null),
          ),
        ),
      );

  Widget _buildPanelMenu() {
    final menu = _panelMenu!;
    final project = ref.read(electricalProjectProvider);
    final panel =
        project.panels.where((p) => p.id == menu.panelId).firstOrNull;
    if (panel == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _closeOverlays());
      return const SizedBox.shrink();
    }
    return Positioned(
      left: _menuAt.dx,
      top: _menuAt.dy,
      child: _EntranceScaleFade(
        alignment: Alignment.topLeft,
        child: ElectricalPanelMenu(
          panel: panel,
          controller: _ctrl,
          onProperties: () => setState(() {
            _panelMenu = null;
            _panelEditing = panel.id;
          }),
          onOpen: () {
            final first = panel.circuits
                .where((c) => c.loadKind != LoadKind.feeder)
                .firstOrNull;
            setState(() {
              _panelMenu = null;
              if (first != null) {
                _editing = ElectricalEditTarget(panel.id, first.id);
              }
            });
          },
          onDone: () => setState(() => _panelMenu = null),
        ),
      ),
    );
  }

  Widget _buildInspector() {
    final target = _editing!;
    final project = ref.watch(electricalProjectProvider);
    final panel =
        project.panels.where((p) => p.id == target.panelId).firstOrNull;
    final circuit =
        panel?.circuits.where((c) => c.id == target.circuitId).firstOrNull;
    if (panel == null || circuit == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _closeOverlays());
      return const SizedBox.shrink();
    }
    return Positioned(
      top: 0,
      right: 0,
      bottom: 0,
      child: ElectricalCircuitInspector(
        key: ValueKey('${target.panelId}/${target.circuitId}'),
        panel: panel,
        circuit: circuit,
        controller: _ctrl,
        onClose: _closeOverlays,
      ),
    );
  }

  Widget _buildPanelInspector() {
    final panelId = _panelEditing!;
    final project = ref.watch(electricalProjectProvider);
    final panel = project.panels.where((p) => p.id == panelId).firstOrNull;
    if (panel == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _closeOverlays());
      return const SizedBox.shrink();
    }
    return Positioned(
      top: 0,
      right: 0,
      bottom: 0,
      child: ElectricalPanelInspector(
        key: ValueKey('panel/$panelId'),
        panel: panel,
        controller: _ctrl,
        onClose: _closeOverlays,
      ),
    );
  }

  // ── Keyboard (delete / undo / redo / escape), shared with the Plan canvas ───

  KeyEventResult _onKey(KeyEvent event) {
    // Hold-Space pan — tracked on both key-down AND key-up (everything below
    // is key-down only). Space is left alone while a text-entry surface could
    // legitimately want it (the smart input bar while drawing, the calibration
    // length field, the electrical circuit/panel editors).
    if (event.logicalKey == LogicalKeyboardKey.space) {
      if (event is KeyUpEvent) {
        if (!_spaceHeld) return KeyEventResult.ignored;
        setState(() => _spaceHeld = false);
        return KeyEventResult.handled;
      }
      // D3: Space still PANS while placing the two calibration points; it is
      // blocked ONLY in the distance-entry phase, where the "Known distance"
      // text field is focused and could legitimately want the space bar.
      final textEntryPossible = _editing != null ||
          _panelEditing != null ||
          ref.read(calibrationControllerProvider).isEnteringDistance ||
          ref.read(networkControllerProvider).isDrawing;
      if (textEntryPossible) return KeyEventResult.ignored;
      if (!_spaceHeld) setState(() => _spaceHeld = true);
      return KeyEventResult.handled; // KeyDownEvent + KeyRepeatEvent
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final mod = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;

    // A focused text field owns its editing keys (B4): Backspace/Delete and
    // the select-all/clipboard/undo combos must edit the FIELD, not the
    // drawing. This ancestor Focus sits BELOW the app-root
    // DefaultTextEditingShortcuts on the bubble path, so returning ignored
    // here lets the field's own handling run. (Descendants include the
    // calibration "Known distance" field, the smart input bar and the
    // electrical inspectors.)
    if (isTextEntryFocused() &&
        (key == LogicalKeyboardKey.delete ||
            key == LogicalKeyboardKey.backspace ||
            (mod &&
                (key == LogicalKeyboardKey.keyA ||
                    key == LogicalKeyboardKey.keyC ||
                    key == LogicalKeyboardKey.keyV ||
                    key == LogicalKeyboardKey.keyZ ||
                    key == LogicalKeyboardKey.keyY)))) {
      return KeyEventResult.ignored;
    }

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

    // Copy / paste / delete only act on the mechanical selection (the active
    // mechanical layer). The current sheet/floor mirror what _SharedSheet uses.
    final activeMechanical = ref.read(activeDisciplineProvider).isMechanical;
    if (activeMechanical && mod && key == LogicalKeyboardKey.keyC) {
      final sel = ref.read(selectionProvider);
      final nodeIds = sel.nodeIds.isEmpty
          ? {if (sel.nodeId != null) sel.nodeId!}
          : sel.nodeIds;
      final edgeIds = sel.edgeIds.isEmpty
          ? {if (sel.edgeId != null) sel.edgeId!}
          : sel.edgeIds;
      if (nodeIds.isEmpty && edgeIds.isEmpty) return KeyEventResult.ignored;
      ref
          .read(networkControllerProvider.notifier)
          .copySelection(nodeIds, edgeIds);
      return KeyEventResult.handled;
    }
    if (activeMechanical && mod && key == LogicalKeyboardKey.keyV) {
      final sheet = ref.read(sheetsControllerProvider).current;
      if (sheet == null) return KeyEventResult.ignored;
      final levelCount =
          ref.read(projectControllerProvider).building.levelCount;
      final floorIndex =
          ref.read(sheetsControllerProvider).floorFor(sheet.id, levelCount);
      ref
          .read(networkControllerProvider.notifier)
          .paste(sheetId: sheet.id, floorIndex: floorIndex);
      return KeyEventResult.handled;
    }
    // Ctrl/Cmd+A — select all on the current sheet/floor, scoped to the ACTIVE
    // discipline's services (Ctrl+A on Plumbing doesn't grab the HVAC ducts).
    if (activeMechanical && mod && key == LogicalKeyboardKey.keyA) {
      final sheet = ref.read(sheetsControllerProvider).current;
      if (sheet == null) return KeyEventResult.ignored;
      final levelCount =
          ref.read(projectControllerProvider).building.levelCount;
      final floorIndex =
          ref.read(sheetsControllerProvider).floorFor(sheet.id, levelCount);
      ref.read(selectionProvider.notifier).selectAllOnFloor(
            sheet.id,
            floorIndex,
            services:
                servicesFor(ref.read(activeDisciplineProvider)).toSet(),
          );
      return KeyEventResult.handled;
    }
    if (activeMechanical &&
        (key == LogicalKeyboardKey.delete ||
            key == LogicalKeyboardKey.backspace)) {
      final sel = ref.read(selectionProvider);
      if (sel.isEmpty) return KeyEventResult.ignored;
      final net = ref.read(networkControllerProvider.notifier);
      if (sel.isMulti) {
        net.deleteMany(sel.nodeIds, sel.edgeIds);
      } else if (sel.isNode) {
        net.deleteNode(sel.nodeId!);
      } else if (sel.isEdge) {
        net.deleteEdge(sel.edgeId!);
      }
      ref.read(selectionProvider.notifier).clear();
      return KeyEventResult.handled;
    }
    // Electrical layer active: Delete removes the selected circuit (or panel)
    // via the undoable store intents — parity with the mechanical branch.
    if (!activeMechanical &&
        (key == LogicalKeyboardKey.delete ||
            key == LogicalKeyboardKey.backspace)) {
      final sel = ref.read(electricalSelectionProvider);
      if (sel == null) return KeyEventResult.ignored;
      final ctrl = ref.read(electricalProjectProvider.notifier);
      if (sel.isCircuit) {
        ctrl.deleteCircuit(sel.panelId, sel.circuitId!);
      } else {
        ctrl.deletePanel(sel.panelId);
      }
      ref.read(electricalSelectionProvider.notifier).clear();
      return KeyEventResult.handled;
    }

    // C3: single-key tool + service shortcuts — bare keys (no Ctrl/Meta),
    // guarded so a focused text field (calibration / smart input / inspector)
    // types normally. F fits the canvas; the rest are mechanical.
    if (!mod && !isTextEntryFocused()) {
      // F fits via the shared fit-request seam so it works even when the
      // CanvasView itself doesn't hold focus (W3-P5; the command palette's Fit
      // action bumps the same provider).
      if (key == LogicalKeyboardKey.keyF) {
        ref.read(canvasFitRequestProvider.notifier).request();
        return KeyEventResult.handled;
      }
      if (activeMechanical) {
        if (key == LogicalKeyboardKey.keyO) {
          ref.read(orthoProvider.notifier).toggle();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.keyV) {
          _armTool(null);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.keyR) {
          _armTool(_CanvasTool.run);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.keyE) {
          _armTool(_CanvasTool.riser);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.keyM) {
          _armTool(_CanvasTool.measure);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.keyK) {
          _armTool(_CanvasTool.tank);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.keyB) {
          _armTool(_CanvasTool.room);
          return KeyEventResult.handled;
        }
        // Enter repeats the last tool when idle (Select, no mode, not drawing).
        if (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) {
          if (_isIdle() && _lastTool != null) {
            _armTool(_lastTool);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }
        // Number keys 1..N pick the active layer's Nth scoped service.
        final digit = _serviceDigit(key);
        if (digit != null) {
          final services = servicesFor(ref.read(activeDisciplineProvider));
          if (digit < services.length) {
            ref.read(networkControllerProvider.notifier)
                .setService(services[digit]);
            return KeyEventResult.handled;
          }
        }
      }
    }

    if (key == LogicalKeyboardKey.escape) {
      if (_editing != null ||
          _panelEditing != null ||
          _panelMenu != null ||
          _circuitMenu != null) {
        _closeOverlays();
        return KeyEventResult.handled;
      }
      if (ref.read(electricalSelectionProvider) != null) {
        ref.read(electricalSelectionProvider.notifier).clear();
        return KeyEventResult.handled;
      }
      if (ref.read(calibrationControllerProvider).isActive) {
        ref.read(calibrationControllerProvider.notifier).cancel();
        return KeyEventResult.handled;
      }
      if (ref.read(networkControllerProvider).pendingPoint != null) {
        ref.read(networkControllerProvider.notifier).cancelPending();
        return KeyEventResult.handled;
      }
      // Step out of any active canvas MODE back to Select — Esc must always
      // back out (the tool buttons live behind two collapsible layers, so a
      // key path is the only reliable exit).
      if (ref.read(measureModeProvider)) {
        ref.read(measureModeProvider.notifier).set(false);
        return KeyEventResult.handled;
      }
      if (ref.read(tankModeProvider)) {
        ref.read(tankModeProvider.notifier).set(false);
        return KeyEventResult.handled;
      }
      if (ref.read(roomModeProvider)) {
        ref.read(roomModeProvider.notifier).set(false);
        return KeyEventResult.handled;
      }
      if (ref.read(networkControllerProvider).tool != DrawTool.select) {
        ref.read(networkControllerProvider.notifier).setTool(DrawTool.select);
        return KeyEventResult.handled;
      }
      if (!ref.read(selectionProvider).isEmpty) {
        ref.read(selectionProvider.notifier).clear();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// Arm a canvas tool/mode via its shortcut (C3), enforcing the toolbar's
  /// mutual exclusion (a draw tool clears the measure/tank/room modes and vice
  /// versa). [tool] null = Select. Remembers the last non-Select tool so Enter
  /// can repeat it.
  void _armTool(_CanvasTool? tool) {
    final net = ref.read(networkControllerProvider.notifier);
    final measure = ref.read(measureModeProvider.notifier);
    final tank = ref.read(tankModeProvider.notifier);
    final room = ref.read(roomModeProvider.notifier);
    switch (tool) {
      case null:
        measure.set(false);
        tank.set(false);
        room.set(false);
        net.setTool(DrawTool.select);
      case _CanvasTool.run:
        measure.set(false);
        tank.set(false);
        room.set(false);
        net.setTool(DrawTool.drawRun);
        _lastTool = tool;
      case _CanvasTool.riser:
        measure.set(false);
        tank.set(false);
        room.set(false);
        net.setTool(DrawTool.drawRiser);
        _lastTool = tool;
      case _CanvasTool.measure:
        net.setTool(DrawTool.select);
        tank.set(false);
        room.set(false);
        measure.set(true);
        _lastTool = tool;
      case _CanvasTool.tank:
        net.setTool(DrawTool.select);
        measure.set(false);
        room.set(false);
        tank.set(true);
        _lastTool = tool;
      case _CanvasTool.room:
        net.setTool(DrawTool.select);
        measure.set(false);
        tank.set(false);
        room.set(true);
        _lastTool = tool;
    }
  }

  /// True when no tool/mode is active (Select, not drawing, no annotation mode)
  /// — the state in which Enter repeats the last tool.
  bool _isIdle() =>
      ref.read(networkControllerProvider).tool == DrawTool.select &&
      !ref.read(measureModeProvider) &&
      !ref.read(tankModeProvider) &&
      !ref.read(roomModeProvider);

  /// The 0-based service index for a number key (`1`..`9`, top-row or numpad),
  /// or null for any other key. (A switch, not a const map — [LogicalKeyboardKey]
  /// overrides `==`, so it can't be a const map key.)
  int? _serviceDigit(LogicalKeyboardKey key) => switch (key) {
        LogicalKeyboardKey.digit1 || LogicalKeyboardKey.numpad1 => 0,
        LogicalKeyboardKey.digit2 || LogicalKeyboardKey.numpad2 => 1,
        LogicalKeyboardKey.digit3 || LogicalKeyboardKey.numpad3 => 2,
        LogicalKeyboardKey.digit4 || LogicalKeyboardKey.numpad4 => 3,
        LogicalKeyboardKey.digit5 || LogicalKeyboardKey.numpad5 => 4,
        LogicalKeyboardKey.digit6 || LogicalKeyboardKey.numpad6 => 5,
        LogicalKeyboardKey.digit7 || LogicalKeyboardKey.numpad7 => 6,
        LogicalKeyboardKey.digit8 || LogicalKeyboardKey.numpad8 => 7,
        LogicalKeyboardKey.digit9 || LogicalKeyboardKey.numpad9 => 8,
        _ => null,
      };

  /// The [CanvasView] arrow-key hook (E2): nudge the mechanical selection by the
  /// grid step and consume the key; return false (so the canvas pans) when a
  /// text field owns the keyboard, the active layer isn't mechanical, or nothing
  /// is selected.
  bool handleDirectionalKey(LogicalKeyboardKey key) {
    if (isTextEntryFocused()) return false;
    if (!ref.read(activeDisciplineProvider).isMechanical) return false;
    final sel = ref.read(selectionProvider);
    if (!sel.hasSelection) return false;
    final sheet = ref.read(sheetsControllerProvider).current;
    if (sheet == null) return false;
    final cal = ref.read(projectControllerProvider).calibrationFor(sheet.id);
    final step =
        cal == null ? 32.0 : calibratedGridWorldStep(cal.metersPerPixel);
    double dx = 0, dy = 0;
    switch (key) {
      case LogicalKeyboardKey.arrowLeft:
        dx = -step;
      case LogicalKeyboardKey.arrowRight:
        dx = step;
      case LogicalKeyboardKey.arrowUp:
        dy = -step;
      case LogicalKeyboardKey.arrowDown:
        dy = step;
      default:
        return false;
    }
    final net = ref.read(networkControllerProvider).network;
    final ids = <String>{...sel.nodeIds};
    for (final eid in sel.edgeIds) {
      final e = net.edgeById(eid);
      if (e != null) {
        ids.add(e.fromId);
        ids.add(e.toId);
      }
    }
    if (ids.isEmpty) return false;
    final ctrl = ref.read(networkControllerProvider.notifier);
    ctrl.pushUndoSnapshot();
    ctrl.moveMany(ids, dx, dy);
    return true;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Top bar: the layer switcher + the sheet/floor selector.
// ════════════════════════════════════════════════════════════════════════════

class _LayoutTopBar extends ConsumerWidget {
  const _LayoutTopBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final sheets = ref.watch(sheetsControllerProvider);
    final levelCount = ref.watch(projectControllerProvider).building.levelCount;
    final current = sheets.current;

    // Sheet switching lives in the flanking sheet rail (the same multi-sheet
    // rail the mechanical canvas uses); this bar carries the LAYER switcher and
    // the active sheet / floor context. The switcher scrolls horizontally and
    // the trailing context truncates, so the bar never overflows on a narrow
    // canvas column.
    return Container(
      color: colors.surface,
      padding: const EdgeInsets.symmetric(
          horizontal: MechXSpacing.md, vertical: MechXSpacing.xs + 2),
      child: Row(
        children: [
          // The layer switcher gets the available width (and scrolls
          // horizontally if the system layers ever exceed it); the sheet
          // breadcrumb is capped so it can't starve the switcher.
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: const LayerSwitcher(),
            ),
          ),
          const SizedBox(width: MechXSpacing.sm),
          if (current != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                _floorLabel(sheets, current.id, current.name, levelCount),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: type.caption.copyWith(color: colors.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}

/// The honest on-canvas floor label (A7). The building seeds three default
/// levels, so a single imported plan otherwise reads "Floor 1 of 3" against two
/// phantom, unmapped floors. Count only the floors a sheet actually OCCUPIES as
/// the denominator (never below the current floor number, so it can't undercount
/// a genuinely tall building), and drop the "Floor N of M" breadcrumb entirely
/// when there is effectively a single floor — showing just the sheet name. For a
/// fully-mapped building (every level carries a sheet, e.g. the demo project)
/// this is byte-identical to the old `<name>  ·  Floor N of levelCount`.
String _floorLabel(
    SheetsState sheets, String sheetId, String sheetName, int levelCount) {
  final n = sheets.floorFor(sheetId, levelCount) + 1;
  final occupied = sheets.sheets
      .map((s) => sheets.floorFor(s.id, levelCount))
      .toSet()
      .length;
  final m = occupied > n ? occupied : n;
  return m <= 1 ? sheetName : '$sheetName  ·  Floor $n of $m';
}

// ════════════════════════════════════════════════════════════════════════════
// The shared sheet: ONE CanvasView + the mechanical overlays (layer-filtered) +
// the electrical layer, all on the same `sheetsControllerProvider` viewport.
// ════════════════════════════════════════════════════════════════════════════

class _SharedSheet extends ConsumerWidget {
  final _LayoutCanvasState host;
  const _SharedSheet({required this.host});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final sheetsState = ref.watch(sheetsControllerProvider);
    final sheet = sheetsState.current;

    if (sheet == null) {
      // A1: on a genuinely empty project, lead with a one-time, dismissible
      // orientation card naming the five-step workflow. It sits ABOVE the
      // branded empty-state card (which keeps carrying its own Import / template
      // actions), and disappears for good once the machine-local "seen" flag is
      // latched — so a returning user just sees the empty state.
      final seenFirstRun = ref.watch(appSettingsProvider).seenFirstRun;
      return ColoredBox(
        color: colors.canvas,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(MechXSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!seenFirstRun) ...[
                  FirstRunOrientationCard(
                    // Latch on BOTH paths so the one-time card never returns —
                    // taking the primary "Import a plan" action counts as
                    // having seen the orientation just as much as dismissing it
                    // (otherwise a later File -> New re-shows it).
                    onImport: () {
                      ref.read(appSettingsProvider.notifier).markFirstRunSeen();
                      importPlan(context, ref);
                    },
                    onDismiss: () => ref
                        .read(appSettingsProvider.notifier)
                        .markFirstRunSeen(),
                  ),
                  const SizedBox(height: MechXSpacing.md),
                ],
                // A branded empty-state card (the shared one, matching the
                // electrical workspace's), not bare text — and it CARRIES its
                // actions (the Apple empty-state rule) instead of describing
                // buttons that live elsewhere.
                MechXEmptyStateCard(
                  title: 'No sheet loaded',
                  body: 'Import a PDF floor plan to begin — then calibrate its '
                      'scale and draw on the Plumbing, HVAC and Electrical '
                      'layers.',
                  actions: [
                    MechXButton(
                      label: 'Import plan...',
                      primary: true,
                      onPressed: () => importPlan(context, ref),
                    ),
                    MechXButton(
                      label: 'New from template...',
                      onPressed: () => showTemplatesDialog(context),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    final content = host.contentFor(sheet);
    final calibrating = ref.watch(calibrationControllerProvider).isActive;
    final drawing = ref.watch(networkControllerProvider).isDrawing;
    // A4: has anything been drawn yet? The first-draw hint teaches the primary
    // gesture only until the very first node lands anywhere in the network.
    final hasDrawing =
        ref.watch(networkControllerProvider).network.nodes.isNotEmpty;
    final showHeatmap = ref.watch(showHeatmapProvider);
    final calibration =
        ref.watch(projectControllerProvider).calibrationFor(sheet.id);
    final calibrated = calibration != null;

    final levelCount = ref.watch(projectControllerProvider).building.levelCount;
    final floorIndex = sheetsState.floorFor(sheet.id, levelCount);

    final active = ref.watch(activeDisciplineProvider);
    final visible = ref.watch(layerVisibilityProvider);
    final mechanicalActive = active.isMechanical;
    final electricalActive = active == DisciplineLayer.electrical;
    final electricalVisible = visible.contains(DisciplineLayer.electrical);
    // Any mechanical layer visible? (Plumbing or HVAC.)
    final mechanicalVisible = visible.any((l) => l.isMechanical);
    final measureMode = ref.watch(measureModeProvider);
    final tankMode = ref.watch(tankModeProvider);
    final roomMode = ref.watch(roomModeProvider);

    // G3: the on-canvas tool cluster only appears when the inspector is
    // collapsed (the canvas-focus state), so an inspector-open workspace stays
    // byte-identical. G1: the network nodes on THIS sheet/floor are the minimap's
    // content landmarks (content-pixel space, mapped like the sheet substrate).
    final inspectorCollapsed = ref.watch(inspectorCollapsedProvider);
    final minimapMarkers = <Offset>[
      for (final n in ref.watch(networkControllerProvider).network.nodes)
        if (n.sheetId == sheet.id && n.floorIndex == floorIndex)
          Offset(n.x, n.y),
    ];

    // The shared viewport transform (persisted per-sheet) is what the electrical
    // layer reads, so both disciplines ride the SAME pan/zoom.
    final vt = sheetsState.viewportFor(sheet.id) ?? const ViewportTransform();

    // Hold-Space pan: the interactive overlays stand down (IgnorePointer) so a
    // left-drag reaches the CanvasView's pan, with the default grab cursor.
    final spaceHeld = host._spaceHeld;
    // The honest cursor for the active mode (the canvas otherwise advertises a
    // grab-pan that the overlays repurpose): precise while a placement/measure
    // tool or calibration owns the click, the plain arrow in Select mode, and
    // the default grab affordance only while Space-pan actually pans.
    final MouseCursor? canvasCursor = spaceHeld
        ? null
        : (calibrating ||
                (mechanicalActive &&
                    (drawing || measureMode || tankMode || roomMode))
            ? SystemMouseCursors.precise
            : SystemMouseCursors.basic);

    return Listener(
      // Middle-button drag pans, mouse-wheel zooms — both handled above the
      // opaque overlays that would otherwise swallow the events.
      onPointerSignal: (e) => host.scrollZoom(e, sheet.id),
      onPointerDown: host.midPanDown,
      onPointerMove: (e) => host.midPanMove(e, sheet.id),
      onPointerUp: (_) => host.midPanEnd(),
      onPointerCancel: (_) => host.midPanEnd(),
      child: Stack(
      children: [
        // The PDF sheet, pannable/zoomable — drives the shared viewport.
        Positioned.fill(
          child: CanvasView(
            key: host.canvasKeyFor(sheet.id),
            contentSize: sheet.sizePx,
            initialTransform: sheetsState.viewportFor(sheet.id),
            background: colors.canvas,
            gridColor: colors.gridLine,
            // A calibrated sheet snaps the grid minors to a round 1-2-5 metre
            // ladder (majors on the 4x multiple); uncalibrated keeps the
            // default 32 px texture.
            gridWorldStep: calibration == null
                ? null
                : calibratedGridWorldStep(calibration.metersPerPixel),
            cursor: canvasCursor,
            // E2: arrows nudge the mechanical selection by the grid step; with
            // nothing selected the host returns false and the canvas pans.
            onDirectionalKey: host.handleDirectionalKey,
            // G1: publish the live viewport for the on-canvas minimap.
            viewportSink: host._minimapViewport,
            onTransformChanged: (t) => ref
                .read(sheetsControllerProvider.notifier)
                .setViewport(sheet.id, t),
            child: content,
          ),
        ),
        // Heatmap (mechanical solve) — only when a mechanical layer is visible.
        if (showHeatmap && mechanicalVisible)
          Positioned.fill(
            child: HeatmapLayer(
              sheetId: sheet.id,
              floorIndex: floorIndex,
              contentSize: sheet.sizePx,
            ),
          ),
        // Mechanical network — layer-filtered (faded/hidden per discipline).
        if (mechanicalVisible)
          Positioned.fill(
            child: NetworkLayer(
              sheetId: sheet.id,
              floorIndex: floorIndex,
              layerFiltered: true,
            ),
          ),
        // Electrical layer — interactive when active, faded when a coordination
        // layer, hidden when toggled off.
        if (electricalVisible)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: spaceHeld,
              child: ElectricalLayoutLayer(
                transform: vt,
                sheetId: sheet.id,
                floorIndex: floorIndex,
                interactive: electricalActive,
                onEditPanel: host.onEditPanel,
                onEditCircuit: host.onEditCircuit,
                onPanelMenu: host.onPanelMenu,
                onCircuitMenu: host.onCircuitMenu,
              ),
            ),
          ),
        // Measurement annotations — saved dimensions always render (when a
        // mechanical layer is visible); the measure tool captures taps only when
        // active (and never while drawing/calibrating).
        if (mechanicalVisible && !calibrating)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: spaceHeld,
              child: MeasurementOverlay(
                sheetId: sheet.id,
                floorIndex: floorIndex,
                active: mechanicalActive && measureMode && !drawing,
              ),
            ),
          ),
        // Tank areas — saved footprints always render (mechanical layer visible);
        // the tank tool captures a drag only when active.
        if (mechanicalVisible && !calibrating)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: spaceHeld,
              child: TankOverlay(
                sheetId: sheet.id,
                floorIndex: floorIndex,
                active: mechanicalActive && tankMode && !drawing,
              ),
            ),
          ),
        // Room/zone areas — saved footprints always render (mechanical layer
        // visible); the room tool captures a drag only when active.
        if (mechanicalVisible && !calibrating)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: spaceHeld,
              child: RoomOverlay(
                sheetId: sheet.id,
                floorIndex: floorIndex,
                active: mechanicalActive && roomMode && !drawing,
              ),
            ),
          ),
        // Mechanical drawing / drop / selection overlays — ONLY when a mechanical
        // layer is active (so editing routes to the active discipline). The
        // selection/drop overlays stand down while the measure tool is on.
        if (mechanicalActive && drawing)
          Positioned.fill(
            child: DrawingOverlay(
              sheetId: sheet.id,
              floorIndex: floorIndex,
              levelCount: levelCount,
            ),
          ),
        if (mechanicalActive &&
            !drawing &&
            !calibrating &&
            !measureMode &&
            !tankMode &&
            !roomMode)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: spaceHeld,
              child: NetworkSelectionOverlay(
                sheetId: sheet.id,
                floorIndex: floorIndex,
                onFitView: () =>
                    host.canvasKeyFor(sheet.id).currentState?.fitView(),
              ),
            ),
          ),
        // The drop target sits ABOVE the selection overlay so a dragged palette
        // card is hit-tested before the (opaque-handle-bearing) selection layer
        // swallows it. It IgnorePointer's itself when nothing is being dragged,
        // so normal taps still fall through to selection underneath.
        if (mechanicalActive &&
            !drawing &&
            !calibrating &&
            !measureMode &&
            !tankMode &&
            !roomMode)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: spaceHeld,
              child:
                  DropOverlay(sheetId: sheet.id, floorIndex: floorIndex),
            ),
          ),
        if (calibrating)
          Positioned.fill(child: CalibrationOverlay(sheetId: sheet.id)),
        // First-run calibrate nudge.
        if (!calibrated && !calibrating)
          const Positioned(
            top: MechXSpacing.md,
            left: 0,
            right: 0,
            child: Center(child: _CalibrateHint()),
          ),
        // A4: first-draw hint — a quiet, non-interactive nudge over a
        // calibrated-but-empty mechanical canvas teaching the primary draw
        // gesture. Shown only while idle (Select, no active mode) so it never
        // collides with the mode pill, and gated off the moment anything is
        // drawn. IgnorePointer so it never eats a drawing tap.
        if (mechanicalActive &&
            calibrated &&
            !calibrating &&
            !drawing &&
            !measureMode &&
            !tankMode &&
            !roomMode &&
            !hasDrawing)
          const Positioned(
            top: MechXSpacing.md,
            left: 0,
            right: 0,
            child: Center(child: IgnorePointer(child: FirstDrawHint())),
          ),
        // On-canvas mode pill — the active tool made visible on the canvas
        // itself (renders nothing in Select mode). Drops below the calibrate
        // nudge when both are up.
        if (mechanicalActive && !calibrating)
          Positioned(
            top: (!calibrated) ? MechXSpacing.md + 40 : MechXSpacing.md,
            left: 0,
            right: 0,
            child: const Center(child: ModePill()),
          ),
        // On-canvas zoom controls (bottom-left) — the same cluster the
        // electrical canvas shows, so both workspaces share the affordance.
        Positioned(
          left: MechXSpacing.md,
          bottom: MechXSpacing.md,
          child: ZoomControls(
            onIn: () => host.canvasKeyFor(sheet.id).currentState?.zoomIn(),
            onOut: () => host.canvasKeyFor(sheet.id).currentState?.zoomOut(),
            onFit: () => host.canvasKeyFor(sheet.id).currentState?.fitView(),
          ),
        ),
        // Persistent "(?) Canvas guide" (top-left) — the same affordance the
        // electrical canvas advertises, now lifted to the mechanical Layout
        // canvas so right-click size/material + drag gestures are discoverable.
        // The gesture list is scoped to the active layer.
        Positioned(
          left: MechXSpacing.md,
          top: MechXSpacing.sm,
          child: CanvasGuideButton(
            open: host._showGuide,
            onToggle: host.toggleGuide,
          ),
        ),
        if (host._showGuide)
          Positioned(
            left: MechXSpacing.md,
            top: 48,
            child: CanvasGuideLegend(
              items: electricalActive
                  ? _electricalLayerGuideItems
                  : _mechanicalLayerGuideItems,
              onClose: host.closeGuide,
            ),
          ),
        // On-canvas minimap (top-right) — a scaled overview of the sheet + drawn
        // content + the live viewport rectangle; tap/drag to recenter (G1).
        // Placed top-right, clear of every other overlay: the zoom cluster
        // (bottom-left), the (?) guide (top-left), the mode pill (top-centre),
        // the inspector-collapse chevron (which sits OUTSIDE the canvas, to its
        // right) and the heatmap legend (bottom-right, on golden 03).
        Positioned(
          right: MechXSpacing.md,
          top: MechXSpacing.sm,
          child: ValueListenableBuilder<MinimapViewport?>(
            valueListenable: host._minimapViewport,
            builder: (context, vp, _) => CanvasMinimap(
              contentSize: sheet.sizePx,
              markers: minimapMarkers,
              viewport: vp,
              onRecenter: (world) => host
                  .canvasKeyFor(sheet.id)
                  .currentState
                  ?.centreOnWorld(world),
            ),
          ),
        ),
        // On-canvas tool cluster (left edge, vertically centred) — SWITCH the
        // primary draw tools (Select / Run / Riser) + the active-layer service
        // without the inspector (G3). Shown ONLY when the inspector is collapsed
        // and a mechanical layer is active, so an inspector-open workspace — and
        // every seeded golden — is byte-identical. Its tool taps route through
        // the same `_armTool` the single-key shortcuts use (shared mutual
        // exclusion).
        if (mechanicalActive && !calibrating && inspectorCollapsed)
          Positioned(
            left: MechXSpacing.md,
            top: 0,
            bottom: 0,
            child: Align(
              alignment: Alignment.centerLeft,
              child: CanvasToolCluster(
                onSelect: () => host._armTool(null),
                onRun: () => host._armTool(_CanvasTool.run),
                onRiser: () => host._armTool(_CanvasTool.riser),
              ),
            ),
          ),
        // Smart input bar (bottom-centre) — precise length entry while drawing a
        // run. Renders nothing unless a run is pending, so idle is unchanged.
        if (mechanicalActive && drawing)
          Positioned(
            left: 0,
            right: 0,
            bottom: MechXSpacing.md,
            child: Center(
              child: SmartInputBar(
                sheetId: sheet.id,
                floorIndex: floorIndex,
              ),
            ),
          ),
      ],
      ),
    );
  }
}

/// Gesture-help for the mechanical (Plumbing / HVAC) layer of the Layout canvas.
const _mechanicalLayerGuideItems = <String>[
  'Tool keys: V select · R run · E riser · M measure · K tank · B room',
  'Number keys 1-N pick the active layer service; Enter repeats the last tool',
  'O toggles ortho; hold Shift while drawing for a free angle',
  'Drag the blue outlet out of a hovered/selected node to lay a run',
  'Drag a Terminal onto a main to branch it (it tees into the run)',
  'Right-click a segment to set its size (inches) or material',
  'Drag a segment endpoint to resize it — it snaps to nearby fittings',
  'Left-click to select; Shift+click or rubber-band for multi-select',
  'Arrow keys nudge the selection; drag a selected node to move the group',
  'Middle-drag or hold Space to pan; scroll to zoom; F fits the view',
  'Risers drawn here stack vertically in the Riser view (left nav)',
];

/// Gesture-help for the electrical layer of the Layout canvas.
const _electricalLayerGuideItems = <String>[
  'Drag a Load card onto a panel to wire it (creates the MCB)',
  'Double-click a panel or circuit to edit it',
  'Right-click a panel or circuit for Edit / Duplicate / Delete',
  'Drag a placed panel or load to move it on the plan',
  'Drag the empty canvas to pan; scroll to zoom',
  // D7: cross-reference to the standalone Electrical workspace, mirroring the
  // mechanical list's Riser cross-reference — both read/write the SAME
  // electrical model, just two different projections of it.
  'Panels and loads placed here also appear in the Electrical workspace (left nav)',
];

/// A small tappable nudge over an uncalibrated sheet — starts scale calibration.
class _CalibrateHint extends ConsumerWidget {
  const _CalibrateHint();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => ref.read(calibrationControllerProvider.notifier).start(),
        // Gentle scale-in + fade so the nudge arrives rather than pops.
        child: const _EntranceScaleFade(
          child: _CalibrateHintBody(),
        ),
      ),
    );
  }
}

/// The calibrate-nudge content (factored out so the entrance wrapper can be a
/// const child).
class _CalibrateHintBody extends StatelessWidget {
  const _CalibrateHintBody();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MechXSpacing.sm + 2,
        vertical: MechXSpacing.xs + 1,
      ),
      decoration: BoxDecoration(
        color: colors.surface.withAlpha(240),
        borderRadius: MechXRadii.control,
        border: Border.all(color: colors.warning),
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
              color: colors.warning,
              borderRadius: MechXRadii.small,
            ),
          ),
          Text(
            'Set drawing scale to measure runs',
            style: type.label.copyWith(color: colors.textPrimary),
          ),
        ],
      ),
    );
  }
}

/// A one-shot entrance: scales from ~0.94 → 1.0 and fades 0 → 1 over
/// [MechXMotion.appear] the first (and only) time it's built. Transient motion
/// — no at-rest pixel change once settled.
class _EntranceScaleFade extends StatelessWidget {
  final Widget child;
  final Alignment alignment;
  const _EntranceScaleFade({
    required this.child,
    this.alignment = Alignment.center,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: MechXMotion.appear,
      curve: MechXMotion.standard,
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.scale(
          scale: 0.94 + 0.06 * t,
          alignment: alignment,
          child: child,
        ),
      ),
    );
  }
}
