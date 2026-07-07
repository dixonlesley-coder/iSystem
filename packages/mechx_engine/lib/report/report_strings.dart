/// Pure Flutter-free EN / ID lookup for the REPORT BODIES — the localisation
/// surface for the four flagship calculation-report builders (`calc_report`,
/// `electrical_calc_report`, `mep_report`, `equipment_schedule`).
///
/// The engine already speaks Indonesian on the DRAWING side (KETERANGAN,
/// GRUP/DAYA, `DIAGRAM SISTEM AIR BERSIH`); this reuses that register for the
/// natural-language consulting-report phrasing (`LAPORAN PERHITUNGAN…`,
/// `Dasar Perancangan`, `Riwayat revisi`…) so the deliverables read as one
/// bilingual product.
///
/// Mirrors the app's `MechXStringsData` idiom ([call] + [format]) but is
/// deliberately engine-pure: it defines its own [ReportLocale] rather than
/// importing the Flutter app's `AppLocale`. Zero Flutter imports.
///
/// EN is the source language: every [kReportStringsEn] value is BYTE-IDENTICAL
/// to the literal it replaces, so the default `ReportStrings.en()` path keeps
/// every existing Markdown/PDF byte the characterization pins captured. Adding a
/// key here (and to BOTH tables, with the same `{placeholder}` set) is how a
/// report literal becomes translatable.
library;

/// The two languages the reports render in. Engine-local (the app maps its own
/// `AppLocale` onto this at the boundary when it wires the locale through).
enum ReportLocale { en, id }

/// Stable, symbolic keys for every localisable report-body string: section
/// headings, table headers, key labels, note leads, and the composed
/// value/caption templates. Numbers, dates, unit symbols, standards-clause
/// citations, and project/model data are NOT keyed — they stay verbatim.
enum RptStringKey {
  // ── Shared across reports ─────────────────────────────────────────────────
  headingDesignBasis,
  headingRevisionHistory,
  tblDate,
  tblDescription,
  tblService,
  tblType,
  tblSize,
  verdictOk,
  verdictOver,

  // ── Mechanical calculation report ─────────────────────────────────────────
  calcTitle, // {name}
  calcGenerated, // {date}
  calcStandardsBasis, // {name} {rev}
  headingUnverified,
  headingBuilding,
  headingWaterSupply,
  headingPressureZones,
  headingFireProtection,
  headingHvac,
  headingStorm,
  headingBom,
  headingFittings,

  // Mechanical design basis.
  dbLevels,
  dbLevelsValue, // {count} {height}
  dbOccupancy,
  dbOccupancyValue, // {label}
  dbFeedStrategy,
  dbTargetResidual,
  dbDesignRainfall,
  dbDesignRainfallValue, // {mm} {c}
  dbFireProtection,
  dbFireNoneModelled,
  dbFireSprinkler,
  dbFireStandpipe,

  // Occupancy labels.
  occPrivate,
  occPublic,
  occAssembly,

  // Provenance status tags.
  statusSecondary,
  statusNotSni,

  // Unverified section (mechanical).
  unverifiedAllVerified,
  unverifiedIntro,

  // Building table.
  tblFloor,
  tblHeightM,
  tblElevationM,
  buildingTotalHeight, // {height} {levels}

  // Water-supply cluster.
  wsFeedStrategy, // {strategy}
  wsTargetResidual, // {kpa}
  wsPumpHead, // {m}
  wsPumpMotor, // {kw}
  wsOperatingPoint, // {lps} {m} {pct} {match}
  wsMatchStable,
  wsMatchUnstable,
  wsSystemCurve, // {static} {shutoff}
  wsNpsh, // {avail} {req} {cav}
  wsCavRisk,
  wsCavAdequate,
  wsDownfeed, // {status}
  wsDownfeedGravity,
  wsDownfeedBooster, // {m}
  wsHotWaterRecirc, // {lps} {loop} {kw} {c}
  wsLegionella, // {c}

  // Pressure-zone table.
  tblZoneFloors,
  tblTopResidual,
  tblBottomStatic,
  tblWithinLimit,

  // Fire protection.
  fireSprinklerKey, // {hazard}
  fireSprinklerValue, // {lps} {count}
  fireRemoteAreaKey, // {k}
  fireRemoteAreaValue, // {lpm} {bar} {minbar} {fric} {verdict}
  // I7 — the two fire-verdict sentences used to leak the engine's hardcoded
  // English into the (otherwise localized) report; the calc-report now picks the
  // localized key off the result's boolean (meetsMinimumPressure / oversized).
  fireRemoteAreaVerdictOk,
  fireRemoteAreaVerdictUnder,
  fireStandpipeKey,
  fireStandpipeValue, // {lps} {m} {kw} {mm}
  firePumpKey, // {des}
  firePumpDuty,
  firePumpStandby,
  firePumpValue, // {rated} {head} {churn} {overload} {motor} {verdict}
  firePumpVerdictOversized,
  firePumpVerdictWithin,
  fireJockeyKey,
  fireJockeyValue, // {lps} {m} {standby}
  fireJockeyStandby,

  // HVAC.
  hvacTrunkAirflow,
  hvacFanStatic,
  hvacFanMotor,
  hvacOperatingPoint,
  hvacOperatingPointValue, // {lps} {pa} {pct} {match} {shutoff}
  hvacAirBalance,
  hvacAirBalanceValue, // {sup} {ret}

  // Storm.
  stormRainfall,
  stormRunoffC,
  stormRunoffCValue, // {c}

  // BOM + fittings tables.
  tblLengthM,
  tblSegments,
  tblMaterial,
  bomRiser,
  bomRun,
  tblFitting,
  tblCount,
  calcClosingNote,

  // Per-run/riser sizing schedule (N16).
  headingRunSchedule,
  tblFixtureUnits,
  tblFlowLps,
  tblVelocityMs,

  // Service names.
  svcColdWater,
  svcHotWater,
  svcDrainage,
  svcVent,
  svcRainwater,
  svcSupplyAir,
  svcReturnAir,
  svcExhaust,
  svcSprinkler,
  svcHydrant,

  // ── Electrical calculation report ─────────────────────────────────────────
  elecTitle, // {name}
  elecDate,
  elecStandard,

  // Electrical design basis + supply summary.
  edbSupply,
  edbConnectedLoad,
  edbConnectedLoadValue, // {w} {dw} {kva}
  edbEarthingSystem,
  edbOriginFault,
  edbOriginFaultValue, // {ka} {ct}
  edbClearingTime, // {s}
  headingSupplySummary,
  ssSystem,
  ssDiversifiedDemand,
  ssOriginDemand,

  // Panels.
  headingPanels,
  panelIncomer, // {rating} {class} {poles}
  panelMainBusbar, // {geom} {amp} {reason}
  busbarReasonWithstand,
  busbarReasonContinuous,
  panelWithstand, // {fault} {dur} {icw} {margin} {verdict}
  panelBusbarSections, // {n}
  panelNeutralBar, // {n} {oversize} {pe}
  panelNeutralOversize, // {f}
  panelDemand, // {c} {d} {a}
  panelPhaseBalance, // {l1} {l2} {l3} {imb}

  // Circuit table.
  tblWay,
  tblIb,
  tblPhase,
  tblBreaker,
  tblCable,
  tblLength,
  tblVdropCum,
  tblRcd,

  // Earthing.
  headingEarthing,
  eMainEarthing,
  eMainBonding,
  eElectrodeTarget,

  // Power one-line + warnings + unverified (electrical).
  headingPowerOneLine,
  headingSourceInterlocks,
  headingWarnings,
  headingUnverifiedElec,
  unverifiedElecIntro,

  // ── Unified MEP report ────────────────────────────────────────────────────
  mepTitle, // {name}
  mepGenerated, // {date}
  mepUnifiedIntro,
  mepMechStandard,
  mepElecStandard,
  mepHeadingMechPlumb3,
  mepHeadingElectrical,
  mepHeadingMechPlumb1,

  // Compliance summary.
  headingComplianceSummary,
  complianceReviewed, // {date} {verdict}
  compliancePass,
  complianceReviewRequired,
  complianceItemReview,
  tblCheck,
  tblVerdict,
  tblDetail,

  // ── Equipment schedule ────────────────────────────────────────────────────
  headingEquipmentSchedule,
  esProjectDate, // {name} {date}
  esNoEquipment,
  catPumps,
  catFans,
  catAirHandling,
  catPanels,
  catTransformer,
  catGenerator,
  catCapacitorBank,
  tblTag,
  tblDuty,
  tblModelSpec,
  tblQty,
  esClosingNote,
}

/// English — the source language. Every value MUST match the inline literal it
/// replaces character-for-character (the characterization pins depend on it).
const Map<RptStringKey, String> kReportStringsEn = {
  // Shared.
  RptStringKey.headingDesignBasis: 'Design basis',
  RptStringKey.headingRevisionHistory: 'Revision history',
  RptStringKey.tblDate: 'Date',
  RptStringKey.tblDescription: 'Description',
  RptStringKey.tblService: 'Service',
  RptStringKey.tblType: 'Type',
  RptStringKey.tblSize: 'Size',
  RptStringKey.verdictOk: 'OK',
  RptStringKey.verdictOver: 'OVER',

  // Mechanical.
  RptStringKey.calcTitle: 'MEP Calculation Report — {name}',
  RptStringKey.calcGenerated: '_Generated {date} · MechX_',
  // N25 — a governed standards statement, not an unqualified "superseded"
  // admission. {rev} is intentionally no longer echoed here (it carried the
  // provenance blob); per-value provenance still prints in the Unverified
  // section. Threaded via report_strings so the profile's revision data is
  // untouched.
  RptStringKey.calcStandardsBasis:
      '**Standards basis:** {name}. Designed to SNI 8153:2015; the 2025 edition '
          'has been published — differences under review.',
  // N25 — ASCII heading (was the "⚠ …" emoji heading a permit office rejects).
  RptStringKey.headingUnverified: 'Unverified values',
  RptStringKey.headingBuilding: 'Building',
  RptStringKey.headingWaterSupply: 'Water supply',
  RptStringKey.headingPressureZones: 'Pressure zones (PRV)',
  RptStringKey.headingFireProtection: 'Fire protection',
  RptStringKey.headingHvac: 'HVAC (air)',
  RptStringKey.headingStorm: 'Storm / rainwater',
  RptStringKey.headingBom: 'Bill of materials',
  RptStringKey.headingFittings: 'Fittings (estimated)',

  RptStringKey.dbLevels: 'Levels:',
  RptStringKey.dbLevelsValue: '**{count}**, total height **{height} m**',
  RptStringKey.dbOccupancy: 'Occupancy class:',
  RptStringKey.dbOccupancyValue:
      '**{label}** (UBAP fixture-unit loads / Hunter demand)',
  RptStringKey.dbFeedStrategy: 'Water feed strategy:',
  RptStringKey.dbTargetResidual: 'Target fixture residual:',
  RptStringKey.dbDesignRainfall: 'Design rainfall:',
  RptStringKey.dbDesignRainfallValue:
      '**{mm} mm/hr** · runoff C **{c}** (rational method)',
  RptStringKey.dbFireProtection: 'Fire protection:',
  RptStringKey.dbFireNoneModelled: 'none modelled',
  RptStringKey.dbFireSprinkler: 'sprinkler',
  RptStringKey.dbFireStandpipe: 'standpipe / hydrant',

  RptStringKey.occPrivate: 'Private',
  RptStringKey.occPublic: 'Public',
  RptStringKey.occAssembly: 'Assembly',

  RptStringKey.statusSecondary:
      ' _(secondary source — confirm against the SNI clause)_',
  RptStringKey.statusNotSni:
      ' _(not an SNI clause — general engineering practice)_',

  RptStringKey.unverifiedAllVerified:
      'All standard values used are verified against source text.',
  RptStringKey.unverifiedIntro:
      'The following values are placeholders / secondary-sourced and '
          'MUST be confirmed against the official standard before this report '
          'is used for a submission:',

  RptStringKey.tblFloor: 'Floor',
  RptStringKey.tblHeightM: 'Height (m)',
  RptStringKey.tblElevationM: 'Elevation (m)',
  RptStringKey.buildingTotalHeight:
      'Total height: **{height} m** over {levels} levels.',

  RptStringKey.wsFeedStrategy: '- Feed strategy: **{strategy}**',
  RptStringKey.wsTargetResidual: '- Target fixture residual: **{kpa} kPa**',
  RptStringKey.wsPumpHead: '- Pump head: **{m} m**',
  RptStringKey.wsPumpMotor: '- Pump motor: **{kw} kW**',
  RptStringKey.wsOperatingPoint:
      '- Operating point (system × pump curve): **{lps} L/s** @ **{m} m** '
          '({pct} % of design flow) · {match} '
          '_(H_sys = static + k·Q² × pump curve — // VERIFY curve coefficients)_',
  RptStringKey.wsMatchStable: 'stable match',
  RptStringKey.wsMatchUnstable: '**unstable / hunting match**',
  RptStringKey.wsSystemCurve:
      '  - System curve: static {static} m + k·Q² · pump shutoff {shutoff} m '
          '_(representative curve, not certified pump data — // VERIFY)_',
  RptStringKey.wsNpsh:
      '  - NPSH: available **{avail} m** vs required ~{req} m · {cav} '
          '_(NPSH_required is a // VERIFY estimate, not a certified curve)_',
  RptStringKey.wsCavRisk: '**⚠ cavitation risk**',
  RptStringKey.wsCavAdequate: 'adequate margin',
  RptStringKey.wsDownfeed: '- Downfeed: {status}',
  RptStringKey.wsDownfeedGravity: '**gravity sufficient**',
  RptStringKey.wsDownfeedBooster: 'booster **+{m} m**',
  RptStringKey.wsHotWaterRecirc:
      '- Hot-water recirculation: **{lps} L/s** · loop {loop} m · '
          'pump {kw} kW · return {c} °C',
  RptStringKey.wsLegionella:
      '  - ⚠ Modelled return temperature {c} °C is below the anti-Legionella '
          'floor (~55 °C). Reduce the loop temperature drop or add trace '
          'heating. _(general guidance — // VERIFY vs SNI)_',

  RptStringKey.tblZoneFloors: 'Zone (floors)',
  RptStringKey.tblTopResidual: 'Top residual (kPa)',
  RptStringKey.tblBottomStatic: 'Bottom static (kPa)',
  RptStringKey.tblWithinLimit: 'Within limit',

  RptStringKey.fireSprinklerKey: 'Sprinkler ({hazard}):',
  RptStringKey.fireSprinklerValue: '**{lps} L/s** over {count} heads',
  RptStringKey.fireRemoteAreaKey: 'Remote-area head (K = {k}):',
  RptStringKey.fireRemoteAreaValue:
      '{lpm} L/min @ **{bar} bar** (min {minbar} bar) · '
          'branch friction {fric} m · **{verdict}** '
          '_(K-factor + min head pressure — general practice, // VERIFY)_',
  RptStringKey.fireRemoteAreaVerdictOk: 'Remote head OK',
  RptStringKey.fireRemoteAreaVerdictUnder: 'Remote head under-pressure',
  RptStringKey.fireStandpipeKey: 'Standpipe:',
  RptStringKey.fireStandpipeValue:
      '**{lps} L/s** · fire pump {m} m · {kw} kW · min riser {mm} mm',
  RptStringKey.firePumpKey: 'Fire-pump rating curve (NFPA 20, {des} pump):',
  RptStringKey.firePumpDuty: 'duty',
  RptStringKey.firePumpStandby: 'standby',
  RptStringKey.firePumpValue:
      'rated {rated} L/s @ {head} m · churn {churn} m (140 %) · '
          '150 % flow @ {overload} m (65 %) · motor **{motor} kW** · '
          '**{verdict}** _(curve acceptance ratios — NFPA 20 limits, // VERIFY)_',
  RptStringKey.firePumpVerdictOversized: 'Oversized pump curve',
  RptStringKey.firePumpVerdictWithin: 'Rating curve within standard range',
  RptStringKey.fireJockeyKey: 'Jockey pump:',
  RptStringKey.fireJockeyValue:
      '{lps} L/s @ {m} m (pressure maintenance){standby}',
  RptStringKey.fireJockeyStandby: ' · standby pump recommended',

  RptStringKey.hvacTrunkAirflow: 'Trunk airflow:',
  RptStringKey.hvacFanStatic: 'Fan total static:',
  RptStringKey.hvacFanMotor: 'Fan motor:',
  RptStringKey.hvacOperatingPoint: 'Operating point (system × fan curve):',
  RptStringKey.hvacOperatingPointValue:
      '**{lps} L/s** @ **{pa} Pa** ({pct} % of design flow) · {match} · '
          'fan shutoff {shutoff} Pa '
          '_(Δp_sys = k·Q² × fan curve — // VERIFY curve coefficients)_',
  RptStringKey.hvacAirBalance: 'Air balance:',
  RptStringKey.hvacAirBalanceValue:
      'supply {sup} L/s vs return {ret} L/s',

  RptStringKey.stormRainfall: 'Design rainfall intensity:',
  RptStringKey.stormRunoffC: 'Runoff coefficient C:',
  RptStringKey.stormRunoffCValue:
      '**{c}** _(surface/region-dependent — // VERIFY vs SNI)_',

  RptStringKey.tblLengthM: 'Length (m)',
  RptStringKey.tblSegments: 'Segments',
  RptStringKey.tblMaterial: 'Material',
  RptStringKey.bomRiser: 'riser',
  RptStringKey.bomRun: 'run',
  RptStringKey.tblFitting: 'Fitting',
  RptStringKey.tblCount: 'Count',
  RptStringKey.headingRunSchedule: 'Run / riser schedule',
  RptStringKey.tblFixtureUnits: 'FU',
  RptStringKey.tblFlowLps: 'Flow (L/s)',
  RptStringKey.tblVelocityMs: 'Vel (m/s)',
  RptStringKey.calcClosingNote:
      '_Sizes are auto-calculated to SNI velocity/demand rules. Confirm '
          'all UNVERIFIED values and review against the applicable SNI before use._',

  RptStringKey.svcColdWater: 'Cold water',
  RptStringKey.svcHotWater: 'Hot water',
  RptStringKey.svcDrainage: 'Drainage',
  RptStringKey.svcVent: 'Vent',
  RptStringKey.svcRainwater: 'Rainwater',
  RptStringKey.svcSupplyAir: 'Supply air',
  RptStringKey.svcReturnAir: 'Return air',
  RptStringKey.svcExhaust: 'Exhaust',
  RptStringKey.svcSprinkler: 'Sprinkler',
  RptStringKey.svcHydrant: 'Hydrant',

  // Electrical.
  RptStringKey.elecTitle: 'Electrical calculation report — {name}',
  RptStringKey.elecDate: 'Date:',
  RptStringKey.elecStandard: 'Standard:',
  RptStringKey.edbSupply: 'Supply:',
  RptStringKey.edbConnectedLoad: 'Connected load:',
  RptStringKey.edbConnectedLoadValue:
      '**{w} W** · diversified demand **{dw} W** ({kva} kVA)',
  RptStringKey.edbEarthingSystem: 'Earthing system:',
  RptStringKey.edbOriginFault: 'Origin fault level:',
  RptStringKey.edbOriginFaultValue:
      '**{ka} kA**{ct} (busbar short-circuit-withstand basis)',
  RptStringKey.edbClearingTime: ' · clearing time **{s} s**',
  RptStringKey.headingSupplySummary: 'Supply summary',
  RptStringKey.ssSystem: 'System:',
  RptStringKey.ssDiversifiedDemand: 'Diversified demand:',
  RptStringKey.ssOriginDemand: 'Origin diversified demand:',

  RptStringKey.headingPanels: 'Panels',
  RptStringKey.panelIncomer: '- Incomer: {rating} {class} {poles}P',
  RptStringKey.panelMainBusbar:
      '- Main busbar: {geom}, ampacity {amp} — governed by {reason}',
  RptStringKey.busbarReasonWithstand: 'short-circuit withstand',
  RptStringKey.busbarReasonContinuous: 'continuous current',
  RptStringKey.panelWithstand:
      '  - Withstand: fault {fault} kA for {dur} s, Icw {icw} kA, '
          'margin {margin} kA ({verdict})',
  RptStringKey.panelBusbarSections:
      '- Busbar sections: {n} (radial split, IEC 61439-1)',
  RptStringKey.panelNeutralBar:
      '- Neutral bar: {n} mm²{oversize}, PE bar: {pe} mm²',
  RptStringKey.panelNeutralOversize: ' (×{f} triplen oversize)',
  RptStringKey.panelDemand:
      '- Demand: connected {c} W, diversified {d} W, {a}',
  RptStringKey.panelPhaseBalance:
      '- Phase balance: L1 {l1} A · L2 {l2} A · L3 {l3} A (imbalance {imb} %)',

  RptStringKey.tblWay: 'Way',
  RptStringKey.tblIb: 'Ib',
  RptStringKey.tblPhase: 'Phase',
  RptStringKey.tblBreaker: 'Breaker',
  RptStringKey.tblCable: 'Cable',
  RptStringKey.tblLength: 'Length',
  RptStringKey.tblVdropCum: 'Vdrop (cum)',
  RptStringKey.tblRcd: 'RCD',

  RptStringKey.headingEarthing: 'Earthing',
  RptStringKey.eMainEarthing: 'Main earthing conductor:',
  RptStringKey.eMainBonding: 'Main bonding conductor:',
  RptStringKey.eElectrodeTarget: 'Electrode resistance target:',

  RptStringKey.headingPowerOneLine: 'Power one-line',
  RptStringKey.headingSourceInterlocks: 'Source interlocks',
  RptStringKey.headingWarnings: 'Warnings',
  RptStringKey.headingUnverifiedElec: 'Unverified values',
  RptStringKey.unverifiedElecIntro:
      'These values are not yet confirmed verbatim against the official '
          'PUIL/SNI clause and should be verified before construction:',

  // Unified MEP.
  RptStringKey.mepTitle: 'MEP Building-Services Report — {name}',
  RptStringKey.mepGenerated: '_Generated {date} · MechX (iSystem)_',
  RptStringKey.mepUnifiedIntro:
      'Unified mechanical · electrical · plumbing report.',
  RptStringKey.mepMechStandard: 'Mechanical / plumbing standard:',
  RptStringKey.mepElecStandard: 'Electrical standard:',
  RptStringKey.mepHeadingMechPlumb3: 'Mechanical / plumbing',
  RptStringKey.mepHeadingElectrical: 'Electrical',
  RptStringKey.mepHeadingMechPlumb1: 'Mechanical & plumbing',

  RptStringKey.headingComplianceSummary: 'Compliance summary',
  RptStringKey.complianceReviewed:
      '_Reviewed {date} — overall: **{verdict}**_',
  RptStringKey.compliancePass: 'PASS',
  RptStringKey.complianceReviewRequired: 'REVIEW REQUIRED',
  RptStringKey.complianceItemReview: 'REVIEW',
  RptStringKey.tblCheck: 'Check',
  RptStringKey.tblVerdict: 'Verdict',
  RptStringKey.tblDetail: 'Detail',

  // Equipment schedule.
  RptStringKey.headingEquipmentSchedule: 'Equipment schedule',
  RptStringKey.esProjectDate: '**Project:** {name}  \n**Date:** {date}\n\n',
  RptStringKey.esNoEquipment: '_(no equipment scheduled)_',
  RptStringKey.catPumps: 'Pumps',
  RptStringKey.catFans: 'Fans',
  RptStringKey.catAirHandling: 'Air-handling (AHU / FCU / AC)',
  RptStringKey.catPanels: 'Electrical panels',
  RptStringKey.catTransformer: 'Transformer',
  RptStringKey.catGenerator: 'Standby generator',
  RptStringKey.catCapacitorBank: 'Capacitor bank',
  RptStringKey.tblTag: 'Tag',
  RptStringKey.tblDuty: 'Duty',
  RptStringKey.tblModelSpec: 'Model / spec',
  RptStringKey.tblQty: 'Qty',
  RptStringKey.esClosingNote:
      '_Model / spec is a placeholder for the engineer to complete from '
          'the selected manufacturer datasheet; iSystem sizes the duty, not the '
          'catalogue model._',
};

/// Bahasa Indonesia — natural consulting-report phrasing, reusing the
/// drawing-side register (KETERANGAN / DIAGRAM SISTEM AIR BERSIH). Numbers,
/// dates, unit symbols and standards-clause citations stay verbatim. Any missing
/// key falls back to [kReportStringsEn] at lookup time.
const Map<RptStringKey, String> kReportStringsId = {
  // Shared.
  RptStringKey.headingDesignBasis: 'Dasar Perancangan',
  RptStringKey.headingRevisionHistory: 'Riwayat revisi',
  RptStringKey.tblDate: 'Tanggal',
  RptStringKey.tblDescription: 'Uraian',
  RptStringKey.tblService: 'Layanan',
  RptStringKey.tblType: 'Jenis',
  RptStringKey.tblSize: 'Ukuran',
  RptStringKey.verdictOk: 'OK',
  RptStringKey.verdictOver: 'LEBIH',

  // Mechanical.
  RptStringKey.calcTitle: 'LAPORAN PERHITUNGAN MEP — {name}',
  RptStringKey.calcGenerated: '_Dibuat {date} · MechX_',
  RptStringKey.calcStandardsBasis:
      '**Dasar standar:** {name}. Dirancang mengacu SNI 8153:2015; edisi 2025 '
          'telah terbit — perbedaan sedang ditinjau.',
  RptStringKey.headingUnverified: 'Nilai belum terverifikasi',
  RptStringKey.headingBuilding: 'Bangunan',
  RptStringKey.headingWaterSupply: 'Pasokan air',
  RptStringKey.headingPressureZones: 'Zona tekanan (PRV)',
  RptStringKey.headingFireProtection: 'Proteksi kebakaran',
  RptStringKey.headingHvac: 'HVAC (udara)',
  RptStringKey.headingStorm: 'Air hujan',
  RptStringKey.headingBom: 'Daftar material',
  RptStringKey.headingFittings: 'Sambungan (perkiraan)',

  RptStringKey.dbLevels: 'Lantai:',
  RptStringKey.dbLevelsValue: '**{count}**, tinggi total **{height} m**',
  RptStringKey.dbOccupancy: 'Kelas hunian:',
  RptStringKey.dbOccupancyValue:
      '**{label}** (beban unit fikstur UBAP / permintaan Hunter)',
  RptStringKey.dbFeedStrategy: 'Strategi pasokan air:',
  RptStringKey.dbTargetResidual: 'Target tekanan sisa fikstur:',
  RptStringKey.dbDesignRainfall: 'Curah hujan desain:',
  RptStringKey.dbDesignRainfallValue:
      '**{mm} mm/hr** · runoff C **{c}** (metode rasional)',
  RptStringKey.dbFireProtection: 'Proteksi kebakaran:',
  RptStringKey.dbFireNoneModelled: 'tidak dimodelkan',
  RptStringKey.dbFireSprinkler: 'sprinkler',
  RptStringKey.dbFireStandpipe: 'pipa tegak / hidran',

  RptStringKey.occPrivate: 'Privat',
  RptStringKey.occPublic: 'Publik',
  RptStringKey.occAssembly: 'Pertemuan',

  RptStringKey.statusSecondary:
      ' _(sumber sekunder — konfirmasi terhadap pasal SNI)_',
  RptStringKey.statusNotSni:
      ' _(bukan pasal SNI — praktik rekayasa umum)_',

  RptStringKey.unverifiedAllVerified:
      'Semua nilai standar yang digunakan telah diverifikasi terhadap teks '
          'sumber.',
  RptStringKey.unverifiedIntro:
      'Nilai berikut bersifat sementara / bersumber sekunder dan HARUS '
          'dikonfirmasi terhadap standar resmi sebelum laporan ini digunakan '
          'untuk pengajuan:',

  RptStringKey.tblFloor: 'Lantai',
  RptStringKey.tblHeightM: 'Tinggi (m)',
  RptStringKey.tblElevationM: 'Elevasi (m)',
  RptStringKey.buildingTotalHeight:
      'Tinggi total: **{height} m** untuk {levels} lantai.',

  RptStringKey.wsFeedStrategy: '- Strategi pasokan: **{strategy}**',
  RptStringKey.wsTargetResidual: '- Target tekanan sisa fikstur: **{kpa} kPa**',
  RptStringKey.wsPumpHead: '- Head pompa: **{m} m**',
  RptStringKey.wsPumpMotor: '- Motor pompa: **{kw} kW**',
  RptStringKey.wsOperatingPoint:
      '- Titik operasi (sistem × kurva pompa): **{lps} L/s** @ **{m} m** '
          '({pct} % dari aliran desain) · {match} '
          '_(H_sys = statis + k·Q² × kurva pompa — // VERIFY koefisien kurva)_',
  RptStringKey.wsMatchStable: 'kecocokan stabil',
  RptStringKey.wsMatchUnstable: '**kecocokan tidak stabil / berayun**',
  RptStringKey.wsSystemCurve:
      '  - Kurva sistem: statis {static} m + k·Q² · shutoff pompa {shutoff} m '
          '_(kurva representatif, bukan data pompa tersertifikasi — // VERIFY)_',
  RptStringKey.wsNpsh:
      '  - NPSH: tersedia **{avail} m** vs dibutuhkan ~{req} m · {cav} '
          '_(NPSH_required adalah perkiraan // VERIFY, bukan kurva '
          'tersertifikasi)_',
  RptStringKey.wsCavRisk: '**⚠ risiko kavitasi**',
  RptStringKey.wsCavAdequate: 'margin memadai',
  RptStringKey.wsDownfeed: '- Aliran turun: {status}',
  RptStringKey.wsDownfeedGravity: '**gravitasi mencukupi**',
  RptStringKey.wsDownfeedBooster: 'booster **+{m} m**',
  RptStringKey.wsHotWaterRecirc:
      '- Resirkulasi air panas: **{lps} L/s** · loop {loop} m · '
          'pompa {kw} kW · balik {c} °C',
  RptStringKey.wsLegionella:
      '  - ⚠ Suhu balik termodelkan {c} °C berada di bawah ambang '
          'anti-Legionella (~55 °C). Kurangi penurunan suhu loop atau tambahkan '
          'pemanas jejak. _(panduan umum — // VERIFY terhadap SNI)_',

  RptStringKey.tblZoneFloors: 'Zona (lantai)',
  RptStringKey.tblTopResidual: 'Sisa atas (kPa)',
  RptStringKey.tblBottomStatic: 'Statis bawah (kPa)',
  RptStringKey.tblWithinLimit: 'Dalam batas',

  RptStringKey.fireSprinklerKey: 'Sprinkler ({hazard}):',
  RptStringKey.fireSprinklerValue: '**{lps} L/s** untuk {count} kepala',
  RptStringKey.fireRemoteAreaKey: 'Head area terjauh (K = {k}):',
  RptStringKey.fireRemoteAreaValue:
      '{lpm} L/min @ **{bar} bar** (min {minbar} bar) · '
          'gesekan cabang {fric} m · **{verdict}** '
          '_(K-factor + tekanan head min — praktik umum, // VERIFY)_',
  RptStringKey.fireRemoteAreaVerdictOk: 'Head terjauh OK',
  RptStringKey.fireRemoteAreaVerdictUnder: 'Head terjauh kurang tekanan',
  RptStringKey.fireStandpipeKey: 'Pipa tegak:',
  RptStringKey.fireStandpipeValue:
      '**{lps} L/s** · pompa pemadam {m} m · {kw} kW · riser min {mm} mm',
  RptStringKey.firePumpKey: 'Kurva rating pompa pemadam (NFPA 20, pompa {des}):',
  RptStringKey.firePumpDuty: 'utama',
  RptStringKey.firePumpStandby: 'cadangan',
  RptStringKey.firePumpValue:
      'rated {rated} L/s @ {head} m · churn {churn} m (140 %) · '
          'aliran 150 % @ {overload} m (65 %) · motor **{motor} kW** · '
          '**{verdict}** _(rasio penerimaan kurva — batas NFPA 20, // VERIFY)_',
  RptStringKey.firePumpVerdictOversized: 'Kurva pompa kebesaran',
  RptStringKey.firePumpVerdictWithin: 'Kurva rating dalam rentang standar',
  RptStringKey.fireJockeyKey: 'Pompa jockey:',
  RptStringKey.fireJockeyValue:
      '{lps} L/s @ {m} m (pemeliharaan tekanan){standby}',
  RptStringKey.fireJockeyStandby: ' · disarankan pompa cadangan',

  RptStringKey.hvacTrunkAirflow: 'Aliran udara utama:',
  RptStringKey.hvacFanStatic: 'Statis total kipas:',
  RptStringKey.hvacFanMotor: 'Motor kipas:',
  RptStringKey.hvacOperatingPoint: 'Titik operasi (sistem × kurva kipas):',
  RptStringKey.hvacOperatingPointValue:
      '**{lps} L/s** @ **{pa} Pa** ({pct} % dari aliran desain) · {match} · '
          'shutoff kipas {shutoff} Pa '
          '_(Δp_sys = k·Q² × kurva kipas — // VERIFY koefisien kurva)_',
  RptStringKey.hvacAirBalance: 'Keseimbangan udara:',
  RptStringKey.hvacAirBalanceValue:
      'suplai {sup} L/s vs balik {ret} L/s',

  RptStringKey.stormRainfall: 'Intensitas curah hujan desain:',
  RptStringKey.stormRunoffC: 'Koefisien limpasan C:',
  RptStringKey.stormRunoffCValue:
      '**{c}** _(bergantung permukaan/wilayah — // VERIFY terhadap SNI)_',

  RptStringKey.tblLengthM: 'Panjang (m)',
  RptStringKey.tblSegments: 'Segmen',
  RptStringKey.tblMaterial: 'Material',
  RptStringKey.bomRiser: 'riser',
  RptStringKey.bomRun: 'saluran',
  RptStringKey.tblFitting: 'Sambungan',
  RptStringKey.tblCount: 'Jumlah',
  RptStringKey.headingRunSchedule: 'Jadwal saluran / riser',
  RptStringKey.tblFixtureUnits: 'UBAP',
  RptStringKey.tblFlowLps: 'Aliran (L/s)',
  RptStringKey.tblVelocityMs: 'Kecepatan (m/s)',
  RptStringKey.calcClosingNote:
      '_Ukuran dihitung otomatis sesuai aturan kecepatan/permintaan SNI. '
          'Konfirmasi semua nilai BELUM TERVERIFIKASI dan tinjau terhadap SNI '
          'yang berlaku sebelum digunakan._',

  RptStringKey.svcColdWater: 'Air dingin',
  RptStringKey.svcHotWater: 'Air panas',
  RptStringKey.svcDrainage: 'Drainase',
  RptStringKey.svcVent: 'Vent',
  RptStringKey.svcRainwater: 'Air hujan',
  RptStringKey.svcSupplyAir: 'Udara suplai',
  RptStringKey.svcReturnAir: 'Udara balik',
  RptStringKey.svcExhaust: 'Exhaust',
  RptStringKey.svcSprinkler: 'Sprinkler',
  RptStringKey.svcHydrant: 'Hidran',

  // Electrical.
  RptStringKey.elecTitle: 'Laporan perhitungan kelistrikan — {name}',
  RptStringKey.elecDate: 'Tanggal:',
  RptStringKey.elecStandard: 'Standar:',
  RptStringKey.edbSupply: 'Suplai:',
  RptStringKey.edbConnectedLoad: 'Beban terpasang:',
  RptStringKey.edbConnectedLoadValue:
      '**{w} W** · permintaan terdiversifikasi **{dw} W** ({kva} kVA)',
  RptStringKey.edbEarthingSystem: 'Sistem pembumian:',
  RptStringKey.edbOriginFault: 'Tingkat gangguan sumber:',
  RptStringKey.edbOriginFaultValue:
      '**{ka} kA**{ct} (dasar ketahanan hubung-singkat busbar)',
  RptStringKey.edbClearingTime: ' · waktu pemutusan **{s} s**',
  RptStringKey.headingSupplySummary: 'Ringkasan pasokan',
  RptStringKey.ssSystem: 'Sistem:',
  RptStringKey.ssDiversifiedDemand: 'Permintaan terdiversifikasi:',
  RptStringKey.ssOriginDemand: 'Permintaan terdiversifikasi sumber:',

  RptStringKey.headingPanels: 'Panel',
  RptStringKey.panelIncomer: '- Incomer: {rating} {class} {poles}P',
  RptStringKey.panelMainBusbar:
      '- Busbar utama: {geom}, ampacity {amp} — diatur oleh {reason}',
  RptStringKey.busbarReasonWithstand: 'ketahanan hubung-singkat',
  RptStringKey.busbarReasonContinuous: 'arus kontinu',
  RptStringKey.panelWithstand:
      '  - Ketahanan: gangguan {fault} kA selama {dur} s, Icw {icw} kA, '
          'margin {margin} kA ({verdict})',
  RptStringKey.panelBusbarSections:
      '- Seksi busbar: {n} (pembagian radial, IEC 61439-1)',
  RptStringKey.panelNeutralBar:
      '- Bar netral: {n} mm²{oversize}, bar PE: {pe} mm²',
  RptStringKey.panelNeutralOversize: ' (×{f} pembesaran triplen)',
  RptStringKey.panelDemand:
      '- Permintaan: terpasang {c} W, terdiversifikasi {d} W, {a}',
  RptStringKey.panelPhaseBalance:
      '- Keseimbangan fasa: L1 {l1} A · L2 {l2} A · L3 {l3} A '
          '(ketidakseimbangan {imb} %)',

  RptStringKey.tblWay: 'Jalur',
  RptStringKey.tblIb: 'Ib',
  RptStringKey.tblPhase: 'Fasa',
  RptStringKey.tblBreaker: 'Pemutus',
  RptStringKey.tblCable: 'Kabel',
  RptStringKey.tblLength: 'Panjang',
  RptStringKey.tblVdropCum: 'Drop V (kum)',
  RptStringKey.tblRcd: 'RCD',

  RptStringKey.headingEarthing: 'Pembumian',
  RptStringKey.eMainEarthing: 'Konduktor pembumian utama:',
  RptStringKey.eMainBonding: 'Konduktor ikatan utama:',
  RptStringKey.eElectrodeTarget: 'Target resistansi elektroda:',

  RptStringKey.headingPowerOneLine: 'Diagram daya satu-garis',
  RptStringKey.headingSourceInterlocks: 'Interlock sumber',
  RptStringKey.headingWarnings: 'Peringatan',
  RptStringKey.headingUnverifiedElec: 'Nilai belum terverifikasi',
  RptStringKey.unverifiedElecIntro:
      'Nilai-nilai ini belum dikonfirmasi verbatim terhadap pasal PUIL/SNI '
          'resmi dan harus diverifikasi sebelum konstruksi:',

  // Unified MEP.
  RptStringKey.mepTitle: 'Laporan Layanan Bangunan MEP — {name}',
  RptStringKey.mepGenerated: '_Dibuat {date} · MechX (iSystem)_',
  RptStringKey.mepUnifiedIntro:
      'Laporan terpadu mekanikal · elektrikal · plambing.',
  RptStringKey.mepMechStandard: 'Standar mekanikal / plambing:',
  RptStringKey.mepElecStandard: 'Standar elektrikal:',
  RptStringKey.mepHeadingMechPlumb3: 'Mekanikal / plambing',
  RptStringKey.mepHeadingElectrical: 'Elektrikal',
  RptStringKey.mepHeadingMechPlumb1: 'Mekanikal & plambing',

  RptStringKey.headingComplianceSummary: 'Ringkasan kepatuhan',
  RptStringKey.complianceReviewed:
      '_Ditinjau {date} — keseluruhan: **{verdict}**_',
  RptStringKey.compliancePass: 'LULUS',
  RptStringKey.complianceReviewRequired: 'PERLU TINJAUAN',
  RptStringKey.complianceItemReview: 'TINJAU',
  RptStringKey.tblCheck: 'Pemeriksaan',
  RptStringKey.tblVerdict: 'Hasil',
  RptStringKey.tblDetail: 'Detail',

  // Equipment schedule.
  RptStringKey.headingEquipmentSchedule: 'Jadwal peralatan',
  RptStringKey.esProjectDate: '**Proyek:** {name}  \n**Tanggal:** {date}\n\n',
  RptStringKey.esNoEquipment: '_(tidak ada peralatan dijadwalkan)_',
  RptStringKey.catPumps: 'Pompa',
  RptStringKey.catFans: 'Kipas',
  RptStringKey.catAirHandling: 'Penanganan udara (AHU / FCU / AC)',
  RptStringKey.catPanels: 'Panel listrik',
  RptStringKey.catTransformer: 'Transformator',
  RptStringKey.catGenerator: 'Genset cadangan',
  RptStringKey.catCapacitorBank: 'Bank kapasitor',
  RptStringKey.tblTag: 'Tag',
  RptStringKey.tblDuty: 'Kapasitas',
  RptStringKey.tblModelSpec: 'Model / spesifikasi',
  RptStringKey.tblQty: 'Jml',
  RptStringKey.esClosingNote:
      '_Model / spesifikasi adalah tempat isian bagi insinyur untuk dilengkapi '
          'dari lembar data produsen terpilih; iSystem mengukur kapasitas, bukan '
          'model katalog._',
};

/// Resolves a [RptStringKey] against a [ReportLocale], mirroring the app's
/// `MechXStringsData` idiom ([call] + [format]) but engine-pure. Any key missing
/// from the active locale's table falls back to English so a report never
/// renders a blank. The default `ReportStrings.en()` keeps every existing byte.
class ReportStrings {
  final ReportLocale locale;
  const ReportStrings(this.locale);
  const ReportStrings.en() : locale = ReportLocale.en;
  const ReportStrings.id() : locale = ReportLocale.id;

  Map<RptStringKey, String> get _map => switch (locale) {
        ReportLocale.en => kReportStringsEn,
        ReportLocale.id => kReportStringsId,
      };

  /// Resolve [key]: the active locale's value, or the English fallback.
  String call(RptStringKey key) => _map[key] ?? kReportStringsEn[key]!;

  /// Resolve a parameterized [key] whose template carries `{name}`
  /// placeholders, substituting each entry of [params]. Unknown placeholders
  /// are left intact and unused params ignored, so a template + call never
  /// throws. Falls back to English like [call] — keep the `{name}` placeholders
  /// identical across the EN and ID templates so both substitute correctly.
  String format(RptStringKey key, Map<String, Object?> params) {
    var out = _map[key] ?? kReportStringsEn[key]!;
    params.forEach((k, v) => out = out.replaceAll('{$k}', '$v'));
    return out;
  }
}
