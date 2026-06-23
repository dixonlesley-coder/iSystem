/// The Electrical ("E") workspace — an INTERACTIVE editor over the sized
/// electrical system. It keeps the A7 read-only rendering (panel schedule /
/// supply / warnings) and layers direct-manipulation editing on top, in the
/// same language PanelMaker uses:
///
///  • a **palette** of load cards (`Draggable<LoadKind>`, defaults from
///    `loadDefaults`) — drop one on a panel card (a `DragTarget`) to add a way;
///  • **double-click** a schedule row → a custom inspector panel to edit the
///    circuit's fields; **right-click** → a custom Edit / Duplicate / Delete menu;
///  • an **add-panel** affordance and a per-panel **"+"** add-circuit button;
///  • an **advanced-study** section (read-only) summarising the A8 passes.
///
/// Styled entirely with MechXTheme tokens (grouped inset lists, monospaced
/// figures via Roboto Mono). No Material/Fluent — overlays are a `Stack` layer,
/// the context menu / inspector are custom panels, right-click is a `Listener`
/// on the secondary button. The pure A4 engine does all the calculation; this
/// widget only reads its result records and drives the store's edit intents.
library;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/arc_flash.dart' show PpeCategoryInfo;
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/harmonics.dart' show ThdBandLabel;
import 'package:mechx_engine/electrical/lightning.dart' show LpsLevelLabel;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/metering.dart' show MeteringKindLabel;
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/results.dart';
import 'package:mechx_engine/electrical/spd.dart' show SpdTypeLabel;
import 'package:mechx_engine/electrical/supply_design.dart' show SupplyLevel;
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';

import '../../store/electrical_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

/// Identifies the circuit currently open in the inspector / context menu.
class _CircuitRef {
  final String panelId;
  final String circuitId;
  const _CircuitRef(this.panelId, this.circuitId);
}

/// Renders the electrical system and hosts the interactive editing overlays.
class ElectricalView extends ConsumerStatefulWidget {
  const ElectricalView({super.key});

  @override
  ConsumerState<ElectricalView> createState() => _ElectricalViewState();
}

class _ElectricalViewState extends ConsumerState<ElectricalView> {
  /// The circuit whose inspector panel is open (null = closed).
  _CircuitRef? _editing;

  /// The circuit whose right-click context menu is open + where to anchor it.
  _CircuitRef? _menuFor;
  Offset _menuAt = Offset.zero;

  /// Whether the advanced-study section is expanded.
  bool _showAdvanced = true;

  void _closeOverlays() {
    if (_editing != null || _menuFor != null) {
      setState(() {
        _editing = null;
        _menuFor = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final result = ref.watch(electricalResultProvider);
    final project = ref.watch(electricalProjectProvider);
    final advanced = ref.watch(electricalAdvancedProvider);

    final panels = [
      for (final id in result.order)
        if (result.panels[id] != null) result.panels[id]!,
    ];

    final report = ColoredBox(
      color: colors.canvas,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(MechXSpacing.lg),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1080),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(
                  projectName: project.name,
                  onAddPanel: _addPanel,
                ),
                const SizedBox(height: MechXSpacing.md),
                _Palette(),
                const SizedBox(height: MechXSpacing.md),
                _SupplyCard(supply: result.supply, earthing: result.earthing),
                const SizedBox(height: MechXSpacing.lg),
                if (result.warnings.isNotEmpty) ...[
                  _WarningsCard(warnings: result.warnings),
                  const SizedBox(height: MechXSpacing.lg),
                ],
                for (final panel in panels) ...[
                  _PanelCard(
                    panel: panel,
                    onDropLoad: (kind) =>
                        _onDropLoad(panel.panelId, kind),
                    onAddCircuit: () => _onAddCircuit(panel.panelId),
                    onEditRow: (cid) =>
                        setState(() => _editing = _CircuitRef(panel.panelId, cid)),
                    onMenuRow: (cid, at) => setState(() {
                      _menuFor = _CircuitRef(panel.panelId, cid);
                      _menuAt = at;
                    }),
                  ),
                  const SizedBox(height: MechXSpacing.lg),
                ],
                _AdvancedCard(
                  advanced: advanced,
                  result: result,
                  expanded: _showAdvanced,
                  onToggle: () =>
                      setState(() => _showAdvanced = !_showAdvanced),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return Stack(
      children: [
        Positioned.fill(child: report),
        // Tap-away scrim behind any open overlay.
        if (_editing != null || _menuFor != null)
          Positioned.fill(
            child: Listener(
              onPointerDown: (_) => _closeOverlays(),
              behavior: HitTestBehavior.translucent,
              child: const SizedBox.expand(),
            ),
          ),
        if (_menuFor != null) _buildContextMenu(),
        if (_editing != null) _buildInspector(),
      ],
    );
  }

  // ── Edit-intent wiring ──────────────────────────────────────────────────────

  ElectricalProjectController get _controller =>
      ref.read(electricalProjectProvider.notifier);

  void _onDropLoad(String panelId, LoadKind kind) =>
      _controller.addCircuit(panelId, kind: kind);

  void _onAddCircuit(String panelId) =>
      _controller.addCircuit(panelId, kind: LoadKind.general);

  void _addPanel() {
    final n = ref.read(electricalProjectProvider).panels.length + 1;
    _controller.addPanel(name: 'Sub-panel $n', tag: 'SP-$n');
  }

  // ── Overlays ────────────────────────────────────────────────────────────────

  Widget _buildContextMenu() {
    final ref0 = _menuFor!;
    return Positioned(
      left: _menuAt.dx,
      top: _menuAt.dy,
      child: _ContextMenu(
        onEdit: () => setState(() {
          _editing = ref0;
          _menuFor = null;
        }),
        onDuplicate: () {
          _controller.duplicateCircuit(ref0.panelId, ref0.circuitId);
          setState(() => _menuFor = null);
        },
        onDelete: () {
          _controller.deleteCircuit(ref0.panelId, ref0.circuitId);
          setState(() => _menuFor = null);
        },
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
      // The circuit was deleted underneath us — close.
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

// ── Header ──────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final String projectName;
  final VoidCallback onAddPanel;
  const _Header({required this.projectName, required this.onAddPanel});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text('Electrical',
            style: type.display.copyWith(color: colors.textPrimary)),
        const SizedBox(width: MechXSpacing.sm),
        Flexible(
          child: Text(
            projectName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: type.body.copyWith(color: colors.textMuted),
          ),
        ),
        const Spacer(),
        _TextButton(label: '+ Panel', onTap: onAddPanel),
        const SizedBox(width: MechXSpacing.md),
        Text(
          'PUIL 2011 / IEC 60364',
          style: type.caption.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}

// ── Palette ───────────────────────────────────────────────────────────────────

/// The load palette — one draggable card per [LoadKind] (excluding the
/// auto-managed feeder), each showing the standards-derived cos φ + demand.
/// Drag a card onto a panel card to add a way of that kind.
class _Palette extends StatelessWidget {
  // Order chosen for the typical workflow; feeder is created by linking panels.
  static const _kinds = <LoadKind>[
    LoadKind.lighting,
    LoadKind.socket,
    LoadKind.hvac,
    LoadKind.motor,
    LoadKind.pump,
    LoadKind.heating,
    LoadKind.ups,
    LoadKind.evCharger,
    LoadKind.welding,
    LoadKind.general,
    LoadKind.spare,
  ];

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return _Card(
      title: 'Loads',
      trailing: 'drag onto a panel',
      child: Wrap(
        spacing: MechXSpacing.sm,
        runSpacing: MechXSpacing.sm,
        children: [
          for (final k in _kinds) _PaletteCard(kind: k),
          Padding(
            padding: const EdgeInsets.only(left: MechXSpacing.xs),
            child: Align(
              alignment: Alignment.center,
              child: Text(
                'cos phi / demand from PUIL load defaults',
                style: type.caption.copyWith(color: colors.textMuted),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PaletteCard extends StatelessWidget {
  final LoadKind kind;
  const _PaletteCard({required this.kind});

  @override
  Widget build(BuildContext context) {
    final d = loadDefaults[kind];
    final label = d?.label ?? kind.name;
    final sub = d == null
        ? ''
        : 'pf ${_a(d.cosPhi)} / df ${_a(d.demandFactor)}';

    final card = _PaletteChrome(label: label, sub: sub);
    return Draggable<LoadKind>(
      data: kind,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _DragFeedback(label: label),
      childWhenDragging: Opacity(opacity: 0.4, child: card),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: card,
      ),
    );
  }
}

class _PaletteChrome extends StatelessWidget {
  final String label;
  final String sub;
  const _PaletteChrome({required this.label, required this.sub});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MechXSpacing.sm + 2,
        vertical: MechXSpacing.xs + 2,
      ),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: MechXRadii.control,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: type.label.copyWith(color: colors.textPrimary)),
          if (sub.isNotEmpty)
            Text(sub, style: type.caption.copyWith(color: colors.textMuted)),
        ],
      ),
    );
  }
}

class _DragFeedback extends StatelessWidget {
  final String label;
  const _DragFeedback({required this.label});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Transform.translate(
      offset: const Offset(8, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: MechXSpacing.sm + 2,
          vertical: MechXSpacing.xs + 2,
        ),
        decoration: BoxDecoration(
          color: colors.accent,
          borderRadius: MechXRadii.control,
          border: Border.all(color: colors.accent),
        ),
        child: Text(label,
            style: type.label.copyWith(color: const Color(0xFFFFFFFF))),
      ),
    );
  }
}

// ── Cards ────────────────────────────────────────────────────────────────────

/// A titled, bordered card on the surface colour — the grouped-inset container.
class _Card extends StatelessWidget {
  final String title;
  final String? trailing;
  final Widget? action;
  final Widget child;
  const _Card({
    required this.title,
    this.trailing,
    this.action,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              MechXSpacing.md,
              MechXSpacing.md,
              MechXSpacing.md,
              MechXSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: type.subtitle.copyWith(color: colors.textPrimary)),
                ),
                if (trailing != null)
                  Padding(
                    padding: const EdgeInsets.only(right: MechXSpacing.sm),
                    child: Text(trailing!,
                        style: type.caption.copyWith(color: colors.textMuted)),
                  ),
                ?action,
              ],
            ),
          ),
          Container(height: 1, color: colors.border),
          Padding(
            padding: const EdgeInsets.all(MechXSpacing.md),
            child: child,
          ),
        ],
      ),
    );
  }
}

/// The project supply + earthing summary.
class _SupplyCard extends StatelessWidget {
  final SupplySummary supply;
  final EarthingResult earthing;
  const _SupplyCard({required this.supply, required this.earthing});

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'Supply & earthing',
      trailing: supply.system.label,
      child: Wrap(
        spacing: MechXSpacing.xl,
        runSpacing: MechXSpacing.sm,
        children: [
          _Metric(label: 'Connected', value: _kw(supply.connectedW)),
          _Metric(label: 'Demand', value: _kw(supply.demandW)),
          _Metric(
              label: 'Apparent', value: _kva(supply.demandVa.inKilovoltAmperes)),
          _Metric(label: 'Voltage', value: '${supply.voltage.volts.round()} V'),
          _Metric(label: 'Earthing', value: earthing.label),
          _Metric(
            label: 'RCD policy',
            value: earthing.requiresRcd ? 'RCD on all finals' : 'Per circuit',
          ),
        ],
      ),
    );
  }
}

/// A label-over-value figure block; the value is monospaced for tabular reading.
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

/// One distribution panel: header, summary metrics, then the load schedule.
/// A [DragTarget] for a [LoadKind] dropped from the palette.
class _PanelCard extends StatelessWidget {
  final ElectricalPanelResult panel;
  final ValueChanged<LoadKind> onDropLoad;
  final VoidCallback onAddCircuit;
  final ValueChanged<String> onEditRow;
  final void Function(String circuitId, Offset globalPos) onMenuRow;

  const _PanelCard({
    required this.panel,
    required this.onDropLoad,
    required this.onAddCircuit,
    required this.onEditRow,
    required this.onMenuRow,
  });

  @override
  Widget build(BuildContext context) {
    final tag = panel.tag;
    final title =
        tag != null && tag.isNotEmpty ? '$tag · ${panel.name}' : panel.name;

    return DragTarget<LoadKind>(
      onAcceptWithDetails: (d) => onDropLoad(d.data),
      builder: (context, candidate, rejected) {
        final hovering = candidate.isNotEmpty;
        return _DropHighlight(
          active: hovering,
          child: _Card(
            title: title,
            trailing: '${panel.system.label} · ${panel.circuits.length} ways',
            action: _TextButton(label: '+ Way', onTap: onAddCircuit),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Panel summary metrics.
                Wrap(
                  spacing: MechXSpacing.xl,
                  runSpacing: MechXSpacing.sm,
                  children: [
                    _Metric(
                      label: 'Incomer',
                      value:
                          '${_amp(panel.incomer.breaker.ratingA.amperes)} · ${panel.incomer.poles}P',
                    ),
                    _Metric(label: 'Busbar', value: _busbar(panel.busbar)),
                    _Metric(label: 'Connected', value: _kw(panel.connectedW)),
                    _Metric(label: 'Demand', value: _kw(panel.demandW)),
                    _Metric(
                        label: 'Demand current',
                        value: _amp(panel.demandCurrent.amperes)),
                    if (panel.system == ElectricalSystem.threePhase)
                      _Metric(
                        label: 'Phase balance',
                        value:
                            'L1 ${_a(panel.phaseBalance.l1)} · L2 ${_a(panel.phaseBalance.l2)} · '
                            'L3 ${_a(panel.phaseBalance.l3)}  (${_a(panel.imbalancePercent)}%)',
                      ),
                  ],
                ),
                const SizedBox(height: MechXSpacing.md),
                _ScheduleTable(
                  circuits: panel.circuits,
                  onEditRow: onEditRow,
                  onMenuRow: onMenuRow,
                ),
                if (panel.warnings.isNotEmpty) ...[
                  const SizedBox(height: MechXSpacing.sm),
                  for (final w in panel.warnings)
                    _WarningRow(warning: w, compact: true),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Wraps a card with an accent ring when a palette card is hovering over it.
class _DropHighlight extends StatelessWidget {
  final bool active;
  final Widget child;
  const _DropHighlight({required this.active, required this.child});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AnimatedContainer(
      duration: MechXMotion.fast,
      decoration: BoxDecoration(
        borderRadius: MechXRadii.card,
        border: Border.all(
          color: active ? colors.accent : const Color(0x00000000),
          width: 2,
        ),
      ),
      child: child,
    );
  }
}

/// The per-panel load schedule (one row per outgoing way).
class _ScheduleTable extends StatelessWidget {
  final List<ElectricalCircuitResult> circuits;
  final ValueChanged<String> onEditRow;
  final void Function(String circuitId, Offset globalPos) onMenuRow;
  const _ScheduleTable({
    required this.circuits,
    required this.onEditRow,
    required this.onMenuRow,
  });

  // Relative column widths — name is the only flexible column.
  static const _w = <int>[34, 9, 11, 22, 7, 8, 9];

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (circuits.isEmpty) {
      return Text('No outgoing ways. Drag a load here or use "+ Way".',
          style: context.type.caption.copyWith(color: colors.textMuted));
    }
    return Container(
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: MechXRadii.control,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        children: [
          const _ScheduleHeader(),
          for (var i = 0; i < circuits.length; i++)
            _ScheduleRow(
              circuit: circuits[i],
              shaded: i.isOdd,
              onEdit: () => onEditRow(circuits[i].circuitId),
              onMenu: (pos) => onMenuRow(circuits[i].circuitId, pos),
            ),
        ],
      ),
    );
  }
}

class _ScheduleHeader extends StatelessWidget {
  const _ScheduleHeader();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    Widget head(String t, int flex, {TextAlign align = TextAlign.left}) =>
        Expanded(
          flex: flex,
          child: Text(
            t,
            textAlign: align,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: type.caption.copyWith(
              color: colors.textMuted,
              letterSpacing: 0.6,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MechXSpacing.sm,
        vertical: MechXSpacing.xs + 1,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          head('CIRCUIT', _ScheduleTable._w[0]),
          head('Ib', _ScheduleTable._w[1], align: TextAlign.right),
          const SizedBox(width: MechXSpacing.sm),
          head('BREAKER', _ScheduleTable._w[2]),
          head('CABLE', _ScheduleTable._w[3]),
          head('Vd%', _ScheduleTable._w[4], align: TextAlign.right),
          head('cumVd%', _ScheduleTable._w[5], align: TextAlign.right),
          head('RCD / ph', _ScheduleTable._w[6], align: TextAlign.right),
        ],
      ),
    );
  }
}

class _ScheduleRow extends StatefulWidget {
  final ElectricalCircuitResult circuit;
  final bool shaded;
  final VoidCallback onEdit;
  final ValueChanged<Offset> onMenu;
  const _ScheduleRow({
    required this.circuit,
    required this.shaded,
    required this.onEdit,
    required this.onMenu,
  });

  @override
  State<_ScheduleRow> createState() => _ScheduleRowState();
}

class _ScheduleRowState extends State<_ScheduleRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final circuit = widget.circuit;

    final mono = type.mono.copyWith(color: colors.textSecondary);
    final name = type.body.copyWith(color: colors.textPrimary);

    final vd = circuit.voltageDrop;
    final vdColor = vd.withinLimit ? colors.textSecondary : colors.danger;
    final cumColor = circuit.cumulativeDropPercent <= vd.limitPercent + 1e-9
        ? colors.textMuted
        : colors.danger;

    final rcdLabel = circuit.rcd.required
        ? '${circuit.rcd.ratingMa}mA${circuit.rcd.type != null ? ' ${_rcdType(circuit.rcd.type!)}' : ''}'
        : '-';

    Widget cell(Widget w, int flex, {Alignment align = Alignment.centerLeft}) =>
        Expanded(flex: flex, child: Align(alignment: align, child: w));

    final bg = widget.shaded
        ? colors.surfaceHover
        : (_hover ? colors.surfaceHover : const Color(0x00000000));

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Listener(
        onPointerDown: (e) {
          if (e.buttons == kSecondaryButton) {
            widget.onMenu(e.position);
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: widget.onEdit,
          child: AnimatedContainer(
            duration: MechXMotion.instant,
            padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.sm,
              vertical: MechXSpacing.xs + 2,
            ),
            color: bg,
            child: Row(
              children: [
                cell(
                  Text(circuit.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: name),
                  _ScheduleTable._w[0],
                ),
                cell(
                  Text(_a(circuit.designCurrent.amperes), style: mono),
                  _ScheduleTable._w[1],
                  align: Alignment.centerRight,
                ),
                const SizedBox(width: MechXSpacing.sm),
                cell(
                  Text(_breaker(circuit.breaker),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: mono),
                  _ScheduleTable._w[2],
                ),
                cell(
                  Text(circuit.grounding.cableSpec,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: mono),
                  _ScheduleTable._w[3],
                ),
                cell(
                  Text(_a(vd.dropPercent), style: mono.copyWith(color: vdColor)),
                  _ScheduleTable._w[4],
                  align: Alignment.centerRight,
                ),
                cell(
                  Text(_a(circuit.cumulativeDropPercent),
                      style: mono.copyWith(color: cumColor)),
                  _ScheduleTable._w[5],
                  align: Alignment.centerRight,
                ),
                cell(
                  Text('$rcdLabel · ${circuit.phase.label}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono),
                  _ScheduleTable._w[6],
                  align: Alignment.centerRight,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The consolidated project warnings list.
class _WarningsCard extends StatelessWidget {
  final List<ElectricalWarning> warnings;
  const _WarningsCard({required this.warnings});

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'Warnings',
      trailing: '${warnings.length}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final w in warnings) _WarningRow(warning: w),
        ],
      ),
    );
  }
}

class _WarningRow extends StatelessWidget {
  final ElectricalWarning warning;
  final bool compact;
  const _WarningRow({required this.warning, this.compact = false});

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
      padding: EdgeInsets.symmetric(
          vertical: compact ? MechXSpacing.xxs : MechXSpacing.xs),
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
            child: Text(
              warning.message,
              style: (compact ? type.caption : type.body)
                  .copyWith(color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Advanced study ────────────────────────────────────────────────────────────

/// A compact, read-only summary of the A8 advanced study (fault / supply / PF /
/// arc-flash / harmonics / containment / enclosure / metering / SPD / lightning).
class _AdvancedCard extends StatelessWidget {
  final AdvancedStudy advanced;
  final ElectricalSystemResult result;
  final bool expanded;
  final VoidCallback onToggle;
  const _AdvancedCard({
    required this.advanced,
    required this.result,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return _Card(
      title: 'Advanced study',
      trailing: expanded ? 'PUIL / IEC / IEEE-1584' : null,
      action: _TextButton(
        label: expanded ? 'Hide' : 'Show',
        onTap: onToggle,
      ),
      child: expanded
          ? _buildBody(context)
          : Text(
              'Fault, supply, power factor, arc-flash, harmonics, containment, '
              'enclosure, metering, SPD and lightning passes.',
              style: context.type.caption.copyWith(color: colors.textMuted),
            ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final supply = advanced.supply;
    final pf = advanced.powerFactor;
    final fault = advanced.fault;

    // Project-level metrics.
    final projectMetrics = <_Metric>[
      _Metric(
          label: 'Supply',
          value: supply.lvOrMv == SupplyLevel.mv && supply.transformerKva != null
              ? 'MV · ${_a(supply.transformerKva!)} kVA${supply.units > 1 ? ' x${supply.units}' : ''}'
              : 'LV direct'),
      _Metric(label: 'Daya', value: '${(advanced.recommendedDayaVa / 1000).toStringAsFixed(1)} kVA'),
      _Metric(label: 'Origin Isc', value: '${_a(fault.originFaultkA)} kA'),
      _Metric(
        label: 'Power factor',
        value: pf.needed
            ? '${_a(pf.existingPf)} -> ${_a(pf.targetPf)}'
            : '${_a(pf.existingPf)} (OK)',
      ),
      if (pf.needed)
        _Metric(
            label: 'Capacitor',
            value:
                '${_a(pf.bankKvar)} kvar${pf.steps > 0 ? ' / ${pf.steps} steps' : ''}${pf.detuned ? ' detuned' : ''}'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: MechXSpacing.xl,
          runSpacing: MechXSpacing.sm,
          children: projectMetrics,
        ),
        if (advanced.lightning != null || advanced.electrode != null) ...[
          const SizedBox(height: MechXSpacing.sm),
          Wrap(
            spacing: MechXSpacing.xl,
            runSpacing: MechXSpacing.sm,
            children: [
              if (advanced.lightning != null)
                _Metric(
                  label: 'Lightning',
                  value: advanced.lightning!.lpsRequired
                      ? 'LPS ${advanced.lightning!.level?.label ?? 'req'}'
                      : 'not required',
                ),
              if (advanced.electrode != null)
                _Metric(
                  label: 'Electrode',
                  value: '${advanced.electrode!.rodCount} rods',
                ),
            ],
          ),
        ],
        const SizedBox(height: MechXSpacing.md),
        Container(height: 1, color: context.colors.border),
        const SizedBox(height: MechXSpacing.sm),
        _AdvancedPanelTable(advanced: advanced, result: result),
        const SizedBox(height: MechXSpacing.sm),
        Text(
          'Estimates — verify against PUIL 2011 / IEC 60364. '
          '${advanced.verifyItems.length} value(s) pending verification.',
          style: context.type.caption.copyWith(color: context.colors.textMuted),
        ),
      ],
    );
  }
}

/// A per-panel matrix of the advanced passes (one row per panel).
class _AdvancedPanelTable extends StatelessWidget {
  final AdvancedStudy advanced;
  final ElectricalSystemResult result;
  const _AdvancedPanelTable({required this.advanced, required this.result});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;

    // A padded cell keeps adjacent columns from touching; every column is
    // left-aligned with a small right gap so the matrix reads cleanly.
    Widget head(String t, int flex) => Expanded(
          flex: flex,
          child: Padding(
            padding: const EdgeInsets.only(right: MechXSpacing.sm),
            child: Text(t,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: type.caption.copyWith(
                  color: colors.textMuted,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                )),
          ),
        );

    Widget cell(String t, int flex) => Expanded(
          flex: flex,
          child: Padding(
            padding: const EdgeInsets.only(right: MechXSpacing.sm),
            child: Text(t,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: type.mono.copyWith(color: colors.textSecondary)),
          ),
        );

    final rows = <Widget>[];
    for (final id in result.order) {
      final panel = result.panels[id];
      if (panel == null) continue;
      final encl = advanced.enclosure[id];
      final arc = advanced.arcFlash[id];
      final harm = advanced.harmonics[id];
      final cont = advanced.containment[id];
      final spd = advanced.spd[id];
      final meter = advanced.metering[id];
      final pf = advanced.fault.panels[id];

      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs + 1),
        child: Row(
          children: [
            Expanded(
              flex: 22,
              child: Padding(
                padding: const EdgeInsets.only(right: MechXSpacing.sm),
                child: Text(panel.tag ?? panel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.body.copyWith(color: colors.textPrimary)),
              ),
            ),
            cell(
                pf != null
                    ? '${_a(pf.prospectiveFaultkA)} kA${pf.incomerAdequate ? '' : ' !'}'
                    : '-',
                13),
            cell(
                arc != null
                    ? _ppeShort(arc.incidentEnergyCalCm2, arc.ppeCategory.label)
                    : '-',
                16),
            cell(harm != null ? harm.thdBand.label : 'low', 10),
            cell(cont != null ? '${_a(cont.tray.widthMm)} mm' : '-', 11),
            cell(
                encl != null
                    ? '${_a(encl.widthMm)}x${_a(encl.heightMm)}x${_a(encl.depthMm)}'
                    : '-',
                20),
            cell(meter?.metering.label ?? '-', 9),
            cell(spd?.type.label ?? '-', 11),
          ],
        ),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
          child: Row(
            children: [
              head('PANEL', 22),
              head('FAULT', 13),
              head('ARC PPE', 16),
              head('THD', 10),
              head('TRAY', 11),
              head('ENCLOSURE', 20),
              head('METER', 9),
              head('SPD', 11),
            ],
          ),
        ),
        ...rows,
      ],
    );
  }
}

// ── Context menu ──────────────────────────────────────────────────────────────

/// A small custom right-click menu (no Material `showMenu`). Anchored by the
/// parent `Positioned`.
class _ContextMenu extends StatelessWidget {
  final VoidCallback onEdit;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;
  const _ContextMenu({
    required this.onEdit,
    required this.onDuplicate,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: 168,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.control,
        border: Border.all(color: colors.border),
        boxShadow: [
          BoxShadow(
            color: const Color(0x33000000),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MenuItem(label: 'Edit', onTap: onEdit),
          _MenuItem(label: 'Duplicate', onTap: onDuplicate),
          _MenuItem(label: 'Delete', onTap: onDelete, danger: true),
        ],
      ),
    );
  }
}

class _MenuItem extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final bool danger;
  const _MenuItem({required this.label, required this.onTap, this.danger = false});

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
            horizontal: MechXSpacing.sm + 2,
            vertical: MechXSpacing.xs + 3,
          ),
          color: _hover ? colors.surfaceHover : const Color(0x00000000),
          child: Text(
            widget.label,
            style: type.body.copyWith(
              color: widget.danger ? colors.danger : colors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Circuit inspector ─────────────────────────────────────────────────────────

/// A right-side drawer to edit one circuit's fields. Custom MechXTheme panel —
/// no Material dialog. Edits route straight through the store's [setCircuit].
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
        boxShadow: [
          BoxShadow(
            color: const Color(0x22000000),
            blurRadius: 16,
            offset: const Offset(-2, 0),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              MechXSpacing.md,
              MechXSpacing.md,
              MechXSpacing.sm,
              MechXSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text('Edit circuit',
                      style: type.subtitle.copyWith(color: colors.textPrimary)),
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
                      onChanged: (v) => controller.setCircuit(
                          panel.id, circuit.id,
                          name: v),
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
                      onChanged: (k) => controller.setCircuit(
                          panel.id, circuit.id,
                          loadKind: k),
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

/// A label-over-control row used inside the inspector.
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

/// A minimal text input (rebuilt on the incoming value via its key by callers).
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
          horizontal: MechXSpacing.sm,
          vertical: MechXSpacing.xs + 2,
        ),
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

/// A numeric text input — parses on change, ignores non-numeric input.
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
          horizontal: MechXSpacing.sm,
          vertical: MechXSpacing.xs + 2,
        ),
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

/// A horizontal segmented picker for an enum-like value (no Material dropdown).
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
            horizontal: MechXSpacing.sm,
            vertical: MechXSpacing.xs + 1,
          ),
          decoration: BoxDecoration(
            color: selected ? colors.accent : colors.background,
            borderRadius: MechXRadii.control,
            border:
                Border.all(color: selected ? colors.accent : colors.border),
          ),
          child: Text(
            label,
            style: type.label.copyWith(
              color: selected ? const Color(0xFFFFFFFF) : colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// A label + on/off toggle row (custom switch).
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
                alignment:
                    value ? Alignment.centerRight : Alignment.centerLeft,
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

/// A small bordered text button (local; matches the report's restrained chrome).
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
            horizontal: MechXSpacing.sm + 2,
            vertical: MechXSpacing.xs + 1,
          ),
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

// ── Formatting helpers (display boundary — convert SI → engineering units) ────

String _a(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

String _amp(double a) => '${_a(a)} A';

String _kw(double w) => '${(w / 1000).toStringAsFixed(1)} kW';

String _kva(double kva) => '${kva.toStringAsFixed(1)} kVA';

String _breaker(BreakerResult b) {
  final cls = b.deviceClass == BreakerClass.mccb ? 'MCCB' : 'MCB';
  final curve = b.curve.name.toUpperCase();
  return '${_a(b.ratingA.amperes)}A $cls·$curve';
}

/// A compact arc-flash cell: the PPE category's leading token (e.g. "CAT 2",
/// "No PPE", "No safe") plus the incident energy in cal/cm².
String _ppeShort(double energyCalCm2, String fullLabel) {
  final lead = fullLabel.startsWith('CAT')
      ? fullLabel.substring(0, 5).trim()
      : (fullLabel.startsWith('No safe') ? 'de-energize' : 'No PPE');
  return '$lead · ${_a(energyCalCm2)}';
}

String _busbar(BusbarResult b) {
  if (b.widthMm > 0 && b.thicknessMm > 0) {
    return '${_a(b.widthMm)}×${_a(b.thicknessMm)} mm';
  }
  return '${_a(b.csaMm2)} mm2';
}

String _rcdType(RcdType t) => switch (t) {
      RcdType.ac => 'AC',
      RcdType.a => 'A',
      RcdType.f => 'F',
      RcdType.b => 'B',
    };
