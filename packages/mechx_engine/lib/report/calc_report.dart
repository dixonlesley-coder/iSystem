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
import '../sizing/fire_sprinkler.dart';
import '../sizing/fire_standpipe.dart';
import '../sizing/hot_water.dart';
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

  final FanDuty? fan;
  final double supplyAirflowLps;
  final double returnAirflowLps;

  final List<BomLine> bom;
  final List<FittingLine> fittings;

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
    this.fan,
    this.supplyAirflowLps = 0,
    this.returnAirflowLps = 0,
    this.bom = const [],
    this.fittings = const [],
  });
}

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

/// Render [d] as a Markdown calculation report.
String buildCalcReportMarkdown(CalcReportData d) {
  final b = StringBuffer();
  b.writeln('# MEP Calculation Report — ${d.projectName}');
  b.writeln();
  b.writeln('_Generated ${d.date} · MechX_');
  b.writeln();
  b.writeln('**Standards basis:** ${d.standardsName} (${d.standardsRevision})');
  b.writeln();

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
      final note = v.note == null ? '' : ' — ${v.note}';
      b.writeln('- **${v.citation}**: ${v.value} ${v.unit}$note');
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
  if (d.boosterHead != null) {
    b.writeln('- Downfeed: '
        '${d.gravitySufficient ? '**gravity sufficient**' : 'booster **+${d.boosterHead!.meters.toStringAsFixed(1)} m**'}');
  }
  final hwr = d.hotWaterRecirc;
  if (hwr != null) {
    b.writeln('- Hot-water recirculation: '
        '**${hwr.recircFlow.inLitersPerSecond.toStringAsFixed(2)} L/s** · '
        'loop ${hwr.loopHead.meters.toStringAsFixed(1)} m · '
        'pump ${hwr.pump.selectedMotor.inKiloWatts.toStringAsFixed(2)} kW');
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
  if (d.sprinkler != null || d.standpipe != null) {
    b.writeln('## Fire protection');
    b.writeln();
    final sp = d.sprinkler;
    if (sp != null) {
      b.writeln('- Sprinkler (${sp.hazard.name}): '
          '**${sp.requiredFlow.inLitersPerSecond.toStringAsFixed(1)} L/s** '
          'over ${sp.sprinklerCount} heads');
    }
    final st = d.standpipe;
    if (st != null) {
      b.writeln('- Standpipe: '
          '**${st.requiredFlow.inLitersPerSecond.toStringAsFixed(1)} L/s** · '
          'fire pump ${st.pumpHead.meters.toStringAsFixed(0)} m · '
          '${st.pumpShaftPower.inKiloWatts.toStringAsFixed(1)} kW · '
          'min riser ${st.minRiserDiameter.inMillimeters.round()} mm');
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
    if (d.returnAirflowLps > 0) {
      b.writeln('- Air balance: supply ${d.supplyAirflowLps.toStringAsFixed(0)} '
          'L/s vs return ${d.returnAirflowLps.toStringAsFixed(0)} L/s');
    }
    b.writeln();
  }

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
