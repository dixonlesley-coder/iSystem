/// Calculation-report generator — builds a full MEP design summary as a
/// neutral [RptBlock] list ([buildCalcReportBlocks]) rendered to Markdown
/// (engineer-friendly, plain-text, diffable) by [buildCalcReportMarkdown] or
/// typeset to PDF by `report_pdf.dart`.
///
/// Pure: takes already-computed typed results in [CalcReportData] and returns
/// blocks / a string. Zero Flutter imports — the app gathers provider values
/// into the data struct and handles file IO. Every UNVERIFIED standard value is
/// surfaced in a dedicated section so the report never hides provenance gaps
/// (§8).
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
import 'report_blocks.dart';
import 'report_strings.dart';

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

String _occupancyLabel(Occupancy o, ReportStrings s) => switch (o) {
      Occupancy.private => s(RptStringKey.occPrivate),
      Occupancy.public => s(RptStringKey.occPublic),
      Occupancy.assembly => s(RptStringKey.occAssembly),
    };

/// A short, honest label for an unverified value's provenance tier.
String _statusTag(VerificationStatus st, ReportStrings s) => switch (st) {
      VerificationStatus.sniVerbatim => '',
      VerificationStatus.secondarySource => s(RptStringKey.statusSecondary),
      VerificationStatus.notAnSniClause => s(RptStringKey.statusNotSni),
    };

String _service(ServiceType type, ReportStrings s) => switch (type) {
      ServiceType.coldWater => s(RptStringKey.svcColdWater),
      ServiceType.hotWater => s(RptStringKey.svcHotWater),
      ServiceType.drainage => s(RptStringKey.svcDrainage),
      ServiceType.vent => s(RptStringKey.svcVent),
      ServiceType.rainwater => s(RptStringKey.svcRainwater),
      ServiceType.duct => s(RptStringKey.svcSupplyAir),
      ServiceType.returnAir => s(RptStringKey.svcReturnAir),
      ServiceType.exhaust => s(RptStringKey.svcExhaust),
      ServiceType.fireSprinkler => s(RptStringKey.svcSprinkler),
      ServiceType.fireHydrant => s(RptStringKey.svcHydrant),
    };

/// The mechanical **Design Basis / Inputs & Assumptions** register as a
/// key-value block — a bulleted echo of the actual project inputs (building,
/// occupancy, feed, residual target, fire systems, rainfall) so the report
/// states the assumptions it was computed under. Shared with the unified MEP
/// report so both surfaces read the same basis. Caller adds the `##` heading.
RptKeyValue mechanicalDesignBasisBlock(CalcReportData d,
    [ReportStrings strings = const ReportStrings.en()]) {
  final fireSystems = <String>[
    if (d.sprinkler != null) strings(RptStringKey.dbFireSprinkler),
    if (d.standpipe != null) strings(RptStringKey.dbFireStandpipe),
  ];
  return RptKeyValue([
    (
      strings(RptStringKey.dbLevels),
      strings.format(RptStringKey.dbLevelsValue, {
        'count': d.building.levelCount,
        'height': d.building.totalHeight.meters.toStringAsFixed(2),
      })
    ),
    if (d.occupancy != null)
      (
        strings(RptStringKey.dbOccupancy),
        strings.format(RptStringKey.dbOccupancyValue,
            {'label': _occupancyLabel(d.occupancy!, strings)})
      ),
    (strings(RptStringKey.dbFeedStrategy), '**${d.feedStrategy}**'),
    (
      strings(RptStringKey.dbTargetResidual),
      '**${d.targetResidual.inKiloPascals.toStringAsFixed(0)} kPa**'
    ),
    (
      strings(RptStringKey.dbDesignRainfall),
      strings.format(RptStringKey.dbDesignRainfallValue, {
        'mm': d.rainfallMmPerHr.toStringAsFixed(0),
        'c': d.runoffCoefficient.toStringAsFixed(2),
      })
    ),
    (
      strings(RptStringKey.dbFireProtection),
      '**${fireSystems.isEmpty ? strings(RptStringKey.dbFireNoneModelled) : fireSystems.join(' + ')}**'
    ),
  ]);
}

/// Render the mechanical Design Basis register into [b] (legacy writer, shared
/// with the unified MEP report's Markdown path). Rows only — no trailing blank
/// line; caller writes the `##` heading.
void writeMechanicalDesignBasis(StringBuffer b, CalcReportData d,
    [ReportStrings strings = const ReportStrings.en()]) {
  for (final (key, value) in mechanicalDesignBasisBlock(d, strings).rows) {
    b.writeln('- $key $value');
  }
}

/// The Revision-history section as blocks (heading + table). Empty [revisions]
/// ⇒ an empty list, so a caller that does not track revisions gets
/// byte-identical legacy output.
List<RptBlock> revisionHistoryBlocks(List<Revision> revisions,
    [ReportStrings strings = const ReportStrings.en()]) {
  if (revisions.isEmpty) return const [];
  return [
    RptHeading(2, strings(RptStringKey.headingRevisionHistory)),
    RptTable(
      [strings(RptStringKey.tblDate), strings(RptStringKey.tblDescription)],
      [
        for (final r in revisions)
          [r.date, r.description.replaceAll('|', r'\|').replaceAll('\n', ' ')],
      ],
      mdSeparator: '|---|---|',
    ),
  ];
}

/// Render a Revision-history table into [b]. No-op when [revisions] is empty, so
/// a caller that does not track revisions gets byte-identical legacy output.
void writeRevisionHistory(StringBuffer b, List<Revision> revisions,
    [ReportStrings strings = const ReportStrings.en()]) {
  b.write(renderRptMarkdown(revisionHistoryBlocks(revisions, strings)));
}

/// Build [d] as the neutral block list — the one content model behind both the
/// Markdown render ([buildCalcReportMarkdown]) and the PDF typesetter.
List<RptBlock> buildCalcReportBlocks(CalcReportData d,
    [ReportStrings strings = const ReportStrings.en()]) {
  final blocks = <RptBlock>[
    RptHeading(1,
        strings.format(RptStringKey.calcTitle, {'name': d.projectName})),
    RptParagraph(strings.format(RptStringKey.calcGenerated, {'date': d.date})),
    RptParagraph(strings.format(RptStringKey.calcStandardsBasis,
        {'name': d.standardsName, 'rev': d.standardsRevision})),

    // ── Design basis / inputs & assumptions ───────────────────────────────────
    RptHeading(2, strings(RptStringKey.headingDesignBasis)),
    mechanicalDesignBasisBlock(d, strings),

    // ── Revision history (only when the caller tracks revisions) ──────────────
    ...revisionHistoryBlocks(d.revisions, strings),
  ];

  // ── Unverified values (provenance honesty) ─────────────────────────────────
  final unverified = d.verifyItems.where((v) => v.isUnverified).toList();
  // Tight: the legacy report runs this heading straight into its paragraph.
  blocks.add(RptHeading(2, strings(RptStringKey.headingUnverified), tight: true));
  if (unverified.isEmpty) {
    blocks.add(RptParagraph(strings(RptStringKey.unverifiedAllVerified)));
  } else {
    blocks.add(RptParagraph(strings(RptStringKey.unverifiedIntro)));
    // Print the citation plus the human-readable `note` (which carries the
    // correctly-scaled value, e.g. "≈392 kPa"). We deliberately do NOT print
    // the raw `value`+`unit` pair: typed quantities store SI base units
    // (Pressure in Pa) while `unit` is a display label (kPa), so pairing them
    // would mis-scale numbers by 1000×. Fall back to value+unit only when no
    // note is supplied (those entries are non-numeric, e.g. the demand curve).
    blocks.add(RptKeyValue([
      for (final v in unverified)
        (
          '',
          '**${v.citation}**${_statusTag(v.status, strings)} — '
              '${v.note ?? '${v.value} ${v.unit}'}'
        ),
    ]));
  }

  // ── Building ────────────────────────────────────────────────────────────────
  blocks
    ..add(RptHeading(2, strings(RptStringKey.headingBuilding)))
    ..add(RptTable(
      [
        strings(RptStringKey.tblFloor),
        strings(RptStringKey.tblHeightM),
        strings(RptStringKey.tblElevationM),
      ],
      [
        for (var i = d.building.levelCount - 1; i >= 0; i--)
          [
            d.building.floors[i].name,
            d.building.floors[i].height.meters.toStringAsFixed(2),
            d.building.elevationOf(i).meters.toStringAsFixed(2),
          ],
      ],
      mdSeparator: '|---|---:|---:|',
    ))
    ..add(RptParagraph(strings.format(RptStringKey.buildingTotalHeight, {
      'height': d.building.totalHeight.meters.toStringAsFixed(2),
      'levels': d.building.levelCount,
    })));

  // ── Water supply ──────────────────────────────────────────────────────────
  // The bullet cluster mixes conditional bullets with indented sub-bullets
  // (operating point, Legionella advisory) — a stubborn legacy construct, so
  // it rides the transitional RptMarkdown hatch verbatim.
  blocks.add(RptHeading(2, strings(RptStringKey.headingWaterSupply)));
  final ws = StringBuffer();
  ws.writeln(strings
      .format(RptStringKey.wsFeedStrategy, {'strategy': d.feedStrategy}));
  ws.writeln(strings.format(RptStringKey.wsTargetResidual,
      {'kpa': d.targetResidual.inKiloPascals.toStringAsFixed(0)}));
  if (d.pump != null) {
    ws.writeln(strings.format(RptStringKey.wsPumpHead,
        {'m': d.pump!.head.meters.toStringAsFixed(1)}));
    ws.writeln(strings.format(RptStringKey.wsPumpMotor,
        {'kw': d.pump!.selectedMotor.inKiloWatts.toStringAsFixed(2)}));
  }
  final pop = d.pumpOperatingPoint ?? d.pump?.operatingPoint;
  if (pop != null) {
    ws.writeln(strings.format(RptStringKey.wsOperatingPoint, {
      'lps': pop.operatingFlow.inLitersPerSecond.toStringAsFixed(1),
      'm': pop.operatingHead.meters.toStringAsFixed(1),
      'pct': (pop.flowRatio * 100).toStringAsFixed(0),
      'match': pop.stable
          ? strings(RptStringKey.wsMatchStable)
          : strings(RptStringKey.wsMatchUnstable),
    }));
    ws.writeln(strings.format(RptStringKey.wsSystemCurve, {
      'static': pop.systemStaticHead.meters.toStringAsFixed(1),
      'shutoff': pop.equipmentShutoffHead.meters.toStringAsFixed(1),
    }));
    ws.writeln(strings.format(RptStringKey.wsNpsh, {
      'avail': pop.npshAvailable.meters.toStringAsFixed(1),
      'req': pop.npshRequired.meters.toStringAsFixed(1),
      'cav': pop.cavitationRisk
          ? strings(RptStringKey.wsCavRisk)
          : strings(RptStringKey.wsCavAdequate),
    }));
  }
  if (d.boosterHead != null) {
    ws.writeln(strings.format(RptStringKey.wsDownfeed, {
      'status': d.gravitySufficient
          ? strings(RptStringKey.wsDownfeedGravity)
          : strings.format(RptStringKey.wsDownfeedBooster,
              {'m': d.boosterHead!.meters.toStringAsFixed(1)}),
    }));
  }
  final hwr = d.hotWaterRecirc;
  if (hwr != null) {
    ws.writeln(strings.format(RptStringKey.wsHotWaterRecirc, {
      'lps': hwr.recircFlow.inLitersPerSecond.toStringAsFixed(2),
      'loop': hwr.loopHead.meters.toStringAsFixed(1),
      'kw': hwr.pump.selectedMotor.inKiloWatts.toStringAsFixed(2),
      'c': hwr.returnTempC.toStringAsFixed(0),
    }));
    if (hwr.legionellaRisk) {
      ws.writeln(strings.format(RptStringKey.wsLegionella,
          {'c': hwr.returnTempC.toStringAsFixed(0)}));
    }
  }
  ws.writeln(); // closes the cluster (one blank line, zones or not).
  blocks.add(RptMarkdown(ws.toString()));
  if (d.zones.isNotEmpty) {
    blocks
      ..add(RptHeading(3, strings(RptStringKey.headingPressureZones)))
      ..add(RptTable(
        [
          strings(RptStringKey.tblZoneFloors),
          strings(RptStringKey.tblTopResidual),
          strings(RptStringKey.tblBottomStatic),
          strings(RptStringKey.tblWithinLimit),
        ],
        [
          for (final z in d.zones)
            [
              '${z.zone.bottomFloorIndex + 1}–${z.zone.topFloorIndex + 1}',
              z.topResidual.inKiloPascals.toStringAsFixed(0),
              z.bottomStatic.inKiloPascals.toStringAsFixed(0),
              z.withinLimit
                  ? strings(RptStringKey.verdictOk)
                  : strings(RptStringKey.verdictOver),
            ],
        ],
        mdSeparator: '|---|---:|---:|---|',
      ));
  }

  // ── Fire ────────────────────────────────────────────────────────────────────
  if (d.sprinkler != null ||
      d.standpipe != null ||
      d.sprinklerRemoteArea != null ||
      d.firePumpRating != null) {
    final sp = d.sprinkler;
    final ra = d.sprinklerRemoteArea;
    final st = d.standpipe;
    final fp = d.firePumpRating;
    blocks
      ..add(RptHeading(2, strings(RptStringKey.headingFireProtection)))
      ..add(RptKeyValue([
        if (sp != null)
          (
            strings.format(
                RptStringKey.fireSprinklerKey, {'hazard': sp.hazard.name}),
            strings.format(RptStringKey.fireSprinklerValue, {
              'lps': sp.requiredFlow.inLitersPerSecond.toStringAsFixed(1),
              'count': sp.sprinklerCount,
            })
          ),
        if (ra != null)
          (
            strings.format(RptStringKey.fireRemoteAreaKey,
                {'k': ra.kFactor.toStringAsFixed(0)}),
            strings.format(RptStringKey.fireRemoteAreaValue, {
              'lpm': ra.remoteHeadFlow.inLitersPerMinute.toStringAsFixed(0),
              'bar': ra.remoteHeadPressure.inBar.toStringAsFixed(2),
              'minbar': ra.minOperatingPressure.inBar.toStringAsFixed(2),
              'fric': ra.branchLineFrictionHead.meters.toStringAsFixed(1),
              // I7 — localized off the boolean, not the engine's English getter.
              'verdict': ra.meetsMinimumPressure
                  ? strings(RptStringKey.fireRemoteAreaVerdictOk)
                  : strings(RptStringKey.fireRemoteAreaVerdictUnder),
            })
          ),
        if (st != null)
          (
            strings(RptStringKey.fireStandpipeKey),
            strings.format(RptStringKey.fireStandpipeValue, {
              'lps': st.requiredFlow.inLitersPerSecond.toStringAsFixed(1),
              'm': st.pumpHead.meters.toStringAsFixed(0),
              'kw': st.pumpShaftPower.inKiloWatts.toStringAsFixed(1),
              'mm': st.minRiserDiameter.inMillimeters.round(),
            })
          ),
        if (fp != null)
          (
            strings.format(RptStringKey.firePumpKey, {
              'des': fp.designation == PumpDesignation.duty
                  ? strings(RptStringKey.firePumpDuty)
                  : strings(RptStringKey.firePumpStandby),
            }),
            strings.format(RptStringKey.firePumpValue, {
              'rated': fp.ratedFlow.inLitersPerSecond.toStringAsFixed(0),
              'head': fp.ratedHead.meters.toStringAsFixed(0),
              'churn': fp.churn.head.meters.toStringAsFixed(0),
              'overload': fp.overload.head.meters.toStringAsFixed(0),
              'motor': fp.selectedMotor.inKiloWatts.toStringAsFixed(1),
              // I7 — localized off the boolean, not the engine's English getter.
              'verdict': fp.oversized
                  ? strings(RptStringKey.firePumpVerdictOversized)
                  : strings(RptStringKey.firePumpVerdictWithin),
            })
          ),
        if (fp != null)
          (
            strings(RptStringKey.fireJockeyKey),
            strings.format(RptStringKey.fireJockeyValue, {
              'lps': fp.jockeyFlow.inLitersPerSecond.toStringAsFixed(2),
              'm': fp.jockeyHead.meters.toStringAsFixed(0),
              'standby': fp.standbyRecommended
                  ? strings(RptStringKey.fireJockeyStandby)
                  : '',
            })
          ),
      ]));
  }

  // ── HVAC ──────────────────────────────────────────────────────────────────
  final fan = d.fan;
  if (fan != null) {
    final fop = d.fanOperatingPoint ?? fan.operatingPoint;
    blocks
      ..add(RptHeading(2, strings(RptStringKey.headingHvac)))
      ..add(RptKeyValue([
        (
          strings(RptStringKey.hvacTrunkAirflow),
          '**${fan.airflow.inLitersPerSecond.toStringAsFixed(0)} L/s**'
        ),
        (
          strings(RptStringKey.hvacFanStatic),
          '**${fan.totalStaticPressure.pascals.toStringAsFixed(0)} Pa**'
        ),
        (
          strings(RptStringKey.hvacFanMotor),
          '**${fan.selectedMotor.inKiloWatts.toStringAsFixed(2)} kW**'
        ),
        if (fop != null)
          (
            strings(RptStringKey.hvacOperatingPoint),
            strings.format(RptStringKey.hvacOperatingPointValue, {
              'lps': fop.operatingFlow.inLitersPerSecond.toStringAsFixed(0),
              'pa': fop.operatingPressure.pascals.toStringAsFixed(0),
              'pct': (fop.flowRatio * 100).toStringAsFixed(0),
              'match': fop.stable
                  ? strings(RptStringKey.wsMatchStable)
                  : strings(RptStringKey.wsMatchUnstable),
              'shutoff':
                  fop.equipmentShutoffPressure.pascals.toStringAsFixed(0),
            })
          ),
        if (d.returnAirflowLps > 0)
          (
            strings(RptStringKey.hvacAirBalance),
            strings.format(RptStringKey.hvacAirBalanceValue, {
              'sup': d.supplyAirflowLps.toStringAsFixed(0),
              'ret': d.returnAirflowLps.toStringAsFixed(0),
            })
          ),
      ]));
  }

  // ── Storm / rainwater ───────────────────────────────────────────────────────
  blocks
    ..add(RptHeading(2, strings(RptStringKey.headingStorm)))
    ..add(RptKeyValue([
      (
        strings(RptStringKey.stormRainfall),
        '**${d.rainfallMmPerHr.toStringAsFixed(0)} mm/hr**'
      ),
      (
        strings(RptStringKey.stormRunoffC),
        strings.format(RptStringKey.stormRunoffCValue,
            {'c': d.runoffCoefficient.toStringAsFixed(2)})
      ),
    ]));

  // ── Bill of materials ───────────────────────────────────────────────────────
  if (d.bom.isNotEmpty) {
    blocks
      ..add(RptHeading(2, strings(RptStringKey.headingBom)))
      ..add(RptTable(
        [
          strings(RptStringKey.tblService),
          strings(RptStringKey.tblType),
          strings(RptStringKey.tblSize),
          strings(RptStringKey.tblLengthM),
          strings(RptStringKey.tblSegments),
        ],
        [
          for (final line in d.bom)
            [
              _service(line.service, strings),
              line.kind == EdgeKind.riser
                  ? strings(RptStringKey.bomRiser)
                  : strings(RptStringKey.bomRun),
              line.service.isAir ? 'Ø${line.diameterMm}' : 'DN${line.diameterMm}',
              line.totalLength.meters.toStringAsFixed(1),
              '${line.segmentCount}',
            ],
        ],
        mdSeparator: '|---|---|---|---:|---:|',
      ));
  }
  if (d.fittings.isNotEmpty) {
    blocks
      ..add(RptHeading(3, strings(RptStringKey.headingFittings)))
      ..add(RptTable(
        [
          strings(RptStringKey.tblService),
          strings(RptStringKey.tblFitting),
          strings(RptStringKey.tblSize),
          strings(RptStringKey.tblCount),
        ],
        [
          for (final f in d.fittings)
            [
              _service(f.service, strings),
              f.type.name,
              'DN${f.diameterMm}',
              '${f.count}'
            ],
        ],
        mdSeparator: '|---|---|---|---:|',
      ));
  }

  blocks
    ..add(const RptMarkdown('---\n'))
    ..add(RptNote(strings(RptStringKey.calcClosingNote)));
  return blocks;
}

/// Render [d] as a Markdown calculation report.
String buildCalcReportMarkdown(CalcReportData d,
        [ReportStrings strings = const ReportStrings.en()]) =>
    renderRptMarkdown(buildCalcReportBlocks(d, strings));
