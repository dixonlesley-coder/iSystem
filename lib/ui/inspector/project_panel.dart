import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

import '../../store/app_state.dart';
import '../../store/calibration_store.dart';
import '../../store/fire_store.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/selection_store.dart';
import '../../store/sheets_store.dart';
import '../../store/sizing_store.dart';
import '../../store/solve_store.dart';
import '../canvas/service_style.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_text_field.dart';

/// All services offered in the draw palette / edge editor, in a sensible order.
const List<ServiceType> kDrawServices = [
  ServiceType.coldWater,
  ServiceType.hotWater,
  ServiceType.drainage,
  ServiceType.vent,
  ServiceType.rainwater,
  ServiceType.duct,
  ServiceType.fireSprinkler,
  ServiceType.fireHydrant,
];

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

              // ── Selection (only shown when something is selected) ─────────
              const _SelectionSection(),

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
            for (final s in kDrawServices)
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
          'Auto-sized to SNI velocity limits. Water supply uses accumulated '
          'fixture units via the Hunter demand curve; assign fixture types per '
          'node.',
          style: type.caption.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: MechXSpacing.sm),
        Text('Occupancy',
            style: type.caption.copyWith(color: colors.textMuted)),
        const SizedBox(height: MechXSpacing.xs),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            for (final o in Occupancy.values)
              _Pill(
                label: _occupancyLabel(o),
                selected: ref.watch(occupancyProvider) == o,
                onTap: () => ref.read(occupancyProvider.notifier).set(o),
              ),
          ],
        ),
      ],
    );
  }
}

String _occupancyLabel(Occupancy o) => switch (o) {
      Occupancy.private => 'Residential',
      Occupancy.public => 'Office / public',
      Occupancy.assembly => 'Assembly / mall',
    };

class _ResultsSection extends ConsumerWidget {
  const _ResultsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final show = ref.watch(showHeatmapProvider);
    final strategy = ref.watch(feedStrategyProvider);
    final stratCtrl = ref.read(feedStrategyProvider.notifier);
    final solution = ref.watch(solveProvider);
    final downfeed = ref.watch(downfeedProvider);
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
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            _Pill(
              label: 'Upfeed pump',
              selected: strategy == FeedStrategy.upfeed,
              onTap: () => stratCtrl.set(FeedStrategy.upfeed),
            ),
            _Pill(
              label: 'Roof-tank downfeed',
              selected: strategy == FeedStrategy.downfeed,
              onTap: () => stratCtrl.set(FeedStrategy.downfeed),
            ),
          ],
        ),
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
        if (strategy == FeedStrategy.upfeed) ...[
          _kv(context, 'Pump head',
              solution == null ? '—' : '${solution.requiredPumpHead.meters.toStringAsFixed(1)} m'),
          _kv(context, 'Motor',
              pump == null ? '—' : '${pump.selectedMotor.inKiloWatts.toStringAsFixed(2)} kW'),
        ] else ...[
          _kv(context, 'Top residual',
              downfeed == null ? '—' : '${downfeed.minResidual.inKiloPascals.toStringAsFixed(0)} kPa'),
          _kv(
            context,
            'Booster',
            downfeed == null
                ? '—'
                : downfeed.gravitySufficient
                    ? 'gravity OK'
                    : '+${downfeed.boosterHeadRequired.meters.toStringAsFixed(1)} m',
          ),
        ],
        _kv(context, 'Pressure zones', '${zones.length}'),
        _kv(context, 'BOM total', '${totalLength.toStringAsFixed(1)} m'),
        if (bom.isNotEmpty) ...[
          const SizedBox(height: MechXSpacing.xs),
          for (final line in bom)
            _kv(
              context,
              '${line.diameterMm}${line.service.regime == FlowRegime.air ? ' Ø' : ' DN'}'
                  ' · ${serviceLabel(line.service)}'
                  ' ${line.kind == EdgeKind.riser ? 'riser' : 'run'}',
              '${line.totalLength.meters.toStringAsFixed(1)} m ×${line.segmentCount}',
            ),
          const SizedBox(height: MechXSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: MechXButton(
              label: 'Export BOM (CSV)',
              onPressed: () => _exportBom(bom),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _exportBom(List<BomLine> bom) async {
    final path = await FilePicker.saveFile(
      dialogTitle: 'Export bill of materials',
      fileName: 'mechx-bom.csv',
      type: FileType.custom,
      allowedExtensions: const ['csv'],
    );
    if (path == null) return;
    final full = path.endsWith('.csv') ? path : '$path.csv';
    await File(full).writeAsString(bomToCsv(bom));
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

String _roleLabel(NodeRole r) => switch (r) {
      NodeRole.main => 'Junction',
      NodeRole.fixture => 'Fixture',
      NodeRole.plant => 'Source / tank',
    };

String fixtureLabel(PlumbingFixture f) => switch (f) {
      PlumbingFixture.waterClosetFlushValve => 'WC · valve',
      PlumbingFixture.waterClosetFlushTank => 'WC · tank',
      PlumbingFixture.urinalFlushTank => 'Urinal',
      PlumbingFixture.lavatory => 'Lavatory',
      PlumbingFixture.shower => 'Shower',
      PlumbingFixture.bathtub => 'Bathtub',
      PlumbingFixture.kitchenSink => 'Kitchen sink',
      PlumbingFixture.hoseBibb => 'Hose bibb',
    };

/// Inspector editor for the current canvas selection (node or edge). Renders
/// nothing when nothing is selected.
class _SelectionSection extends ConsumerWidget {
  const _SelectionSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(selectionProvider);
    if (selection.isEmpty) return const SizedBox.shrink();

    final net = ref.watch(networkControllerProvider).network;
    final ctrl = ref.read(networkControllerProvider.notifier);
    final selCtrl = ref.read(selectionProvider.notifier);

    Widget? body;
    if (selection.isNode) {
      final node = net.nodeById(selection.nodeId!);
      if (node != null) {
        body = _nodeEditor(context, ref, node, ctrl, selCtrl);
      }
    } else if (selection.isEdge) {
      NetEdge? edge;
      for (final e in net.edges) {
        if (e.id == selection.edgeId) {
          edge = e;
          break;
        }
      }
      if (edge != null) {
        body = _edgeEditor(context, ref, edge, net, ctrl, selCtrl);
      }
    }
    if (body == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _SectionLabel('Selection')),
            _GlyphButton(glyph: '×', onTap: selCtrl.clear),
          ],
        ),
        const SizedBox(height: MechXSpacing.sm),
        body,
        const SizedBox(height: MechXSpacing.lg),
      ],
    );
  }

  Widget _nodeEditor(BuildContext context, WidgetRef ref, NetNode node,
      NetworkController ctrl, SelectionController selCtrl) {
    final project = ref.watch(projectControllerProvider);
    final elev = nodeElevation(node, project.building).meters;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Node · floor ${node.floorIndex + 1} · elev '
            '${elev.toStringAsFixed(1)} m',
            style: context.type.caption.copyWith(color: context.colors.textMuted)),
        const SizedBox(height: MechXSpacing.sm),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            for (final r in NodeRole.values)
              _Pill(
                label: _roleLabel(r),
                selected: node.role == r,
                onTap: () => ctrl.setNodeRole(node.id, r),
              ),
          ],
        ),
        if (node.role == NodeRole.fixture) ...[
          const SizedBox(height: MechXSpacing.sm),
          Text('Fixture type',
              style: context.type.caption
                  .copyWith(color: context.colors.textMuted)),
          const SizedBox(height: MechXSpacing.xs),
          Wrap(
            spacing: MechXSpacing.xs,
            runSpacing: MechXSpacing.xs,
            children: [
              for (final f in PlumbingFixture.values)
                _Pill(
                  label: fixtureLabel(f),
                  selected: node.fixture == f,
                  onTap: () => ctrl.setNodeFixture(node.id, f),
                ),
            ],
          ),
        ],
        const SizedBox(height: MechXSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: MechXButton(
            label: 'Delete node',
            onPressed: () {
              ctrl.deleteNode(node.id);
              selCtrl.clear();
            },
          ),
        ),
      ],
    );
  }

  Widget _edgeEditor(BuildContext context, WidgetRef ref, NetEdge edge,
      Network net, NetworkController ctrl, SelectionController selCtrl) {
    final project = ref.watch(projectControllerProvider);
    final sizing = ref.watch(sizingProvider)[edge.id];
    final len = edgeLength(
      edge,
      net,
      calibrationBySheet: project.calibrations,
      building: project.building,
    ).meters;
    final kind = edge.kind == EdgeKind.riser ? 'Riser / drop' : 'Run';
    final sizeStr = sizing == null
        ? '—'
        : '${edge.service.regime == FlowRegime.air ? 'Ø' : 'DN'}'
            '${sizing.diameter.inMillimeters.round()}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('$kind · ${len.toStringAsFixed(2)} m · $sizeStr',
            style: context.type.caption.copyWith(color: context.colors.textMuted)),
        const SizedBox(height: MechXSpacing.sm),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            for (final s in kDrawServices)
              _ServiceChip(
                service: s,
                selected: edge.service == s,
                onTap: () => ctrl.setEdgeService(edge.id, s),
              ),
          ],
        ),
        const SizedBox(height: MechXSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: MechXButton(
            label: 'Delete ${edge.kind == EdgeKind.riser ? 'riser' : 'run'}',
            onPressed: () {
              ctrl.deleteEdge(edge.id);
              selCtrl.clear();
            },
          ),
        ),
      ],
    );
  }
}

/// A compact selectable pill used by the selection editor (role / fixture).
class _Pill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _Pill({
    required this.label,
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
          child: Text(
            label,
            style: type.label.copyWith(
              color: selected ? colors.textPrimary : colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
