/// Electrical calculation-report generator — renders the sized electrical
/// system (panels, incomers, busbars, circuits, earthing, the optional hybrid
/// power one-line and warnings) as Markdown. The electrical mirror of
/// `calc_report.dart`.
///
/// Pure: takes already-computed result records in [ElectricalCalcReportData]
/// and returns a string. Zero Flutter imports — the app gathers provider values
/// into the data struct and handles file IO. Every unverified value is surfaced
/// in a dedicated "Unverified values" section so the report never hides
/// provenance gaps (§8 / golden rule 6).
library;

import '../electrical/model.dart';
import '../electrical/panel_results.dart';
import '../electrical/power_oneline.dart';
import '../electrical/results.dart' show BusbarSizingReason;

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

  const ElectricalCalcReportData({
    required this.projectName,
    required this.date,
    required this.standardsName,
    required this.standardsRevision,
    required this.project,
    required this.result,
    this.powerOneLine,
    this.verifyItems = const [],
  });
}

String _n(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

String _a(double amperes) => '${_n(amperes)} A';

String _severityTag(WarningSeverity s) => switch (s) {
      WarningSeverity.error => 'ERROR',
      WarningSeverity.warning => 'WARN',
      WarningSeverity.info => 'INFO',
    };

/// Render [data] as a Markdown electrical calculation report.
String buildElectricalCalcReport(ElectricalCalcReportData data) {
  final b = StringBuffer();
  final r = data.result;
  final modelById = {for (final p in data.project.panels) p.id: p};

  b.writeln('# Electrical calculation report — ${data.projectName}');
  b.writeln();
  b.writeln('- Date: ${data.date}');
  b.writeln(
      '- Standard: ${data.standardsName} ${data.standardsRevision}'.trimRight());
  b.writeln();

  // ── Supply summary ────────────────────────────────────────────────────────
  final s = r.supply;
  b.writeln('## Supply summary');
  b.writeln();
  b.writeln('- System: ${s.system.label}, ${_n(s.voltage.volts)} V');
  b.writeln('- Connected load: ${_n(s.connectedW)} W');
  b.writeln(
      '- Diversified demand: ${_n(s.demandW)} W (${_n(s.demandVa.inKilovoltAmperes)} kVA)');
  b.writeln('- Origin diversified demand: ${_n(r.totalDemandW)} W');
  b.writeln('- Earthing system: ${r.earthing.label}');
  b.writeln();

  // ── Panels ────────────────────────────────────────────────────────────────
  b.writeln('## Panels');
  b.writeln();
  for (final id in r.order) {
    final p = r.panels[id];
    if (p == null) continue;
    final model = modelById[id];
    final tag = p.tag != null && p.tag!.isNotEmpty ? ' [${p.tag}]' : '';
    b.writeln('### ${p.name}$tag — ${p.system.label}'
        '${model != null ? ', ${_n(model.voltage.volts)} V' : ''}');
    b.writeln();
    b.writeln('- Incomer: ${_a(p.incomer.breaker.ratingA.amperes)} '
        '${p.incomer.breaker.deviceClass.name.toUpperCase()} '
        '${p.incomer.poles}P');

    final bus = p.busbar;
    final busGeom = bus.widthMm > 0 && bus.thicknessMm > 0
        ? '${_n(bus.widthMm)}×${_n(bus.thicknessMm)} mm (${_n(bus.csaMm2)} mm²)'
        : '${_n(bus.csaMm2)} mm²';
    final reason = bus.sizingReason == BusbarSizingReason.withstand
        ? 'short-circuit withstand'
        : 'continuous current';
    b.writeln('- Main busbar: $busGeom, ampacity ${_a(bus.ampacityA.amperes)} '
        '— governed by $reason');
    final w = bus.withstand;
    if (w != null) {
      final verdict = w.adequate ? 'OK' : 'OVER';
      b.writeln('  - Withstand: fault ${_n(w.faultKa)} kA for ${_n(w.durationS)} s, '
          'Icw ${_n(w.icwKa)} kA, margin ${_n(w.marginKa)} kA ($verdict)');
    }
    if (p.busbarSections.length > 1) {
      b.writeln('- Busbar sections: ${p.busbarSections.length} '
          '(radial split, IEC 61439-1)');
    }
    b.writeln('- Neutral bar: ${_n(p.neutralPeBars.neutralCsaMm2)} mm²'
        '${p.neutralPeBars.neutralOversizeFactor > 1 ? ' (×${_n(p.neutralPeBars.neutralOversizeFactor)} triplen oversize)' : ''}'
        ', PE bar: ${_n(p.neutralPeBars.peCsaMm2)} mm²');
    b.writeln('- Demand: connected ${_n(p.connectedW)} W, '
        'diversified ${_n(p.demandW)} W, ${_a(p.demandCurrent.amperes)}');
    if (p.system.isThreePhase) {
      b.writeln('- Phase balance: L1 ${_n(p.phaseBalance.l1)} A · '
          'L2 ${_n(p.phaseBalance.l2)} A · L3 ${_n(p.phaseBalance.l3)} A '
          '(imbalance ${_n(p.imbalancePercent)} %)');
    }
    b.writeln();

    // Circuits table.
    final branches = p.circuits;
    if (branches.isNotEmpty) {
      b.writeln('| Way | Type | Ib | Phase | Breaker | Cable | Vdrop (cum) | RCD |');
      b.writeln('| --- | --- | --- | --- | --- | --- | --- | --- |');
      for (final c in branches) {
        final br = '${_a(c.breaker.ratingA.amperes)} '
            '${c.breaker.deviceClass.name.toUpperCase()}/${c.breaker.curve.name.toUpperCase()}';
        final runs =
            (c.cable.runsPerPhase ?? 1) > 1 ? '${c.cable.runsPerPhase}×' : '';
        final cable = '$runs${_n(c.cable.csaMm2)} mm²';
        final vd = '${_n(c.voltageDrop.dropPercent)}% '
            '(${_n(c.cumulativeDropPercent)}%)'
            '${c.voltageDrop.withinLimit ? '' : ' OVER'}';
        final rcd = c.rcd.required
            ? '${c.rcd.ratingMa} mA${c.rcd.type != null ? ' ${c.rcd.type!.name.toUpperCase()}' : ''}'
            : '—';
        b.writeln('| ${c.name} | ${c.loadKind.name} | ${_a(c.designCurrent.amperes)} '
            '| ${c.phase.label} | $br | $cable | $vd | $rcd |');
      }
      b.writeln();
    }

    // Per-panel warnings.
    if (p.warnings.isNotEmpty) {
      for (final w in p.warnings) {
        b.writeln('- _${_severityTag(w.severity)}_: ${w.message}');
      }
      b.writeln();
    }
  }

  // ── Earthing ────────────────────────────────────────────────────────────--
  final e = r.earthing;
  b.writeln('## Earthing');
  b.writeln();
  b.writeln('- System: ${e.label}');
  b.writeln('- Main earthing conductor: ${_n(e.mainEarthingConductorMm2)} mm²');
  b.writeln('- Main bonding conductor: ${_n(e.mainBondingConductorMm2)} mm²');
  b.writeln(
      '- Electrode resistance target: ${_n(e.electrodeResistanceTarget.ohms)} Ω');
  if (e.note.isNotEmpty) b.writeln('- ${e.note}');
  b.writeln();

  // ── Power one-line ─────────────────────────────────────────────────────────
  final ol = data.powerOneLine;
  if (ol != null && ol.nodes.isNotEmpty) {
    b.writeln('## Power one-line');
    b.writeln();
    for (final node in ol.nodes) {
      final sub = node.sub != null ? ' — ${node.sub}' : '';
      b.writeln('- ${node.label} (${node.kind.name})$sub');
    }
    if (ol.interlocks.isNotEmpty) {
      b.writeln();
      b.writeln('### Source interlocks');
      b.writeln();
      for (final il in ol.interlocks) {
        b.writeln('- _${il.kind.name}_: ${il.note}');
      }
    }
    b.writeln();
  }

  // ── System warnings ─────────────────────────────────────────────────────--
  if (r.warnings.isNotEmpty) {
    b.writeln('## Warnings');
    b.writeln();
    for (final w in r.warnings) {
      b.writeln('- _${_severityTag(w.severity)}_: ${w.message}');
    }
    b.writeln();
  }

  // ── Unverified values ──────────────────────────────────────────────────────
  if (data.verifyItems.isNotEmpty) {
    b.writeln('## Unverified values');
    b.writeln();
    b.writeln('These values are not yet confirmed verbatim against the official '
        'PUIL/SNI clause and should be verified before construction:');
    b.writeln();
    for (final v in data.verifyItems) {
      b.writeln('- $v');
    }
    b.writeln();
  }

  return b.toString();
}
