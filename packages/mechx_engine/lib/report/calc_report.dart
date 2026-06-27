/// Calculation-report generator — renders a full MEP design summary as
/// Markdown (engineer-friendly, plain-text, diffable, convertible to PDF).
///
/// Pure: takes already-computed typed results in [CalcReportData] and returns a
/// string. Zero Flutter imports — the app gathers provider values into the data
/// struct and handles file IO. Every UNVERIFIED standard value is surfaced in a
/// dedicated section so the report never hides provenance gaps (§8).
library;

import '../geometry/building.dart';
import '../network/network.dart';
import '../network/zoning.dart';
import '../sizing/bom.dart';
import '../sizing/fan.dart';
import '../sizing/fire_pump_rating.dart';
import '../sizing/fire_sprinkler.dart';
import '../sizing/fire_sprinkler_hydraulic.dart';
import '../sizing/fire_standpipe.dart';
import '../sizing/hot_water.dart';
import '../sizing/operating_point.dart';
import '../sizing/pump.dart';
import '../standards/sni.dart';
import '../units.dart';

/// All inputs the calc report renders. Systems that aren't present are null /
/// empty and their sections are skipped.
class CalcReportData {
  final String projectName;
  final String date;
  final String standardsName;
  final String standardsRevision;
  final List<StandardValue<Object?>> verifyItems;

  final BuildingLevels building;

  final String feedStrategy;
  final Pressure targetResidual;
  final PumpDuty? pump; // upfeed
  final Head? boosterHead; // downfeed shortfall (null if n/a)
  final bool gravitySufficient;
  final List<DownfeedZoneStatic> zones;
  final HotWaterRecircDesign? hotWaterRecirc;

  final SprinklerDesign? sprinkler;
  final FireStandpipeDesign? standpipe;

  /// Remote-area hydraulic check for the sprinkler design (K-factor + branch
  /// friction + minimum-operating-pressure verdict). Null ⇒ section skipped.
  final SprinklerRemoteAreaResult? sprinklerRemoteArea;

  /// NFPA 20 fire-pump rating-curve check (churn/rated/overload points + jockey
  /// + duty/standby). Null ⇒ section skipped.
  final FirePumpRatingResult? firePumpRating;

  final FanDuty? fan;
  final double supplyAirflowLps;
  final double returnAirflowLps;

  /// Pump system × equipment curve operating point (intersection + stability +
  /// NPSH cavitation check). When null the renderer falls back to
  /// [pump]'s own `operatingPoint`; if both are null the section is skipped.
  /// Its curve coefficients are // VERIFY representative estimates.
  final PumpOperatingPoint? pumpOperatingPoint;

  /// Fan system × equipment curve operating point. Falls back to [fan]'s own
  /// `operatingPoint`; both null ⇒ skipped. // VERIFY representative curves.
  final FanOperatingPoint? fanOperatingPoint;

  /// Design rainfall intensity (mm/hr) driving the storm/rainwater sizing.
  final double rainfallMmPerHr;

  /// Design storm runoff coefficient C (dimensionless, 0–1) — the fraction of
  /// rainfall that becomes runoff at the outlet (rational method).
  final double runoffCoefficient;

  final List<BomLine> bom;
  final List<FittingLine> fittings;

  /// Building occupancy class for the Design Basis register (UBAP fixture loads
  /// / demand). Null ⇒ the line is omitted (legacy output byte-identical).
  final Occupancy? occupancy;

  /// Revision history (caller-supplied). Empty ⇒ no Revision-history table, so a
  /// caller that does not populate it gets byte-identical legacy output.
  final List<Revision> revisions;

  const CalcReportData({
    required this.projectName,
    required this.date,
    required this.standardsName,
    required this.standardsRevision,
    required this.verifyItems,
    required this.building,
    required this.feedStrategy,
    required this.targetResidual,
    this.pump,
    this.boosterHead,
    this.gravitySufficient = false,
    this.zones = const [],
    this.hotWaterRecirc,
    this.sprinkler,
    this.standpipe,
    this.sprinklerRemoteArea,
    this.firePumpRating,
    this.fan,
    this.supplyAirflowLps = 0,
    this.returnAirflowLps = 0,
    this.pumpOperatingPoint,
    this.fanOperatingPoint,
    this.rainfallMmPerHr = 200.0,
    this.runoffCoefficient = 1.0,
    this.bom = const [],
    this.fittings = const [],
    this.occupancy,
    this.revisions = const [],
  });
}

String _occupancyLabel(Occupancy o) => switch (o) {
      Occupancy.private => 'Private',
      Occupancy.public => 'Public',
      Occupancy.assembly => 'Assembly',
    };

/// A short, honest label for an unverified value's provenance tier.
String _statusTag(VerificationStatus s) => switch (s) {
      VerificationStatus.sniVerbatim => '',
      VerificationStatus.secondarySource =>
        ' _(secondary source — confirm against the SNI clause)_',
      VerificationStatus.notAnSniClause =>
        ' _(not an SNI clause — general engineering practice)_',
    };

String _service(ServiceType s) => switch (s) {
      ServiceType.coldWater => 'Cold water',
      ServiceType.hotWater => 'Hot water',
      ServiceType.drainage => 'Drainage',
      ServiceType.vent => 'Vent',
      ServiceType.rainwater => 'Rainwater',
      ServiceType.duct => 'Supply air',
      ServiceType.returnAir => 'Return air',
      ServiceType.exhaust => 'Exhaust',
      ServiceType.fireSprinkler => 'Sprinkler',
      ServiceType.fireHydrant => 'Hydrant',
    };

/// Render the mechanical **Design Basis / Inputs & Assumptions** register into
/// [b] from [d]. A bulleted echo of the actual project inputs (building,
/// occupancy, feed, residual target, fire systems, rainfall) so the report
/// states the assumptions it was computed under. Shared with the unified MEP
/// report so both surfaces read the same basis. Caller writes the `##` heading.
void writeMechanicalDesignBasis(StringBuffer b, CalcReportData d) {
  b.writeln('- Levels: **${d.building.levelCount}**, total height '
      '**${d.building.totalHeight.meters.toStringAsFixed(2)} m**');
  if (d.occupancy != null) {
    b.writeln('- Occupancy class: **${_occupancyLabel(d.occupancy!)}** '
        '(UBAP fixture-unit loads / Hunter demand)');
  }
  b.writeln('- Water feed strategy: **${d.feedStrategy}**');
  b.writeln('- Target fixture residual: '
      '**${d.targetResidual.inKiloPascals.toStringAsFixed(0)} kPa**');
  b.writeln('- Design rainfall: **${d.rainfallMmPerHr.toStringAsFixed(0)} mm/hr** '
      '· runoff C **${d.runoffCoefficient.toStringAsFixed(2)}** (rational method)');
  final fireSystems = <String>[
    if (d.sprinkler != null) 'sprinkler',
    if (d.standpipe != null) 'standpipe / hydrant',
  ];
  b.writeln('- Fire protection: '
      '**${fireSystems.isEmpty ? 'none modelled' : fireSystems.join(' + ')}**');
}

/// Render a Revision-history table into [b]. No-op when [revisions] is empty, so
/// a caller that does not track revisions gets byte-identical legacy output.
void writeRevisionHistory(StringBuffer b, List<Revision> revisions) {
  if (revisions.isEmpty) return;
  b.writeln('## Revision history');
  b.writeln();
  b.writeln('| Date | Description |');
  b.writeln('|---|---|');
  for (final r in revisions) {
    final desc = r.description.replaceAll('|', r'\|').replaceAll('\n', ' ');
    b.writeln('| ${r.date} | $desc |');
  }
  b.writeln();
}

/// Render [d] as a Markdown calculation report.
String buildCalcReportMarkdown(CalcReportData d) {
  final b = StringBuffer();
  b.writeln('# MEP Calculation Report — ${d.projectName}');
  b.writeln();
  b.writeln('_Generated ${d.date} · MechX_');
  b.writeln();
  b.writeln('**Standards basis:** ${d.standardsName} (${d.standardsRevision})');
  b.writeln();

  // ── Design basis / inputs & assumptions ─────────────────────────────────────
  b.writeln('## Design basis');
  b.writeln();
  writeMechanicalDesignBasis(b, d);
  b.writeln();

  // ── Revision history (only when the caller tracks revisions) ────────────────
  writeRevisionHistory(b, d.revisions);

  // ── Unverified values (provenance honesty) ─────────────────────────────────
  final unverified = d.verifyItems.where((v) => v.isUnverified).toList();
  b.writeln('## ⚠ Unverified values');
  if (unverified.isEmpty) {
    b.writeln('All standard values used are verified against source text.');
  } else {
    b.writeln('The following values are placeholders / secondary-sourced and '
        'MUST be confirmed against the official standard before this report '
        'is used for a submission:');
    b.writeln();
    for (final v in unverified) {
      // Print the citation plus the human-readable `note` (which carries the
      // correctly-scaled value, e.g. "≈392 kPa"). We deliberately do NOT print
      // the raw `value`+`unit` pair: typed quantities store SI base units
      // (Pressure in Pa) while `unit` is a display label (kPa), so pairing them
      // would mis-scale numbers by 1000×. Fall back to value+unit only when no
      // note is supplied (those entries are non-numeric, e.g. the demand curve).
      final detail = v.note ?? '${v.value} ${v.unit}';
      b.writeln('- **${v.citation}**${_statusTag(v.status)} — $detail');
    }
  }
  b.writeln();

  // ── Building ────────────────────────────────────────────────────────────────
  b.writeln('## Building');
  b.writeln();
  b.writeln('| Floor | Height (m) | Elevation (m) |');
  b.writeln('|---|---:|---:|');
  for (var i = d.building.levelCount - 1; i >= 0; i--) {
    final f = d.building.floors[i];
    b.writeln('| ${f.name} | ${f.height.meters.toStringAsFixed(2)} '
        '| ${d.building.elevationOf(i).meters.toStringAsFixed(2)} |');
  }
  b.writeln();
  b.writeln('Total height: **${d.building.totalHeight.meters.toStringAsFixed(2)} m** '
      'over ${d.building.levelCount} levels.');
  b.writeln();

  // ── Water supply ──────────────────────────────────────────────────────────
  b.writeln('## Water supply');
  b.writeln();
  b.writeln('- Feed strategy: **${d.feedStrategy}**');
  b.writeln('- Target fixture residual: '
      '**${d.targetResidual.inKiloPascals.toStringAsFixed(0)} kPa**');
  if (d.pump != null) {
    b.writeln('- Pump head: **${d.pump!.head.meters.toStringAsFixed(1)} m**');
    b.writeln('- Pump motor: '
        '**${d.pump!.selectedMotor.inKiloWatts.toStringAsFixed(2)} kW**');
  }
  final pop = d.pumpOperatingPoint ?? d.pump?.operatingPoint;
  if (pop != null) {
    b.writeln('- Operating point (system × pump curve): '
        '**${pop.operatingFlow.inLitersPerSecond.toStringAsFixed(1)} L/s** '
        '@ **${pop.operatingHead.meters.toStringAsFixed(1)} m** '
        '(${(pop.flowRatio * 100).toStringAsFixed(0)} % of design flow) · '
        '${pop.stable ? 'stable match' : '**unstable / hunting match**'} '
        '_(H_sys = static + k·Q² × pump curve — // VERIFY curve coefficients)_');
    b.writeln('  - System curve: static '
        '${pop.systemStaticHead.meters.toStringAsFixed(1)} m + k·Q² · '
        'pump shutoff ${pop.equipmentShutoffHead.meters.toStringAsFixed(1)} m '
        '_(representative curve, not certified pump data — // VERIFY)_');
    b.writeln('  - NPSH: available '
        '**${pop.npshAvailable.meters.toStringAsFixed(1)} m** vs required '
        '~${pop.npshRequired.meters.toStringAsFixed(1)} m · '
        '${pop.cavitationRisk ? '**⚠ cavitation risk**' : 'adequate margin'} '
        '_(NPSH_required is a // VERIFY estimate, not a certified curve)_');
  }
  if (d.boosterHead != null) {
    b.writeln('- Downfeed: '
        '${d.gravitySufficient ? '**gravity sufficient**' : 'booster **+${d.boosterHead!.meters.toStringAsFixed(1)} m**'}');
  }
  final hwr = d.hotWaterRecirc;
  if (hwr != null) {
    b.writeln('- Hot-water recirculation: '
        '**${hwr.recircFlow.inLitersPerSecond.toStringAsFixed(2)} L/s** · '
        'loop ${hwr.loopHead.meters.toStringAsFixed(1)} m · '
        'pump ${hwr.pump.selectedMotor.inKiloWatts.toStringAsFixed(2)} kW · '
        'return ${hwr.returnTempC.toStringAsFixed(0)} °C');
    if (hwr.legionellaRisk) {
      b.writeln('  - ⚠ Modelled return temperature '
          '${hwr.returnTempC.toStringAsFixed(0)} °C is below the anti-Legionella '
          'floor (~55 °C). Reduce the loop temperature drop or add trace '
          'heating. _(general guidance — // VERIFY vs SNI)_');
    }
  }
  if (d.zones.isNotEmpty) {
    b.writeln();
    b.writeln('### Pressure zones (PRV)');
    b.writeln();
    b.writeln('| Zone (floors) | Top residual (kPa) | Bottom static (kPa) | Within limit |');
    b.writeln('|---|---:|---:|---|');
    for (var i = 0; i < d.zones.length; i++) {
      final z = d.zones[i];
      b.writeln('| ${z.zone.bottomFloorIndex + 1}–${z.zone.topFloorIndex + 1} '
          '| ${z.topResidual.inKiloPascals.toStringAsFixed(0)} '
          '| ${z.bottomStatic.inKiloPascals.toStringAsFixed(0)} '
          '| ${z.withinLimit ? 'OK' : 'OVER'} |');
    }
  }
  b.writeln();

  // ── Fire ────────────────────────────────────────────────────────────────────
  if (d.sprinkler != null ||
      d.standpipe != null ||
      d.sprinklerRemoteArea != null ||
      d.firePumpRating != null) {
    b.writeln('## Fire protection');
    b.writeln();
    final sp = d.sprinkler;
    if (sp != null) {
      b.writeln('- Sprinkler (${sp.hazard.name}): '
          '**${sp.requiredFlow.inLitersPerSecond.toStringAsFixed(1)} L/s** '
          'over ${sp.sprinklerCount} heads');
    }
    final ra = d.sprinklerRemoteArea;
    if (ra != null) {
      b.writeln('- Remote-area head (K = ${ra.kFactor.toStringAsFixed(0)}): '
          '${ra.remoteHeadFlow.inLitersPerMinute.toStringAsFixed(0)} L/min '
          '@ **${ra.remoteHeadPressure.inBar.toStringAsFixed(2)} bar** '
          '(min ${ra.minOperatingPressure.inBar.toStringAsFixed(2)} bar) · '
          'branch friction ${ra.branchLineFrictionHead.meters.toStringAsFixed(1)} m · '
          '**${ra.verdict}** '
          '_(K-factor + min head pressure — general practice, // VERIFY)_');
    }
    final st = d.standpipe;
    if (st != null) {
      b.writeln('- Standpipe: '
          '**${st.requiredFlow.inLitersPerSecond.toStringAsFixed(1)} L/s** · '
          'fire pump ${st.pumpHead.meters.toStringAsFixed(0)} m · '
          '${st.pumpShaftPower.inKiloWatts.toStringAsFixed(1)} kW · '
          'min riser ${st.minRiserDiameter.inMillimeters.round()} mm');
    }
    final fp = d.firePumpRating;
    if (fp != null) {
      final duty =
          fp.designation == PumpDesignation.duty ? 'duty' : 'standby';
      b.writeln('- Fire-pump rating curve (NFPA 20, $duty pump): '
          'rated ${fp.ratedFlow.inLitersPerSecond.toStringAsFixed(0)} L/s '
          '@ ${fp.ratedHead.meters.toStringAsFixed(0)} m · '
          'churn ${fp.churn.head.meters.toStringAsFixed(0)} m (140 %) · '
          '150 % flow @ ${fp.overload.head.meters.toStringAsFixed(0)} m (65 %) · '
          'motor **${fp.selectedMotor.inKiloWatts.toStringAsFixed(1)} kW** · '
          '**${fp.verdict}** '
          '_(curve acceptance ratios — NFPA 20 limits, // VERIFY)_');
      b.writeln('- Jockey pump: '
          '${fp.jockeyFlow.inLitersPerSecond.toStringAsFixed(2)} L/s '
          '@ ${fp.jockeyHead.meters.toStringAsFixed(0)} m '
          '(pressure maintenance)'
          '${fp.standbyRecommended ? ' · standby pump recommended' : ''}');
    }
    b.writeln();
  }

  // ── HVAC ──────────────────────────────────────────────────────────────────
  if (d.fan != null) {
    b.writeln('## HVAC (air)');
    b.writeln();
    b.writeln('- Trunk airflow: '
        '**${d.fan!.airflow.inLitersPerSecond.toStringAsFixed(0)} L/s**');
    b.writeln('- Fan total static: '
        '**${d.fan!.totalStaticPressure.pascals.toStringAsFixed(0)} Pa**');
    b.writeln('- Fan motor: '
        '**${d.fan!.selectedMotor.inKiloWatts.toStringAsFixed(2)} kW**');
    final fop = d.fanOperatingPoint ?? d.fan!.operatingPoint;
    if (fop != null) {
      b.writeln('- Operating point (system × fan curve): '
          '**${fop.operatingFlow.inLitersPerSecond.toStringAsFixed(0)} L/s** '
          '@ **${fop.operatingPressure.pascals.toStringAsFixed(0)} Pa** '
          '(${(fop.flowRatio * 100).toStringAsFixed(0)} % of design flow) · '
          '${fop.stable ? 'stable match' : '**unstable / hunting match**'} · '
          'fan shutoff ${fop.equipmentShutoffPressure.pascals.toStringAsFixed(0)} Pa '
          '_(Δp_sys = k·Q² × fan curve — // VERIFY curve coefficients)_');
    }
    if (d.returnAirflowLps > 0) {
      b.writeln('- Air balance: supply ${d.supplyAirflowLps.toStringAsFixed(0)} '
          'L/s vs return ${d.returnAirflowLps.toStringAsFixed(0)} L/s');
    }
    b.writeln();
  }

  // ── Storm / rainwater ───────────────────────────────────────────────────────
  b.writeln('## Storm / rainwater');
  b.writeln();
  b.writeln('- Design rainfall intensity: '
      '**${d.rainfallMmPerHr.toStringAsFixed(0)} mm/hr**');
  b.writeln('- Runoff coefficient C: '
      '**${d.runoffCoefficient.toStringAsFixed(2)}** '
      '_(surface/region-dependent — // VERIFY vs SNI)_');
  b.writeln();

  // ── Bill of materials ───────────────────────────────────────────────────────
  if (d.bom.isNotEmpty) {
    b.writeln('## Bill of materials');
    b.writeln();
    b.writeln('| Service | Type | Size | Length (m) | Segments |');
    b.writeln('|---|---|---|---:|---:|');
    for (final line in d.bom) {
      final size = line.service.isAir
          ? 'Ø${line.diameterMm}'
          : 'DN${line.diameterMm}';
      b.writeln('| ${_service(line.service)} '
          '| ${line.kind == EdgeKind.riser ? 'riser' : 'run'} '
          '| $size | ${line.totalLength.meters.toStringAsFixed(1)} '
          '| ${line.segmentCount} |');
    }
    b.writeln();
  }
  if (d.fittings.isNotEmpty) {
    b.writeln('### Fittings (estimated)');
    b.writeln();
    b.writeln('| Service | Fitting | Size | Count |');
    b.writeln('|---|---|---|---:|');
    for (final f in d.fittings) {
      b.writeln('| ${_service(f.service)} | ${f.type.name} '
          '| DN${f.diameterMm} | ${f.count} |');
    }
    b.writeln();
  }

  b.writeln('---');
  b.writeln('_Sizes are auto-calculated to SNI velocity/demand rules. Confirm '
      'all UNVERIFIED values and review against the applicable SNI before use._');
  return b.toString();
}
