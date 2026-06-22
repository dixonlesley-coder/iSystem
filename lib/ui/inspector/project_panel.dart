import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

import '../../store/calibration_store.dart';
import '../../store/fire_store.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import '../../store/sizing_store.dart';
import '../../store/solve_store.dart';
import '../canvas/service_style.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_text_field.dart';

/// Right inspector: project details, per-floor heights (the vertical
/// length source of truth, §10), and the per-sheet scale-calibration status.
class ProjectPanel extends ConsumerWidget {
  const ProjectPanel({super.key});

  static const double width = 296;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final project = ref.watch(projectControllerProvider);
    final ctrl = ref.read(projectControllerProvider.notifier);
    final building = project.building;
    final currentSheet = ref.watch(sheetsControllerProvider).current;
    final calibration =
        currentSheet == null ? null : project.calibrationFor(currentSheet.id);

    return SizedBox(
      width: width,
      child: ColoredBox(
        color: colors.surface,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(MechXSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SectionLabel('Project'),
              const SizedBox(height: MechXSpacing.sm),
              MechXTextField(
                value: project.name,
                onChanged: ctrl.setName,
              ),
              const SizedBox(height: MechXSpacing.lg),

              // ── Building / floor heights ──────────────────────────────────
              Row(
                children: [
                  Expanded(child: _SectionLabel('Building')),
                  Text(
                    '${building.totalHeight.meters.toStringAsFixed(1)} m · '
                    '${building.levelCount} levels',
                    style: type.caption.copyWith(color: colors.textMuted),
                  ),
                ],
              ),
              const SizedBox(height: MechXSpacing.sm),
              // Top floor first.
              for (var i = project.floors.length - 1; i >= 0; i--)
                _FloorRow(
                  name: project.floors[i].name,
                  height: project.floors[i].height,
                  elevation: building.elevationOf(i),
                  onMinus: () => ctrl.nudgeFloorHeight(i, -0.1),
                  onPlus: () => ctrl.nudgeFloorHeight(i, 0.1),
                  onRemove: project.floors.length > 1
                      ? () => ctrl.removeFloor(i)
                      : null,
                ),
              const SizedBox(height: MechXSpacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: MechXButton(label: '+  Add level', onPressed: ctrl.addFloor),
              ),
              const SizedBox(height: MechXSpacing.lg),

              // ── Draw ──────────────────────────────────────────────────────
              const _DrawSection(),
              const SizedBox(height: MechXSpacing.lg),

              // ── Sizing ────────────────────────────────────────────────────
              const _SizingSection(),
              const SizedBox(height: MechXSpacing.lg),

              // ── Network results ───────────────────────────────────────────
              const _ResultsSection(),
              const SizedBox(height: MechXSpacing.lg),

              // ── Fire protection ───────────────────────────────────────────
              const _FireSection(),
              const SizedBox(height: MechXSpacing.lg),

              // ── Scale calibration ─────────────────────────────────────────
              _SectionLabel('Scale'),
              const SizedBox(height: MechXSpacing.sm),
              Container(
                padding: const EdgeInsets.all(MechXSpacing.sm),
                decoration: BoxDecoration(
                  color: colors.background,
                  borderRadius: MechXRadii.control,
                  border: Border.all(color: colors.border),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      margin: const EdgeInsets.only(right: MechXSpacing.sm),
                      decoration: BoxDecoration(
                        color: calibration == null
                            ? colors.warning
                            : colors.success,
                        borderRadius: const BorderRadius.all(Radius.circular(4)),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        calibration == null
                            ? 'Not calibrated — mark a known distance'
                            : '1 px = ${calibration.metersPerPixel.toStringAsExponential(2)} m',
                        style: type.caption.copyWith(color: colors.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
              if (currentSheet != null) ...[
                const SizedBox(height: MechXSpacing.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: MechXButton(
                    label: calibration == null
                        ? 'Calibrate scale'
                        : 'Re-calibrate',
                    onPressed: () =>
                        ref.read(calibrationControllerProvider.notifier).start(),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: context.type.caption.copyWith(
          color: context.colors.textMuted,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
        ),
      );
}

class _FloorRow extends StatelessWidget {
  final String name;
  final Length height;
  final Length elevation;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  final VoidCallback? onRemove;

  const _FloorRow({
    required this.name,
    required this.height,
    required this.elevation,
    required this.onMinus,
    required this.onPlus,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.body.copyWith(color: colors.textPrimary)),
                Text('elev ${elevation.meters.toStringAsFixed(1)} m',
                    style: type.caption.copyWith(color: colors.textMuted)),
              ],
            ),
          ),
          _GlyphButton(glyph: '−', onTap: onMinus),
          SizedBox(
            width: 56,
            child: Text(
              '${height.meters.toStringAsFixed(1)} m',
              textAlign: TextAlign.center,
              style: type.mono.copyWith(color: colors.textPrimary),
            ),
          ),
          _GlyphButton(glyph: '+', onTap: onPlus),
          const SizedBox(width: MechXSpacing.xs),
          _GlyphButton(
            glyph: '×',
            onTap: onRemove,
            danger: true,
          ),
        ],
      ),
    );
  }
}

class _GlyphButton extends StatefulWidget {
  final String glyph;
  final VoidCallback? onTap;
  final bool danger;
  const _GlyphButton({required this.glyph, required this.onTap, this.danger = false});

  @override
  State<_GlyphButton> createState() => _GlyphButtonState();
}

class _GlyphButtonState extends State<_GlyphButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabled = widget.onTap != null;
    final fg = !enabled
        ? colors.textMuted.withAlpha(90)
        : widget.danger
            ? (_hover ? colors.danger : colors.textMuted)
            : (_hover ? colors.textPrimary : colors.textSecondary);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hover && enabled ? colors.surfaceHover : const Color(0x00000000),
            borderRadius: MechXRadii.control,
          ),
          child: Text(
            widget.glyph,
            style: TextStyle(fontFamily: 'Roboto', fontSize: 16, height: 1.0, color: fg),
          ),
        ),
      ),
    );
  }
}

class _DrawSection extends ConsumerWidget {
  const _DrawSection();

  static const List<ServiceType> _services = [
    ServiceType.coldWater,
    ServiceType.hotWater,
    ServiceType.drainage,
    ServiceType.vent,
    ServiceType.duct,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drawing = ref.watch(networkControllerProvider);
    final ctrl = ref.read(networkControllerProvider.notifier);

    Widget tool(String label, DrawTool t) => MechXButton(
          label: label,
          primary: drawing.tool == t,
          onPressed: () => ctrl.setTool(t),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionLabel('Draw'),
        const SizedBox(height: MechXSpacing.sm),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            tool('Select', DrawTool.select),
            tool('Run', DrawTool.drawRun),
            tool('Riser', DrawTool.drawRiser),
          ],
        ),
        const SizedBox(height: MechXSpacing.sm),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            for (final s in _services)
              _ServiceChip(
                service: s,
                selected: drawing.service == s,
                onTap: () => ctrl.setService(s),
              ),
          ],
        ),
        const SizedBox(height: MechXSpacing.sm),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            MechXButton(label: 'Undo', onPressed: ctrl.undo),
            MechXButton(label: 'Redo', onPressed: ctrl.redo),
            MechXButton(label: 'Clear', onPressed: ctrl.clear),
          ],
        ),
      ],
    );
  }
}

class _SizingSection extends ConsumerWidget {
  const _SizingSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final show = ref.watch(showSizingProvider);
    final sized = ref.watch(sizingProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionLabel('Sizing'),
        const SizedBox(height: MechXSpacing.sm),
        Row(
          children: [
            MechXButton(
              label: show ? 'Hide sizes' : 'Show sizes',
              primary: show,
              onPressed: () => ref.read(showSizingProvider.notifier).toggle(),
            ),
            const Spacer(),
            Text(
              '${sized.length} sized',
              style: type.caption.copyWith(color: colors.textMuted),
            ),
          ],
        ),
        const SizedBox(height: MechXSpacing.xs),
        Text(
          'Auto-sized to SNI velocity limits (per-branch flow). '
          'Default terminal demands — refine per fixture later.',
          style: type.caption.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}

class _ResultsSection extends ConsumerWidget {
  const _ResultsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final show = ref.watch(showHeatmapProvider);
    final solution = ref.watch(solveProvider);
    final pump = ref.watch(pumpDutyProvider);
    final zones = ref.watch(zonesProvider);
    final bom = ref.watch(bomProvider);
    final totalLength =
        bom.fold<double>(0, (sum, line) => sum + line.totalLength.meters);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionLabel('Network'),
        const SizedBox(height: MechXSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: MechXButton(
            label: show ? 'Hide heatmap' : 'Show heatmap',
            primary: show,
            onPressed: () => ref.read(showHeatmapProvider.notifier).toggle(),
          ),
        ),
        const SizedBox(height: MechXSpacing.sm),
        _kv(context, 'Pump head',
            solution == null ? '—' : '${solution.requiredPumpHead.meters.toStringAsFixed(1)} m'),
        _kv(context, 'Motor',
            pump == null ? '—' : '${pump.selectedMotor.inKiloWatts.toStringAsFixed(2)} kW'),
        _kv(context, 'Pressure zones', '${zones.length}'),
        _kv(context, 'BOM total', '${totalLength.toStringAsFixed(1)} m'),
      ],
    );
  }

  Widget _kv(BuildContext context, String key, String value) {
    final colors = context.colors;
    final type = context.type;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs),
      child: Row(
        children: [
          Expanded(
            child: Text(key, style: type.caption.copyWith(color: colors.textMuted)),
          ),
          Text(value, style: type.mono.copyWith(color: colors.textSecondary)),
        ],
      ),
    );
  }
}

class _FireSection extends ConsumerWidget {
  const _FireSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final sprinkler = ref.watch(sprinklerDesignProvider);
    final standpipe = ref.watch(standpipeDesignProvider);

    Widget kv(String key, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs),
          child: Row(
            children: [
              Expanded(
                child: Text(key,
                    style: type.caption.copyWith(color: colors.textMuted)),
              ),
              Text(value,
                  style: type.mono.copyWith(color: colors.textSecondary)),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionLabel('Fire'),
        const SizedBox(height: MechXSpacing.sm),
        kv('Sprinkler flow',
            '${sprinkler.requiredFlow.inLitersPerSecond.toStringAsFixed(1)} L/s'),
        kv('Sprinkler heads', '${sprinkler.sprinklerCount}'),
        kv('Standpipe flow',
            '${standpipe.requiredFlow.inLitersPerSecond.toStringAsFixed(1)} L/s'),
        kv('Fire pump',
            '${standpipe.pumpHead.meters.toStringAsFixed(0)} m · ${standpipe.pumpShaftPower.inKiloWatts.toStringAsFixed(1)} kW'),
        const SizedBox(height: MechXSpacing.xs),
        Row(
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
            Expanded(
              child: Text(
                'SNI 03-3989 / 1745 / 6570 · single-riser draft demand',
                style: type.caption.copyWith(color: colors.textMuted),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ServiceChip extends StatelessWidget {
  final ServiceType service;
  final bool selected;
  final VoidCallback onTap;

  const _ServiceChip({
    required this.service,
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
            horizontal: MechXSpacing.sm,
            vertical: MechXSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: selected ? colors.accentMuted : colors.background,
            borderRadius: MechXRadii.control,
            border: Border.all(color: selected ? colors.accent : colors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: serviceColor(service),
                  borderRadius: const BorderRadius.all(Radius.circular(2)),
                ),
              ),
              const SizedBox(width: MechXSpacing.xs),
              Text(
                serviceLabel(service),
                style: type.label.copyWith(
                  color: selected ? colors.textPrimary : colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
