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

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/lightning.dart' show LpsLevelLabel;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/metering.dart' show MeteringKindLabel;
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/spd.dart' show SpdTypeLabel;
import 'package:mechx_engine/electrical/supply_design.dart' show SupplyLevel;
import 'package:mechx_engine/units.dart';

import '../../store/electrical_store.dart';
import '../canvas/zoom_controls.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/canvas_guide_popover.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_empty_state_card.dart';
import '../widgets/mechx_segment.dart';
import '../widgets/severity_glyph.dart';
import 'electrical_canvas.dart';
import 'electrical_controls.dart';
import 'electrical_export.dart';
import 'electrical_format.dart';
import 'electrical_inspector.dart' show ElectricalCircuitInspector;
import 'electrical_palette.dart';
import 'panel_geometry.dart';
import 'power_oneline_view.dart';

/// Identifies the circuit currently open in the inspector / context menu.
class _CircuitRef {
  final String panelId;
  final String circuitId;
  const _CircuitRef(this.panelId, this.circuitId);
}

/// Which tab the workspace shows. (Spatial placement on the PDF moved to the
/// unified Layout canvas — the Electrical layer there — so this is the two
/// abstract projections.)
enum _Tab { singleLine, powerOneLine }

/// Renders the electrical single-line canvas and hosts the editing overlays.
class ElectricalView extends ConsumerStatefulWidget {
  const ElectricalView({super.key});

  @override
  ConsumerState<ElectricalView> createState() => _ElectricalViewState();
}

class _ElectricalViewState extends ConsumerState<ElectricalView> {
  final GlobalKey<ElectricalCanvasState> _canvasKey =
      GlobalKey<ElectricalCanvasState>();

  _Tab _tab = _Tab.singleLine;

  /// The circuit whose inspector panel is open (null = closed).
  _CircuitRef? _editing;

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

  /// Whether the Export menu (SLD / report / power one-line) is open.
  bool _showExportMenu = false;

  ElectricalProjectController get _controller =>
      ref.read(electricalProjectProvider.notifier);

  void _closeOverlays() {
    if (_editing != null || _panelMenu != null || _circuitMenu != null) {
      setState(() {
        _editing = null;
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

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final result = ref.watch(electricalResultProvider);
    final project = ref.watch(electricalProjectProvider);
    final advanced = ref.watch(electricalAdvancedProvider);

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Toolbar(
          warningCount: result.warnings.length,
          tab: _tab,
          onTab: (t) => setState(() => _tab = t),
          onIssues: () => setState(() => _showAdvanced = false),
          onService: _openService,
          onAddPanel: _addPanel,
          onExport: () => setState(() => _showExportMenu = !_showExportMenu),
          onToggleAdvanced: () =>
              setState(() => _showAdvanced = !_showAdvanced),
          advancedOpen: _showAdvanced,
        ),
        Container(height: 1, color: colors.border),
        Expanded(
          child: switch (_tab) {
            _Tab.singleLine => _buildCanvasArea(project, result),
            _Tab.powerOneLine => PowerOneLineView(
              oneLine: advanced.powerOneLine,
            ),
          },
        ),
      ],
    );

    return Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(color: colors.canvas, child: body),
        ),
        // Tap-away scrim behind any open menu / inspector.
        if (_editing != null ||
            _panelMenu != null ||
            _circuitMenu != null ||
            _showExportMenu)
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
              onReport: () => _runExport(exportElectricalCalcReport),
              onPowerOneLine: () => _runExport(exportPowerOneLineDxf),
            ),
          ),
        if (_circuitMenu != null) _buildCircuitMenu(),
        if (_panelMenu != null) _buildPanelMenu(),
        if (_editing != null) _buildInspector(),
        if (_showAdvanced)
          _AdvancedDrawer(
            advanced: advanced,
            result: result,
            onClose: () => setState(() => _showAdvanced = false),
          ),
        if (_showService)
          _ServiceInspector(
            onClose: () => setState(() => _showService = false),
          ),
      ],
    );
  }

  Widget _buildCanvasArea(
    ElectricalProject project,
    ElectricalSystemResult result,
  ) {
    final colors = context.colors;
    // The Loads palette sits on the RIGHT — consistent with the inspector/DRAW
    // column in every other workspace (Layout, Schematic). The canvas leads.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: ElectricalCanvas(
                  key: _canvasKey,
                  onEditPanel: (panelId) {
                    // Open the inspector on the panel's first editable way.
                    final panel = project.panels
                        .where((p) => p.id == panelId)
                        .firstOrNull;
                    final first = panel?.circuits
                        .where((c) => c.loadKind != LoadKind.feeder)
                        .firstOrNull;
                    if (panel != null && first != null) {
                      setState(() => _editing = _CircuitRef(panelId, first.id));
                    } else {
                      _openPanelMenu(panelId, _canvasCenter());
                    }
                  },
                  onEditCircuit: (panelId, circuitId) => setState(
                    () => _editing = _CircuitRef(panelId, circuitId),
                  ),
                  onPanelMenu: _openPanelMenu,
                  onCircuitMenu: (panelId, circuitId, gp) => setState(() {
                    _circuitMenu = _CircuitRef(panelId, circuitId);
                    _menuAt = _toLocal(gp);
                  }),
                  onRequestService: _openService,
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
              // Minimap (bottom-right).
              Positioned(
                right: MechXSpacing.md,
                bottom: MechXSpacing.md,
                child: _MiniMap(project: project, result: result),
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
                    items: _electricalGuideItems,
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
                    ),
                  ),
                ),
            ],
          ),
        ),
        Container(width: 1, color: colors.border),
        const ElectricalPalette(),
      ],
    );
  }

  // ── Geometry helpers ────────────────────────────────────────────────────────

  Offset _toLocal(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    return box?.globalToLocal(global) ?? global;
  }

  Offset _canvasCenter() {
    final box = context.findRenderObject() as RenderBox?;
    final size = box?.size ?? const Size(800, 600);
    return Offset(size.width / 2, size.height / 2);
  }

  // ── Edit-intent wiring ──────────────────────────────────────────────────────

  void _addPanel() {
    final n = ref.read(electricalProjectProvider).panels.length + 1;
    _controller.addPanelAt(
      name: 'Sub-panel $n',
      tag: 'SP-$n',
      x: 80 + n * 40,
      y: 80 + n * 40,
    );
  }

  void _openService() {
    setState(() {
      _panelMenu = null;
      _circuitMenu = null;
      _editing = null;
      _showAdvanced = false;
      _showService = true;
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
            'Edit',
            () => setState(() {
              _editing = ref0;
              _circuitMenu = null;
            }),
          ),
          ElectricalMenuAction('Duplicate', () {
            _controller.duplicateCircuit(ref0.panelId, ref0.circuitId);
            setState(() => _circuitMenu = null);
          }),
          ElectricalMenuAction('Delete', () {
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
          ElectricalMenuAction('Open panel', () {
            final first = panel.circuits
                .where((c) => c.loadKind != LoadKind.feeder)
                .firstOrNull;
            setState(() {
              _panelMenu = null;
              if (first != null) {
                _editing = _CircuitRef(panel.id, first.id);
              }
            });
          }),
          ElectricalMenuAction(
            panel.essential ? 'Unmark essential' : 'Mark essential',
            () {
              _controller.setPanelEssential(panel.id, !panel.essential);
              setState(() => _panelMenu = null);
            },
          ),
          ElectricalMenuAction(
            panel.upsBacked ? 'Unmark critical (UPS)' : 'Mark critical (UPS)',
            () {
              _controller.setPanelUpsBacked(panel.id, !panel.upsBacked);
              setState(() => _panelMenu = null);
            },
          ),
          ElectricalMenuAction(panel.submeter ? 'Remove submeter' : 'Add submeter', () {
            _controller.setPanelSubmeter(panel.id, !panel.submeter);
            setState(() => _panelMenu = null);
          }),
          if (panel.fedByCircuitId != null)
            ElectricalMenuAction('Disconnect feeder', () {
              _controller.disconnectFeeder(panel.id);
              setState(() => _panelMenu = null);
            }),
          ElectricalMenuAction('Delete panel', () {
            _controller.deletePanel(panel.id);
            setState(() => _panelMenu = null);
          }, danger: true),
        ],
      ),
    );
  }

  Widget _buildInspector() {
    final ref0 = _editing!;
    final project = ref.watch(electricalProjectProvider);
    final panel = project.panels.where((p) => p.id == ref0.panelId).firstOrNull;
    final circuit = panel?.circuits
        .where((c) => c.id == ref0.circuitId)
        .firstOrNull;
    if (panel == null || circuit == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _closeOverlays());
      return const SizedBox.shrink();
    }
    return Positioned(
      top: 0,
      right: 0,
      bottom: 0,
      child: ElectricalCircuitInspector(
        key: ValueKey('${ref0.panelId}/${ref0.circuitId}'),
        panel: panel,
        circuit: circuit,
        controller: _controller,
        onClose: _closeOverlays,
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
    required this.onAddPanel,
    required this.onExport,
    required this.onToggleAdvanced,
    required this.advancedOpen,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      color: colors.surface,
      padding: const EdgeInsets.symmetric(
        horizontal: MechXSpacing.md,
        vertical: MechXSpacing.sm,
      ),
      child: Row(
        children: [
          // Tabs (left) — the shared selectable-segment vocabulary.
          MechXSegment(
            label: 'Single-line',
            selected: tab == _Tab.singleLine,
            onTap: () => onTab(_Tab.singleLine),
          ),
          const SizedBox(width: MechXSpacing.xs),
          MechXSegment(
            label: 'Power one-line',
            selected: tab == _Tab.powerOneLine,
            onTap: () => onTab(_Tab.powerOneLine),
          ),
          const Spacer(),
          // Actions (right) — horizontally scrollable so a narrow window never
          // overflows the toolbar. The canonical MechXButton "gray button";
          // danger / muted tones only recolour the label.
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MechXButton(
                    label: warningCount > 0
                        ? 'Issues ($warningCount)'
                        : 'Issues',
                    tone: warningCount > 0
                        ? MechXButtonTone.danger
                        : MechXButtonTone.normal,
                    onPressed: onToggleAdvanced,
                  ),
                  const SizedBox(width: MechXSpacing.xs),
                  MechXButton(
                    label: 'Service & Earthing',
                    onPressed: onService,
                  ),
                  const SizedBox(width: MechXSpacing.xs),
                  MechXButton(label: '+ Panel', onPressed: onAddPanel),
                  const SizedBox(width: MechXSpacing.xs),
                  MechXButton(
                    label: 'Export',
                    tone: MechXButtonTone.muted,
                    onPressed: onExport,
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

// ── Canvas chrome (zoom, minimap, help) ─────────────────────────────────────

/// The electrical canvas gesture-help items, ported verbatim from PanelMaker's
/// CanvasHelp HELP_ITEMS. Rendered via the shared [CanvasGuideLegend].
const _electricalGuideItems = <String>[
  'Double-click a component to edit its size, type or label',
  'Right-click a component for compatible replacement parts',
  'Drag a card from the palette onto a panel to add a way',
  "Drag a panel's round outlet onto another panel to feed it",
  'Drag a load onto a panel to wire it (creates the MCB)',
  'Select a panel or floating load and press Delete; right-click a way to delete it',
  'Drag the empty canvas to pan; scroll to zoom; panels reveal their internals up close',
];

/// The Export popover (anchored under the toolbar's Export button) — single-line
/// DXF, electrical report (Markdown) and power one-line DXF.
class _ExportMenu extends StatelessWidget {
  final VoidCallback onSld;
  final VoidCallback onSldPdf;
  final VoidCallback onReport;
  final VoidCallback onPowerOneLine;
  const _ExportMenu({
    required this.onSld,
    required this.onSldPdf,
    required this.onReport,
    required this.onPowerOneLine,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
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
      child: Container(
        width: 260,
        padding: const EdgeInsets.all(MechXSpacing.xs),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: MechXRadii.card,
          border: Border.all(color: colors.border),
          boxShadow: MechXShadow.popover,
        ),
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
          ],
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

/// A small static minimap (bottom-right): every panel as a coloured rectangle.
class _MiniMap extends StatelessWidget {
  final ElectricalProject project;
  final ElectricalSystemResult result;
  const _MiniMap({required this.project, required this.result});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: 150,
      height: 100,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.control,
        border: Border.all(color: colors.border),
        boxShadow: MechXShadow.card,
      ),
      child: ClipRRect(
        borderRadius: MechXRadii.control,
        child: CustomPaint(
          painter: _MiniMapPainter(
            project: project,
            result: result,
            accent: colors.accent,
            muted: colors.textMuted,
          ),
        ),
      ),
    );
  }
}

class _MiniMapPainter extends CustomPainter {
  final ElectricalProject project;
  final ElectricalSystemResult result;
  final Color accent;
  final Color muted;
  _MiniMapPainter({
    required this.project,
    required this.result,
    required this.accent,
    required this.muted,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final positions = autoLayout(project, result);
    if (positions.isEmpty) return;
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
    positions.forEach((id, p) {
      final x = ox + (p.dx - minX + 80) * scale;
      final y = oy + (p.dy - minY + 60) * scale;
      canvas.drawRect(Rect.fromLTWH(x, y, 14, 8), Paint()..color = accent);
    });
  }

  @override
  bool shouldRepaint(_MiniMapPainter old) =>
      old.project != project || old.result != result;
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback onSetUp;
  final VoidCallback onAddPanel;
  const _EmptyState({required this.onSetUp, required this.onAddPanel});

  @override
  Widget build(BuildContext context) {
    // The shared branded empty-state card (matching the mechanical Layout
    // canvas's), with the two service set-up actions.
    return Padding(
      padding: const EdgeInsets.all(MechXSpacing.lg),
      child: MechXEmptyStateCard(
        title: 'Set up your service',
        body: 'Add a distribution panel, then drag loads from the palette '
            'onto it. Set the supply phase and earthing from Service & '
            'Earthing.',
        actions: [
          MechXButton(label: '+ Panel', onPressed: onAddPanel),
          const SizedBox(width: MechXSpacing.sm),
          MechXButton(label: 'Service & Earthing', onPressed: onSetUp),
        ],
      ),
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
                      'Service & Earthing',
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
                    ElectricalField(
                      label: 'Earthing system',
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
  const _AdvancedDrawer({
    required this.advanced,
    required this.result,
    required this.onClose,
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
                      for (final w in result.warnings) _WarningRow(warning: w),
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
        label: 'Daya',
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
          'Estimates — verify against PUIL 2011 / IEC 60364. '
          '${advanced.verifyItems.length} value(s) pending verification.',
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

class _WarningRow extends StatelessWidget {
  final ElectricalWarning warning;
  const _WarningRow({required this.warning});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs),
      child: Row(
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
        ],
      ),
    );
  }
}
