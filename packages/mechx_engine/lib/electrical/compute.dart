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
import 'fault.dart'
    show
        Impedance,
        conductorImpedance,
        coldMaxFaultImpedance,
        faultBasisLineVoltageV,
        feederNeutralImpedance,
        selectivityRatio,
        solvedRunLengthM,
        sourceImpedanceFromIsc,
        subPanelBusFaultA;
import 'genset_backup.dart' show isEssentialByName;
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

// The assumed motor efficiency (shaft kW → electrical input kW) lives in
// `load_kind.dart` as [kAssumedMotorEfficiency] so the power-factor pass reads
// the SAME figure as the Ib derivation below.

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
    final vals = [
      phases[PhaseLine.l1]!,
      phases[PhaseLine.l2]!,
      phases[PhaseLine.l3]!
    ];
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
        final cost =
            math.max(reassignCost(a.id, pa, pb), reassignCost(b.id, pb, pa));
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

  // elec-props-3 — EXACT refinement. Relocate / pairwise-swap stops at local
  // optima: nine ways of 7.7…24.4 A settled at L 47.5 / 48.1 / 50.8 A (a 63 A
  // incomer) where {24.4, 23.7} / {23.1, 16.7, 9.7} / {21.5, 13.4, 7.7, 6.2}
  // reaches a 49.5 A worst phase (a 50 A incomer) — and the engine then told
  // the engineer to "redistribute" its own assignment. For a board with at
  // most [kPhaseExactSearchMaxWays] movable singles, walk every assignment
  // (pins and 3φ ways fixed) and adopt the best by the sizing objective:
  // minimum WORST phase (what the incomer + busbar size on), then minimum
  // spread. Only a STRICT improvement is adopted, so a board the local search
  // already solved keeps its labels; with a prior seed the gain must also
  // clear the stickiness threshold, exactly like a single move.
  if (singles.length >= 2 && singles.length <= kPhaseExactSearchMaxWays) {
    final base = <PhaseLine, double>{...phases};
    for (final c in singles) {
      final line = fromAssign(assignment[c.id]!);
      base[line] = base[line]! - c.currentA;
    }
    final lines = [
      base[PhaseLine.l1]!,
      base[PhaseLine.l2]!,
      base[PhaseLine.l3]!
    ];
    final pick = List<int>.filled(singles.length, 0);
    List<int>? bestPick;
    var bestWorst = double.infinity;
    var bestSpread = double.infinity;
    void walk(int i) {
      if (i == singles.length) {
        final worst = math.max(lines[0], math.max(lines[1], lines[2]));
        final sp = _spread3(lines[0], lines[1], lines[2]);
        if (worst < bestWorst - 1e-9 ||
            (worst <= bestWorst + 1e-9 && sp < bestSpread - 1e-9)) {
          bestWorst = worst;
          bestSpread = sp;
          bestPick = [...pick];
        }
        return;
      }
      for (var p = 0; p < 3; p++) {
        lines[p] += singles[i].currentA;
        pick[i] = p;
        walk(i + 1);
        lines[p] -= singles[i].currentA;
      }
    }

    walk(0);
    final curWorst = math.max(phases[PhaseLine.l1]!,
        math.max(phases[PhaseLine.l2]!, phases[PhaseLine.l3]!));
    final curSpread = spread();
    final better = bestWorst < curWorst - 1e-9 ||
        (bestWorst <= curWorst + 1e-9 && bestSpread < curSpread - 1e-9);
    final clearsStickiness = seeded.isEmpty ||
        curWorst - bestWorst > reassignThresholdA ||
        curSpread - bestSpread > reassignThresholdA;
    if (bestPick != null && better && clearsStickiness) {
      phases
        ..[PhaseLine.l1] = base[PhaseLine.l1]!
        ..[PhaseLine.l2] = base[PhaseLine.l2]!
        ..[PhaseLine.l3] = base[PhaseLine.l3]!;
      for (var i = 0; i < singles.length; i++) {
        final line = keys[bestPick![i]];
        phases[line] = phases[line]! + singles[i].currentA;
        assignment[singles[i].id] = _lineAssign(line);
      }
    }
  }

  final vals = [
    phases[PhaseLine.l1]!,
    phases[PhaseLine.l2]!,
    phases[PhaseLine.l3]!
  ];
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
      final overCurrent = _sectionWorstPhaseA([...group, w], system) >
          maxSectionCurrentA.amperes;
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

  /// elec-props-2 — the REAL power factor of each fed board (child panel id →
  /// diversified demand W / diversified demand VA), derived by `computeSystem`
  /// bottom-up. A feeder way's load IS that board's demand W, so its Ib and
  /// voltage drop convert at the fed board's own power factor — not at the
  /// feeder circuit's default 0.85 (which under-sized a feeder to a 0.65-pf
  /// board by 0.65/0.85 = 24 %, leaving its cable carrying more than Iz). A
  /// feeder absent from the map keeps its own `cosPhi` (direct `computePanel`
  /// callers ⇒ byte-identical).
  final Map<String, double> feederPowerFactor;

  /// Round 13 — the CAPACITOR switching current (A, per line, already × the
  /// [kCapacitorSwitchingFactor]) each fed board's capacitor ways — its own and
  /// any further down its feeder tree — draw, keyed by the child panel id a
  /// feeder serves. A bank adds no demand W, so without this floor a feeder to
  /// a dedicated PFC board sized on 0 A (a 10 A / 4 mm² feeder protecting a
  /// 144 A bank). Derived by `computeSystem`; empty (the default) ⇒ no floor ⇒
  /// byte-identical.
  final Map<String, double> feederCapacitorFloorA;

  const ComputePanelOptions({
    this.feederCapacitorFloorA = const {},
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
    this.feederPowerFactor = const {},
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

/// A leaf circuit's connected demand (W) — the ELECTRICAL INPUT power the way
/// draws from the bus — times the demand factor:
///   * an A5 MEP-derived way (`flaOverrideA` set) → `loadW`, which A5 sets to the
///     equipment's electrical input power (the same figure its FLA derives from);
///   * a hand-entered motor/pump way → shaft `motorKw` ×1000 ÷ the assumed motor
///     efficiency, the SAME electrical-input basis its Ib uses (`_computeCircuit`),
///     so a feeder/panel/supply demand never under-counts the current the motor
///     way itself draws;
///   * anything else → connected `loadW`.
/// Ported from `computePanel.ts circuitConnectedW` (which summed shaft kW). With
/// no diversity library/id the factor is the circuit's own
/// [ElectricalCircuit.demandFactor].
double circuitConnectedW(
  ElectricalCircuit c, {
  DiversityLibrary? library,
  String? diversityLibraryId,
}) {
  // Round 11 — a capacitor bank's `loadW` is its REACTIVE rating (kvar): it
  // draws no real power, so it contributes nothing to the connected / demand
  // W of the panel, the feeders above it, the supply or the daya check (it
  // used to be summed as kW — a 20 kvar bank added +20 kW, +59 % on the
  // worked example). `power_factor.dart` already excludes it from leaf loads.
  if (c.loadKind == LoadKind.capacitor) return 0;
  final isMotor =
      (c.loadKind == LoadKind.motor || c.loadKind == LoadKind.pump) &&
          c.motorKw != null;
  final double baseW;
  if (c.flaOverrideA != null) {
    baseW = c.loadW;
  } else if (isMotor) {
    // Shaft kW → electrical input W via the assumed efficiency (// VERIFY).
    baseW = c.motorKw! * 1000 / kAssumedMotorEfficiency;
  } else {
    baseW = c.loadW;
  }
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
    final w = math.max(0.0, _balanceCurrentA(cm.result));
    total += w;
    if (cm.nonLinear && !cm.threePhase) singlePhaseNonLinear += w;
  }
  if (total <= 0) return 0;
  return roundTo(singlePhaseNonLinear / total, 3);
}

/// The line current a way adds to the PHASE balance (and so to the incomer's
/// worst-phase sizing current). Round 11 — a capacitor bank's current is
/// REACTIVE and leading: it offsets the lagging load current in phasor, it
/// never adds to it arithmetically (a 20 kvar bank took a 30 kW motor board
/// from 61.5 A to 90.4 A and a 63 A incomer to 100 A). Its worst case is the
/// bank switched OFF — the load alone — so it contributes 0 here.
double _balanceCurrentA(ElectricalCircuitResult r) =>
    r.loadKind == LoadKind.capacitor ? 0.0 : r.designCurrent.amperes;

/// Round 15 — the current a busbar SECTION must carry for one way: its design
/// current, a capacitor bank at [kCapacitorSwitchingFactor] × its rated
/// current, a feeder at least its fed board's capacitor switching current.
double _busbarWayCurrentA(ElectricalCircuitResult r, ElectricalCircuit c,
    Map<String, double> feederCapacitorFloorA) {
  var a = r.designCurrent.amperes;
  if (c.loadKind == LoadKind.capacitor) a *= kCapacitorSwitchingFactor;
  final fed = c.feedsPanelId;
  final floor = fed != null ? feederCapacitorFloorA[fed] : null;
  if (floor != null && floor > a) a = floor;
  return a;
}

/// Round 15 (elec-props-3-single-phase-banks-stacked-on-one-line) — spread a
/// three-phase board's UNPINNED single-phase capacitor banks across L1/L2/L3
/// by their switching current ([kCapacitorSwitchingFactor] × Q / U0): seed
/// each line with the pinned banks and the single-phase feeders' capacitor
/// floors already on it, then place each unpinned bank, LARGEST first (ties
/// by id), on the lowest tally (ties to the lower line). Load balance (l1/l2/
/// l3) is untouched — a bank carries no balance current. A single-phase
/// board, or one with no unpinned single-phase bank, returns [balance].
PhaseBalance _spreadSinglePhaseBanks(
  PhaseBalance balance, {
  required ElectricalPanel panel,
  required List<ElectricalCircuit> branches,
  required Map<String, bool> threePhaseOf,
  Map<String, double> feederCapacitorFloorA = const {},
  Map<String, ElectricalSystem> panelSystems = const {},
}) {
  if (panel.system != ElectricalSystem.threePhase) return balance;
  final phaseV = roundTo(panel.voltage.volts / math.sqrt(3), 0);
  int? lineOf(PhaseAssignment? a) => switch (a) {
        PhaseAssignment.l1 => 0,
        PhaseAssignment.l2 => 1,
        PhaseAssignment.l3 => 2,
        _ => null,
      };
  final tally = [0.0, 0.0, 0.0];
  final free = <(String, double)>[];
  for (final c in branches) {
    if (threePhaseOf[c.id] ?? true) continue;
    if (c.feedsPanelId != null) {
      final f = feederCapacitorFloorA[c.feedsPanelId];
      final idx = lineOf(balance.assignment[c.id]);
      if (f != null && idx != null) tally[idx] += f;
      continue;
    }
    if (c.loadKind != LoadKind.capacitor || c.loadW <= 0) continue;
    final a = c.loadW / phaseV * kCapacitorSwitchingFactor;
    if (c.phaseOverride != null) {
      tally[c.phaseOverride!.index] += a;
    } else {
      free.add((c.id, a));
    }
  }
  if (free.isEmpty) return balance;
  free.sort((x, y) {
    final c = y.$2.compareTo(x.$2);
    return c != 0 ? c : x.$1.compareTo(y.$1);
  });
  final assignment = {...balance.assignment};
  const lines = [PhaseAssignment.l1, PhaseAssignment.l2, PhaseAssignment.l3];
  for (final (id, a) in free) {
    var idx = 0;
    for (var i = 1; i < 3; i++) {
      if (tally[i] < tally[idx] - 1e-9) idx = i;
    }
    tally[idx] += a;
    assignment[id] = lines[idx];
  }
  return PhaseBalance(
    l1: balance.l1,
    l2: balance.l2,
    l3: balance.l3,
    imbalancePercent: balance.imbalancePercent,
    assignment: assignment,
  );
}

/// Round 13 (regression-capacitor-panel-feeder-zero) — the worst LINE current
/// (A) a board must carry for its CAPACITOR ways alone: each bank way's rated
/// current (`Q / (√3·U_LL)` 3φ, `Q / U0` 1φ, from its kvar rating) × the
/// [kCapacitorSwitchingFactor], plus — through each feeder way — the same
/// figure of the board it feeds ([childFloorA], child panel id → A). A bank
/// adds no demand W and no balance current (its leading current offsets the
/// load in phasor, so for a MIXED board the bank-off case governs), but a
/// DEDICATED PFC board's only current IS the bank: its incomer, and the feeder
/// supplying it, must carry that current whenever the bank switches in. A
/// 3φ way loads every line; a 1φ way loads its [assignment] line (else its
/// pin, else the lightest line so far). 0 when the board holds no capacitor
/// way, directly or downstream.
double panelCapacitorFloorA(
  ElectricalPanel panel, {
  Map<String, double> childFloorA = const {},
  Map<String, ElectricalSystem> panelSystems = const {},
  Map<String, PhaseAssignment> assignment = const {},
}) {
  final lines = [0.0, 0.0, 0.0];
  final threePhasePanel = panel.system == ElectricalSystem.threePhase;
  void add(String id, bool threePhase, PhaseLine? pin, double a) {
    if (a <= 0) return;
    if (!threePhasePanel) {
      lines[0] += a;
      return;
    }
    if (threePhase) {
      for (var i = 0; i < 3; i++) {
        lines[i] += a;
      }
      return;
    }
    final assigned = assignment[id];
    int idx;
    if (assigned == PhaseAssignment.l1) {
      idx = 0;
    } else if (assigned == PhaseAssignment.l2) {
      idx = 1;
    } else if (assigned == PhaseAssignment.l3) {
      idx = 2;
    } else if (pin != null) {
      idx = pin.index;
    } else {
      idx = 0;
      for (var i = 1; i < 3; i++) {
        if (lines[i] < lines[idx]) idx = i;
      }
    }
    lines[idx] += a;
  }

  for (final c in panel.circuits) {
    if (c.role != CircuitRole.branch) continue;
    if (c.feedsPanelId != null) {
      final f = childFloorA[c.feedsPanelId];
      if (f == null) continue;
      final threePhase =
          panelSystems[c.feedsPanelId] != ElectricalSystem.singlePhase &&
              threePhasePanel;
      add(c.id, threePhase, c.phaseOverride, f);
      continue;
    }
    if (c.loadKind != LoadKind.capacitor) continue;
    final threePhase = circuitIsThreePhase(
      panelSystem: panel.system,
      kind: c.loadKind,
      loadW: c.loadW,
      phases: c.phases,
    );
    final phaseV = threePhasePanel
        ? roundTo(panel.voltage.volts / math.sqrt(3), 0)
        : panel.voltage.volts;
    // Round 15 — Q / (√3·U): a bank's current carries no cos φ divisor.
    final rated = loadCurrent(
      power: Power(c.loadW),
      voltage: Voltage(threePhase ? panel.voltage.volts : phaseV),
      cosPhi: 1.0,
      threePhase: threePhase,
    ).amperes;
    add(c.id, threePhase, c.phaseOverride, rated * kCapacitorSwitchingFactor);
  }
  final worst = math.max(lines[0], math.max(lines[1], lines[2]));
  return roundTo(worst, 1);
}

/// Round 13 — the root (utility-fed) panel that GOVERNS the service: the
/// largest incomer rating, then the largest worst-phase demand current, then
/// the lowest id — so the supply summary and the main earthing / bonding
/// conductors never depend on panel list order. Null when [roots] is empty.
ElectricalPanel? governingRootPanel(
  List<ElectricalPanel> roots,
  Map<String, ElectricalPanelResult> results,
) {
  ElectricalPanel? best;
  for (final r in roots) {
    if (best == null) {
      best = r;
      continue;
    }
    final a = results[r.id];
    final b = results[best.id];
    final ra = a?.incomer.breaker.ratingA.amperes ?? 0;
    final rb = b?.incomer.breaker.ratingA.amperes ?? 0;
    if (ra != rb) {
      if (ra > rb) best = r;
      continue;
    }
    final da = a?.demandCurrent.amperes ?? 0;
    final db = b?.demandCurrent.amperes ?? 0;
    if (da != db) {
      if (da > db) best = r;
      continue;
    }
    if (r.id.compareTo(best.id) < 0) best = r;
  }
  return best;
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

  const _CircuitComputation(this.result, this.warnings, this.effectiveLoadW,
      this.threePhase, this.nonLinear);
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
  // elec-props-2 — a feeder converts the fed board's demand W at that board's
  // real power factor (see [ComputePanelOptions.feederPowerFactor]).
  // Round 15 (regression-capacitor-ib-divides-by-stale-cosphi) — a capacitor
  // bank has no meaningful power factor: its current is I = Q / (√3·U) (3φ)
  // or Q / U0 (1φ) from its kvar. A way re-kinded to Capacitor in the
  // inspector kept its old cos φ (0.85) and was sized 1/0.85 ≈ 18 % high.
  final cosPhi = c.loadKind == LoadKind.capacitor
      ? 1.0
      : (isFeeder && c.feedsPanelId != null)
          ? (opts.feederPowerFactor[c.feedsPanelId] ?? c.cosPhi)
          : c.cosPhi;

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
          // Round 14 (elec-building-sim-1) — a capacitor way's demand W is 0
          // (circuitConnectedW: a bank draws no real power), so the phase
          // decision reads its kvar RATING — the same figure its Ib, the
          // selectivity pre-pass and [panelCapacitorFloorA] use. An Auto-phase
          // 50 kvar bank on a 3φ board used to size 1φ at 216 A (MCCB 315 A,
          // 300 mm²) instead of 3φ at 72 A.
          loadW: c.loadKind == LoadKind.capacitor ? c.loadW : loadW,
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
  // Round 13 (elec-props-2-motor-ib-undiversified) — the UNDIVERSIFIED full-
  // load current of a motor / A5-FLA way. Its own device + conductor size on
  // this (one machine does not diversify against itself), while its DESIGN
  // current — the figure that feeds the phase balance, the board's demand
  // current and the incomer — carries the same demand factor
  // [circuitConnectedW] applies to the way's watts. Before, the design current
  // was the undiversified FLC while the feeder / upstream demand W was
  // diversified, so a df-0.5 duty/standby pump pair put a 125 A incomer on a
  // sub-board fed by an 80 A feeder under a 63 A main incomer.
  Current? undiversifiedFlc;
  if (c.flaOverrideA != null) {
    undiversifiedFlc = c.flaOverrideA!;
  } else if (motorLike) {
    // Shaft kW → electrical input kW via the assumed efficiency (// VERIFY).
    undiversifiedFlc = loadCurrent(
      power: Power.kiloWatts(c.motorKw! / kAssumedMotorEfficiency),
      voltage: Voltage(useVoltageV),
      cosPhi: cosPhi,
      threePhase: threePhase,
    );
  }
  if (undiversifiedFlc != null) {
    final dfEff = isFeeder
        ? 1.0
        : effectiveDemandFactor(c,
            library: opts.diversityLibrary,
            diversityLibraryId: panel.diversityLibraryId);
    ib = Current(undiversifiedFlc.amperes * dfEff);
  } else {
    ib = loadCurrent(
      // A capacitor way carries no demand W (see [circuitConnectedW]) but its
      // own line current is real: Ib = Q / (√3·U) from its kvar rating.
      power: Power(c.loadKind == LoadKind.capacitor ? c.loadW : loadW),
      voltage: Voltage(useVoltageV),
      cosPhi: cosPhi,
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
  //
  // Round 11 — GENERALISED from sockets to EVERY final way: one machine does
  // not diversify against itself, so a final way's own device + conductor
  // always size on its undiversified current (a 2.5 PK AC at df 0.9 drew
  // 10.5 A and got a 10 A breaker — Ib > In, a trip on normal running; a
  // 54.5 kW chiller got 25 mm² against its own 1.25·Ib rule). Motor / A5-FLA
  // ways already derive Ib from the undiversified input, and a feeder IS an
  // aggregation, so both keep `ib`.
  final sizeOnUndiversifiedLoad = !isFeeder;
  Current sizingCurrent;
  if (undiversifiedFlc != null) {
    // Motor / A5-FLA: device + conductor on the undiversified FLC (never below
    // the design current, so a demand factor above 1 cannot under-size it).
    sizingCurrent =
        Current(math.max(ib.amperes, undiversifiedFlc.amperes));
  } else if (sizeOnUndiversifiedLoad) {
    final undiversified = loadCurrent(
      power: Power(c.loadW),
      voltage: Voltage(useVoltageV),
      cosPhi: cosPhi,
      threePhase: threePhase,
    );
    // A demand factor above 1 must never size the device BELOW the load it
    // carries, so the sizing current is never less than the design current.
    sizingCurrent = Current(math.max(ib.amperes, undiversified.amperes));
  } else {
    sizingCurrent = ib;
  }
  // Round 13 (elec-props-2-final-vd-on-diversified-ib) — the current the run
  // REALLY carries when its machine runs: the undiversified current for a
  // final way (the same basis its cable was sized on), the aggregated Ib for a
  // feeder. The printed / cumulative voltage drop uses this, so a demand factor
  // can no longer understate a final way's drop (and hide a cumulative-limit
  // breach). Taken BEFORE the capacitor switching multiple — that factor is a
  // thermal allowance for the device, not the current that flows.
  final runCurrent = isFeeder ? ib : sizingCurrent;
  // Round 11 — a capacitor bank's switching device + conductor carry 1.43 ×
  // its rated current ([kCapacitorSwitchingFactor], IEC 60831-1 1.3 × 1.1).
  if (c.loadKind == LoadKind.capacitor) {
    sizingCurrent =
        Current(sizingCurrent.amperes * kCapacitorSwitchingFactor);
  }
  // Round 13 (regression-capacitor-panel-feeder-zero) — a feeder to a board
  // holding capacitor ways carries that bank's current whenever it is switched
  // in, even though the bank adds no demand W (and so nothing to `ib`). The
  // feeder's device + conductor floor at the fed board's capacitor switching
  // current ([ComputePanelOptions.feederCapacitorFloorA]); its voltage drop
  // uses the bank's rated current. Absent ⇒ byte-identical.
  var feederRunCurrent = runCurrent;
  final capFloorA =
      isFeeder ? opts.feederCapacitorFloorA[c.feedsPanelId] : null;
  if (capFloorA != null && capFloorA > sizingCurrent.amperes) {
    sizingCurrent = Current(capFloorA);
    final rated = capFloorA / kCapacitorSwitchingFactor;
    if (rated > feederRunCurrent.amperes) feederRunCurrent = Current(rated);
  }

  // THE LOAD-SIZED DEVICE. Deliberately floor-free: the conductor below is sized
  // against THIS pick, so a coordination floor can never inflate copper (E3).
  final loadBreaker = selectBreaker(
    profile,
    designCurrent: sizingCurrent,
    loadKind: c.loadKind,
    overrideA: c.breakerOverrideA,
  );

  // elec-props-5 — a MANUAL breaker below the current it must carry
  // (Ib > In) trips on normal load. IEC 60364-4-43 / PUIL 2011 require
  // Ib ≤ In ≤ Iz; the In ≤ Iz half is already judged (cable-ampacity-
  // inadequate), this is the Ib ≤ In half. Judge-only: the override is kept.
  if (loadBreaker.overridden &&
      loadBreaker.ratingA.amperes < sizingCurrent.amperes - 1e-9) {
    warnings.add(ElectricalWarning(
      code: 'breaker-below-design-current',
      severity: WarningSeverity.warning,
      message: '${c.name}: the ${_num(loadBreaker.ratingA.amperes)} A breaker '
          'override is below the design current '
          '${_num(roundTo(sizingCurrent.amperes, 1))} A (Ib > In) — it will '
          'trip on normal load; pick a rating at or above Ib (IEC 60364-4-43).',
      panelId: panel.id,
      circuitId: c.id,
    ));
  }

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
    // Parallel runs of this circuit group with its neighbours (the same count
    // `dfFor` folded into `df`).
    groupingCount: c.groupingCountOverride ?? panel.groupingCount,
    vd: CableVoltageDropConstraint(
      length: effectiveLength,
      cosPhi: cosPhi,
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
    current: Current(feederRunCurrent.amperes / runsPerPhase),
    length: effectiveLength,
    csaMm2: cable.csaMm2,
    cosPhi: cosPhi,
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
    // ONE family source: the explicit construction, else the drawing
    // convention for the load kind (`defaultCableFamily` — NYM finals, NYY
    // otherwise) — the SAME rule the board schedule / overview / riser print,
    // so `grounding.cableType`/`cableSpec`, the BOM line + SKU match and the
    // canvas label can never name a different cable than the issued drawing.
    // Labelling only: KHA/derating still key on the explicit `c.cableType`.
    cableType: (c.cableType != null && c.cableType!.isNotEmpty)
        ? c.cableType
        : defaultCableFamily(c.loadKind),
  );

  final rcd = circuitRcd(
    earthingSystem: opts.earthingSystem,
    loadKind: c.loadKind,
    isFinalCircuit: !isFeeder,
    designCurrent: designCurrent,
    lifeSafety: c.lifeSafety,
    // Round 11 — a VFD's 3-phase rectifier can drive SMOOTH DC earth-fault
    // current that blinds a Type A RCD: the Type B branch must be reachable.
    hasVfd: c.starterType == StarterType.vfd,
  );

  // A life-safety run with NO construction named is sized + printed on the
  // load kind's default family (NYY, PVC 70 °C) — the same spec gap as an
  // explicit non-FRC type, so it is surfaced too (audit r8 coupling-5).
  // Judge-only: the sizing basis is unchanged.
  if (c.lifeSafety && (c.cableType == null || c.cableType!.isEmpty)) {
    warnings.add(ElectricalWarning(
      code: 'life-safety-cable',
      severity: WarningSeverity.warning,
      message:
          '${c.name}: life-safety circuit has no cable type — it is sized and '
          'printed as ${defaultCableFamily(c.loadKind)}; specify fire-resistant '
          'cable (FRC/MICA) so the run survives a fire.',
      panelId: panel.id,
      circuitId: c.id,
    ));
  }
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
      message: '${c.name}: voltage drop ${vd.dropPercent}% exceeds the '
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
  //
  // Round 19 (electrical-parity-2-ampacity-error-message-wrong-comparison) —
  // the message states the requirement that actually FAILED: the sizer needs
  // Iz ≥ max(In, 1.25 × Ib) (the continuous-load rule, `notAnSniClause`), so
  // a large feeder can have Iz ≥ In and still fail on 1.25 × Ib. Printing
  // "Iz 1024.4 A is below the breaker In 1000 A (In > Iz)" was arithmetically
  // false beside its own figures.
  if (!cable.ampacityReached) {
    final iz = roundTo(cable.deratedIz.amperes, 1);
    final inA = breaker.ratingA.amperes;
    final f = cable.continuousLoadFactor ??
        profile.continuousLoadFactor.value;
    final ibA = (cable.izBasisCurrent ?? designCurrent).amperes;
    final contA = roundTo(f * ibA, 1);
    final reqA = roundTo(
        cable.izRequired?.amperes ?? math.max(inA, f * ibA), 1);
    final runs = cable.runsPerPhase ?? 1;
    final section =
        '${runs > 1 ? '${runs}x' : ''}${_num(cable.csaMm2)} mm2';
    final inBelowCont = inA + 1e-9 < f * ibA;
    final inShort = inA > iz + 1e-9;
    warnings.add(ElectricalWarning(
      code: 'cable-ampacity-inadequate',
      severity: WarningSeverity.error,
      message:
          '${c.name}: cable ampacity Iz ${_num(iz)} A at $section is below the '
          'required max(In ${_num(inA)} A, ${_num(f)} x Ib '
          '${_num(roundTo(ibA, 1))} A = ${_num(contA)} A) = ${_num(reqA)} A '
          'even at the largest section'
          '${inShort ? ' — the breaker no longer protects the conductor (In > Iz)' : ' — the conductor cannot carry the continuous load (the ${_num(f * 100)} % continuous-load rule, VERIFY: general practice, not a PUIL clause)'}'
          '${inBelowCont ? '; the ${_num(inA)} A breaker is itself below ${_num(f)} x Ib' : ''}. '
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
    runCurrent: Current(roundTo(feederRunCurrent.amperes, 1)),
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
        insulation:
            insulationForCableType(c.cableType, fallback: panel.insulation),
        soilThermalResistivityKmW: opts.soilThermalResistivityKmW,
        groundTempC: panel.groundTempC,
        depthM: panel.depthM,
      );

  final comps = branches
      .map((c) => _computeCircuit(profile, c, panel, dfFor(c), opts))
      .toList();

  // Balance single-phase circuits across L1/L2/L3; pinned phases are honoured.
  final loadBalance = balancePhases(
    [
      for (var i = 0; i < comps.length; i++)
        _PhaseCircuit(
          comps[i].result.circuitId,
          comps[i].threePhase,
          _balanceCurrentA(comps[i].result),
          branches[i].phaseOverride,
        ),
    ],
    panel.system,
    prior: opts.priorAssignment,
    reassignThresholdA: opts.phaseReassignThresholdA,
  );
  // Round 15 (elec-props-3-single-phase-banks-stacked-on-one-line) — a bank
  // adds no balance current, so the load balancer had no signal to spread
  // unpinned single-phase capacitor banks and stacked them all on L1 (three
  // 10 kvar banks → 185.7 A on R, a 200 A incomer, S and T uncompensated).
  // A separate deterministic pass spreads them by their SWITCHING current.
  final balance = _spreadSinglePhaseBanks(
    loadBalance,
    panel: panel,
    branches: branches,
    threePhaseOf: {
      for (var i = 0; i < comps.length; i++)
        comps[i].result.circuitId: comps[i].threePhase,
    },
    feederCapacitorFloorA: opts.feederCapacitorFloorA,
    panelSystems: opts.panelSystems,
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
  // elec-props-3 — with no phase PIN and no prior seed on any single, the
  // assignment is the ENGINE's own (exact for ≤ kPhaseExactSearchMaxWays
  // singles, by the min-worst-phase objective the incomer sizes on), so no
  // re-assignment is an action the engineer could take: never "reducible".
  final engineOwned = !branches.asMap().entries.any((e) =>
      !comps[e.key].threePhase &&
      (e.value.phaseOverride != null ||
          opts.priorAssignment.containsKey(e.value.id)));
  if (overImbalanceLimit) {
    // The average line current is assignment-invariant (the same total load is
    // shared out however the ways are placed), so the achievable imbalance is
    // the achievable SPREAD measured against the same average.
    final avgA = (balance.l1 + balance.l2 + balance.l3) / 3;
    final bestSpreadA = minimumPhaseSpreadA([
      for (final cm in comps)
        if (!cm.threePhase) _balanceCurrentA(cm.result),
    ]);
    bestImbalancePercent =
        avgA > 0 ? roundTo((bestSpreadA / avgA) * 100, 1) : 0.0;
    imbalanceReducible = !engineOwned &&
        bestImbalancePercent + kPhaseImbalanceReducibleMarginPercent <
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
      message: 'Phase loading is unbalanced by ${balance.imbalancePercent}% '
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
      message: 'Phase loading is unbalanced by ${balance.imbalancePercent}% '
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
  // Round 13 — the board's capacitor switching current (its own banks + any
  // fed downstream) floors the incomer + busbar: a dedicated PFC board whose
  // only current is the bank no longer gets a 6 A incomer. 0 ⇒ byte-identical.
  final capacitorFloorA = panelCapacitorFloorA(
    panel,
    childFloorA: opts.feederCapacitorFloorA,
    panelSystems: opts.panelSystems,
    assignment: balance.assignment,
  );
  final serviceGoverns = serviceFloorA > futureDemandCurrentA &&
      serviceFloorA >= capacitorFloorA;
  final capacitorGoverns = !serviceGoverns &&
      capacitorFloorA > futureDemandCurrentA;
  final incomerSizingCurrentA = serviceGoverns
      ? roundTo(serviceFloorA, 1)
      : capacitorGoverns
          ? capacitorFloorA
          : futureDemandCurrentA;

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
        : capacitorGoverns
            ? 'capacitor-bank switching current'
            : '${headroomApplied ? 'future ' : ''}demand';
    warnings.add(ElectricalWarning(
      code: 'incomer-exceeds-range',
      severity: WarningSeverity.error,
      message: '${panel.name}: $basis '
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
          // Round 15 (elec-props-3-busbar-section-ignores-capacitor-
          // switching) — a section carries what the way's own protection
          // admits: a bank at its SWITCHING current, a feeder to a capacitor
          // board at least that board's switching current (it adds no W, so
          // its Ib alone is 0 A).
          _busbarWayCurrentA(comps[i].result, branches[i],
              opts.feederCapacitorFloorA),
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
      message: '${panel.name}: single-phase non-linear load '
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
    capacitorCurrentA: capacitorFloorA,
    phaseBalance: PhaseBalanceResult(
      l1: balance.l1,
      l2: balance.l2,
      l3: balance.l3,
      imbalancePercent: balance.imbalancePercent,
      imbalanceReducible: imbalanceReducible,
    ),
    warnings: warnings,
    diversityFactor: panel.diversityFactor,
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
        message: '${child!.name}: a three-phase panel cannot be fed from the '
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
  // elec-props-2 — the same bottom-up sum in VA (each leaf W ÷ its own cos φ,
  // each feeder W ÷ its fed board's power factor), so every board carries its
  // REAL power factor = demand W / demand VA for the feeder that supplies it.
  // Arithmetic VA (not phasor) — conservative: never above the true pf.
  final panelDemandVa = <String, double>{};
  final panelPowerFactor = <String, double>{};
  for (final id in postOrder) {
    final panel = byId[id];
    if (panel == null) continue;
    final feederLoadW = <String, double>{};
    var connectedW = 0.0;
    var connectedVa = 0.0;
    for (final c in panel.circuits) {
      if (c.role != CircuitRole.branch) continue;
      final load = c.feedsPanelId != null
          ? (panelDemandW[c.feedsPanelId] ?? 0)
          : circuitConnectedW(c,
              library: diversityLibrary,
              diversityLibraryId: panel.diversityLibraryId);
      if (c.feedsPanelId != null) feederLoadW[c.feedsPanelId!] = load;
      connectedW += load;
      final pf = c.feedsPanelId != null
          ? (panelPowerFactor[c.feedsPanelId] ?? c.cosPhi)
          : c.cosPhi;
      connectedVa += pf > 0 ? load / pf : load;
    }
    feederLoadWByPanel[id] = feederLoadW;
    panelDemandW[id] = connectedW * panel.diversityFactor;
    panelDemandVa[id] = connectedVa * panel.diversityFactor;
    if (connectedVa > 0 && connectedW > 0) {
      panelPowerFactor[id] = math.min(1.0, connectedW / connectedVa);
    }
  }

  // Round 13 — bottom-up capacitor switching current per board (its own banks
  // + every board it feeds), so a feeder to a PFC board floors at the bank's
  // current (see [ComputePanelOptions.feederCapacitorFloorA]). Boards with no
  // capacitor way anywhere below are absent ⇒ byte-identical.
  final capacitorFloorByPanel = <String, double>{};
  for (final id in postOrder) {
    final panel = byId[id];
    if (panel == null) continue;
    final f = panelCapacitorFloorA(panel,
        childFloorA: capacitorFloorByPanel, panelSystems: panelSystems);
    if (f > 0) capacitorFloorByPanel[id] = f;
  }
  // Round 14 (regression-capacitor-floor-phase-model-mismatch) — the figure a
  // FEEDER floors at must be the SAME one its fed board's incomer floors at.
  // That board places each single-phase bank on the line its phase BALANCE
  // assigned (a bank adds no balance current, so the balancer may stack two
  // banks on L1), while the estimate above put unpinned banks on the
  // 'lightest line' — an 80 A / 25 mm² feeder then supplied a board whose
  // incomer floored at 123.8 A. Re-solve each capacitor-bearing board
  // bottom-up with the very `computePanel` the sizing pass runs (its balance
  // assignment is a function of the board's own ways + the floors below it,
  // never of its parent or the fault level) and take ITS
  // `capacitorCurrentA`. Boards with no capacitor anywhere below are skipped
  // ⇒ byte-identical.
  if (capacitorFloorByPanel.isNotEmpty) {
    for (final id in postOrder) {
      final panel = byId[id];
      if (panel == null || !capacitorFloorByPanel.containsKey(id)) continue;
      final solved = computePanel(
        profile,
        panel,
        opts: ComputePanelOptions(
          feederLoadW: feederLoadWByPanel[id] ?? const {},
          feederPowerFactor: panelPowerFactor,
          feederCapacitorFloorA: capacitorFloorByPanel,
          panelSystems: panelSystems,
          earthingSystem: project.earthingSystem,
          calibrationBySheet: calibrationBySheet,
          building: building,
          panelById: byId,
          diversityLibrary: diversityLibrary,
          priorAssignment: priorAssignments[id] ?? const {},
          phaseReassignThresholdA: phaseReassignThresholdA,
        ),
      ).capacitorCurrentA;
      if (solved > 0) capacitorFloorByPanel[id] = solved;
    }
  }

  // True building connected load = leaf loads only (feeders are aggregations).
  var connectedLoadW = 0.0;
  for (final p in panels) {
    for (final c in p.circuits) {
      if (c.role == CircuitRole.branch && c.feedsPanelId == null) {
        connectedLoadW += circuitConnectedW(c,
            library: diversityLibrary,
            diversityLibraryId: p.diversityLibraryId);
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
    final panelNeutralZ = <String, Impedance>{};

    // Size every panel (root-first is fine for the core; demand is precomputed).
    final results = <String, ElectricalPanelResult>{};
    for (final id in postOrder.reversed) {
      final panel = byId[id];
      if (panel == null) continue;

      // Prospective fault + source impedance at this bus (FOLD 1), when enabled.
      Current? faultLevelA;
      if (applyWithstand) {
        // Source Z on the LV network LINE basis (a 1-phase board stores its
        // 220 V phase voltage — same voltage basis as `faultStudy`).
        final lineVoltageV = faultBasisLineVoltageV(panel);
        final parentId = parentOf[id];
        final feederId = feederCircuitOf[id];
        final double faultA;
        final Impedance sourceZ;
        final Impedance neutralZ;
        if (parentId == null || feederId == null) {
          // Root / utility-fed panel — the full origin fault.
          faultA = originIscA;
          sourceZ = sourceImpedanceFromIsc(originIscA, lineVoltageV);
          neutralZ = const Impedance(0, 0);
        } else {
          final upstreamIscA = panelFaultA[parentId] ?? originIscA;
          final upstreamSourceZ = panelSourceZ[parentId] ??
              sourceImpedanceFromIsc(originIscA, lineVoltageV);
          final feederResult = results[parentId]
              ?.circuits
              .where((c) => c.circuitId == feederId)
              .firstOrNull;
          final feederModel = byId[parentId]
              ?.circuits
              .where((c) => c.id == feederId)
              .firstOrNull;
          final csa = feederResult?.cable.csaMm2 ?? 0;
          final runs = (feederResult?.cable.runsPerPhase ?? 1) > 1
              ? feederResult!.cable.runsPerPhase!
              : 1;
          // The run the feeder was SIZED on (geo when placed) and the PARENT's
          // conductor material (the parent sized this feeder cable).
          final lengthM = solvedRunLengthM(feederResult, feederModel);
          final feederMaterial = byId[parentId]?.material ?? panel.material;
          final single =
              conductorImpedance(profile, csa, lengthM, feederMaterial);
          final feederZ = Impedance(single.rOhm / runs, single.xOhm / runs);
          // Round 17 — the maximum (withstand) fault decays through the
          // conductor at 20 °C (IEC 60909-0), the same basis `faultStudy`
          // uses for the device kA, so the bus Icw and the tokens agree.
          sourceZ =
              upstreamSourceZ + coldMaxFaultImpedance(feederZ, feederMaterial);
          neutralZ = (panelNeutralZ[parentId] ?? const Impedance(0, 0)) +
              coldMaxFaultImpedance(
                  feederNeutralImpedance(
                      profile,
                      csa,
                      feederResult?.grounding.neutralCsaMm2 ?? 0,
                      lengthM,
                      feederMaterial,
                      runs),
                  feederMaterial);
          // 3-phase board: V_LL/(√3·|Z|); 1-phase board: the L-N fault
          // U0/|Z_phase + Z_neutral| (never 220 V in the 3-phase formula).
          faultA = subPanelBusFaultA(panel, sourceZ, neutralZ, upstreamIscA);
        }
        panelFaultA[id] = faultA;
        panelSourceZ[id] = sourceZ;
        panelNeutralZ[id] = neutralZ;
        faultLevelA = Current(faultA);
      }

      results[id] = computePanel(
        profile,
        panel,
        opts: ComputePanelOptions(
          feederLoadW: feederLoadWByPanel[id] ?? const {},
          feederPowerFactor: panelPowerFactor,
          feederCapacitorFloorA: capacitorFloorByPanel,
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
          serviceMinCurrentA: roots.length == 1 && id == roots.first.id
              ? serviceMinCurrentA
              : null,
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
        demandVa: roundTo(
            math.max(panelDemandVa[id] ?? 0, pr.demandW), 0),
        futureLoadW: pr.futureLoadW,
        headroomApplied: pr.headroomApplied,
        spareWaysReserved: pr.spareWaysReserved,
        capacitorCurrentA: pr.capacitorCurrentA,
        phaseBalance: pr.phaseBalance,
        warnings: pr.warnings,
        diversityFactor: pr.diversityFactor,
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
        // elec-props-4 — the feeder sizes on the fed board's DIVERSIFIED
        // demand (connected × diversityFactor), while `demandCurrent` is the
        // board's undiversified worst-phase current. Compare like with like:
        // the worst phase at the same diversity, so a perfectly balanced board
        // with diversity < 1 is no longer told its feeder is too small.
        final childDiversity = byId[childId]?.diversityFactor ?? 1.0;
        final childDemandA =
            roundTo(childResult.demandCurrent.amperes * childDiversity, 1);
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

    // Round 15 (elec-props-3-subboard-headroom-not-carried-by-feeder) —
    // JUDGE-ONLY: a sub-board's FUTURE-LOAD headroom rates ITS incomer + bus
    // for the uplifted demand, but by design (the headroom invariant) the
    // feeder and every board upstream keep sizing on TODAY's demand. When the
    // feeder breaker is below the fed board's future worst-phase current the
    // reserved capacity can never be drawn (the planned load would trip the
    // feeder first) — the spec is silently unfulfillable, so say so. Never
    // resizes: raise the feeder (a breaker override) or drop the headroom.
    for (final id in postOrder.reversed) {
      final parent = byId[id];
      final pr = results[id];
      if (parent == null || pr == null) continue;
      for (final c in parent.circuits) {
        final childId = c.feedsPanelId;
        if (childId == null) continue;
        final child = byId[childId];
        final childResult = results[childId];
        final feederResult =
            pr.circuits.where((r) => r.circuitId == c.id).firstOrNull;
        if (child == null || childResult == null || feederResult == null) {
          continue;
        }
        final multiplier =
            (child.headroom ?? HeadroomSpec.none).demandMultiplier;
        if (multiplier <= 1.0 + 1e-9) continue;
        final futureA = roundTo(
            childResult.demandCurrent.amperes *
                child.diversityFactor *
                multiplier,
            1);
        final feederRatingA = feederResult.breaker.ratingA.amperes;
        if (futureA <= 0 || feederRatingA + 1e-9 >= futureA) continue;
        pr.warnings.add(ElectricalWarning(
          code: 'feeder-below-fed-headroom',
          severity: WarningSeverity.warning,
          message:
              '${c.name}: ${childResult.name} reserves future load to '
              '${_num(futureA)} A on its worst-loaded phase, but its feeder '
              'breaker is ${_num(feederRatingA)} A — the reserved capacity '
              'cannot be drawn; raise the feeder rating (and the boards '
              'upstream) or reduce the headroom.',
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
          message: '${rootResult.name}: demand '
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

    // JUDGE-ONLY essential-supply check (audit r8 coupling-5): a life-safety
    // way (fire pump, smoke control …) on a board that is NOT on the essential
    // (genset-backed) path loses supply exactly when it is needed. A board is
    // essential when it, or any board upstream of it, carries the explicit
    // `essential` flag or an essential NAME ([isEssentialByName], Round 19).
    // Never resizes.
    bool onEssentialPath(String id) {
      final seen = <String>{};
      String? cur = id;
      while (cur != null && seen.add(cur)) {
        // Round 19 — the SAME essential set as the genset backing / SLD
        // colour split: the explicit flag OR the one name heuristic.
        final b = byId[cur];
        if (b != null && (b.essential || isEssentialByName(b.name))) {
          return true;
        }
        cur = parentOf[cur];
      }
      return false;
    }

    for (final p in panels) {
      if (onEssentialPath(p.id)) continue;
      final pr = results[p.id];
      if (pr == null) continue;
      for (final c in p.circuits) {
        if (!c.lifeSafety || c.isFeeder) continue;
        pr.warnings.add(ElectricalWarning(
          code: 'life-safety-not-essential',
          severity: WarningSeverity.warning,
          message: '${c.name}: life-safety load on ${p.name}, which is not on '
              'the essential (genset-backed) supply — feed it from an essential '
              'board or mark ${p.name} essential.',
          panelId: p.id,
          circuitId: c.id,
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
    // Round 13 (elec-props-2-multiroot-earthing-first-root) — with several
    // utility-fed roots the SERVICE (supply system / voltage, main cable,
    // main earthing + bonding conductors) is governed by the LARGEST root, not
    // whichever happened to be listed first: largest incomer rating, then
    // largest worst-phase demand current, then the lowest id (deterministic).
    // A 250 A 3φ root listed after a 1φ lighting board used to print a 16 mm²
    // main earthing conductor and a single-phase 230 V supply. One root ⇒ that
    // root ⇒ byte-identical.
    final governingRoot = governingRootPanel(roots, results);
    final supplySystem =
        governingRoot?.system ?? ElectricalSystem.threePhase;
    final supplyVoltage = governingRoot?.voltage ?? const Voltage(400);
    // Round 14 (elec-building-sim-2) — the supply kVA (genset size, the
    // 'backs NN %' label, transformer + daya tiers) comes from the engine's
    // OWN per-circuit cos φ: each root's diversified demand VA, aggregated
    // bottom-up exactly like its demand W (Σ leaf W / cos φ, a feeder at its
    // fed board's VA, × diversity) — the same per-board power factor the
    // feeder sizing and the PF study use. The flat 0.85 PF stays only as the
    // fallback for a root with no VA record. A 60 kW chiller at cos φ 0.72
    // used to print 89.4 kVA (W / 0.85) against ~103 kVA really drawn, so a
    // 100 kVA genset was labelled 'backs 100 %'. Never below the demand W.
    var rootDemandVa = 0.0;
    for (final r in roots) {
      final w = panelDemandW[r.id] ?? 0;
      final va = panelDemandVa[r.id];
      rootDemandVa +=
          va != null && va > 0 ? math.max(va, w) : w / assumedBuildingPf;
    }
    final supply = SupplySummary(
      connectedW: roundTo(connectedLoadW, 0),
      demandW: roundTo(rootDemandW, 0),
      demandVa: ApparentPower(roundTo(rootDemandVa, 0)),
      system: supplySystem,
      voltage: supplyVoltage,
    );

    // Earthing system designed from the main incomer's PE conductor. The
    // service-capacity floor rides along (when it governs), so the service PE
    // tracks the entrance device the same floor sized.
    final mainResult =
        governingRoot != null ? results[governingRoot.id] : null;
    // Round 12 (report-recompute-earthing-ignores-headroom) — with a future-
    // load HEADROOM on the root, the incomer is rated for the future load
    // (demand × multiplier), so the service cable — and the main earthing /
    // bonding conductors derived from its PE — are sized for the device that
    // protects it: the root's ACTUAL incomer rating as both the design
    // current and the breaker rating. Today's bare demand used to size them
    // for a 50 A service while headroom had doubled the incomer to 100 A
    // (16 / 10 mm² printed vs 25 / 16 mm² required). No headroom ⇒ the
    // demand basis below ⇒ byte-identical.
    //
    // Round 14 (regression-capacitor-governed-root-earthing-undersized) — the
    // same holds for EVERY reason the root incomer is rated above the device
    // its demand would select: the Round-13 capacitor switching floor (a
    // 100 kvar bank fed downstream lifts a 63 A board to 250 A) printed the
    // 63 A service's 16 / 10 mm² earthing behind a 250 A incomer. Whenever
    // the incomer exceeds the demand-selected breaker, the service is sized
    // for the incomer.
    final mainDemandIb = mainResult?.demandCurrent ?? const Current(0);
    final rootHeadroomActive =
        (governingRoot?.headroom ?? HeadroomSpec.none).isActive;
    final incomerRating = mainResult?.incomer.breaker.ratingA;
    final demandIb = serviceMinCurrentA != null &&
            serviceMinCurrentA > mainDemandIb.amperes
        ? Current(roundTo(serviceMinCurrentA, 1))
        : mainDemandIb;
    final demandBreaker =
        selectBreaker(profile, designCurrent: demandIb, loadKind: LoadKind.feeder);
    final incomerFloored = incomerRating != null &&
        (rootHeadroomActive ||
            incomerRating.amperes > demandBreaker.ratingA.amperes + 1e-9);
    final mainIb = incomerFloored ? incomerRating : demandIb;
    final mainBreaker = incomerFloored ? null : demandBreaker;
    final mainCable = sizeCable(
      profile,
      designCurrent: mainIb,
      breakerRating: mainBreaker?.ratingA ?? incomerRating!,
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
      final feederResult = pass1.panels[p.id]?.circuits
          .where((r) => r.circuitId == c.id)
          .firstOrNull;
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
