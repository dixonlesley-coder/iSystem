/// Unified MEP (M + E + P) building-services report — composes the mechanical
/// calc report, the electrical calc report, and a compliance pass/fail summary
/// into ONE cohesive issuable document.
///
/// Pure: takes the already-built [CalcReportData] and [ElectricalCalcReportData]
/// structs (the same ones the standalone reports consume) plus a
/// [ComplianceSummary] the app derives from its live design issues, and returns
/// a Markdown string. Zero Flutter imports — the app gathers provider values and
/// handles file IO.
///
/// Design: rather than re-deriving anything, it renders a unified head (project
/// identity + a single Design Basis register fed by BOTH disciplines' basis
/// writers), then a Compliance Summary table, then the FULL mechanical and
/// electrical report bodies (demoted under one `#` title) so nothing is lost,
/// then the merged Revision history. The standalone builders stay the source of
/// truth for every section — this file only composes.
library;

import '../standards/sni.dart' show Revision;
import 'calc_report.dart';
import 'electrical_calc_report.dart';
import 'report_blocks.dart';
import 'report_strings.dart';

/// One verdict in the compliance summary. The app derives pass/fail from its
/// existing design-issues fan-in (air velocities, standards verification,
/// calibration, …) — the engine only renders; it invents no new checks.
class ComplianceItem {
  /// The check name, e.g. "Air velocities within band".
  final String category;

  /// `true` ⇒ PASS, `false` ⇒ FAIL/REVIEW.
  final bool pass;

  /// One-line detail (count of offending elements, or "all within band").
  final String detail;

  const ComplianceItem(this.category, {required this.pass, this.detail = ''});
}

/// A pass/fail compliance roll-up the app passes to the unified report. Pure
/// data — the app computes the verdicts from `designIssuesProvider`; the engine
/// renders the table and the overall verdict. [date] stamps when the review was
/// run (the engine never reads the clock).
class ComplianceSummary {
  final String date;
  final List<ComplianceItem> items;

  const ComplianceSummary({required this.date, this.items = const []});

  /// Overall verdict — PASS only when every item passes.
  bool get allPass => items.every((i) => i.pass);
}

/// The compliance pass/fail summary as blocks (reviewed line + table). Caller
/// adds the `##` heading.
List<RptBlock> complianceSummaryBlocks(ComplianceSummary compliance,
        [ReportStrings strings = const ReportStrings.en()]) =>
    [
      RptParagraph(strings.format(RptStringKey.complianceReviewed, {
        'date': compliance.date,
        'verdict': compliance.allPass
            ? strings(RptStringKey.compliancePass)
            : strings(RptStringKey.complianceReviewRequired),
      })),
      RptTable(
        [
          strings(RptStringKey.tblCheck),
          strings(RptStringKey.tblVerdict),
          strings(RptStringKey.tblDetail),
        ],
        [
          for (final i in compliance.items)
            [
              i.category,
              i.pass
                  ? strings(RptStringKey.compliancePass)
                  : strings(RptStringKey.complianceItemReview),
              i.detail.replaceAll('|', r'\|').replaceAll('\n', ' '),
            ],
        ],
        mdSeparator: '|---|---|---|',
      ),
    ];

/// Render [compliance] as a Markdown pass/fail table into [b]. Caller writes the
/// `##` heading. No-op for an empty item list (the heading-less call site guards
/// that).
void writeComplianceSummary(StringBuffer b, ComplianceSummary compliance,
    [ReportStrings strings = const ReportStrings.en()]) {
  b.write(renderRptMarkdown(complianceSummaryBlocks(compliance, strings)));
}

/// Drop a standalone report's leading level-1 heading block so its body can be
/// embedded under a unified title without a duplicate top-level heading (the
/// block analogue of stripping the `# …` line + its blank line). Everything
/// else is preserved verbatim, so each discipline's report stays the source of
/// truth.
List<RptBlock> _demoteBlocks(List<RptBlock> blocks) {
  if (blocks.isNotEmpty) {
    final first = blocks.first;
    if (first is RptHeading && first.level == 1) return blocks.sublist(1);
  }
  return blocks;
}

/// Build the unified MEP building-services report as the neutral block list —
/// the one content model behind both the Markdown render
/// ([buildMepUnifiedReport]) and the PDF typesetter.
List<RptBlock> buildMepUnifiedReportBlocks({
  required CalcReportData mechanical,
  required ElectricalCalcReportData electrical,
  required ComplianceSummary compliance,
  ReportStrings strings = const ReportStrings.en(),
}) {
  // ── Identity ────────────────────────────────────────────────────────────────
  final name = mechanical.projectName.isNotEmpty
      ? mechanical.projectName
      : electrical.projectName;
  final blocks = <RptBlock>[
    RptHeading(1, strings.format(RptStringKey.mepTitle, {'name': name})),
    RptParagraph(
        strings.format(RptStringKey.mepGenerated, {'date': mechanical.date})),
    RptParagraph(strings(RptStringKey.mepUnifiedIntro)),
    RptKeyValue([
      (
        strings(RptStringKey.mepMechStandard),
        '**${mechanical.standardsName} (${mechanical.standardsRevision})**'
      ),
      (
        strings(RptStringKey.mepElecStandard),
        '**${electrical.standardsName} ${electrical.standardsRevision}**'
      ),
    ]),

    // ── Unified Design Basis (both disciplines) ───────────────────────────────
    RptHeading(2, strings(RptStringKey.headingDesignBasis)),
    RptHeading(3, strings(RptStringKey.mepHeadingMechPlumb3)),
    mechanicalDesignBasisBlock(mechanical, strings),
    RptHeading(3, strings(RptStringKey.mepHeadingElectrical)),
    electricalDesignBasisBlock(electrical, strings),

    // ── Compliance summary ────────────────────────────────────────────────────
    RptHeading(2, strings(RptStringKey.headingComplianceSummary)),
    ...complianceSummaryBlocks(compliance, strings),

    // ── Mechanical section (full body, demoted) ───────────────────────────────
    RptHeading(1, strings(RptStringKey.mepHeadingMechPlumb1)),
    ..._demoteBlocks(buildCalcReportBlocks(mechanical, strings)),
    // The legacy composer wrote a blank line after each embedded body (the
    // mechanical body ends its closing note without one).
    const RptMarkdown('\n'),

    // ── Electrical section (full body, demoted) ───────────────────────────────
    RptHeading(1, strings(RptStringKey.mepHeadingElectrical)),
    ..._demoteBlocks(buildElectricalCalcReportBlocks(electrical, strings)),
    const RptMarkdown('\n'),
  ];

  // ── Merged revision history ─────────────────────────────────────────────────
  final mergedRevisions = <Revision>[
    ...mechanical.revisions,
    ...electrical.revisions,
  ];
  if (mergedRevisions.isNotEmpty) {
    blocks
      ..add(RptHeading(1, strings(RptStringKey.headingRevisionHistory)))
      ..addAll(revisionHistoryBlocks(mergedRevisions, strings));
  }

  return blocks;
}

/// Compose the unified MEP building-services report.
String buildMepUnifiedReport({
  required CalcReportData mechanical,
  required ElectricalCalcReportData electrical,
  required ComplianceSummary compliance,
  ReportStrings strings = const ReportStrings.en(),
}) =>
    renderRptMarkdown(buildMepUnifiedReportBlocks(
      mechanical: mechanical,
      electrical: electrical,
      compliance: compliance,
      strings: strings,
    ));
