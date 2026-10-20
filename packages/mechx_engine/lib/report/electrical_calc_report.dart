/// Electrical calculation-report generator — builds the sized electrical
/// system (panels, incomers, busbars, circuits, earthing, the optional hybrid
/// power one-line and warnings) as a neutral [RptBlock] list
/// ([buildElectricalCalcReportBlocks]) rendered to Markdown by
/// [buildElectricalCalcReport] or typeset to PDF by `report_pdf.dart`. The
/// electrical mirror of `calc_report.dart`.
///
/// Pure: takes already-computed result records in [ElectricalCalcReportData]
/// and returns blocks / a string. Zero Flutter imports — the app gathers
/// provider values into the data struct and handles file IO. Every unverified
/// value is surfaced in a dedicated "Unverified values" section so the report
/// never hides provenance gaps (§8 / golden rule 6).
library;

import '../electrical/compute.dart' show serviceEntranceCapacityVa;
import '../electrical/earthing.dart' show EarthingResult, EarthingSystem;
import '../electrical/fault.dart'
    show faultStudyU0VerifyItem, inverterFaultMultiple, kAlternatorXdPu;
import '../electrical/load_kind.dart' show LoadKind;
import '../electrical/model.dart';
import '../electrical/panel_results.dart';
import '../electrical/power_oneline.dart';
import '../electrical/results.dart' show BusbarSizingReason;
import '../standards/puil.dart' show BreakerClassCode;
import '../standards/sni.dart'
    show Revision, StandardValue, VerificationStatus;
import '../units.dart' show Length;
import 'electrical_sld_drawing.dart' show cableRunLabel;
import 'plan_symbols.dart' show planLengthLabel;
import 'report_blocks.dart';
import 'report_strings.dart';

/// All inputs the electrical calc report renders. The [project] supplies the
/// input model (panel tags / order) and [result] the sizing; [powerOneLine] and
/// [verifyItems] are optional (skipped / empty when absent).
class ElectricalCalcReportData {
  final String projectName;
  final String date;
  final String standardsName;
  final String standardsRevision;

  final ElectricalProject project;
  final ElectricalSystemResult result;

  /// The hybrid power one-line (utility / genset / PV / battery), when the
  /// project carries energy sources — else null and its section is skipped.
  final PowerOneLine? powerOneLine;

  /// Aggregated provenance honesty surface (e.g. `AdvancedStudy.verifyItems`).
  final List<String> verifyItems;

  /// Round 30 (report-parity-2-3) — the standards profile's checklist
  /// (`PuilProfile.verifyChecklist`), printed WITH each value's verification
  /// tier (the mechanical report's convention). The flattened
  /// '<citation> — <note>' strings in [verifyItems] dropped the tier.
  final List<StandardValue<Object?>> verifyChecklist;

  /// Prospective short-circuit current at the supply origin (A) — the Fold-1
  /// busbar-withstand fault target. Null ⇒ omitted from the Design Basis.
  final double? originFaultLevelA;

  /// Protective-device clearing time (s) for the busbar withstand check. Null ⇒
  /// omitted from the Design Basis. Round 12 — printed on its own row when
  /// [originFaultLevelA] is null (it used to hide behind the fault gate).
  final double? busbarClearingTimeS;

  /// Round 12 (report-recompute-fault-basis-omitted) — WHERE
  /// [originFaultLevelA] came from (the app passes the EFFECTIVE value the
  /// busbars were sized on: explicit → service estimate → 16 kA default).
  /// Null ⇒ no provenance tail (byte-identical).
  final FaultLevelBasis? faultLevelBasis;

  /// Revision history (caller-supplied). Empty ⇒ no Revision-history table, so a
  /// caller that does not populate it gets byte-identical legacy output.
  final List<Revision> revisions;

  /// R1 — the COMBINED electrical warning surface the app already shows in
  /// Review / compliance (`electricalAllWarningsProvider`): the core
  /// [ElectricalSystemResult.warnings] PLUS the ADVANCED fault study's findings
  /// (`non-selective`, `selectivity-partial`, `breaking-capacity-inadequate`,
  /// `busbar-withstand-inadequate`, `tt-no-earth-fault-protection`), deduped on
  /// (code, panelId, circuitId).
  ///
  /// The issued report used to print [result].warnings ONLY, so an
  /// error-severity breaking-capacity finding the app flagged on screen was
  /// missing from the deliverable a panel builder receives. When this is
  /// supplied the "System warnings" section prints THIS list, and each panel
  /// section gains the findings carrying its own `panelId` that its own
  /// `warnings` list doesn't already hold.
  ///
  /// Null ⇒ the legacy behaviour (core warnings only) ⇒ byte-identical.
  final List<ElectricalWarning>? allWarnings;

  /// Round 9 (report-parity-engine-messages-english) — the standards
  /// PROVENANCE note (e.g. `PuilProfile.provenanceNote`: how the values were
  /// sourced and what remains unconfirmed). It belongs with the honesty
  /// surface, so it prints as the first row of the 'Unverified values'
  /// section — never as the report head's / PDF cover's 'Standard:' line,
  /// which carries only the short [standardsRevision] edition label. Null ⇒
  /// omitted.
  final String? standardsProvenance;

  /// Round 39 (elec-reports-parity-5) — the per-board INCOMER breaking
  /// capacity (kA) the fault study specifies (`faultSpecifiedKa(...).incomers`,
  /// the same map the board schedule and BOM receive). Null ⇒ no kA printed
  /// (byte-identical).
  final Map<String, double>? incomerKaByPanelId;

  /// Round 39 — the per-way device breaking capacity (kA) the fault study
  /// specifies (`faultSpecifiedKa(...).breakers`). Null ⇒ no kA printed.
  final Map<String, double>? breakerKaByCircuitId;

  const ElectricalCalcReportData({
    required this.projectName,
    required this.date,
    required this.standardsName,
    required this.standardsRevision,
    required this.project,
    required this.result,
    this.powerOneLine,
    this.verifyItems = const [],
    this.verifyChecklist = const [],
    this.originFaultLevelA,
    this.busbarClearingTimeS,
    this.faultLevelBasis,
    this.revisions = const [],
    this.allWarnings,
    this.standardsProvenance,
    this.incomerKaByPanelId,
    this.breakerKaByCircuitId,
  });
}

String _n(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// Round 30 (report-parity-2-4) — a current at the ONE fixed 0.1 A precision
/// the board schedule / SLD print (never '59 A' beside '59.1 A').
String _a(double amperes) => '${amperes.toStringAsFixed(1)} A';

/// A device / bar RATING (a nominal rung, not a computed current) keeps its
/// whole-number notation (`125 A MCCB`).
String _rating(double amperes) => '${_n(amperes)} A';

/// Round 30 — a percentage at a fixed 0.1 (the warnings' own format).
String _pct(double v) => v.toStringAsFixed(1);

/// Round 39 (elec-reports-parity-6) — a voltage-drop percentage printed in
/// the direction of its verdict: when the drop is OVER [limit] it is rounded
/// UP to 0.1 (and to 0.01 when that would still print at the limit), so the
/// printed figure always exceeds the printed limit next to 'OVER'. Pure.
String vdropPctForVerdict(double v, {required double limit, required bool over}) {
  if (!over) return _pct(v);
  final up1 = (v * 10 - 1e-9).ceil() / 10;
  if (up1 > limit + 1e-9) return up1.toStringAsFixed(1);
  final up2 = (v * 100 - 1e-9).ceil() / 100;
  return up2.toStringAsFixed(2);
}

/// Round 39 (elec-reports-parity-5) — the ' <n> kA' breaking-capacity token
/// (and ' (< <Ik> kA)' when the specified rating is short of the bus's
/// prospective fault), or '' when no rating is known.
String _kaToken(double? ka, double? busFaultKa) {
  if (ka == null || !ka.isFinite || ka <= 0) return '';
  final short = busFaultKa != null && ka + 1e-9 < busFaultKa;
  return ' ${_n(ka)} kA${short ? ' (< ${_n(busFaultKa)} kA)' : ''}';
}

/// Round 30 (report-parity-2-5) — the localized phase cell.
String _phaseCell(PhaseAssignment p, ReportStrings strings) =>
    p == PhaseAssignment.threePhase
        ? strings(RptStringKey.phaseCell3ph)
        : p.label;

/// Round 30 (report-parity-2-3) — the verification tier tag the mechanical
/// report prints beside each unverified value.
String _statusTag(VerificationStatus st, ReportStrings s) => switch (st) {
      VerificationStatus.sniVerbatim => '',
      VerificationStatus.secondarySource => s(RptStringKey.statusSecondary),
      VerificationStatus.notAnSniClause => s(RptStringKey.statusNotSni),
    };

/// Round 30 (report-parity-2-2) — the UNDIVERSIFIED connected load of [panelId]
/// and every board below it: each final way at its undiversified connected W,
/// each feeder replaced by its fed board's own sub-tree. The engine's panel
/// `connectedW` counts a feeder at the fed board's DIVERSIFIED demand, so with
/// any sub-board diversity the root bullet disagreed with the supply's
/// 'connected' figure (Σ undiversified leaves). Equal to `connectedW` when no
/// feeder hangs below (byte-identical).
double _subtreeConnectedW(ElectricalProject project, ElectricalSystemResult r,
    String panelId, [Set<String>? seen]) {
  final visited = seen ?? <String>{};
  if (!visited.add(panelId)) return 0;
  final p = r.panels[panelId];
  if (p == null) return 0;
  final feeds = <String, String>{
    for (final m in project.panels)
      if (m.id == panelId)
        for (final c in m.circuits)
          if (c.feedsPanelId != null) c.id: c.feedsPanelId!,
  };
  var w = 0.0;
  for (final c in p.circuits) {
    final fed = feeds[c.circuitId];
    w += fed != null && r.panels.containsKey(fed)
        ? _subtreeConnectedW(project, r, fed, visited)
        : c.connectedWOrLoad;
  }
  return w;
}

/// The localized system label (`3-phase` / `3 fasa`).
String _systemLabel(ElectricalSystem s, ReportStrings strings) =>
    s == ElectricalSystem.threePhase
        ? strings(RptStringKey.sysThreePhase)
        : strings(RptStringKey.sysSinglePhase);

/// The earthing note in the report's language. EN prints the engine's own
/// note verbatim (byte-identical); other locales compose the same two parts
/// (`EarthingSystem.note` + the RCD/overcurrent tail of `computeEarthing`)
/// from report keys.
String _earthingNote(EarthingResult e, ReportStrings strings) {
  if (strings.locale == ReportLocale.en) return e.note;
  final head = switch (e.system) {
    EarthingSystem.tnCs => strings(RptStringKey.earthNoteTnCs),
    EarthingSystem.tnS => strings(RptStringKey.earthNoteTnS),
    EarthingSystem.tt => strings(RptStringKey.earthNoteTt),
  };
  final tail = e.requiresRcd
      ? strings(RptStringKey.earthTailRcd)
      : strings(RptStringKey.earthTailOcpd);
  return head + tail;
}

/// Escape a value for a Markdown table cell: a literal `|` would split the row
/// into extra columns; a newline would break it.
String _md(String v) => v.replaceAll('|', r'\|').replaceAll('\n', ' ');

String _severityTag(WarningSeverity s, ReportStrings strings) =>
    strings(switch (s) {
      WarningSeverity.error => RptStringKey.sevError,
      WarningSeverity.warning => RptStringKey.sevWarn,
      WarningSeverity.info => RptStringKey.sevInfo,
    });

/// Provenance of the origin fault level printed in the Design Basis.
enum FaultLevelBasis {
  /// The engineer's explicit project setting.
  explicit,

  /// `estimatedServiceFaultLevelA` from the declared transformer / daya.
  serviceEstimate,

  /// The flat 16 kA fallback (nothing declared).
  defaultValue,

  /// Round 16 — nothing declared, but the demand needs an MV service: the
  /// fault of the transformer the supply study selects for it.
  supplyStudyEstimate,

  /// Round 39 r2 — a GENERATOR primary supply: the alternator's own
  /// S/(√3·400·Xd'') on its declared capacity (else the demand).
  generatorEstimate,

  /// Round 39 r2 — a SOLAR (inverter) primary supply: the inverter's
  /// current-limited fault (a multiple of its rated current).
  inverterEstimate,
}

/// Round 39 r2 — the provenance of a NON-explicit origin-fault estimate
/// (`estimatedServiceFaultLevelA` returned a figure): a declared customer
/// transformer is the service estimate; otherwise a generator / solar
/// primary supply names its alternator / inverter basis; otherwise a
/// declared capacity is the service estimate and nothing declared is the
/// supply-study transformer. Mirrors the branch order of
/// `estimatedServiceFaultLevelA`, so the printed basis is the one used.
FaultLevelBasis serviceFaultEstimateBasis(ElectricalProject project) {
  if ((project.transformerKva?.voltAmperes ?? 0) > 0) {
    return FaultLevelBasis.serviceEstimate;
  }
  switch (project.supplyKind) {
    case SupplyKind.generator:
      return FaultLevelBasis.generatorEstimate;
    case SupplyKind.solar:
      return FaultLevelBasis.inverterEstimate;
    case SupplyKind.pln:
      return (project.supplyCapacityVa?.voltAmperes ?? 0) > 0
          ? FaultLevelBasis.serviceEstimate
          : FaultLevelBasis.supplyStudyEstimate;
  }
}

/// The electrical **Design Basis / Inputs & Assumptions** register as a
/// key-value block — supply system/voltage, connected/diversified load,
/// earthing system, and (when set) the Fold-1 fault target + clearing time.
/// Shared with the unified MEP report. Caller adds the `##` heading.
RptKeyValue electricalDesignBasisBlock(ElectricalCalcReportData data,
    [ReportStrings strings = const ReportStrings.en()]) {
  final s = data.result.supply;
  return RptKeyValue([
    (
      strings(RptStringKey.edbSupply),
      '**${_systemLabel(s.system, strings)}, ${_n(s.voltage.volts)} V**'
    ),
    (
      strings(RptStringKey.edbConnectedLoad),
      strings.format(RptStringKey.edbConnectedLoadValue, {
        'w': _n(s.connectedW),
        'dw': _n(s.demandW),
        'kva': _n(s.demandVa.inKilovoltAmperes),
      })
    ),
    (
      strings(RptStringKey.edbEarthingSystem),
      '**${data.result.earthing.label}**'
    ),
    if (data.originFaultLevelA != null)
      (
        strings(RptStringKey.edbOriginFault),
        strings.format(RptStringKey.edbOriginFaultValue, {
          'ka': _n(data.originFaultLevelA! / 1000),
          'ct': data.busbarClearingTimeS != null
              ? strings.format(RptStringKey.edbClearingTime,
                  {'s': data.busbarClearingTimeS!.toStringAsFixed(2)})
              : '',
        }) +
            switch (data.faultLevelBasis) {
              null => '',
              FaultLevelBasis.explicit =>
                strings(RptStringKey.edbFaultBasisExplicit),
              FaultLevelBasis.serviceEstimate =>
                strings(RptStringKey.edbFaultBasisEstimate),
              FaultLevelBasis.defaultValue =>
                strings(RptStringKey.edbFaultBasisDefault),
              FaultLevelBasis.supplyStudyEstimate =>
                strings(RptStringKey.edbFaultBasisSupplyStudy),
              FaultLevelBasis.generatorEstimate =>
                strings.format(RptStringKey.edbFaultBasisGenerator,
                    {'xd': kAlternatorXdPu.toStringAsFixed(2)}),
              FaultLevelBasis.inverterEstimate =>
                strings.format(RptStringKey.edbFaultBasisInverter,
                    {'m': inverterFaultMultiple.toStringAsFixed(1)}),
            }
      ),
    if (data.originFaultLevelA == null && data.busbarClearingTimeS != null)
      (
        strings(RptStringKey.edbClearingTimeKey),
        strings.format(RptStringKey.edbClearingTimeValue,
            {'s': data.busbarClearingTimeS!.toStringAsFixed(2)})
      ),
    // Round 37 — a dual-transformer service rates its single service-entrance
    // board on ONE section (coupler normally open), the fault basis's own.
    if (data.project.dualTransformer &&
        serviceEntranceCapacityVa(data.project) != null)
      (
        strings(RptStringKey.edbServiceSectionKey),
        strings.format(RptStringKey.edbServiceSectionValue, {
          'kva': _n(serviceEntranceCapacityVa(data.project)! / 1000),
          'total': _n(data.project.supplyCapacityVa!.voltAmperes / 1000),
        })
      ),
  ]);
}

/// Render the electrical Design Basis register into [b] (legacy writer, shared
/// with the unified MEP report's Markdown path). Rows only — no trailing blank
/// line; caller writes the `##` heading.
void writeElectricalDesignBasis(StringBuffer b, ElectricalCalcReportData data,
    [ReportStrings strings = const ReportStrings.en()]) {
  for (final (key, value) in electricalDesignBasisBlock(data, strings).rows) {
    b.writeln('- $key $value');
  }
}

/// The electrical Revision-history section as blocks (heading + table). Empty
/// [revisions] ⇒ an empty list.
List<RptBlock> electricalRevisionHistoryBlocks(List<Revision> revisions,
    [ReportStrings strings = const ReportStrings.en()]) {
  if (revisions.isEmpty) return const [];
  return [
    RptHeading(2, strings(RptStringKey.headingRevisionHistory)),
    RptTable(
      [strings(RptStringKey.tblDate), strings(RptStringKey.tblDescription)],
      [
        for (final r in revisions) [_md(r.date), _md(r.description)],
      ],
      mdSeparator: '| --- | --- |',
    ),
  ];
}

/// Render a Revision-history table into [b]. No-op when [revisions] is empty.
void writeElectricalRevisionHistory(StringBuffer b, List<Revision> revisions,
    [ReportStrings strings = const ReportStrings.en()]) {
  b.write(renderRptMarkdown(electricalRevisionHistoryBlocks(revisions, strings)));
}

/// Build [data] as the neutral block list — the one content model behind both
/// the Markdown render ([buildElectricalCalcReport]) and the PDF typesetter.
List<RptBlock> buildElectricalCalcReportBlocks(ElectricalCalcReportData data,
    [ReportStrings strings = const ReportStrings.en()]) {
  final r = data.result;
  final modelById = {for (final p in data.project.panels) p.id: p};

  final blocks = <RptBlock>[
    RptHeading(1,
        strings.format(RptStringKey.elecTitle, {'name': data.projectName})),
    RptKeyValue([
      (strings(RptStringKey.elecDate), data.date),
      (
        strings(RptStringKey.elecStandard),
        '${data.standardsName} ${data.standardsRevision}'.trimRight()
      ),
    ]),

    // ── Design basis / inputs & assumptions ───────────────────────────────────
    RptHeading(2, strings(RptStringKey.headingDesignBasis)),
    electricalDesignBasisBlock(data, strings),

    // ── Revision history (only when the caller tracks revisions) ──────────────
    ...electricalRevisionHistoryBlocks(data.revisions, strings),
  ];

  // ── Supply summary ────────────────────────────────────────────────────────
  final s = r.supply;
  blocks
    ..add(RptHeading(2, strings(RptStringKey.headingSupplySummary)))
    ..add(RptKeyValue([
      (
        strings(RptStringKey.ssSystem),
        '${_systemLabel(s.system, strings)}, ${_n(s.voltage.volts)} V'
      ),
      (strings(RptStringKey.edbConnectedLoad), '${_n(s.connectedW)} W'),
      (
        strings(RptStringKey.ssDiversifiedDemand),
        '${_n(s.demandW)} W (${_n(s.demandVa.inKilovoltAmperes)} kVA)'
      ),
      (strings(RptStringKey.ssOriginDemand), '${_n(r.totalDemandW)} W'),
      (strings(RptStringKey.edbEarthingSystem), r.earthing.label),
    ]));

  // ── Panels ────────────────────────────────────────────────────────────────
  blocks.add(RptHeading(2, strings(RptStringKey.headingPanels)));
  for (final id in r.order) {
    final p = r.panels[id];
    if (p == null) continue;
    final model = modelById[id];
    final tag = p.tag != null && p.tag!.isNotEmpty ? ' [${p.tag}]' : '';
    blocks.add(RptHeading(
        3,
        '${p.name}$tag — ${_systemLabel(p.system, strings)}'
        '${model != null ? ', ${_n(model.voltage.volts)} V' : ''}'));

    // Panel summary bullets: conditional bullets with an indented withstand
    // sub-bullet — a stubborn legacy construct, kept verbatim via RptMarkdown.
    final pb = StringBuffer();
    // Round 24 — a saturated incomer bullet carries the OVER RANGE token.
    pb.writeln(strings.format(RptStringKey.panelIncomer, {
          'rating': _rating(p.incomer.breaker.ratingA.amperes),
          'class': p.incomer.breaker.deviceClass.name.toUpperCase(),
          'poles': p.incomer.poles,
        }) +
        _kaToken(data.incomerKaByPanelId?[id], p.busbar.withstand?.faultKa) +
        incomerOverRangeSuffix(p.incomer));
    final bus = p.busbar;
    final busGeom = bus.widthMm > 0 && bus.thicknessMm > 0
        ? '${_n(bus.widthMm)}×${_n(bus.thicknessMm)} mm (${_n(bus.csaMm2)} mm²)'
        : '${_n(bus.csaMm2)} mm²';
    final reason = bus.sizingReason == BusbarSizingReason.withstand
        ? strings(RptStringKey.busbarReasonWithstand)
        : strings(RptStringKey.busbarReasonContinuous);
    pb.writeln(strings.format(RptStringKey.panelMainBusbar, {
      'geom': busGeom,
      'amp': _rating(bus.ampacityA.amperes),
      'reason': reason,
    }));
    final w = bus.withstand;
    if (w != null) {
      final verdict = w.adequate
          ? strings(RptStringKey.verdictOk)
          : strings(RptStringKey.verdictOver);
      pb.writeln(strings.format(RptStringKey.panelWithstand, {
        'fault': _n(w.faultKa),
        'dur': _n(w.durationS),
        'icw': _n(w.icwKa),
        'margin': _n(w.marginKa),
        'verdict': verdict,
      }));
    }
    if (p.busbarSections.length > 1) {
      pb.writeln(strings.format(RptStringKey.panelBusbarSections,
          {'n': p.busbarSections.length}));
    }
    pb.writeln(strings.format(RptStringKey.panelNeutralBar, {
      'n': _n(p.neutralPeBars.neutralCsaMm2),
      'oversize': p.neutralPeBars.neutralOversizeFactor > 1
          ? strings.format(RptStringKey.panelNeutralOversize,
              {'f': _n(p.neutralPeBars.neutralOversizeFactor)})
          : '',
      'pe': _n(p.neutralPeBars.peCsaMm2),
    }));
    // Round 19 — a diversified board's current is printed as the diversified
    // figure (pairs with the diversified W) with the undiversified worst-phase
    // sizing current labelled beside it, never the bare pre-diversity figure.
    pb.writeln(strings.format(RptStringKey.panelDemand, {
      'c': _n(_subtreeConnectedW(data.project, r, id)),
      'd': _n(p.demandW),
      'a': p.isDiversified
          ? strings.format(RptStringKey.panelDemandCurrentSplit, {
              'div': _a(p.diversifiedDemandCurrent.amperes),
              'undiv': _a(p.demandCurrent.amperes),
            })
          : _a(p.demandCurrent.amperes),
    }));
    if (p.system.isThreePhase) {
      pb.writeln(strings.format(RptStringKey.panelPhaseBalance, {
        'l1': p.phaseBalance.l1.toStringAsFixed(1),
        'l2': p.phaseBalance.l2.toStringAsFixed(1),
        'l3': p.phaseBalance.l3.toStringAsFixed(1),
        'imb': _pct(p.imbalancePercent),
      }));
    }
    pb.writeln();
    blocks.add(RptMarkdown(pb.toString()));

    // Circuits table.
    final branches = p.circuits;
    // Feeder way ids — a feeder's cumulative drop is the sub-bus drop its
    // downstream ways carry, so the verdict judges it on its own drop only
    // (the shared `voltageDropOverLimit` gate, same as the board schedule).
    final feederIds = {
      for (final mc in model?.circuits ?? const <ElectricalCircuit>[])
        if (mc.feedsPanelId != null) mc.id,
    };
    final modelCircuitById = {
      for (final mc in model?.circuits ?? const <ElectricalCircuit>[]) mc.id: mc,
    };
    if (branches.isNotEmpty) {
      blocks.add(RptTable(
        [
          strings(RptStringKey.tblWay),
          strings(RptStringKey.tblType),
          strings(RptStringKey.tblIb),
          strings(RptStringKey.tblPhase),
          strings(RptStringKey.tblBreaker),
          strings(RptStringKey.tblCable),
          strings(RptStringKey.tblLength),
          strings(RptStringKey.tblVdropCum),
          strings(RptStringKey.tblRcd),
        ],
        [
          for (final c in branches)
            [
              _md(c.name),
              loadKindLabel(c.loadKind, strings),
              // Round 17 — the RUN current the way's In / Iz / printed Vd are
              // sized on (undiversified for a final way), so a reviewer's
              // Ib -> Vd and Ib <= In <= Iz recompute closes; the diversified
              // figure stays in the phase balance / demand roll-up.
              _a(c.runCurrentA.amperes),
              _phaseCell(c.phase, strings),
              // An MCCB has no B/C/D trip characteristic — print the curve
              // letter for MCBs only (as the board schedule + legend do, N12).
              '${_rating(c.breaker.ratingA.amperes)} '
                  '${c.breaker.deviceClass.name.toUpperCase()}'
                  '${c.breaker.deviceClass.hasTripCurve ? '/${c.breaker.curve.name.toUpperCase()}' : ''}'
                  '${_kaToken(data.breakerKaByCircuitId?[c.circuitId], p.busbar.withstand?.faultKa)}',
              // Round 39 (elec-reports-parity-4) — the SAME conductor make-up
              // the board schedule issues (family, cores, reduced N / PE,
              // `Nx(...)` for parallel runs) — never a bare '4×300 mm²' that
              // reads as one 4-core cable. A spare way pulls no cable.
              _reportCableCell(c, modelCircuitById[c.circuitId]),
              // Run length (N8) — the figure that drove the printed Vdrop;
              // geo-derived when placed, else the manual length. Absent ⇒ '—'.
              // One 0.1 m length format across every deliverable (Round 20
              // follow-up): the board schedule prints the same figure.
              c.lengthM > 0 ? planLengthLabel(Length(c.lengthM)) : '—',
              _vdropCell(c, feederIds.contains(c.circuitId), strings),
              c.rcd.required
                  ? '${c.rcd.ratingMa} mA${c.rcd.type != null ? ' ${c.rcd.type!.name.toUpperCase()}' : ''}'
                      '${c.rcd.timeDelayed ? ' S' : ''}'
                  : '—',
            ],
        ],
        mdSeparator: '| --- | --- | --- | --- | --- | --- | --- | --- | --- |',
      ));
    }

    // Per-panel warnings — the panel's own list PLUS (R1) any finding of the
    // combined surface that carries this panel's id and isn't already in it
    // (the advanced fault study's selectivity / breaking-capacity / withstand
    // findings). Deduped on (code, circuitId) so a warning never prints twice.
    final panelWarnings = <ElectricalWarning>[...p.warnings];
    final all = data.allWarnings;
    if (all != null) {
      final known = {for (final w in p.warnings) (w.code, w.circuitId)};
      for (final w in all) {
        if (w.panelId != id) continue;
        if (!known.add((w.code, w.circuitId))) continue;
        panelWarnings.add(w);
      }
    }
    if (panelWarnings.isNotEmpty) {
      blocks.add(RptKeyValue([
        for (final w in panelWarnings)
          ('',
              '_${_severityTag(w.severity, strings)}_: ${strings.format(RptStringKey.warnLeadIn, {'code': w.code})}${w.message}'),
      ]));
    }
  }

  // ── Earthing ────────────────────────────────────────────────────────────--
  final e = r.earthing;
  blocks
    ..add(RptHeading(2, strings(RptStringKey.headingEarthing)))
    ..add(RptKeyValue([
      (strings(RptStringKey.ssSystem), e.label),
      (strings(RptStringKey.eMainEarthing), '${e.mainEarthingMakeup} mm²'),
      (strings(RptStringKey.eMainBonding), '${_n(e.mainBondingConductorMm2)} mm²'),
      (
        strings(RptStringKey.eElectrodeTarget),
        '${_n(e.electrodeResistanceTarget.ohms)} Ω'
      ),
      if (e.note.isNotEmpty) ('', _earthingNote(e, strings)),
    ]));

  // ── Power one-line ─────────────────────────────────────────────────────────
  final ol = data.powerOneLine;
  if (ol != null && ol.nodes.isNotEmpty) {
    blocks
      ..add(RptHeading(2, strings(RptStringKey.headingPowerOneLine)))
      ..add(RptKeyValue([
        for (final node in ol.nodes)
          (
            '',
            '${_oneLineLabel(node.label, strings)} '
                '(${_oneLineKindLabel(node, strings)})'
                '${node.sub != null ? ' — ${_oneLineSub(node.sub!, strings)}' : ''}'
          ),
      ]));
    if (ol.interlocks.isNotEmpty) {
      blocks
        ..add(RptHeading(3, strings(RptStringKey.headingSourceInterlocks)))
        ..add(RptKeyValue([
          for (final il in ol.interlocks)
            (
              '',
              '_${interlockKindLabel(il.kind, strings)}_: '
                  '${strings.locale == ReportLocale.id ? strings(RptStringKey.olNoteLead) : ''}'
                  '${il.note}'
            ),
        ]));
    }
  }

  // ── System warnings ─────────────────────────────────────────────────────--
  // R1: the COMBINED surface when the caller supplies it (core + fault study),
  // else the core list alone (byte-identical legacy output).
  final systemWarnings = data.allWarnings ?? r.warnings;
  if (systemWarnings.isNotEmpty) {
    blocks
      ..add(RptHeading(2, strings(RptStringKey.headingWarnings)))
      ..add(RptKeyValue([
        for (final w in systemWarnings)
          ('',
              '_${_severityTag(w.severity, strings)}_: ${strings.format(RptStringKey.warnLeadIn, {'code': w.code})}${w.message}'),
      ]));
  }

  // ── Unverified values ──────────────────────────────────────────────────────
  final provenance = data.standardsProvenance;
  if (data.verifyItems.isNotEmpty ||
      data.verifyChecklist.isNotEmpty ||
      provenance != null) {
    // Round 30 (report-parity-2-3) — the advanced study's U0 line restates
    // the profile's own U0 entry: print the basis once.
    final checklistHasU0 =
        data.verifyChecklist.any((v) => v.citation.contains('U0'));
    final plain = [
      for (final v in data.verifyItems)
        if (!(checklistHasU0 && v == faultStudyU0VerifyItem)) v,
    ];
    // The notes are English source text: ID carries the explicit lead, like
    // the warnings and interlocks.
    final lead = strings.locale == ReportLocale.id
        ? strings(RptStringKey.olNoteLead)
        : '';
    blocks
      ..add(RptHeading(2, strings(RptStringKey.headingUnverifiedElec)))
      ..add(RptParagraph(strings(RptStringKey.unverifiedElecIntro)))
      ..add(RptKeyValue([
        if (provenance != null) ('', provenance),
        for (final v in plain) ('', '$lead$v'),
        for (final v in data.verifyChecklist)
          ('',
              '$lead**${v.citation}**${_statusTag(v.status, strings)}'
                  '${v.note == null ? '' : ' — ${v.note}'}'),
      ]));
  }

  return blocks;
}

/// Render [data] as a Markdown electrical calculation report.
String buildElectricalCalcReport(ElectricalCalcReportData data,
        [ReportStrings strings = const ReportStrings.en()]) =>
    renderRptMarkdown(buildElectricalCalcReportBlocks(data, strings));

// Round 17 follow-up (i18n-residuals-oneline-section-english-in-id-report) —
// the power one-line's fixed node labels / sub-captions are the engine's EN
// literals (power_oneline.dart); the report localizes the known ones and
// leaves anything else (a user-named node, a numeric sub) verbatim. The
// interlock sentences stay EN but carry the explicit English-note lead in ID,
// like the warnings section.
const Map<String, RptStringKey> _oneLineLabelKeys = {
  'Main LV bus': RptStringKey.olMainLvBus,
  'Main panel': RptStringKey.olMainPanel,
  'PLN utility': RptStringKey.olPlnUtility,
  'Generator': RptStringKey.olGenerator,
  'Essential bus': RptStringKey.olEssentialBus,
  'Hybrid inverter': RptStringKey.olHybridInverter,
  'Solar array': RptStringKey.olSolarArray,
  'Battery': RptStringKey.olBattery,
  'PV inverter': RptStringKey.olPvInverter,
  'Battery inverter': RptStringKey.olBatteryInverter,
  'UPS / critical bus': RptStringKey.olUpsCriticalBus,
};

String _oneLineLabel(String label, ReportStrings strings) {
  final key = _oneLineLabelKeys[label];
  return key == null ? label : strings(key);
}

/// A MANUAL changeover node is drawn 'COS' with the ATS kind — its tag must
/// read (COS), never (ATS).
String _oneLineKindLabel(PowerNode node, ReportStrings strings) =>
    node.kind == PowerNodeKind.ats && node.label == 'COS'
        ? strings(RptStringKey.pnCos)
        : powerNodeKindLabel(node.kind, strings);

final RegExp _voltsLv = RegExp(r'^([0-9.,]+) V LV$');

String _oneLineSub(String sub, ReportStrings strings) {
  if (sub == 'manual changeover') {
    return strings(RptStringKey.olManualChangeover);
  }
  if (sub == 'transfer switch') return strings(RptStringKey.olTransferSwitch);
  // Round 30 (report-parity-2-5) — the genset caption's mode word.
  for (final (word, key) in [
    (' kVA Prime (continuous)', RptStringKey.olGenPrime),
    (' kVA Standby', RptStringKey.olGenStandby),
  ]) {
    final i = sub.indexOf(word);
    if (i >= 0) {
      return '${sub.substring(0, i)} kVA ${strings(key)}'
          '${sub.substring(i + word.length)}';
    }
  }
  final m = _voltsLv.firstMatch(sub);
  if (m != null) {
    return strings.format(RptStringKey.olVoltsLv, {'v': m.group(1)});
  }
  return sub;
}


/// Round 39 (elec-reports-parity-4) — the report's cable cell: the board
/// schedule's own [cableRunLabel] when the model circuit is known, else
/// `N x (<csa> mm²)` / `<csa> mm²`; a spare way '—'.
String _reportCableCell(ElectricalCircuitResult c, ElectricalCircuit? model) {
  if (c.loadKind == LoadKind.spare) return '—';
  final runs = c.cable.runsPerPhase ?? 1;
  if (model == null) {
    final single = '${_n(c.cable.csaMm2)} mm²';
    return runs > 1 ? '$runs x ($single)' : single;
  }
  // Round 42 — a star-delta way's field run is its two motor leads (the
  // schedule's PENGHANTAR cell).
  final leads = c.motorLeads;
  if (leads != null) {
    return 'leads ${cableRunLabel(model, leads.csaMm2, true, cores: 4, runs: 2 * (leads.runsPerPhase ?? 1), peCsaMm2: c.motorLeadsPeCsaMm2)}';
  }
  return cableRunLabel(model, c.cable.csaMm2, c.threePhase,
      cores: c.grounding.cores,
      runs: c.cable.runsPerPhase,
      peCsaMm2: c.grounding.peCsaMm2,
      neutralCsaMm2: c.grounding.neutralCsaMm2);
}

/// Round 39 (elec-reports-parity-6) — the Vdrop cell: own + cumulative drop,
/// each printed in its verdict's direction so 'OVER' never sits beside a
/// figure that satisfies the limit.
String _vdropCell(
    ElectricalCircuitResult c, bool isFeeder, ReportStrings strings) {
  final over = voltageDropOverLimit(c, isFeeder: isFeeder);
  final limit = c.voltageDrop.limitPercent;
  final ownOver = !c.voltageDrop.withinLimit;
  final cumOver = over && !isFeeder && c.cumulativeDropPercent > limit + 1e-9;
  final own = vdropPctForVerdict(c.voltageDrop.dropPercent,
      limit: limit, over: ownOver);
  final cum = vdropPctForVerdict(c.cumulativeDropPercent,
      limit: limit, over: cumOver);
  return '$own% ($cum%)${over ? ' ${strings(RptStringKey.verdictOver)}' : ''}';
}
