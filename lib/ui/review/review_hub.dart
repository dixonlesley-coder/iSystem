import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/mep_report.dart' show ComplianceItem;

import '../../store/compliance_store.dart';
import '../../store/design_issues_store.dart';
import '../../store/electrical_store.dart';
import '../../store/solve_store.dart';
import '../canvas/service_style.dart';
import '../inspector/project_panel.dart'
    show
        ExportIdentityBar,
        exportCalcReport,
        exportCalcReportPdf,
        exportEquipmentSchedule,
        exportEquipmentSchedulePdf,
        exportMepUnifiedReport,
        exportMepUnifiedReportPdf,
        exportSubmittalPackage;
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/hub_scaffold.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_focus_ring.dart';
import '../widgets/severity_glyph.dart';
import 'issues_card.dart';

/// The Review hub — a calm landing for checking the design before issue.
///
/// For this pass it surfaces what the engine already computes (electrical
/// warnings, the BOM line count) and points at the existing calc-report export.
/// The detailed Review tabs come together in a later wave; this is the durable
/// shell PanelMaker's "Review" group maps onto.
class ReviewHub extends ConsumerWidget {
  const ReviewHub({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final elec = ref.watch(electricalResultProvider);
    final bom = ref.watch(bomProvider);
    final cutPlan = ref.watch(pipeCutPlanProvider);

    final panels = elec.panels.length;

    // Overall pipe efficiency across all (service, diameter) groups.
    var totalBars = 0;
    var purchased = 0.0, required = 0.0;
    for (final g in cutPlan) {
      totalBars += g.plan.totalBars;
      purchased += g.plan.purchasedM;
      required += g.plan.requiredM;
    }
    final wastePct = purchased <= 0 ? 0.0 : 100 * (purchased - required) / purchased;

    final s = context.strings;
    return HubScaffold(
      title: s(StringKey.reviewHubTitle),
      lead: s(StringKey.reviewHubLead),
      children: [
        const _ComplianceCard(),
        const SizedBox(height: MechXSpacing.md),
        // The bare 'Electrical warnings' count is now redundant: every
        // ElectricalWarning fans into the unified IssuesCard below (grouped by
        // severity, locatable) and the compliance card's 'Electrical circuit
        // sizing' row. Panels-sized + BOM line items stay unique.
        //
        // ONE stat grid (V1): all five figures in a single _StatGrid call so
        // they render as one consistent, BALANCED tile system (the cut-plan
        // trio simply joins the grid when a plan exists) — equal-width tiles
        // filling the row rather than wrapping a lone trailing tile onto its
        // own line, degrading to a wrapped grid only when genuinely narrow.
        _StatGrid(
          stats: [
            (s(StringKey.reviewStatPanelsSized), '$panels'),
            (s(StringKey.reviewStatBomLineItems), '${bom.length}'),
            if (cutPlan.isNotEmpty) ...[
              (s(StringKey.reviewStatStockPipes), '$totalBars'),
              (s(StringKey.reviewStatPipeRequired),
                  '${required.toStringAsFixed(1)} m'),
              (s(StringKey.reviewStatOffcutWaste),
                  '${wastePct.toStringAsFixed(0)}%'),
            ],
          ],
        ),
        if (cutPlan.isNotEmpty) ...[
          const SizedBox(height: MechXSpacing.md),
          _CutPlanCard(),
        ],
        const SizedBox(height: MechXSpacing.md),
        const IssuesCard(),
        const SizedBox(height: MechXSpacing.md),
        _ConsumablesCard(),
        const SizedBox(height: MechXSpacing.lg),
        HubNote(s(StringKey.reviewStockNote)),
        const SizedBox(height: MechXSpacing.md),
        const _ExportDeliverablesCard(),
      ],
    );
  }
}

/// The Review hub's final stop: the same PASS / REVIEW REQUIRED verdict as
/// [_ComplianceCard] (both watch [complianceSummaryProvider] so the two never
/// disagree) leading straight into the deliverable exports — making the
/// "check, then issue" pairing explicit. Exports stay enabled on REVIEW
/// REQUIRED: the compliance summary is advisory, the engineer decides whether
/// to issue. The three buttons reuse the SAME export functions already wired
/// on the Projects screen (`project_panel.dart`'s `exportCalcReport` /
/// `exportMepUnifiedReport` / `exportEquipmentSchedule`) — no new export path.
/// Per-sheet drawing exports (DXF/PDF) need a current-sheet context that the
/// Review hub doesn't have, so they're represented by a hint pointing at
/// Layout rather than duplicated here.
class _ExportDeliverablesCard extends ConsumerWidget {
  const _ExportDeliverablesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final s = context.strings;
    // WATCHED (H2): the verdict re-computes live as issues are fixed, moving
    // together with the IssuesCard above.
    final summary = ref.watch(complianceSummaryProvider);
    final allPass = summary.allPass;
    final verdictColor = allPass ? colors.success : colors.warning;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.border),
      ),
      padding: const EdgeInsets.all(MechXSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s(StringKey.reviewExportDeliverables),
              style: type.subtitle.copyWith(color: colors.textPrimary)),
          const SizedBox(height: MechXSpacing.sm),
          Row(
            children: [
              CustomPaint(
                size: const Size(14, 14),
                painter: SeverityGlyph(
                  kind: allPass
                      ? SeverityGlyphKind.check
                      : SeverityGlyphKind.warn,
                  color: verdictColor,
                ),
              ),
              const SizedBox(width: MechXSpacing.sm),
              Text(
                allPass
                    ? s(StringKey.reviewIssueReady)
                    : s(StringKey.reviewIssueReviewRequired),
                style: type.caption.copyWith(color: verdictColor),
              ),
            ],
          ),
          const SizedBox(height: MechXSpacing.md),
          // H5: the document-control identity right at the export surface.
          const ExportIdentityBar(),
          const SizedBox(height: MechXSpacing.md),
          // H4: the one-folder submittal package — the whole deliverable set
          // (reports + BOM/quotation + plan/riser/electrical drawings) into one
          // chosen folder in one action.
          Align(
            alignment: Alignment.centerLeft,
            child: MechXButton(
              label: s(StringKey.reviewExportSubmittalPackage),
              primary: true,
              onPressed: () => exportSubmittalPackage(ref),
            ),
          ),
          const SizedBox(height: MechXSpacing.sm),
          Wrap(
            spacing: MechXSpacing.xs,
            runSpacing: MechXSpacing.xs,
            children: [
              MechXButton(
                label: s(StringKey.inspectorExportCalcReportMd),
                onPressed: () => exportCalcReport(ref),
              ),
              MechXButton(
                label: s(StringKey.inspectorExportCalcReportPdfBtn),
                onPressed: () => exportCalcReportPdf(ref),
              ),
              MechXButton(
                label: s(StringKey.inspectorExportMepReportMd),
                onPressed: () => exportMepUnifiedReport(ref),
              ),
              MechXButton(
                label: s(StringKey.inspectorExportMepReportPdfBtn),
                onPressed: () => exportMepUnifiedReportPdf(ref),
              ),
              MechXButton(
                // H8: the MD export writes a spreadsheet CSV sibling too —
                // the label says so.
                label: s(StringKey.inspectorExportEquipmentScheduleMd),
                onPressed: () => exportEquipmentSchedule(ref),
              ),
              MechXButton(
                label: s(StringKey.inspectorExportEquipmentSchedulePdfBtn),
                onPressed: () => exportEquipmentSchedulePdf(ref),
              ),
            ],
          ),
          const SizedBox(height: MechXSpacing.sm),
          Text(
            s(StringKey.reviewSubmittalHint),
            style: type.caption.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

/// The pre-issue compliance roll-up: an overall PASS / REVIEW REQUIRED verdict
/// plus the category rows (air velocities / sheet calibration / standards
/// verification …) the unified MEP report also prints. Read-only over
/// [complianceCheckItemsProvider] (the CHECK rows; the per-advisory
/// acknowledgement audit log the report also prints is surfaced by the
/// IssuesCard's Acknowledged group below, not duplicated here). Its verdict is
/// identical to the shared [complianceSummaryProvider], so the hub and the
/// exported report always agree.
class _ComplianceCard extends ConsumerWidget {
  const _ComplianceCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final s = context.strings;
    // WATCHED (H2): fixing an issue updates this verdict immediately, in step
    // with the live IssuesCard below.
    final summary = ref.watch(complianceCheckItemsProvider);
    // A5 — the same live issue list the IssuesCard renders, so a category row
    // can address the group that carries its actionable copy.
    final issues = ref.watch(designIssuesProvider);
    final allPass = summary.allPass;
    final headlineColor = allPass ? colors.success : colors.warning;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.border),
      ),
      padding: const EdgeInsets.all(MechXSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Overall verdict headline with a redundant glyph (check / "!") so it
          // reads without hue alone.
          Row(
            children: [
              CustomPaint(
                size: const Size(16, 16),
                painter: SeverityGlyph(
                  kind: allPass
                      ? SeverityGlyphKind.check
                      : SeverityGlyphKind.warn,
                  color: headlineColor,
                ),
              ),
              const SizedBox(width: MechXSpacing.sm),
              Text(
                allPass
                    ? s(StringKey.reviewVerdictPass)
                    : s(StringKey.reviewVerdictReviewRequired),
                style: type.subtitle.copyWith(color: headlineColor),
              ),
              const SizedBox(width: MechXSpacing.sm),
              Text(s(StringKey.reviewDesignSignoff),
                  style: type.caption.copyWith(color: colors.textMuted)),
            ],
          ),
          const SizedBox(height: MechXSpacing.sm),
          // A5 — a category row is the headline verdict, and the actionable copy
          // of the same finding sits in the IssuesCard below the fold. Each row
          // that resolves to a real issue group is now a LINK to it (scroll +
          // expand + highlight); a row with nothing to show stays inert text.
          for (final (item, groupKey) in [
            for (final item in summary.items)
              (item, complianceRowGroupKey(item, issues, s)),
          ])
            _ComplianceRow(
              item: item,
              linked: groupKey != null,
              onTap: () {
                if (groupKey == null) return;
                ref.read(issueFocusProvider.notifier).reveal(groupKey);
              },
            ),
        ],
      ),
    );
  }
}

/// A5 — the IssuesCard group a compliance category row points at, or null when
/// the row has nothing to reveal (a clean PASS row, or the acknowledgement-log
/// rows). The predicates MIRROR `buildComplianceSummaryFrom`'s own claim rules
/// (stable [DesignIssue.kind] / [DesignIssue.isVerify], remainder rows keyed by
/// title), so a row can never link to a group it didn't count. A category that
/// spans several groups points at the first FAILING one — the finding the row's
/// REVIEW verdict is actually about.
String? complianceRowGroupKey(
    ComplianceItem item, List<DesignIssue> issues, MechXStringsData s) {
  final category = item.category;
  bool Function(DesignIssue) test;
  if (category == s(StringKey.complianceCategoryAirVelocity)) {
    test = (i) => i.kind.contains('velocity');
  } else if (category == s(StringKey.complianceCategorySheetCalibration)) {
    test = (i) => i.kind.startsWith('sheet-uncalibrated');
  } else if (category == s(StringKey.complianceCategoryStandardsVerification)) {
    test = (i) => i.isVerify;
  } else if (category == s(StringKey.complianceCategoryElectricalSizing)) {
    test = (i) => i.kind.startsWith('electrical:');
  } else {
    // Every remaining aggregated issue gets its own row, keyed by title.
    test = (i) => i.title == category;
  }
  DesignIssue? match;
  for (final i in issues) {
    if (!test(i)) continue;
    match ??= i;
    if (i.severity != IssueSeverity.info) {
      match = i;
      break;
    }
  }
  return match == null ? null : issueGroupKey(match);
}

/// A5 — one compliance category row. A [linked] row is a keyboard-reachable,
/// hoverable link to its issue group; an unlinked row renders exactly as the
/// plain text row it has always been (same paddings + styles), so a clean
/// project's card is unchanged.
class _ComplianceRow extends StatefulWidget {
  final ComplianceItem item;
  final VoidCallback onTap;
  final bool linked;

  const _ComplianceRow({
    required this.item,
    required this.onTap,
    required this.linked,
  });

  @override
  State<_ComplianceRow> createState() => _ComplianceRowState();
}

class _ComplianceRowState extends State<_ComplianceRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final s = context.strings;
    final item = widget.item;
    final row = Padding(
      padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: MechXSpacing.sm),
            child: CustomPaint(
              size: const Size(11, 11),
              painter: SeverityGlyph(
                kind: item.pass
                    ? SeverityGlyphKind.check
                    : SeverityGlyphKind.warn,
                color: item.pass ? colors.success : colors.warning,
              ),
            ),
          ),
          Expanded(
            child: Text(item.category,
                style: type.caption.copyWith(color: colors.textPrimary)),
          ),
          Text(
            item.pass
                ? s(StringKey.reviewItemPass)
                : s(StringKey.reviewItemReview),
            style: type.caption.copyWith(
              color: item.pass ? colors.success : colors.warning,
            ),
          ),
          if (item.detail.isNotEmpty) ...[
            const SizedBox(width: MechXSpacing.sm),
            Flexible(
              child: Text(
                item.detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: type.caption.copyWith(color: colors.textMuted),
              ),
            ),
          ],
        ],
      ),
    );
    if (!widget.linked) return row;
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: MechXFocusRing(
          onActivated: widget.onTap,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  // Hover feedback only — at rest the row is byte-identical.
                  color: _hover ? colors.surfaceHover : null,
                  borderRadius: MechXRadii.control,
                ),
                child: row,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The pipe cut plan: per (service, diameter), how many stock bars are needed
/// (with offcut reuse) and the resulting waste — the efficiency engine's output.
class _CutPlanCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final plan = ref.watch(pipeCutPlanProvider);
    if (plan.isEmpty) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.border),
      ),
      padding: const EdgeInsets.all(MechXSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.strings(StringKey.reviewPipeCutPlan),
              style: type.subtitle.copyWith(color: colors.textPrimary)),
          const SizedBox(height: MechXSpacing.sm),
          for (final g in plan)
            Padding(
              padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      // Ducts size by Ø + the BJLS/PU section; pipes by DN.
                      g.service.isAir
                          ? '${serviceLabel(g.service)}  Ø${g.diameterMm}  '
                              '${g.stockLengthM == 4.0 ? 'PU' : 'BJLS'}'
                          : '${serviceLabel(g.service)}  DN${g.diameterMm}',
                      style:
                          type.caption.copyWith(color: colors.textSecondary),
                    ),
                  ),
                  Text(
                    '${g.plan.totalBars} x '
                    '${g.stockLengthM.toStringAsFixed(g.service.isAir ? 1 : 0)} m'
                    '  ·  ${g.plan.wastePercent.toStringAsFixed(0)}% waste',
                    style: type.mono.copyWith(color: colors.textPrimary),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A balanced grid of labelled figures (V1): unlike [HubStatRow] (which
/// floors to a fixed minimum tile width and can strand a lone trailing tile
/// on its own row — the 4+1 wrap this replaces), [_StatGrid] first tries to
/// fit every stat as an EQUAL-width tile filling one row, and only falls back
/// to a wrapped multi-row grid when the hub is genuinely too narrow for that.
/// Display-only; same tile visuals as [HubStatRow].
class _StatGrid extends StatelessWidget {
  final List<(String, String)> stats;
  const _StatGrid({required this.stats});

  /// A tile never narrows below this — below it we wrap instead of cramming
  /// every stat onto one row.
  static const double _minTileWidth = 110;

  @override
  Widget build(BuildContext context) {
    if (stats.isEmpty) return const SizedBox.shrink();
    final colors = context.colors;
    final type = context.type;

    Widget tile(String label, String value) => Container(
          padding: const EdgeInsets.all(MechXSpacing.md),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: MechXRadii.card,
            border: Border.all(color: colors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value,
                  style: MechXTypography.tabular(type.display)
                      .copyWith(color: colors.textPrimary)),
              const SizedBox(height: MechXSpacing.xxs),
              Text(label, style: type.caption.copyWith(color: colors.textMuted)),
            ],
          ),
        );

    return LayoutBuilder(builder: (context, constraints) {
      const gutter = MechXSpacing.md;
      final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 720.0;

      // Prefer one balanced row: every tile the same width, filling the row.
      final naturalWidth = (width - (stats.length - 1) * gutter) / stats.length;
      if (naturalWidth >= _minTileWidth) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < stats.length; i++) ...[
              if (i > 0) const SizedBox(width: gutter),
              Expanded(child: tile(stats[i].$1, stats[i].$2)),
            ],
          ],
        );
      }

      // Genuinely narrow: degrade to a wrapped grid at the fixed minimum.
      final fit = ((width + gutter) / (_minTileWidth + gutter)).floor();
      final columns = fit.clamp(1, stats.length);
      final tileWidth =
          ((width - (columns - 1) * gutter) / columns).floorToDouble();
      return Wrap(
        spacing: gutter,
        runSpacing: gutter,
        children: [
          for (final (label, value) in stats)
            SizedBox(width: tileWidth, child: tile(label, value)),
        ],
      );
    });
  }
}

/// Jointing-consumables estimate — cans of PVC cement, tubes of duct sealant,
/// rolls of thread tape — for the quotation. Hidden until something needs them.
class _ConsumablesCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final s = context.strings;
    final e = ref.watch(consumablesProvider);
    if (e.isEmpty) return const SizedBox.shrink();

    final rows = <(String, String)>[
      if (e.pvcCementCans > 0)
        (s(StringKey.reviewConsumablePvcCement), '${e.pvcCementCans} can'
            '${e.pvcCementCans == 1 ? '' : 's'}  (${e.solventJoints} joints)'),
      if (e.ductSealantCartridges > 0)
        (s(StringKey.reviewConsumableDuctSealant), '${e.ductSealantCartridges} cartridge'
            '${e.ductSealantCartridges == 1 ? '' : 's'}  '
            '(${e.ductSealMetres.toStringAsFixed(1)} m)'),
      if (e.threadTapeRolls > 0)
        (s(StringKey.reviewConsumableThreadTape), '${e.threadTapeRolls} roll'
            '${e.threadTapeRolls == 1 ? '' : 's'}  (${e.threadedJoints} joints)'),
    ];

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.border),
      ),
      padding: const EdgeInsets.all(MechXSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s(StringKey.reviewConsumablesTitle),
              style: type.subtitle.copyWith(color: colors.textPrimary)),
          const SizedBox(height: MechXSpacing.sm),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
              child: Row(
                children: [
                  Expanded(
                    child: Text(r.$1,
                        style: type.caption
                            .copyWith(color: colors.textSecondary)),
                  ),
                  Text(r.$2,
                      style: type.mono.copyWith(color: colors.textPrimary)),
                ],
              ),
            ),
          Text(
            s(StringKey.reviewConsumablesNote),
            style: type.caption.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

