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

import '../standards/puil.dart' show ElectricalStandardsProfile;
import '../units.dart';
import 'arc_flash.dart' show ArcFlashResult, estimateArcFlash;
import 'bom.dart' show Bom, buildBom;
import 'containment.dart' show ContainmentResult, containmentFor;
import 'control/starter.dart'
    show ControlAssembly, StarterType, applyStarterTemplate;
import 'electrode.dart' show ElectrodeDesign, designElectrode;
import 'enclosure.dart' show EnclosureResult, estimateEnclosure;
import 'fault.dart' show FaultStudyResult, faultStudy;
import 'harmonics.dart' show HarmonicsResult, ThdBand, estimateHarmonics;
import 'lightning.dart' show LightningRisk, assessLightning, collectionArea;
import 'load_kind.dart' show LoadKind;
import 'metering.dart' show MeteringSpec, meterFor;
import 'model.dart'
    show ElectricalCircuit, ElectricalPanel, ElectricalProject, ElectricalSystem;
import 'panel_results.dart' show ElectricalPanelResult, ElectricalSystemResult;
import 'power_factor.dart' show PowerFactorResult, powerFactorCorrection;
import 'power_oneline.dart' show PowerOneLine, buildPowerOneLine;
import 'sources.dart' show GensetMotor;
import 'spd.dart' show SpdRecommendation, recommendSpd;
import 'supply_design.dart'
    show SupplyDesign, determineSupply, recommendedDayaVa;

/// A representative MCB clearing (arcing) time for the arc-flash screen (s) —
/// fast magnetic/thermal trip on a miniature device.
const double _mcbClearingTimeS = 0.05;

/// A representative MCCB clearing (arcing) time for the arc-flash screen (s) —
/// a moulded-case device clears more slowly than an MCB.
const double _mccbClearingTimeS = 0.2;

/// A small ambient / quiescent enclosure heat allowance (W) added to the summed
/// control-device losses when no explicit `panel.heatW` is given — wiring +
/// breaker losses the device-loss estimate does not capture. Engineering
/// estimate; reported via the enclosure pass's own verifyItems.
const double _baseEnclosureHeatW = 25;

/// The bundled advanced-study result. Each map is keyed by panel id (or circuit
/// id, for the per-circuit passes); a nullable entry means the pass had nothing
/// to report for that key (e.g. a panel with no non-linear load → null harmonics).
class AdvancedStudy {
  /// Protection / fault study (Isc, breaking capacity, Zs/ADS, selectivity).
  final FaultStudyResult fault;

  /// Project supply arrangement (LV direct vs MV + transformer).
  final SupplyDesign supply;

  /// Recommended PLN connected power "daya tersambung" (VA).
  final double recommendedDayaVa;

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

  const AdvancedStudy({
    required this.fault,
    required this.supply,
    required this.recommendedDayaVa,
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
  });
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
///      representative clearing time (MCB 0.05 s / MCCB 0.2 s by the incomer).
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
}) {
  final modelById = {for (final p in project.panels) p.id: p};

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
      final assembly = applyStarterTemplate(
        circuitId: c.id,
        starterType: c.starterType!,
        motorKw: motorKw,
        voltage: panel.voltage,
        variableTorque:
            c.starterType == StarterType.vfd && c.loadKind == LoadKind.pump,
      );
      controlAssemblies[c.id] = assembly;
      for (final d in assembly.devices) {
        heat += d.heatLossW * d.qty;
      }
    }
    controlHeatByPanel[panel.id] = heat;
  }

  // 2 ── Fault study (drives the arc-flash fault levels + breaking-capacity).
  final fault = faultStudy(sys, project, profile);

  // Origin / service-root panel (first root-first id that is utility-fed).
  final originPanelId = _originPanelId(sys, modelById);
  // Feeder distance (m) from the origin SPD to each sub-board (the cumulative
  // feeder-cable run on the path to the panel).
  final feederDistanceM = _feederDistances(sys, project);

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
    final clearingTimeS = panelResult.incomer.breaker.deviceClass.name == 'mccb'
        ? _mccbClearingTimeS
        : _mcbClearingTimeS;
    arcFlash[id] = estimateArcFlash(
      faultkA: Current.kiloamperes(faultkA),
      clearingTimeS: clearingTimeS,
      voltageV: panelModel?.voltage.volts ??
          (panelResult.system == ElectricalSystem.threePhase ? 400 : 230),
    );

    // Harmonics — the VFD-driven (pump/fan) share the kind-only classifier can't
    // see is fed in from the control assemblies on this panel.
    final nlFrac = _nonLinearFraction(panelResult, controlAssemblies);
    final h = estimateHarmonics(panelResult, profile, nonLinearFraction: nlFrac);
    harmonics[id] = h;
    if (h != null && h.thdBand == ThdBand.high) anyHarmonicRich = true;

    // Containment.
    containment[id] = containmentFor(panelResult);

    // Enclosure — explicit panel heat wins; else summed control-device heat + a
    // small base allowance. Floor gear when any VFD/soft-starter is present.
    final explicitHeat = panelModel?.heatW;
    final heatW = explicitHeat != null
        ? explicitHeat.watts
        : (controlHeatByPanel[id] ?? 0) + _baseEnclosureHeatW;
    enclosure[id] = estimateEnclosure(
      panelResult,
      heat: Power(heatW),
      hasFloorGear: _hasFloorGear(panelModel, controlAssemblies),
    );

    // Metering.
    metering[id] = meterFor(panelResult.demandCurrent);

    // SPD — origin board at the service entrance; sub-boards by feeder distance.
    final atOrigin = id == originPanelId;
    spd[id] = recommendSpd(
      atOrigin: atOrigin,
      feederDistanceM: feederDistanceM[id] ?? 0,
      earthingSystem: sys.earthing.system.name,
      hasExternalLps: project.externalLps,
      overheadSupply: project.overheadSupply,
    );
  }

  // 5 ── Project-level passes.
  final supply = determineSupply(
    sys.supply.demandVa,
    dualTransformer: project.dualTransformer,
  );
  final daya = recommendedDayaVa(sys.supply.demandVa, sys.supply.system);
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
      voltage: sys.supply.voltage,
      motors: _gensetMotors(project),
    );
  }

  final bom = buildBom(sys);

  // Aggregate every sub-result's provenance honesty surface.
  final verify = _aggregateVerify([
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
  ]);

  return AdvancedStudy(
    fault: fault,
    supply: supply,
    recommendedDayaVa: daya,
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
  );
}

// ───────────────────────────────────────────────────────────────────────────
// Helpers.
// ───────────────────────────────────────────────────────────────────────────

/// True when a circuit is motor-like (so a starter assembly makes sense).
bool _isMotorLike(ElectricalCircuit c) =>
    c.loadKind == LoadKind.motor ||
    c.loadKind == LoadKind.pump ||
    c.loadKind == LoadKind.hvac;

/// Shaft kW for a motor circuit — the explicit [ElectricalCircuit.motorKw], else
/// the connected load as a kW proxy (so an HVAC way with watts still sizes gear).
double _motorKw(ElectricalCircuit c) =>
    c.motorKw ?? (c.loadW > 0 ? c.loadW / 1000.0 : 0);

/// The origin / service-root panel id: the first root-first panel that takes its
/// supply directly from the utility, else the first id in the solve order.
String? _originPanelId(
  ElectricalSystemResult sys,
  Map<String, ElectricalPanel> modelById,
) {
  for (final id in sys.order) {
    final m = modelById[id];
    if (m != null && m.fedByCircuitId == null) return id;
  }
  return sys.order.isNotEmpty ? sys.order.first : null;
}

/// Cumulative feeder-cable run length (m) from the origin to each panel, walking
/// the feeder tree (a child's distance = its parent's distance + the feeding
/// circuit's run length). Origin panels are 0.
Map<String, double> _feederDistances(
  ElectricalSystemResult sys,
  ElectricalProject project,
) {
  // child panel id -> (parent panel id, feeding circuit length).
  final parentOf = <String, String>{};
  final feederLenM = <String, double>{};
  for (final p in project.panels) {
    for (final c in p.circuits) {
      if (c.feedsPanelId != null) {
        parentOf[c.feedsPanelId!] = p.id;
        feederLenM[c.feedsPanelId!] = c.length.meters;
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

/// The panel's non-linear demand fraction (0–1) for the harmonics estimate,
/// derived from its VFD-fed motor/pump circuits (which the kind-only classifier
/// inside `estimateHarmonics` cannot see). The share is design-current-weighted.
/// Returns null when no VFD circuit is present (let the kind-only classifier
/// — UPS / welding — drive it instead).
double? _nonLinearFraction(
  ElectricalPanelResult panel,
  Map<String, ControlAssembly> controlAssemblies,
) {
  var total = 0.0;
  var vfd = 0.0;
  for (final c in panel.circuits) {
    if (c.loadKind == LoadKind.spare) continue;
    final w = c.designCurrent.amperes;
    total += w;
    final a = controlAssemblies[c.circuitId];
    if (a != null && a.starterType == StarterType.vfd) vfd += w;
  }
  if (vfd <= 0 || total <= 0) return null;
  return vfd / total;
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

/// The motors (for the genset-start voltage-dip screen) — every motor/pump
/// circuit across the project, with its starter string.
List<GensetMotor> _gensetMotors(ElectricalProject project) {
  final motors = <GensetMotor>[];
  for (final p in project.panels) {
    for (final c in p.circuits) {
      if (!_isMotorLike(c)) continue;
      final kw = _motorKw(c);
      if (kw <= 0) continue;
      motors.add(GensetMotor(
        name: c.name,
        shaftPower: Power.kiloWatts(kw),
        starterType: c.starterType == null
            ? null
            : _starterString(c.starterType!),
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
