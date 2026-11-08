/// The ONE Export sheet (Ctrl/Cmd+E) — every deliverable the app can write, in
/// one place: the document-control identity, the primary submittal-package
/// action, then collapsible Drawings / Reports / Data / Electrical / Commercial
/// groups, each header carrying a live count of its rows.
///
/// App-shell-local, exactly like the command palette: a non-layout [Stack]
/// layer in `app_shell.dart`, gated on [exportSheetProvider] — it renders
/// NOTHING when closed, so the goldens are unchanged at rest. Every opener
/// (the top bar's Export button, Ctrl/Cmd+E, the palette's 'Export...', the
/// Riser / Electrical toolbar Export buttons, the 'All exports...' links on
/// Review and Projects) calls `exportSheetProvider.notifier.open(group)`, and
/// the group passed is pre-expanded + focused.
///
/// Every row calls the EXISTING guarded export function (`runExportGuarded`
/// via `exportXxx(ref)`) — the sheet changes WHERE an export is reached, never
/// how a file is produced. Custom design system only (no Material): a tinted
/// scrim + an OPAQUE [MechXTheme] card (export rows are content, not chrome).
/// Esc closes; Up / Down move the highlight; Enter runs it (or toggles a group).
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart' show ServiceType;

import '../../store/app_state.dart' show AppLocale;
import '../../store/command_store.dart';
import '../../store/schematic_view_store.dart';
import '../canvas/text_entry_guard.dart';
import '../commercial/commercial_hub.dart'
    show exportMepBomCsv, exportMepProposalMarkdown;
import '../electrical/electrical_export.dart';
import '../inspector/project_panel.dart'
    show
        ExportIdentityBar,
        exportAnnotatedPlanPdf,
        exportBomCsv,
        exportCalcReport,
        exportCalcReportPdf,
        exportDrawingDxf,
        exportDrawingPdf,
        exportEquipmentSchedule,
        exportEquipmentSchedulePdf,
        exportMepUnifiedReport,
        exportMepUnifiedReportPdf,
        exportSubmittalPackage;
import '../schematic/schematic_export.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_scrollbar.dart';

/// One export row: a stable [id] (widget key + keyboard identity), a [label],
/// an optional muted [sub] line (format / clarifier) and the [run] action —
/// always an existing guarded export entry point.
@immutable
class _ExportRowSpec {
  final String id;
  final String label;
  final String sub;
  final Future<void> Function(WidgetRef ref) run;

  const _ExportRowSpec(this.id, this.label, this.run, {this.sub = ''});
}

/// The rows of each group, in display order. Built per build from the live
/// locale; the riser rows read the Riser view's current Auto focus at RUN time
/// (exactly what the old Riser toolbar menu exported).
Map<ExportGroup, List<_ExportRowSpec>> _buildGroups(MechXStringsData s) {
  // The riser rows export the Riser view's CURRENT Auto focus, read at run
  // time — exactly what the old Riser toolbar menu exported.
  ServiceType? focus(WidgetRef ref) => ref.read(schematicViewProvider).autoFocus;
  return {
    ExportGroup.drawings: [
      _ExportRowSpec('plan-dxf', s(StringKey.inspectorExportDrawingDxf),
          exportDrawingDxf),
      _ExportRowSpec(
          'plan-pdf', s(StringKey.inspectorExportDrawingPdf), exportDrawingPdf,
          sub: s(StringKey.projectsExportDrawingPdfHint)),
      _ExportRowSpec('plan-annotated-pdf',
          s(StringKey.inspectorExportAnnotatedPlanPdf), exportAnnotatedPlanPdf,
          sub: s(StringKey.projectsExportAnnotatedPlanPdfHint)),
      _ExportRowSpec('riser-pdf', s(StringKey.exportSheetRiserSld),
          (r) => exportMechanicalRiserPdf(r, focus(r)),
          sub: s(StringKey.electricalExportSldPdf)),
      _ExportRowSpec('riser-dxf', s(StringKey.exportSheetRiserSld),
          (r) => exportMechanicalRiserDxf(r, focus(r)),
          sub: s(StringKey.electricalExportSldDxf)),
      _ExportRowSpec('riser-set-pdf', s(StringKey.mechExportAllSystems),
          (r) => exportMechanicalRiserSetPdf(r, focus(r)),
          sub: s(StringKey.mechExportAllSystemsPdf)),
      _ExportRowSpec('riser-set-dxf', s(StringKey.mechExportAllSystems),
          (r) => exportMechanicalRiserSetDxf(r, focus(r)),
          sub: s(StringKey.mechExportAllSystemsDxf)),
    ],
    ExportGroup.reports: [
      _ExportRowSpec('calc-md', s(StringKey.inspectorExportCalcReportMd),
          exportCalcReport),
      _ExportRowSpec('calc-pdf', s(StringKey.inspectorExportCalcReportPdfBtn),
          exportCalcReportPdf),
      _ExportRowSpec('mep-md', s(StringKey.inspectorExportMepReportMd),
          exportMepUnifiedReport),
      _ExportRowSpec('mep-pdf', s(StringKey.inspectorExportMepReportPdfBtn),
          exportMepUnifiedReportPdf),
      _ExportRowSpec('equipment-md',
          s(StringKey.inspectorExportEquipmentScheduleMd),
          exportEquipmentSchedule),
      _ExportRowSpec('equipment-pdf',
          s(StringKey.inspectorExportEquipmentSchedulePdfBtn),
          exportEquipmentSchedulePdf),
    ],
    ExportGroup.data: [
      _ExportRowSpec(
          'bom-csv', s(StringKey.exportSheetBomFittings), exportBomCsv,
          sub: s(StringKey.exportSheetBomFittingsSub)),
      _ExportRowSpec('equipment-csv', s(StringKey.exportSheetEquipmentCsv),
          exportEquipmentSchedule,
          sub: s(StringKey.exportSheetEquipmentCsvSub)),
    ],
    ExportGroup.electrical: [
      _ExportRowSpec('el-plan-pdf', s(StringKey.electricalExportPlan),
          exportElectricalPlanPdf,
          sub: s(StringKey.electricalExportSldPdf)),
      _ExportRowSpec('el-plan-dxf', s(StringKey.electricalExportPlan),
          exportElectricalPlanDxf,
          sub: s(StringKey.electricalExportSldDxf)),
      _ExportRowSpec('el-sld-pdf', s(StringKey.electricalExportSld),
          exportElectricalSldPdf,
          sub: s(StringKey.electricalExportSldPdf)),
      _ExportRowSpec('el-sld-dxf', s(StringKey.electricalExportSld),
          exportElectricalSldDxf,
          sub: s(StringKey.electricalExportSldDxf)),
      _ExportRowSpec('el-schedules-pdf', s(StringKey.electricalExportSchedules),
          exportElectricalPanelSchedulesPdf,
          sub: s(StringKey.electricalExportSchedulesPdf)),
      _ExportRowSpec('el-overview-pdf', s(StringKey.electricalExportOverview),
          exportElectricalOverviewPdf,
          sub: s(StringKey.electricalExportOverviewPdf)),
      _ExportRowSpec('el-overview-dxf', s(StringKey.electricalExportOverview),
          exportElectricalOverviewDxf,
          sub: s(StringKey.electricalExportOverviewDxf)),
      _ExportRowSpec('el-riser-pdf', s(StringKey.electricalExportRiser),
          exportElectricalRiserPdf,
          sub: s(StringKey.electricalExportRiserPdf)),
      _ExportRowSpec('el-riser-dxf', s(StringKey.electricalExportRiser),
          exportElectricalRiserDxf,
          sub: s(StringKey.electricalExportRiserDxf)),
      _ExportRowSpec('el-report-md', s(StringKey.electricalExportReport),
          exportElectricalCalcReport,
          sub: s(StringKey.electricalExportReportSub)),
      _ExportRowSpec('el-power-dxf', s(StringKey.electricalExportPowerOneLine),
          exportPowerOneLineDxf,
          sub: s(StringKey.electricalExportPowerOneLineSub)),
      _ExportRowSpec('el-power-pdf', s(StringKey.electricalExportPowerOneLine),
          exportPowerOneLinePdf,
          sub: s(StringKey.electricalExportSldPdf)),
    ],
    ExportGroup.commercial: [
      _ExportRowSpec('mep-bom-csv', s(StringKey.commercialExportBomCsv),
          exportMepBomCsv),
      _ExportRowSpec('proposal-md', s(StringKey.commercialExportProposalMd),
          exportMepProposalMarkdown),
    ],
  };
}

String _groupTitle(MechXStringsData s, ExportGroup g) => switch (g) {
      ExportGroup.drawings => s(StringKey.projectsExportGroupDrawings),
      ExportGroup.reports => s(StringKey.projectsExportGroupReports),
      ExportGroup.data => s(StringKey.projectsExportGroupData),
      ExportGroup.electrical => s(StringKey.exportSheetGroupElectrical),
      ExportGroup.commercial => s(StringKey.exportSheetGroupCommercial),
      ExportGroup.submittal => s(StringKey.reviewExportSubmittalPackage),
    };

/// The number of rows each group lists — exposed so tests (and any caller)
/// read the same inventory the headers count.
@visibleForTesting
int exportSheetRowCount(ExportGroup group) =>
    _buildGroups(const MechXStringsData(AppLocale.en))[group]?.length ?? 0;

/// The non-layout overlay layer hosted at app-shell level. Renders nothing
/// when the sheet is closed. It owns the [WidgetRef] the exports run on: this
/// widget stays mounted for the app's lifetime, so an export that awaits a
/// file dialog after the sheet closes still holds a live ref.
class ExportSheetOverlay extends ConsumerWidget {
  const ExportSheetOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final group = ref.watch(exportSheetProvider);
    if (group == null) return const SizedBox.shrink();
    final colors = context.colors;
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => ref.read(exportSheetProvider.notifier).close(),
        child: ColoredBox(
          color: colors.scrim,
          child: Center(
            // Swallow taps on the card itself (don't dismiss). Keyed by the
            // opening group so re-opening on another group re-seeds the state.
            child: GestureDetector(
              onTap: () {},
              child: _ExportSheetCard(
                key: ValueKey('export-sheet-${group.name}'),
                initialGroup: group,
                hostRef: ref,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One keyboard-reachable entry: the primary action, a group header, or a row.
@immutable
class _Item {
  final String id;
  final ExportGroup? group; // header / row
  final _ExportRowSpec? row; // row only
  const _Item(this.id, {this.group, this.row});

  bool get isPrimary => group == null;
  bool get isHeader => group != null && row == null;
}

class _ExportSheetCard extends StatefulWidget {
  final ExportGroup initialGroup;
  final WidgetRef hostRef;

  const _ExportSheetCard({
    super.key,
    required this.initialGroup,
    required this.hostRef,
  });

  @override
  State<_ExportSheetCard> createState() => _ExportSheetCardState();
}

class _ExportSheetCardState extends State<_ExportSheetCard> {
  final _focus = FocusNode(debugLabel: 'export-sheet');
  final _scroll = ScrollController();
  final Map<String, GlobalKey> _itemKeys = {};
  late final Set<ExportGroup> _expanded;
  String _highlightId = 'primary';

  @override
  void initState() {
    super.initState();
    final g = widget.initialGroup;
    _expanded = {if (g != ExportGroup.submittal) g};
    if (g != ExportGroup.submittal) _highlightId = 'group:${g.name}';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      _revealHighlight();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  GlobalKey _keyFor(String id) => _itemKeys.putIfAbsent(id, GlobalKey.new);

  List<_Item> _items(Map<ExportGroup, List<_ExportRowSpec>> groups) => [
        const _Item('primary'),
        for (final e in groups.entries) ...[
          _Item('group:${e.key.name}', group: e.key),
          if (_expanded.contains(e.key))
            for (final r in e.value)
              _Item('row:${r.id}', group: e.key, row: r),
        ],
      ];

  void _close() => widget.hostRef.read(exportSheetProvider.notifier).close();

  /// Close the sheet, then run the export on the host's long-lived ref.
  void _run(Future<void> Function(WidgetRef) action) {
    final ref = widget.hostRef;
    _close();
    action(ref);
  }

  void _toggle(ExportGroup g) => setState(() {
        if (!_expanded.remove(g)) _expanded.add(g);
        _highlightId = 'group:${g.name}';
      });

  void _activate(_Item item) {
    if (item.isPrimary) {
      _run(exportSubmittalPackage);
    } else if (item.isHeader) {
      _toggle(item.group!);
    } else {
      _run(item.row!.run);
    }
  }

  void _revealHighlight() {
    final ctx = _itemKeys[_highlightId]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx,
        alignment: 0.1, duration: Duration.zero);
  }

  KeyEventResult _onKey(List<_Item> items, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    // The identity bar's text fields own their own keys (Enter commits the
    // field; arrows move the caret) — never run an export from a field.
    if (isTextEntryFocused()) return KeyEventResult.ignored;
    final i = items.indexWhere((e) => e.id == _highlightId);
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      final step = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      final next = ((i < 0 ? 0 : i) + step + items.length) % items.length;
      setState(() => _highlightId = items[next].id);
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealHighlight());
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter)) {
      if (i >= 0) _activate(items[i]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final s = context.strings;
    final groups = _buildGroups(s);
    final items = _items(groups);
    final maxH = (MediaQuery.maybeSizeOf(context)?.height ?? 800) - 96;

    return Focus(
      focusNode: _focus,
      onKeyEvent: (_, event) => _onKey(items, event),
      child: SizedBox(
        width: 600,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH.clamp(320.0, 720.0)),
          child: Container(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: MechXRadii.card,
              border: Border.all(color: colors.border),
              boxShadow: MechXShadow.popover,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(MechXSpacing.md,
                      MechXSpacing.md, MechXSpacing.md, MechXSpacing.sm),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(s(StringKey.exportSheetButton),
                            style: type.title
                                .copyWith(color: colors.textPrimary)),
                      ),
                      MechXButton(
                        label: s(StringKey.exportSheetClose),
                        onPressed: _close,
                      ),
                    ],
                  ),
                ),
                Container(height: 1, color: colors.border),
                Flexible(
                  child: MechXScrollbar(
                    controller: _scroll,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      padding: const EdgeInsets.all(MechXSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const ExportIdentityBar(),
                          const SizedBox(height: MechXSpacing.md),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              key: _keyFor('primary'),
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                borderRadius: MechXRadii.control,
                                border: Border.all(
                                  color: _highlightId == 'primary'
                                      ? colors.accent
                                      : const Color(0x00000000),
                                  width: 1.5,
                                ),
                              ),
                              child: MechXButton(
                                label:
                                    s(StringKey.reviewExportSubmittalPackage),
                                primary: true,
                                onPressed: () => _run(exportSubmittalPackage),
                              ),
                            ),
                          ),
                          const SizedBox(height: MechXSpacing.sm),
                          for (final e in groups.entries) ...[
                            const SizedBox(height: MechXSpacing.xs),
                            _GroupHeader(
                              key: _keyFor('group:${e.key.name}'),
                              title: _groupTitle(s, e.key),
                              count: e.value.length,
                              expanded: _expanded.contains(e.key),
                              highlighted:
                                  _highlightId == 'group:${e.key.name}',
                              onHover: () => setState(() =>
                                  _highlightId = 'group:${e.key.name}'),
                              onTap: () => _toggle(e.key),
                            ),
                            if (_expanded.contains(e.key))
                              for (final r in e.value)
                                _Row(
                                  key: _keyFor('row:${r.id}'),
                                  spec: r,
                                  highlighted: _highlightId == 'row:${r.id}',
                                  onHover: () => setState(
                                      () => _highlightId = 'row:${r.id}'),
                                  onTap: () => _run(r.run),
                                ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                Container(height: 1, color: colors.border),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: MechXSpacing.md, vertical: MechXSpacing.sm),
                  child: Text(s(StringKey.exportSheetHint),
                      style: type.caption.copyWith(color: colors.textMuted)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A collapsible group header: chevron + UPPERCASE title + `(N)` count.
class _GroupHeader extends StatelessWidget {
  final String title;
  final int count;
  final bool expanded;
  final bool highlighted;
  final VoidCallback onHover;
  final VoidCallback onTap;

  const _GroupHeader({
    super.key,
    required this.title,
    required this.count,
    required this.expanded,
    required this.highlighted,
    required this.onHover,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final fg = highlighted ? colors.accent : colors.textSecondary;
    return Semantics(
      button: true,
      expanded: expanded,
      label: '$title ($count)',
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onHover(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.xs, vertical: MechXSpacing.xs + 2),
            decoration: BoxDecoration(
              color: highlighted ? colors.accentMuted : const Color(0x00000000),
              borderRadius: MechXRadii.control,
            ),
            child: Row(
              children: [
                RotatedBox(
                  quarterTurns: expanded ? 1 : 0,
                  child: CustomPaint(
                    size: const Size(14, 14),
                    painter: _ChevronPainter(color: fg),
                  ),
                ),
                const SizedBox(width: MechXSpacing.xs),
                Text(
                  '${title.toUpperCase()} ($count)',
                  style: type.caption.copyWith(
                    color: fg,
                    letterSpacing: 0.8,
                    fontWeight: FontWeight.w600,
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

/// One export row: label + muted format/clarifier line.
class _Row extends StatelessWidget {
  final _ExportRowSpec spec;
  final bool highlighted;
  final VoidCallback onHover;
  final VoidCallback onTap;

  const _Row({
    super.key,
    required this.spec,
    required this.highlighted,
    required this.onHover,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Semantics(
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onHover(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            margin: const EdgeInsets.only(left: MechXSpacing.md, top: 1),
            padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.sm, vertical: MechXSpacing.xs + 1),
            decoration: BoxDecoration(
              color: highlighted ? colors.accentMuted : const Color(0x00000000),
              borderRadius: MechXRadii.control,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    spec.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.body.copyWith(
                        color:
                            highlighted ? colors.accent : colors.textPrimary),
                  ),
                ),
                if (spec.sub.isNotEmpty) ...[
                  const SizedBox(width: MechXSpacing.sm),
                  // The format / clarifier hugs the right edge; it may take up
                  // to ~60% of the row before ellipsizing.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: Text(
                      spec.sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: type.caption.copyWith(color: colors.textMuted),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A single right-pointing chevron drawn from primitives (never tofu); the
/// header rotates it down when the group is expanded.
class _ChevronPainter extends CustomPainter {
  final Color color;
  _ChevronPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final w = size.width, h = size.height;
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.40, h * 0.24)
        ..lineTo(w * 0.66, h * 0.50)
        ..lineTo(w * 0.40, h * 0.76),
      stroke,
    );
  }

  @override
  bool shouldRepaint(_ChevronPainter old) => old.color != color;
}

/// The quiet 'All exports...' text link — Review's deliverables card and the
/// Projects page each carry one, opening the Export sheet on its default group
/// (the submittal action focused, every group collapsed).
class AllExportsLink extends ConsumerWidget {
  const AllExportsLink({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Align(
        alignment: Alignment.centerLeft,
        child: MechXButton(
          label: context.strings(StringKey.exportSheetAllExports),
          tertiary: true,
          onPressed: () => ref.read(exportSheetProvider.notifier).open(),
        ),
      );
}
