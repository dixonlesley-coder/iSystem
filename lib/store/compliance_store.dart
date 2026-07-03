/// H2 — the LIVE compliance verdict. The pass/fail roll-up used to be built by
/// a `ref.read` helper inside `project_panel.dart`, so the Review hub's cards
/// showed a STALE snapshot (fixing an issue updated the IssuesCard while the
/// PASS / REVIEW REQUIRED verdict above it kept the old answer). The fan-in now
/// lives here as a watched [Provider] — every consumer (`_ComplianceCard`,
/// `_ExportDeliverablesCard`, the report exports) re-verdicts the moment
/// `designIssuesProvider` or the electrical solve changes.
///
/// The fan-in itself stays a PURE function ([buildComplianceSummaryFrom]) so
/// the report-export path and tests can drive it without a container.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/panel_results.dart'
    show ElectricalWarning, WarningSeverity;
import 'package:mechx_engine/report/mep_report.dart';

import 'design_issues_store.dart';
import 'electrical_store.dart';

/// Build the compliance pass/fail roll-up from the aggregated design [issues]
/// and the solved electrical system's own [electricalWarnings]. Pure fan-in (no
/// new checks). COMPLETE by construction: the three named checks match their
/// categories, every REMAINING aggregated issue title gets its own row (so a
/// present — or future — issue kind can never be silently omitted and the
/// table can't say PASS beside an unlisted finding), and the electrical
/// system's own warnings feed a dedicated row (they are not part of
/// `designIssuesProvider`).
ComplianceSummary buildComplianceSummaryFrom({
  required List<DesignIssue> issues,
  required List<ElectricalWarning> electricalWarnings,
  required String date,
  Set<String> acknowledged = const {},
}) {
  bool isFail(DesignIssue i) =>
      i.severity == IssueSeverity.warning ||
      i.severity == IssueSeverity.critical;

  // H1 — an advisory the engineer has ACKNOWLEDGED no longer blocks the verdict.
  // Only [info]-severity issues are acknowledgeable ([DesignIssue.isAcknowledgeable]);
  // a warning/critical is never treated as acknowledged even if a stale key
  // lingers, so an acknowledgement can never hide a real error.
  bool isAck(DesignIssue i) =>
      i.isAcknowledgeable && acknowledged.contains(i.key);

  // The three named checks (kept as positive confirmations on a clean
  // project). Track which issues they account for; everything else rolls up
  // into per-title rows below.
  final accounted = <DesignIssue>{};
  List<DesignIssue> claim(bool Function(DesignIssue) test) {
    final matched = issues.where(test).toList();
    accounted.addAll(matched);
    return matched;
  }

  // Velocity: any out-of-band air-velocity warning fails the check.
  final velocityWarnings =
      claim((i) => i.title.contains('velocity')).where(isFail).length;
  // Calibration: any uncalibrated-sheet issue fails the check — a blank sheet
  // is a warning, an edge-bearing one is escalated to critical, and BOTH must
  // fail the 'Sheet calibration' compliance item.
  final calibrationWarnings =
      claim((i) => i.title.contains('calibrated')).where(isFail).length;
  // Standards verification: unverified-standard info items. An ACKNOWLEDGED
  // value no longer counts as OPEN (H1) — the mechanism that makes a PASS
  // structurally reachable while the full tiered register still prints in the
  // report (guardrail 6 intact). The acknowledged count is surfaced honestly in
  // the row detail rather than silently dropped.
  final unverifiedItems = claim((i) => i.title == 'Unverified standard');
  final openUnverified = unverifiedItems.where((i) => !isAck(i)).length;
  final ackUnverified = unverifiedItems.length - openUnverified;
  // Electrical warnings are fanned into designIssuesProvider (Wave 3) with an
  // 'Electrical: ' title prefix — claim them here so the dedicated
  // 'Electrical circuit sizing' row below (counted from the solved system
  // directly) stays the single source and nothing double-counts.
  claim((i) => i.title.startsWith('Electrical:'));

  // Every other aggregated issue, grouped by title — duct over-capacity,
  // network connectivity, unsized air elements, drainage/Legionella
  // advisories, and whatever lands in the aggregator next.
  final remainder = <String, List<DesignIssue>>{};
  for (final i in issues) {
    if (accounted.contains(i)) continue;
    remainder.putIfAbsent(i.title, () => []).add(i);
  }

  // Electrical sizing: the solved system's own warning list (error severity —
  // e.g. cable-ampacity-inadequate — must fail the sign-off).
  final eErrors = electricalWarnings
      .where((w) => w.severity == WarningSeverity.error)
      .length;
  final eWarns = electricalWarnings
      .where((w) => w.severity == WarningSeverity.warning)
      .length;

  return ComplianceSummary(
    date: date,
    items: [
      ComplianceItem('Air velocities within band',
          pass: velocityWarnings == 0,
          detail: velocityWarnings == 0
              ? 'all within band'
              : '$velocityWarnings out of band'),
      ComplianceItem('Sheet calibration',
          pass: calibrationWarnings == 0,
          detail: calibrationWarnings == 0
              ? 'all sheets calibrated'
              : '$calibrationWarnings uncalibrated'),
      ComplianceItem('Standards verification',
          pass: openUnverified == 0,
          detail: openUnverified == 0
              ? (ackUnverified == 0
                  ? 'all values verified'
                  : '$ackUnverified acknowledged, none open')
              : (ackUnverified == 0
                  ? '$openUnverified value(s) require verification or '
                      'acknowledgement before submission'
                  : '$openUnverified open, $ackUnverified acknowledged')),
      for (final e in remainder.entries)
        ComplianceItem(e.key,
            pass: !e.value.any(isFail),
            detail: e.value.any(isFail)
                ? '${e.value.where(isFail).length} finding(s)'
                : '${e.value.length} advisory note(s)'),
      ComplianceItem('Electrical circuit sizing',
          pass: eErrors == 0,
          detail: eErrors == 0
              ? (eWarns == 0
                  ? 'no sizing errors'
                  : '$eWarns warning(s), no errors')
              : '$eErrors error(s), $eWarns warning(s)'),
    ],
  );
}

/// The live compliance roll-up — WATCHES its inputs so the Review hub's verdict,
/// category rows and the IssuesCard always move together (H2). The exports read
/// the same provider, so the screen and the issued report never disagree.
final complianceSummaryProvider = Provider<ComplianceSummary>((ref) {
  return buildComplianceSummaryFrom(
    issues: ref.watch(designIssuesProvider),
    electricalWarnings: ref.watch(electricalResultProvider).warnings,
    acknowledged: ref.watch(acknowledgedIssuesProvider),
    // The verdict date is formatted app-side (the engine never reads the
    // clock); it only rolls at midnight, which no open session cares about.
    date: DateTime.now().toIso8601String().split('T').first,
  );
});
