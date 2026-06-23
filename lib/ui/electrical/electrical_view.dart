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
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'electrical_canvas.dart';
import 'electrical_format.dart';
import 'electrical_layout_view.dart';
import 'electrical_palette.dart';
import 'panel_geometry.dart';
import 'power_oneline_view.dart';

/// Identifies the circuit currently open in the inspector / context menu.
class _CircuitRef {
  final String panelId;
  final String circuitId;
  const _CircuitRef(this.panelId, this.circuitId);
}

/// Which tab the workspace shows.
enum _Tab { singleLine, layout, powerOneLine }

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
          onImport: () {},
          onExport: () {},
          onToggleAdvanced: () =>
              setState(() => _showAdvanced = !_showAdvanced),
          advancedOpen: _showAdvanced,
        ),
        Container(height: 1, color: colors.border),
        Expanded(
          child: switch (_tab) {
            _Tab.singleLine => _buildCanvasArea(project, result),
            _Tab.layout => _buildLayoutArea(),
            _Tab.powerOneLine =>
              PowerOneLineView(oneLine: advanced.powerOneLine),
          },
        ),
      ],
    );

    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: colors.canvas, child: body)),
        // Tap-away scrim behind any open menu / inspector.
        if (_editing != null || _panelMenu != null || _circuitMenu != null)
          Positioned.fill(
            child: Listener(
              onPointerDown: (_) => _closeOverlays(),
              behavior: HitTestBehavior.translucent,
              child: const SizedBox.expand(),
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
          _ServiceInspector(onClose: () => setState(() => _showService = false)),
      ],
    );
  }

  Widget _buildCanvasArea(
      ElectricalProject project, ElectricalSystemResult result) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ElectricalPalette(),
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
                      setState(() =>
                          _editing = _CircuitRef(panelId, first.id));
                    } else {
                      _openPanelMenu(panelId, _canvasCenter());
                    }
                  },
                  onEditCircuit: (panelId, circuitId) => setState(
                      () => _editing = _CircuitRef(panelId, circuitId)),
                  onPanelMenu: _openPanelMenu,
                  onCircuitMenu: (panelId, circuitId, gp) => setState(() {
                    _circuitMenu = _CircuitRef(panelId, circuitId);
                    _menuAt = _toLocal(gp);
                  }),
                  onRequestService: _openService,
                ),
              ),
              // Hint banner (top-right).
              Positioned(
                top: MechXSpacing.sm,
                right: MechXSpacing.md,
                child: _HintChip(
                  text:
                      'Zoom in on a panel to see its components; zoom out for a summary. Double-click to edit.',
                ),
              ),
              // Zoom controls (bottom-left).
              Positioned(
                left: MechXSpacing.md,
                bottom: MechXSpacing.md,
                child: _ZoomControls(
                  onIn: () => _canvasKey.currentState?.zoomIn(),
                  onOut: () => _canvasKey.currentState?.zoomOut(),
                  onFit: () => _canvasKey.currentState?.fitView(),
                ),
              ),
              // Minimap (bottom-right).
              Positioned(
                right: MechXSpacing.md,
                bottom: MechXSpacing.md,
                child: _MiniMap(
                  project: project,
                  result: result,
                ),
              ),
              // Gesture-help (?) (top-left).
              Positioned(
                left: MechXSpacing.md,
                top: MechXSpacing.sm,
                child: _HelpButton(
                  open: _showHelp,
                  onToggle: () => setState(() => _showHelp = !_showHelp),
                ),
              ),
              if (_showHelp)
                Positioned(
                  left: MechXSpacing.md,
                  top: 48,
                  child: _CanvasHelp(
                      onClose: () => setState(() => _showHelp = false)),
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
      ],
    );
  }

  /// The Layout tab: panels + loads placed on the calibrated PDF sheet, sized on
  /// real geometry. Reuses the SAME inspector + context menus as the single-line
  /// canvas (it edits the one shared model).
  Widget _buildLayoutArea() {
    return ElectricalLayoutView(
      onEditPanel: (panelId) {
        final project = ref.read(electricalProjectProvider);
        final panel =
            project.panels.where((p) => p.id == panelId).firstOrNull;
        final first = panel?.circuits
            .where((c) => c.loadKind != LoadKind.feeder)
            .firstOrNull;
        if (panel != null && first != null) {
          setState(() => _editing = _CircuitRef(panelId, first.id));
        } else {
          _openPanelMenu(panelId, _canvasCenter());
        }
      },
      onEditCircuit: (panelId, circuitId) =>
          setState(() => _editing = _CircuitRef(panelId, circuitId)),
      onPanelMenu: _openPanelMenu,
      onCircuitMenu: (panelId, circuitId, gp) => setState(() {
        _circuitMenu = _CircuitRef(panelId, circuitId);
        _menuAt = _toLocal(gp);
      }),
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
        name: 'Sub-panel $n', tag: 'SP-$n', x: 80 + n * 40, y: 80 + n * 40);
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
      child: _ContextMenu(
        items: [
          _MenuAction('Edit', () => setState(() {
                _editing = ref0;
                _circuitMenu = null;
              })),
          _MenuAction('Duplicate', () {
            _controller.duplicateCircuit(ref0.panelId, ref0.circuitId);
            setState(() => _circuitMenu = null);
          }),
          _MenuAction('Delete', () {
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
      child: _ContextMenu(
        items: [
          _MenuAction('Open panel', () {
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
          _MenuAction(
            panel.essential ? 'Unmark essential' : 'Mark essential',
            () {
              _controller.setPanelEssential(panel.id, !panel.essential);
              setState(() => _panelMenu = null);
            },
          ),
          _MenuAction(
            panel.upsBacked ? 'Unmark critical (UPS)' : 'Mark critical (UPS)',
            () {
              _controller.setPanelUpsBacked(panel.id, !panel.upsBacked);
              setState(() => _panelMenu = null);
            },
          ),
          _MenuAction(
            panel.submeter ? 'Remove submeter' : 'Add submeter',
            () {
              _controller.setPanelSubmeter(panel.id, !panel.submeter);
              setState(() => _panelMenu = null);
            },
          ),
          if (panel.fedByCircuitId != null)
            _MenuAction('Disconnect feeder', () {
              _controller.disconnectFeeder(panel.id);
              setState(() => _panelMenu = null);
            }),
          _MenuAction('Delete panel', () {
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
    final circuit =
        panel?.circuits.where((c) => c.id == ref0.circuitId).firstOrNull;
    if (panel == null || circuit == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _closeOverlays());
      return const SizedBox.shrink();
    }
    return Positioned(
      top: 0,
      right: 0,
      bottom: 0,
      child: _CircuitInspector(
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
  final VoidCallback onImport;
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
    required this.onImport,
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
          horizontal: MechXSpacing.md, vertical: MechXSpacing.sm),
      child: Row(
        children: [
          // Tabs (left).
          _TabButton(
            label: 'Single-line',
            selected: tab == _Tab.singleLine,
            onTap: () => onTab(_Tab.singleLine),
          ),
          const SizedBox(width: MechXSpacing.xs),
          _TabButton(
            label: 'Layout',
            selected: tab == _Tab.layout,
            onTap: () => onTab(_Tab.layout),
          ),
          const SizedBox(width: MechXSpacing.xs),
          _TabButton(
            label: 'Power one-line',
            selected: tab == _Tab.powerOneLine,
            onTap: () => onTab(_Tab.powerOneLine),
          ),
          const Spacer(),
          // Actions (right) — horizontally scrollable so a narrow window never
          // overflows the toolbar.
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Btn(
                    label:
                        warningCount > 0 ? 'Issues ($warningCount)' : 'Issues',
                    danger: warningCount > 0,
                    onTap: onToggleAdvanced,
                  ),
                  const SizedBox(width: MechXSpacing.xs),
                  _Btn(label: 'Service & Earthing', onTap: onService),
                  const SizedBox(width: MechXSpacing.xs),
                  _Btn(label: '+ Panel', onTap: onAddPanel),
                  const SizedBox(width: MechXSpacing.xs),
                  _Btn(label: 'Import loads', onTap: onImport, muted: true),
                  const SizedBox(width: MechXSpacing.xs),
                  _Btn(label: 'Export', onTap: onExport, muted: true),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _TabButton(
      {required this.label, required this.selected, required this.onTap});

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
              horizontal: MechXSpacing.sm + 2, vertical: MechXSpacing.xs + 2),
          decoration: BoxDecoration(
            color: selected ? colors.accentMuted : const Color(0x00000000),
            borderRadius: MechXRadii.control,
            border: Border.all(
                color: selected ? colors.accent : const Color(0x00000000)),
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

class _Btn extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final bool danger;
  final bool muted;
  const _Btn(
      {required this.label,
      required this.onTap,
      this.danger = false,
      this.muted = false});

  @override
  State<_Btn> createState() => _BtnState();
}

class _BtnState extends State<_Btn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final fg = widget.danger
        ? colors.danger
        : widget.muted
            ? colors.textMuted
            : colors.textSecondary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.sm + 2, vertical: MechXSpacing.xs + 1),
          decoration: BoxDecoration(
            color: _hover ? colors.surfaceHover : const Color(0x00000000),
            borderRadius: MechXRadii.control,
            border: Border.all(color: colors.border),
          ),
          child: Text(widget.label, style: type.label.copyWith(color: fg)),
        ),
      ),
    );
  }
}

// ── Canvas chrome (hint, zoom, minimap, help) ───────────────────────────────

class _HintChip extends StatelessWidget {
  final String text;
  const _HintChip({required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: MechXSpacing.sm, vertical: MechXSpacing.xs),
        decoration: BoxDecoration(
          color: colors.surface.withAlpha(220),
          borderRadius: MechXRadii.control,
          border: Border.all(color: colors.border),
        ),
        child: Text(text,
            style: context.type.caption.copyWith(color: colors.textMuted)),
      ),
    );
  }
}

class _ZoomControls extends StatelessWidget {
  final VoidCallback onIn;
  final VoidCallback onOut;
  final VoidCallback onFit;
  const _ZoomControls(
      {required this.onIn, required this.onOut, required this.onFit});

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
          _IconBtn(glyph: '+', onTap: onIn),
          _Sep(),
          _IconBtn(glyph: '-', onTap: onOut),
          _Sep(),
          _IconBtn(glyph: 'fit', onTap: onFit),
        ],
      ),
    );
  }
}

class _Sep extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 22, color: context.colors.border);
}

class _IconBtn extends StatefulWidget {
  final String glyph;
  final VoidCallback onTap;
  const _IconBtn({required this.glyph, required this.onTap});

  @override
  State<_IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<_IconBtn> {
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
              style: context.type.label.copyWith(color: colors.textSecondary)),
        ),
      ),
    );
  }
}

class _HelpButton extends StatelessWidget {
  final bool open;
  final VoidCallback onToggle;
  const _HelpButton({required this.open, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onToggle,
        child: Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: open ? colors.accent : colors.surface,
            shape: BoxShape.circle,
            border: Border.all(color: colors.border),
          ),
          child: Text('?',
              style: context.type.label.copyWith(
                  color: open
                      ? const Color(0xFFFFFFFF)
                      : colors.textSecondary)),
        ),
      ),
    );
  }
}

class _CanvasHelp extends StatelessWidget {
  final VoidCallback onClose;
  const _CanvasHelp({required this.onClose});

  // Ported verbatim from PanelMaker's CanvasHelp HELP_ITEMS.
  static const _items = <String>[
    'Double-click a component to edit its size, type or label',
    'Right-click a component for compatible replacement parts',
    'Drag a card from the palette onto a panel to add a way',
    "Drag a panel's round outlet onto another panel to feed it",
    'Drag a load onto a panel to wire it (creates the MCB)',
    'Select a panel or floating load and press Delete; right-click a way to delete it',
    'Drag the empty canvas to pan; scroll to zoom; panels reveal their internals up close',
  ];

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Container(
      width: 310,
      padding: const EdgeInsets.all(MechXSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.border),
        boxShadow: const [
          BoxShadow(
              color: Color(0x33000000), blurRadius: 16, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Canvas guide',
                    style:
                        type.subtitle.copyWith(color: colors.textPrimary)),
              ),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: onClose,
                  child: Text('Close',
                      style: type.label.copyWith(color: colors.textMuted)),
                ),
              ),
            ],
          ),
          const SizedBox(height: MechXSpacing.sm),
          for (final item in _items)
            Padding(
              padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 5,
                    height: 5,
                    margin: const EdgeInsets.only(top: 6, right: MechXSpacing.sm),
                    decoration: BoxDecoration(
                      color: colors.accent,
                      borderRadius: const BorderRadius.all(Radius.circular(3)),
                    ),
                  ),
                  Expanded(
                    child: Text(item,
                        style: type.caption
                            .copyWith(color: colors.textSecondary)),
                  ),
                ],
              ),
            ),
        ],
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
        color: colors.surface.withAlpha(230),
        borderRadius: MechXRadii.control,
        border: Border.all(color: colors.border),
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
      canvas.drawRect(
        Rect.fromLTWH(x, y, 14, 8),
        Paint()..color = accent,
      );
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
    final colors = context.colors;
    final type = context.type;
    return Container(
      width: 360,
      padding: const EdgeInsets.all(MechXSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Set up your service',
              style: type.title.copyWith(color: colors.textPrimary)),
          const SizedBox(height: MechXSpacing.xs),
          Text(
            'Add a distribution panel, then drag loads from the palette onto it. '
            'Set the supply phase and earthing from Service & Earthing.',
            style: type.body.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: MechXSpacing.md),
          Row(
            children: [
              _Btn(label: '+ Panel', onTap: onAddPanel),
              const SizedBox(width: MechXSpacing.sm),
              _Btn(label: 'Service & Earthing', onTap: onSetUp),
            ],
          ),
        ],
      ),
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

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: ColoredBox(color: const Color(0x33000000)),
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          bottom: 0,
          child: Container(
            width: 340,
            decoration: BoxDecoration(
              color: colors.surface,
              border: Border(left: BorderSide(color: colors.border)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(MechXSpacing.md,
                      MechXSpacing.md, MechXSpacing.sm, MechXSpacing.sm),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('Service & Earthing',
                            style: type.subtitle
                                .copyWith(color: colors.textPrimary)),
                      ),
                      _TextButton(label: 'Close', onTap: onClose),
                    ],
                  ),
                ),
                Container(height: 1, color: colors.border),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(MechXSpacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Field(
                          label: 'Earthing system',
                          child: _EnumPicker<EarthingSystem>(
                            value: project.earthingSystem,
                            options: EarthingSystem.values,
                            label: (e) => e.label,
                            onChanged: ctrl.setEarthingSystem,
                          ),
                        ),
                        Text(
                          project.earthingSystem.note,
                          style: type.caption
                              .copyWith(color: colors.textMuted),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
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
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: ColoredBox(color: const Color(0x33000000)),
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          bottom: 0,
          child: Container(
            width: 420,
            decoration: BoxDecoration(
              color: colors.surface,
              border: Border(left: BorderSide(color: colors.border)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(MechXSpacing.md,
                      MechXSpacing.md, MechXSpacing.sm, MechXSpacing.sm),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('Issues & advanced study',
                            style: type.subtitle
                                .copyWith(color: colors.textPrimary)),
                      ),
                      _TextButton(label: 'Close', onTap: onClose),
                    ],
                  ),
                ),
                Container(height: 1, color: colors.border),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(MechXSpacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (result.warnings.isNotEmpty) ...[
                          Text('Warnings (${result.warnings.length})',
                              style: type.label
                                  .copyWith(color: colors.textPrimary)),
                          const SizedBox(height: MechXSpacing.xs),
                          for (final w in result.warnings)
                            _WarningRow(warning: w),
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
        ),
      ],
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
          value: supply.lvOrMv == SupplyLevel.mv &&
                  supply.transformerKva != null
              ? 'MV · ${fmtNum(supply.transformerKva!)} kVA${supply.units > 1 ? ' x${supply.units}' : ''}'
              : 'LV direct'),
      _Metric(
          label: 'Daya',
          value:
              '${(advanced.recommendedDayaVa / 1000).toStringAsFixed(1)} kVA'),
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
                '${fmtNum(pf.bankKvar)} kvar${pf.steps > 0 ? ' / ${pf.steps} steps' : ''}'),
      if (advanced.lightning != null)
        _Metric(
            label: 'Lightning',
            value: advanced.lightning!.lpsRequired
                ? 'LPS ${advanced.lightning!.level?.label ?? 'req'}'
                : 'not required'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Advanced study',
            style: type.label.copyWith(color: colors.textPrimary)),
        const SizedBox(height: MechXSpacing.sm),
        Wrap(spacing: MechXSpacing.xl, runSpacing: MechXSpacing.sm, children: metrics),
        const SizedBox(height: MechXSpacing.md),
        // Per-panel matrix.
        for (final id in result.order)
          if (result.panels[id] != null)
            _PanelAdvancedRow(
              panel: result.panels[id]!,
              advanced: advanced,
            ),
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
            child: Text(panel.tag ?? panel.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: type.body.copyWith(color: colors.textPrimary)),
          ),
          Expanded(
            child: Text(bits.join(' · '),
                style: type.caption.copyWith(color: colors.textSecondary)),
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
        Text(label.toUpperCase(),
            style: type.caption.copyWith(
              color: colors.textMuted,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w600,
            )),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.only(top: 5, right: MechXSpacing.sm),
            decoration: BoxDecoration(
              color: color,
              borderRadius: const BorderRadius.all(Radius.circular(4)),
            ),
          ),
          Expanded(
            child: Text(warning.message,
                style: type.caption.copyWith(color: colors.textSecondary)),
          ),
        ],
      ),
    );
  }
}

// ── Context menu ──────────────────────────────────────────────────────────────

class _MenuAction {
  final String label;
  final VoidCallback onTap;
  final bool danger;
  const _MenuAction(this.label, this.onTap, {this.danger = false});
}

class _ContextMenu extends StatelessWidget {
  final List<_MenuAction> items;
  const _ContextMenu({required this.items});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: 188,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.control,
        border: Border.all(color: colors.border),
        boxShadow: const [
          BoxShadow(
              color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in items)
            _MenuItem(label: item.label, onTap: item.onTap, danger: item.danger),
        ],
      ),
    );
  }
}

class _MenuItem extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final bool danger;
  const _MenuItem(
      {required this.label, required this.onTap, this.danger = false});

  @override
  State<_MenuItem> createState() => _MenuItemState();
}

class _MenuItemState extends State<_MenuItem> {
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
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.sm + 2, vertical: MechXSpacing.xs + 3),
          color: _hover ? colors.surfaceHover : const Color(0x00000000),
          child: Text(widget.label,
              style: type.body.copyWith(
                color: widget.danger ? colors.danger : colors.textPrimary,
              )),
        ),
      ),
    );
  }
}

// ── Circuit inspector (the Wave-4 drawer, reused) ───────────────────────────

class _CircuitInspector extends StatelessWidget {
  final ElectricalPanel panel;
  final ElectricalCircuit circuit;
  final ElectricalProjectController controller;
  final VoidCallback onClose;

  const _CircuitInspector({
    super.key,
    required this.panel,
    required this.circuit,
    required this.controller,
    required this.onClose,
  });

  static const _cableTypes = <String?>[
    null,
    'NYY',
    'NYM',
    'NYA',
    'NYAF',
    'FRC',
  ];

  bool get _isMotor =>
      circuit.loadKind == LoadKind.motor || circuit.loadKind == LoadKind.pump;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;

    return Container(
      width: 340,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(left: BorderSide(color: colors.border)),
        boxShadow: const [
          BoxShadow(
              color: Color(0x22000000), blurRadius: 16, offset: Offset(-2, 0)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(MechXSpacing.md, MechXSpacing.md,
                MechXSpacing.sm, MechXSpacing.sm),
            child: Row(
              children: [
                Expanded(
                  child: Text('Edit circuit',
                      style:
                          type.subtitle.copyWith(color: colors.textPrimary)),
                ),
                _TextButton(label: 'Close', onTap: onClose),
              ],
            ),
          ),
          Container(height: 1, color: colors.border),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(MechXSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Field(
                    label: 'Name',
                    child: _Text(
                      value: circuit.name,
                      onChanged: (v) =>
                          controller.setCircuit(panel.id, circuit.id, name: v),
                    ),
                  ),
                  _Field(
                    label: 'Load kind',
                    child: _EnumPicker<LoadKind>(
                      value: circuit.loadKind,
                      options: const [
                        LoadKind.general,
                        LoadKind.lighting,
                        LoadKind.socket,
                        LoadKind.hvac,
                        LoadKind.motor,
                        LoadKind.pump,
                        LoadKind.heating,
                        LoadKind.ups,
                        LoadKind.evCharger,
                        LoadKind.welding,
                        LoadKind.spare,
                      ],
                      label: (k) => loadDefaults[k]?.label ?? k.name,
                      onChanged: (k) =>
                          controller.setCircuit(panel.id, circuit.id, loadKind: k),
                    ),
                  ),
                  if (_isMotor)
                    _Field(
                      label: 'Motor power (kW)',
                      child: _Num(
                        value: circuit.motorKw ?? 0,
                        onChanged: (v) => controller.setCircuit(
                            panel.id, circuit.id,
                            motorKw: v),
                      ),
                    )
                  else
                    _Field(
                      label: 'Load (W)',
                      child: _Num(
                        value: circuit.loadW,
                        onChanged: (v) => controller.setCircuit(
                            panel.id, circuit.id,
                            loadW: v),
                      ),
                    ),
                  _Field(
                    label: 'cos phi',
                    child: _Num(
                      value: circuit.cosPhi,
                      onChanged: (v) => controller.setCircuit(
                          panel.id, circuit.id,
                          cosPhi: v.clamp(0.0, 1.0)),
                    ),
                  ),
                  _Field(
                    label: 'Demand factor',
                    child: _Num(
                      value: circuit.demandFactor,
                      onChanged: (v) => controller.setCircuit(
                          panel.id, circuit.id,
                          demandFactor: v.clamp(0.0, 1.0)),
                    ),
                  ),
                  _Field(
                    label: 'Run length (m)',
                    child: _Num(
                      value: circuit.length.meters,
                      onChanged: (v) => controller.setCircuit(
                          panel.id, circuit.id,
                          length: Length(v)),
                    ),
                  ),
                  _Field(
                    label: 'Supply phase',
                    child: _EnumPicker<int>(
                      value: circuit.phases ?? 0,
                      options: const [0, 1, 3],
                      label: (p) => switch (p) {
                        1 => '1-phase',
                        3 => '3-phase',
                        _ => 'Auto',
                      },
                      onChanged: (p) => p == 0
                          ? controller.setCircuit(panel.id, circuit.id,
                              clearPhases: true)
                          : controller.setCircuit(panel.id, circuit.id,
                              phases: p),
                    ),
                  ),
                  _Field(
                    label: 'Cable type',
                    child: _EnumPicker<String?>(
                      value: circuit.cableType,
                      options: _cableTypes,
                      label: (t) => t ?? 'Panel default',
                      onChanged: (t) => t == null
                          ? controller.setCircuit(panel.id, circuit.id,
                              clearCableType: true)
                          : controller.setCircuit(panel.id, circuit.id,
                              cableType: t),
                    ),
                  ),
                  _ToggleRow(
                    label: 'Lighting circuit (3% Vd limit)',
                    value: circuit.isLighting,
                    onChanged: (v) => controller.setCircuit(
                        panel.id, circuit.id,
                        isLighting: v),
                  ),
                  _ToggleRow(
                    label: 'Life-safety (no RCD)',
                    value: circuit.lifeSafety,
                    onChanged: (v) => controller.setCircuit(
                        panel.id, circuit.id,
                        lifeSafety: v),
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

// ── Reused field primitives ─────────────────────────────────────────────────

class _Field extends StatelessWidget {
  final String label;
  final Widget child;
  const _Field({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Padding(
      padding: const EdgeInsets.only(bottom: MechXSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label.toUpperCase(),
              style: type.caption.copyWith(
                color: colors.textMuted,
                letterSpacing: 0.6,
                fontWeight: FontWeight.w600,
              )),
          const SizedBox(height: MechXSpacing.xs),
          child,
        ],
      ),
    );
  }
}

class _Text extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _Text({required this.value, required this.onChanged});

  @override
  State<_Text> createState() => _TextState();
}

class _TextState extends State<_Text> {
  late final TextEditingController _ctl =
      TextEditingController(text: widget.value);
  final FocusNode _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() => _focused = _focus.hasFocus));
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return GestureDetector(
      onTap: _focus.requestFocus,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: MechXSpacing.sm, vertical: MechXSpacing.xs + 2),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: MechXRadii.control,
          border: Border.all(color: _focused ? colors.accent : colors.border),
        ),
        child: EditableText(
          controller: _ctl,
          focusNode: _focus,
          onChanged: widget.onChanged,
          maxLines: 1,
          style: type.body.copyWith(color: colors.textPrimary),
          cursorColor: colors.accent,
          backgroundCursorColor: colors.textMuted,
          cursorWidth: 1.5,
          selectionColor: colors.accentMuted,
        ),
      ),
    );
  }
}

class _Num extends StatefulWidget {
  final double value;
  final ValueChanged<double> onChanged;
  const _Num({required this.value, required this.onChanged});

  @override
  State<_Num> createState() => _NumState();
}

class _NumState extends State<_Num> {
  late final TextEditingController _ctl =
      TextEditingController(text: _fmt(widget.value));
  final FocusNode _focus = FocusNode();
  bool _focused = false;

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() => _focused = _focus.hasFocus));
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return GestureDetector(
      onTap: _focus.requestFocus,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: MechXSpacing.sm, vertical: MechXSpacing.xs + 2),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: MechXRadii.control,
          border: Border.all(color: _focused ? colors.accent : colors.border),
        ),
        child: EditableText(
          controller: _ctl,
          focusNode: _focus,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (s) {
            final v = double.tryParse(s.trim());
            if (v != null) widget.onChanged(v);
          },
          maxLines: 1,
          style: type.mono.copyWith(color: colors.textPrimary),
          cursorColor: colors.accent,
          backgroundCursorColor: colors.textMuted,
          cursorWidth: 1.5,
          selectionColor: colors.accentMuted,
        ),
      ),
    );
  }
}

class _EnumPicker<T> extends StatelessWidget {
  final T value;
  final List<T> options;
  final String Function(T) label;
  final ValueChanged<T> onChanged;
  const _EnumPicker({
    required this.value,
    required this.options,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: MechXSpacing.xs,
      runSpacing: MechXSpacing.xs,
      children: [
        for (final o in options)
          _Chip(
            label: label(o),
            selected: o == value,
            onTap: () => onChanged(o),
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip(
      {required this.label, required this.selected, required this.onTap});

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
              horizontal: MechXSpacing.sm, vertical: MechXSpacing.xs + 1),
          decoration: BoxDecoration(
            color: selected ? colors.accent : colors.background,
            borderRadius: MechXRadii.control,
            border: Border.all(color: selected ? colors.accent : colors.border),
          ),
          child: Text(label,
              style: type.label.copyWith(
                color: selected ? const Color(0xFFFFFFFF) : colors.textSecondary,
              )),
        ),
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Padding(
      padding: const EdgeInsets.only(bottom: MechXSpacing.md),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!value),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: type.body.copyWith(color: colors.textSecondary)),
            ),
            const SizedBox(width: MechXSpacing.sm),
            AnimatedContainer(
              duration: MechXMotion.fast,
              width: 36,
              height: 20,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: value ? colors.accent : colors.border,
                borderRadius: const BorderRadius.all(Radius.circular(10)),
              ),
              child: Align(
                alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: const BoxDecoration(
                    color: Color(0xFFFFFFFF),
                    shape: BoxShape.circle,
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

class _TextButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _TextButton({required this.label, required this.onTap});

  @override
  State<_TextButton> createState() => _TextButtonState();
}

class _TextButtonState extends State<_TextButton> {
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
        child: AnimatedContainer(
          duration: MechXMotion.fast,
          padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.sm + 2, vertical: MechXSpacing.xs + 1),
          decoration: BoxDecoration(
            color: _hover ? colors.surfaceHover : const Color(0x00000000),
            borderRadius: MechXRadii.control,
            border: Border.all(color: colors.border),
          ),
          child: Text(widget.label,
              style: type.label.copyWith(color: colors.textSecondary)),
        ),
      ),
    );
  }
}
