/// A4 panel / system orchestrator — the pure-Dart heart of the electrical
/// domain. Ported (CORE only) from PanelMaker `engine/{computePanel,
/// computeSystem,phase,busbar}.ts`. Walks the panel feeder tree bottom-up,
/// sizes every circuit with the A3 primitives, balances phases, sizes the
/// incomer + busbar (with section splitting), aggregates diversified demand
/// upstream, accumulates cumulative voltage drop down the tree, and designs the
/// installation earthing system.
///
/// `computePanel` / `computeSystem` are the ONLY constructors of the result
/// types in `panel_results.dart`.
///
/// DEFERRED (markers below): fault/Isc/Zs/ADS, selectivity, capacitor/PF,
/// transformer/MV supply, energy sources, arc-flash, harmonics, containment,
/// enclosure, occupancy demand-factor library, metering, SPD, lightning — all
/// land in A8.
///
/// Zero Flutter imports.
library;

import 'dart:math' as math;

import '../geometry/building.dart';
import '../geometry/scale_calibration.dart';
import '../standards/puil.dart';
import '../units.dart';
import 'busbar.dart';
import 'control/starter.dart' show StarterType;
import 'earthing.dart';
import 'fault.dart' show Impedance, conductorImpedance, downstreamFaultA,
    sourceImpedanceFromIsc;
import 'geo_length.dart';
import 'harmonics.dart' show neutralOversizeFactor;
import 'load_kind.dart';
import 'model.dart';
import 'panel_results.dart';
import 'sizing.dart';

/// Practical building power factor used to convert demand kW → kVA for the
/// supply summary (matches PanelMaker `ASSUMED_BUILDING_PF`). Not a PUIL clause.
const double assumedBuildingPf = 0.85;

// ── phase determination ─────────────────────────────────────────────────────

/// Whether a circuit is supplied three-phase. On a single-phase panel
/// everything is single-phase. A feeder is three-phase (on a 3φ panel); an
/// explicit `phases` choice wins; otherwise motor-like loads go three-phase at
/// or above [motorThreePhaseKw] and other loads above [singlePhaseMaxW].
///
/// Phase is NOT inferred from a starter (a 1φ motor has a DOL contactor too) —
/// only from the rating or the explicit override. Ported from
/// `phase.ts circuitIsThreePhase`.
bool circuitIsThreePhase({
  required ElectricalSystem panelSystem,
  required LoadKind kind,
  required double loadW,
  double? motorKw,
  int? phases,
  bool isFeeder = false,
}) {
  if (panelSystem == ElectricalSystem.singlePhase) return false;
  if (isFeeder || kind == LoadKind.feeder) return true;
  if (phases != null) return phases == 3;
  final def = loadDefaults[kind]!;
  if (def.motorLike) {
    final kw = motorKw ?? loadW / 1000;
    return kw >= motorThreePhaseKw;
  }
  return loadW > singlePhaseMaxW;
}

// ── phase balancing ─────────────────────────────────────────────────────────

/// One circuit's loading for the balancer.
class _PhaseCircuit {
  final String id;
  final bool threePhase;
  final double currentA;
  final PhaseLine? pinned;
  const _PhaseCircuit(this.id, this.threePhase, this.currentA, this.pinned);
}

/// The balance assignment + per-line currents + imbalance.
class PhaseBalance {
  final double l1;
  final double l2;
  final double l3;
  final double imbalancePercent;

  /// circuit id → phase assignment.
  final Map<String, PhaseAssignment> assignment;

  const PhaseBalance({
    required this.l1,
    required this.l2,
    required this.l3,
    required this.imbalancePercent,
    required this.assignment,
  });
}

PhaseAssignment _lineAssign(PhaseLine line) => switch (line) {
      PhaseLine.l1 => PhaseAssignment.l1,
      PhaseLine.l2 => PhaseAssignment.l2,
      PhaseLine.l3 => PhaseAssignment.l3,
    };

/// Distribute single-phase circuits across L1/L2/L3 (greedy LPT + local-search
/// refinement) while three-phase circuits load all phases equally, then report
/// per-phase line current and the imbalance percentage. Pinned circuits keep
/// their line and are excluded from balancing. Ported from `phase.ts
/// balancePhases`.
PhaseBalance balancePhases(
  List<_PhaseCircuit> circuits,
  ElectricalSystem system,
) {
  final phases = <PhaseLine, double>{
    PhaseLine.l1: 0,
    PhaseLine.l2: 0,
    PhaseLine.l3: 0,
  };
  final assignment = <String, PhaseAssignment>{};

  if (system == ElectricalSystem.singlePhase) {
    var l1 = 0.0;
    for (final c in circuits) {
      l1 += c.currentA;
      assignment[c.id] = PhaseAssignment.l1;
    }
    return PhaseBalance(
      l1: roundTo(l1, 1),
      l2: 0,
      l3: 0,
      imbalancePercent: 0,
      assignment: assignment,
    );
  }

  // Three-phase ways load all lines equally.
  for (final c in circuits) {
    if (c.threePhase) {
      phases[PhaseLine.l1] = phases[PhaseLine.l1]! + c.currentA;
      phases[PhaseLine.l2] = phases[PhaseLine.l2]! + c.currentA;
      phases[PhaseLine.l3] = phases[PhaseLine.l3]! + c.currentA;
      assignment[c.id] = PhaseAssignment.threePhase;
    }
  }

  // Pinned single-phase circuits load their line first, verbatim.
  for (final c in circuits) {
    if (c.threePhase || c.pinned == null) continue;
    phases[c.pinned!] = phases[c.pinned!]! + c.currentA;
    assignment[c.id] = _lineAssign(c.pinned!);
  }

  const keys = [PhaseLine.l1, PhaseLine.l2, PhaseLine.l3];
  final singles = circuits
      .where((c) => !c.threePhase && c.pinned == null)
      .toList()
    ..sort((a, b) => b.currentA.compareTo(a.currentA));

  // Greedy least-loaded assignment.
  for (final c in singles) {
    var minLine = PhaseLine.l1;
    for (final p in keys) {
      if (phases[p]! < phases[minLine]!) minLine = p;
    }
    phases[minLine] = phases[minLine]! + c.currentA;
    assignment[c.id] = _lineAssign(minLine);
  }

  PhaseLine fromAssign(PhaseAssignment a) => switch (a) {
        PhaseAssignment.l2 => PhaseLine.l2,
        PhaseAssignment.l3 => PhaseLine.l3,
        _ => PhaseLine.l1,
      };

  double spread() {
    final vals = [phases[PhaseLine.l1]!, phases[PhaseLine.l2]!, phases[PhaseLine.l3]!];
    return vals.reduce(math.max) - vals.reduce(math.min);
  }

  // Local-search refinement: relocate / swap movable singles while the spread
  // shrinks. Only unpinned singles move.
  for (var pass = 0; pass < 40; pass++) {
    var improved = false;
    for (final c in singles) {
      final from = fromAssign(assignment[c.id]!);
      for (final to in keys) {
        if (to == from) continue;
        final before = spread();
        phases[from] = phases[from]! - c.currentA;
        phases[to] = phases[to]! + c.currentA;
        if (spread() < before - 1e-9) {
          assignment[c.id] = _lineAssign(to);
          improved = true;
        } else {
          phases[from] = phases[from]! + c.currentA;
          phases[to] = phases[to]! - c.currentA;
        }
      }
    }
    for (final a in singles) {
      for (final b in singles) {
        final pa = fromAssign(assignment[a.id]!);
        final pb = fromAssign(assignment[b.id]!);
        if (a.id == b.id || pa == pb) continue;
        final before = spread();
        phases[pa] = phases[pa]! + b.currentA - a.currentA;
        phases[pb] = phases[pb]! + a.currentA - b.currentA;
        if (spread() < before - 1e-9) {
          assignment[a.id] = _lineAssign(pb);
          assignment[b.id] = _lineAssign(pa);
          improved = true;
        } else {
          phases[pa] = phases[pa]! - (b.currentA - a.currentA);
          phases[pb] = phases[pb]! - (a.currentA - b.currentA);
        }
      }
    }
    if (!improved) break;
  }

  final vals = [phases[PhaseLine.l1]!, phases[PhaseLine.l2]!, phases[PhaseLine.l3]!];
  final maxV = vals.reduce(math.max);
  final minV = vals.reduce(math.min);
  final avg = (vals[0] + vals[1] + vals[2]) / 3;
  final imbalance = avg > 0 ? ((maxV - minV) / avg) * 100 : 0.0;

  return PhaseBalance(
    l1: roundTo(phases[PhaseLine.l1]!, 1),
    l2: roundTo(phases[PhaseLine.l2]!, 1),
    l3: roundTo(phases[PhaseLine.l3]!, 1),
    imbalancePercent: roundTo(imbalance, 1),
    assignment: assignment,
  );
}

// ── busbar section splitting ────────────────────────────────────────────────

/// One outgoing way's loading, for grouping ways onto busbar sections.
class _BusbarWayLoad {
  final String id;
  final double designCurrentA;
  final bool threePhase;
  final PhaseAssignment phase;
  final bool breakBefore;
  const _BusbarWayLoad(
    this.id,
    this.designCurrentA,
    this.threePhase,
    this.phase,
    this.breakBefore,
  );
}

/// Worst-loaded phase's line current for a group of ways (A).
double _sectionWorstPhaseA(List<_BusbarWayLoad> ways, ElectricalSystem system) {
  if (system != ElectricalSystem.threePhase) {
    return ways.fold(0.0, (s, w) => s + w.designCurrentA);
  }
  var l1 = 0.0, l2 = 0.0, l3 = 0.0;
  for (final w in ways) {
    if (w.threePhase) {
      l1 += w.designCurrentA;
      l2 += w.designCurrentA;
      l3 += w.designCurrentA;
    } else if (w.phase == PhaseAssignment.l2) {
      l2 += w.designCurrentA;
    } else if (w.phase == PhaseAssignment.l3) {
      l3 += w.designCurrentA;
    } else {
      l1 += w.designCurrentA;
    }
  }
  return math.max(l1, math.max(l2, l3));
}

/// Divide a panel's outgoing ways into capacity-bounded busbar sections (max
/// ways / max worst-phase current / manual break). Each section is sized for the
/// worst-phase current of the ways it carries and is fed radially from the
/// incomer (so per-group sizing is valid). Always returns ≥ 1 section. Ported
/// from `busbar.ts splitBusbarSections`.
List<BusbarSectionResult> splitBusbarSections(
  ElectricalStandardsProfile profile,
  List<_BusbarWayLoad> ways, {
  required int maxWays,
  required Current maxSectionCurrentA,
  required ElectricalSystem system,
  double minCsaMm2 = 0,
  double faultKa = 0,
  double clearingTimeS = busbarDefaultClearingTimeS,
}) {
  final cap = math.max(1, maxWays);
  final sections = <BusbarSectionResult>[];
  var group = <_BusbarWayLoad>[];
  var groupManual = false;

  void flush() {
    if (group.isEmpty) return;
    final currentA = roundTo(_sectionWorstPhaseA(group, system), 1);
    sections.add(BusbarSectionResult(
      index: sections.length + 1,
      circuitIds: group.map((w) => w.id).toList(),
      ways: group.length,
      sectionCurrent: Current(currentA),
      busbar: sizeBusbar(profile, Current(currentA),
          minCsaMm2: minCsaMm2, faultKa: faultKa, clearingTimeS: clearingTimeS),
      manualBreak: groupManual,
    ));
    group = [];
    groupManual = false;
  }

  for (final w in ways) {
    final manual = w.breakBefore;
    if (group.isNotEmpty) {
      final overWays = group.length + 1 > cap;
      final overCurrent =
          _sectionWorstPhaseA([...group, w], system) > maxSectionCurrentA.amperes;
      if (manual || overWays || overCurrent) {
        flush();
        if (manual) groupManual = true;
      }
    }
    group.add(w);
  }
  flush();

  if (sections.isEmpty) {
    sections.add(BusbarSectionResult(
      index: 1,
      circuitIds: const [],
      ways: 0,
      sectionCurrent: const Current(0),
      busbar: sizeBusbar(profile, const Current(0)),
      manualBreak: false,
    ));
  }
  return sections;
}

// ── per-circuit computation ─────────────────────────────────────────────────

/// Options threaded into `computePanel` by `computeSystem`.
class ComputePanelOptions {
  /// Aggregated downstream diversified demand (W) keyed by the child panel id a
  /// feeder serves.
  final Map<String, double> feederLoadW;

  /// Each panel's system, so a feeder follows the panel it FEEDS.
  final Map<String, ElectricalSystem> panelSystems;

  /// Installation earthing system (drives RCD policy).
  final EarthingSystem earthingSystem;

  /// Prospective 3-phase symmetrical fault current at this panel's bus (A),
  /// propagated down the feeder tree by `computeSystem`. When > 0 the busbar
  /// short-circuit-withstand fold (FOLD 1) floors the bar's cross-section at the
  /// fault's Icw demand; null/0 ⇒ no withstand floor (byte-identical sizing).
  final Current? faultLevelA;

  /// Representative protective-device clearing time (s) for the busbar Icw check
  /// (a fault clears within this time, so Icw scales by 1/√t). Defaults to the
  /// conventional 1-second assembly-Icw basis.
  final double busbarClearingTimeS;

  /// Site soil thermal resistivity (K·m/W) — derates buried runs.
  final double? soilThermalResistivityKmW;

  // ── Geo cable-length inputs (additive; omitted ⇒ manual lengths) ───────────
  /// Per-sheet pixel↔metre calibration for geo-derived cable length. Empty (the
  /// default) ⇒ every circuit uses its manual [ElectricalCircuit.length], so the
  /// computation is byte-identical to a non-geo project.
  final Map<String, ScaleCalibration> calibrationBySheet;

  /// Building floor elevations for the vertical (riser/drop) component of a
  /// geo cable run (§10). Null ⇒ geo length is not resolved (manual length wins).
  final BuildingLevels? building;

  /// All project panels keyed by id, so a feeder's geo length can target the
  /// fed sub-panel's [ElectricalPanel.layoutPos] (panel→sub-panel run). Empty ⇒
  /// feeders fall back to their manual length.
  final Map<String, ElectricalPanel> panelById;

  const ComputePanelOptions({
    this.feederLoadW = const {},
    this.panelSystems = const {},
    this.earthingSystem = EarthingSystem.tnCs,
    this.faultLevelA,
    this.busbarClearingTimeS = busbarDefaultClearingTimeS,
    this.soilThermalResistivityKmW,
    this.calibrationBySheet = const {},
    this.building,
    this.panelById = const {},
  });
}

/// A circuit's effective install method: a per-run laying override wins over the
/// panel method ('ground' → buried; 'air' → above-ground even if the panel is
/// buried). Drives both the ampacity table and the temperature derating basis.
CableInstallMethod _effectiveInstallMethod(
    ElectricalCircuit c, ElectricalPanel panel) {
  if (c.laying == 'ground') return CableInstallMethod.buried;
  if (c.laying == 'air' && panel.installMethod == CableInstallMethod.buried) {
    return CableInstallMethod.conduit;
  }
  return panel.installMethod;
}

/// A leaf circuit's connected demand (W): motor kW ×1000 for motors, else
/// connected W, times the demand factor. Ported from `computePanel.ts
/// circuitConnectedW`.
double circuitConnectedW(ElectricalCircuit c) {
  final isMotor =
      (c.loadKind == LoadKind.motor || c.loadKind == LoadKind.pump) &&
          c.motorKw != null;
  final baseW = isMotor ? c.motorKw! * 1000 : c.loadW;
  return baseW * c.demandFactor;
}

double _effectiveLoadW(ElectricalCircuit c, ComputePanelOptions opts) {
  if (c.feedsPanelId != null && opts.feederLoadW.containsKey(c.feedsPanelId)) {
    return opts.feederLoadW[c.feedsPanelId]!;
  }
  return circuitConnectedW(c);
}

/// The panel's SINGLE-PHASE non-linear demand share (0–1) for the triplen-
/// neutral oversize (FOLD 2): the design-current-weighted fraction of the
/// panel's load that is single-phase AND non-linear (the triplen harmonics that
/// sum arithmetically in the shared neutral). Spare ways carry no load. Mirrors
/// PanelMaker `computeHarmonics` singlePhaseFraction. 0 ⇒ no oversize.
double _singlePhaseNonLinearFraction(List<_CircuitComputation> comps) {
  var total = 0.0;
  var singlePhaseNonLinear = 0.0;
  for (final cm in comps) {
    if (cm.result.loadKind == LoadKind.spare) continue;
    final w = math.max(0.0, cm.result.designCurrent.amperes);
    total += w;
    if (cm.nonLinear && !cm.threePhase) singlePhaseNonLinear += w;
  }
  if (total <= 0) return 0;
  return roundTo(singlePhaseNonLinear / total, 3);
}

/// Format a double without a trailing `.0` for whole numbers (warning text only).
String _num(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// Internal per-circuit computation bundle.
class _CircuitComputation {
  final ElectricalCircuitResult result;
  final List<ElectricalWarning> warnings;
  final double effectiveLoadW;
  final bool threePhase;

  /// True when the circuit draws non-linear (harmonic-rich) current — a VFD /
  /// soft-starter motor front-end, or a UPS / welding rectifier load. Drives the
  /// panel's triplen-neutral oversize (FOLD 2). Mirrors PanelMaker `isNonLinear`.
  final bool nonLinear;

  const _CircuitComputation(
      this.result, this.warnings, this.effectiveLoadW, this.threePhase,
      this.nonLinear);
}

/// Whether a circuit draws non-linear current (harmonic-rich): a VFD or
/// soft-starter motor front-end, or a UPS / welding rectifier load. DOL /
/// star-delta / reversing motors are linear inductive loads (not counted).
/// Faithful to PanelMaker `engine/harmonics.ts isNonLinear`.
bool _circuitIsNonLinear(ElectricalCircuit c) =>
    c.starterType == StarterType.vfd ||
    c.starterType == StarterType.softStarter ||
    c.loadKind == LoadKind.ups ||
    c.loadKind == LoadKind.welding;

_CircuitComputation _computeCircuit(
  ElectricalStandardsProfile profile,
  ElectricalCircuit c,
  ElectricalPanel panel,
  double df,
  ComputePanelOptions opts,
) {
  final loadW = _effectiveLoadW(c, opts);
  final def = loadDefaults[c.loadKind]!;
  final isFeeder = c.isFeeder;
  final warnings = <ElectricalWarning>[];

  // Effective run length: geo-derived when this circuit + the panel are placed
  // on the calibrated layout (and `building`/`calibrationBySheet` were supplied),
  // else the manual `c.length`. With the default (empty) geo inputs this is
  // exactly `c.length`, so non-geo projects compute identically.
  final effectiveLength = opts.building == null
      ? c.length
      : resolveCircuitLength(
          c,
          panel,
          calibrationBySheet: opts.calibrationBySheet,
          building: opts.building!,
          panelById: opts.panelById,
        );

  // A feeder's phase follows the panel it FEEDS: a single-phase sub-board takes
  // a single-phase feeder even from a three-phase parent.
  final fedSystem =
      c.feedsPanelId != null ? opts.panelSystems[c.feedsPanelId] : null;
  final threePhase = fedSystem == ElectricalSystem.singlePhase
      ? false
      : circuitIsThreePhase(
          panelSystem: panel.system,
          kind: c.loadKind,
          loadW: loadW,
          motorKw: c.motorKw,
          phases: c.phases,
          isFeeder: isFeeder,
        );

  // Single-phase circuits on a three-phase panel run at the phase voltage (~230).
  final phaseVoltageV = panel.system == ElectricalSystem.threePhase
      ? roundTo(panel.voltage.volts / math.sqrt(3), 0)
      : panel.voltage.volts;
  final useVoltageV = threePhase ? panel.voltage.volts : phaseVoltageV;

  // Design current: a source-supplied FLA wins (A5); a motor approximates via
  // P = motorKw·1000 (TODO motor FLC table (A8)); else loadCurrent.
  final motorLike =
      (c.loadKind == LoadKind.motor || c.loadKind == LoadKind.pump) &&
          c.motorKw != null;
  final Current ib;
  if (c.flaOverrideA != null) {
    ib = c.flaOverrideA!;
  } else if (motorLike) {
    // TODO motor FLC table (A8) — approximate the FLC from the shaft kW.
    ib = loadCurrent(
      power: Power.kiloWatts(c.motorKw!),
      voltage: Voltage(useVoltageV),
      cosPhi: c.cosPhi,
      threePhase: threePhase,
    );
  } else {
    ib = loadCurrent(
      power: Power(loadW),
      voltage: Voltage(useVoltageV),
      cosPhi: c.cosPhi,
      threePhase: threePhase,
    );
  }
  final designCurrent = Current(roundTo(ib.amperes, 1));

  final breaker = selectBreaker(
    profile,
    designCurrent: ib,
    loadKind: c.loadKind,
    overrideA: c.breakerOverrideA,
  );

  // PUIL minimums: trunk (incomer/feeder) → 4 (3φ) / 2.5; final → lighting 1.5
  // else 2.5. A manual cable minimum floors it.
  final isTrunk = c.role == CircuitRole.incomer || isFeeder;
  final baseMin = profile.minSectionMm2(
    lighting: c.isLighting,
    trunk: isTrunk,
    threePhase: threePhase,
  );
  final minSection = math.max(baseMin, c.cableOverrideMm2 ?? 0);

  final installMethod = _effectiveInstallMethod(c, panel);

  final cable = sizeCable(
    profile,
    designCurrent: ib,
    breakerRating: breaker.ratingA,
    deratingFactor: df,
    minSectionMm2: minSection,
    insulation: panel.insulation,
    material: panel.material,
    method: installMethod,
    threePhase: threePhase,
    vd: CableVoltageDropConstraint(
      length: effectiveLength,
      cosPhi: c.cosPhi,
      threePhase: threePhase,
      voltage: Voltage(useVoltageV),
      isLighting: c.isLighting,
    ),
  );

  final runsPerPhase = cable.runsPerPhase ?? 1;
  final vd = voltageDrop(
    profile,
    current: Current(ib.amperes / runsPerPhase),
    length: effectiveLength,
    csaMm2: cable.csaMm2,
    cosPhi: c.cosPhi,
    threePhase: threePhase,
    voltage: Voltage(useVoltageV),
    isLighting: c.isLighting,
    material: panel.material,
  );

  // Cores follow the load's neutral need: every 1φ final carries its neutral;
  // 3φ motors/resistive line loads are 4-core (no N), other 3φ loads 5-core.
  final hasNeutral = threePhase ? def.needsNeutral && !def.motorLike : true;
  final grounding = sizeGrounding(
    profile,
    phaseCsaMm2: cable.csaMm2,
    threePhase: threePhase,
    hasNeutral: hasNeutral,
    runsPerPhase: runsPerPhase,
    cableType: c.cableType,
  );

  final rcd = circuitRcd(
    earthingSystem: opts.earthingSystem,
    loadKind: c.loadKind,
    isFinalCircuit: !isFeeder,
    designCurrent: designCurrent,
    lifeSafety: c.lifeSafety,
  );

  // A life-safety run with an explicit non-FRC construction is a spec error.
  if (c.lifeSafety && c.cableType != null && c.cableType != 'FRC') {
    warnings.add(ElectricalWarning(
      code: 'life-safety-cable',
      severity: WarningSeverity.warning,
      message:
          '${c.name}: life-safety circuit specified with ${c.cableType} — use '
          'fire-resistant cable (FRC/MICA) so the run survives a fire.',
      panelId: panel.id,
      circuitId: c.id,
    ));
  }
  // A single-phase motor above ~4 kW is impractical.
  if (motorLike && !threePhase && (c.motorKw ?? 0) > 4) {
    warnings.add(ElectricalWarning(
      code: 'single-phase-large-motor',
      severity: WarningSeverity.warning,
      message:
          '${c.name}: ${c.motorKw} kW on single phase is impractical — supply '
          'it three-phase or confirm the machine rating.',
      panelId: panel.id,
      circuitId: c.id,
    ));
  }
  // The auto-sized cable normally holds the drop within limit by construction;
  // a residual over-limit is the genuinely-impossible (max-section) case.
  if (!vd.withinLimit) {
    warnings.add(ElectricalWarning(
      code: 'voltage-drop-exceeded',
      severity: WarningSeverity.warning,
      message:
          '${c.name}: voltage drop ${vd.dropPercent}% exceeds the '
          '${vd.limitPercent}% limit even at the largest standard section — '
          'shorten the run or split the load.',
      panelId: panel.id,
      circuitId: c.id,
    ));
  }

  final result = ElectricalCircuitResult(
    circuitId: c.id,
    name: c.name,
    loadKind: c.loadKind,
    designCurrent: designCurrent,
    threePhase: threePhase,
    // single-phase assignment is finalised after balancing.
    phase: threePhase ? PhaseAssignment.threePhase : PhaseAssignment.l1,
    breaker: breaker,
    cable: cable,
    voltageDrop: vd,
    cumulativeDropPercent: vd.dropPercent,
    grounding: grounding,
    rcd: rcd,
  );

  return _CircuitComputation(
      result, warnings, loadW, threePhase, _circuitIsNonLinear(c));
}

// ── panel computation ───────────────────────────────────────────────────────

/// Compute all CORE sizing — per-circuit, phase balance, incomer, busbar (main
/// + sections), neutral/PE bars, demand — for one panel. The ONLY constructor of
/// [ElectricalPanelResult]. Ported from `computePanel.ts` (core slice).
ElectricalPanelResult computePanel(
  ElectricalStandardsProfile profile,
  ElectricalPanel panel, {
  ComputePanelOptions opts = const ComputePanelOptions(),
}) {
  final branches =
      panel.circuits.where((c) => c.role == CircuitRole.branch).toList();

  double dfFor(ElectricalCircuit c) => deratingFactor(
        profile,
        ambientC: panel.ambientTempC,
        groupingCount: c.groupingCountOverride ?? panel.groupingCount,
        method: _effectiveInstallMethod(c, panel),
        insulation: panel.insulation,
        soilThermalResistivityKmW: opts.soilThermalResistivityKmW,
        groundTempC: panel.groundTempC,
        depthM: panel.depthM,
      );

  final comps =
      branches.map((c) => _computeCircuit(profile, c, panel, dfFor(c), opts)).toList();

  // Balance single-phase circuits across L1/L2/L3; pinned phases are honoured.
  final balance = balancePhases(
    [
      for (var i = 0; i < comps.length; i++)
        _PhaseCircuit(
          comps[i].result.circuitId,
          comps[i].threePhase,
          comps[i].result.designCurrent.amperes,
          branches[i].phaseOverride,
        ),
    ],
    panel.system,
  );

  final warnings = <ElectricalWarning>[];
  var connectedW = 0.0;
  final circuits = <ElectricalCircuitResult>[];
  for (final cm in comps) {
    connectedW += cm.effectiveLoadW;
    warnings.addAll(cm.warnings);
    circuits.add(cm.result.copyWith(
      phase: balance.assignment[cm.result.circuitId] ?? cm.result.phase,
    ));
  }

  if (panel.system == ElectricalSystem.threePhase &&
      balance.imbalancePercent > 15) {
    warnings.add(ElectricalWarning(
      code: 'phase-imbalance',
      severity: WarningSeverity.warning,
      message:
          'Phase loading is unbalanced by ${balance.imbalancePercent}% '
          '(L1 ${balance.l1} A, L2 ${balance.l2} A, L3 ${balance.l3} A). '
          'Redistribute single-phase circuits.',
      panelId: panel.id,
    ));
  }

  // Busbar / incomer carry the worst-loaded phase's line current.
  final demandCurrentA = roundTo(
    panel.system == ElectricalSystem.threePhase
        ? math.max(balance.l1, math.max(balance.l2, balance.l3))
        : balance.l1,
    1,
  );

  final incomerBreaker = selectBreaker(
    profile,
    designCurrent: Current(demandCurrentA),
    loadKind: LoadKind.feeder,
  );
  final incomer = IncomerResult(
    breaker: incomerBreaker,
    poles: panel.system == ElectricalSystem.threePhase ? 4 : 2,
  );
  if (incomerBreaker.ratingA.amperes + 1e-9 < demandCurrentA) {
    warnings.add(ElectricalWarning(
      code: 'incomer-exceeds-range',
      severity: WarningSeverity.error,
      message:
          '${panel.name}: demand $demandCurrentA A exceeds the largest standard '
          'breaker frame (${incomerBreaker.ratingA.amperes} A) — split the board '
          'or feed it at MV.',
      panelId: panel.id,
    ));
  }

  // FOLD 1 — busbar short-circuit withstand: when the prospective fault at this
  // bus is known (propagated by `computeSystem`), the bar (main + every section)
  // is floored at the cross-section the fault's Icw demands, so it grows to
  // SURVIVE the fault, not merely carry the load. faultKa = 0 ⇒ no floor.
  final faultKa = opts.faultLevelA != null && opts.faultLevelA!.amperes > 0
      ? opts.faultLevelA!.amperes / 1000.0
      : 0.0;
  final clearingTimeS = opts.busbarClearingTimeS;

  // Main bus rated for the incoming device (IEC 61439-1), not just demand.
  final busbar = sizeBusbar(
    profile,
    Current(demandCurrentA),
    minAmpacityA: incomerBreaker.ratingA,
    faultKa: faultKa,
    clearingTimeS: clearingTimeS,
  );

  // FOLD 2 — harmonics triplen-neutral oversize: a panel whose SINGLE-PHASE
  // non-linear (VFD/soft-starter/UPS/welding) share crosses the triplen
  // threshold carries summed 3rd-harmonic current in the shared neutral that can
  // exceed the phase current, so the neutral bar is oversized (IEC 60364-5-52
  // §523.6.3 / Annex E). A linear panel has no non-linear load ⇒ factor 1.0 ⇒
  // the neutral is byte-identical to the phase bar (the regression guard).
  final triplenFraction = _singlePhaseNonLinearFraction(comps);
  final nFactor = roundTo(neutralOversizeFactor(triplenFraction), 2);
  final neutralPe = sizeNeutralPeBars(
    busbar.csaMm2,
    busbar.ampacityA,
    profile: profile,
    neutralOversizeFactor: nFactor,
    triplenFraction: triplenFraction,
  );

  // Split the panel bus into capacity-bounded sections (each floored at the same
  // withstand cross-section as the main bus — a smaller section bar can fail
  // withstand even when the main bus passes).
  final busbarSections = splitBusbarSections(
    profile,
    [
      for (var i = 0; i < comps.length; i++)
        _BusbarWayLoad(
          comps[i].result.circuitId,
          comps[i].result.designCurrent.amperes,
          comps[i].threePhase,
          () {
            final a = balance.assignment[comps[i].result.circuitId];
            return a == PhaseAssignment.l2 || a == PhaseAssignment.l3
                ? a!
                : PhaseAssignment.l1;
          }(),
          branches[i].busbarBreakBefore,
        ),
    ],
    maxWays: profile.maxWaysPerBusbar,
    maxSectionCurrentA: profile.maxBusbarSectionCurrentA,
    system: panel.system,
    faultKa: faultKa,
    clearingTimeS: clearingTimeS,
  );

  // Warn when even the largest standard bar cannot withstand the fault.
  if (busbar.withstand != null && !busbar.withstand!.adequate) {
    warnings.add(ElectricalWarning(
      code: 'busbar-withstand-inadequate',
      severity: WarningSeverity.error,
      message:
          '${panel.name}: even the largest standard bar (${busbar.csaMm2} mm², '
          'Icw ${busbar.withstand!.icwKa} kA) is below the '
          '${busbar.withstand!.faultKa} kA prospective fault — use parallel '
          'bars, brace the run, or add upstream current limiting.',
      panelId: panel.id,
    ));
  }
  // A section bar carries its own (smaller) load, so it can fail withstand even
  // when the main bus passes — warn per inadequate section.
  for (final section in busbarSections) {
    final w = section.busbar.withstand;
    if (w != null && !w.adequate) {
      final where = busbarSections.length > 1
          ? '${panel.name} busbar section ${section.index}'
          : panel.name;
      warnings.add(ElectricalWarning(
        code: 'busbar-withstand-inadequate',
        severity: WarningSeverity.error,
        message:
            '$where: bar ${section.busbar.csaMm2} mm² (Icw ${w.icwKa} kA) is '
            'below the ${w.faultKa} kA prospective fault — use parallel bars, '
            'brace the run, or add upstream current limiting.',
        panelId: panel.id,
      ));
    }
  }
  // Surface the harmonic neutral oversize (a recommendation that never reaches
  // the schedule does not get built).
  if (neutralPe.neutralOversizeFactor > 1) {
    warnings.add(ElectricalWarning(
      code: 'harmonics-neutral-oversize',
      severity: WarningSeverity.warning,
      message:
          '${panel.name}: single-phase non-linear load '
          '(${(triplenFraction * 100).round()}%) raises triplen-harmonic '
          'neutral current to ~${neutralPe.neutralOversizeFactor}x phase — '
          'neutral bar oversized to ${_num(neutralPe.neutralCsaMm2)} mm² '
          '(phase bar ${_num(busbar.csaMm2)} mm²).',
      panelId: panel.id,
    ));
  }

  final demandW = connectedW * panel.diversityFactor;

  return ElectricalPanelResult(
    panelId: panel.id,
    name: panel.name,
    tag: panel.tag,
    system: panel.system,
    circuits: circuits,
    incomer: incomer,
    busbar: busbar,
    busbarSections: busbarSections,
    neutralPeBars: neutralPe,
    connectedW: roundTo(connectedW, 0),
    demandW: roundTo(demandW, 0),
    demandCurrent: Current(demandCurrentA),
    phaseBalance: PhaseBalanceResult(
      l1: balance.l1,
      l2: balance.l2,
      l3: balance.l3,
      imbalancePercent: balance.imbalancePercent,
    ),
    warnings: warnings,
  );
}

// ── system computation ──────────────────────────────────────────────────────

/// Compute a whole project (building): walk the panel feeder tree bottom-up so a
/// feeder circuit carries its child panel's diversified demand, then accumulate
/// the cumulative origin→load voltage drop down the tree and design the earthing
/// system. The ONLY constructor of [ElectricalSystemResult]. Ported from
/// `computeSystem.ts` (core slice).
///
/// The cumulative voltage-drop pass and earthing design run as before.
///
/// FOLD 1 (busbar withstand) is OPT-IN: pass [originFaultLevel] (the prospective
/// 3-phase symmetrical fault the supply origin delivers, default null) to
/// propagate Isc root→leaf down the feeder tree (decaying through each already-
/// sized feeder cable's series impedance, exactly as `faultStudy` does) and
/// floor every panel's busbar (main + sections) at the cross-section the fault's
/// short-circuit withstand (Icw) demands. With the default `null` no withstand
/// floor is applied and the busbars are byte-identical to before — the
/// regression guard for projects that don't request the fault-withstand fold.
/// [busbarClearingTimeS] sets the Icw fault duration (default 1 s).
///
/// FOLD 2 (harmonics triplen-neutral oversize) is ALWAYS-ON but self-guarding:
/// a panel with no single-phase non-linear load gets factor 1.0 ⇒ its neutral
/// bar is byte-identical to the phase bar.
ElectricalSystemResult computeSystem(
  ElectricalStandardsProfile profile,
  ElectricalProject project, {
  Map<String, ScaleCalibration> calibrationBySheet = const {},
  BuildingLevels? building,
  Current? originFaultLevel,
  double busbarClearingTimeS = busbarDefaultClearingTimeS,
}) {
  final panels = project.panels;
  final byId = {for (final p in panels) p.id: p};
  final warnings = <ElectricalWarning>[];

  // child panel id -> parent panel id.
  final parentOf = <String, String>{};
  for (final p in panels) {
    for (final c in p.circuits) {
      if (c.feedsPanelId != null) parentOf[c.feedsPanelId!] = p.id;
    }
  }

  // Each panel's system, so feeders follow the panel they feed.
  final panelSystems = {for (final p in panels) p.id: p.system};
  for (final entry in parentOf.entries) {
    final child = byId[entry.key];
    final parent = byId[entry.value];
    if (child?.system == ElectricalSystem.threePhase &&
        parent?.system == ElectricalSystem.singlePhase) {
      warnings.add(ElectricalWarning(
        code: 'feeder-phase-mismatch',
        severity: WarningSeverity.error,
        message:
            '${child!.name}: a three-phase panel cannot be fed from the '
            'single-phase ${parent!.name} — change a panel system or re-parent '
            'the feeder.',
        panelId: child.id,
      ));
    }
  }

  // Post-order DFS from roots (children before parents) + cycle detection.
  final visited = <String>{};
  final inStack = <String>{};
  final postOrder = <String>[];
  var cycle = false;

  List<ElectricalPanel> childrenOf(String id) =>
      panels.where((p) => parentOf[p.id] == id).toList();

  void dfs(String id) {
    if (inStack.contains(id)) {
      cycle = true;
      return;
    }
    if (visited.contains(id)) return;
    inStack.add(id);
    for (final child in childrenOf(id)) {
      dfs(child.id);
    }
    inStack.remove(id);
    visited.add(id);
    postOrder.add(id);
  }

  final roots = panels.where((p) => !parentOf.containsKey(p.id)).toList();
  for (final r in roots) {
    dfs(r.id);
  }
  // Anything unreached is inside a cycle (no valid root).
  for (final p in panels) {
    if (!visited.contains(p.id)) {
      cycle = true;
      postOrder.add(p.id);
      visited.add(p.id);
    }
  }
  if (cycle) {
    warnings.add(const ElectricalWarning(
      code: 'feeder-cycle',
      severity: WarningSeverity.error,
      message:
          'Feeder topology contains a cycle; system aggregation may be incomplete.',
    ));
  }

  // Bottom-up diversified demand: a feeder's effective load = the child panel's
  // diversified demand (connectedW × diversity). Demand depends only on
  // connected load, so it is summed cheaply here ahead of the full sizing.
  final feederLoadWByPanel = <String, Map<String, double>>{};
  final panelDemandW = <String, double>{};
  for (final id in postOrder) {
    final panel = byId[id];
    if (panel == null) continue;
    final feederLoadW = <String, double>{};
    var connectedW = 0.0;
    for (final c in panel.circuits) {
      if (c.role != CircuitRole.branch) continue;
      final load = c.feedsPanelId != null
          ? (panelDemandW[c.feedsPanelId] ?? 0)
          : circuitConnectedW(c);
      if (c.feedsPanelId != null) feederLoadW[c.feedsPanelId!] = load;
      connectedW += load;
    }
    feederLoadWByPanel[id] = feederLoadW;
    panelDemandW[id] = connectedW * panel.diversityFactor;
  }

  // True building connected load = leaf loads only (feeders are aggregations).
  var connectedLoadW = 0.0;
  for (final p in panels) {
    for (final c in p.circuits) {
      if (c.role == CircuitRole.branch && c.feedsPanelId == null) {
        connectedLoadW += circuitConnectedW(c);
      }
    }
  }

  // FOLD 1 — prospective-fault propagation (only when an origin fault is given).
  // Root-first, so a parent's bus fault + source impedance are known before its
  // child's: the child decays the parent fault through the feeder cable's series
  // impedance, exactly as `faultStudy`. The feeder's sized CSA comes from the
  // parent result (already computed in this root-first loop). child id → fault A.
  final applyWithstand =
      originFaultLevel != null && originFaultLevel.amperes > 0;
  final originIscA = applyWithstand ? originFaultLevel.amperes : 0.0;
  final panelFaultA = <String, double>{};
  final panelSourceZ = <String, Impedance>{};

  // The feeder circuit id feeding each child panel (parent way).
  final feederCircuitOf = <String, String>{}; // child panel id → feeder id
  for (final p in panels) {
    for (final c in p.circuits) {
      if (c.feedsPanelId != null) feederCircuitOf[c.feedsPanelId!] = c.id;
    }
  }

  // Size every panel (root-first is fine for the core; demand is precomputed).
  final results = <String, ElectricalPanelResult>{};
  for (final id in postOrder.reversed) {
    final panel = byId[id];
    if (panel == null) continue;

    // Prospective fault + source impedance at this bus (FOLD 1), when enabled.
    Current? faultLevelA;
    if (applyWithstand) {
      final lineVoltageV = panel.voltage.volts;
      final parentId = parentOf[id];
      final feederId = feederCircuitOf[id];
      final double faultA;
      final Impedance sourceZ;
      if (parentId == null || feederId == null) {
        // Root / utility-fed panel — the full origin fault.
        faultA = originIscA;
        sourceZ = sourceImpedanceFromIsc(originIscA, lineVoltageV);
      } else {
        final upstreamIscA = panelFaultA[parentId] ?? originIscA;
        final upstreamSourceZ = panelSourceZ[parentId] ??
            sourceImpedanceFromIsc(originIscA, lineVoltageV);
        final feederResult = results[parentId]
            ?.circuits
            .where((c) => c.circuitId == feederId)
            .firstOrNull;
        final feederModel =
            byId[parentId]?.circuits.where((c) => c.id == feederId).firstOrNull;
        final csa = feederResult?.cable.csaMm2 ?? 0;
        final runs = (feederResult?.cable.runsPerPhase ?? 1) > 1
            ? feederResult!.cable.runsPerPhase!
            : 1;
        final lengthM = feederModel?.length.meters ?? 0;
        final single =
            conductorImpedance(profile, csa, lengthM, panel.material);
        final feederZ = Impedance(single.rOhm / runs, single.xOhm / runs);
        sourceZ = upstreamSourceZ + feederZ;
        faultA = downstreamFaultA(lineVoltageV, sourceZ, upstreamIscA);
      }
      panelFaultA[id] = faultA;
      panelSourceZ[id] = sourceZ;
      faultLevelA = Current(faultA);
    }

    results[id] = computePanel(
      profile,
      panel,
      opts: ComputePanelOptions(
        feederLoadW: feederLoadWByPanel[id] ?? const {},
        panelSystems: panelSystems,
        earthingSystem: project.earthingSystem,
        faultLevelA: faultLevelA,
        busbarClearingTimeS: busbarClearingTimeS,
        calibrationBySheet: calibrationBySheet,
        building: building,
        panelById: byId,
      ),
    );
  }

  // Cumulative (origin → load) voltage drop down the feeder tree, root-first.
  final panelUpstreamDropPct = <String, double>{};
  for (final id in postOrder.reversed) {
    final parentId = parentOf[id];
    var upstream = 0.0;
    if (parentId != null) {
      final parent = byId[parentId];
      final feeder =
          parent?.circuits.where((c) => c.feedsPanelId == id).firstOrNull;
      final feederResult = results[parentId]
          ?.circuits
          .where((c) => c.circuitId == feeder?.id)
          .firstOrNull;
      upstream = (panelUpstreamDropPct[parentId] ?? 0) +
          (feederResult?.voltageDrop.dropPercent ?? 0);
    }
    upstream = roundTo(upstream, 2);
    panelUpstreamDropPct[id] = upstream;

    final pr = results[id];
    if (pr == null) continue;
    // Feeder circuit ids in this panel — their cumulative drop is the sub-bus
    // drop downstream branches already account for, so don't warn on them.
    final feederIds = (byId[id]?.circuits ?? const <ElectricalCircuit>[])
        .where((c) => c.feedsPanelId != null)
        .map((c) => c.id)
        .toSet();
    final newCircuits = <ElectricalCircuitResult>[];
    for (final c in pr.circuits) {
      final cum = roundTo(upstream + c.voltageDrop.dropPercent, 2);
      newCircuits.add(c.copyWith(cumulativeDropPercent: cum));
      if (!feederIds.contains(c.circuitId) &&
          cum > c.voltageDrop.limitPercent + 1e-9) {
        final w = ElectricalWarning(
          code: 'cumulative-voltage-drop-exceeded',
          severity: WarningSeverity.warning,
          message:
              '${c.name}: cumulative voltage drop $cum% from the origin exceeds '
              'the ${c.voltageDrop.limitPercent}% limit (this run '
              '${c.voltageDrop.dropPercent}% + $upstream% upstream) — shorten '
              'the run, upsize the feeder, or relocate the load.',
          panelId: id,
          circuitId: c.circuitId,
        );
        pr.warnings.add(w);
        warnings.add(w);
      }
    }
    // Replace with the cumulative-drop-annotated circuits (in place).
    results[id] = ElectricalPanelResult(
      panelId: pr.panelId,
      name: pr.name,
      tag: pr.tag,
      system: pr.system,
      circuits: newCircuits,
      incomer: pr.incomer,
      busbar: pr.busbar,
      busbarSections: pr.busbarSections,
      neutralPeBars: pr.neutralPeBars,
      connectedW: pr.connectedW,
      demandW: pr.demandW,
      demandCurrent: pr.demandCurrent,
      phaseBalance: pr.phaseBalance,
      warnings: pr.warnings,
    );
  }

  // Collect every panel's warnings into the system list (after augmentation).
  for (final id in postOrder.reversed) {
    final pr = results[id];
    if (pr == null) continue;
    for (final w in pr.warnings) {
      // Cumulative-drop warnings were already added above; skip duplicates.
      if (w.code == 'cumulative-voltage-drop-exceeded') continue;
      warnings.add(w);
    }
  }

  // Supply summary from the diversified demand presented by the root panel(s).
  final rootDemandW =
      roots.fold(0.0, (s, p) => s + (panelDemandW[p.id] ?? 0));
  final supplySystem = roots.firstOrNull?.system ?? ElectricalSystem.threePhase;
  final supplyVoltage = roots.firstOrNull?.voltage ?? const Voltage(400);
  final supply = SupplySummary(
    connectedW: roundTo(connectedLoadW, 0),
    demandW: roundTo(rootDemandW, 0),
    demandVa: ApparentPower(roundTo(rootDemandW / assumedBuildingPf, 0)),
    system: supplySystem,
    voltage: supplyVoltage,
  );

  // Earthing system designed from the main incomer's PE conductor.
  final mainResult = roots.firstOrNull != null ? results[roots.first.id] : null;
  final mainIb = mainResult?.demandCurrent ?? const Current(0);
  final mainBreaker =
      selectBreaker(profile, designCurrent: mainIb, loadKind: LoadKind.feeder);
  final mainCable = sizeCable(
    profile,
    designCurrent: mainIb,
    breakerRating: mainBreaker.ratingA,
    deratingFactor: 1,
    minSectionMm2: 4,
  );
  final earthing = computeEarthing(
    profile,
    system: project.earthingSystem,
    supplyPeMm2: profile.peConductorSizeMm2(mainCable.csaMm2),
  );

  return ElectricalSystemResult(
    projectId: project.id,
    panels: results,
    order: postOrder.reversed.toList(),
    totalDemandW: roundTo(rootDemandW, 0),
    supply: supply,
    earthing: earthing,
    warnings: warnings,
  );
}
