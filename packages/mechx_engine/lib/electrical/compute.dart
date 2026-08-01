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
import 'cable_family.dart';
import 'control/starter.dart' show StarterType;
import 'diversity_library.dart' show DiversityLibrary;
import 'earthing.dart';
// `fault.dart` is a pure post-processing pass that imports neither this file nor
// anything that reaches it (puil/units/earthing/load_kind/model/panel_results
// only), so taking `selectivityRatio` from it introduces no import cycle.
import 'fault.dart' show Impedance, conductorImpedance, downstreamFaultA,
    selectivityRatio, sourceImpedanceFromIsc;
import 'geo_length.dart';
import 'harmonics.dart' show neutralOversizeFactor;
import 'headroom.dart' show HeadroomSpec;
import 'load_kind.dart';
import 'model.dart';
import 'panel_results.dart';
import 'sizing.dart';

/// Practical building power factor used to convert demand kW → kVA for the
/// supply summary (matches PanelMaker `ASSUMED_BUILDING_PF`). Not a PUIL clause.
const double assumedBuildingPf = 0.85;

/// Assumed full-load efficiency of an induction motor when only the shaft
/// (mechanical) kW is given: the electrical input (nameplate FLC) is the shaft
/// kW divided by this efficiency. ~0.88 is a representative IE3-class value; the
/// proper fix is a motor-kW → nameplate-FLC table (A8).
// VERIFY — secondarySource (assumed IE3 induction-motor efficiency; no PUIL
// clause, not in a standards profile — replace with a motorKw→FLC table).
const double _assumedMotorEfficiency = 0.88;

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

/// A prior assignment read back as a LINE, or null when there is none for [id]
/// or the recorded value is `threePhase` (a three-phase way loads all three
/// lines — it is never placed by the search, so such an entry is ignored).
PhaseLine? _priorLine(Map<String, PhaseAssignment> prior, String id) =>
    switch (prior[id]) {
      PhaseAssignment.l1 => PhaseLine.l1,
      PhaseAssignment.l2 => PhaseLine.l2,
      PhaseAssignment.l3 => PhaseLine.l3,
      _ => null,
    };

/// Distribute single-phase circuits across L1/L2/L3 (greedy LPT + local-search
/// refinement) while three-phase circuits load all phases equally, then report
/// per-phase line current and the imbalance percentage. Pinned circuits keep
/// their line and are excluded from balancing. Ported from `phase.ts
/// balancePhases`.
///
/// PHASE-ASSIGNMENT STABILITY (additive; the defaults reproduce the port
/// exactly). [prior] is a previous solve's `circuitId → PhaseAssignment` map:
/// an unpinned single-phase circuit listed there is SEEDED onto its prior line
/// instead of entering the descending-current greedy, and the local search only
/// moves a circuit OFF its prior line when the move improves the spread by MORE
/// than [reassignThresholdA] amperes (strictly). A pin still wins over a prior
/// entry, a move back TO the prior line is always free, and a circuit with no
/// prior entry keeps the plain strict-improvement rule. So a re-solve of an
/// unchanged board reproduces its labelled phases, while a genuinely better
/// balance (gain > the threshold) is still taken. With the defaults (`prior`
/// empty, threshold 0) the seeding is empty and every acceptance test reduces
/// to `spread() < before - 1e-9` — step-for-step the original algorithm.
PhaseBalance balancePhases(
  List<_PhaseCircuit> circuits,
  ElectricalSystem system, {
  Map<String, PhaseAssignment> prior = const {},
  double reassignThresholdA = 0,
}) {
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

  // Prior-line SEED: a circuit the caller already placed keeps that line as its
  // starting point, so an unchanged board re-solves to the labels on site.
  // Empty [prior] ⇒ nothing is seeded and the greedy below sees every single.
  final seeded = <String, PhaseLine>{};
  for (final c in singles) {
    final line = _priorLine(prior, c.id);
    if (line == null) continue;
    seeded[c.id] = line;
    phases[line] = phases[line]! + c.currentA;
    assignment[c.id] = _lineAssign(line);
  }

  // Greedy least-loaded assignment (of the un-seeded singles — with no prior
  // that is every single, i.e. the original loop).
  for (final c in singles) {
    if (seeded.containsKey(c.id)) continue;
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

  // The spread improvement (A) a move must beat before it is accepted: the
  // caller's `reassignThresholdA` when it takes the circuit OFF the line a prior
  // solve recorded for it, else 0 (no prior line, already away from it, or a
  // move back onto it). 0 ⇒ the plain strict-improvement rule.
  double reassignCost(String id, PhaseLine from, PhaseLine to) {
    final p = seeded[id];
    if (p == null || from != p || to == p) return 0;
    return reassignThresholdA;
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
        final cost = reassignCost(c.id, from, to);
        phases[from] = phases[from]! - c.currentA;
        phases[to] = phases[to]! + c.currentA;
        if (spread() < before - cost - 1e-9) {
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
        // A swap moves BOTH ways, so it must clear the larger of the two
        // re-assignment costs (0 for a pair with no prior lines).
        final cost = math.max(
            reassignCost(a.id, pa, pb), reassignCost(b.id, pb, pa));
        phases[pa] = phases[pa]! + b.currentA - a.currentA;
        phases[pb] = phases[pb]! + a.currentA - b.currentA;
        if (spread() < before - cost - 1e-9) {
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

// ── phase-imbalance ACTIONABILITY ───────────────────────────────────────────

/// Imbalance (%) above which a three-phase board's phase loading is reported —
/// and only ever reported when a different assignment could actually improve it
/// (see [minimumPhaseSpreadA]).
const double kPhaseImbalanceWarnPercent = 15;

/// How many percentage points of imbalance a re-assignment must save before the
/// imbalance counts as REDUCIBLE. A judge-only actionability threshold (not a
/// standards value): below it the board is as even as its own loads allow and
/// asking the engineer to "redistribute" would be an instruction that cannot be
/// carried out.
const double kPhaseImbalanceReducibleMarginPercent = 1.0;

/// Boards with at most this many single-phase ways get an EXACT minimum-spread
/// search (3^n, symmetry-reduced ⇒ 3^(n-1) walks); above it the balancer's own
/// freest re-run is the reference.
const int kPhaseExactSearchMaxWays = 10;

double _spread3(double a, double b, double c) =>
    math.max(a, math.max(b, c)) - math.min(a, math.min(b, c));

/// The smallest line-current spread (A) ANY assignment of [currents] — the
/// single-phase way currents of one three-phase board — could reach.
///
/// Three-phase ways are deliberately absent: they load all three lines equally,
/// so they shift every sum by the same amount and cannot change the spread.
/// Phase PINS are released here, because unpinning is an action the engineer can
/// take, so a pin-forced imbalance counts as reducible.
///
/// Exhaustive (hence exact) while the way count is ≤ [exactSearchMax]: the
/// largest way is fixed on the first line (three empty lines are interchangeable)
/// so only 3^(n-1) assignments are walked. Above that the balancer's own greedy +
/// relocate/swap refinement — run free of pins and prior seeding — is the
/// reference; a board with that many single-phase ways balances to well inside
/// the warning limit unless one load dominates, and there relocate/swap is
/// already at the floor.
double minimumPhaseSpreadA(
  List<double> currents, {
  int exactSearchMax = kPhaseExactSearchMaxWays,
}) {
  final ways = currents.where((c) => c > 0).toList()
    ..sort((a, b) => b.compareTo(a));
  if (ways.isEmpty) return 0;

  if (ways.length <= exactSearchMax) {
    final lines = [0.0, 0.0, 0.0];
    var best = double.infinity;
    void walk(int i) {
      if (i == ways.length) {
        final s = _spread3(lines[0], lines[1], lines[2]);
        if (s < best) best = s;
        return;
      }
      // Symmetry break: with three empty lines the heaviest way can sit on L1
      // without loss of generality.
      final lanes = i == 0 ? 1 : 3;
      for (var p = 0; p < lanes; p++) {
        lines[p] += ways[i];
        walk(i + 1);
        lines[p] -= ways[i];
      }
    }

    walk(0);
    return roundTo(best, 1);
  }

  final free = balancePhases(
    [
      for (var i = 0; i < ways.length; i++)
        _PhaseCircuit('#$i', false, ways[i], null),
    ],
    ElectricalSystem.threePhase,
  );
  return roundTo(_spread3(free.l1, free.l2, free.l3), 1);
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

  /// Optional occupancy-keyed demand-factor library. When supplied AND the panel
  /// sets [ElectricalPanel.diversityLibraryId], each circuit's demand factor is
  /// looked up by occupancy + load kind in place of the model's per-circuit
  /// `demandFactor`. Null ⇒ the per-circuit factor is used as before
  /// (byte-identical). Additive.
  final DiversityLibrary? diversityLibrary;

  /// A previous solve's phase assignment for THIS panel (`circuitId → line`).
  /// Listed single-phase ways are seeded onto their prior line and only leave it
  /// for a gain above [phaseReassignThresholdA], so re-solving an unchanged
  /// board keeps the phases already labelled in the field. Empty (the default)
  /// ⇒ the balancer derives the assignment from scratch ⇒ byte-identical.
  final Map<String, PhaseAssignment> priorAssignment;

  /// How much the phase spread (A) must improve before a way is moved OFF the
  /// line [priorAssignment] recorded for it. 0 (the default) keeps the plain
  /// strict-improvement rule. A stability preference, not a standards value.
  final double phaseReassignThresholdA;

  /// SELECTIVITY FLOOR (A) for a feeder way, keyed by circuit id — derived by
  /// `computeSystem` from the fed board's incomer rating so the upstream feeder
  /// discriminates with it. Fed straight to [selectBreaker]'s `minRatingA`; a
  /// way absent from the map (the default: empty) sizes on its design current
  /// alone ⇒ byte-identical.
  final Map<String, double> feederBreakerFloorA;

  /// SERVICE-CAPACITY FLOOR (A) for the incomer + busbar of a SERVICE-ENTRANCE
  /// (root) panel — the line current of the declared connection capacity
  /// ([ElectricalProject.supplyCapacityVa], daya tersambung), derived by
  /// `computeSystem` for the single root panel. The service board is rated to
  /// carry everything the utility limiter will pass, so the incomer + bus size
  /// on `max(demand-based current, this floor)`; per-circuit sizing is
  /// untouched. Rating the entrance board at the subscribed daya is standard
  /// Indonesian LV-service practice, not an SNI/PUIL clause. // VERIFY
  /// Null (the default) ⇒ demand-based sizing exactly as before ⇒
  /// byte-identical.
  final double? serviceMinCurrentA;

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
    this.diversityLibrary,
    this.priorAssignment = const {},
    this.phaseReassignThresholdA = 0,
    this.feederBreakerFloorA = const {},
    this.serviceMinCurrentA,
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

/// The effective per-circuit demand (utilisation) factor: the occupancy-keyed
/// diversity library value when [library] is supplied AND [diversityLibraryId]
/// is set on the panel, else the circuit's own [ElectricalCircuit.demandFactor].
/// A feeder is an aggregation of the fed panel's already-diversified demand, so
/// it is NEVER re-diversified by the library (it keeps its own factor — normally
/// 1.0). With no library/id this returns `c.demandFactor` ⇒ byte-identical.
double effectiveDemandFactor(
  ElectricalCircuit c, {
  DiversityLibrary? library,
  String? diversityLibraryId,
}) {
  if (library == null ||
      diversityLibraryId == null ||
      c.isFeeder ||
      !library.hasOccupancy(diversityLibraryId)) {
    return c.demandFactor;
  }
  return library.demandFactorFor(
    diversityLibraryId,
    c.loadKind,
    fallback: c.demandFactor,
  );
}

/// A leaf circuit's connected demand (W): motor kW ×1000 for motors, else
/// connected W, times the demand factor. Ported from `computePanel.ts
/// circuitConnectedW`. With no diversity library/id the factor is the circuit's
/// own [ElectricalCircuit.demandFactor] ⇒ byte-identical to the original.
double circuitConnectedW(
  ElectricalCircuit c, {
  DiversityLibrary? library,
  String? diversityLibraryId,
}) {
  final isMotor =
      (c.loadKind == LoadKind.motor || c.loadKind == LoadKind.pump) &&
          c.motorKw != null;
  final baseW = isMotor ? c.motorKw! * 1000 : c.loadW;
  return baseW *
      effectiveDemandFactor(c,
          library: library, diversityLibraryId: diversityLibraryId);
}

double _effectiveLoadW(
    ElectricalCircuit c, ElectricalPanel panel, ComputePanelOptions opts) {
  if (c.feedsPanelId != null && opts.feederLoadW.containsKey(c.feedsPanelId)) {
    return opts.feederLoadW[c.feedsPanelId]!;
  }
  return circuitConnectedW(c,
      library: opts.diversityLibrary,
      diversityLibraryId: panel.diversityLibraryId);
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
  final loadW = _effectiveLoadW(c, panel, opts);
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

  // E8a — VOLTAGE BASE. A final circuit sits on THIS panel's bus. A FEEDER
  // terminates on the board it FEEDS, so the load it carries is drawn at the FED
  // board's voltage and its drop is a percentage of that same voltage: a feeder
  // to a 220 V single-phase sub-board is a 220 V run, not a 231 V one, so the
  // cumulative origin→load chain no longer mixes two bases. With no
  // [ComputePanelOptions.panelById] (a direct `computePanel` call) the fed panel
  // is unknown and this panel's own voltage is used exactly as before.
  final fedPanel =
      c.feedsPanelId != null ? opts.panelById[c.feedsPanelId] : null;
  final refPanel = fedPanel ?? panel;
  // Single-phase circuits on a three-phase panel run at the phase voltage (~230).
  final phaseVoltageV = refPanel.system == ElectricalSystem.threePhase
      ? roundTo(refPanel.voltage.volts / math.sqrt(3), 0)
      : refPanel.voltage.volts;
  final useVoltageV = threePhase ? refPanel.voltage.volts : phaseVoltageV;

  // Design current: a source-supplied FLA wins (A5); a motor derives its
  // nameplate FLC from the SHAFT kW divided by the assumed motor efficiency
  // (electrical input > shaft power), so its breaker/cable size on the real
  // full-load current rather than the under-stated shaft current; else
  // loadCurrent. (TODO motor FLC table (A8) replaces the efficiency divisor.)
  final motorLike =
      (c.loadKind == LoadKind.motor || c.loadKind == LoadKind.pump) &&
          c.motorKw != null;
  final Current ib;
  if (c.flaOverrideA != null) {
    ib = c.flaOverrideA!;
  } else if (motorLike) {
    // Shaft kW → electrical input kW via the assumed efficiency (// VERIFY).
    ib = loadCurrent(
      power: Power.kiloWatts(c.motorKw! / _assumedMotorEfficiency),
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

  // E5 — a FINAL SOCKET way sizes its OWN device + conductor on the
  // UNDIVERSIFIED connected load. `demandFactor` is a coincidence factor across
  // ways: it belongs in the aggregation that feeds the busbar / incomer / demand
  // (and it still does — [designCurrent], the phase balance and every demand
  // figure keep the diversified current), but a stop-kontak way is built to
  // carry every socket on it. Sizing the device on the diversified figure put
  // adjacent socket ways on different rungs purely from a utilisation factor
  // (2.8 kW → 10 A beside 3.0 kW → 16 A). Feeders (already an aggregation of the
  // fed board's diversified demand) and every non-socket kind are unchanged, so
  // a project without diversified socket finals is byte-identical.
  // VERIFY — notAnSniClause: Indonesian practice puts a stop-kontak final on a
  // uniform 16 A / 2.5 mm² make-up; no PUIL clause forbids diversifying a final
  // circuit's own device, this is a drafting/uniformity convention.
  final sizeOnUndiversifiedLoad = !isFeeder && c.loadKind == LoadKind.socket;
  final Current sizingCurrent;
  if (sizeOnUndiversifiedLoad && c.flaOverrideA == null && !motorLike) {
    final undiversified = loadCurrent(
      power: Power(c.loadW),
      voltage: Voltage(useVoltageV),
      cosPhi: c.cosPhi,
      threePhase: threePhase,
    );
    // A demand factor above 1 must never size the device BELOW the load it
    // carries, so the sizing current is never less than the design current.
    sizingCurrent = Current(math.max(ib.amperes, undiversified.amperes));
  } else {
    sizingCurrent = ib;
  }

  // THE LOAD-SIZED DEVICE. Deliberately floor-free: the conductor below is sized
  // against THIS pick, so a coordination floor can never inflate copper (E3).
  final loadBreaker = selectBreaker(
    profile,
    designCurrent: sizingCurrent,
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
  // The cable family (NYY/NYM/NYA/NYAF/FRC) sets the insulation temperature
  // class for the KHA lookup — notably FRC sizes on the 90 °C table — falling
  // back to the panel default when the run is untyped (byte-identical then).
  final cableInsulation =
      insulationForCableType(c.cableType, fallback: panel.insulation);

  final cable = sizeCable(
    profile,
    designCurrent: sizingCurrent,
    breakerRating: loadBreaker.ratingA,
    deratingFactor: df,
    minSectionMm2: minSection,
    insulation: cableInsulation,
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

  // E3/E4 — FEEDER SELECTIVITY FLOOR: DEVICE-ONLY, AMPACITY-CAPPED.
  //
  // Real practice discriminates a feeder from the board it feeds with the
  // DEVICE (a rating band, and on an MCCB its settings) — not by inflating the
  // conductor. So the floor is applied here, after the cable was sized on the
  // load, and is capped at the largest rung the load-sized cable's derated Iz
  // still protects: overload protection of the conductor (In ≤ Iz) is
  // inviolable and always beats coordination. When the cap bites below the floor
  // target the residual non-/partial-selectivity is REAL and stays reported by
  // `faultStudy` (that feeder is not listed in
  // [ElectricalSystemResult.feederFloorsApplied]).
  //
  // A way `computeSystem` did not flag, and any way carrying an explicit
  // override, keeps the load-sized device verbatim ⇒ byte-identical.
  final floorA =
      c.breakerOverrideA != null ? null : opts.feederBreakerFloorA[c.id];
  var breaker = loadBreaker;
  if (floorA != null) {
    final floored = selectBreaker(
      profile,
      designCurrent: sizingCurrent,
      loadKind: c.loadKind,
      minRatingA: floorA,
      maxRatingA: cable.deratedIz,
    );
    // The cap may only hold the floor back, never pull the device below the
    // rating the load itself demanded (the ampacity-impossible fallback is the
    // one case where Iz < In, and it is already an error-severity finding).
    if (floored.ratingA.amperes > breaker.ratingA.amperes) breaker = floored;
  }

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
  // E6 — a LIFE-SAFETY motor/pump way (fire pump, jockey pump, sprinkler
  // booster) is auto-sized like any other motor: an ordinary thermal-magnetic
  // device whose OVERLOAD element will trip a stalled or over-pumping machine.
  // Under fire duty the machine is expected to run to destruction rather than
  // stop, so the protection is specified differently (locked-rotor-rated,
  // overload trip disabled / alarm-only). The engine does NOT fabricate that
  // device — it has no data for it — so this is an INFO note carried onto the
  // schedule, not a sizing change.
  //
  // G5 — the note is a SPEC INSTRUCTION for the issued schedule, not a request
  // for an app setting (there is no overload-trip-disabled field to set, and
  // asking for one sent the engineer hunting for a control that does not
  // exist). The schedule row for this way now prints the matching
  // `· no-OL trip (fire)` KETERANGAN token
  // (`report/electrical_sld_drawing.dart`, same `lifeSafety && motorLike`
  // gate), so the note and the deliverable say the same thing.
  // VERIFY — notAnSniClause: NFPA 20 fire-pump controller practice (locked-rotor
  // rated protection, no overload trip), NOT a PUIL/SNI clause.
  if (c.lifeSafety &&
      (c.loadKind == LoadKind.motor || c.loadKind == LoadKind.pump)) {
    warnings.add(ElectricalWarning(
      code: 'fire-pump-protection',
      severity: WarningSeverity.info,
      message:
          '${c.name}: fire pump way - specify overload-trip-disabled protection '
          'on the schedule (fire duty runs to destruction - NFPA 20 practice). '
          'Sized here as an ordinary ${_num(breaker.ratingA.amperes)} A curve '
          '${breaker.curve.name.toUpperCase()} device; the schedule row carries '
          '"no-OL trip (fire)".',
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
  // The cable could not reach the required ampacity even at the largest section
  // / max parallel runs: the breaker In now exceeds the conductor Iz, so the
  // device no longer protects the cable (IEC 60364-4-43 / PUIL cl 2.2.8.3
  // In ≤ Iz coordination violated). A genuine safety defect — flag as an error.
  if (!cable.ampacityReached) {
    warnings.add(ElectricalWarning(
      code: 'cable-ampacity-inadequate',
      severity: WarningSeverity.error,
      message:
          '${c.name}: cable ampacity Iz ${cable.deratedIz.amperes} A is below '
          'the breaker In ${breaker.ratingA.amperes} A even at the largest '
          'section — the breaker no longer protects the conductor (In > Iz). '
          'Reduce the grouping/ambient derating, split the load, or feed it '
          'separately.',
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
    lengthM: effectiveLength.meters,
    loadW: loadW,
    points: c.points,
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
        // Match the sizing insulation: a family (e.g. FRC at 90 °C) derates on
        // its own ambient curve, not the panel default.
        insulation: insulationForCableType(c.cableType, fallback: panel.insulation),
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
    prior: opts.priorAssignment,
    reassignThresholdA: opts.phaseReassignThresholdA,
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

  // PHASE IMBALANCE — reported only when it is actually REDUCIBLE.
  //
  // `balancePhases` has already spread every unpinned single-phase way as evenly
  // as it can, so "redistribute single-phase circuits" is a real instruction ONLY
  // when some other assignment would materially cut the imbalance — a phase PIN
  // holding a way on an already-loaded line, or a prior-assignment seed the
  // stability threshold refused to leave. Two single-phase ways can never load
  // three lines evenly: that imbalance is inherent to the board's loads, and the
  // engineer is not told to fix what no re-assignment can fix. The percentage
  // still prints on the schedule TOTAL footer and in the panel inspector /
  // report — only the unactionable WARNING is dropped. The floor search runs
  // ONLY for a board already over the limit, so an even board costs nothing.
  final overImbalanceLimit = panel.system == ElectricalSystem.threePhase &&
      balance.imbalancePercent > kPhaseImbalanceWarnPercent;
  var imbalanceReducible = false;
  var bestImbalancePercent = balance.imbalancePercent;
  if (overImbalanceLimit) {
    // The average line current is assignment-invariant (the same total load is
    // shared out however the ways are placed), so the achievable imbalance is
    // the achievable SPREAD measured against the same average.
    final avgA = (balance.l1 + balance.l2 + balance.l3) / 3;
    final bestSpreadA = minimumPhaseSpreadA([
      for (final cm in comps)
        if (!cm.threePhase) cm.result.designCurrent.amperes,
    ]);
    bestImbalancePercent =
        avgA > 0 ? roundTo((bestSpreadA / avgA) * 100, 1) : 0.0;
    imbalanceReducible = bestImbalancePercent +
            kPhaseImbalanceReducibleMarginPercent <
        balance.imbalancePercent;
  }

  if (overImbalanceLimit && imbalanceReducible) {
    final pinnedWays = [
      for (var i = 0; i < comps.length; i++)
        if (!comps[i].threePhase && branches[i].phaseOverride != null)
          branches[i].id,
    ].length;
    final action = pinnedWays > 0
        ? 'Unpin the ${pinnedWays == 1 ? 'way pinned' : '$pinnedWays ways pinned'} '
            'to a phase so the balancer can even the load'
        : 'Redistribute single-phase circuits';
    warnings.add(ElectricalWarning(
      code: 'phase-imbalance',
      severity: WarningSeverity.warning,
      message:
          'Phase loading is unbalanced by ${balance.imbalancePercent}% '
          '(L1 ${balance.l1} A, L2 ${balance.l2} A, L3 ${balance.l3} A). '
          '$action — $bestImbalancePercent% is achievable.',
      panelId: panel.id,
    ));
  }

  // E7 — an imbalance over the limit that NO re-assignment can improve is still
  // worth printing: it is a real property of the board (the incomer, busbar and
  // feeder all size on the heavy phase) and the engineer has a genuine, but
  // different, action — add a third single-phase leg or replace two 1φ machines
  // with one 3φ appliance. INFO, never a warning: there is nothing wrong with
  // the design as drawn, and "redistribute" would be an instruction that cannot
  // be carried out. Same threshold + same reducibility test as the warning path,
  // so exactly one of the two ever fires.
  if (overImbalanceLimit && !imbalanceReducible) {
    warnings.add(ElectricalWarning(
      code: 'phase-imbalance-inherent',
      severity: WarningSeverity.info,
      message:
          'Phase loading is unbalanced by ${balance.imbalancePercent}% '
          '(L1 ${balance.l1} A, L2 ${balance.l2} A, L3 ${balance.l3} A) - '
          'inherent to the single-phase load set ($bestImbalancePercent% is the '
          'best any assignment reaches), so no redistribution helps; consider a '
          'third leg or a 3-phase appliance.',
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

  // SPARE-WAYS / FUTURE-LOAD HEADROOM. A null spec (or a 0 % / 0-way spec)
  // leaves the incomer + busbar + section count BYTE-IDENTICAL — the multiplier
  // is 1.0 and no spare ways are reserved. When a future-load % is set, the
  // INCOMER + BUSBAR are rated for the uplifted (future) line current so a later
  // load addition doesn't outgrow the board; the per-circuit sizing is unchanged
  // (today's circuits are sized for today's load). Reserved spare ways are
  // counted toward the busbar way capacity below.
  final headroom = panel.headroom ?? HeadroomSpec.none;
  final headroomApplied = headroom.isActive;
  final headroomMultiplier = headroom.demandMultiplier;
  final spareWaysReserved = headroom.effectiveSpareWays;
  // The line current the incomer + busbar are sized against (= demand × future
  // multiplier). 1.0 ⇒ exactly demandCurrentA. A SERVICE-ENTRANCE (root) panel
  // additionally floors at the declared connection capacity's line current
  // (daya tersambung, [ComputePanelOptions.serviceMinCurrentA]) — the entrance
  // board is rated for everything the utility limiter will pass, so changing
  // the subscribed daya re-sizes the incomer even when today's demand is small.
  // Null / smaller floor ⇒ exactly the demand-based current ⇒ byte-identical.
  final futureDemandCurrentA = roundTo(demandCurrentA * headroomMultiplier, 1);
  final serviceFloorA = opts.serviceMinCurrentA ?? 0;
  final serviceGoverns = serviceFloorA > futureDemandCurrentA;
  final incomerSizingCurrentA =
      serviceGoverns ? roundTo(serviceFloorA, 1) : futureDemandCurrentA;

  final incomerBreaker = selectBreaker(
    profile,
    designCurrent: Current(incomerSizingCurrentA),
    loadKind: LoadKind.feeder,
  );
  final incomer = IncomerResult(
    breaker: incomerBreaker,
    poles: panel.system == ElectricalSystem.threePhase ? 4 : 2,
  );
  if (incomerBreaker.ratingA.amperes + 1e-9 < incomerSizingCurrentA) {
    final basis = serviceGoverns
        ? 'declared service capacity'
        : '${headroomApplied ? 'future ' : ''}demand';
    warnings.add(ElectricalWarning(
      code: 'incomer-exceeds-range',
      severity: WarningSeverity.error,
      message:
          '${panel.name}: $basis '
          '$incomerSizingCurrentA A exceeds the largest standard breaker frame '
          '(${incomerBreaker.ratingA.amperes} A) — split the board or feed it '
          'at MV.',
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

  // Main bus rated for the incoming device (IEC 61439-1), not just demand. The
  // sizing current carries any future-load headroom (= demand × multiplier; 1.0
  // ⇒ exactly demandCurrentA ⇒ byte-identical).
  final busbar = sizeBusbar(
    profile,
    Current(incomerSizingCurrentA),
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
      // Reserved spare ways occupy busbar way-capacity (so the bus is split into
      // enough sections to host them) but carry no load. spareWaysReserved = 0
      // ⇒ none added ⇒ byte-identical section layout.
      for (var s = 0; s < spareWaysReserved; s++)
        _BusbarWayLoad('__spare_$s', 0, false, PhaseAssignment.l1, false),
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
  // the schedule does not get built). INFO, not a warning: the always-on FOLD 2
  // has already oversized the neutral bar, so the condition is self-compensated
  // — a sizing note to carry onto the schedule, with nothing left to act on.
  if (neutralPe.neutralOversizeFactor > 1) {
    warnings.add(ElectricalWarning(
      code: 'harmonics-neutral-oversize',
      severity: WarningSeverity.info,
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
  // Future (spare-uplifted) demand the incomer + busbar were rated for. With no
  // headroom the multiplier is 1.0 ⇒ futureLoadW == demandW.
  final futureLoadW = demandW * headroomMultiplier;

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
    futureLoadW: roundTo(futureLoadW, 0),
    headroomApplied: headroomApplied,
    spareWaysReserved: spareWaysReserved,
    phaseBalance: PhaseBalanceResult(
      l1: balance.l1,
      l2: balance.l2,
      l3: balance.l3,
      imbalancePercent: balance.imbalancePercent,
      imbalanceReducible: imbalanceReducible,
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
///
/// SERVICE-CAPACITY FLOOR is data-driven: a declared
/// [ElectricalProject.supplyCapacityVa] (daya tersambung) floors the single
/// root panel's incomer + busbar (and the earthing PE derivation) at the
/// declared capacity's line current, and raises a judge-only
/// `service-capacity-below-demand` warning when the computed worst-phase
/// demand exceeds what that capacity's limiter passes. Null (the default) ⇒
/// no floor ⇒ byte-identical.
///
/// PHASE STABILITY is opt-in: [priorAssignments] (`panelId → (circuitId → line)`,
/// normally the previous solve's assignment) seeds each panel's balancer and,
/// with [phaseReassignThresholdA], stops a marginal gain from re-labelling an
/// installed board. Empty / 0 (the defaults) ⇒ every panel balances from
/// scratch ⇒ byte-identical.
ElectricalSystemResult computeSystem(
  ElectricalStandardsProfile profile,
  ElectricalProject project, {
  Map<String, ScaleCalibration> calibrationBySheet = const {},
  BuildingLevels? building,
  Current? originFaultLevel,
  double busbarClearingTimeS = busbarDefaultClearingTimeS,
  DiversityLibrary? diversityLibrary,
  Map<String, Map<String, PhaseAssignment>> priorAssignments = const {},
  double phaseReassignThresholdA = 0,
}) {
  final panels = project.panels;
  final byId = {for (final p in panels) p.id: p};
  // Topology warnings raised before any sizing — pass-invariant, so they seed
  // each sizing pass's warning list rather than accumulating across passes.
  final baseWarnings = <ElectricalWarning>[];

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
      baseWarnings.add(ElectricalWarning(
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
    baseWarnings.add(const ElectricalWarning(
      code: 'feeder-cycle',
      severity: WarningSeverity.error,
      message:
          'Feeder topology contains a cycle; system aggregation may be incomplete.',
    ));
  }

  // SERVICE-CAPACITY FLOOR — the declared connection capacity (daya
  // tersambung, [ElectricalProject.supplyCapacityVa]) converted to the line
  // current at the SERVICE-ENTRANCE board, so the root incomer + busbar are
  // rated for everything the utility limiter will pass (3φ: VA / (√3·V_LL);
  // 1φ: VA / V — pure arithmetic; e.g. PLN 33 kVA 3φ 400 V → 47.6 A → the
  // 50 A rung, the matching PLN limiter). Applied ONLY when the tree has
  // exactly ONE root — with several utility-fed boards the split of the
  // declared capacity between them is unknown, so nothing is fabricated.
  // Null capacity (the default) ⇒ no floor ⇒ byte-identical.
  final serviceCapacityVa = project.supplyCapacityVa?.voltAmperes;
  double? serviceMinCurrentA;
  if (serviceCapacityVa != null && serviceCapacityVa > 0 && roots.length == 1) {
    final root = roots.first;
    final v = root.voltage.volts;
    if (v > 0) {
      serviceMinCurrentA = root.system == ElectricalSystem.threePhase
          ? serviceCapacityVa / (math.sqrt(3) * v)
          : serviceCapacityVa / v;
    }
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
          : circuitConnectedW(c,
              library: diversityLibrary,
              diversityLibraryId: panel.diversityLibraryId);
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
        connectedLoadW += circuitConnectedW(c,
            library: diversityLibrary, diversityLibraryId: p.diversityLibraryId);
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

  // The feeder circuit id feeding each child panel (parent way), and the panel
  // each feeder way lives ON (so a floored feeder's result can be found again).
  final feederCircuitOf = <String, String>{}; // child panel id → feeder id
  final feederParentOf = <String, String>{}; // feeder id → parent panel id
  for (final p in panels) {
    for (final c in p.circuits) {
      if (c.feedsPanelId != null) {
        feederCircuitOf[c.feedsPanelId!] = c.id;
        feederParentOf[c.id] = p.id;
      }
    }
  }

  // ── one complete sizing + post-processing pass ─────────────────────────────
  // Everything below (per-panel sizing, FOLD-1 fault propagation, cumulative
  // voltage drop, the judge-only feeder check, supply summary, earthing) is a
  // pure function of the project + [feederBreakerFloorA], so it can be re-run
  // once with a selectivity floor applied (see the two-pass note after it).
  ElectricalSystemResult sizeAll(Map<String, double> feederBreakerFloorA) {
    final warnings = <ElectricalWarning>[...baseWarnings];
    final panelFaultA = <String, double>{};
    final panelSourceZ = <String, Impedance>{};

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
          diversityLibrary: diversityLibrary,
          priorAssignment: priorAssignments[id] ?? const {},
          phaseReassignThresholdA: phaseReassignThresholdA,
          feederBreakerFloorA: feederBreakerFloorA,
          serviceMinCurrentA:
              roots.length == 1 && id == roots.first.id ? serviceMinCurrentA : null,
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
        futureLoadW: pr.futureLoadW,
        headroomApplied: pr.headroomApplied,
        spareWaysReserved: pr.spareWaysReserved,
        phaseBalance: pr.phaseBalance,
        warnings: pr.warnings,
      );
    }

    // JUDGE-ONLY feeder-vs-fed-board check: a feeder way's design current is the
    // fed board's diversified demand W converted at a balanced power factor, but
    // the fed board's own incomer (and the current the feeder REALLY carries on
    // its worst phase) is the WORST-PHASE line current — on an imbalanced fed
    // board those diverge, and the feeder breaker can end up rated below what
    // the board actually draws (nuisance trip under full demand, and the two
    // printed figures contradict on the schedule). Never resizes — the honest
    // fix is rebalancing the fed board's phases (or a breaker override).
    for (final id in postOrder.reversed) {
      final parent = byId[id];
      final pr = results[id];
      if (parent == null || pr == null) continue;
      for (final c in parent.circuits) {
        final childId = c.feedsPanelId;
        if (childId == null) continue;
        final childResult = results[childId];
        final feederResult =
            pr.circuits.where((r) => r.circuitId == c.id).firstOrNull;
        if (childResult == null || feederResult == null) continue;
        final childDemandA = childResult.demandCurrent.amperes;
        final feederRatingA = feederResult.breaker.ratingA.amperes;
        if (childDemandA <= 0 || feederRatingA + 1e-9 >= childDemandA) continue;
        // Only offer "rebalance" when that board's imbalance is actually
        // reducible; an imbalance inherent to its single-phase loads leaves the
        // feeder rating (or splitting the load) as the honest fix.
        final imbalance = childResult.phaseBalance.imbalancePercent;
        final cause = imbalance <= 0
            ? ' — raise the feeder rating'
            : childResult.phaseBalance.imbalanceReducible
                ? ' (phase imbalance $imbalance% — rebalance that board\'s '
                    'single-phase ways or raise the feeder rating)'
                : ' (phase imbalance $imbalance%, inherent to that board\'s '
                    'single-phase loads — raise the feeder rating)';
        pr.warnings.add(ElectricalWarning(
          code: 'feeder-below-fed-demand',
          severity: WarningSeverity.warning,
          message:
              '${c.name}: the feeder breaker is ${_num(feederRatingA)} A but '
              '${childResult.name} draws ${_num(childDemandA)} A on its '
              'worst-loaded phase$cause.',
          panelId: id,
          circuitId: c.id,
        ));
      }
    }

    // JUDGE-ONLY service-capacity check: the declared connection capacity
    // (daya tersambung) is what the utility limiter passes — a root board whose
    // worst-phase demand exceeds that current will trip the limiter under full
    // load. Never resizes (the incomer already sizes on the larger demand);
    // the honest fix is a bigger subscription or shedding load.
    if (serviceMinCurrentA != null) {
      final rootId = roots.first.id;
      final rootResult = results[rootId];
      if (rootResult != null &&
          rootResult.demandCurrent.amperes > serviceMinCurrentA + 1e-9) {
        rootResult.warnings.add(ElectricalWarning(
          code: 'service-capacity-below-demand',
          severity: WarningSeverity.warning,
          message:
              '${rootResult.name}: demand '
              '${_num(rootResult.demandCurrent.amperes)} A on the worst-loaded '
              'phase exceeds the declared connection capacity '
              '${_num(serviceCapacityVa! / 1000)} kVA '
              '(~${_num(roundTo(serviceMinCurrentA, 1))} A) — the utility '
              'limiter would trip under full demand; raise the subscribed daya '
              'or shed load.',
          panelId: rootId,
        ));
      }
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

    // Earthing system designed from the main incomer's PE conductor. The
    // service-capacity floor rides along (when it governs), so the service PE
    // tracks the entrance device the same floor sized.
    final mainResult = roots.firstOrNull != null ? results[roots.first.id] : null;
    final mainDemandIb = mainResult?.demandCurrent ?? const Current(0);
    final mainIb =
        serviceMinCurrentA != null && serviceMinCurrentA > mainDemandIb.amperes
            ? Current(roundTo(serviceMinCurrentA, 1))
            : mainDemandIb;
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

    // Which flagged feeders actually REACHED their selectivity target. A floor
    // held back by the conductor-protection cap is deliberately absent, so the
    // residual partial/non-selectivity keeps being reported by `faultStudy`.
    final floorsApplied = <String>{};
    // G3 — and, for the ones that did NOT reach it, whether the CONDUCTOR-
    // PROTECTION CAP is what held them back (as opposed to the ladder simply
    // running out of rungs). `selectBreaker` resolves the floor to the first
    // rung ≥ the target and only then applies `maxRatingA` (the cable's derated
    // Iz), so the cap bit exactly when that floor rung sits above Iz. Recording
    // it here — rather than deep in `_computeCircuit` — keeps the per-circuit
    // sizing path untouched, and reads the SAME ladder + Iz the sizer used.
    final floorsCapped = <String>{};
    final ladder = profile.standardBreakerRatingsA;
    for (final entry in feederBreakerFloorA.entries) {
      final parentId = feederParentOf[entry.key];
      final r = results[parentId]
          ?.circuits
          .where((x) => x.circuitId == entry.key)
          .firstOrNull;
      if (r == null || r.breaker.overridden) continue;
      if (r.breaker.ratingA.amperes + 1e-9 >= entry.value) {
        floorsApplied.add(entry.key);
        continue;
      }
      final floorRung = ladder.firstWhere((x) => x + 1e-9 >= entry.value,
          orElse: () => ladder.last);
      if (floorRung > r.cable.deratedIz.amperes) floorsCapped.add(entry.key);
    }

    return ElectricalSystemResult(
      projectId: project.id,
      panels: results,
      order: postOrder.reversed.toList(),
      totalDemandW: roundTo(rootDemandW, 0),
      supply: supply,
      earthing: earthing,
      warnings: warnings,
      feederFloorsApplied: floorsApplied,
      feederFloorsCapped: floorsCapped,
    );
  }

  // PASS 1 — size the system with no coordination floor (exactly the historic
  // single-pass behaviour).
  final pass1 = sizeAll(const {});

  // FEEDER SELECTIVITY FLOOR. A feeder way and the incomer of the board it feeds
  // are sized from the SAME diversified demand, so they routinely land on the
  // same ladder rung — ratio 1.0, i.e. `nonSelective` by `fault.dart`'s
  // [selectivityRatio] rule: a fault on the sub-board would trip the upstream
  // feeder as readily as the board's own incomer. The sizer must not create the
  // condition the fault study then warns about, so any such feeder is re-sized
  // in a second pass at a floor of `selectivityRatio × the child's incomer`.
  // Skipped for an explicitly overridden feeder — the engineer's rating stands
  // verbatim, and the residual non-selectivity remains for `faultStudy` to flag.
  //
  // The floor moves the DEVICE ONLY, and only as far as the load-sized cable's
  // ampacity permits (`_computeCircuit`): the conductor is sized from the load
  // on both passes, so nothing about the cable — or the fault impedance derived
  // from it — differs between the two.
  final feederFloors = <String, double>{};
  for (final p in panels) {
    for (final c in p.circuits) {
      final childId = c.feedsPanelId;
      if (childId == null || c.breakerOverrideA != null) continue;
      final childResult = pass1.panels[childId];
      final feederResult =
          pass1.panels[p.id]?.circuits.where((r) => r.circuitId == c.id).firstOrNull;
      if (childResult == null || feederResult == null) continue;
      // Whatever produced it (auto-sized, headroom-uplifted, or overridden) the
      // child's incomer rating is the device the feeder must discriminate with.
      final childIncomerA = childResult.incomer.breaker.ratingA.amperes;
      if (childIncomerA <= 0) continue;
      final floorA = selectivityRatio * childIncomerA;
      if (feederResult.breaker.ratingA.amperes + 1e-9 < floorA) {
        feederFloors[c.id] = floorA;
      }
    }
  }

  // No feeder needed lifting (every single-panel project, and any project whose
  // feeders are overridden or already selective) ⇒ pass 1 IS the answer, handed
  // back as-is so nothing is recomputed and the output is byte-identical.
  if (feederFloors.isEmpty) return pass1;

  // PASS 2 — exactly one more pass, and provably enough: each floor is derived
  // from a CHILD's incomer rating, which is sized from that child's own load-side
  // demand (its circuit design currents × its diversity/headroom) and is
  // therefore invariant under a change to its PARENT's feeder breaker or cable.
  // So the floors computed from pass 1 are still the correct floors in pass 2,
  // and every flagged feeder emerges at or above `selectivityRatio ×` its child's
  // incomer (or clamped at the ladder top, reported honestly) — a fixed point.
  return sizeAll(feederFloors);
}
