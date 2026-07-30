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

import '../data/project_document.dart' show IssueAck;
import '../ui/strings/app_strings.dart';
import '../ui/strings/plural.dart';
import 'app_state.dart';
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
  // I4 — the AUDIT metadata for each acknowledged advisory (author, date,
  // justification), keyed by issue key. Only the live provider supplies this;
  // the pure tests / report path that omit it get NO acknowledgement-log rows,
  // so the compliance table stays byte-identical (the pass/fail logic uses
  // [acknowledged], not this).
  Map<String, IssueAck> acks = const {},
  // Wave 5a (H1): category + detail strings resolve through the active locale.
  // Defaults to English so the report-export path and pure tests that omit it
  // stay byte-identical.
  MechXStringsData strings = const MechXStringsData(AppLocale.en),
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

  // Velocity: any out-of-band air-velocity warning fails the check. Matched on
  // the stable [DesignIssue.kind] (`duct-velocity` / `terminal-velocity`), NOT
  // the now-localized title (which would fall out of the bucket in Bahasa).
  final velocityWarnings =
      claim((i) => i.kind.contains('velocity')).where(isFail).length;
  // Calibration: an EDGE-BEARING uncalibrated sheet is a critical (its runs
  // size to zero) and fails the check; a BLANK uncalibrated sheet is an
  // info-tier advisory ("calibrate before you draw") that does NOT fail — but
  // the PASS row must still COUNT it, or the all-clear caption would claim
  // 'all sheets calibrated' while blank sheets sit uncalibrated. Both tiers
  // carry the stable `sheet-uncalibrated:<sheetId>` kind.
  final uncalibratedIssues =
      claim((i) => i.kind.startsWith('sheet-uncalibrated'));
  final calibrationWarnings = uncalibratedIssues.where(isFail).length;
  final blankUncalibrated = uncalibratedIssues.length - calibrationWarnings;
  // Standards verification: unverified-standard info items. An ACKNOWLEDGED
  // value no longer counts as OPEN (H1) — the mechanism that makes a PASS
  // structurally reachable while the full tiered register still prints in the
  // report (guardrail 6 intact). The acknowledged count is surfaced honestly in
  // the row detail rather than silently dropped.
  // H7a — verify rows now NAME their specific value in the title, so the generic
  // 'Unverified standard' literal is gone; discriminate on the stable
  // [DesignIssue.isVerify] flag instead.
  final unverifiedItems = claim((i) => i.isVerify);
  final openUnverified = unverifiedItems.where((i) => !isAck(i)).length;
  final ackUnverified = unverifiedItems.length - openUnverified;
  // Electrical warnings are fanned into designIssuesProvider (Wave 3) with an
  // `electrical:<code>` kind — claim them here (on the stable kind, not the
  // localized 'Electrical: …' title) so the dedicated 'Electrical circuit
  // sizing' row below (counted from the solved system directly) stays the
  // single source and nothing double-counts.
  claim((i) => i.kind.startsWith('electrical:'));

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

  // I4 — the ACKNOWLEDGEMENT LOG: one PASS row per accepted advisory carrying
  // its audit trail (who, when, why) so the signed deliverable records the
  // basis on which a `secondarySource` value was accepted, not only a bare
  // count. Emitted ONLY when [acks] metadata is supplied (the live provider),
  // so the pure/report tests that pass just [acknowledged] stay byte-identical.
  final ackLog = <ComplianceItem>[];
  for (final i in issues) {
    if (!isAck(i)) continue;
    final a = acks[i.key];
    if (a == null) continue;
    final meta = <String>[
      if (a.author.isNotEmpty) a.author,
      if (a.date.isNotEmpty) a.date,
    ].join(', ');
    final detail = a.note.isEmpty
        ? meta
        : (meta.isEmpty ? a.note : '$meta: ${a.note}');
    ackLog.add(ComplianceItem(
      strings.format(StringKey.complianceAckEntry, {'label': i.title}),
      pass: true,
      detail: detail,
    ));
  }

  return ComplianceSummary(
    date: date,
    items: [
      ComplianceItem(strings(StringKey.complianceCategoryAirVelocity),
          pass: velocityWarnings == 0,
          detail: velocityWarnings == 0
              ? strings(StringKey.complianceDetailAllWithinBand)
              : strings.format(StringKey.complianceDetailOutOfBand,
                  {'n': '$velocityWarnings'})),
      ComplianceItem(strings(StringKey.complianceCategorySheetCalibration),
          pass: calibrationWarnings == 0,
          detail: calibrationWarnings != 0
              ? strings.format(StringKey.complianceDetailUncalibrated,
                  {'n': '$calibrationWarnings'})
              // A passing row still names any blank uncalibrated sheets — an
              // advisory doesn't block sign-off, but the sign-off must not
              // claim 'all sheets calibrated' when they exist.
              : blankUncalibrated != 0
                  ? strings.format(StringKey.complianceDetailBlankUncalibrated,
                      {'n': '$blankUncalibrated'})
                  : strings(StringKey.complianceDetailAllCalibrated)),
      ComplianceItem(strings(StringKey.complianceCategoryStandardsVerification),
          pass: openUnverified == 0,
          detail: openUnverified == 0
              ? (ackUnverified == 0
                  ? strings(StringKey.complianceDetailAllVerified)
                  : strings.format(StringKey.complianceDetailAckNoneOpen,
                      {'n': '$ackUnverified'}))
              : (ackUnverified == 0
                  ? strings.format(
                      StringKey.complianceDetailRequireVerification, {
                      'values': pluralCount(
                          openUnverified,
                          strings(StringKey.complianceNounValueOne),
                          strings(StringKey.complianceNounValueMany)),
                    })
                  : strings.format(StringKey.complianceDetailOpenAck,
                      {'open': '$openUnverified', 'ack': '$ackUnverified'}))),
      for (final e in remainder.entries)
        ComplianceItem(e.key,
            pass: !e.value.any(isFail),
            detail: e.value.any(isFail)
                ? pluralCount(
                    e.value.where(isFail).length,
                    strings(StringKey.complianceNounFindingOne),
                    strings(StringKey.complianceNounFindingMany))
                : pluralCount(
                    e.value.length,
                    strings(StringKey.complianceNounAdvisoryNoteOne),
                    strings(StringKey.complianceNounAdvisoryNoteMany))),
      ComplianceItem(strings(StringKey.complianceCategoryElectricalSizing),
          pass: eErrors == 0,
          detail: eErrors == 0
              ? (eWarns == 0
                  ? strings(StringKey.complianceDetailNoSizingErrors)
                  : strings.format(StringKey.complianceDetailWarningsNoErrors, {
                      'warnings': pluralCount(
                          eWarns,
                          strings(StringKey.complianceNounWarningOne),
                          strings(StringKey.complianceNounWarningMany)),
                    }))
              : strings.format(StringKey.complianceDetailErrorsWarnings, {
                  'errors': pluralCount(
                      eErrors,
                      strings(StringKey.complianceNounErrorOne),
                      strings(StringKey.complianceNounErrorMany)),
                  'warnings': pluralCount(
                      eWarns,
                      strings(StringKey.complianceNounWarningOne),
                      strings(StringKey.complianceNounWarningMany)),
                })),
      // I4 — the acknowledgement log rows (empty unless [acks] was supplied).
      ...ackLog,
    ],
  );
}

/// The live compliance roll-up — WATCHES its inputs so the Review hub's verdict,
/// category rows and the IssuesCard always move together (H2). The exports read
/// the same provider, so the screen and the issued report never disagree.
final complianceSummaryProvider = Provider<ComplianceSummary>((ref) {
  final acks = ref.watch(acknowledgedIssuesProvider);
  return buildComplianceSummaryFrom(
    issues: ref.watch(designIssuesProvider),
    electricalWarnings: ref.watch(electricalAllWarningsProvider),
    acknowledged: acks.keys.toSet(),
    acks: acks,
    strings: MechXStringsData(ref.watch(localeProvider)),
    // The verdict date is formatted app-side (the engine never reads the
    // clock); it only rolls at midnight, which no open session cares about.
    date: DateTime.now().toIso8601String().split('T').first,
  );
});

/// I4 — the on-screen compliance roll-up: the design CHECK rows only, WITHOUT
/// the per-advisory acknowledgement log. The audit log (who accepted what, when,
/// why) is surfaced by the IssuesCard's Acknowledged group on the same screen
/// and printed in the exported report ([complianceSummaryProvider]); omitting it
/// here keeps the sign-off CARD a clean checks list rather than duplicating the
/// acknowledged advisories. The overall verdict is IDENTICAL to
/// [complianceSummaryProvider] (ack-log rows are all PASS, so they never move
/// `allPass`), so the two never disagree. Default state (nothing acknowledged) ⇒
/// byte-identical to [complianceSummaryProvider].
final complianceCheckItemsProvider = Provider<ComplianceSummary>((ref) {
  return buildComplianceSummaryFrom(
    issues: ref.watch(designIssuesProvider),
    electricalWarnings: ref.watch(electricalAllWarningsProvider),
    acknowledged: ref.watch(acknowledgedIssuesProvider).keys.toSet(),
    // No `acks` ⇒ no acknowledgement-log rows.
    strings: MechXStringsData(ref.watch(localeProvider)),
    date: DateTime.now().toIso8601String().split('T').first,
  );
});
