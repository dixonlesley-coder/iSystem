import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/report/dxf_export.dart';
import 'package:mechx_engine/report/pdf_export.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/supply_design.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

import '../../store/annotation_store.dart';
import '../../store/app_state.dart';
import '../../store/calibration_store.dart';
import '../../store/electrical_store.dart';
import '../../store/fire_store.dart';
import '../../store/fixture_library_store.dart';
import '../../store/history_store.dart';
import '../../store/layer_store.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/selection_store.dart';
import '../../store/sheets_store.dart';
import '../../store/sizing_store.dart';
import '../../store/solve_store.dart';
import '../canvas/segment_palette.dart';
import '../canvas/segment_symbols.dart';
import '../canvas/service_style.dart';
import '../shell/nav_rail.dart';
import '../strings/app_strings.dart';
import 'fixture_library_editor.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_focus_ring.dart';
import '../widgets/section_label.dart';

/// Gather the live design results into a calc report and write it to a Markdown
/// file chosen by the user.
Future<void> exportCalcReport(WidgetRef ref) async {
  final project = ref.read(projectControllerProvider);
  final strategy = ref.read(feedStrategyProvider);
  final downfeed = ref.read(downfeedProvider);
  final balance = ref.read(airBalanceProvider);
  const profile = SniProfile();

  final data = CalcReportData(
    projectName: project.name,
    date: DateTime.now().toIso8601String().split('T').first,
    standardsName: profile.name,
    standardsRevision: profile.revision,
    verifyItems: profile.verifyChecklist,
    building: project.building,
    feedStrategy:
        strategy == FeedStrategy.upfeed ? 'Upfeed pump' : 'Roof-tank downfeed',
    targetResidual:
        SupplyDesignCriteria.recommended().targetFixtureResidualPressure,
    pump: ref.read(pumpDutyProvider),
    boosterHead: downfeed?.boosterHeadRequired,
    gravitySufficient: downfeed?.gravitySufficient ?? false,
    zones: ref.read(zoneStaticsProvider),
    hotWaterRecirc: ref.read(hotWaterRecircProvider),
    sprinkler: ref.read(sprinklerDesignProvider),
    standpipe: ref.read(standpipeDesignProvider),
    fan: ref.read(ductFanProvider),
    supplyAirflowLps: balance?.supplyLps ?? 0,
    returnAirflowLps: balance?.returnLps ?? 0,
    bom: ref.read(bomProvider),
    fittings: ref.read(fittingsProvider),
  );

  final path = await FilePicker.saveFile(
    dialogTitle: MechXStringsData(ref.read(localeProvider))(StringKey.exportTitleCalcReport),
    fileName: '${project.name}-report.md',
    type: FileType.custom,
    allowedExtensions: const ['md'],
  );
  if (path == null) return;
  final full = path.endsWith('.md') ? path : '$path.md';
  await File(full).writeAsString(buildCalcReportMarkdown(data));
}

/// Export the current sheet/floor's drawn network as a DXF drawing file.
Future<void> exportDrawingDxf(WidgetRef ref) async {
  final sheets = ref.read(sheetsControllerProvider);
  final sheet = sheets.current;
  if (sheet == null) return;
  final levelCount = ref.read(projectControllerProvider).building.levelCount;
  final floorIndex = sheets.floorFor(sheet.id, levelCount);
  final dxf = networkToDxf(
    net: ref.read(networkControllerProvider).network,
    sizing: ref.read(sizingProvider),
    sheetId: sheet.id,
    floorIndex: floorIndex,
  );
  final path = await FilePicker.saveFile(
    dialogTitle: MechXStringsData(ref.read(localeProvider))(StringKey.exportTitleDrawingDxf),
    fileName: '${sheet.name}.dxf',
    type: FileType.custom,
    allowedExtensions: const ['dxf'],
  );
  if (path == null) return;
  final full = path.endsWith('.dxf') ? path : '$path.dxf';
  await File(full).writeAsString(dxf);
}

/// Export the current sheet/floor's drawn network as a native (vector) PDF.
Future<void> exportDrawingPdf(WidgetRef ref) async {
  final sheets = ref.read(sheetsControllerProvider);
  final sheet = sheets.current;
  if (sheet == null) return;
  final levelCount = ref.read(projectControllerProvider).building.levelCount;
  final floorIndex = sheets.floorFor(sheet.id, levelCount);
  final bytes = networkToPdf(
    net: ref.read(networkControllerProvider).network,
    sizing: ref.read(sizingProvider),
    sheetId: sheet.id,
    floorIndex: floorIndex,
    title: sheet.name,
  );
  final path = await FilePicker.saveFile(
    dialogTitle: MechXStringsData(ref.read(localeProvider))(StringKey.exportTitleDrawingPdf),
    fileName: '${sheet.name}.pdf',
    type: FileType.custom,
    allowedExtensions: const ['pdf'],
  );
  if (path == null) return;
  final full = path.endsWith('.pdf') ? path : '$path.pdf';
  await File(full).writeAsBytes(bytes);
}

/// All services offered in the draw palette / edge editor, in a sensible order.
const List<ServiceType> kDrawServices = [
  ServiceType.coldWater,
  ServiceType.hotWater,
  ServiceType.drainage,
  ServiceType.vent,
  ServiceType.rainwater,
  ServiceType.duct,
  ServiceType.returnAir,
  ServiceType.exhaust,
  ServiceType.fireSprinkler,
  ServiceType.fireHydrant,
];

/// Right inspector: project details, per-floor heights (the vertical
/// length source of truth, §10), and the per-sheet scale-calibration status.
class ProjectPanel extends ConsumerWidget {
  const ProjectPanel({super.key});

  static const double width = 272;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final project = ref.watch(projectControllerProvider);
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
              // ── Building (summary → its own page) ─────────────────────────
              // The full floor/level editor (+ per-floor fixture heights) now
              // lives on the dedicated Building page so the inspector stays
              // canvas-focused; this is a read-only summary that opens it.
              MechXSectionLabel(context.strings(StringKey.inspectorBuilding)),
              const SizedBox(height: MechXSpacing.sm),
              _BuildingSummary(
                summary: '${building.totalHeight.meters.toStringAsFixed(1)} m · '
                    '${building.levelCount} levels',
                onOpen: () => ref
                    .read(shellSectionProvider.notifier)
                    .set(ShellSection.building),
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

              // ── HVAC / ducting ────────────────────────────────────────────
              const _HvacSection(),
              const SizedBox(height: MechXSpacing.lg),

              // ── Sheet → floor mapping ─────────────────────────────────────
              if (currentSheet != null) ...[
                MechXSectionLabel(context.strings(StringKey.inspectorSheet)),
                const SizedBox(height: MechXSpacing.sm),
                Builder(builder: (context) {
                  final sheetsState = ref.watch(sheetsControllerProvider);
                  final floor =
                      sheetsState.floorFor(currentSheet.id, building.levelCount);
                  final floorName = building.floors[floor].name;
                  return Row(
                    children: [
                      Expanded(
                        child: Text(
                            context.strings(StringKey.inspectorMapsToFloor),
                            style:
                                type.caption.copyWith(color: colors.textMuted)),
                      ),
                      _GlyphButton(
                        glyph: '−',
                        onTap: floor > 0
                            ? () => ref
                                .read(sheetsControllerProvider.notifier)
                                .setSheetFloor(currentSheet.id, floor - 1)
                            : null,
                      ),
                      const SizedBox(width: MechXSpacing.xs),
                      Text(floorName,
                          style:
                              type.mono.copyWith(color: colors.textSecondary)),
                      const SizedBox(width: MechXSpacing.xs),
                      _GlyphButton(
                        glyph: '+',
                        onTap: floor < building.levelCount - 1
                            ? () => ref
                                .read(sheetsControllerProvider.notifier)
                                .setSheetFloor(currentSheet.id, floor + 1)
                            : null,
                      ),
                    ],
                  );
                }),
                const SizedBox(height: MechXSpacing.lg),
              ],

              // ── Scale calibration ─────────────────────────────────────────
              MechXSectionLabel('Scale'),
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

/// The compact building summary shown in the inspector: a one-line "11.0 m · 3
/// levels" readout in a tappable card that opens the dedicated Building page
/// (where floors are edited). Keeps the inspector canvas-focused.
class _BuildingSummary extends StatefulWidget {
  final String summary;
  final VoidCallback onOpen;
  const _BuildingSummary({required this.summary, required this.onOpen});

  @override
  State<_BuildingSummary> createState() => _BuildingSummaryState();
}

class _BuildingSummaryState extends State<_BuildingSummary> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return MechXFocusRing(
      borderRadius: MechXRadii.control,
      onActivated: widget.onOpen,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onOpen,
          child: AnimatedContainer(
            duration: MechXMotion.hover,
            curve: MechXMotion.standard,
            padding: const EdgeInsets.all(MechXSpacing.sm),
            decoration: BoxDecoration(
              color: _hover ? colors.surfaceHover : colors.background,
              borderRadius: MechXRadii.control,
              border: Border.all(color: _hover ? colors.textMuted : colors.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(widget.summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          type.body.copyWith(color: colors.textSecondary)),
                ),
                const SizedBox(width: MechXSpacing.xs),
                Text('Edit',
                    style: type.caption.copyWith(color: colors.accent)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GlyphButton extends StatefulWidget {
  final String glyph;
  final VoidCallback? onTap;
  const _GlyphButton({required this.glyph, required this.onTap});

  @override
  State<_GlyphButton> createState() => _GlyphButtonState();
}

class _GlyphButtonState extends State<_GlyphButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabled = widget.onTap != null;
    final fg = !enabled
        ? colors.textMuted.withAlpha(90)
        : (_hover ? colors.textPrimary : colors.textSecondary);
    final glyph = AnimatedScale(
      scale: _down && enabled ? 0.9 : 1.0,
      duration: MechXMotion.press,
      curve: MechXMotion.standard,
      child: AnimatedContainer(
        duration: MechXMotion.hover,
        curve: MechXMotion.standard,
        width: 24,
        height: 24,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color:
              _hover && enabled ? colors.surfaceHover : const Color(0x00000000),
          borderRadius: MechXRadii.control,
        ),
        child: Text(
          widget.glyph,
          style:
              TextStyle(fontFamily: 'Roboto', fontSize: 16, height: 1.0, color: fg),
        ),
      ),
    );
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: MechXFocusRing(
        enabled: enabled,
        onActivated: widget.onTap,
        child: GestureDetector(
          onTap: widget.onTap,
          onTapDown: enabled ? (_) => setState(() => _down = true) : null,
          onTapUp: enabled ? (_) => setState(() => _down = false) : null,
          onTapCancel: enabled ? () => setState(() => _down = false) : null,
          child: glyph,
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
    final ortho = ref.watch(orthoProvider);
    final sheets = ref.watch(sheetsControllerProvider);
    final levelCount = ref.watch(projectControllerProvider).building.levelCount;

    // On the unified Layout canvas, scope the drawable services to the ACTIVE
    // discipline layer (plumbing services when Plumbing is active, air services
    // when HVAC). On the Schematic view there is no layer concept, so the full
    // list is offered (unchanged). Electrical isn't a `ServiceType`, so it too
    // falls back to the full list (the electrical palette is shown elsewhere).
    final onLayout = ref.watch(workspaceViewProvider) == WorkspaceView.plan;
    final active = ref.watch(activeDisciplineProvider);
    final scoped = (onLayout && active.isMechanical)
        ? servicesFor(active)
        : kDrawServices;
    // If the active service isn't in scope, switch to the first scoped one so a
    // hidden service is never silently the draw target.
    if (scoped.isNotEmpty && !scoped.contains(drawing.service)) {
      final next = scoped.first;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (ref.read(networkControllerProvider).service != next) {
          ctrl.setService(next);
        }
      });
    }

    final measureMode = ref.watch(measureModeProvider);
    Widget tool(String label, DrawTool t) => MechXButton(
          label: label,
          // While the measure tool is on, no draw tool reads as active.
          primary: drawing.tool == t && !measureMode,
          onPressed: () {
            ctrl.setTool(t);
            ref.read(measureModeProvider.notifier).set(false);
          },
        );

    // Duplicate the current floor's runs to the sheet ONE FLOOR UP. The
    // destination is resolved by the sheet→floor MAPPING, not by list position:
    // a sheet may carry an explicit floor override, so a sheet's list index need
    // not equal its floor index. Enabled only when such a destination sheet
    // exists for the next floor.
    final current = sheets.current;
    final fromFloor =
        current == null ? 0 : sheets.floorFor(current.id, levelCount);
    final toFloor = fromFloor + 1;
    String? toSheetId;
    if (current != null && toFloor < levelCount) {
      for (final s in sheets.sheets) {
        if (sheets.floorFor(s.id, levelCount) == toFloor) {
          toSheetId = s.id;
          break;
        }
      }
    }
    final canDuplicate = current != null && toSheetId != null;
    void duplicateFloor() {
      if (current == null || toSheetId == null) return;
      ctrl.duplicateFloor(
        fromSheetId: current.id,
        fromFloor: fromFloor,
        toSheetId: toSheetId,
        toFloor: toFloor,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MechXSectionLabel('Draw'),
        const SizedBox(height: MechXSpacing.sm),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            tool('Select', DrawTool.select),
            tool('Run', DrawTool.drawRun),
            tool('Riser', DrawTool.drawRiser),
            // Measure is a separate mode (annotation, not a network element);
            // turning it on collapses the draw tool to Select.
            MechXButton(
              label: 'Measure',
              primary: measureMode,
              onPressed: () {
                final on = !measureMode;
                ref.read(measureModeProvider.notifier).set(on);
                if (on) ctrl.setTool(DrawTool.select);
              },
            ),
          ],
        ),
        const SizedBox(height: MechXSpacing.sm),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            for (final s in scoped)
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
            MechXButton(
              label: 'Undo',
              onPressed: ref.read(historyProvider.notifier).undo,
            ),
            MechXButton(
              label: 'Redo',
              onPressed: ref.read(historyProvider.notifier).redo,
            ),
            MechXButton(label: 'Clear', onPressed: ctrl.clear),
            MechXButton(
              label: 'Ortho',
              primary: ortho,
              onPressed: () => ref.read(orthoProvider.notifier).toggle(),
            ),
            if (canDuplicate)
              MechXButton(
                label: 'Duplicate floor up',
                onPressed: duplicateFloor,
              ),
          ],
        ),
        const SizedBox(height: MechXSpacing.lg),
        const SegmentPalette(),
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
        const MechXSectionLabel('Sizing'),
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
        const SizedBox(height: MechXSpacing.sm),
        Row(
          children: [
            Expanded(
              child: Text('Rainfall (storm)',
                  style: type.caption.copyWith(color: colors.textMuted)),
            ),
            _GlyphButton(
              glyph: '−',
              onTap: () =>
                  ref.read(rainfallIntensityProvider.notifier).nudge(-25),
            ),
            const SizedBox(width: MechXSpacing.xs),
            Text('${ref.watch(rainfallIntensityProvider).round()} mm/hr',
                style: type.mono.copyWith(color: colors.textSecondary)),
            const SizedBox(width: MechXSpacing.xs),
            _GlyphButton(
              glyph: '+',
              onTap: () =>
                  ref.read(rainfallIntensityProvider.notifier).nudge(25),
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
    final zoneStatics = ref.watch(zoneStaticsProvider);
    final bom = ref.watch(bomProvider);
    final fittings = ref.watch(fittingsProvider);
    final hwr = ref.watch(hotWaterRecircProvider);
    final worstZone = zoneStatics.isEmpty
        ? 0.0
        : zoneStatics
            .map((z) => z.bottomStatic.inKiloPascals)
            .reduce((a, b) => a > b ? a : b);
    final zonesOk = zoneStatics.every((z) => z.withinLimit);
    final totalLength =
        bom.fold<double>(0, (sum, line) => sum + line.totalLength.meters);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MechXSectionLabel('Network'),
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
          _kv(
            context,
            'PRV zones',
            zoneStatics.isEmpty
                ? '${zones.length}'
                : '${zones.length} · worst ${worstZone.toStringAsFixed(0)} kPa'
                    ' ${zonesOk ? 'OK' : 'over'}',
          ),
        ],
        if (strategy == FeedStrategy.upfeed)
          _kv(context, 'Pressure zones', '${zones.length}'),
        if (hwr != null)
          _kv(context, 'HW recirc',
              '${hwr.recircFlow.inLitersPerSecond.toStringAsFixed(2)} L/s · ${hwr.pump.selectedMotor.inKiloWatts.toStringAsFixed(2)} kW'),
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
          if (fittings.isNotEmpty)
            _kv(context, 'Fittings (est.)',
                '${fittings.fold<int>(0, (s, f) => s + f.count)}'),
          const SizedBox(height: MechXSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: MechXButton(
              label: 'Export BOM (CSV)',
              onPressed: () => _exportBom(bom, fittings,
                  MechXStringsData(ref.read(localeProvider))(
                      StringKey.exportTitleBom)),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _exportBom(List<BomLine> bom, List<FittingLine> fittings,
      String dialogTitle) async {
    final path = await FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: 'mechx-bom.csv',
      type: FileType.custom,
      allowedExtensions: const ['csv'],
    );
    if (path == null) return;
    final full = path.endsWith('.csv') ? path : '$path.csv';
    final csv = StringBuffer()
      ..writeln('# Pipe / duct')
      ..write(bomToCsv(bom))
      ..writeln()
      ..writeln('# Fittings (estimated)')
      ..write(fittingsToCsv(fittings));
    await File(full).writeAsString(csv.toString());
  }

  Widget _kv(BuildContext context, String key, String value) {
    final colors = context.colors;
    final type = context.type;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs),
      child: Row(
        children: [
          Expanded(
            child: Text(key,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: type.caption.copyWith(color: colors.textMuted)),
          ),
          const SizedBox(width: MechXSpacing.xs),
          Flexible(
            child: Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: type.mono.copyWith(color: colors.textSecondary)),
          ),
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.caption.copyWith(color: colors.textMuted)),
              ),
              const SizedBox(width: MechXSpacing.xs),
              Flexible(
                child: Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: type.mono.copyWith(color: colors.textSecondary)),
              ),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MechXSectionLabel('Fire'),
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
      child: MechXFocusRing(
        onActivated: onTap,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: EdgeInsets.symmetric(
              // Compensate the heavier selected border so the chip never jumps.
              horizontal: MechXSpacing.sm - (selected ? 1 : 0),
              vertical: MechXSpacing.xs - (selected ? 1 : 0),
            ),
            decoration: BoxDecoration(
              color: selected ? colors.accentMuted : colors.background,
              borderRadius: MechXRadii.control,
              border: Border.all(
                color: selected ? colors.accent : colors.border,
                width: selected ? 2 : 1,
              ),
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
                    color:
                        selected ? colors.textPrimary : colors.textSecondary,
                    fontWeight: selected ? FontWeight.w600 : null,
                  ),
                ),
              ],
            ),
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

    // Multi-selection: a count header + Copy / Paste / Delete actions (the
    // single-element editor is shown only for a single selection).
    if (selection.isMulti) {
      return _multiSelectionSection(context, ref, selection, ctrl, selCtrl);
    }

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
            Expanded(child: MechXSectionLabel('Selection')),
            _GlyphButton(glyph: '×', onTap: selCtrl.clear),
          ],
        ),
        const SizedBox(height: MechXSpacing.sm),
        body,
        const SizedBox(height: MechXSpacing.lg),
      ],
    );
  }

  Widget _multiSelectionSection(BuildContext context, WidgetRef ref,
      Selection selection, NetworkController ctrl, SelectionController selCtrl) {
    final colors = context.colors;
    final type = context.type;
    final n = selection.nodeIds.length;
    final m = selection.edgeIds.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: MechXSectionLabel('Selection')),
            _GlyphButton(glyph: '×', onTap: selCtrl.clear),
          ],
        ),
        const SizedBox(height: MechXSpacing.sm),
        Text(
          '$n ${n == 1 ? 'node' : 'nodes'} / $m ${m == 1 ? 'edge' : 'edges'} '
          'selected',
          style: type.caption.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: MechXSpacing.sm),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            MechXButton(
              label: 'Copy',
              onPressed: () =>
                  ctrl.copySelection(selection.nodeIds, selection.edgeIds),
            ),
            MechXButton(
              label: 'Paste',
              onPressed: () {
                final sheet = ref.read(sheetsControllerProvider).current;
                if (sheet == null) return;
                final levelCount =
                    ref.read(projectControllerProvider).building.levelCount;
                final floorIndex = ref
                    .read(sheetsControllerProvider)
                    .floorFor(sheet.id, levelCount);
                ctrl.paste(sheetId: sheet.id, floorIndex: floorIndex);
              },
            ),
            MechXButton(
              label: 'Delete',
              onPressed: () {
                ctrl.deleteMany(selection.nodeIds, selection.edgeIds);
                selCtrl.clear();
              },
            ),
          ],
        ),
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
        if (node.component != null) ...[
          const SizedBox(height: MechXSpacing.xxs),
          Row(
            children: [
              ComponentSymbol(
                  component: node.component!,
                  color: context.colors.textSecondary,
                  size: 15),
              const SizedBox(width: MechXSpacing.xs),
              Expanded(
                child: Text(node.component!.label,
                    style: context.type.body
                        .copyWith(color: context.colors.textPrimary)),
              ),
              MechXButton(
                label: 'Clear',
                tertiary: true,
                onPressed: () => ctrl.setNodeComponent(node.id, null),
              ),
            ],
          ),
        ],
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
        // Per-node mounting height — "how high on the wall" this fixture/outlet
        // sits above its own floor. Drives the vertical pipe/cable run to it
        // (§10). Shown in cm; "default" = the role's standard height.
        const SizedBox(height: MechXSpacing.sm),
        Text('Mounting height (above floor)',
            style:
                context.type.caption.copyWith(color: context.colors.textMuted)),
        const SizedBox(height: MechXSpacing.xs),
        Row(
          children: [
            _GlyphButton(
              glyph: '−',
              onTap: () {
                final base = node.mountHeight?.meters ??
                    const MountingHeights().fixtureHeight.meters;
                final next = base - 0.05;
                // Stepping down through floor level reverts to the role default.
                ctrl.setNodeMountHeight(
                    node.id, next <= 0 ? null : Length(next));
              },
            ),
            const SizedBox(width: MechXSpacing.sm),
            Text(
              node.mountHeight == null
                  ? 'default'
                  : '${(node.mountHeight!.meters * 100).round()} cm',
              style: context.type.mono
                  .copyWith(color: context.colors.textSecondary),
            ),
            const SizedBox(width: MechXSpacing.sm),
            _GlyphButton(
              glyph: '+',
              onTap: () {
                final base = node.mountHeight?.meters ??
                    const MountingHeights().fixtureHeight.meters;
                ctrl.setNodeMountHeight(node.id, Length(base + 0.05));
              },
            ),
            if (node.mountHeight != null) ...[
              const SizedBox(width: MechXSpacing.sm),
              MechXButton(
                label: 'Reset',
                tertiary: true,
                onPressed: () => ctrl.setNodeMountHeight(node.id, null),
              ),
            ],
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
                  selected:
                      node.customFixtureId == null && node.fixture == f,
                  onTap: () => ctrl.setNodeFixture(node.id, f),
                ),
            ],
          ),
          // User-defined fixture library — shown only when non-empty so the
          // built-in-only goldens are unchanged. A selected custom pill clears
          // the built-in fixture (mutual exclusivity, handled in the store).
          if (ref.watch(fixtureLibraryProvider).isNotEmpty) ...[
            const SizedBox(height: MechXSpacing.xs),
            Wrap(
              spacing: MechXSpacing.xs,
              runSpacing: MechXSpacing.xs,
              children: [
                for (final cf in ref.watch(fixtureLibraryProvider))
                  _Pill(
                    label: cf.name,
                    selected: node.customFixtureId == cf.id,
                    onTap: () => ctrl.setNodeCustomFixture(node.id, cf.id),
                  ),
              ],
            ),
          ],
          const SizedBox(height: MechXSpacing.xs),
          Align(
            alignment: Alignment.centerLeft,
            child: MechXButton(
              label: 'Manage fixtures…',
              onPressed: () => showFixtureLibraryEditor(context, ref),
            ),
          ),
          const SizedBox(height: MechXSpacing.sm),
          Text('Air terminal (diffuser) airflow',
              style: context.type.caption
                  .copyWith(color: context.colors.textMuted)),
          const SizedBox(height: MechXSpacing.xs),
          Row(
            children: [
              _GlyphButton(
                glyph: '−',
                onTap: () {
                  final lps = (node.airflow?.inLitersPerSecond ?? 0) - 5;
                  ctrl.setNodeAirflow(
                      node.id, lps <= 0 ? null : FlowRate.litersPerSecond(lps));
                },
              ),
              const SizedBox(width: MechXSpacing.sm),
              Text(
                node.airflow == null
                    ? '—'
                    : '${node.airflow!.inLitersPerSecond.toStringAsFixed(0)} L/s',
                style: context.type.mono
                    .copyWith(color: context.colors.textSecondary),
              ),
              const SizedBox(width: MechXSpacing.sm),
              _GlyphButton(
                glyph: '+',
                onTap: () {
                  final lps = (node.airflow?.inLitersPerSecond ?? 0) + 5;
                  ctrl.setNodeAirflow(node.id, FlowRate.litersPerSecond(lps));
                },
              ),
            ],
          ),
          const SizedBox(height: MechXSpacing.sm),
          Text('Rainwater outlet roof area',
              style: context.type.caption
                  .copyWith(color: context.colors.textMuted)),
          const SizedBox(height: MechXSpacing.xs),
          Row(
            children: [
              _GlyphButton(
                glyph: '−',
                onTap: () {
                  final a = (node.roofAreaM2 ?? 0) - 50;
                  ctrl.setNodeRoofArea(node.id, a <= 0 ? null : a);
                },
              ),
              const SizedBox(width: MechXSpacing.sm),
              Text(
                node.roofAreaM2 == null
                    ? '—'
                    : '${node.roofAreaM2!.toStringAsFixed(0)} m2',
                style: context.type.mono
                    .copyWith(color: context.colors.textSecondary),
              ),
              const SizedBox(width: MechXSpacing.sm),
              _GlyphButton(
                glyph: '+',
                onTap: () => ctrl.setNodeRoofArea(
                    node.id, (node.roofAreaM2 ?? 0) + 50),
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
    final material = edgeMaterialLabel(edge);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('$kind · ${len.toStringAsFixed(2)} m · $sizeStr'
            '${edge.sizeOverride != null ? ' (set)' : ''}',
            style: context.type.caption.copyWith(color: context.colors.textMuted)),
        if (material != null) ...[
          const SizedBox(height: MechXSpacing.xxs),
          Text('Material: $material',
              style: context.type.caption
                  .copyWith(color: context.colors.textSecondary)),
        ],
        const SizedBox(height: MechXSpacing.xxs),
        Text('Right-click the segment to set its size and material.',
            style:
                context.type.caption.copyWith(color: context.colors.textMuted)),
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
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            if (edge.sizeOverride != null)
              MechXButton(
                label: 'Clear size override',
                onPressed: () => ctrl.setEdgeSizeOverride(edge.id, null),
              ),
            MechXButton(
              label: 'Delete ${edge.kind == EdgeKind.riser ? 'riser' : 'run'}',
              onPressed: () {
                ctrl.deleteEdge(edge.id);
                selCtrl.clear();
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// HVAC / duct sizing controls + fan duty readout (the air-path analogue of the
/// Network section).
class _HvacSection extends ConsumerWidget {
  const _HvacSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final settings = ref.watch(ductSettingsProvider);
    final ctrl = ref.read(ductSettingsProvider.notifier);
    final fan = ref.watch(ductFanProvider);
    final balance = ref.watch(airBalanceProvider);

    Widget kv(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs),
          child: Row(
            children: [
              Expanded(
                child: Text(k,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.caption.copyWith(color: colors.textMuted)),
              ),
              const SizedBox(width: MechXSpacing.xs),
              Flexible(
                child: Text(v,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: type.mono.copyWith(color: colors.textSecondary)),
              ),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MechXSectionLabel('HVAC · ducting'),
        const SizedBox(height: MechXSpacing.sm),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            _Pill(
              label: 'Round',
              selected: settings.shape == DuctShape.round,
              onTap: () => ctrl.setShape(DuctShape.round),
            ),
            _Pill(
              label: 'Rectangular',
              selected: settings.shape == DuctShape.rectangular,
              onTap: () => ctrl.setShape(DuctShape.rectangular),
            ),
          ],
        ),
        const SizedBox(height: MechXSpacing.xs),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            _Pill(
              label: 'Velocity',
              selected: settings.method == DuctSizingMethod.velocity,
              onTap: () => ctrl.setMethod(DuctSizingMethod.velocity),
            ),
            _Pill(
              label: 'Equal friction',
              selected: settings.method == DuctSizingMethod.equalFriction,
              onTap: () => ctrl.setMethod(DuctSizingMethod.equalFriction),
            ),
          ],
        ),
        const SizedBox(height: MechXSpacing.sm),
        if (fan == null)
          Text('Draw a duct network and assign diffuser airflows.',
              style: type.caption.copyWith(color: colors.textMuted))
        else ...[
          kv('Trunk airflow',
              '${fan.airflow.inLitersPerSecond.toStringAsFixed(0)} L/s'),
          kv('Fan static',
              '${fan.totalStaticPressure.pascals.toStringAsFixed(0)} Pa'),
          kv('Fan power',
              '${fan.shaftPower.inKiloWatts.toStringAsFixed(2)} kW'),
          kv('Fan motor',
              '${fan.selectedMotor.inKiloWatts.toStringAsFixed(2)} kW'),
        ],
        if (balance != null) ...[
          const SizedBox(height: MechXSpacing.xs),
          kv('Supply air', '${balance.supplyLps.toStringAsFixed(0)} L/s'),
          kv('Return air', '${balance.returnLps.toStringAsFixed(0)} L/s'),
          kv('Air balance', _balanceLabel(balance.supplyLps, balance.returnLps)),
        ],
      ],
    );
  }
}

String _balanceLabel(double supplyLps, double returnLps) {
  if (returnLps <= 0) return 'no return drawn';
  if (supplyLps <= 0) return 'exhaust only';
  final deltaPct = (supplyLps - returnLps) / supplyLps * 100;
  if (deltaPct.abs() < 1) return 'balanced';
  final sign = deltaPct > 0 ? '+' : '';
  return '$sign${deltaPct.toStringAsFixed(0)}% supply';
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
      child: MechXFocusRing(
        onActivated: onTap,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: EdgeInsets.symmetric(
              // Compensate the heavier selected border so the pill never jumps.
              horizontal: MechXSpacing.sm - (selected ? 1 : 0),
              vertical: MechXSpacing.xs - (selected ? 1 : 0),
            ),
            decoration: BoxDecoration(
              color: selected ? colors.accentMuted : colors.background,
              borderRadius: MechXRadii.control,
              border: Border.all(
                color: selected ? colors.accent : colors.border,
                width: selected ? 2 : 1,
              ),
            ),
            child: Text(
              label,
              style: type.label.copyWith(
                color: selected ? colors.textPrimary : colors.textSecondary,
                fontWeight: selected ? FontWeight.w600 : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
