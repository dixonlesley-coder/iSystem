/// A8 advanced-study BUNDLING layer — the single pure, derived pass that runs
/// every landed advanced electrical module over an already-solved system and
/// collects their results into one [AdvancedStudy] record.
///
/// This is ADDITIVE post-processing: it reads the A4 [ElectricalSystemResult]
/// (constructed only by `compute.dart`) plus the [ElectricalProject] input, and
/// calls each advanced module
/// (`fault` / `supply_design` / `power_factor` / `containment` / `enclosure` /
/// `harmonics` / `arc_flash` / `metering` / `spd` / `lightning` / `electrode` /
/// `sources` → `power_oneline` / `control/starter` / `bom`). It constructs none
/// of the A4 result records and mutates neither the project nor the system.
///
/// The two sizing-MUTATING folds now live in `computePanel`/`computeSystem`
/// (`compute.dart`), NOT here:
///   - FOLD 1 (busbar short-circuit withstand) floors each panel's busbar at the
///     cross-section the prospective fault's Icw demands. It is opt-in: pass
///     `computeSystem(..., originFaultLevel: …)` to propagate Isc and apply it.
///   - FOLD 2 (harmonics triplen-neutral oversize) grows the neutral bar from
///     the panel's single-phase non-linear share; it is always-on but
///     self-guarding (a linear panel keeps a full-size neutral).
/// This study still REPORTS the fault / harmonics estimates (for the report +
/// UI), but no longer needs to re-derive the conductor sizes.
///
/// Provenance honesty: every sub-result's `verifyItems` is aggregated into
/// [AdvancedStudy.verifyItems] (de-duplicated, order-preserving) so the calc
/// report's "unverified values" surface survives this layer.
///
/// Pure + deterministic — zero Flutter imports.
library;

import 'dart:math' as math;

import '../standards/puil.dart' show BreakerClass, ElectricalStandardsProfile;
import '../units.dart';
import 'advanced_bom.dart' show advancedBomLines;
import 'arc_flash.dart' show ArcFlashResult, estimateArcFlash;
import 'bom.dart' show Bom, buildBom, faultSpecifiedKa;
import 'compute.dart'
    show
        circuitIsThreePhase,
        kThreePhaseServiceLineVoltageV;
import 'containment.dart'
    show ConduitSpec, ContainmentResult, containmentFor, effectiveInstallMethod;
import 'control/motor_flc.dart' show motorFlc, motorFlc1ph;
import 'control/starter.dart'
    show
        ControlAssembly,
        StarterType,
        applyStarterTemplate,
        effectiveStarterType;
import 'control/starting.dart' show startingAnalysis;
import 'diversity_library.dart' show diversityLibraryVerifyItems;
import 'earthing.dart'
    show EarthingSystem, kTtTouchVoltageLimitV, ttRcdTouchVoltageOk;
import 'electrode.dart' show ElectrodeDesign, designElectrode;
import 'enclosure.dart'
    show
        EnclosureResult,
        Ventilation,
        estimateEnclosure,
        maxInternalTempRiseK,
        switchgearLossW;
import 'fault.dart'
    show
        FaultStudyResult,
        defaultLvUtilityFaultKa,
        estimatedServiceFaultLevelA,
        faultStudy,
        maxEstimatedServiceFaultKa,
        onSiteSourceFaultA,
        serviceFaultEstimateVerifyItems,
        solvedRunLengthM;
import 'genset_backup.dart'
    show
        gensetBackedPanelIds,
        gensetBackupDemandVa,
        gensetBackupDemandW,
        gensetBackupWarnings,
        worstPhaseDemandVa;
import 'harmonics.dart' show HarmonicsResult, ThdBand, estimateHarmonics;
import 'lightning.dart' show LightningRisk, assessLightning, collectionArea;
import 'load_kind.dart' show LoadKind;
import 'metering.dart' show MeteringSpec, meterFor;
import 'model.dart'
    show
        ElectricalCircuit,
        ElectricalPanel,
        ElectricalProject,
        ElectricalSystem,
        SupplyKind;
import 'panel_results.dart'
    show
        ElectricalCircuitResult,
        ElectricalPanelResult,
        ElectricalSystemResult,
        ElectricalWarning,
        WarningSeverity;
import 'power_factor.dart'
    show PowerFactorResult, isDriveFedCircuit, powerFactorCorrection;
import 'power_oneline.dart' show PowerOneLine, buildPowerOneLine;
import 'sources.dart' show GensetMotor, sizeGenerator;
import 'spd.dart' show SpdRecommendation, recommendSpd;
import 'supply_design.dart'
    show
        SupplyDesign,
        SupplyLevel,
        declaredServiceTransformer,
        determineSupply,
        isDeclaredMvService,
        recommendedDaya,
        serviceSections;

export 'genset_backup.dart' show gensetBackedPanelIds;

/// A representative MCB clearing (arcing) time for the arc-flash screen (s) —
/// fast magnetic/thermal trip on a miniature device.
const double _mcbClearingTimeS = 0.05;

/// A representative MCCB clearing (arcing) time for the arc-flash screen (s) —
/// a moulded-case device clears more slowly than an MCB.
const double _mccbClearingTimeS = 0.2;

/// A representative ACB clearing (arcing) time for the arc-flash screen (s) —
/// an air circuit breaker on an LV main normally carries a short-time delay
/// for selectivity, so it clears SLOWER than an MCCB (Round 23 r2: an ACB had
/// fallen through to the 0.05 s MCB time, under-estimating the incident energy
/// on the largest board ~4×). A safety quantity — never clamp it down.
// VERIFY (notAnSniClause): IEEE 1584 practice ≈ 0.3–0.5 s for an LV power
// breaker with short-time delay.
const double _acbClearingTimeS = 0.5;

/// The arc-flash clearing time for a breaker class (s) — exhaustive over
/// [BreakerClass] so a new frame class can never silently fall to the MCB time.
double arcFlashClearingTimeS(BreakerClass c) => switch (c) {
      BreakerClass.mcb => _mcbClearingTimeS,
      BreakerClass.mccb => _mccbClearingTimeS,
      BreakerClass.acb => _acbClearingTimeS,
    };

/// A small ambient / quiescent enclosure heat allowance (W) — wiring,
/// terminals, indicator lamps — added to the summed control-device losses AND
/// the load-dependent switchgear I²R ([switchgearLossW]) when no explicit
/// `panel.heatW` is given. Engineering estimate; reported via the enclosure
/// pass's own verifyItems.
const double _baseEnclosureHeatW = 25;

/// The bundled advanced-study result. Each map is keyed by panel id (or circuit
/// id, for the per-circuit passes); a nullable entry means the pass had nothing
/// to report for that key (e.g. a panel with no non-linear load → null harmonics).
class AdvancedStudy {
  /// Protection / fault study (Isc, breaking capacity, Zs/ADS, selectivity).
  final FaultStudyResult fault;

  /// Project supply arrangement (LV direct vs MV + transformer).
  final SupplyDesign supply;

  /// Recommended PLN connected power "daya tersambung" (VA) — the smallest
  /// standard step AT OR ABOVE the demand; null when the demand exceeds the
  /// LV catalogue (an MV service — no LV daya exists).
  final double? recommendedDayaVa;

  /// True when [recommendedDayaVa] is a 3-phase step (a single-phase project
  /// whose demand exceeds the 1φ ceiling is recommended a 3φ service).
  final bool recommendedDayaThreePhase;

  /// Power-factor / capacitor-bank correction.
  final PowerFactorResult powerFactor;

  /// Control assemblies keyed by motor/pump circuit id (only circuits that
  /// carry a [StarterType]).
  final Map<String, ControlAssembly> controlAssemblies;

  /// Per-panel harmonics estimate (null when the panel has no non-linear load).
  final Map<String, HarmonicsResult?> harmonics;

  /// Per-panel arc-flash screen (null when there is no meaningful fault).
  final Map<String, ArcFlashResult?> arcFlash;

  /// Per-panel containment (conduit fill + cable tray).
  final Map<String, ContainmentResult> containment;

  /// Per-panel enclosure estimate.
  final Map<String, EnclosureResult> enclosure;

  /// Per-panel revenue / sub-metering selection.
  final Map<String, MeteringSpec> metering;

  /// Per-panel SPD recommendation.
  final Map<String, SpdRecommendation> spd;

  /// Lightning risk screen (only when the building geometry + Ng are given).
  final LightningRisk? lightning;

  /// Earth-electrode array design (only when soil resistivity is given).
  final ElectrodeDesign? electrode;

  /// Hybrid power one-line (only when the project carries energy [sources]).
  final PowerOneLine? powerOneLine;

  /// Project bill of materials.
  final Bom bom;

  /// Aggregated provenance honesty surface — every sub-result's `verifyItems`,
  /// de-duplicated and order-preserving.
  final List<String> verifyItems;

  /// Round 13 — JUDGE-ONLY project-level warnings this layer raises (today: a
  /// forced genset nameplate below the essential boards' demand). Fanned into
  /// the ONE electrical warning surface by the app. Empty by default.
  final List<ElectricalWarning> warnings;

  /// Round 56 (elec-convergence-8-ads-never-judged-on-standby-genset-source)
  /// — the genset-backed ways that pass ADS on the utility but FAIL it with
  /// the standby genset as the origin ([gensetAdsCheck]); every printed
  /// schedule marks them ' Zs!' like a utility failure. Empty by default.
  final Set<String> gensetAdsFailedCircuitIds;

  const AdvancedStudy({
    required this.fault,
    required this.supply,
    required this.recommendedDayaVa,
    this.recommendedDayaThreePhase = true,
    required this.powerFactor,
    required this.controlAssemblies,
    required this.harmonics,
    required this.arcFlash,
    required this.containment,
    required this.enclosure,
    required this.metering,
    required this.spd,
    this.lightning,
    this.electrode,
    this.powerOneLine,
    required this.bom,
    required this.verifyItems,
    this.warnings = const [],
    this.gensetAdsFailedCircuitIds = const {},
  });

  /// Every way failing automatic disconnection on ANY supply: the utility
  /// fault study's failures plus [gensetAdsFailedCircuitIds].
  Set<String> get adsFailedCircuitIds => {
        for (final e in fault.circuits.entries)
          if (e.value.adsOk == false) e.key,
        ...gensetAdsFailedCircuitIds,
      };
}

/// Run the whole advanced study over an already-solved system. Pure +
/// deterministic.
///
/// Ordering (each step may inform a later one):
///   1. **Control assemblies** — per motor/pump circuit that carries a
///      [StarterType]; their summed device heat (+ a small base allowance)
///      becomes the per-panel enclosure heat when `panel.heatW` is unset.
///   2. **Fault study** — Isc / breaking-capacity / Zs-ADS / selectivity.
///   3. **Arc-flash** — per panel, from the panel's prospective fault and a
///      representative clearing time (MCB 0.05 s / MCCB 0.2 s / ACB 0.5 s by
///      the incomer class, [arcFlashClearingTimeS]).
///   4. **Harmonics / containment / metering / SPD** — per panel (the origin
///      panel gets `atOrigin:true`; sub-boards by their feeder distance).
///   5. **Supply** + **daya tersambung**, **power factor** (detuned when any
///      panel is harmonic-rich), **lightning** + **electrode** (only when the
///      site inputs exist), **power one-line** (only when [sources] is set),
///      and the project **BOM**.
AdvancedStudy computeAdvancedStudy(
  ElectricalStandardsProfile profile,
  ElectricalProject project,
  ElectricalSystemResult sys, {
  Map<String, double> priceList = const {},
  Current? originFaultLevel,
}) {
  final modelById = {for (final p in project.panels) p.id: p};
  // Round 29 — the SOLVED phase of each way (a 1φ motor's starter / overload
  // size on the 1φ FLC at U0, never the 3φ 400 V table).
  final threePhaseByCircuit = <String, bool>{
    for (final pr in sys.panels.values)
      for (final r in pr.circuits) r.circuitId: r.threePhase,
  };
  final resultByCircuit = <String, ElectricalCircuitResult>{
    for (final pr in sys.panels.values)
      for (final r in pr.circuits) r.circuitId: r,
  };
  final starterWarnings = <ElectricalWarning>[];

  // 1 ── Control assemblies (per motor/pump circuit with an explicit starter).
  final controlAssemblies = <String, ControlAssembly>{};
  // Summed control-device heat per panel id (for the enclosure pass).
  final controlHeatByPanel = <String, double>{};
  for (final panel in project.panels) {
    var heat = 0.0;
    for (final c in panel.circuits) {
      if (c.starterType == null) continue;
      if (!_isMotorLike(c)) continue;
      final motorKw = _motorKw(c);
      if (motorKw <= 0) continue;
      final threePhase = threePhaseByCircuit[c.id] ??
          circuitIsThreePhase(
            panelSystem: panel.system,
            kind: c.loadKind,
            loadW: c.loadW,
            motorKw: c.motorKw,
            phases: c.phases,
          );
      // U0 for a 1φ way on a 3φ board (the rounding compute.dart uses).
      final u0 = panel.system == ElectricalSystem.threePhase
          ? (panel.voltage.volts / math.sqrt(3)).roundToDouble()
          : panel.voltage.volts;
      // Round 42 (elec-props-8-star-delta-on-single-phase-way) — a
      // single-phase motor has no six winding terminals to reconnect: a
      // star-delta starter on a 1φ way is built as DOL on the full 1φ
      // current (never 58 % gear carrying the whole line current) and the
      // way is flagged (judge-only).
      final starter = effectiveStarterType(c.starterType!, threePhase);
      if (starter != c.starterType) {
        starterWarnings.add(ElectricalWarning(
          code: 'star-delta-single-phase',
          severity: WarningSeverity.warning,
          message: '${c.name}: a star-delta starter needs a three-phase '
              'motor with six winding terminals — this way is single-phase, '
              'so its control gear is sized as direct-on-line on the full '
              'current; choose DOL / soft-starter or supply it three-phase.',
          panelId: panel.id,
          circuitId: c.id,
        ));
      }
      // Round 42 (elec-props-8-control-gear-flc-basis-below-schedule-ib) —
      // the gear sizes on the way's SOLVED running current (the Ib the
      // schedule prints); the IEC table only when no solved result exists.
      final solved = resultByCircuit[c.id];
      final assembly = applyStarterTemplate(
        circuitId: c.id,
        starterType: starter,
        motorKw: motorKw,
        voltage: threePhase ? panel.voltage : Voltage(u0),
        singlePhase: !threePhase,
        flcA: solved?.runCurrentA,
        variableTorque:
            starter == StarterType.vfd && c.loadKind == LoadKind.pump,
        // Round 41 — the SAME gate as the schedule's 'no-OL trip (fire)'
        // token and compute.dart's `fire-pump-protection` note, so the
        // control spec / BOM never buys a tripping overload for a fire pump.
        fireDuty: c.lifeSafety &&
            (c.loadKind == LoadKind.motor || c.loadKind == LoadKind.pump),
      );
      controlAssemblies[c.id] = assembly;
      for (final d in assembly.devices) {
        heat += d.heatLossW * d.qty;
      }
    }
    controlHeatByPanel[panel.id] = heat;
  }

  // 2 ── Fault study (drives the arc-flash fault levels + breaking-capacity).
  // Resolved with the SAME chain the app's Fold-1 withstand uses — an explicit
  // [originFaultLevel] argument, else the project's declared setting, else the
  // service-size estimate, else the flat default — so the device kA the
  // schedule prints can never diverge from the bus-withstand basis again (a
  // domestic board used to print 25 kA devices over a 6 kA bus). A project
  // declaring nothing resolves to the historic 16 kA ⇒ byte-identical.
  //
  // R5: the SERVICE-SIZE ESTIMATE governs only when nothing more authoritative
  // was declared — no explicit argument AND no project `originFaultLevelA` —
  // and the estimate itself resolved. Exactly then (and only then) does the
  // estimate's provenance debt belong on the printed honesty surface below; a
  // project that declares its fault level, or one that falls through to the
  // flat default, adds nothing ⇒ byte-identical.
  // Round 16 — with nothing declared, a demand that needs an MV service
  // resolves to the transformer the supply study selects (the store's Fold-1
  // chain resolves the same way, so the device kA and the bus agree).
  // Round 25 — the demand rides every tier (a declared capacity above the
  // PLN TR ceiling never estimates below the study transformer's fault).
  // Round 52 — the estimate reads the SAME supply study the advanced study
  // prints ([studySupplyDesign]): the largest section / per-phase basis.
  final serviceEstimate = estimatedServiceFaultLevelA(project,
      demand: sys.supply.demandVa, supply: studySupplyDesign(project, sys));
  final serviceEstimateGoverns = originFaultLevel == null &&
      project.originFaultLevelA == null &&
      serviceEstimate != null;
  final fault = faultStudy(
    sys,
    project,
    profile,
    originFaultLevel: originFaultLevel ??
        project.originFaultLevelA ??
        serviceEstimate ??
        const Current(defaultLvUtilityFaultKa * 1000),
  );

  // Origin / service-root panels — EVERY utility-fed root (Round 13: one
  // origin per service entrance, not just the first listed).
  final originPanelIds = originPanelIdsOf(sys, project);
  // Feeder distance (m) from the origin to each sub-board (the cumulative
  // feeder-cable run on the path to the panel). Round 24 — the SPD rule reads
  // the distance from the NEAREST upstream SPD instead (below).
  final feederDistanceM = _feederDistances(sys, project);
  final parentOfPanel = <String, String>{
    for (final p in project.panels)
      for (final c in p.circuits)
        if (c.feedsPanelId != null) c.feedsPanelId!: p.id,
  };
  // Distance from the nearest upstream recommended SPD, root-first.
  final spdDistanceM = <String, double>{};

  // 3+4 ── Per-panel passes.
  final arcFlash = <String, ArcFlashResult?>{};
  final harmonics = <String, HarmonicsResult?>{};
  final containment = <String, ContainmentResult>{};
  final enclosure = <String, EnclosureResult>{};
  final metering = <String, MeteringSpec>{};
  final spd = <String, SpdRecommendation>{};
  var anyHarmonicRich = false;

  for (final id in sys.order) {
    final panelResult = sys.panels[id];
    final panelModel = modelById[id];
    if (panelResult == null) continue;

    // Arc-flash — fault kA at the bus × a representative clearing time.
    final faultkA = fault.panels[id]?.prospectiveFaultkA ?? 0;
    final clearingTimeS =
        arcFlashClearingTimeS(panelResult.incomer.breaker.deviceClass);
    arcFlash[id] = estimateArcFlash(
      faultkA: Current.kiloamperes(faultkA),
      clearingTimeS: clearingTimeS,
      voltageV: panelModel?.voltage.volts ??
          (panelResult.system == ElectricalSystem.threePhase ? 400 : 230),
    );

    // Harmonics — the VFD-driven (pump/fan) share the kind-only classifier can't
    // see is fed in from the control assemblies on this panel.
    final h = estimateHarmonics(panelResult, profile,
        driveFedCircuitIds:
            _driveFedCircuitIds(panelResult, panelModel));
    harmonics[id] = h;
    if (h != null && h.thdBand == ThdBand.high) anyHarmonicRich = true;

    // Containment.
    // Round 44 — each way routed on the method its conductor was sized on.
    containment[id] = containmentFor(panelResult,
        methodOf: panelModel == null
            ? null
            : (cid) {
                for (final c in panelModel.circuits) {
                  if (c.id == cid) return effectiveInstallMethod(c, panelModel);
                }
                return panelModel.installMethod;
              });

    // Enclosure — explicit panel heat wins; else summed control-device heat +
    // the load-dependent breaker/busbar I²R + a small base allowance. Floor gear when any VFD/soft-starter is present.
    final explicitHeat = panelModel?.heatW;
    final heatW = explicitHeat != null
        ? explicitHeat.watts
        : (controlHeatByPanel[id] ?? 0) +
            switchgearLossW(panelResult) +
            _baseEnclosureHeatW;
    enclosure[id] = estimateEnclosure(
      panelResult,
      heat: Power(heatW),
      hasFloorGear: _hasFloorGear(panelModel, controlAssemblies),
    );

    // Metering.
    metering[id] = meterFor(panelResult.meteringCurrent);

    // SPD — origin board at the service entrance; sub-boards by the feeder
    // distance from the NEAREST upstream SPD (Round 24 — a board below a
    // sub-board that itself received a recommended SPD measures from THAT
    // device, IEC 61643-12 / IEC 60364-5-534 protective distance).
    final atOrigin = originPanelIds.contains(id);
    final parentId = parentOfPanel[id];
    final double distFromSpd;
    if (atOrigin || parentId == null) {
      distFromSpd = 0;
    } else {
      final ownLeg = (feederDistanceM[id] ?? 0) - (feederDistanceM[parentId] ?? 0);
      final parentProtected = spd[parentId]?.recommended ?? false;
      distFromSpd = (parentProtected ? 0 : (spdDistanceM[parentId] ?? 0)) +
          (ownLeg > 0 ? ownLeg : 0);
    }
    spdDistanceM[id] = distFromSpd;
    spd[id] = recommendSpd(
      atOrigin: atOrigin,
      feederDistanceM: distFromSpd,
      earthingSystem: sys.earthing.system.name,
      hasExternalLps: project.externalLps,
      overheadSupply: project.overheadSupply,
    );
  }

  // 5 ── Project-level passes.
  // Round 16 — a declared transformer IS the arrangement (MV), so no LV daya
  // is recommended for a service not taken at LV.
  // Round 39 — the per-phase basis (below) is computed FIRST so the LV / MV
  // verdict is judged on the same figure the daya recommendation uses.
  // Round 52 — the ONE assembly of the supply study's inputs (shared with
  // the fault estimate, so the device kA ratings derive from the transformer
  // this study prints).
  final studied =
      studySupplyInputs(project, sys, originPanelIds: originPanelIds);
  final worstPhaseVa = studied.worstPhaseVa;
  final supply = studied.supply;
  final largestSectionId = studied.largestSectionId;
  // Round 35 (elec-core-2-daya-ignores-worst-phase) — a PLN 3φ limiter trips
  // PER PHASE at daya / (√3·400), and `computeSystem` judges a declared daya
  // against the root's diversified WORST-phase current
  // (`service-capacity-below-demand`). The recommendation sizes on the same
  // basis — max(total demand VA, Σ roots' worst-phase VA through the exact
  // inverse conversion, currents rounded as the judge rounds them) — so
  // declaring the recommended daya can never trip the engine's own judge
  // (two 1φ 5 kW heaters: 16 500 VA, never 10 600 VA / 15.3 A).
  // Round 58 — no PLN daya on an on-site genset / PV primary supply.
  var daya = supply.declared || project.supplyKind != SupplyKind.pln
      ? null
      : recommendedDaya(
          ApparentPower(math.max(
              sys.supply.demandVa.voltAmperes, worstPhaseVa)),
          sys.supply.system);
  // Round 38 (elec-sizing-supply-3) — a single-phase supply whose demand
  // outgrows the 1φ ladder moves to a 3φ step, but its 1φ root board still
  // loads ONE phase of that service: size the step on the same 3φ per-phase
  // basis `computeSystem` judges it on (√3·400·I), so declaring the
  // recommendation never trips the engine's own judge.
  if (daya != null &&
      daya.system == ElectricalSystem.threePhase &&
      sys.supply.system == ElectricalSystem.singlePhase) {
    final va3 = worstPhaseDemandVa(project, sys, originPanelIds,
        roundCurrent: true,
        withLargestMachine: true,
        asSystem: ElectricalSystem.threePhase,
        asVolts: kThreePhaseServiceLineVoltageV);
    daya = recommendedDaya(
        ApparentPower(math.max(sys.supply.demandVa.voltAmperes, va3)),
        ElectricalSystem.threePhase);
  }
  final powerFactor = powerFactorCorrection(
    sys,
    project,
    harmonicRich: anyHarmonicRich,
  );

  // Lightning + electrode — only when the site inputs are present.
  LightningRisk? lightning;
  if (project.groundFlashDensity != null &&
      project.buildingLengthM != null &&
      project.buildingWidthM != null &&
      project.buildingHeightM != null) {
    final area = collectionArea(
      project.buildingLengthM!,
      project.buildingWidthM!,
      project.buildingHeightM!,
    );
    lightning = assessLightning(
      groundFlashDensity: project.groundFlashDensity!,
      areaM2: area,
    );
  }
  ElectrodeDesign? electrode;
  if (project.soilResistivityOhmM != null) {
    electrode = designElectrode(soilResistivityOhmM: project.soilResistivityOhmM!);
  }

  // Power one-line — only when the project carries energy sources. The motors
  // for the genset-start dip screen come from the sized motor/pump circuits.
  PowerOneLine? powerOneLine;
  if (project.sources != null) {
    powerOneLine = buildPowerOneLine(
      project.sources!,
      demand: sys.supply.demandVa,
      // Round 13 — the genset backs max(fraction × demand, the essential
      // sub-tree's demand), the same basis the spine + schedule print.
      backupDemand: gensetBackupDemandVa(project, sys),
      // Round 16 — the genset's kW limit + the battery's real critical load.
      backupPower: gensetBackupDemandW(project, sys),
      demandPower: Power(sys.supply.demandW),
      voltage: sys.supply.voltage,
      motors: gensetStartMotors(project,
          sys: sys, assemblies: controlAssemblies),
      utilitySub: powerOneLineUtilitySub(project, sys,
          voltage: sys.supply.voltage),
      // Round 58 — the head follows the primary supply (PLN / genset / PV).
      supplyKind: project.supplyKind,
      supplyCapacity: project.supplyCapacityVa,
    );
  }

  // Breakers match parts whose breaking capacity covers the board's
  // prospective fault — the same fault study the schedule's kA tokens use.
  // Round 15 — each device matches its SPECIFIED kA (the schedule's figure).
  final faultKa = faultSpecifiedKa(fault);
  // Round 21 (bom-quote-4/-5) — each enclosure priced at its sized W x H x D,
  // and the designed control gear / genset / SPDs / earthing taken off too.
  final bom = buildBom(sys,
      requiredIcuKaByPanelId: faultKa.bus,
      incomerKaByPanelId: faultKa.incomers,
      breakerKaByCircuitId: faultKa.breakers,
      enclosureByPanelId: enclosure,
      extraLines: advancedBomLines(
        project: project,
        sys: sys,
        controlAssemblies: controlAssemblies,
        spd: spd,
        electrode: electrode,
        powerFactor: powerFactor,
        containment: containment,
        metering: metering,
      ));

  // Round 56 — ADS judged on the standby genset too (judge-only).
  final onGenset = gensetAdsCheck(profile, project, sys, fault);

  // Aggregate every sub-result's provenance honesty surface.
  final verify = _aggregateVerify([
    if (onGenset.judged) [gensetSustainedFaultVerifyItem],
    fault.verifyItems,
    supply.verifyItems,
    powerFactor.verifyItems,
    for (final a in controlAssemblies.values) a.verifyItems,
    for (final h in harmonics.values) h?.verifyItems,
    for (final a in arcFlash.values) a?.verifyItems,
    for (final c in containment.values) c.verifyItems,
    for (final e in enclosure.values) e.verifyItems,
    for (final m in metering.values) m.verifyItems,
    for (final s in spd.values) s.verifyItems,
    lightning?.verifyItems,
    electrode?.verifyItems,
    // The occupancy diversity library is only an honesty surface when a panel
    // actually references it (otherwise the per-circuit demand factors apply).
    if (project.panels.any((p) => p.diversityLibraryId != null))
      diversityLibraryVerifyItems,
    // R5 — the service-size fault ESTIMATE drives the printed device kA tokens
    // and the busbar-withstand basis whenever it governs, so its representative
    // transformer impedance / capacity rungs / clamp must be declared in the
    // report's "Unverified values" section rather than sitting silently behind
    // the numbers.
    if (serviceEstimateGoverns) serviceFaultEstimateVerifyItems,
  ]);

  return AdvancedStudy(
    gensetAdsFailedCircuitIds: onGenset.failedIds,
    fault: fault,
    supply: supply,
    recommendedDayaVa: daya?.va,
    recommendedDayaThreePhase:
        (daya?.system ?? ElectricalSystem.threePhase) ==
            ElectricalSystem.threePhase,
    powerFactor: powerFactor,
    controlAssemblies: controlAssemblies,
    harmonics: harmonics,
    arcFlash: arcFlash,
    containment: containment,
    enclosure: enclosure,
    metering: metering,
    spd: spd,
    lightning: lightning,
    electrode: electrode,
    powerOneLine: powerOneLine,
    bom: bom,
    verifyItems: verify,
    warnings: [
      ...gensetBackupWarnings(project, sys),
      ...onGenset.warnings,
      ...enclosureTempRiseWarnings(sys, enclosure),
      ...ttRcdTouchVoltageWarnings(project, sys, electrode),
      ...starterWarnings,
      // Round 40 — a DECLARED transformer (or the most loaded section of a
      // dual service) whose 80 %-loaded rating is below what it carries was
      // only a note; it is now a judge-only warning (never resizes).
      if (supply.declared && supply.declaredBelowDemand)
        ElectricalWarning(
          code: largestSectionId != null
              ? 'section-transformer-overloaded'
              : 'transformer-below-demand',
          severity: WarningSeverity.warning,
          message: supply.note,
          panelId: largestSectionId,
        ),
      // Round 40 — a root incomer rated above the full-load current its
      // transformer unit can deliver (one unit per section on a dual
      // service) can never be loaded to its rating.
      for (final w
          in _incomerAboveTransformerFlc(
              profile, project, sys, supply, originPanelIds))
        w,
      // Round 17 — the service-size estimate is no longer clamped at 50 kA
      // (a clamp LOWERED the safety quantity); above the realistic LV device
      // ladder it is flagged so the engineer commissions a real study.
      if (serviceEstimateGoverns &&
          serviceEstimate != null &&
          serviceEstimate.amperes > maxEstimatedServiceFaultKa * 1000.0 + 1e-6)
        ElectricalWarning(
          code: 'service-fault-estimate-high',
          severity: WarningSeverity.warning,
          message: 'Service fault estimate '
              '${(serviceEstimate.amperes / 1000).toStringAsFixed(1)} kA '
              'exceeds ${maxEstimatedServiceFaultKa.toStringAsFixed(0)} kA — '
              'an IEC 60909 short-circuit study and 65/70 kA-class devices are '
              'required; enter the studied origin fault level in Service & '
              'Earthing.',
        ),
    ],
  );
}

// ───────────────────────────────────────────────────────────────────────────
// Helpers.
// ───────────────────────────────────────────────────────────────────────────

/// Round 56 — the INSTALLED standby genset (VA): a forced nameplate × its
/// units, else the set the G-01 schedule / spine / BOM size
/// ([sizeGenerator] over [gensetBackupDemandVa] / [gensetBackupDemandW]) ×
/// its units. Null when the project has no generator or nothing to back.
double? gensetPlantVa(ElectricalProject project, ElectricalSystemResult sys) {
  final gen = project.sources?.generator;
  if (gen == null) return null;
  if (gen.kva != null) {
    final v = gen.kva!.voltAmperes * (gen.units < 1 ? 1 : gen.units);
    return v > 0 ? v : null;
  }
  if (sys.supply.demandVa.voltAmperes <= 0) return null;
  final r = sizeGenerator(gensetBackupDemandVa(project, sys),
      mode: gen.mode,
      transfer: gen.transfer,
      backupPower: gensetBackupDemandW(project, sys));
  final v = r.ratingKva.voltAmperes * r.units;
  return v > 0 ? v : null;
}

/// Round 56 (elec-convergence-8-ads-never-judged-on-standby-genset-source)
/// — JUDGE-ONLY: IEC 60364-4-41 411.3.2 requires automatic disconnection
/// under EVERY supply condition, and a life-safety board runs exactly when
/// the standby genset carries it. On TN, every way of a genset-backed board
/// ([gensetBackedPanelIds]; the whole installation for a full-backup set
/// with nothing marked essential) is re-judged with the genset as the origin
/// — the alternator sub-transient fault S/(√3·400·Xd'') of the installed set
/// ([gensetPlantVa], [onSiteSourceFaultA], Xd'' `// VERIFY`). A way that
/// passes on the utility but fails there raises the ERROR
/// `ads-disconnection-on-genset` (never resizes). The sustained ~3 × FLC
/// short-circuit current of an alternator without a PMG excitation is a
/// harsher second basis, recorded as a `// VERIFY` item, not judged. A
/// prime-power plant ([SupplyKind.generator]) is already the study origin.
({bool judged, Set<String> failedIds, List<ElectricalWarning> warnings})
    gensetAdsCheck(
  ElectricalStandardsProfile profile,
  ElectricalProject project,
  ElectricalSystemResult sys,
  FaultStudyResult utility,
) {
  const none =
      (judged: false, failedIds: <String>{}, warnings: <ElectricalWarning>[]);
  final gen = project.sources?.generator;
  final tn = sys.earthing.system == EarthingSystem.tnS ||
      sys.earthing.system == EarthingSystem.tnCs;
  if (gen == null || !tn || project.supplyKind == SupplyKind.generator) {
    return none;
  }
  var backed = gensetBackedPanelIds(project);
  if (backed.isEmpty && gen.backupFraction >= 1 - 1e-9) {
    backed = {for (final p in project.panels) p.id};
  }
  if (backed.isEmpty) return none;
  final va = gensetPlantVa(project, sys);
  if (va == null) return none;
  final iscA = onSiteSourceFaultA(SupplyKind.generator, va);
  final g = faultStudy(sys, project, profile, originFaultLevel: Current(iscA));
  final kva = (va / 1000).toStringAsFixed(0);
  final failed = <String>{};
  final warnings = <ElectricalWarning>[];
  for (final pid in sys.order) {
    if (!backed.contains(pid)) continue;
    final pr = sys.panels[pid];
    if (pr == null) continue;
    for (final w in pr.circuits) {
      final onGen = g.circuits[w.circuitId];
      if (onGen?.adsOk != false) continue;
      if (utility.circuits[w.circuitId]?.adsOk == false) continue;
      failed.add(w.circuitId);
      final zs = onGen!.zsOhm;
      final lim = onGen.zsMaxOhm;
      warnings.add(ElectricalWarning(
        code: 'ads-disconnection-on-genset',
        severity: WarningSeverity.error,
        message: '${w.name}: on the $kva kVA standby genset (alternator '
            'fault ${(iscA / 1000).toStringAsFixed(1)} kA) the earth-fault '
            'loop${zs != null && lim != null ? ' Zs ${zs.toStringAsFixed(3)} ohm exceeds the ${lim.toStringAsFixed(3)} ohm limit' : ' exceeds its limit'}'
            ' — automatic disconnection is not met on genset supply '
            '(IEC 60364-4-41 411.3.2): enlarge the cable, lower the device '
            'rating, add an RCD, or size the set for the fault.',
        panelId: pid,
        circuitId: w.circuitId,
      ));
    }
  }
  return (judged: true, failedIds: failed, warnings: warnings);
}

/// Round 56 — the `// VERIFY` second genset fault basis [gensetAdsCheck]
/// records but does not judge on.
const String gensetSustainedFaultVerifyItem =
    'standby genset ADS judged on the alternator sub-transient fault '
    '(Xd\'\'); a set without PMG excitation sustains only ~3 x FLC — the '
    'alternator decrement curve governs';

/// Round 56 (elec-convergence-8-enclosure-thermal-fail-silent-and-priced)
/// — JUDGE-ONLY: a board whose estimated enclosure rise ([estimateEnclosure],
/// IEC 60890 power balance, `// VERIFY` estimate) exceeds
/// [maxInternalTempRiseK] raises `enclosure-temp-rise-exceeded`. The
/// envelope is never grown here (a larger cubicle would change every large
/// board's W x H x D and price) — the engineer enlarges / ventilates it.
List<ElectricalWarning> enclosureTempRiseWarnings(
    ElectricalSystemResult sys, Map<String, EnclosureResult> enclosure) {
  final out = <ElectricalWarning>[];
  for (final id in sys.order) {
    final e = enclosure[id];
    if (e == null) continue;
    if (e.withinTempLimit && e.tempRiseK.isFinite) continue;
    final name = sys.panels[id]?.name ?? id;
    final rise =
        e.tempRiseK.isFinite ? '${e.tempRiseK.toStringAsFixed(0)} K' : 'n/a';
    final vent = switch (e.ventilation) {
      Ventilation.natural => 'natural ventilation',
      Ventilation.fanFilter => 'a filter fan',
      Ventilation.forced => 'forced ventilation',
      Ventilation.heatExchanger => 'a heat exchanger / cooling unit',
    };
    out.add(ElectricalWarning(
      code: 'enclosure-temp-rise-exceeded',
      severity: WarningSeverity.warning,
      message: '$name: estimated enclosure rise $rise > '
          '${maxInternalTempRiseK.toStringAsFixed(0)} K in '
          '${e.widthMm.toStringAsFixed(0)}x${e.heightMm.toStringAsFixed(0)}x'
          '${e.depthMm.toStringAsFixed(0)} mm (IEC 60890, estimate) — '
          'enlarge it / use a floor-standing cubicle / add $vent.',
      panelId: id,
    ));
  }
  return out;
}

/// Round 54 (regression-tt-rcd-touch-voltage-judge-dead) — JUDGE-ONLY: the TT
/// RCD fault-protection condition Ra × IΔn <= 50 V (IEC 60364-4-41 411.5.3)
/// against the DESIGNED electrode's achieved resistance ([electrode], from the
/// project soil resistivity): every TT way that requires an RCD whose IΔn the
/// electrode cannot meet raises `tt-rcd-touch-voltage` (never re-rated).
/// Without a soil resistivity there is no site Ra: a single INFO
/// `tt-earth-fault-unchecked` says the condition is unverified — it is never
/// judged against the 5 ohm target, which passes every IΔn the engine mints.
List<ElectricalWarning> ttRcdTouchVoltageWarnings(
  ElectricalProject project,
  ElectricalSystemResult sys,
  ElectrodeDesign? electrode,
) {
  if (project.earthingSystem != EarthingSystem.tt) return const [];
  final rcdWays = <(String, ElectricalCircuitResult)>[
    for (final pid in sys.order)
      if (sys.panels[pid] case final p?)
        for (final c in p.circuits)
          if (c.rcd.required) (pid, c),
  ];
  if (rcdWays.isEmpty) return const [];
  if (electrode == null) {
    return const [
      ElectricalWarning(
        code: 'tt-earth-fault-unchecked',
        severity: WarningSeverity.info,
        message: 'TT earth-fault protection unverified: enter the site soil '
            'resistivity (Service & Earthing) so the earth electrode is '
            'designed and each RCD is judged against Ra x IΔn <= 50 V '
            '(IEC 60364-4-41 411.5.3).',
      ),
    ];
  }
  final ra = electrode.achieved.ohms;
  final out = <ElectricalWarning>[];
  for (final (pid, c) in rcdWays) {
    if (ttRcdTouchVoltageOk(ra, c.rcd.ratingMa)) continue;
    final v = ra * c.rcd.ratingMa / 1000.0;
    out.add(ElectricalWarning(
      code: 'tt-rcd-touch-voltage',
      severity: WarningSeverity.warning,
      message: '${c.name}: RCD ${c.rcd.ratingMa} mA x earth electrode '
          '${ra.toStringAsFixed(1)} ohm = ${v.toStringAsFixed(1)} V exceeds '
          'the ${kTtTouchVoltageLimitV.toStringAsFixed(0)} V touch-voltage '
          'limit (IEC 60364-4-41 411.5.3): lower the electrode resistance '
          'or the RCD IΔn.',
      panelId: pid,
      circuitId: c.circuitId,
    ));
  }
  return out;
}

/// Round 40 — `root-incomer-exceeds-transformer-flc`: each service-entrance
/// board on a DECLARED transformer service whose incomer rating exceeds the
/// LV full-load current of the unit feeding it (one unit per section on a
/// dual service; the paralleled units otherwise). Judge-only.
///
/// Round 41 (regression-incomer-above-tx-flc-fires-on-engine-own-rung):
/// breakers come in rungs, so an incomer sized to carry the transformer's
/// full load is the first rung AT OR ABOVE the FLC (630 kVA → 909 A → the
/// 1000 A rung the Round-29 service-capacity floor itself picks). The
/// warning fires only ABOVE that rung — never on the engine's own pick. A
/// dual service is judged per SECTION whatever the root count (Round 37: a
/// single root on a dual service sits on ONE section, coupler normally
/// open — the basis of `serviceEntranceCapacityVa` and `determineSupply(
/// singleSectionCarriesAll:)`), so a section is `units / 2` units.
List<ElectricalWarning> _incomerAboveTransformerFlc(
  ElectricalStandardsProfile profile,
  ElectricalProject project,
  ElectricalSystemResult sys,
  SupplyDesign supply,
  Set<String> originPanelIds,
) {
  // Round 60 — undeclared study transformers are judged too (a single root
  // board on an undeclared sectioned service once sat on a unit sized for
  // demand / N, with nothing flagged).
  final kva = supply.transformerKva;
  if (supply.lvOrMv != SupplyLevel.mv || kva == null || kva <= 0) {
    return const [];
  }
  final units = math.max(1, supply.units);
  final unitsPerRoot = math.max(1, units ~/ serviceSections(project));
  final flcA = unitsPerRoot * kva * 1000 / (math.sqrt(3) * 400);
  final rungA = incomerRungForFlcA(profile, flcA);
  final out = <ElectricalWarning>[];
  for (final id in originPanelIds.toList()..sort()) {
    final r = sys.panels[id];
    if (r == null) continue;
    final inA = r.incomer.breaker.ratingA.amperes;
    if (inA > rungA + 1e-6) {
      out.add(ElectricalWarning(
        code: 'root-incomer-exceeds-transformer-flc',
        severity: WarningSeverity.warning,
        message: '${r.name}: the ${inA.round()} A incomer is above the '
            '${rungA.round()} A breaker rung matching the '
            '${flcA.round()} A full-load current of the '
            '${unitsPerRoot > 1 ? '$unitsPerRoot x ' : ''}${kva.round()} kVA '
            'transformer feeding it — the board can never be loaded to its '
            'incomer rating; raise the transformer rating or move load to '
            'the other section.',
        panelId: id,
      ));
    }
  }
  return out;
}

/// Round 41 — the first breaker rung at or above a transformer's LV
/// full-load current [flcA] (the profile ladder runs on to ACB frames);
/// [flcA] itself when the ladder tops out below it.
double incomerRungForFlcA(ElectricalStandardsProfile profile, double flcA) {
  for (final r in profile.standardBreakerRatingsA) {
    if (r >= flcA - 1e-6) return r;
  }
  return flcA;
}

/// True when a circuit is motor-like (so a starter assembly makes sense).
bool _isMotorLike(ElectricalCircuit c) =>
    c.loadKind == LoadKind.motor ||
    c.loadKind == LoadKind.pump ||
    c.loadKind == LoadKind.hvac;

/// Shaft kW for a motor circuit — the explicit [ElectricalCircuit.motorKw], else
/// the connected load as a kW proxy (so an HVAC way with watts still sizes gear).
///
/// Round 36 (elec-props-4-stale-motorkw-after-rekind) — an HVAC way sizes on
/// its `loadW` (compute reads `motorKw` only on motor / pump ways), so a
/// hand-entered HVAC way's `motorKw` (left over from re-kinding a motor, and
/// hidden by the inspector) never drives its starter or the genset dip while
/// `loadW` is set. An MEP-derived way (`sourceEquipmentId` / `flaOverrideA`)
/// keeps its authoritative machine `motorKw`.
double _motorKw(ElectricalCircuit c) {
  final loadKw = c.loadW > 0 ? c.loadW / 1000.0 : 0.0;
  final m = c.motorKw;
  if (m == null) return loadKw;
  final mepDerived = (c.sourceEquipmentId != null &&
          c.sourceEquipmentId!.isNotEmpty) ||
      c.flaOverrideA != null;
  if (c.loadKind == LoadKind.hvac && loadKw > 0 && !mepDerived) return loadKw;
  return m;
}

/// Round 52 (elec-convergence-4-undeclared-study-transformer-fault-not-the-
/// printed-transformer) — the supply study of [sys]: [determineSupply] on the
/// building demand, the largest dual-service SECTION (Round 40), the per-phase
/// basis (Round 39) and the declared rating (Round 29) — the ONE assembly
/// [computeAdvancedStudy] prints (supply note, power one-line, overview,
/// riser) AND the fault estimate reads ([estimatedServiceFaultLevelA]
/// `supply:`), so the fault study, busbar withstand and every specified device
/// kA derive from the transformer actually issued, never a smaller unit sized
/// on the total demand split evenly. [worstPhaseVa] / [perPhaseBasisVa] are
/// the per-phase figures the daya recommendation also uses. Pure.
({
  SupplyDesign supply,
  double worstPhaseVa,
  double perPhaseBasisVa,
  String? largestSectionId,
}) studySupplyInputs(ElectricalProject project, ElectricalSystemResult sys,
        {Set<String>? originPanelIds}) {
  originPanelIds ??= originPanelIdsOf(sys, project);
  final worstPhaseVa = worstPhaseDemandVa(project, sys, originPanelIds,
      roundCurrent: true, withLargestMachine: true);
  final perPhaseBasisVa = sys.supply.system == ElectricalSystem.singlePhase
      ? worstPhaseDemandVa(project, sys, originPanelIds,
          roundCurrent: true,
          withLargestMachine: true,
          asSystem: ElectricalSystem.threePhase,
          asVolts: kThreePhaseServiceLineVoltageV)
      : worstPhaseVa;
  // Round 40 (electrical-sim-5-dual-tx-section-overload-missed) — on a dual
  // service each root board sits on ONE unit (coupler normally open, as the
  // fault study models it), so the most loaded ROOT governs a section: its
  // diversified VA, or its worst-phase basis when that is larger.
  var largestSectionVa = 0.0;
  String? largestSectionId;
  if (serviceSections(project) > 1 && originPanelIds.length > 1) {
    for (final id in originPanelIds) {
      final r = sys.panels[id];
      if (r == null) continue;
      final va = math.max(
          r.demandVaOrEstimate(),
          worstPhaseDemandVa(project, sys, [id],
              roundCurrent: true, withLargestMachine: true));
      if (va > largestSectionVa + 1e-9 ||
          (largestSectionId != null &&
              (va - largestSectionVa).abs() <= 1e-9 &&
              id.compareTo(largestSectionId) < 0)) {
        largestSectionVa = va;
        largestSectionId = id;
      }
    }
  }
  final supply = determineSupply(
    sys.supply.demandVa,
    largestSectionDemand:
        largestSectionVa > 0 ? ApparentPower(largestSectionVa) : null,
    perPhaseDemand: ApparentPower(perPhaseBasisVa),
    dualTransformer: project.dualTransformer,
    // Round 29 — the ONE declared rating (a connection capacity above the
    // LV ceiling is a TM service on its snapped transformer).
    declaredKva: declaredServiceTransformer(project)?.kva,
    declaredUnits: declaredServiceTransformer(project)?.units,
    // Round 37 r2 — a single root board on a dual service is judged against
    // ONE section, like its incomer floor and the service-capacity judge.
    singleSectionCarriesAll: originPanelIds.length == 1,
    // Round 58 — an N-section service judges each root on one unit.
    sections: serviceSections(project),
    // Round 58 — an on-site genset / PV primary supply has no PLN service.
    supplyKind: project.supplyKind,
    plantCapacity: project.supplyCapacityVa,
  );
  return (
    supply: supply,
    worstPhaseVa: worstPhaseVa,
    perPhaseBasisVa: perPhaseBasisVa,
    largestSectionId: largestSectionId,
  );
}

/// Round 16 (supply-sources-dual-tx-spine-genset-ladder) / Round 60
/// (elec-convergence-12-printed-transformer-not-the-study-transformer) — the
/// service transformer the DRAWINGS, the equipment schedule, the BOM and the
/// power one-line print: EXACTLY the transformer the supply study picked
/// ([studySupplyDesign] — its largest section, per-phase basis, section count
/// and single-root rule, the transformer the origin fault and every device kA
/// are specified against), never a second [determineSupply] re-derivation on
/// the total demand alone. Only on a declared MV / sectioned service
/// ([isDeclaredMvService]) — an undeclared single service draws no customer
/// transformer (Round 19). A null [sys] (nothing solved) prints the declared
/// rating only. Null when nothing is to be printed.
({double kva, int units})? serviceTransformer(
    ElectricalProject project, ElectricalSystemResult? sys) {
  if (!isDeclaredMvService(project)) return null;
  if (sys == null) {
    final d = declaredServiceTransformer(project);
    if (d == null || d.kva.inKilovoltAmperes <= 0) return null;
    return (kva: d.kva.inKilovoltAmperes, units: d.units);
  }
  final s = studySupplyDesign(project, sys);
  final kva = s.transformerKva;
  if (s.lvOrMv != SupplyLevel.mv || kva == null || kva <= 0 || s.units < 1) {
    return null;
  }
  return (kva: kva, units: s.units);
}

/// Round 52 — [studySupplyInputs]' supply design alone.
SupplyDesign studySupplyDesign(
        ElectricalProject project, ElectricalSystemResult sys) =>
    studySupplyInputs(project, sys).supply;

/// The origin / service-entrance panel ids: EVERY panel that takes its supply
/// directly from the utility — no feeder way points at it and it carries no
/// `fedByCircuitId`. Round 13 (elec-props-2-multiroot-spd-single-origin): it
/// used to return ONE id (the first root in the solve order), so a second
/// service-entrance board on an external-LPS building was treated as a
/// sub-board at 0 m and told an SPD was not recommended — and the verdict
/// flipped with panel list order. Falls back to the first id in the solve
/// order when no panel qualifies (a cyclic topology).
Set<String> originPanelIdsOf(
  ElectricalSystemResult sys,
  ElectricalProject project,
) {
  final fed = <String>{
    for (final p in project.panels)
      for (final c in p.circuits)
        if (c.feedsPanelId != null && c.feedsPanelId!.isNotEmpty)
          c.feedsPanelId!,
  };
  final modelById = {for (final p in project.panels) p.id: p};
  final out = <String>{
    for (final id in sys.order)
      if (!fed.contains(id) && modelById[id]?.fedByCircuitId == null) id,
  };
  if (out.isEmpty && sys.order.isNotEmpty) out.add(sys.order.first);
  return out;
}

/// Cumulative feeder-cable run length (m) from the origin to each panel, walking
/// the feeder tree (a child's distance = its parent's distance + the feeding
/// circuit's run length). Origin panels are 0.
///
/// The feeder run length is the SOLVED one ([solvedRunLengthM] — geo-derived
/// when the boards are placed, else the manual length), the same run the cable,
/// Vd and the fault/Zs decay were computed on, so the SPD distance agrees with
/// sizing instead of reading a stale manual default.
Map<String, double> _feederDistances(
  ElectricalSystemResult sys,
  ElectricalProject project,
) {
  // child panel id -> (parent panel id, feeding circuit solved length).
  final parentOf = <String, String>{};
  final feederLenM = <String, double>{};
  for (final p in project.panels) {
    final panelResult = sys.panels[p.id];
    for (final c in p.circuits) {
      if (c.feedsPanelId != null) {
        ElectricalCircuitResult? result;
        if (panelResult != null) {
          for (final r in panelResult.circuits) {
            if (r.circuitId == c.id) {
              result = r;
              break;
            }
          }
        }
        parentOf[c.feedsPanelId!] = p.id;
        feederLenM[c.feedsPanelId!] = solvedRunLengthM(result, c);
      }
    }
  }
  final dist = <String, double>{};
  // sys.order is root-first, so a parent's distance is set before its child.
  for (final id in sys.order) {
    final parent = parentOf[id];
    if (parent == null) {
      dist[id] = 0;
    } else {
      dist[id] = (dist[parent] ?? 0) + (feederLenM[id] ?? 0);
    }
  }
  return dist;
}

/// The panel's VFD-fed circuit ids, which the kind-only classifier inside
/// `estimateHarmonics` cannot see. They are counted ADDITIVELY with the
/// kind-derived (UPS / welding) share — never as an override — so adding a
/// drive can only raise the panel's non-linear fraction.
///
/// Round 42 — read through [isDriveFedCircuit], the predicate the PF study
/// also uses, so both studies see ONE drive-fed set.
Set<String> _driveFedCircuitIds(
  ElectricalPanelResult panel,
  ElectricalPanel? panelModel,
) {
  final ids = <String>{};
  if (panelModel == null) return ids;
  final resultIds = {for (final c in panel.circuits) c.circuitId};
  for (final c in panelModel.circuits) {
    if (c.loadKind == LoadKind.spare) continue;
    if (!resultIds.contains(c.id)) continue;
    if (isDriveFedCircuit(c)) ids.add(c.id);
  }
  return ids;
}

/// True when the panel hosts floor-standing gear (a VFD or soft-starter on any
/// of its circuits, or an explicit floor-gear-sized depth).
bool _hasFloorGear(
  ElectricalPanel? panelModel,
  Map<String, ControlAssembly> controlAssemblies,
) {
  if (panelModel == null) return false;
  for (final c in panelModel.circuits) {
    final a = controlAssemblies[c.id];
    if (a != null &&
        (a.starterType == StarterType.vfd ||
            a.starterType == StarterType.softStarter)) {
      return true;
    }
  }
  return false;
}

/// The motors (for the genset-start voltage-dip screen), with their starter
/// strings.
///
/// Round 11 — only the motors the genset actually STARTS: when the set backs a
/// fraction of the load (`backupFraction < 1`) or any board is flagged
/// essential, just the motors on the essential sub-tree
/// ([gensetBackedPanelIds]); a full-backup set with no essential designation
/// still screens every motor. It used to screen every motor in the project —
/// a 110 kW chiller on the NORMAL supply was the limiting motor of a 30 %-backup
/// 200 kVA set and printed 'start dip 38.22% over'.
///
/// Round 26 (fractional-genset-screens-no-motor) — the restriction applies only
/// when some board IS designated essential. A fractional set with NO essential
/// designation names no sub-tree, so nothing says which motors it does not
/// start: it screens every motor, like full backup (the safe direction — a
/// silently skipped 110 kW DOL start on a 100 kVA set dips ~55 %).
///
/// Round 36 (elec-props-4-genset-dip-skips-motors-full-backup) — and only
/// when the set does NOT back the whole load (`backupFraction < 1`). A
/// full-backup set transfers the WHOLE bus (the power one-line draws no
/// essential split for it — `essentialSplit` needs `backupFraction < 1`) and
/// was sized on the whole demand, so after transfer it starts every motor:
/// marking the fire-pump board essential (what `life-safety-not-essential`
/// asks for) must never drop a 110 kW DOL chiller out of the dip screen.
///
/// Round 42 (electrical-sim-7-genset-dip-multiples-disagree-with-starter) —
/// each motor carries its STARTING kVA on the ONE starting basis the control
/// assembly prints (`control/starting.dart`): the way's own assembly's
/// starting current when [assemblies] holds one, else [startingAnalysis] on
/// the assembly's own FLC basis (max of the IEC table FLC and the way's
/// solved running current [sys]) × √3·U (3φ) / U0 (1φ). One machine, one
/// starting current.
List<GensetMotor> gensetStartMotors(
  ElectricalProject project, {
  ElectricalSystemResult? sys,
  Map<String, ControlAssembly> assemblies = const {},
}) {
  final motors = <GensetMotor>[];
  final essential = gensetBackedPanelIds(project);
  final gen = project.sources?.generator;
  final restrict =
      essential.isNotEmpty && (gen?.backupFraction ?? 1.0) < 1.0;
  final resultByCircuit = <String, ElectricalCircuitResult>{
    if (sys != null)
      for (final pr in sys.panels.values)
        for (final r in pr.circuits) r.circuitId: r,
  };
  for (final p in project.panels) {
    if (restrict && !essential.contains(p.id)) continue;
    for (final c in p.circuits) {
      if (!_isMotorLike(c)) continue;
      final kw = _motorKw(c);
      if (kw <= 0) continue;
      final solved = resultByCircuit[c.id];
      final threePhase = solved?.threePhase ??
          circuitIsThreePhase(
            panelSystem: p.system,
            kind: c.loadKind,
            loadW: c.loadW,
            motorKw: c.motorKw,
            phases: c.phases,
          );
      final u0 = p.system == ElectricalSystem.threePhase
          ? (p.voltage.volts / math.sqrt(3)).roundToDouble()
          : p.voltage.volts;
      final starter = c.starterType == null
          ? null
          : effectiveStarterType(c.starterType!, threePhase);
      final assemblyStart = assemblies[c.id]?.starting;
      final double startA;
      if (assemblyStart != null) {
        startA = assemblyStart.startCurrentA.amperes;
      } else {
        // The assembly's own basis: max(table FLC, the solved Ib).
        final table = threePhase
            ? motorFlc(kw, p.voltage).amperes
            : motorFlc1ph(kw, Voltage(u0)).amperes;
        final ib = solved?.runCurrentA.amperes ?? 0;
        final flc = Current(
            ((ib > table ? ib : table) * 10).roundToDouble() / 10);
        startA = startingAnalysis(flc, starter ?? StarterType.dol)
            .startCurrentA
            .amperes;
      }
      final startVa = threePhase
          ? math.sqrt(3) * p.voltage.volts * startA
          : u0 * startA;
      motors.add(GensetMotor(
        name: c.name,
        shaftPower: Power.kiloWatts(kw),
        starterType: starter == null ? null : _starterString(starter),
        startKva: ApparentPower(startVa),
      ));
    }
  }
  return motors;
}


/// Map a [StarterType] to the loose string the genset dip screen expects (its
/// `kStartKvaMultiple` keys: DOL / STAR_DELTA / SOFT_STARTER / VFD / …).
String _starterString(StarterType t) => switch (t) {
      StarterType.dol => 'DOL',
      StarterType.starDelta => 'STAR_DELTA',
      StarterType.reversing => 'REVERSING',
      StarterType.softStarter => 'SOFT_STARTER',
      StarterType.vfd => 'VFD',
      StarterType.ats => 'ATS',
      StarterType.pump => 'PUMP',
    };

/// Merge a list of (nullable) verifyItems lists into one de-duplicated,
/// order-preserving list — the aggregate provenance honesty surface.
List<String> _aggregateVerify(List<List<String>?> lists) {
  final seen = <String>{};
  final out = <String>[];
  for (final list in lists) {
    if (list == null) continue;
    for (final item in list) {
      if (seen.add(item)) out.add(item);
    }
  }
  return out;
}

/// Round 34 (electrical-drawings-4-app-schedule-conduit-ladder-not-study) —
/// the containment STUDY's conduit per circuit id (`circuitId -> ConduitSpec`),
/// the ONE containment source every board schedule (canvas, PDF, DXF,
/// submittal, report figure) passes to `buildElectricalSld`, so the printed
/// `PVC <n>mm` token is the study's fill-checked size, never the CSA ladder.
Map<String, ConduitSpec> containmentByCircuitIdOf(AdvancedStudy study) => {
      for (final c in study.containment.values)
        for (final cc in c.conduits) cc.circuitId: cc.conduit,
    };

/// Round 23 (elec-drafting-2-2) — the power one-line's utility sub-label on a
/// DECLARED MV service (an explicit transformer rating or a dual-transformer
/// service): `MV via TX <n x kVA>` from the SAME [serviceTransformer] the
/// riser / overview / schedule print; on an LV direct service the builder's
/// `<V> V LV`, with the declared connection capacity appended when one is
/// declared (Round 34), else null.
String? powerOneLineUtilitySub(
    ElectricalProject project, ElectricalSystemResult? sys,
    {Voltage voltage = const Voltage(400)}) {
  if (!isDeclaredMvService(project)) {
    // Round 34 (electrical-drawings-4-lv-power-one-line-omits-daya) — an LV
    // service with a declared connection capacity states it, like the
    // overview / riser supply head ('PLN 197 kVA'); nothing declared ⇒ null
    // (the builder's bare '<V> V LV', byte-identical).
    final cap = project.supplyCapacityVa;
    if (cap == null || !(cap.inKilovoltAmperes > 0)) return null;
    String n(double v) =>
        v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
    return '${n(voltage.volts)} V LV · ${n(cap.inKilovoltAmperes)} kVA';
  }
  final t = serviceTransformer(project, sys);
  if (t == null || t.kva <= 0) return 'MV via TX';
  String n(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  final fig = t.units > 1 ? '${t.units} x ${n(t.kva)}' : n(t.kva);
  return 'MV via TX $fig kVA';
}
