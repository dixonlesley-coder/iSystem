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
import '../sizing/network_sizing.dart' show EdgeSizing;
import '../sizing/operating_point.dart';
import '../sizing/pump.dart';
import '../standards/sni.dart';
import '../units.dart';
import 'report_blocks.dart';
import 'report_strings.dart';
import 'riser_tags.dart' show elementTags;

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

  /// Per-run/riser sizing schedule (tag / size / FU / flow / velocity / length).
  /// Empty ⇒ the section is skipped (legacy output byte-identical). Built via
  /// [buildRunSchedule] by the app / dev tool from the live network + sizing.
  final List<RunScheduleRow> runSchedule;

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
    this.runSchedule = const [],
    this.occupancy,
    this.revisions = const [],
  });
}

/// One row of the per-run/riser sizing schedule (N16): the design basis behind a
/// single drawn segment's size, tabulated from its [EdgeSizing] so a reviewer can
/// check "why DN32 not DN25?" against flow + velocity from the issued set. Pure
/// data — [buildRunSchedule] reads it off the already-solved sizing.
class RunScheduleRow {
  final ServiceType service;
  final EdgeKind kind;

  /// The stable, cross-artifact element tag (N13) — the riser stack tag
  /// (`CW-R1`) for a riser, `<code>-F<floor>` for a run — matching the plan,
  /// riser single-line and BOM so a scheduled row traces to a drawn element.
  final String tag;

  /// Set-wide size notation (Ø round duct / W×H rect duct / DN pipe).
  final String sizeLabel;

  /// Accumulated fixture units carried by the segment (water UBAP / drainage
  /// DFU) when supplied; null ⇒ not applicable / not threaded (air terminals) —
  /// rendered as a dash, never guessed.
  final double? fixtureUnits;

  /// Design flow (L/s). For air services this is the airflow.
  final double flowLps;

  /// Flow velocity (m/s); <= 0 when the sizing path computes none.
  final double velocityMs;

  /// Physical length (m) from the §10 geometry.
  final double lengthM;

  const RunScheduleRow({
    required this.service,
    required this.kind,
    required this.tag,
    required this.sizeLabel,
    required this.fixtureUnits,
    required this.flowLps,
    required this.velocityMs,
    required this.lengthM,
  });
}

/// The set-wide size notation for a solved [EdgeSizing] (N18): a rectangular
/// duct as `W x H` (mm), a round air duct as `Ø<mm>`, a pipe as `DN<mm>`.
String _edgeSizeLabel(EdgeSizing s) {
  if (s.isRectangular) {
    return '${s.width!.inMillimeters.round()}x${s.height!.inMillimeters.round()}';
  }
  final mm = s.diameter.inMillimeters.round();
  return s.service.isAir ? 'Ø$mm' : 'DN$mm';
}

/// Build the per-run/riser sizing schedule from the already-solved [sizing] +
/// per-edge [edgeLengths] (§10 metres). One row per sized edge, ordered by
/// service then kind then the network's drawn edge order (deterministic). Each
/// row's tag is the SHARED stable element tag ([elementTags], N13) — the riser
/// stack tag (`CW-R1`) for a riser, `<code>-F<floor>` for a run — so a schedule
/// row reads the same identifier the plan, riser single-line and BOM carry (a
/// reviewer can find "why DN32 not DN25?" for the exact run drawn on the plan).
/// [edgeFixtureUnits] (edgeId → accumulated UBAP/DFU) fills the FU column when
/// the caller supplies it; omitted edges show no FU. Pure — tabulates existing
/// data, adds no sizing.
List<RunScheduleRow> buildRunSchedule({
  required Network net,
  required Map<String, EdgeSizing> sizing,
  required Map<String, Length> edgeLengths,
  Map<String, double> edgeFixtureUnits = const {},
}) {
  final drawnIndex = <String, int>{
    for (var i = 0; i < net.edges.length; i++) net.edges[i].id: i,
  };
  final ordered = [
    for (final e in net.edges)
      if (sizing.containsKey(e.id)) e,
  ]..sort((a, b) {
      final svc = a.service.index.compareTo(b.service.index);
      if (svc != 0) return svc;
      final knd = a.kind.index.compareTo(b.kind.index);
      if (knd != 0) return knd;
      return drawnIndex[a.id]!.compareTo(drawnIndex[b.id]!);
    });

  final tags = elementTags(net);
  final rows = <RunScheduleRow>[];
  for (final e in ordered) {
    final s = sizing[e.id]!;
    rows.add(RunScheduleRow(
      service: e.service,
      kind: e.kind,
      tag: tags[e.id] ?? '',
      sizeLabel: _edgeSizeLabel(s),
      fixtureUnits: edgeFixtureUnits[e.id],
      flowLps: s.flow.inLitersPerSecond,
      velocityMs: s.velocity.metersPerSecond,
      lengthM: edgeLengths[e.id]?.meters ?? 0.0,
    ));
  }
  return rows;
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
    // N25: the standards line is a governed statement (report_strings), not the
    // raw revision blob's "superseded" admission — {rev} is no longer echoed.
    RptParagraph(strings.format(RptStringKey.calcStandardsBasis,
        {'name': d.standardsName})),

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
          // N13: the stable element tag (riser stack tag / run floor tag) so a
          // BOM line traces to the drawn run/riser on the plan + riser + report.
          strings(RptStringKey.tblTag),
          strings(RptStringKey.tblSize),
          strings(RptStringKey.tblMaterial),
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
              line.tag,
              // N18: one size notation — Ø round duct / W×H rect / DN pipe. I5:
              // a `*` marks a size that came from a MANUAL override, resolved by
              // the footnote below.
              line.manual ? '${line.sizeLabel} *' : line.sizeLabel,
              line.material,
              line.totalLength.meters.toStringAsFixed(1),
              '${line.segmentCount}',
            ],
        ],
        mdSeparator: '|---|---|---|---|---|---:|---:|',
      ));
    // I5 — a footnote resolving the `*` marker when any BOM line is a manual
    // override, so a reviewer/auditor sees from the deliverable alone that a
    // human overrode a code-derived size. Localized inline (the shared report
    // string table is outside this change's scope); the marker is mid-sentence
    // so it renders literally in both the Markdown and PDF outputs. A paragraph
    // (trailing blank line) keeps clean spacing before the next section. Absent
    // when nothing was overridden ⇒ byte-identical.
    if (d.bom.any((l) => l.manual)) {
      blocks.add(RptParagraph(switch (strings.locale) {
        ReportLocale.en => 'Sizes marked * were manually overridden.',
        ReportLocale.id => 'Ukuran bertanda * diatur secara manual.',
      }));
    }
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
              // N18: air fittings quote Ø, piped fittings DN (no more DN-for-air).
              f.service.isAir ? 'Ø${f.diameterMm}' : 'DN${f.diameterMm}',
              '${f.count}'
            ],
        ],
        mdSeparator: '|---|---|---|---:|',
      ));
  }

  // ── Run / riser sizing schedule (per-edge basis) ────────────────────────────
  if (d.runSchedule.isNotEmpty) {
    blocks
      ..add(RptHeading(2, strings(RptStringKey.headingRunSchedule)))
      ..add(RptTable(
        [
          strings(RptStringKey.tblService),
          strings(RptStringKey.tblType),
          strings(RptStringKey.tblTag),
          strings(RptStringKey.tblSize),
          strings(RptStringKey.tblFixtureUnits),
          strings(RptStringKey.tblFlowLps),
          strings(RptStringKey.tblVelocityMs),
          strings(RptStringKey.tblLengthM),
        ],
        [
          for (final r in d.runSchedule)
            [
              _service(r.service, strings),
              r.kind == EdgeKind.riser
                  ? strings(RptStringKey.bomRiser)
                  : strings(RptStringKey.bomRun),
              r.tag,
              r.sizeLabel,
              r.fixtureUnits == null
                  ? '—'
                  : r.fixtureUnits!.toStringAsFixed(1),
              // Flow L/s is the basis only for pressurized water + air; gravity
              // drains size by DFU, so a ~0 L/s reads as a dash, not "0.00".
              r.flowLps >= 0.005 ? r.flowLps.toStringAsFixed(2) : '—',
              r.velocityMs > 0 ? r.velocityMs.toStringAsFixed(2) : '—',
              r.lengthM.toStringAsFixed(1),
            ],
        ],
        mdSeparator: '|---|---|---|---|---:|---:|---:|---:|',
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
