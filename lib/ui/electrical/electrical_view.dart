/// The Electrical ("E") workspace — a single-line SPATIAL CANVAS, a faithful
/// port of PanelMaker's `BuildingSingleLine.tsx`. Panels are boxes on a
/// pannable / zoomable canvas wired by feeder lines, with each panel's loads
/// hanging below it and zoom-driven level-of-detail (summary card → full
/// internal R-S-T busbar). A left Loads palette drops ways onto panels (or
/// floating loads onto blank canvas), double-click edits, right-click opens a
/// context menu, dragging a panel's outlet onto another panel creates a feeder,
/// and the view has a toolbar (Issues / Service & Earthing / Add panel /
/// Import / Export), Single-line / Power-one-line tabs, a minimap, zoom
/// controls and a gesture-help legend.
///
/// The interactive editing surfaces (the circuit inspector drawer, the context
/// menus) and the read-only A8 advanced study are reused here. Styled entirely
/// with MechXTheme — no Material; overlays are a `Stack` layer + the root
/// `Overlay`. The pure A4 engine does all calculation; this widget reads its
/// result records and drives the store's edit intents.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/lightning.dart' show LpsLevelLabel;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/metering.dart' show MeteringKindLabel;
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/sources.dart'
    show GeneratorMode, GeneratorSource, GeneratorTransfer;
import 'package:mechx_engine/electrical/spd.dart' show SpdTypeLabel;
import 'package:mechx_engine/electrical/supply_design.dart' show SupplyLevel;
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/units.dart';

import '../../store/electrical_feed.dart';
import '../../store/electrical_focus_store.dart';
import '../../store/electrical_store.dart';
import '../../store/project_store.dart';
import '../canvas/zoom_controls.dart';
import '../strings/app_strings.dart';
import '../strings/plural.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/glass_surface.dart';
import '../widgets/canvas_guide_popover.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_empty_state_card.dart';
import '../widgets/mechx_segment.dart';
import '../widgets/severity_glyph.dart';
import 'electrical_canvas.dart';
import 'electrical_controls.dart';
import 'electrical_export.dart';
import 'electrical_format.dart';
import 'panel_geometry.dart';
import 'power_oneline_view.dart';
import 'sld_sheet_painter.dart';

/// Identifies the circuit currently open in the inspector / context menu.
class _CircuitRef {
  final String panelId;
  final String circuitId;
  const _CircuitRef(this.panelId, this.circuitId);
}

/// Which tab the workspace shows. (Spatial placement on the PDF moved to the
/// unified Layout canvas — the Electrical layer there — so these are the
/// abstract projections of the SAME solved model.)
///
///  • [singleLine]   — the interactive per-panel spatial single-line canvas
///    (zoom out for the whole-building tree: essential boards + feeders read
///    red, feeders carry their cable + breaker — the old Overview, folded in);
///  • [powerOneLine] — the hybrid power one-line (sources / MV / tx / busses);
///  • [riser]        — the floor-by-floor building riser (panels stacked by
///    true building elevation, vertical riser feeders), via
///    `buildElectricalRiser` over the live mechanical [BuildingLevels].
///
/// [riser] is a READ-ONLY render of the same `SldSheet` geometry the PDF / DXF
/// exporters draw — one source of truth, no parallel layout. (The compact
/// whole-building Overview remains an EXPORT — 'Building single-line (overview)'
/// — but no longer a redundant tab now the single-line canvas covers it.)
enum _Tab { singleLine, powerOneLine, riser }

/// Renders the electrical single-line canvas and hosts the editing overlays.
class ElectricalView extends ConsumerStatefulWidget {
  const ElectricalView({super.key});

  @override
  ConsumerState<ElectricalView> createState() => _ElectricalViewState();
}

class _ElectricalViewState extends ConsumerState<ElectricalView> {
  final GlobalKey<ElectricalCanvasState> _canvasKey =
      GlobalKey<ElectricalCanvasState>();
  final GlobalKey<SldSheetViewState> _riserKey =
      GlobalKey<SldSheetViewState>();

  _Tab _tab = _Tab.singleLine;

  // The circuit / panel open in the inline inspector column moved OUT of this
  // State to `electricalInspectorTargetProvider` (C1/C4) so the SIBLING
  // inspector column — rendered by the shared shell scaffold — reads + drives
  // the same target the canvas opens. This view only SETS the provider (on
  // double-click / context-menu Edit / +Way flows) and clears it (Esc / Close).

  /// An open right-click context menu (panel or circuit) + its anchor.
  _PanelMenuState? _panelMenu;
  _CircuitRef? _circuitMenu;
  Offset _menuAt = Offset.zero;

  /// Whether the advanced-study drawer is open.
  bool _showAdvanced = false;

  /// Whether the gesture-help popover is open.
  bool _showHelp = false;

  /// Whether the Service & Earthing inspector is open.
  bool _showService = false;

  /// Whether the Sources editor (genset / capacitor / transformer) is open.
  bool _showSources = false;

  /// Whether the Export menu (SLD / report / power one-line) is open.
  bool _showExportMenu = false;

  /// The single-line canvas's live viewport (transform + size), published by
  /// the canvas so the minimap (I8) can draw a truthful viewport rectangle and
  /// pan-to-tap. A [ValueNotifier] so a pan repaints only the minimap, not the
  /// whole view.
  final ValueNotifier<CanvasViewport?> _viewport = ValueNotifier(null);

  @override
  void dispose() {
    _viewport.dispose();
    super.dispose();
  }

  ElectricalProjectController get _controller =>
      ref.read(electricalProjectProvider.notifier);

  void _closeOverlays() {
    ref.read(electricalInspectorTargetProvider.notifier).clear();
    if (_panelMenu != null || _circuitMenu != null) {
      setState(() {
        _panelMenu = null;
        _circuitMenu = null;
      });
    }
  }

  /// Close the export menu and run the chosen export action against the live
  /// providers (the file dialog + IO live in `electrical_export.dart`).
  void _runExport(Future<void> Function(WidgetRef) action) {
    setState(() => _showExportMenu = false);
    action(ref);
  }

  /// G4 — the electrical-workspace Esc ladder. Bubbles up from the canvas's own
  /// Focus (which clears any canvas selection first), then closes the topmost
  /// open overlay: a context menu → the export popover → an open inspector /
  /// drawer → the gesture-help popover. Every close path already exists as a
  /// `setState`; this just gives them a keyboard exit (they previously closed
  /// only by scrim / button). Non-Esc keys / an all-closed workspace bubble on.
  KeyEventResult _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    if (_panelMenu != null || _circuitMenu != null) {
      setState(() {
        _panelMenu = null;
        _circuitMenu = null;
      });
      return KeyEventResult.handled;
    }
    if (_showExportMenu) {
      setState(() => _showExportMenu = false);
      return KeyEventResult.handled;
    }
    final hasEdit = ref.read(electricalInspectorTargetProvider) != null;
    if (hasEdit || _showService || _showSources || _showAdvanced) {
      ref.read(electricalInspectorTargetProvider.notifier).clear();
      setState(() {
        _showService = false;
        _showSources = false;
        _showAdvanced = false;
      });
      return KeyEventResult.handled;
    }
    if (_showHelp) {
      setState(() => _showHelp = false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// G5 — the Issues-drawer "locate" action: close the advanced drawer, switch
  /// to the single-line canvas (the only tab hosting the interactive board
  /// schedule), and frame + select the offending panel / way. Mirrors the
  /// Review -> Electrical jump seam already wired in this file.
  void _locateWarning(String panelId, String? circuitId) {
    setState(() {
      _showAdvanced = false;
      if (_tab != _Tab.singleLine) _tab = _Tab.singleLine;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _canvasKey.currentState?.focusIssue(panelId, circuitId: circuitId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final result = ref.watch(electricalResultProvider);
    final project = ref.watch(electricalProjectProvider);
    final advanced = ref.watch(electricalAdvancedProvider);

    // The Review → Electrical jump seam: a located issue hands a panel id (and,
    // when the issue pinpoints one, a circuit/way id — H7) via
    // electricalFocusProvider; consume it once — switch to the single-line tab,
    // frame that panel's board schedule, SELECT the exact way when known, and
    // clear the request.
    ref.listen(electricalFocusProvider, (prev, req) {
      if (req == null) return;
      if (_tab != _Tab.singleLine) setState(() => _tab = _Tab.singleLine);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final circuitId = req.circuitId;
        if (circuitId != null) {
          // Frame the board AND ring the exact way — focusIssue drives the
          // single-line canvas's OWN selection (the same path G5's Issues drawer
          // uses), unlike electricalSelectionProvider which only the Layout
          // layer consumes (a no-op on the single-line tab this jump lands on).
          _canvasKey.currentState?.focusIssue(req.panelId, circuitId: circuitId);
        } else {
          _canvasKey.currentState?.focusPanelSchedule(req.panelId);
        }
        ref.read(electricalFocusProvider.notifier).clear();
      });
    });

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Toolbar(
          warningCount: result.warnings.length,
          tab: _tab,
          onTab: (t) => setState(() => _tab = t),
          onIssues: () => setState(() => _showAdvanced = false),
          onService: _openService,
          onSources: _openSources,
          onAddPanel: _addPanel,
          onExport: () => setState(() => _showExportMenu = !_showExportMenu),
          onToggleAdvanced: () =>
              setState(() => _showAdvanced = !_showAdvanced),
          advancedOpen: _showAdvanced,
        ),
        Expanded(
          child: switch (_tab) {
            _Tab.singleLine => _buildCanvasArea(project, result),
            _Tab.powerOneLine => PowerOneLineView(
              oneLine: advanced.powerOneLine,
            ),
            _Tab.riser => _buildRiserArea(project, result),
          },
        ),
      ],
    );

    return Focus(
      // A bubble-phase Esc listener that never steals focus from the canvas
      // (which keeps its own key handling for selection / Delete / undo); Esc
      // bubbles up here when the focused descendant ignores it — G4.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) => _onKeyEvent(event),
      child: Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(color: colors.canvas, child: body),
        ),
        // Tap-away scrim behind any open menu / export popover. (The circuit /
        // panel editors no longer float here — they live in the sibling inline
        // inspector column, closed via its Close button or Esc.)
        if (_panelMenu != null || _circuitMenu != null || _showExportMenu)
          Positioned.fill(
            child: Listener(
              onPointerDown: (_) {
                _closeOverlays();
                if (_showExportMenu) setState(() => _showExportMenu = false);
              },
              behavior: HitTestBehavior.translucent,
              child: const SizedBox.expand(),
            ),
          ),
        if (_showExportMenu)
          Positioned(
            top: 48,
            right: MechXSpacing.md,
            child: _ExportMenu(
              onSld: () => _runExport(exportElectricalSldDxf),
              onSldPdf: () => _runExport(exportElectricalSldPdf),
              onSchedulesPdf: () =>
                  _runExport(exportElectricalPanelSchedulesPdf),
              onOverviewPdf: () => _runExport(exportElectricalOverviewPdf),
              onOverviewDxf: () => _runExport(exportElectricalOverviewDxf),
              onRiserPdf: () => _runExport(exportElectricalRiserPdf),
              onRiserDxf: () => _runExport(exportElectricalRiserDxf),
              onReport: () => _runExport(exportElectricalCalcReport),
              onPowerOneLine: () => _runExport(exportPowerOneLineDxf),
              onPowerOneLinePdf: () => _runExport(exportPowerOneLinePdf),
            ),
          ),
        if (_circuitMenu != null) _buildCircuitMenu(),
        if (_panelMenu != null) _buildPanelMenu(),
        if (_showAdvanced)
          _AdvancedDrawer(
            advanced: advanced,
            result: result,
            onClose: () => setState(() => _showAdvanced = false),
            onLocate: _locateWarning,
          ),
        if (_showService)
          _ServiceInspector(
            onClose: () => setState(() => _showService = false),
          ),
        if (_showSources)
          _SourcesEditor(
            onClose: () => setState(() => _showSources = false),
          ),
      ],
      ),
    );
  }

  Widget _buildCanvasArea(
    ElectricalProject project,
    ElectricalSystemResult result,
  ) {
    // The Loads palette + the circuit/panel editors now live in the shared
    // collapsible inspector column (a sibling in the shell scaffold), NOT baked
    // into this canvas row — so the electrical workspace's frame matches the
    // mechanical Layout/Riser. The canvas fills the whole area here.
    return Stack(
            children: [
              Positioned.fill(
                child: ElectricalCanvas(
                  key: _canvasKey,
                  viewport: _viewport,
                  // Panel double-click opens the panel PROPERTIES editor
                  // (name / tag / diversity / headroom) in the inspector column;
                  // a way row double-click opens the circuit editor there.
                  onEditPanel: (panelId) => ref
                      .read(electricalInspectorTargetProvider.notifier)
                      .editPanel(panelId),
                  onEditCircuit: (panelId, circuitId) => ref
                      .read(electricalInspectorTargetProvider.notifier)
                      .editCircuit(panelId, circuitId),
                  onPanelMenu: _openPanelMenu,
                  onCircuitMenu: (panelId, circuitId, gp) => setState(() {
                    _circuitMenu = _CircuitRef(panelId, circuitId);
                    _menuAt = _toLocal(gp);
                  }),
                  onRequestService: _openService,
                  onRequestSources: _openSources,
                ),
              ),
              // Zoom controls (bottom-left).
              Positioned(
                left: MechXSpacing.md,
                bottom: MechXSpacing.md,
                child: ZoomControls(
                  onIn: () => _canvasKey.currentState?.zoomIn(),
                  onOut: () => _canvasKey.currentState?.zoomOut(),
                  onFit: () => _canvasKey.currentState?.fitView(),
                ),
              ),
              // Minimap (bottom-right) — tracks the live viewport + dragged
              // panels, and pans the canvas on tap (I8).
              Positioned(
                right: MechXSpacing.md,
                bottom: MechXSpacing.md,
                child: ValueListenableBuilder<CanvasViewport?>(
                  valueListenable: _viewport,
                  builder: (context, vp, _) => _MiniMap(
                    project: project,
                    result: result,
                    viewport: vp,
                    onCentre: (world) =>
                        _canvasKey.currentState?.centreOn(world),
                  ),
                ),
              ),
              // Gesture-help (?) (top-left).
              Positioned(
                left: MechXSpacing.md,
                top: MechXSpacing.sm,
                child: CanvasGuideButton(
                  open: _showHelp,
                  onToggle: () => setState(() => _showHelp = !_showHelp),
                ),
              ),
              if (_showHelp)
                Positioned(
                  left: MechXSpacing.md,
                  top: 48,
                  child: CanvasGuideLegend(
                    items: [
                      context.strings(StringKey.electricalGuide1),
                      context.strings(StringKey.electricalGuide2),
                      context.strings(StringKey.electricalGuide3),
                      context.strings(StringKey.electricalGuide4),
                      context.strings(StringKey.electricalGuide5),
                      context.strings(StringKey.electricalGuide6),
                      context.strings(StringKey.electricalGuide7),
                    ],
                    onClose: () => setState(() => _showHelp = false),
                  ),
                ),
              // Empty-state setup card.
              if (project.panels.isEmpty)
                Positioned.fill(
                  child: Center(
                    child: _EmptyState(
                      onSetUp: _openService,
                      onAddPanel: _addPanel,
                      onLoadSample: _controller.resetToSample,
                    ),
                  ),
                ),
            ],
    );
  }

  /// The FLOOR-BY-FLOOR building riser, rendered LIVE from
  /// [buildElectricalRiser] over the live mechanical [BuildingLevels] (the
  /// shared §10 geometry — panels stacked by true floor elevation). Read-only.
  Widget _buildRiserArea(
    ElectricalProject project,
    ElectricalSystemResult result,
  ) {
    final building = ref.watch(projectControllerProvider).building;
    final sheet = buildElectricalRiser(
      project: project,
      result: result,
      building: building,
    );
    return _SldProjectionArea(
      sheetKey: _riserKey,
      sheet: sheet,
      empty: project.panels.isEmpty,
      onSetUp: _openService,
      onAddPanel: _addPanel,
      onLoadSample: _controller.resetToSample,
    );
  }

  // ── Geometry helpers ────────────────────────────────────────────────────────

  Offset _toLocal(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    return box?.globalToLocal(global) ?? global;
  }

  // ── Edit-intent wiring ──────────────────────────────────────────────────────

  void _addPanel() {
    // G8 — mint the first FREE SP-N ordinal (max+1 across existing names AND
    // tags), so deleting a board never lets a later add re-mint its
    // designation onto an issued schedule.
    final n = nextSubPanelOrdinal(ref.read(electricalProjectProvider).panels);
    _controller.addPanelAt(
      name: 'Sub-panel $n',
      tag: 'SP-$n',
      x: 80 + n * 40,
      y: 80 + n * 40,
    );
  }

  void _openService() {
    ref.read(electricalInspectorTargetProvider.notifier).clear();
    setState(() {
      _panelMenu = null;
      _circuitMenu = null;
      _showAdvanced = false;
      _showSources = false;
      _showService = true;
    });
  }

  void _openSources() {
    ref.read(electricalInspectorTargetProvider.notifier).clear();
    setState(() {
      _panelMenu = null;
      _circuitMenu = null;
      _showAdvanced = false;
      _showService = false;
      _showSources = true;
    });
  }

  void _openPanelMenu(String panelId, Offset globalPos) {
    setState(() {
      _panelMenu = _PanelMenuState(panelId);
      _circuitMenu = null;
      _menuAt = _toLocal(globalPos);
    });
  }

  // ── Overlays ────────────────────────────────────────────────────────────────

  Widget _buildCircuitMenu() {
    final ref0 = _circuitMenu!;
    return Positioned(
      left: _menuAt.dx,
      top: _menuAt.dy,
      child: ElectricalMenu(
        items: [
          ElectricalMenuAction(
            context.strings(StringKey.electricalMenuEdit),
            () {
              ref
                  .read(electricalInspectorTargetProvider.notifier)
                  .editCircuit(ref0.panelId, ref0.circuitId);
              setState(() => _circuitMenu = null);
            },
          ),
          ElectricalMenuAction(context.strings(StringKey.electricalMenuDuplicate),
              () {
            _controller.duplicateCircuit(ref0.panelId, ref0.circuitId);
            setState(() => _circuitMenu = null);
          }),
          ElectricalMenuAction(context.strings(StringKey.electricalMenuDelete),
              () {
            _controller.deleteCircuit(ref0.panelId, ref0.circuitId);
            setState(() => _circuitMenu = null);
          }, danger: true),
        ],
      ),
    );
  }

  Widget _buildPanelMenu() {
    final menu = _panelMenu!;
    final project = ref.read(electricalProjectProvider);
    final panel = project.panels.where((p) => p.id == menu.panelId).firstOrNull;
    if (panel == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _closeOverlays());
      return const SizedBox.shrink();
    }
    return Positioned(
      left: _menuAt.dx,
      top: _menuAt.dy,
      child: ElectricalMenu(
        items: [
          ElectricalMenuAction(
              context.strings(StringKey.electricalPanelProperties), () {
            ref
                .read(electricalInspectorTargetProvider.notifier)
                .editPanel(panel.id);
            setState(() => _panelMenu = null);
          }),
          ElectricalMenuAction(
              context.strings(StringKey.electricalMenuOpenPanel), () {
            final first = panel.circuits
                .where((c) => c.loadKind != LoadKind.feeder)
                .firstOrNull;
            if (first != null) {
              ref
                  .read(electricalInspectorTargetProvider.notifier)
                  .editCircuit(panel.id, first.id);
            }
            setState(() => _panelMenu = null);
          }),
          ElectricalMenuAction(
            context.strings(panel.essential
                ? StringKey.electricalMenuUnmarkEssential
                : StringKey.electricalMenuMarkEssential),
            () {
              _controller.setPanelEssential(panel.id, !panel.essential);
              setState(() => _panelMenu = null);
            },
          ),
          ElectricalMenuAction(
            context.strings(panel.upsBacked
                ? StringKey.electricalMenuUnmarkCritical
                : StringKey.electricalMenuMarkCritical),
            () {
              _controller.setPanelUpsBacked(panel.id, !panel.upsBacked);
              setState(() => _panelMenu = null);
            },
          ),
          ElectricalMenuAction(
              context.strings(panel.submeter
                  ? StringKey.electricalMenuRemoveSubmeter
                  : StringKey.electricalMenuAddSubmeter), () {
            _controller.setPanelSubmeter(panel.id, !panel.submeter);
            setState(() => _panelMenu = null);
          }),
          // Duplicate the whole board (fresh ids, undoable one step — I5).
          ElectricalMenuAction(
              context.strings(StringKey.electricalMenuDuplicatePanel), () {
            _controller.duplicatePanel(panel.id);
            setState(() => _panelMenu = null);
          }),
          if (panel.fedByCircuitId != null)
            ElectricalMenuAction(
                context.strings(StringKey.electricalMenuDisconnectFeeder), () {
              _controller.disconnectFeeder(panel.id);
              setState(() => _panelMenu = null);
            }),
          ElectricalMenuAction(
              context.strings(StringKey.electricalMenuDeletePanel), () {
            _controller.deletePanel(panel.id);
            setState(() => _panelMenu = null);
          }, danger: true),
        ],
      ),
    );
  }

}

class _PanelMenuState {
  final String panelId;
  const _PanelMenuState(this.panelId);
}

// ── Toolbar ───────────────────────────────────────────────────────────────────

class _Toolbar extends StatelessWidget {
  final int warningCount;
  final _Tab tab;
  final ValueChanged<_Tab> onTab;
  final VoidCallback onIssues;
  final VoidCallback onService;
  final VoidCallback onSources;
  final VoidCallback onAddPanel;
  final VoidCallback onExport;
  final VoidCallback onToggleAdvanced;
  final bool advancedOpen;

  const _Toolbar({
    required this.warningCount,
    required this.tab,
    required this.onTab,
    required this.onIssues,
    required this.onService,
    required this.onSources,
    required this.onAddPanel,
    required this.onExport,
    required this.onToggleAdvanced,
    required this.advancedOpen,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return GlassSurface(
      edge: Border(
          bottom:
              BorderSide(color: colors.glassEdge, width: MechXGlass.edgeWidth)),
      child: Padding(
        padding: const EdgeInsets.symmetric(
        horizontal: MechXSpacing.md,
        vertical: MechXSpacing.sm,
      ),
      child: Row(
        children: [
          // Tabs (left) — the shared selectable-segment vocabulary.
          MechXSegment(
            label: context.strings(StringKey.electricalTabSingleLine),
            selected: tab == _Tab.singleLine,
            onTap: () => onTab(_Tab.singleLine),
          ),
          const SizedBox(width: MechXSpacing.xs),
          MechXSegment(
            label: context.strings(StringKey.electricalTabPowerOneLine),
            selected: tab == _Tab.powerOneLine,
            onTap: () => onTab(_Tab.powerOneLine),
          ),
          const SizedBox(width: MechXSpacing.xs),
          MechXSegment(
            // 'Building riser' — disambiguated from the nav rail's mechanical
            // Riser view (one word must not name two destinations).
            label: context.strings(StringKey.electricalTabBuildingRiser),
            selected: tab == _Tab.riser,
            onTap: () => onTab(_Tab.riser),
          ),
          // Actions (right). The canonical MechXButton "gray button"; danger /
          // muted tones only recolour the label.
          //
          // B9: this used to be a `Spacer()` (an `Expanded` doing nothing)
          // FOLLOWED BY a `Flexible` holding a horizontally-scrolling Row —
          // two flex:1 siblings splitting the free width 50/50, so the
          // actions got only HALF the room they were actually owed, and (with
          // `reverse: true` anchoring its scroll offset at the END) whichever
          // button that squeeze cut into painted only a sliver at the clip
          // boundary (golden 11's stray fragment "near the tabs"). A single
          // `Expanded` now claims ALL the leftover width for the actions
          // (right-aligned via `Align`, so it still hugs the trailing edge
          // when everything fits), and a `Wrap` can't silently clip a child
          // either way: any button that doesn't fit the remaining width on
          // this line simply flows onto a second line, still right-aligned
          // and always shown in FULL. The toolbar grows a little taller on a
          // narrow window instead of hiding a fragment of a button (the
          // Column above wraps a plain `Expanded` canvas below, so a taller
          // toolbar just costs it a few px, never overflows).
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                alignment: WrapAlignment.end,
                runAlignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: MechXSpacing.xs,
                runSpacing: MechXSpacing.xs,
                children: [
                  MechXButton(
                    // B2 — this count is ELECTRICAL-ONLY (result.warnings for
                    // the electrical system). The StringKey values are now
                    // SCOPED ('Electrical issues' / 'Masalah kelistrikan') so
                    // the label can't be conflated with the nav Review badge
                    // (all OPEN issues, every discipline) or the Review hub's
                    // all-count, both on-screen at the same time — while
                    // keeping the ID translation (localized via
                    // context.strings, not a literal).
                    label: warningCount > 0
                        ? context.strings.format(
                            StringKey.electricalToolbarIssuesCount,
                            {'n': warningCount})
                        : context.strings(StringKey.electricalToolbarIssues),
                    tone: warningCount > 0
                        ? MechXButtonTone.danger
                        : MechXButtonTone.normal,
                    onPressed: onToggleAdvanced,
                  ),
                  MechXButton(
                    label:
                        context.strings(StringKey.electricalServiceEarthing),
                    onPressed: onService,
                  ),
                  MechXButton(
                    label: context.strings(StringKey.electricalSources),
                    onPressed: onSources,
                  ),
                  MechXButton(
                    label: context.strings(StringKey.electricalAddPanel),
                    onPressed: onAddPanel,
                  ),
                  MechXButton(
                    // J4 — Export is the deliverable action; it reads in the
                    // normal (primary-label) tone like the mechanical export
                    // buttons, not the muted/disabled-looking grey it used to.
                    label: context.strings(StringKey.electricalExport),
                    onPressed: onExport,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }
}

// ── Canvas chrome (zoom, minimap, help) ─────────────────────────────────────

/// The Export popover (anchored under the toolbar's Export button) — single-line
/// DXF, electrical report (Markdown) and power one-line DXF.
class _ExportMenu extends StatelessWidget {
  final VoidCallback onSld;
  final VoidCallback onSldPdf;
  final VoidCallback onSchedulesPdf;
  final VoidCallback onOverviewPdf;
  final VoidCallback onOverviewDxf;
  final VoidCallback onRiserPdf;
  final VoidCallback onRiserDxf;
  final VoidCallback onReport;
  final VoidCallback onPowerOneLine;
  final VoidCallback onPowerOneLinePdf;
  const _ExportMenu({
    required this.onSld,
    required this.onSldPdf,
    required this.onSchedulesPdf,
    required this.onOverviewPdf,
    required this.onOverviewDxf,
    required this.onRiserPdf,
    required this.onRiserDxf,
    required this.onReport,
    required this.onPowerOneLine,
    required this.onPowerOneLinePdf,
  });

  @override
  Widget build(BuildContext context) {
    // Pop-in: a brief scale-from-95% + fade, anchored at the top-right corner
    // (under the Export button), so the popover feels like it grows from there.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: MechXMotion.appear,
      curve: MechXMotion.standard,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.scale(
          scale: 0.95 + 0.05 * t,
          alignment: Alignment.topRight,
          child: child,
        ),
      ),
      child: SizedBox(
        width: 260,
        child: GlassSurface(
          borderRadius: MechXRadii.card,
          blurSigma: MechXGlass.blurSigmaLight,
          shadow: MechXShadow.popover,
          child: Padding(
            padding: const EdgeInsets.all(MechXSpacing.xs),
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _ExportRow(
              label: context.strings(StringKey.electricalExportSld),
              sub: context.strings(StringKey.electricalExportSldDxf),
              onTap: onSld,
            ),
            _ExportRow(
              label: context.strings(StringKey.electricalExportSld),
              sub: context.strings(StringKey.electricalExportSldPdf),
              onTap: onSldPdf,
            ),
            // The issuable schedule SET — one board schedule per page, real
            // `Sheet i of t` counters (C1 pagination).
            _ExportRow(
              label: context.strings(StringKey.electricalExportSchedules),
              sub: context.strings(StringKey.electricalExportSchedulesPdf),
              onTap: onSchedulesPdf,
            ),
            _ExportRow(
              label: context.strings(StringKey.electricalExportOverview),
              sub: context.strings(StringKey.electricalExportOverviewPdf),
              onTap: onOverviewPdf,
            ),
            _ExportRow(
              label: context.strings(StringKey.electricalExportOverview),
              sub: context.strings(StringKey.electricalExportOverviewDxf),
              onTap: onOverviewDxf,
            ),
            _ExportRow(
              label: context.strings(StringKey.electricalExportRiser),
              sub: context.strings(StringKey.electricalExportRiserPdf),
              onTap: onRiserPdf,
            ),
            _ExportRow(
              label: context.strings(StringKey.electricalExportRiser),
              sub: context.strings(StringKey.electricalExportRiserDxf),
              onTap: onRiserDxf,
            ),
            _ExportRow(
              label: context.strings(StringKey.electricalExportReport),
              sub: context.strings(StringKey.electricalExportReportSub),
              onTap: onReport,
            ),
            _ExportRow(
              label: context.strings(StringKey.electricalExportPowerOneLine),
              sub: context.strings(StringKey.electricalExportPowerOneLineSub),
              onTap: onPowerOneLine,
            ),
            // C7 — the PDF companion (same shared SldSheet geometry as the DXF).
            // Reuses the generic 'PDF (vector)' string; a dedicated
            // power-one-line-PDF key is owned by app_strings.dart (see followUps).
            _ExportRow(
              label: context.strings(StringKey.electricalExportPowerOneLine),
              sub: context.strings(StringKey.electricalExportSldPdf),
              onTap: onPowerOneLinePdf,
            ),
          ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ExportRow extends StatefulWidget {
  final String label;
  final String sub;
  final VoidCallback onTap;
  const _ExportRow({
    required this.label,
    required this.sub,
    required this.onTap,
  });

  @override
  State<_ExportRow> createState() => _ExportRowState();
}

class _ExportRowState extends State<_ExportRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: MechXMotion.hover,
          curve: MechXMotion.standard,
          padding: const EdgeInsets.symmetric(
            horizontal: MechXSpacing.sm,
            vertical: MechXSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: _hover ? colors.surfaceHover : const Color(0x00000000),
            borderRadius: MechXRadii.control,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                style: type.label.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: 2),
              Text(
                widget.sub,
                style: type.caption.copyWith(color: colors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The minimap frame size (the paint box, so the widget + painter agree on the
/// world↔minimap mapping for the tap hit-test).
const Size _kMiniMapSize = Size(150, 100);

/// The minimap-space mapping of the panel layout — the SAME `resolvePanelPositions`
/// the canvas uses (so it tracks DRAGGED panels, not the auto-layout only, I8).
/// Exposes `toMini` / `toWorld` so the painter draws + the widget hit-tests
/// through one geometry.
class _MiniMapGeometry {
  final double minX, minY, scale, ox, oy;
  const _MiniMapGeometry(this.minX, this.minY, this.scale, this.ox, this.oy);

  static const double _padX = 80, _padY = 60;

  static _MiniMapGeometry? of(Map<String, Offset> positions, Size size) {
    if (positions.isEmpty || size.isEmpty) return null;
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    positions.forEach((id, p) {
      minX = minX < p.dx ? minX : p.dx;
      minY = minY < p.dy ? minY : p.dy;
      maxX = maxX > p.dx ? maxX : p.dx;
      maxY = maxY > p.dy ? maxY : p.dy;
    });
    final spanX = (maxX - minX).abs() + 200;
    final spanY = (maxY - minY).abs() + 160;
    final scale = (size.width / spanX).clamp(0.0, size.height / spanY) * 0.9;
    final ox = (size.width - spanX * scale) / 2;
    final oy = (size.height - spanY * scale) / 2;
    return _MiniMapGeometry(minX, minY, scale, ox, oy);
  }

  Offset toMini(Offset world) => Offset(
        ox + (world.dx - minX + _padX) * scale,
        oy + (world.dy - minY + _padY) * scale,
      );

  Offset toWorld(Offset mini) => Offset(
        (mini.dx - ox) / scale + minX - _padX,
        (mini.dy - oy) / scale + minY - _padY,
      );
}

/// A small minimap (bottom-right): every panel as a coloured rectangle, the live
/// viewport as an outlined rectangle, and a tap pans the canvas to that point.
class _MiniMap extends StatelessWidget {
  final ElectricalProject project;
  final ElectricalSystemResult result;
  final CanvasViewport? viewport;
  final ValueChanged<Offset> onCentre;
  const _MiniMap({
    required this.project,
    required this.result,
    required this.viewport,
    required this.onCentre,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final positions = resolvePanelPositions(project, result);
    final geo = _MiniMapGeometry.of(positions, _kMiniMapSize);
    return SizedBox.fromSize(
      size: _kMiniMapSize,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: MechXRadii.control,
          border: Border.all(color: colors.border),
          boxShadow: MechXShadow.card,
        ),
        child: ClipRRect(
          borderRadius: MechXRadii.control,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              if (geo == null) return;
              onCentre(geo.toWorld(d.localPosition));
            },
            child: CustomPaint(
              painter: _MiniMapPainter(
                positions: positions,
                viewport: viewport,
                accent: colors.accent,
                muted: colors.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniMapPainter extends CustomPainter {
  final Map<String, Offset> positions;
  final CanvasViewport? viewport;
  final Color accent;
  final Color muted;
  _MiniMapPainter({
    required this.positions,
    required this.viewport,
    required this.accent,
    required this.muted,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final geo = _MiniMapGeometry.of(positions, size);
    if (geo == null) return;
    positions.forEach((id, p) {
      final at = geo.toMini(p);
      canvas.drawRect(
          Rect.fromLTWH(at.dx, at.dy, 14, 8), Paint()..color = accent);
    });
    // The live viewport rectangle — the world region on screen, mapped through
    // the same minimap geometry (I8). Skipped until the canvas has a viewport.
    final vp = viewport;
    if (vp != null && !vp.size.isEmpty) {
      final tl = geo.toMini(vp.transform.screenToWorld(Offset.zero));
      final br = geo.toMini(
          vp.transform.screenToWorld(vp.size.bottomRight(Offset.zero)));
      final rect = Rect.fromPoints(tl, br);
      canvas.drawRect(
        rect,
        Paint()
          ..color = muted
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
  }

  @override
  bool shouldRepaint(_MiniMapPainter old) =>
      old.positions != positions ||
      old.viewport != viewport ||
      old.accent != accent ||
      old.muted != muted;
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback onSetUp;
  final VoidCallback onAddPanel;
  final VoidCallback onLoadSample;
  const _EmptyState({
    required this.onSetUp,
    required this.onAddPanel,
    required this.onLoadSample,
  });

  @override
  Widget build(BuildContext context) {
    // The shared branded empty-state card (matching the mechanical Layout
    // canvas's), with the two service set-up actions plus the explicit
    // "Load sample project" secondary action (A2 — the sample switchboard is
    // never auto-seeded; it lives one click away here). MechXEmptyStateCard
    // hosts the actions in a Wrap itself, so the buttons are passed directly
    // (no Expanded — which is invalid inside a Wrap) and flow to a second line
    // inside the 360-px card rather than overflowing.
    return Padding(
      padding: const EdgeInsets.all(MechXSpacing.lg),
      child: MechXEmptyStateCard(
        title: context.strings(StringKey.electricalEmptyTitle),
        body: context.strings(StringKey.electricalEmptyBody),
        actions: [
          MechXButton(
            label: context.strings(StringKey.electricalAddPanel),
            onPressed: onAddPanel,
          ),
          MechXButton(
            label: context.strings(StringKey.electricalServiceEarthing),
            onPressed: onSetUp,
          ),
          MechXButton(
            label: context.strings(StringKey.electricalLoadSampleProject),
            onPressed: onLoadSample,
          ),
        ],
      ),
    );
  }
}

// ── Read-only SldSheet projection (Overview / Riser) ────────────────────────

/// Hosts a read-only [SldSheetView] (the Overview / Riser projection) with the
/// shared on-canvas chrome: the zoom cluster (bottom-left) driving the sheet's
/// imperative zoom API, and the branded empty-state card when there are no
/// panels yet. The same layout as the single-line canvas area minus the
/// interactive palette (these projections are renders, not editors).
class _SldProjectionArea extends StatelessWidget {
  final GlobalKey<SldSheetViewState> sheetKey;
  final SldSheet sheet;
  final bool empty;
  final VoidCallback onSetUp;
  final VoidCallback onAddPanel;
  final VoidCallback onLoadSample;

  const _SldProjectionArea({
    required this.sheetKey,
    required this.sheet,
    required this.empty,
    required this.onSetUp,
    required this.onAddPanel,
    required this.onLoadSample,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: SldSheetView(key: sheetKey, sheet: sheet)),
        Positioned(
          left: MechXSpacing.md,
          bottom: MechXSpacing.md,
          child: ZoomControls(
            onIn: () => sheetKey.currentState?.zoomIn(),
            onOut: () => sheetKey.currentState?.zoomOut(),
            onFit: () => sheetKey.currentState?.fitView(),
          ),
        ),
        if (empty)
          Positioned.fill(
            child: Center(
              child: _EmptyState(
                onSetUp: onSetUp,
                onAddPanel: onAddPanel,
                onLoadSample: onLoadSample,
              ),
            ),
          ),
      ],
    );
  }
}

// ── Animated drawer shell ───────────────────────────────────────────────────

/// A right-anchored sheet drawer: the modal scrim fades in over the content
/// (using the brightness-aware [MechXColors.scrim]) and the panel slides in
/// from the right + fades on mount (MechXMotion.appear), matching the iOS
/// sheet idiom. Tap the scrim to close. Reused by the Service & Earthing and
/// the Advanced-study drawers so both present identically.
class _AnimatedDrawerShell extends StatefulWidget {
  final double width;
  final VoidCallback onClose;
  final Widget child;
  const _AnimatedDrawerShell({
    required this.width,
    required this.onClose,
    required this.child,
  });

  @override
  State<_AnimatedDrawerShell> createState() => _AnimatedDrawerShellState();
}

class _AnimatedDrawerShellState extends State<_AnimatedDrawerShell> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            child: AnimatedOpacity(
              opacity: _shown ? 1 : 0,
              duration: MechXMotion.appear,
              curve: MechXMotion.standard,
              child: ColoredBox(color: colors.scrim),
            ),
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          bottom: 0,
          child: AnimatedSlide(
            offset: _shown ? Offset.zero : const Offset(1, 0),
            duration: MechXMotion.appear,
            curve: MechXMotion.standard,
            child: AnimatedOpacity(
              opacity: _shown ? 1 : 0,
              duration: MechXMotion.appear,
              curve: MechXMotion.standard,
              child: SizedBox(width: widget.width, child: widget.child),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Service inspector ─────────────────────────────────────────────────────────

class _ServiceInspector extends ConsumerWidget {
  final VoidCallback onClose;
  const _ServiceInspector({required this.onClose});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final project = ref.watch(electricalProjectProvider);
    final ctrl = ref.read(electricalProjectProvider.notifier);

    // G1 — the solved-duty MEP → electrical bridge. The equipment the mechanical
    // engine has already sized (pump / fan / fire-pump duties) surfaced as
    // electrical circuits the engineer would otherwise re-type. Off by default so
    // an untouched project never grows a phantom MEP panel.
    final duties = ref.watch(mepEquipmentLoadsProvider);
    final dutyFeedOn = ref.watch(mepDutyFeedEnabledProvider);

    return _AnimatedDrawerShell(
      width: 340,
      onClose: onClose,
      child: Container(
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(left: BorderSide(color: colors.border)),
          boxShadow: MechXShadow.popover,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MechXSpacing.md,
                MechXSpacing.md,
                MechXSpacing.md,
                MechXSpacing.sm + 4,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.strings(StringKey.electricalServiceEarthing),
                      style: type.title.copyWith(color: colors.textPrimary),
                    ),
                  ),
                  MechXButton(
                    label: context.strings(StringKey.electricalClose),
                    tertiary: true,
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
            Container(height: 1, color: colors.border),
            const SizedBox(height: MechXSpacing.xs),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(MechXSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ElectricalField(
                      label:
                          context.strings(StringKey.electricalFieldEarthingSystem),
                      child: ElectricalEnumPicker<EarthingSystem>(
                        value: project.earthingSystem,
                        options: EarthingSystem.values,
                        label: (e) => e.label,
                        onChanged: ctrl.setEarthingSystem,
                      ),
                    ),
                    Text(
                      project.earthingSystem.note,
                      style: type.caption.copyWith(color: colors.textMuted),
                    ),
                    const SizedBox(height: MechXSpacing.md),
                    ElectricalField(
                      label: context.strings(
                        StringKey.electricalOriginFaultLevel,
                      ),
                      child: ElectricalNumInput(
                        value: project.originFaultLevelA != null
                            ? project.originFaultLevelA!.amperes / 1000
                            : 16,
                        onChanged: (v) =>
                            ctrl.setOriginFaultLevel(Current(v * 1000)),
                      ),
                    ),
                    Text(
                      context.strings(StringKey.electricalOriginFaultLevelNote),
                      style: type.caption.copyWith(color: colors.textMuted),
                    ),
                    const SizedBox(height: MechXSpacing.md),
                    ElectricalField(
                      label: context.strings(
                        StringKey.electricalBusbarClearingTime,
                      ),
                      child: ElectricalNumInput(
                        value: project.busbarClearingTimeS ?? 0.1,
                        onChanged: ctrl.setBusbarClearingTime,
                      ),
                    ),
                    Text(
                      context.strings(
                        StringKey.electricalBusbarClearingTimeNote,
                      ),
                      style: type.caption.copyWith(color: colors.textMuted),
                    ),
                    const SizedBox(height: MechXSpacing.md),
                    Container(height: 1, color: colors.border),
                    const SizedBox(height: MechXSpacing.md),
                    // ── MEP equipment feed (G1) ──────────────────────────────
                    Text(
                      'MEP equipment feed',
                      style: type.label.copyWith(color: colors.textPrimary),
                    ),
                    const SizedBox(height: MechXSpacing.sm),
                    ElectricalToggleRow(
                      label: 'Add solved MEP duties to panel',
                      value: dutyFeedOn,
                      onChanged: (on) =>
                          ref.read(mepDutyFeedEnabledProvider.notifier).set(on),
                    ),
                    Text(
                      duties.isEmpty
                          ? 'No auto-sized pump / fan / fire-pump duty yet — '
                              'draw and size the mechanical systems first. '
                              'Equipment placed on the plan always feeds the '
                              'MEP Equipment panel.'
                          : 'Folds the app-sized ${duties.map((d) => d.name).join(', ')} '
                              'into the MEP Equipment panel as sized circuits — '
                              'no re-entry of the kW. Fire pumps carry life-safety '
                              'treatment. Placed equipment always feeds the panel.',
                      style: type.caption.copyWith(color: colors.textMuted),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Sources editor (genset / capacitor / transformer / dual-tx) ─────────────

/// Edit the SOURCE chain drawn above the panel tree (the overview / riser /
/// interactive single-line head + the PDF / DXF exports — one
/// `_buildSourceSpine` geometry). Genset present/rating/mode/transfer, the
/// installed capacitor bank (kvar), an explicit transformer rating (kVA), and
/// the dual-transformer split bus. All route through the store's
/// field-preserving `_withProject`; the capacitor / transformer are drawing
/// inputs only (// VERIFY, never a sizing path).
class _SourcesEditor extends ConsumerWidget {
  final VoidCallback onClose;
  const _SourcesEditor({required this.onClose});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final project = ref.watch(electricalProjectProvider);
    final ctrl = ref.read(electricalProjectProvider.notifier);
    final gen = project.sources?.generator;

    String genModeLabel(GeneratorMode m) => switch (m) {
          GeneratorMode.standby =>
            context.strings(StringKey.electricalGensetModeStandby),
          GeneratorMode.prime =>
            context.strings(StringKey.electricalGensetModePrime),
        };
    String genTransferLabel(GeneratorTransfer t) => switch (t) {
          GeneratorTransfer.ats =>
            context.strings(StringKey.electricalGensetTransferAts),
          GeneratorTransfer.manual =>
            context.strings(StringKey.electricalGensetTransferManual),
        };

    return _AnimatedDrawerShell(
      width: 340,
      onClose: onClose,
      child: Container(
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(left: BorderSide(color: colors.border)),
          boxShadow: MechXShadow.popover,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MechXSpacing.md,
                MechXSpacing.md,
                MechXSpacing.md,
                MechXSpacing.sm + 4,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.strings(StringKey.electricalSources),
                      style: type.title.copyWith(color: colors.textPrimary),
                    ),
                  ),
                  MechXButton(
                    label: context.strings(StringKey.electricalClose),
                    tertiary: true,
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
            Container(height: 1, color: colors.border),
            const SizedBox(height: MechXSpacing.xs),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(MechXSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── Genset ────────────────────────────────────────────
                    Text(
                      context.strings(StringKey.electricalGenset),
                      style: type.label.copyWith(color: colors.textPrimary),
                    ),
                    const SizedBox(height: MechXSpacing.sm),
                    ElectricalToggleRow(
                      label: context.strings(StringKey.electricalGensetPresent),
                      value: gen != null,
                      onChanged: (on) => ctrl
                          .setGenerator(on ? const GeneratorSource() : null),
                    ),
                    if (gen != null) ...[
                      ElectricalField(
                        label:
                            context.strings(StringKey.electricalGensetKva),
                        child: ElectricalNumInput(
                          value: gen.kva?.inKilovoltAmperes ?? 0,
                          onChanged: (v) => ctrl.setGeneratorKva(
                            v > 0 ? ApparentPower.kilovoltAmperes(v) : null,
                          ),
                        ),
                      ),
                      ElectricalField(
                        label:
                            context.strings(StringKey.electricalGensetMode),
                        child: ElectricalEnumPicker<GeneratorMode>(
                          value: gen.mode,
                          options: GeneratorMode.values,
                          label: genModeLabel,
                          onChanged: ctrl.setGeneratorMode,
                        ),
                      ),
                      ElectricalField(
                        label: context
                            .strings(StringKey.electricalGensetTransfer),
                        child: ElectricalEnumPicker<GeneratorTransfer>(
                          value: gen.transfer,
                          options: GeneratorTransfer.values,
                          label: genTransferLabel,
                          onChanged: ctrl.setGeneratorTransfer,
                        ),
                      ),
                    ],
                    const SizedBox(height: MechXSpacing.sm),
                    Container(height: 1, color: colors.border),
                    const SizedBox(height: MechXSpacing.md),
                    // ── Transformer ──────────────────────────────────────
                    ElectricalField(
                      label:
                          context.strings(StringKey.electricalTransformerKva),
                      child: ElectricalNumInput(
                        value: project.transformerKva?.inKilovoltAmperes ?? 0,
                        onChanged: (v) => ctrl.setTransformerKva(
                          v > 0 ? ApparentPower.kilovoltAmperes(v) : null,
                        ),
                      ),
                    ),
                    Text(
                      context.strings(StringKey.electricalTransformerKvaNote),
                      style: type.caption.copyWith(color: colors.textMuted),
                    ),
                    const SizedBox(height: MechXSpacing.md),
                    // ── Capacitor bank ───────────────────────────────────
                    ElectricalField(
                      label:
                          context.strings(StringKey.electricalCapacitorKvar),
                      child: ElectricalNumInput(
                        value: project.capacitorBankKvar ?? 0,
                        onChanged: (v) =>
                            ctrl.setCapacitorBankKvar(v > 0 ? v : null),
                      ),
                    ),
                    Text(
                      context.strings(StringKey.electricalCapacitorKvarNote),
                      style: type.caption.copyWith(color: colors.textMuted),
                    ),
                    const SizedBox(height: MechXSpacing.md),
                    // ── Dual transformer ─────────────────────────────────
                    ElectricalToggleRow(
                      label: context
                          .strings(StringKey.electricalDualTransformer),
                      value: project.dualTransformer,
                      onChanged: ctrl.setDualTransformer,
                    ),
                    const SizedBox(height: MechXSpacing.sm),
                    Text(
                      context.strings(StringKey.electricalSourcesNote),
                      style: type.caption.copyWith(color: colors.textMuted),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Advanced study drawer (read-only A8) ────────────────────────────────────

class _AdvancedDrawer extends StatelessWidget {
  final AdvancedStudy advanced;
  final ElectricalSystemResult result;
  final VoidCallback onClose;

  /// G5 — locate a warning's offending board / way on the single-line canvas.
  final void Function(String panelId, String? circuitId) onLocate;
  const _AdvancedDrawer({
    required this.advanced,
    required this.result,
    required this.onClose,
    required this.onLocate,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return _AnimatedDrawerShell(
      width: 420,
      onClose: onClose,
      child: Container(
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(left: BorderSide(color: colors.border)),
          boxShadow: MechXShadow.popover,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MechXSpacing.md,
                MechXSpacing.md,
                MechXSpacing.md,
                MechXSpacing.sm + 4,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Issues & advanced study',
                      style: type.title.copyWith(color: colors.textPrimary),
                    ),
                  ),
                  MechXButton(
                    label: 'Close',
                    tertiary: true,
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
            Container(height: 1, color: colors.border),
            const SizedBox(height: MechXSpacing.xs),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(MechXSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (result.warnings.isNotEmpty) ...[
                      Text(
                        'Warnings (${result.warnings.length})',
                        style: type.label.copyWith(color: colors.textPrimary),
                      ),
                      const SizedBox(height: MechXSpacing.xs),
                      for (final w in result.warnings)
                        _WarningRow(warning: w, onLocate: onLocate),
                      const SizedBox(height: MechXSpacing.md),
                    ],
                    _AdvancedBody(advanced: advanced, result: result),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdvancedBody extends StatelessWidget {
  final AdvancedStudy advanced;
  final ElectricalSystemResult result;
  const _AdvancedBody({required this.advanced, required this.result});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final supply = advanced.supply;
    final pf = advanced.powerFactor;
    final fault = advanced.fault;

    final metrics = <_Metric>[
      _Metric(
        label: 'Supply',
        value: supply.lvOrMv == SupplyLevel.mv && supply.transformerKva != null
            ? 'MV · ${fmtNum(supply.transformerKva!)} kVA${supply.units > 1 ? ' x${supply.units}' : ''}'
            : 'LV direct',
      ),
      _Metric(
        label: 'Demand (kVA)',
        value: '${(advanced.recommendedDayaVa / 1000).toStringAsFixed(1)} kVA',
      ),
      _Metric(label: 'Origin Isc', value: '${fmtNum(fault.originFaultkA)} kA'),
      _Metric(
        label: 'Power factor',
        value: pf.needed
            ? '${fmtNum(pf.existingPf)} -> ${fmtNum(pf.targetPf)}'
            : '${fmtNum(pf.existingPf)} (OK)',
      ),
      if (pf.needed)
        _Metric(
          label: 'Capacitor',
          value:
              '${fmtNum(pf.bankKvar)} kvar${pf.steps > 0 ? ' / ${pf.steps} steps' : ''}',
        ),
      if (advanced.lightning != null)
        _Metric(
          label: 'Lightning',
          value: advanced.lightning!.lpsRequired
              ? 'LPS ${advanced.lightning!.level?.label ?? 'req'}'
              : 'not required',
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Advanced study',
          style: type.label.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: MechXSpacing.sm),
        Wrap(
          spacing: MechXSpacing.xl,
          runSpacing: MechXSpacing.sm,
          children: metrics,
        ),
        const SizedBox(height: MechXSpacing.md),
        // Per-panel matrix.
        for (final id in result.order)
          if (result.panels[id] != null)
            _PanelAdvancedRow(panel: result.panels[id]!, advanced: advanced),
        const SizedBox(height: MechXSpacing.sm),
        Text(
          // H2 — no dev-speak "value(s)": pick the correct noun for the count.
          'Estimates — verify against PUIL 2011 / IEC 60364. '
          '${pluralCount(advanced.verifyItems.length, 'value', 'values')} '
          'pending verification.',
          style: type.caption.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}

class _PanelAdvancedRow extends StatelessWidget {
  final ElectricalPanelResult panel;
  final AdvancedStudy advanced;
  const _PanelAdvancedRow({required this.panel, required this.advanced});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final fault = advanced.fault.panels[panel.panelId];
    final encl = advanced.enclosure[panel.panelId];
    final spd = advanced.spd[panel.panelId];
    final meter = advanced.metering[panel.panelId];
    final bits = <String>[
      if (fault != null)
        '${fmtNum(fault.prospectiveFaultkA)} kA${fault.incomerAdequate ? '' : ' !'}',
      if (encl != null)
        '${fmtNum(encl.widthMm)}x${fmtNum(encl.heightMm)}x${fmtNum(encl.depthMm)}',
      if (spd != null) spd.type.label,
      if (meter != null) meter.metering.label,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs + 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              panel.tag ?? panel.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: type.body.copyWith(color: colors.textPrimary),
            ),
          ),
          Expanded(
            child: Text(
              bits.join(' · '),
              style: type.caption.copyWith(color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  const _Metric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: type.caption.copyWith(
            color: colors.textMuted,
            letterSpacing: 0.5,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: MechXSpacing.xxs),
        Text(value, style: type.mono.copyWith(color: colors.textPrimary)),
      ],
    );
  }
}

/// One row in the Issues drawer. When the warning carries a [panelId] it is
/// TAPPABLE (G5) — a hover-tinted, click-cursored row that locates the offending
/// board / way on the single-line canvas via [onLocate]. A location-less warning
/// (system-wide) renders as inert text, exactly as before.
class _WarningRow extends StatefulWidget {
  final ElectricalWarning warning;
  final void Function(String panelId, String? circuitId) onLocate;
  const _WarningRow({required this.warning, required this.onLocate});

  @override
  State<_WarningRow> createState() => _WarningRowState();
}

class _WarningRowState extends State<_WarningRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final warning = widget.warning;
    final color = switch (warning.severity) {
      WarningSeverity.error => colors.danger,
      WarningSeverity.warning => colors.warning,
      WarningSeverity.info => colors.textMuted,
    };
    // Severity is carried by SHAPE as well as colour (the shared [SeverityGlyph])
    // so error/warning/info stay distinguishable without relying on hue alone:
    // error + warning use the "!"-ring (in their danger / warning colour), info
    // uses the dot-ring. No longer a colour-only filled dot.
    final glyphKind = switch (warning.severity) {
      WarningSeverity.error => SeverityGlyphKind.warn,
      WarningSeverity.warning => SeverityGlyphKind.warn,
      WarningSeverity.info => SeverityGlyphKind.info,
    };
    final panelId = warning.panelId;
    final locatable = panelId != null;

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3, right: MechXSpacing.sm),
          child: CustomPaint(
            size: const Size(11, 11),
            painter: SeverityGlyph(kind: glyphKind, color: color),
          ),
        ),
        Expanded(
          child: Text(
            warning.message,
            style: type.caption.copyWith(color: colors.textSecondary),
          ),
        ),
        // A trailing "locate" affordance (a right-pointing caret) on the rows a
        // tap can navigate — so the drawer reads as actionable, not inert text.
        if (locatable)
          Padding(
            padding: const EdgeInsets.only(left: MechXSpacing.xs, top: 2),
            child: CustomPaint(
              size: const Size(9, 11),
              painter: _LocateCaret(colors.textMuted),
            ),
          ),
      ],
    );

    if (!locatable) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs),
        child: row,
      );
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onLocate(panelId, warning.circuitId),
        child: AnimatedContainer(
          duration: MechXMotion.hover,
          curve: MechXMotion.standard,
          padding: const EdgeInsets.symmetric(
            horizontal: MechXSpacing.xs,
            vertical: MechXSpacing.xxs + 1,
          ),
          decoration: BoxDecoration(
            color: _hover ? colors.surfaceHover : const Color(0x00000000),
            borderRadius: MechXRadii.control,
          ),
          child: row,
        ),
      ),
    );
  }
}

/// A small right-pointing caret — the "locate" affordance on a tappable Issues
/// row (ASCII-free glyph, so no tofu risk in any font).
class _LocateCaret extends CustomPainter {
  final Color color;
  const _LocateCaret(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final w = size.width, h = size.height;
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.3, h * 0.24)
        ..lineTo(w * 0.72, h * 0.5)
        ..lineTo(w * 0.3, h * 0.76),
      p,
    );
  }

  @override
  bool shouldRepaint(_LocateCaret old) => old.color != color;
}
