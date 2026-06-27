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

/// Render [compliance] as a Markdown pass/fail table into [b]. Caller writes the
/// `##` heading. No-op for an empty item list (the heading-less call site guards
/// that).
void writeComplianceSummary(StringBuffer b, ComplianceSummary compliance) {
  b.writeln('_Reviewed ${compliance.date} — overall: '
      '**${compliance.allPass ? 'PASS' : 'REVIEW REQUIRED'}**_');
  b.writeln();
  b.writeln('| Check | Verdict | Detail |');
  b.writeln('|---|---|---|');
  for (final i in compliance.items) {
    final detail = i.detail.replaceAll('|', r'\|').replaceAll('\n', ' ');
    b.writeln('| ${i.category} | ${i.pass ? 'PASS' : 'REVIEW'} | $detail |');
  }
  b.writeln();
}

/// Strip the leading `# …` H1 line (and the blank line after it) from a
/// standalone report body so it can be embedded under a unified title without a
/// duplicate top-level heading. Everything else is preserved verbatim, so each
/// discipline's report stays the source of truth.
String _demoteBody(String report) {
  final lines = report.split('\n');
  var start = 0;
  if (start < lines.length && lines[start].startsWith('# ')) {
    start++;
    if (start < lines.length && lines[start].trim().isEmpty) start++;
  }
  return lines.sublist(start).join('\n');
}

/// Compose the unified MEP building-services report.
String buildMepUnifiedReport({
  required CalcReportData mechanical,
  required ElectricalCalcReportData electrical,
  required ComplianceSummary compliance,
}) {
  final b = StringBuffer();

  // ── Identity ────────────────────────────────────────────────────────────────
  final name = mechanical.projectName.isNotEmpty
      ? mechanical.projectName
      : electrical.projectName;
  b.writeln('# MEP Building-Services Report — $name');
  b.writeln();
  b.writeln('_Generated ${mechanical.date} · MechX (iSystem)_');
  b.writeln();
  b.writeln('Unified mechanical · electrical · plumbing report.');
  b.writeln();
  b.writeln('- Mechanical / plumbing standard: '
      '**${mechanical.standardsName} (${mechanical.standardsRevision})**');
  b.writeln('- Electrical standard: '
      '**${electrical.standardsName} ${electrical.standardsRevision}**'
      .trimRight());
  b.writeln();

  // ── Unified Design Basis (both disciplines) ─────────────────────────────────
  b.writeln('## Design basis');
  b.writeln();
  b.writeln('### Mechanical / plumbing');
  b.writeln();
  writeMechanicalDesignBasis(b, mechanical);
  b.writeln();
  b.writeln('### Electrical');
  b.writeln();
  writeElectricalDesignBasis(b, electrical);
  b.writeln();

  // ── Compliance summary ──────────────────────────────────────────────────────
  b.writeln('## Compliance summary');
  b.writeln();
  writeComplianceSummary(b, compliance);

  // ── Mechanical section (full body, demoted) ─────────────────────────────────
  b.writeln('# Mechanical & plumbing');
  b.writeln();
  b.write(_demoteBody(buildCalcReportMarkdown(mechanical)));
  b.writeln();

  // ── Electrical section (full body, demoted) ─────────────────────────────────
  b.writeln('# Electrical');
  b.writeln();
  b.write(_demoteBody(buildElectricalCalcReport(electrical)));
  b.writeln();

  // ── Merged revision history ─────────────────────────────────────────────────
  final mergedRevisions = <Revision>[
    ...mechanical.revisions,
    ...electrical.revisions,
  ];
  if (mergedRevisions.isNotEmpty) {
    b.writeln('# Revision history');
    b.writeln();
    writeRevisionHistory(b, mergedRevisions);
  }

  return b.toString();
}
