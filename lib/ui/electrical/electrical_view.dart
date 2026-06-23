/// The Electrical ("E") workspace — a read-only render of the sized electrical
/// system (`electricalResultProvider`). Surfaces, per panel, the load-list /
/// panel schedule (circuit · design current · breaker · cable · Vd% · cumulative
/// Vd% · RCD · phase), the panel summary (incomer, busbar, connected / demand,
/// phase balance), the project supply summary and a consolidated warnings list.
///
/// Styled entirely with MechXTheme tokens (grouped inset lists, monospaced
/// figures via Roboto Mono). No Material/Fluent. Editing is deferred — this is
/// the A7 first cut. The pure A4 engine does all the calculation; this widget
/// only reads its result records.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/results.dart';
import 'package:mechx_engine/standards/puil.dart';

import '../../store/electrical_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

/// Renders the electrical system from the live Riverpod result. Pointer-passive
/// (a scrollable report); sizes itself to fill the available space.
class ElectricalView extends ConsumerWidget {
  const ElectricalView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final result = ref.watch(electricalResultProvider);
    final project = ref.watch(electricalProjectProvider);

    final panels = [
      for (final id in result.order)
        if (result.panels[id] != null) result.panels[id]!,
    ];

    return ColoredBox(
      color: colors.canvas,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(MechXSpacing.lg),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1080),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(projectName: project.name),
                const SizedBox(height: MechXSpacing.md),
                _SupplyCard(supply: result.supply, earthing: result.earthing),
                const SizedBox(height: MechXSpacing.lg),
                if (result.warnings.isNotEmpty) ...[
                  _WarningsCard(warnings: result.warnings),
                  const SizedBox(height: MechXSpacing.lg),
                ],
                for (final panel in panels) ...[
                  _PanelCard(panel: panel),
                  const SizedBox(height: MechXSpacing.lg),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String projectName;
  const _Header({required this.projectName});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
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
        Text(
          'PUIL 2011 / IEC 60364',
          style: type.caption.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}

// ── Cards ────────────────────────────────────────────────────────────────────

/// A titled, bordered card on the surface colour — the grouped-inset container.
class _Card extends StatelessWidget {
  final String title;
  final String? trailing;
  final Widget child;
  const _Card({required this.title, this.trailing, required this.child});

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
                  Text(trailing!,
                      style:
                          type.caption.copyWith(color: colors.textMuted)),
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
class _PanelCard extends StatelessWidget {
  final ElectricalPanelResult panel;
  const _PanelCard({required this.panel});

  @override
  Widget build(BuildContext context) {
    final tag = panel.tag;
    final title = tag != null && tag.isNotEmpty ? '$tag · ${panel.name}' : panel.name;

    return _Card(
      title: title,
      trailing: '${panel.system.label} · ${panel.circuits.length} ways',
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
              _Metric(
                label: 'Busbar',
                value: _busbar(panel.busbar),
              ),
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
          _ScheduleTable(circuits: panel.circuits),
          if (panel.warnings.isNotEmpty) ...[
            const SizedBox(height: MechXSpacing.sm),
            for (final w in panel.warnings)
              _WarningRow(warning: w, compact: true),
          ],
        ],
      ),
    );
  }
}

/// The per-panel load schedule (one row per outgoing way).
class _ScheduleTable extends StatelessWidget {
  final List<ElectricalCircuitResult> circuits;
  const _ScheduleTable({required this.circuits});

  // Relative column widths — name is the only flexible column.
  static const _w = <int>[34, 9, 11, 22, 7, 8, 9];

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (circuits.isEmpty) {
      return Text('No outgoing ways.',
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
            _ScheduleRow(circuit: circuits[i], shaded: i.isOdd),
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
          head('ΣVd%', _ScheduleTable._w[5], align: TextAlign.right),
          head('RCD / φ', _ScheduleTable._w[6], align: TextAlign.right),
        ],
      ),
    );
  }
}

class _ScheduleRow extends StatelessWidget {
  final ElectricalCircuitResult circuit;
  final bool shaded;
  const _ScheduleRow({required this.circuit, required this.shaded});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;

    final mono = type.mono.copyWith(color: colors.textSecondary);
    final name = type.body.copyWith(color: colors.textPrimary);

    final vd = circuit.voltageDrop;
    final vdColor = vd.withinLimit ? colors.textSecondary : colors.danger;
    final cumColor = circuit.cumulativeDropPercent <= vd.limitPercent + 1e-9
        ? colors.textMuted
        : colors.danger;

    final rcdLabel = circuit.rcd.required
        ? '${circuit.rcd.ratingMa}mA${circuit.rcd.type != null ? ' ${_rcdType(circuit.rcd.type!)}' : ''}'
        : '—';

    Widget cell(Widget w, int flex, {Alignment align = Alignment.centerLeft}) =>
        Expanded(flex: flex, child: Align(alignment: align, child: w));

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MechXSpacing.sm,
        vertical: MechXSpacing.xs + 2,
      ),
      color: shaded ? colors.surfaceHover : const Color(0x00000000),
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
                maxLines: 1, overflow: TextOverflow.ellipsis, style: mono),
            _ScheduleTable._w[6],
            align: Alignment.centerRight,
          ),
        ],
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
            margin: const EdgeInsets.only(
                top: 5, right: MechXSpacing.sm),
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

// ── Formatting helpers (display boundary — convert SI → engineering units) ────

String _a(double v) => v == v.roundToDouble()
    ? v.toInt().toString()
    : v.toStringAsFixed(1);

String _amp(double a) => '${_a(a)} A';

String _kw(double w) => '${(w / 1000).toStringAsFixed(1)} kW';

String _kva(double kva) => '${kva.toStringAsFixed(1)} kVA';

String _breaker(BreakerResult b) {
  final cls = b.deviceClass == BreakerClass.mccb ? 'MCCB' : 'MCB';
  final curve = b.curve.name.toUpperCase();
  return '${_a(b.ratingA.amperes)}A $cls·$curve';
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
