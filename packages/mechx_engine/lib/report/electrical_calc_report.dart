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

import '../electrical/model.dart';
import '../electrical/panel_results.dart';
import '../electrical/power_oneline.dart';
import '../electrical/results.dart' show BusbarSizingReason;
import '../standards/sni.dart' show Revision;
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

  /// Prospective short-circuit current at the supply origin (A) — the Fold-1
  /// busbar-withstand fault target. Null ⇒ omitted from the Design Basis.
  final double? originFaultLevelA;

  /// Protective-device clearing time (s) for the busbar withstand check. Null ⇒
  /// omitted from the Design Basis.
  final double? busbarClearingTimeS;

  /// Revision history (caller-supplied). Empty ⇒ no Revision-history table, so a
  /// caller that does not populate it gets byte-identical legacy output.
  final List<Revision> revisions;

  const ElectricalCalcReportData({
    required this.projectName,
    required this.date,
    required this.standardsName,
    required this.standardsRevision,
    required this.project,
    required this.result,
    this.powerOneLine,
    this.verifyItems = const [],
    this.originFaultLevelA,
    this.busbarClearingTimeS,
    this.revisions = const [],
  });
}

String _n(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

String _a(double amperes) => '${_n(amperes)} A';

/// Escape a value for a Markdown table cell: a literal `|` would split the row
/// into extra columns; a newline would break it.
String _md(String v) => v.replaceAll('|', r'\|').replaceAll('\n', ' ');

String _severityTag(WarningSeverity s) => switch (s) {
      WarningSeverity.error => 'ERROR',
      WarningSeverity.warning => 'WARN',
      WarningSeverity.info => 'INFO',
    };

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
      '**${s.system.label}, ${_n(s.voltage.volts)} V**'
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
      (strings(RptStringKey.ssSystem), '${s.system.label}, ${_n(s.voltage.volts)} V'),
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
        '${p.name}$tag — ${p.system.label}'
        '${model != null ? ', ${_n(model.voltage.volts)} V' : ''}'));

    // Panel summary bullets: conditional bullets with an indented withstand
    // sub-bullet — a stubborn legacy construct, kept verbatim via RptMarkdown.
    final pb = StringBuffer();
    pb.writeln(strings.format(RptStringKey.panelIncomer, {
      'rating': _a(p.incomer.breaker.ratingA.amperes),
      'class': p.incomer.breaker.deviceClass.name.toUpperCase(),
      'poles': p.incomer.poles,
    }));
    final bus = p.busbar;
    final busGeom = bus.widthMm > 0 && bus.thicknessMm > 0
        ? '${_n(bus.widthMm)}×${_n(bus.thicknessMm)} mm (${_n(bus.csaMm2)} mm²)'
        : '${_n(bus.csaMm2)} mm²';
    final reason = bus.sizingReason == BusbarSizingReason.withstand
        ? strings(RptStringKey.busbarReasonWithstand)
        : strings(RptStringKey.busbarReasonContinuous);
    pb.writeln(strings.format(RptStringKey.panelMainBusbar, {
      'geom': busGeom,
      'amp': _a(bus.ampacityA.amperes),
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
    pb.writeln(strings.format(RptStringKey.panelDemand, {
      'c': _n(p.connectedW),
      'd': _n(p.demandW),
      'a': _a(p.demandCurrent.amperes),
    }));
    if (p.system.isThreePhase) {
      pb.writeln(strings.format(RptStringKey.panelPhaseBalance, {
        'l1': _n(p.phaseBalance.l1),
        'l2': _n(p.phaseBalance.l2),
        'l3': _n(p.phaseBalance.l3),
        'imb': _n(p.imbalancePercent),
      }));
    }
    pb.writeln();
    blocks.add(RptMarkdown(pb.toString()));

    // Circuits table.
    final branches = p.circuits;
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
              c.loadKind.name,
              _a(c.designCurrent.amperes),
              c.phase.label,
              '${_a(c.breaker.ratingA.amperes)} '
                  '${c.breaker.deviceClass.name.toUpperCase()}/${c.breaker.curve.name.toUpperCase()}',
              '${(c.cable.runsPerPhase ?? 1) > 1 ? '${c.cable.runsPerPhase}×' : ''}'
                  '${_n(c.cable.csaMm2)} mm²',
              // Run length (N8) — the figure that drove the printed Vdrop;
              // geo-derived when placed, else the manual length. Absent ⇒ '—'.
              c.lengthM > 0 ? '${_n(c.lengthM)} m' : '—',
              '${_n(c.voltageDrop.dropPercent)}% '
                  '(${_n(c.cumulativeDropPercent)}%)'
                  '${c.voltageDrop.withinLimit ? '' : ' ${strings(RptStringKey.verdictOver)}'}',
              c.rcd.required
                  ? '${c.rcd.ratingMa} mA${c.rcd.type != null ? ' ${c.rcd.type!.name.toUpperCase()}' : ''}'
                  : '—',
            ],
        ],
        mdSeparator: '| --- | --- | --- | --- | --- | --- | --- | --- | --- |',
      ));
    }

    // Per-panel warnings.
    if (p.warnings.isNotEmpty) {
      blocks.add(RptKeyValue([
        for (final w in p.warnings)
          ('', '_${_severityTag(w.severity)}_: ${w.message}'),
      ]));
    }
  }

  // ── Earthing ────────────────────────────────────────────────────────────--
  final e = r.earthing;
  blocks
    ..add(RptHeading(2, strings(RptStringKey.headingEarthing)))
    ..add(RptKeyValue([
      (strings(RptStringKey.ssSystem), e.label),
      (strings(RptStringKey.eMainEarthing), '${_n(e.mainEarthingConductorMm2)} mm²'),
      (strings(RptStringKey.eMainBonding), '${_n(e.mainBondingConductorMm2)} mm²'),
      (
        strings(RptStringKey.eElectrodeTarget),
        '${_n(e.electrodeResistanceTarget.ohms)} Ω'
      ),
      if (e.note.isNotEmpty) ('', e.note),
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
            '${node.label} (${node.kind.name})'
                '${node.sub != null ? ' — ${node.sub}' : ''}'
          ),
      ]));
    if (ol.interlocks.isNotEmpty) {
      blocks
        ..add(RptHeading(3, strings(RptStringKey.headingSourceInterlocks)))
        ..add(RptKeyValue([
          for (final il in ol.interlocks)
            ('', '_${il.kind.name}_: ${il.note}'),
        ]));
    }
  }

  // ── System warnings ─────────────────────────────────────────────────────--
  if (r.warnings.isNotEmpty) {
    blocks
      ..add(RptHeading(2, strings(RptStringKey.headingWarnings)))
      ..add(RptKeyValue([
        for (final w in r.warnings)
          ('', '_${_severityTag(w.severity)}_: ${w.message}'),
      ]));
  }

  // ── Unverified values ──────────────────────────────────────────────────────
  if (data.verifyItems.isNotEmpty) {
    blocks
      ..add(RptHeading(2, strings(RptStringKey.headingUnverifiedElec)))
      ..add(RptParagraph(strings(RptStringKey.unverifiedElecIntro)))
      ..add(RptKeyValue([for (final v in data.verifyItems) ('', v)]));
  }

  return blocks;
}

/// Render [data] as a Markdown electrical calculation report.
String buildElectricalCalcReport(ElectricalCalcReportData data,
        [ReportStrings strings = const ReportStrings.en()]) =>
    renderRptMarkdown(buildElectricalCalcReportBlocks(data, strings));
