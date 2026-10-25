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
// Round 52 — the supply study's ONE assembly ([studySupplyDesign]) feeds the
// fault estimate here too, so the ADS / selectivity fault origin is the
// transformer the advanced study prints (a library cycle, legal in Dart: the
// helper is a pure function of the solved result).
import 'advanced_study.dart' show studySupplyDesign;
import 'busbar.dart';
import 'cable_family.dart';
import 'containment.dart' show effectiveInstallMethod;
import 'control/starter.dart' show StarterType, effectiveStarterType;
import 'diversity_library.dart' show DiversityLibrary;
import 'earthing.dart';
// `fault.dart` is a pure post-processing pass that imports neither this file nor
// anything that reaches it (puil/units/earthing/load_kind/model/panel_results
// only), so taking `selectivityRatio` from it introduces no import cycle.
import 'fault.dart'
    show
        Impedance,
        conductorImpedance,
        breakingCapacityKa,
        coldMaxFaultImpedance,
        defaultLvUtilityFaultKa,
        estimatedServiceFaultLevelA,
        faultBasisLineVoltageV,
        kMccbMagneticTripMultiple,
        faultStudy,
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
import 'results.dart'
    show
        BreakerResult,
        CableResult,
        VoltageDropResult,
        kStarDeltaInternalWiringM;
import 'sizing.dart';
import 'supply_design.dart' show plnDayaVa1ph;
import 'ups.dart';

export 'ups.dart' show kUpsEfficiency, kUpsRechargeAllowance, kUpsInputFactor;

/// The LV line voltage (V) of a PLN 3-phase service (230/400 V system) — the
/// basis a declared 3φ-only daya is converted on when the service-entrance
/// board is single-phase (Round 38). // VERIFY — secondarySource (PUIL /
/// SPLN 1 nominal, the profile's `nominalLineVoltage`).
const double kThreePhaseServiceLineVoltageV = 400;

/// Round 38 (elec-protection-mcb-on-high-fault-bus) — a rating ≤ 63 A is an
/// MCB only while the MCB breaking-capacity ladder (top rung
/// `breakingCapacityKa[mcb].last`, 25 kA) covers the prospective fault at the
/// bus it sits on; above that the SAME rating is specified as an MCCB (MCCB
/// frames start at 16 A and reach 70 kA, so the fault study then specifies a
/// rung that clears the fault instead of an un-actionable Icu error on every
/// ≤ 63 A way of a ≥ ~700 kVA main board: 25e3·√3·400·0.04 = 693 kVA). The
/// rating, curve and override flag are kept. An unknown bus fault (null / 0)
/// keeps the rating-only class ⇒ byte-identical. Pure.
// VERIFY — notAnSniClause (device-class practice, IEC 60898-1 vs 60947-2).
///
/// Round 39 (regression-fault-aware-class-mints-nonexistent-small-mccb) — an
/// MCCB frame starts at [kMccbMinFrameA]: a converted rating below it is
/// RAISED to the frame minimum (no 6 A / 10 A MCCB exists), but only while
/// that stays ≤ [maxRatingA] (the way's cable derated Iz — In ≤ Iz is
/// inviolable) and the rating is not the engineer's override. Otherwise the
/// MCB is KEPT (it then needs back-up / cascade protection from the upstream
/// device — see [mcbNeedsBackupProtection]).
///
/// Round 43 (electrical-sim-8-mccb-frame-raise-breaks-ads) — [allowFrameRaise]
/// false keeps a sub-frame MCB (never raised to the 16 A MCCB frame): the
/// caller (`computeSystem`) passes it for a FINAL way whose frame-raised
/// rating fails the earth-fault loop (ADS) — a device-class rule must never
/// create a safety non-compliance the load-sized device did not have.
///
/// Round 54 (elec-convergence-6-mcb-class-swap-creates-ads-failure) — the
/// CLASS change itself can fail ADS: a non-MCB device is judged at
/// `max(10, curve multiple) × In` (`kMccbMagneticTripMultiple`), which halves a
/// B-curve way's Zs limit (a 16 A 2.5 mm² 60 m life-safety lighting way:
/// 1.368 ohm passes 0.95·230/(5·16) = 2.731 ohm as an MCB, fails
/// 0.95·230/(10·16) = 1.365 ohm as the converted MCCB). So [allowClassChange]
/// false keeps the load-sized MCB for ANY rating — the frame raise and the
/// class change alike — and the way takes the existing back-up (cascade)
/// path instead.
BreakerResult faultAwareBreakerClass(BreakerResult b, Current? busFault,
    {Current? maxRatingA, bool allowClassChange = true}) {
  if (!_mcbBelowBusFault(b, busFault)) return b;
  if (!allowClassChange) return b;
  var rating = b.ratingA.amperes;
  if (rating < kMccbMinFrameA - 1e-9) {
    if (b.overridden) return b;
    if (maxRatingA != null && kMccbMinFrameA > maxRatingA.amperes + 1e-9) {
      return b;
    }
    rating = kMccbMinFrameA;
  }
  return BreakerResult(
    ratingA: Current(rating),
    deviceClass: BreakerClass.mccb,
    curve: b.curve,
    overridden: b.overridden,
  );
}

/// Round 39 — the smallest MCCB frame rating (A). // VERIFY — notAnSniClause
/// (manufacturer frame practice: MCCB ranges start at 16 A).
const double kMccbMinFrameA = 16;

bool _mcbBelowBusFault(BreakerResult b, Current? busFault) {
  if (b.deviceClass != BreakerClass.mcb || busFault == null) return false;
  final mcbTopKa = breakingCapacityKa[BreakerClass.mcb]!.last;
  return busFault.amperes / 1000.0 > mcbTopKa + 1e-9;
}

/// Round 39 — true when [faultAwareBreakerClass] had to KEEP an MCB on a bus
/// whose prospective fault exceeds the MCB breaking-capacity ladder (the way
/// is below the MCCB frame minimum and its cable cannot take a 16 A MCCB):
/// the MCB then relies on back-up (cascade) protection by the upstream
/// device (IEC 60898-1 Annex D / IEC 60947-2 Annex A). Pure.
bool mcbNeedsBackupProtection(BreakerResult chosen, Current? busFault) =>
    _mcbBelowBusFault(chosen, busFault);

/// Practical building power factor used to convert demand kW → kVA for the
/// supply summary (matches PanelMaker `ASSUMED_BUILDING_PF`). Not a PUIL clause.
const double assumedBuildingPf = 0.85;

// The assumed motor efficiency (shaft kW → electrical input kW) lives in
// `load_kind.dart` as [kAssumedMotorEfficiency] so the power-factor pass reads
// the SAME figure as the Ib derivation below.

/// Round 37 — the current-carrying-capacity reduction for a cable whose
/// NEUTRAL carries triplen-harmonic current: four loaded conductors in one
/// sheath (IEC 60364-5-52 Annex E, Table E.52.1 reduction factor 0.86).
/// A design rule, NOT an SNI/PUIL clause. // VERIFY (notAnSniClause)
const double kFourLoadedConductorFactor = 0.86;

/// Round 37 — a fed three-phase board's triplen-neutral condition, carried up
/// to the FEEDER that supplies it: its FOLD-2 neutral factor (× phase
/// current), its DIVERSIFIED worst-phase current (A) and its single-phase
/// non-linear share (0–1).
typedef FedNeutralLoad = ({
  double factor,
  double worstPhaseA,
  double triplenFraction,
});

/// Round 37 (electrical-sim-4-dual-tx-single-root-floor-vs-fault-basis) —
/// the declared connection capacity (VA) the SERVICE-ENTRANCE board of a
/// single-root tree is rated for: the whole [ElectricalProject.supplyCapacityVa]
/// on a single-transformer / LV service, ONE section's share (half) on a
/// [ElectricalProject.dualTransformer] service. A single root board on a
/// dual service sits on one section with the bus coupler normally open —
/// the SAME one-section basis the fault estimate, the supply study and the
/// device kA use (Round 30) — so it can never be offered more than that
/// section (1 MVA dual: 500 kVA ⇒ 721.7 A ⇒ an 800 A incomer, never 1600 A
/// specified at the one-section 18 kA). Null when nothing is declared.
double? serviceEntranceCapacityVa(ElectricalProject project) {
  final cap = project.supplyCapacityVa?.voltAmperes;
  if (cap == null || cap <= 0) return null;
  return project.dualTransformer ? cap / 2 : cap;
}

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

  /// Round 37 — a 3φ FEEDER to an imbalanced 3φ board loads the parent's
  /// lines with the fed board's own diversified L1 / L2 / L3 currents, not a
  /// balanced Ib on each. Null ⇒ [currentA] on every line.
  final List<double>? lines;
  const _PhaseCircuit(this.id, this.threePhase, this.currentA, this.pinned,
      {this.lines});
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
  final seededResult = _balancePhasesOnce(circuits, system,
      prior: prior, reassignThresholdA: reassignThresholdA);
  if (prior.isEmpty || system != ElectricalSystem.threePhase) {
    return seededResult;
  }
  // Round 37 (edit-fuzz-3-1) — phase STICKINESS may only keep a labelled
  // assignment whose WORST phase (the incomer + busbar sizing basis) equals
  // the fresh, unseeded solve's (stickiness never raises the sizing current:
  // a sticky assignment up to 1 A heavier once sized a 40 A incomer where
  // 32 A suffices). A spread-only difference (the labels on site) is still
  // kept; a different worst phase never is. Round 39 r3 — the prior is the
  // document's persisted `assignedPhase`, so either outcome is a function of
  // the document alone.
  final fresh = _balancePhasesOnce(circuits, system);
  double worst(PhaseBalance b) => math.max(b.l1, math.max(b.l2, b.l3));
  final chosen =
      (worst(seededResult) - worst(fresh)).abs() > 1e-9 ? fresh : seededResult;
  // Round 40 (elec-props-6-phase-labels-not-restored-after-mep-add-remove) —
  // never adopt a solve's labels WHOLESALE: among the assignments no worse
  // than the chosen one (worst phase AND spread), take the one that moves the
  // fewest ways off their prior (labelled) line. A transient load added then
  // removed returns the board to its original labels instead of permanently
  // swapping R and T on site. A chosen assignment already on every prior line
  // is returned verbatim.
  return _minimisePriorMoves(circuits, chosen, prior);
}

/// Round 40 — the assignment of the unpinned single-phase ways that is no
/// worse than [chosen] (worst line AND spread, each within 1e-9) and leaves
/// the fewest ways off their [prior] line (ties: lower worst, then lower
/// spread, then [chosen]'s line for ways with no prior). Exact (branch and
/// bound) up to [kPhaseExactSearchMaxWays] movable ways; above it a
/// deterministic move / swap descent from [chosen]. A [chosen] with every
/// prior-listed way on its prior line is returned as is.
PhaseBalance _minimisePriorMoves(List<_PhaseCircuit> circuits,
    PhaseBalance chosen, Map<String, PhaseAssignment> prior) {
  const keys = [PhaseLine.l1, PhaseLine.l2, PhaseLine.l3];
  int idxOf(PhaseAssignment? a) => switch (a) {
        PhaseAssignment.l2 => 1,
        PhaseAssignment.l3 => 2,
        _ => 0,
      };
  final singles = circuits
      .where((c) => !c.threePhase && c.pinned == null)
      .toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  final chosenPick = [
    for (final c in singles) idxOf(chosen.assignment[c.id]),
  ];
  final priorPick = [
    for (final c in singles)
      switch (_priorLine(prior, c.id)) {
        PhaseLine.l1 => 0,
        PhaseLine.l2 => 1,
        PhaseLine.l3 => 2,
        null => -1,
      },
  ];
  var anyOff = false;
  for (var i = 0; i < singles.length; i++) {
    if (priorPick[i] >= 0 && chosenPick[i] != priorPick[i]) anyOff = true;
  }
  if (!anyOff) return chosen;

  final base = [0.0, 0.0, 0.0];
  for (final c in circuits) {
    if (c.threePhase) {
      final ls = c.lines;
      base[0] += ls?[0] ?? c.currentA;
      base[1] += ls?[1] ?? c.currentA;
      base[2] += ls?[2] ?? c.currentA;
    } else if (c.pinned != null) {
      base[c.pinned!.index] += c.currentA;
    }
  }
  List<double> linesOf(List<int> pick) {
    final l = [...base];
    for (var i = 0; i < singles.length; i++) {
      l[pick[i]] += singles[i].currentA;
    }
    return l;
  }

  double worstOf(List<double> l) => math.max(l[0], math.max(l[1], l[2]));
  final chosenLines = linesOf(chosenPick);
  final worstBound = worstOf(chosenLines) + 1e-9;
  final spreadBound =
      _spread3(chosenLines[0], chosenLines[1], chosenLines[2]) + 1e-9;
  bool admissible(List<double> l) =>
      worstOf(l) <= worstBound && _spread3(l[0], l[1], l[2]) <= spreadBound;
  int movesOf(List<int> pick) {
    var m = 0;
    for (var i = 0; i < pick.length; i++) {
      if (priorPick[i] >= 0 && pick[i] != priorPick[i]) m++;
    }
    return m;
  }

  // (moves off prior, worst, spread, moves off chosen for prior-less ways)
  (int, double, double, int) score(List<int> pick) {
    final l = linesOf(pick);
    var other = 0;
    for (var i = 0; i < pick.length; i++) {
      if (priorPick[i] < 0 && pick[i] != chosenPick[i]) other++;
    }
    return (movesOf(pick), worstOf(l), _spread3(l[0], l[1], l[2]), other);
  }

  bool better((int, double, double, int) a, (int, double, double, int) b) {
    if (a.$1 != b.$1) return a.$1 < b.$1;
    if ((a.$2 - b.$2).abs() > 1e-9) return a.$2 < b.$2;
    if ((a.$3 - b.$3).abs() > 1e-9) return a.$3 < b.$3;
    return a.$4 < b.$4;
  }

  var best = [...chosenPick];
  var bestScore = score(best);
  if (singles.length <= kPhaseExactSearchMaxWays) {
    final pick = List<int>.filled(singles.length, 0);
    final lines = [...base];
    void walk(int i, int moves) {
      if (moves > bestScore.$1) return;
      if (i == singles.length) {
        if (!admissible(lines)) return;
        final sc = score(pick);
        if (better(sc, bestScore)) {
          bestScore = sc;
          best = [...pick];
        }
        return;
      }
      // Prior line first so the cheapest assignments are reached early.
      final order = priorPick[i] >= 0
          ? [
              priorPick[i],
              for (var p = 0; p < 3; p++)
                if (p != priorPick[i]) p
            ]
          : const [0, 1, 2];
      for (final p in order) {
        pick[i] = p;
        lines[p] += singles[i].currentA;
        walk(i + 1, moves + (priorPick[i] >= 0 && p != priorPick[i] ? 1 : 0));
        lines[p] -= singles[i].currentA;
      }
    }

    walk(0, 0);
  } else {
    for (var pass = 0; pass < 40; pass++) {
      var improved = false;
      for (var i = 0; i < singles.length; i++) {
        if (priorPick[i] < 0 || best[i] == priorPick[i]) continue;
        final trial = [...best]..[i] = priorPick[i];
        if (admissible(linesOf(trial)) && better(score(trial), bestScore)) {
          best = trial;
          bestScore = score(trial);
          improved = true;
          continue;
        }
        for (var j = 0; j < singles.length; j++) {
          if (j == i || best[j] != priorPick[i]) continue;
          final swap = [...best]
            ..[i] = best[j]
            ..[j] = best[i];
          if (admissible(linesOf(swap)) && better(score(swap), bestScore)) {
            best = swap;
            bestScore = score(swap);
            improved = true;
            break;
          }
        }
      }
      if (!improved) break;
    }
  }
  if (_listEq(best, chosenPick)) return chosen;

  final assignment = <String, PhaseAssignment>{...chosen.assignment};
  for (var i = 0; i < singles.length; i++) {
    assignment[singles[i].id] = _lineAssign(keys[best[i]]);
  }
  final vals = linesOf(best);
  final maxV = vals.reduce(math.max);
  final minV = vals.reduce(math.min);
  final avg = (vals[0] + vals[1] + vals[2]) / 3;
  final imbalance = avg > 0 ? ((maxV - minV) / avg) * 100 : 0.0;
  return PhaseBalance(
    l1: roundTo(vals[0], 1),
    l2: roundTo(vals[1], 1),
    l3: roundTo(vals[2], 1),
    imbalancePercent: roundTo(imbalance, 1),
    assignment: assignment,
  );
}

bool _listEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

PhaseBalance _balancePhasesOnce(
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

  // Three-phase ways load all lines equally — except a feeder to an
  // imbalanced 3φ board, which carries that board's own line currents.
  for (final c in circuits) {
    if (c.threePhase) {
      final ls = c.lines;
      phases[PhaseLine.l1] = phases[PhaseLine.l1]! + (ls?[0] ?? c.currentA);
      phases[PhaseLine.l2] = phases[PhaseLine.l2]! + (ls?[1] ?? c.currentA);
      phases[PhaseLine.l3] = phases[PhaseLine.l3]! + (ls?[2] ?? c.currentA);
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
      // Round 31 (stress-edits-1): `from` tracks the way's CURRENT line. An
      // accepted move updates it, so the next trial never subtracts the
      // current from the line the way already left (a stale `from` counted
      // the way on two lines and dropped it from a third).
      var from = fromAssign(assignment[c.id]!);
      for (final to in keys) {
        if (to == from) continue;
        final before = spread();
        final cost = reassignCost(c.id, from, to);
        phases[from] = phases[from]! - c.currentA;
        phases[to] = phases[to]! + c.currentA;
        if (spread() < before - cost - 1e-9) {
          assignment[c.id] = _lineAssign(to);
          from = to;
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
    // Round 37 — a lower WORST phase is always taken (stickiness never
    // raises the sizing current); the threshold gates spread-only moves.
    final clearsStickiness = seeded.isEmpty ||
        curWorst - bestWorst > 1e-9 ||
        (bestWorst <= curWorst + 1e-9 &&
            curSpread - bestSpread > reassignThresholdA);
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

/// Round 48 — up to this many rotatable fed sub-boards under one parent, the
/// R/S/T relabelling search (`computeSystem`'s parent-aware rotation and the
/// reducibility floor's cyclic-permutation floor) is EXHAUSTIVE over every
/// 3^k cyclic relabelling; above it, greedy seeds + coordinate descent.
const int kRotationExhaustiveMaxBoards = 6;

double _spread3(double a, double b, double c) =>
    math.max(a, math.max(b, c)) - math.min(a, math.min(b, c));

/// Round 49 — the EXACT (unrounded) L1 / L2 / L3 sums of [circuits] under
/// [assignment]: the very sums [balancePhases] rounds to 0.1 A for print, so
/// a verdict can compare like with like.
List<double> _exactLines(
    List<_PhaseCircuit> circuits, Map<String, PhaseAssignment> assignment) {
  final l = [0.0, 0.0, 0.0];
  for (final c in circuits) {
    if (c.threePhase) {
      final ls = c.lines;
      for (var k = 0; k < 3; k++) {
        l[k] += ls?[k] ?? c.currentA;
      }
      continue;
    }
    final idx = switch (assignment[c.id]) {
      PhaseAssignment.l2 => 1,
      PhaseAssignment.l3 => 2,
      _ => 0,
    };
    l[idx] += c.currentA;
  }
  return l;
}

/// Round 49 (elec-props-13-three-level-tree-never-rotated) — the boards a
/// 'Rotate R/S/T at …' instruction must name for fed board [id]: [id] itself
/// when it holds a single-phase way of its own, plus (recursively) every
/// three-phase board below it whose feeder carries unequal lines — a
/// mid-level riser SDB with only feeders has nothing of its own to relabel,
/// its floor DBs do. Falls back to [id] when nothing below can be resolved.
List<String> _rotationHolders(
    String id, ComputePanelOptions opts, Set<String> seen) {
  final p = opts.panelById[id];
  if (p == null || !seen.add(id)) return [id];
  var own = false;
  final below = <String>[];
  for (final c in p.circuits) {
    if (c.role != CircuitRole.branch) continue;
    final fed = c.feedsPanelId;
    if (fed != null) {
      final fedSystem =
          opts.panelSystems[fed] ?? opts.panelById[fed]?.system;
      if (fedSystem == ElectricalSystem.singlePhase) {
        own = true;
      } else if (opts.feederLineCurrentsA.containsKey(fed)) {
        below.addAll(_rotationHolders(fed, opts, seen));
      }
      continue;
    }
    if (c.loadKind == LoadKind.spare || c.loadKind == LoadKind.capacitor) {
      continue;
    }
    if (!circuitIsThreePhase(
      panelSystem: p.system,
      kind: c.loadKind,
      loadW: c.loadW,
      motorKw: c.motorKw,
      phases: c.phases,
    )) {
      own = true;
    }
  }
  final out = [if (own) id, ...below];
  return out.isEmpty ? [id] : out;
}

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
///
/// Round 49 — the figure is EXACT (unrounded): the reducibility verdict
/// compares it against exact line sums, and rounding it first turned an
/// inherent 200 % board into a phantom 'Unpin … 198.5 % is achievable'.
/// Round only where it is displayed.
double minimumPhaseSpreadA(
  List<double> currents, {
  int exactSearchMax = kPhaseExactSearchMaxWays,
  List<double> base = const [0, 0, 0],
}) {
  final ways = currents.where((c) => c > 0).toList()
    ..sort((a, b) => b.compareTo(a));
  // Round 37 — [base] is the FIXED per-line load of the 3φ ways that do not
  // load their lines equally (a feeder to an imbalanced 3φ board carries that
  // board's own L1 / L2 / L3): they shift the lines unequally, so they DO
  // change the achievable spread. Equal base lines (the default) reproduce
  // the original search exactly.
  final baseEqual = (base[0] - base[1]).abs() < 1e-12 &&
      (base[1] - base[2]).abs() < 1e-12;
  if (ways.isEmpty) {
    return baseEqual ? 0 : _spread3(base[0], base[1], base[2]);
  }

  if (ways.length <= exactSearchMax) {
    final lines = baseEqual ? [0.0, 0.0, 0.0] : [...base];
    var best = double.infinity;
    void walk(int i) {
      if (i == ways.length) {
        final s = _spread3(lines[0], lines[1], lines[2]);
        if (s < best) best = s;
        return;
      }
      // Symmetry break: with three empty lines the heaviest way can sit on L1
      // without loss of generality (only when the base lines are equal).
      final lanes = i == 0 && baseEqual ? 1 : 3;
      for (var p = 0; p < lanes; p++) {
        lines[p] += ways[i];
        walk(i + 1);
        lines[p] -= ways[i];
      }
    }

    walk(0);
    return best;
  }

  final freeCircuits = [
    if (!baseEqual) _PhaseCircuit('#base', true, 0, null, lines: [...base]),
    for (var i = 0; i < ways.length; i++)
      _PhaseCircuit('#$i', false, ways[i], null),
  ];
  final free = balancePhases(freeCircuits, ElectricalSystem.threePhase);
  final l = _exactLines(freeCircuits, free.assignment);
  return _spread3(l[0], l[1], l[2]);
}

// ── busbar section splitting ────────────────────────────────────────────────

/// One outgoing way's loading, for grouping ways onto busbar sections.
class _BusbarWayLoad {
  final String id;
  final double designCurrentA;
  final bool threePhase;
  final PhaseAssignment phase;
  final bool breakBefore;

  /// Round 44 — the way's own breaker rating (A): a section must carry the
  /// largest outgoing device on it before that device trips.
  final double deviceRatingA;
  const _BusbarWayLoad(
    this.id,
    this.designCurrentA,
    this.threePhase,
    this.phase,
    this.breakBefore, [
    this.deviceRatingA = 0,
  ]);
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
    // Round 44 (electrical-sim-9-busbar-section-below-outgoing-device) — a
    // section is rated for the largest outgoing DEVICE it carries (like the
    // main bus for its incomer, IEC 61439-1): a 1764 A way on a 2000 A ACB
    // can draw 2000 A through its section before the ACB trips.
    final deviceFloorA =
        group.fold<double>(0, (m, w) => math.max(m, w.deviceRatingA));
    sections.add(BusbarSectionResult(
      index: sections.length + 1,
      circuitIds: group.map((w) => w.id).toList(),
      ways: group.length,
      sectionCurrent: Current(currentA),
      busbar: sizeBusbar(profile, Current(currentA),
          minAmpacityA: Current(deviceFloorA),
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
/// Round 56 — the ADS conductor-growth bounds for a FINAL way
/// (`computeSystem`): at most this many section rungs above the load-sized
/// cable …
const int kAdsCsaGrowthMaxRungs = 6;

/// … and never above this section (mm²): a final way needing more is a
/// design to rethink (a sub-board nearer the load), so the
/// `ads-disconnection` error stands. `// VERIFY` notAnSniClause (a bound,
/// not a code figure).
const double kAdsCsaGrowthMaxMm2 = 35;

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

  /// Round 40 (electrical-sim-5-selectivity-floor-breaks-ads) — the largest
  /// rating (A) the selectivity floor may reach on a feeder way, keyed by
  /// circuit id, so the discretionary coordination floor never pushes the
  /// device past the earth-fault loop limit (ADS) the load-sized device met.
  /// Derived by `computeSystem` from the fault study; empty ⇒ only the
  /// cable's Iz caps the floor ⇒ byte-identical.
  final Map<String, double> feederBreakerCapA;

  /// Round 43 (electrical-sim-8-mccb-frame-raise-breaks-ads) — FINAL way ids
  /// whose MCCB frame raise ([kMccbMinFrameA]) is refused because the raised
  /// rating fails ADS: the load-sized MCB is kept (cascade back-up info).
  /// Derived by `computeSystem` from the fault study; empty ⇒ byte-identical.
  final Set<String> mccbFrameRaiseRefusedIds;

  /// Round 56 (regression-ads-fail-both-classes-no-csa-growth) — per FINAL
  /// way id, a conductor-section floor (mm²) `computeSystem` sets so a way
  /// that fails ADS as both MCB and MCCB on its load-sized cable steps up the
  /// section ladder until it disconnects in time. Applied like a cable
  /// minimum but flagged [ElectricalCircuitResult.cableRaisedForAds] (never a
  /// user override). Empty ⇒ byte-identical.
  final Map<String, double> adsCsaFloorMm2;

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

  /// Round 24 — on a TT installation, the fed sub-tree's RCD topology keyed
  /// by the CHILD panel id a feeder serves (see [TtFeederRcdBasis]): the
  /// feeder RCD takes the highest downstream type, steps its sensitivity up
  /// per RCD feeder level below it, and is omitted for a life-safety-only
  /// sub-tree. Derived by `computeSystem`; empty (the default, and every TN
  /// project) ⇒ the single-level rule ⇒ byte-identical.
  final Map<String, TtFeederRcdBasis> ttFeederRcd;

  /// Round 37 (electrical-sim-4-feeder-balanced-phase-hides-fed-board-
  /// imbalance) — each IMBALANCED three-phase fed board's DIVERSIFIED line
  /// currents `[L1, L2, L3]` (A), keyed by the child panel id a feeder
  /// serves, derived bottom-up by `computeSystem`. A 3φ feeder to such a
  /// board loads the parent's phase balance with those three currents (so the
  /// parent incomer / busbar, the recommended daya, the genset per-phase basis
  /// and the service-capacity judge see the real worst line) and its own Ib /
  /// Vd use the fed board's worst line. A balanced fed board (all three lines
  /// equal) is absent ⇒ the balanced Ib exactly as before ⇒ byte-identical.
  final Map<String, List<double>> feederLineCurrentsA;

  /// Round 37 (electrical-sim-4-feeder-neutral-ignores-fed-board-triplen-
  /// oversize) — each fed three-phase board whose FOLD-2 neutral factor is
  /// above 1, keyed by the child panel id a feeder serves (see
  /// [FedNeutralLoad]). The feeder's shared neutral carries `factor ×` the
  /// fed worst-phase current, so its cable steps up until the derated Iz ×
  /// [kFourLoadedConductorFactor] covers it (a full-size neutral, never a
  /// reduced one), and the parent's own FOLD 2 counts the feeder current ×
  /// the fed board's triplen share as single-phase non-linear load. Empty
  /// (the default: no non-linear 1φ board anywhere) ⇒ byte-identical.
  final Map<String, FedNeutralLoad> feederNeutralLoad;

  /// Round 40 (regression-largest-machine-floor-not-propagated-upstream) —
  /// each fed board's [ElectricalPanelResult.largestDownstreamRunA] (the
  /// largest single FINAL way's UNDIVERSIFIED running current on it or below
  /// it), keyed by the child panel id a feeder serves, derived bottom-up by
  /// `computeSystem`. The feeder's device + conductor floor at it (the
  /// machine runs at that current through the feeder whatever its demand
  /// factor), and this board's incomer counts it among its own ways. Empty
  /// (the default) ⇒ byte-identical.
  final Map<String, double> feederLargestRunA;

  /// Round 56 — each fed board's
  /// [ElectricalPanelResult.largestDownstreamRunLinesA] (keyed like
  /// [feederLargestRunA]): which LINES that machine loads, so this board's
  /// own vector follows it through the feeder. Empty ⇒ the scalar on every
  /// line.
  final Map<String, List<double>> feederLargestRunLinesA;

  const ComputePanelOptions({
    this.feederLargestRunA = const {},
    this.feederLargestRunLinesA = const {},
    this.feederNeutralLoad = const {},
    this.feederLineCurrentsA = const {},
    this.ttFeederRcd = const {},
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
    this.feederBreakerCapA = const {},
    this.mccbFrameRaiseRefusedIds = const {},
    this.adsCsaFloorMm2 = const {},
    this.serviceMinCurrentA,
    this.feederPowerFactor = const {},
  });
}

/// A circuit's effective install method: a per-run laying override wins over the
/// panel method ('ground' → buried; 'air' → above-ground even if the panel is
/// buried). Drives both the ampacity table and the temperature derating basis.
CableInstallMethod _effectiveInstallMethod(
        ElectricalCircuit c, ElectricalPanel panel) =>
    effectiveInstallMethod(c, panel);

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
  // Round 26 — the library replaces MINTED defaults only: an engineer's typed
  // factor (`demandFactorUserSet`) and a deliberate 0 (a standby machine that
  // never coincides with its duty partner) are provenance, never overwritten.
  if (library == null ||
      diversityLibraryId == null ||
      c.isFeeder ||
      c.demandFactorUserSet ||
      c.demandFactor == 0 ||
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
  // Round 41 — a spare way carries no load, whatever W / FLA it still holds.
  if (c.loadKind == LoadKind.capacitor || c.loadKind == LoadKind.spare) {
    return 0;
  }
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

/// Round 25 — the UNDIVERSIFIED connected input (W) of a way: the same
/// electrical-input basis as [circuitConnectedW] before the demand factor (0
/// for a capacitor bank). The accessory takeoff and the schedule DAYA read it.
double circuitUndiversifiedW(ElectricalCircuit c) {
  if (c.loadKind == LoadKind.capacitor || c.loadKind == LoadKind.spare) {
    return 0;
  }
  final isMotor =
      (c.loadKind == LoadKind.motor || c.loadKind == LoadKind.pump) &&
          c.motorKw != null;
  if (c.flaOverrideA == null && isMotor) {
    return c.motorKw! * 1000 / kAssumedMotorEfficiency;
  }
  return c.loadW;
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
double _singlePhaseNonLinearFraction(List<_CircuitComputation> comps,
    {Map<String, double> feederTriplenShare = const {}}) {
  var total = 0.0;
  var singlePhaseNonLinear = 0.0;
  for (final cm in comps) {
    if (cm.result.loadKind == LoadKind.spare) continue;
    final w = math.max(0.0, _balanceCurrentA(cm.result));
    total += w;
    if (cm.nonLinear && !cm.threePhase) {
      singlePhaseNonLinear += w;
    } else {
      // Round 37 — a feeder to a board whose 1φ non-linear share puts
      // triplen current in ITS neutral carries that share up the tree.
      final share = feederTriplenShare[cm.result.circuitId];
      if (share != null) singlePhaseNonLinear += w * share;
    }
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
    r.loadKind == LoadKind.capacitor ? 0.0 : r.designCurrentSumA;

/// Round 15 — the current a busbar SECTION must carry for one way: its design
/// current, a capacitor bank at [kCapacitorSwitchingFactor] × its rated
/// current, a feeder at least its fed board's capacitor switching current.
double _busbarWayCurrentA(ElectricalCircuitResult r, ElectricalCircuit c,
    Map<String, double> feederCapacitorFloorA) {
  var a = r.designCurrentSumA;
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
/// Round 32 (electrical-props-3-demand-rounding-order-dependent) — an
/// ORDER-FREE accumulator: float addition is not associative, so a board
/// total summed in model order could land either side of a rounding
/// boundary (63 360 vs 63 359 W) when the ways are shuffled. Each term is
/// quantized to an integer number of micro-units and summed as an int —
/// exact, so the printed totals are permutation-invariant.
int _micro(double v) => (v * 1e6).round();
double _fromMicro(int v) => v / 1e6;

double panelCapacitorFloorA(
  ElectricalPanel panel, {
  Map<String, double> childFloorA = const {},
  Map<String, ElectricalSystem> panelSystems = const {},
  Map<String, PhaseAssignment> assignment = const {},
}) {
  // Integer micro-amps (Round 32) — order-free sums.
  final lines = [0, 0, 0];
  final threePhasePanel = panel.system == ElectricalSystem.threePhase;
  void add(String id, bool threePhase, PhaseLine? pin, double amps) {
    if (amps <= 0) return;
    final a = _micro(amps);
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
  return roundTo(_fromMicro(worst), 1);
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
  ElectricalCircuit way,
  ElectricalPanel panel,
  double df,
  ComputePanelOptions opts,
) {
  // Round 41 (regression-rekind-bypasses-mep-machine-lock) — a SPARE way is
  // zero-demand by definition (Round 39: no cable / load): a leftover W,
  // shaft kW or A5 FLA from the machine it used to be never sizes it (a
  // 15 kW pump re-kinded to Spare was still a 32 A way adding 17 kW).
  final c = way.loadKind == LoadKind.spare &&
          (way.loadW != 0 || way.motorKw != null || way.flaOverrideA != null)
      ? way.copyWith(loadW: 0, clearMotorKw: true, clearFlaOverrideA: true)
      : way;
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
          //
          // Round 20 (regression-demand-factor-flips-way-to-single-phase) —
          // a FINAL way's phase is decided on its UNDIVERSIFIED rating
          // (c.loadW): one machine does not diversify against itself, so a
          // coincidence factor must never move a 5 kW pump (df 0.5) below the
          // 3 kW / 5500 W Auto threshold onto one phase (12.7 A design /
          // 25.5 A run on 1φ instead of 8.5 A on 3φ). A feeder is 3φ by rule.
          loadW: isFeeder ? loadW : c.loadW,
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
  Current ib;
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
    // Round 38 (elec-sizing-supply-1) — the A5 FLA is minted ONCE at the
    // minted phases + cos φ (`equipmentFullLoadCurrent` = loadCurrent(input
    // W, terminal V, cos φ, 3φ)). Once the engineer TYPES the way's phases or
    // cos φ (provenance flags), that mint is stale — a 3 kW pump set to 1φ was
    // sized at its 3φ 5.7 A on a 6 A breaker instead of 17.0 A / 20 A. Re-derive
    // it with the SAME formula on the way's effective phase, voltage and cos φ
    // (identical to the mint for an untouched way ⇒ byte-identical).
    //
    // Round 39 (elec-ui-journeys-2) — the mint is ALSO stale when the way is
    // no longer machine-owned (a PARKED way, `sourceEquipmentId` cleared: the
    // engineer may retype its load for a replacement machine) or when it now
    // runs at a different phase count / on a single-phase BOARD than the
    // 3φ / 400 V it was minted at (`setPanelSystem`, a move onto a 1φ board):
    // a 3529 W pump minted at 6.0 A must size at 3529 / (220 × 0.85) = 18.9 A
    // on a 1φ 220 V board, and a parked row retyped to 15 kW at 25.5 A.
    final mintStale = c.phasesUserSet ||
        c.cosPhiUserSet ||
        c.sourceEquipmentId == null ||
        threePhase != (c.phases == 3) ||
        refPanel.system == ElectricalSystem.singlePhase;
    undiversifiedFlc = mintStale
        ? loadCurrent(
            power: Power(c.loadW),
            voltage: Voltage(useVoltageV),
            cosPhi: cosPhi,
            threePhase: threePhase,
          )
        : c.flaOverrideA!;
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
  // Round 37 — a 3φ feeder carries its fed board's WORST line, never only
  // the balanced W / (√3·V·pf): two 7 kW 1φ heaters on a 3φ sub-board put
  // 30.3 A on L1 and L2, not 20.2 A. Its device, cable and Vd size on it.
  final fedLines = isFeeder && threePhase && c.feedsPanelId != null
      ? opts.feederLineCurrentsA[c.feedsPanelId]
      : null;
  if (fedLines != null) {
    final worst = fedLines.reduce(math.max);
    if (worst > ib.amperes) ib = Current(worst);
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
  // Round 40 (regression-largest-machine-floor-not-propagated-upstream) — a
  // feeder carries at least the largest single machine below it at its
  // UNDIVERSIFIED running current (one machine does not diversify against
  // itself — the Round-39 incomer rule, carried up the tree). A 15 kW
  // 0.7-pf welder at df 0.5 behind a feeder runs at 30.9 A whatever its
  // 15.5 A diversified share; its feeder's device AND conductor size on it,
  // and so does its voltage drop. Absent / covered ⇒ byte-identical.
  final machineFloorA =
      isFeeder ? opts.feederLargestRunA[c.feedsPanelId] : null;
  if (machineFloorA != null && machineFloorA > sizingCurrent.amperes) {
    sizingCurrent = Current(machineFloorA);
    if (machineFloorA > feederRunCurrent.amperes) {
      feederRunCurrent = Current(machineFloorA);
    }
  }

  // THE LOAD-SIZED DEVICE. Deliberately floor-free: the conductor below is sized
  // against THIS pick, so a coordination floor can never inflate copper (E3).
  // Round 57 — the trip curve follows the EFFECTIVE starter (a VFD / soft
  // starter / star-delta motor way takes C, never the DOL D curve that
  // halves its ADS loop limit — `breakerCurveFor`).
  final wayStarter = c.starterType == null
      ? null
      : effectiveStarterType(c.starterType!, threePhase);
  final loadBreaker = selectBreaker(
    profile,
    designCurrent: sizingCurrent,
    loadKind: c.loadKind,
    overrideA: c.breakerOverrideA,
    starterType: wayStarter,
  );

  // Round 38 (elec-ui-drawings-4) — a feeder-kind way with no target feeds
  // nothing, yet it would be sized, scheduled and bought; a desynced / copied
  // file is never silently scheduled. Judge-only.
  if (c.loadKind == LoadKind.feeder &&
      (c.feedsPanelId == null || c.feedsPanelId!.isEmpty)) {
    warnings.add(ElectricalWarning(
      code: 'feeder-without-target',
      severity: WarningSeverity.warning,
      message: '${c.name}: a feeder way that feeds no board — connect it to '
          'the board it supplies, or change it to a spare / load way.',
      panelId: panel.id,
      circuitId: c.id,
    ));
  }

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

  // Round 42 (elec-ui-journey-3-free-typed-breaker-override-nonstandard) — a
  // typed breaker override that is NOT a standard rating (17 A, 70 A …) is
  // kept verbatim (the engineer's statement) but named: no such device is
  // made, so the schedule + BOM would carry an unbuildable line. Judge-only.
  if (loadBreaker.overridden) {
    final ov = loadBreaker.ratingA.amperes;
    final ladder = profile.standardBreakerRatingsA;
    final onLadder = ladder.any((r) => (r - ov).abs() < 1e-6);
    if (!onLadder) {
      double? below;
      double? above;
      for (final r in ladder) {
        if (r < ov) below = r;
        if (r > ov && above == null) above = r;
      }
      final near = [
        if (below != null) '${_num(below)} A',
        if (above != null) '${_num(above)} A',
      ].join(' / ');
      warnings.add(ElectricalWarning(
        code: 'breaker-override-nonstandard',
        severity: WarningSeverity.warning,
        message: '${c.name}: the ${_num(ov)} A breaker override is not a '
            'standard rating — no such device is made; pick a standard rung'
            '${near.isEmpty ? '' : ' ($near)'}.',
        panelId: panel.id,
        circuitId: c.id,
      ));
    }
  }

  // PUIL minimums: trunk (incomer/feeder) → 4 (3φ) / 2.5; final → lighting 1.5
  // else 2.5. A manual cable minimum floors it.
  final isTrunk = c.role == CircuitRole.incomer || isFeeder;
  final baseMin = profile.minSectionMm2(
    lighting: c.isLighting,
    trunk: isTrunk,
    threePhase: threePhase,
  );
  final userMinSection = math.max(baseMin, c.cableOverrideMm2 ?? 0);
  final adsFloor = opts.adsCsaFloorMm2[c.id] ?? 0;
  final minSection = math.max(userMinSection, adsFloor);

  final installMethod = _effectiveInstallMethod(c, panel);
  // The cable family (NYY/NYM/NYA/NYAF/FRC) sets the insulation temperature
  // class for the KHA lookup — notably FRC sizes on the 90 °C table — falling
  // back to the panel default when the run is untyped (byte-identical then).
  final cableInsulation =
      insulationForCableType(c.cableType, fallback: panel.insulation);

  // Round 42 — a star-delta motor way (the starter in the board): the
  // supply cable is the INTERNAL breaker → starter link; the field run is
  // the motor leads (sized below on the way length).
  final starDeltaMotor = !isFeeder &&
      threePhase &&
      c.starterType == StarterType.starDelta &&
      (c.loadKind == LoadKind.motor ||
          c.loadKind == LoadKind.pump ||
          c.loadKind == LoadKind.hvac);
  final supplyLength = starDeltaMotor
      ? const Length(kStarDeltaInternalWiringM)
      : effectiveLength;

  var cable = sizeCable(
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
      length: supplyLength,
      cosPhi: cosPhi,
      threePhase: threePhase,
      voltage: Voltage(useVoltageV),
      isLighting: c.isLighting,
    ),
  );

  // Round 37 (electrical-sim-4-feeder-neutral-ignores-fed-board-triplen-
  // oversize) — a 3φ feeder to a board whose 1φ non-linear load raises the
  // neutral current to `factor ×` phase carries that current in its OWN
  // neutral core too; the phase breaker never sees it. Size the cable on the
  // neutral condition (IEC 60364-5-52 Annex E, four loaded conductors:
  // Iz × 0.86 ≥ factor × the fed worst phase), stepping the section up — a
  // full-size neutral, never a reduced one.
  final fedNeutral = isFeeder && threePhase && c.feedsPanelId != null
      ? opts.feederNeutralLoad[c.feedsPanelId]
      : null;
  // Round 38 (regression-feeder-neutral-upsize-stops-at-largest-single-core)
  // — the neutral condition is sized through sizeCable's OWN parallel-run
  // ladder (an extra total-Iz floor of neutralA / 0.86), so a neutral above
  // the largest single section steps into 2..4 parallel runs; afterwards the
  // condition is RE-CHECKED — also on a hand-overridden cable (never skipped)
  // — and a neutral still above Iz × 0.86 is an ERROR, never an info note
  // claiming it is carried.
  if (fedNeutral != null && fedNeutral.factor > 1 && def.needsNeutral) {
    final neutralA = fedNeutral.factor * fedNeutral.worstPhaseA;
    bool carries(CableResult r) =>
        r.deratedIz.amperes * kFourLoadedConductorFactor >= neutralA - 1e-9;
    var upsized = false;
    if (!carries(cable) && c.cableOverrideMm2 == null) {
      final candidate = sizeCable(
        profile,
        designCurrent: sizingCurrent,
        breakerRating: loadBreaker.ratingA,
        deratingFactor: df,
        minSectionMm2: minSection,
        insulation: cableInsulation,
        material: panel.material,
        method: installMethod,
        threePhase: threePhase,
        groupingCount: c.groupingCountOverride ?? panel.groupingCount,
        vd: CableVoltageDropConstraint(
          length: effectiveLength,
          cosPhi: cosPhi,
          threePhase: threePhase,
          voltage: Voltage(useVoltageV),
          isLighting: c.isLighting,
        ),
        izRequiredMinA: neutralA / kFourLoadedConductorFactor,
      );
      if (carries(candidate) && candidate.ampacityReached) {
        cable = candidate;
        upsized = true;
      }
    }
    final runs = cable.runsPerPhase ?? 1;
    final make = runs > 1
        ? '${runs}x${_num(cable.csaMm2)} mm²'
        : '${_num(cable.csaMm2)} mm²';
    if (!carries(cable)) {
      warnings.add(ElectricalWarning(
        code: 'feeder-neutral-overloaded',
        severity: WarningSeverity.error,
        message: '${c.name}: the fed board\'s single-phase non-linear load '
            'raises the feeder NEUTRAL current to ~${fedNeutral.factor}x its '
            '${_num(roundTo(fedNeutral.worstPhaseA, 1))} A worst phase '
            '(${_num(roundTo(neutralA, 1))} A), above the feeder cable\'s '
            'Iz x $kFourLoadedConductorFactor = '
            '${_num(roundTo(cable.deratedIz.amperes * kFourLoadedConductorFactor, 1))} A '
            '($make, four loaded conductors, IEC 60364-5-52 Annex E) — the '
            'neutral is overloaded; '
            '${c.cableOverrideMm2 != null ? 'raise or clear the cable override' : 'split the board or reduce its non-linear load'}.',
        panelId: panel.id,
        circuitId: c.id,
      ));
    } else if (upsized) {
      warnings.add(ElectricalWarning(
        code: 'harmonics-neutral-oversize',
        severity: WarningSeverity.info,
        message: '${c.name}: the fed board\'s single-phase non-linear load '
            'raises the feeder NEUTRAL current to ~${fedNeutral.factor}x its '
            '${_num(roundTo(fedNeutral.worstPhaseA, 1))} A worst phase '
            '(${_num(roundTo(neutralA, 1))} A) — feeder cable upsized to '
            '$make so Iz x $kFourLoadedConductorFactor '
            '(four loaded conductors, IEC 60364-5-52 Annex E) carries it with '
            'a full-size neutral.',
        panelId: panel.id,
        circuitId: c.id,
      ));
    }
  }

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
    // Round 40 — the floor is ALSO capped by the earth-fault loop (ADS):
    // a coordination floor must never create the safety non-compliance the
    // load-sized device did not have ([ComputePanelOptions.feederBreakerCapA]).
    final adsCapA = opts.feederBreakerCapA[c.id];
    final capIz = adsCapA != null && adsCapA < cable.deratedIz.amperes
        ? Current(adsCapA)
        : cable.deratedIz;
    final floored = selectBreaker(
      profile,
      designCurrent: sizingCurrent,
      loadKind: c.loadKind,
      minRatingA: floorA,
      maxRatingA: capIz,
      starterType: wayStarter,
    );
    // The cap may only hold the floor back, never pull the device below the
    // rating the load itself demanded (the ampacity-impossible fallback is the
    // one case where Iz < In, and it is already an error-severity finding).
    if (floored.ratingA.amperes > breaker.ratingA.amperes) breaker = floored;
  }
  // Round 38 — the device CLASS follows the bus fault (see
  // [faultAwareBreakerClass]).
  final frameRaiseRefused = opts.mccbFrameRaiseRefusedIds.contains(c.id);
  breaker = faultAwareBreakerClass(breaker, opts.faultLevelA,
      maxRatingA: cable.deratedIz, allowClassChange: !frameRaiseRefused);
  if (mcbNeedsBackupProtection(breaker, opts.faultLevelA)) {
    final why = frameRaiseRefused
        ? 'an MCCB (magnetic trip at ${_num(kMccbMagneticTripMultiple)} x In) '
            'would fail the earth-fault loop (ADS) on this run'
        : 'its cable (Iz ${_num(roundTo(cable.deratedIz.amperes, 1))} A) '
            'cannot carry a ${_num(kMccbMinFrameA)} A MCCB frame';
    warnings.add(ElectricalWarning(
      code: 'mcb-backup-protection-required',
      severity: WarningSeverity.info,
      message: '${c.name}: the ${_num(breaker.ratingA.amperes)} A way sits on '
          'a ${_num(roundTo(opts.faultLevelA!.amperes / 1000.0, 1))} kA bus, '
          'above the MCB breaking-capacity range, and is kept as an MCB '
          'because $why — '
          'it relies on back-up (cascade) protection by the upstream device '
          '(IEC 60898-1 Annex D); verify the cascade combination.',
      panelId: panel.id,
      circuitId: c.id,
    ));
  }

  final runsPerPhase = cable.runsPerPhase ?? 1;

  final supplyVd = voltageDrop(
    profile,
    current: Current(feederRunCurrent.amperes / runsPerPhase),
    length: supplyLength,
    csaMm2: cable.csaMm2,
    cosPhi: cosPhi,
    threePhase: threePhase,
    voltage: Voltage(useVoltageV),
    isLighting: c.isLighting,
    material: panel.material,
  );

  // Round 41 (electrical-sim-6-star-delta-motor-has-one-cable-not-six-leads)
  // — a STAR-DELTA starter is wired to the motor's SIX winding terminals:
  // the starter → motor section is TWO 3-core cables, each carrying the
  // winding current Ib/√3 (I_line = √3 · I_winding in delta). One lead cable
  // is sized here on that current (same family, laying and minimum; In basis
  // = the delta-leg overload setting ≈ the winding current, so
  // Iz ≥ 1.25 × Ib/√3). Each lead carries a PE (the way's PE, capped at the
  // lead section).
  // Round 42 — the leads ARE the field run (the starter is in the board,
  // [kStarDeltaInternalWiringM]): the way length, and the way's Vd is judged
  // on them.
  // Round 43 — (1) the two lead cables run TOGETHER in one route, so each is
  // one of 2·g grouped circuits (IEC 60364-5-52 Table B.52.17, the same
  // parallel-run rule `sizeCable` applies to its own runs: the g-circuit
  // factor inside `df` is swapped for the 2g one). // VERIFY notAnSniClause.
  // (2) each winding sits between its OWN two lead conductors (U1 out, U2
  // back), both carrying I_w, so the winding sees V_LL − 2·I_w·Z·L: the
  // SINGLE-PHASE loop formula at I_w against 400 V — never the balanced 3φ
  // √3 factor (2/√3 = 1.155 × low). (3) the lead is sized against the limit
  // LESS the internal link's drop, so link + lead ≤ limit.
  CableResult? motorLeads;
  if (starDeltaMotor) {
    final leadIb = Current(sizingCurrent.amperes / math.sqrt(3));
    final g = math.max(1, c.groupingCountOverride ?? panel.groupingCount);
    final leadDf =
        df * groupingFactor(profile, 2 * g) / groupingFactor(profile, g);
    motorLeads = sizeCable(
      profile,
      designCurrent: leadIb,
      breakerRating: leadIb,
      deratingFactor: leadDf,
      minSectionMm2: baseMin,
      insulation: cableInsulation,
      material: panel.material,
      method: installMethod,
      threePhase: true,
      groupingCount: 2 * g,
      vd: CableVoltageDropConstraint(
        length: effectiveLength,
        cosPhi: cosPhi,
        threePhase: false,
        voltage: Voltage(useVoltageV),
        isLighting: false,
        limitPercent: math.max(0.0, supplyVd.limitPercent - supplyVd.dropPercent),
      ),
    );
  }

  final VoltageDropResult vd;
  if (motorLeads == null) {
    vd = supplyVd;
  } else {
    // The motor terminal sees the internal link's drop PLUS the lead run's
    // winding-loop drop 2·I_w·Z·L / V_LL.
    final leadRuns = motorLeads.runsPerPhase ?? 1;
    final leadVd = voltageDrop(
      profile,
      current: Current(
          feederRunCurrent.amperes / math.sqrt(3) / leadRuns),
      length: effectiveLength,
      csaMm2: motorLeads.csaMm2,
      cosPhi: cosPhi,
      threePhase: false,
      voltage: Voltage(useVoltageV),
      isLighting: false,
      material: panel.material,
    );
    final pct = roundTo(supplyVd.dropPercent + leadVd.dropPercent, 2);
    vd = VoltageDropResult(
      dropV: roundTo(supplyVd.dropV + leadVd.dropV, 2),
      dropPercent: pct,
      limitPercent: supplyVd.limitPercent,
      withinLimit: pct <= supplyVd.limitPercent + 1e-9,
    );
  }

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
    ttFeeder: c.feedsPanelId == null ? null : opts.ttFeederRcd[c.feedsPanelId],
  );

  // Round 54 (regression-tt-rcd-touch-voltage-judge-dead) — the TT
  // Ra × IΔn <= 50 V judge moved to `computeAdvancedStudy`, which has the
  // DESIGNED electrode (`designElectrode`); judged here against the constant
  // 5 ohm target it could never fire (5 ohm x 10 A = 50 V passes).

  // Round 36 (elec-props-4-tt-rcd-ladder-saturates) — JUDGE-ONLY: a TT
  // feeder RCD whose IΔn ladder is exhausted (≥ 5 cascaded RCD feeder levels)
  // sits at the same sensitivity as the feeder RCD below it, so an earth fault
  // downstream can trip it and black out everything it feeds.
  if (isFeeder &&
      rcd.required &&
      rcd.timeDelayed &&
      opts.earthingSystem == EarthingSystem.tt) {
    final basis = opts.ttFeederRcd[c.feedsPanelId];
    final levels = basis?.rcdFeederLevelsBelow ?? 0;
    final below = basis?.maxDownstreamMa ?? 0;
    // Round 55 — judged against the real IΔn below (finals included).
    final selective = below > 0
        ? ttFeederRcdSelectiveAbove(rcd.ratingMa, below)
        : ttFeederRcdSelective(levels);
    if (!selective) {
      final belowMa = below > 0 ? below : ttFeederRcdMa(levels - 1);
      warnings.add(ElectricalWarning(
        code: 'tt-rcd-not-selective',
        severity: WarningSeverity.warning,
        message: '${c.name}: TT feeder RCD at ${rcd.ratingMa} mA is not '
            '≥ 3 × the $belowMa mA RCD below it '
            '(the IΔn ladder is exhausted after $levels RCD feeder levels) — '
            'an earth fault downstream can trip it; flatten the distribution '
            'tree or rely on time-delay grading / an RCM.',
        panelId: panel.id,
        circuitId: c.id,
      ));
    }
  }

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
          '${c.name}: ${c.loadKind == LoadKind.pump ? 'fire pump way' : 'life-safety motor way'}'
          ' - specify overload-trip-disabled protection '
          'on the schedule (fire duty runs to destruction - NFPA 20 practice). '
          // Round 25 — a curve letter only for a device that has one (MCB):
          // an MCCB / ACB prints its class, like the schedule and the BOM.
          'Sized here as an ordinary ${breaker.deviceClass.hasTripCurve ? '${_num(breaker.ratingA.amperes)} A curve ${breaker.curve.name.toUpperCase()} MCB' : '${_num(breaker.ratingA.amperes)} A ${breaker.deviceClass.code}'}'
          ' device; the schedule row carries '
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

  // Each lead carries a PE (the way's PE, capped at the lead section).
  double? motorLeadsPe;
  if (motorLeads != null) {
    final wayPe =
        grounding.peCsaMm2 > 0 ? grounding.peCsaMm2 : cable.csaMm2;
    motorLeadsPe = math.min(wayPe, motorLeads.csaMm2);
  }

  final result = ElectricalCircuitResult(
    circuitId: c.id,
    name: c.name,
    loadKind: c.loadKind,
    designCurrent: designCurrent,
    designCurrentExactA: ib.amperes,
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
    // Round 25 — the takeoff / DAYA basis: undiversified for a final way, the
    // fed board's W for a feeder.
    connectedW: isFeeder ? loadW : circuitUndiversifiedW(c),
    points: c.points,
    runCurrent: Current(roundTo(feederRunCurrent.amperes, 1)),
    lineCurrentsA: fedLines == null
        ? null
        : [for (final l in fedLines) roundTo(l, 1)],
    motorLeads: motorLeads,
    motorLeadsPeCsaMm2: motorLeadsPe,
    cableRaisedForAds: adsFloor > userMinSection + 1e-9,
  );
  if (result.cableRaisedForAds) {
    warnings.add(ElectricalWarning(
      code: 'cable-raised-for-ads',
      severity: WarningSeverity.info,
      message: '${c.name}: cable raised to ${_num(cable.csaMm2)} mm2 so the '
          'earth-fault loop disconnects in time (IEC 60364-4-41 Zs limit); '
          'the load alone needs a smaller section.',
      panelId: panel.id,
      circuitId: c.id,
    ));
  }

  return _CircuitComputation(
      result, warnings, loadW, threePhase, _circuitIsNonLinear(c));
}

// ── panel computation ───────────────────────────────────────────────────────

/// Round 48 — a board's sized ways and the [_PhaseCircuit] list its phase
/// balance runs on (shared by [computePanel] and `computeSystem`'s rotation
/// search, which re-balances the SAME list with permuted feeder lines
/// instead of re-sizing the board for every candidate).
({
  List<ElectricalCircuit> branches,
  List<_CircuitComputation> comps,
  List<_PhaseCircuit> phaseCircuits,
}) _panelComps(
  ElectricalStandardsProfile profile,
  ElectricalPanel panel,
  ComputePanelOptions opts,
) {
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
  final phaseCircuits = [
    for (var i = 0; i < comps.length; i++)
      _PhaseCircuit(
        comps[i].result.circuitId,
        comps[i].threePhase,
        _balanceCurrentA(comps[i].result),
        branches[i].phaseOverride,
        lines: comps[i].threePhase && branches[i].feedsPanelId != null
            ? opts.feederLineCurrentsA[branches[i].feedsPanelId]
            : null,
      ),
  ];
  return (branches: branches, comps: comps, phaseCircuits: phaseCircuits);
}

/// Compute all CORE sizing — per-circuit, phase balance, incomer, busbar (main
/// + sections), neutral/PE bars, demand — for one panel. The ONLY constructor of
/// [ElectricalPanelResult]. Ported from `computePanel.ts` (core slice).
ElectricalPanelResult computePanel(
  ElectricalStandardsProfile profile,
  ElectricalPanel panel, {
  ComputePanelOptions opts = const ComputePanelOptions(),
}) {
  final pcs = _panelComps(profile, panel, opts);
  final branches = pcs.branches;
  final comps = pcs.comps;
  final phaseCircuits = pcs.phaseCircuits;
  final loadBalance = balancePhases(
    phaseCircuits,
    panel.system,
    prior: opts.priorAssignment,
    reassignThresholdA: opts.phaseReassignThresholdA,
  );
  // Round 15 (elec-props-3-single-phase-banks-stacked-on-one-line) — a bank
  // adds no balance current, so the load balancer had no signal to spread
  // unpinned single-phase capacitor banks and stacked them all on L1 (three
  // 10 kvar banks → 185.7 A on R, a 200 A incomer, S and T uncompensated).
  // A separate deterministic pass spreads them by their SWITCHING current.
  final stickyBalance = _spreadSinglePhaseBanks(
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

  // Round 39 r3 — ONE assignment: the seeded (document-prior) balance is
  // both what the board prints and what every verdict / parent reads. The
  // prior is the document's persisted `assignedPhase`, so this is a function
  // of the document alone (live == reopen) — no second, unseeded figure.
  final balance = stickyBalance;
  final warnings = <ElectricalWarning>[];
  // Round 32 — integer micro-watts: the printed board kW is order-free.
  var connectedMicroW = 0;
  final circuits = <ElectricalCircuitResult>[];
  for (final cm in comps) {
    connectedMicroW += _micro(cm.effectiveLoadW);
    warnings.addAll(cm.warnings);
    circuits.add(cm.result.copyWith(
      phase: balance.assignment[cm.result.circuitId] ?? cm.result.phase,
    ));
  }

  final connectedW = _fromMicro(connectedMicroW);

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
  // Round 39 r3 — the verdict reads the SAME labelled lines the schedule
  // prints; their prior is the document's persisted assignment, so the same
  // document reports the same verdict live and after reopen.
  final overImbalanceLimit = panel.system == ElectricalSystem.threePhase &&
      balance.imbalancePercent > kPhaseImbalanceWarnPercent;
  var imbalanceReducible = false;
  var bestImbalancePercent = balance.imbalancePercent;
  // Round 46 — fed boards whose R/S/T relabelling makes this board's
  // imbalance reducible (see below).
  final rotateBoardIds = <String>[];
  // elec-props-3 — with no phase PIN and no prior seed on any single, the
  // assignment is the ENGINE's own (exact for ≤ kPhaseExactSearchMaxWays
  // singles, by the min-worst-phase objective the incomer sizes on), so no
  // re-assignment is an action the engineer could take: never "reducible".
  // Round 37 (edit-fuzz-3-2) — only a real input (a PIN) makes the
  // assignment the engineer's; the session prior seed is the engine's own.
  final engineOwned = !branches.asMap().entries.any((e) =>
      !comps[e.key].threePhase && e.value.phaseOverride != null);
  // Round 49 (elec-props-13-rounded-floor-phantom-unpin-warning) — the
  // floor is judged on EXACT line sums, never on the 0.1 A-rounded printed
  // lines (a 2.2 / 4.3 / 0.0 A board read 198.5 % 'achievable' against an
  // exact 200 % — a 1.5 pp rounding artefact above the 1 pp margin).
  var floorGainA = 0.0;
  var marginA = 0.0;
  if (overImbalanceLimit) {
    final exact = _exactLines(phaseCircuits, balance.assignment);
    // The average line current is assignment-invariant (the same total load is
    // shared out however the ways are placed), so the achievable imbalance is
    // the achievable SPREAD measured against the same average.
    final avgA = (exact[0] + exact[1] + exact[2]) / 3;
    final actualSpreadA = _spread3(exact[0], exact[1], exact[2]);
    final actualWorstA = math.max(exact[0], math.max(exact[1], exact[2]));
    marginA = kPhaseImbalanceReducibleMarginPercent * avgA / 100;
    double pct(double spreadA) =>
        avgA > 0 ? roundTo((spreadA / avgA) * 100, 1) : 0.0;
    // Round 37 — 3φ feeders carrying an imbalanced fed board's lines are a
    // FIXED unequal base the singles are placed against.
    final base = [0.0, 0.0, 0.0];
    for (final pc in phaseCircuits) {
      final ls = pc.lines;
      if (!pc.threePhase || ls == null) continue;
      final m = ls.reduce(math.min);
      for (var k = 0; k < 3; k++) {
        base[k] += ls[k] - m;
      }
    }
    var bestSpreadA = minimumPhaseSpreadA([
      for (final cm in comps)
        if (!cm.threePhase) _balanceCurrentA(cm.result),
    ], base: base);
    // Round 43 — the actual assignment is itself achievable, so the floor
    // can never sit ABOVE the actual figure.
    if (bestSpreadA > actualSpreadA) bestSpreadA = actualSpreadA;
    floorGainA = actualSpreadA - bestSpreadA;
    bestImbalancePercent = math.min(pct(bestSpreadA), balance.imbalancePercent);
    imbalanceReducible = !engineOwned && floorGainA > marginA + 1e-9;
    // Round 46 (drawings-7-phase-label-bias-inherent-verdict) — a fed
    // board's R/S/T labels are an engineer's choice too: relabelling a
    // sub-board (rotating which of its lines is light) permutes the lines its
    // feeder brings here. (Rotatable boards are already rotated by
    // `computeSystem`; this names the ones it could not move — a phase pin
    // below, or a gain within the stability threshold.)
    final excesses = <(String, int)>[];
    for (var i = 0; i < phaseCircuits.length; i++) {
      final pc = phaseCircuits[i];
      final ls = pc.lines;
      if (!pc.threePhase || ls == null) continue;
      if (ls.reduce(math.max) - ls.reduce(math.min) <= 1e-9) continue;
      excesses.add((branches[i].feedsPanelId!, i));
    }
    if (!imbalanceReducible && excesses.isNotEmpty) {
      // Only the three CYCLIC relabellings — the same set
      // `computeSystem.rotateFedChildren` applies and the 'Rotate R/S/T'
      // advice names; a two-line swap is never counted as achievable here.
      const perms = [
        [0, 1, 2], [1, 2, 0], [2, 0, 1], //
      ];
      // Round 49 (regression-rotation-vs-reducibility-objective /
      // elec-props-13-rotate-advice-raises-worst-phase) — every candidate is
      // scored with the SAME objective `rotateFedChildren` takes: this
      // board's own solved balance (its singles placed by [balancePhases]
      // with its prior + stability threshold against the permuted feeder
      // lines), compared lexicographically on (worst line, spread). A
      // relabelling that cuts the spread but RAISES the worst line — the
      // figure the incomer, feeder and daya size on — is one the engine
      // itself rejected and is never advised; spread alone (Round 46/48)
      // printed 'Rotate R/S/T at DB-1 — 93.9 % achievable' for a relabel
      // whose worst line rose from 34.6 to 34.7 A.
      final scoreCache = <String, (double, double)>{};
      (double, double) scoreFor(List<int> pick) =>
          scoreCache.putIfAbsent(pick.join(','), () {
            final pcs = [...phaseCircuits];
            for (var e = 0; e < excesses.length; e++) {
              final i = excesses[e].$2;
              final pc = phaseCircuits[i];
              final ls = pc.lines!;
              final perm = perms[pick[e]];
              final out = [0.0, 0.0, 0.0];
              for (var j = 0; j < 3; j++) {
                out[perm[j]] = ls[j];
              }
              pcs[i] = _PhaseCircuit(
                  pc.id, pc.threePhase, pc.currentA, pc.pinned,
                  lines: out);
            }
            final b = balancePhases(pcs, panel.system,
                prior: opts.priorAssignment,
                reassignThresholdA: opts.phaseReassignThresholdA);
            final l = _exactLines(pcs, b.assignment);
            return (
              math.max(l[0], math.max(l[1], l[2])),
              _spread3(l[0], l[1], l[2]),
            );
          });
      bool better((double, double) a, (double, double) b) =>
          a.$1 < b.$1 - 1e-9 ||
          ((a.$1 - b.$1).abs() <= 1e-9 && a.$2 < b.$2 - 1e-9);
      // Accepted only when it never raises this board's worst line and cuts
      // the spread by more than the margin (both exact).
      bool accepted((double, double) s) =>
          s.$1 <= actualWorstA + 1e-9 &&
          actualSpreadA - s.$2 > marginA + 1e-9;
      final nEx = excesses.length;
      List<int>? bestPick;
      (double, double)? bestScore;
      void consider(List<int> pick) {
        if (pick.every((r) => r == 0)) return;
        final s = scoreFor(pick);
        if (!accepted(s)) return;
        if (bestScore == null || better(s, bestScore!)) {
          bestScore = s;
          bestPick = [...pick];
        }
      }

      if (nEx <= kRotationExhaustiveMaxBoards) {
        final pk = List<int>.filled(nEx, 0);
        while (true) {
          var i = nEx - 1;
          while (i >= 0 && pk[i] == 2) {
            pk[i] = 0;
            i--;
          }
          if (i < 0) break;
          pk[i]++;
          consider(pk);
        }
      } else {
        // Heaviest-first greedy seed (the Round-46 construction) refined by
        // coordinate descent on the same (worst, spread) objective.
        final order = [for (var e = 0; e < nEx; e++) e]..sort((a, b) {
            final la = phaseCircuits[excesses[a].$2].lines!;
            final lb = phaseCircuits[excesses[b].$2].lines!;
            final byMax = (lb.reduce(math.max) - lb.reduce(math.min))
                .compareTo(la.reduce(math.max) - la.reduce(math.min));
            return byMax != 0
                ? byMax
                : excesses[a].$1.compareTo(excesses[b].$1);
          });
        final seed = List<int>.filled(nEx, 0);
        final acc = [0.0, 0.0, 0.0];
        double rank(List<double> l) =>
            l.reduce(math.max) * 1e6 +
            (l.reduce(math.max) - l.reduce(math.min));
        for (final e in order) {
          final ls = phaseCircuits[excesses[e].$2].lines!;
          final m = ls.reduce(math.min);
          List<double>? bestL;
          var bestIdx = 0;
          for (var k = 0; k < perms.length; k++) {
            final onParent = [...acc];
            for (var j = 0; j < 3; j++) {
              onParent[perms[k][j]] += ls[j] - m;
            }
            if (bestL == null || rank(onParent) < rank(bestL) - 1e-6) {
              bestL = onParent;
              bestIdx = k;
            }
          }
          for (var j = 0; j < 3; j++) {
            acc[j] = bestL![j];
          }
          seed[e] = bestIdx;
        }
        var cur = List<int>.filled(nEx, 0);
        if (better(scoreFor(seed), scoreFor(cur))) cur = seed;
        var improved = true;
        var passes = 0;
        while (improved && passes++ < 3 * nEx + 3) {
          improved = false;
          for (var e = 0; e < nEx; e++) {
            for (var r = 0; r < 3; r++) {
              if (r == cur[e]) continue;
              final cand = [...cur]..[e] = r;
              if (better(scoreFor(cand), scoreFor(cur))) {
                cur = cand;
                improved = true;
              }
            }
          }
        }
        consider(seed);
        consider(cur);
      }
      final pick = bestPick;
      if (pick != null) {
        imbalanceReducible = true;
        // Named in the board's own circuit (schedule) order — and, for a
        // mid-level board that holds no single-phase way of its own, the
        // descendant boards that actually carry the ways to relabel.
        final seen = <String>{};
        for (var e = 0; e < nEx; e++) {
          if (pick[e] == 0) continue;
          for (final h in _rotationHolders(excesses[e].$1, opts, seen)) {
            if (!rotateBoardIds.contains(h)) rotateBoardIds.add(h);
          }
        }
        bestImbalancePercent = pct(bestScore!.$2);
      }
    }
  }
  if (overImbalanceLimit && imbalanceReducible) {
    final pinnedWays = [
      for (var i = 0; i < comps.length; i++)
        if (!comps[i].threePhase && branches[i].phaseOverride != null)
          branches[i].id,
    ].length;
    String boardName(String id) => opts.panelById[id]?.name ?? id;
    final action = rotateBoardIds.isNotEmpty
        ? 'Rotate R/S/T at ${rotateBoardIds.map(boardName).join(', ')} '
            '(relabel their single-phase ways so their light lines fall on '
            'different phases here)'
        : pinnedWays > 0
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
    // Round 49 — on the exact floor gain (see above), never the rounded %.
    final labelsKeptForStability = floorGainA > marginA + 1e-9;
    warnings.add(ElectricalWarning(
      code: 'phase-imbalance-inherent',
      severity: WarningSeverity.info,
      // Round 39 r3 — the % is the LABELLED (persisted) assignment's. When
      // it sits above the achievable floor the labels were kept for
      // stability (the re-labelling gain is within the threshold): say so,
      // never claim the labelled spread is itself the floor.
      message: 'Phase loading is unbalanced by ${balance.imbalancePercent}% '
          '(L1 ${balance.l1} A, L2 ${balance.l2} A, L3 ${balance.l3} A) - '
          '${labelsKeptForStability ? 'the labelled phases are kept (re-labelling would move installed ways for a spread gain within the ${opts.phaseReassignThresholdA} A stability threshold); ' : ''}'
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
  // Round 39 (regression-outgoing-exceeds-incomer) — the incomer carries at
  // least the largest single FINAL way's UNDIVERSIFIED running current: one
  // machine does not diversify against itself, so a board whose only way is a
  // 17 A machine at df 0.9 must not get a 16 A incomer sized on the 15.3 A
  // diversified worst line (it would trip on normal running). Feeders,
  // capacitor banks (their own floor above) and spare ways are excluded.
  // Byte-identical whenever the diversified worst line already covers it.
  //
  // Round 40 — a FEEDER way counts with its fed board's largest downstream
  // machine ([ComputePanelOptions.feederLargestRunA]), so the floor follows
  // the machine up the tree: a 30.9 A welder behind a feeder no longer sits
  // under a 16 A main incomer.
  //
  // Round 56 (regression-alternator-floor-all-lines-at-1ph-machine) — the
  // machine's LINES ride with it: a 3φ way (or any way on a 1φ board) loads
  // [I, I, I], a 1φ way on a 3φ board only its assigned line; a feeder
  // carries its fed board's vector (a 1φ fed board: its peak on the
  // feeder's own line).
  final threePhaseBoard = panel.system == ElectricalSystem.threePhase;
  List<double> onLines(double a, PhaseAssignment? line, bool threePhaseWay) {
    if (!threePhaseBoard || threePhaseWay) return [a, a, a];
    return switch (line) {
      PhaseAssignment.l1 => [a, 0, 0],
      PhaseAssignment.l2 => [0, a, 0],
      PhaseAssignment.l3 => [0, 0, a],
      _ => [a, a, a],
    };
  }

  var ownWayRunA = 0.0;
  var downstreamRunA = 0.0;
  var ownLines = const <double>[0, 0, 0];
  var downstreamLines = const <double>[0, 0, 0];
  for (var i = 0; i < comps.length; i++) {
    final b = branches[i];
    final id = comps[i].result.circuitId;
    if (b.feedsPanelId != null) {
      final d = opts.feederLargestRunA[b.feedsPanelId] ?? 0;
      if (d > downstreamRunA) {
        downstreamRunA = d;
        final fedVec = opts.feederLargestRunLinesA[b.feedsPanelId];
        final threePhaseFeeder = comps[i].result.threePhase;
        downstreamLines = threePhaseFeeder && fedVec != null && threePhaseBoard
            ? [for (final x in fedVec) roundTo(x, 1)]
            : onLines(d, balance.assignment[id], threePhaseFeeder);
      }
      continue;
    }
    final k = comps[i].result.loadKind;
    if (k == LoadKind.capacitor || k == LoadKind.spare) continue;
    final run = comps[i].result.runCurrentA.amperes;
    if (run > ownWayRunA) {
      ownWayRunA = run;
      ownLines =
          onLines(run, balance.assignment[id], comps[i].result.threePhase);
    }
  }
  ownWayRunA = roundTo(ownWayRunA, 1);
  downstreamRunA = roundTo(downstreamRunA, 1);
  final largestWayRunA = math.max(ownWayRunA, downstreamRunA);
  final largestWayRunLinesA = [
    for (final x in downstreamRunA > ownWayRunA ? downstreamLines : ownLines)
      roundTo(x, 1),
  ];
  final largestIsDownstream = downstreamRunA > ownWayRunA;
  final serviceGoverns = serviceFloorA > futureDemandCurrentA &&
      serviceFloorA >= capacitorFloorA &&
      serviceFloorA >= largestWayRunA;
  final capacitorGoverns = !serviceGoverns &&
      capacitorFloorA > futureDemandCurrentA &&
      capacitorFloorA >= largestWayRunA;
  final largestWayGoverns = !serviceGoverns &&
      !capacitorGoverns &&
      largestWayRunA > futureDemandCurrentA;
  final incomerSizingCurrentA = serviceGoverns
      ? roundTo(serviceFloorA, 1)
      : capacitorGoverns
          ? capacitorFloorA
          : largestWayGoverns
              ? largestWayRunA
              : futureDemandCurrentA;

  final incomerBreaker = faultAwareBreakerClass(
    selectBreaker(
      profile,
      designCurrent: Current(incomerSizingCurrentA),
      loadKind: LoadKind.feeder,
    ),
    opts.faultLevelA,
  );
  final incomer = IncomerResult(
    breaker: incomerBreaker,
    poles: panel.system == ElectricalSystem.threePhase ? 4 : 2,
    sizingCurrent: Current(incomerSizingCurrentA),
  );
  if (incomerBreaker.ratingA.amperes + 1e-9 < incomerSizingCurrentA) {
    final basis = serviceGoverns
        ? 'declared service capacity'
        : capacitorGoverns
            ? 'capacitor-bank switching current'
            : largestWayGoverns
                ? (largestIsDownstream
                    ? 'largest downstream machine running current'
                    : 'largest way running current')
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

  // Round 38 (elec-ui-drawings-6) — JUDGE-ONLY: an outgoing way rated ABOVE
  // its own board's incomer can never discriminate (the incomer always trips
  // first) and inverts the incomer / outgoing pair on the issued schedule.
  // When the inversion is the engine's OWN device-only selectivity floor (the
  // way carries no breaker override and was floored towards 1.6 x the fed
  // board's incomer), the design is not wrong — the rating chain simply needs
  // this board's incomer raised to match; the finding is an INFO note naming
  // that action, never a sign-off blocker (as `selectivity-partial` is
  // suppressed for the engine's own floors). An override-caused inversion
  // stays a warning.
  final overrideById = {for (final b in branches) b.id: b.breakerOverrideA};
  for (final cr in circuits) {
    if (cr.breaker.ratingA.amperes >
        incomerBreaker.ratingA.amperes + 1e-9) {
      // Round 39 — any override-free inversion is the ENGINE's own device
      // pick (the selectivity floor, a motor / capacitor switching factor),
      // never an engineer error: INFO naming the incomer action. Only a way
      // carrying a breaker override stays a sign-off WARNING.
      final selectivityFloor =
          opts.feederBreakerFloorA.containsKey(cr.circuitId);
      final engineFloor = overrideById[cr.circuitId] == null;
      warnings.add(ElectricalWarning(
        code: 'outgoing-exceeds-incomer',
        severity:
            engineFloor ? WarningSeverity.info : WarningSeverity.warning,
        message: engineFloor
            ? '${panel.name} / ${cr.name}: '
                '${selectivityFloor ? 'the selectivity floor raised this feeder' : 'the engine sized this way'} '
                'to ${_num(cr.breaker.ratingA.amperes)} A, above the '
                'board\'s own ${_num(incomerBreaker.ratingA.amperes)} A '
                'incomer — raise the incomer to at least '
                '${_num(cr.breaker.ratingA.amperes)} A (this board\'s '
                'spare-capacity headroom) so the rating chain stays '
                'consistent.'
            : '${panel.name} / ${cr.name}: the outgoing '
                '${_num(cr.breaker.ratingA.amperes)} A device is rated above '
                'the board\'s own ${_num(incomerBreaker.ratingA.amperes)} A '
                'incomer — the incomer always trips first, so the pair cannot '
                'discriminate; lower the way (breaker override) or raise the '
                'incomer.',
        panelId: panel.id,
        circuitId: cr.circuitId,
      ));
    }
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
  final triplenFraction = _singlePhaseNonLinearFraction(comps,
      feederTriplenShare: {
        for (final b in branches)
          if (b.feedsPanelId != null &&
              opts.feederNeutralLoad.containsKey(b.feedsPanelId))
            b.id: opts.feederNeutralLoad[b.feedsPanelId]!.triplenFraction,
      });
  final nFactor = roundTo(neutralOversizeFactor(triplenFraction), 2);
  final neutralPe = sizeNeutralPeBars(
    busbar.csaMm2,
    busbar.ampacityA,
    profile: profile,
    neutralOversizeFactor: nFactor,
    triplenFraction: triplenFraction,
    // Round 44 — the factor scales the CURRENT, never a withstand-floored
    // section.
    phaseSizingCurrentA: incomerSizingCurrentA,
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
          comps[i].result.breaker.ratingA.amperes,
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
          '${neutralPe.oversized ? 'neutral bar oversized to ${_num(neutralPe.neutralCsaMm2)} mm² (phase bar ${_num(busbar.csaMm2)} mm²)' : 'the full-size ${_num(neutralPe.neutralCsaMm2)} mm² neutral bar (the phase bar, sized for the fault withstand / incomer) already carries it'}.',
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
    largestDownstreamRunA: largestWayRunA,
    largestDownstreamRunLinesA: largestWayRunLinesA,
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
/// `service-capacity-below-demand` warning when the computed DIVERSIFIED
/// worst-phase demand exceeds what that capacity's limiter passes. Null (the default) ⇒
/// no floor ⇒ byte-identical.
///
/// PHASE STABILITY: each way's persisted `assignedPhase` (Round 39 r3 — the
/// document's own record of the last solve) plus any explicit
/// [priorAssignments] (`panelId → (circuitId → line)`) seeds each panel's
/// balancer and,
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
  // Round 39 r3 — the phase-stability PRIOR is the document's persisted
  // assignment (`ElectricalCircuit.assignedPhase`), so the balance is a
  // function of the document alone; an explicit [priorAssignments] entry
  // (tests / tools) overrides it per way.
  final prior = <String, Map<String, PhaseAssignment>>{};
  for (final p in panels) {
    final m = <String, PhaseAssignment>{
      for (final c in p.circuits)
        if (c.assignedPhase != null) c.id: _lineAssign(c.assignedPhase!),
      ...?priorAssignments[p.id],
    };
    if (m.isNotEmpty) prior[p.id] = m;
  }
  // Round 50 (elec-convergence-3) — the boards the DOCUMENT labels, snapped
  // before any in-pass relabel writes `prior`: the sub-tree rotation below
  // re-solves a rotated board with its new lines as `prior`, and those are
  // the engine's OWN choice, never a persisted label the stability threshold
  // protects. Reading the live map made a nested rotation count as labelled
  // one level up, refusing a fresh document's own improvement (a 25 A MDP
  // incomer solved as 32 A).
  final docLabelled = {
    for (final e in prior.entries)
      if (e.value.isNotEmpty) e.key,
  };
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
  // Round 23 (report-pdf-board-order-reversed) — the ROOT-FIRST order the
  // reports / schedules / drawings list boards in is a PRE-order walk
  // (parent, then its children in model order): reversing the post-order put
  // the parent first but reversed every sibling run (MDP, LP-6 … LP-1).
  final preOrder = <String>[];
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
    preOrder.add(id);
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
      if (!preOrder.contains(p.id)) preOrder.add(p.id);
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
  final serviceCapacityVa = serviceEntranceCapacityVa(project);
  double? serviceMinCurrentA;
  // Round 38 (elec-sizing-supply-3) — a declared daya ABOVE the single-phase
  // PLN ladder exists only as a 3φ service, whose limiter passes
  // VA / (√3·400) PER PHASE. A 1φ root board sits on ONE of those phases, so
  // the floor and the judge convert on the 3φ basis (16.5 kVA ⇒ 23.8 A, never
  // the 71.7 A the board's own 230 V basis gave — an 80 A incomer floor
  // under a limiter that trips at 23.8 A).
  var singlePhaseRootOnThreePhaseDaya = false;
  if (serviceCapacityVa != null && serviceCapacityVa > 0 && roots.length == 1) {
    final root = roots.first;
    final v = root.voltage.volts;
    if (v > 0) {
      singlePhaseRootOnThreePhaseDaya =
          root.system == ElectricalSystem.singlePhase &&
              serviceCapacityVa > plnDayaVa1ph.last + 1e-9;
      // Round 35 — the ONE conversion shared with the recommended daya.
      serviceMinCurrentA = singlePhaseRootOnThreePhaseDaya
          ? lineCurrentForCapacityA(serviceCapacityVa,
              ElectricalSystem.threePhase, kThreePhaseServiceLineVoltageV)
          : lineCurrentForCapacityA(serviceCapacityVa, root.system, v);
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
  // Round 44 (electrical-sim-9-ups-backed-board-sizes-no-ups) — a UPS-backed
  // board is supplied THROUGH its UPS: what its feeder (and everything
  // upstream) carries is the UPS INPUT = output ÷ η + battery recharge.
  double upsIn(String? id) =>
      (id != null && (byId[id]?.upsBacked ?? false)) ? kUpsInputFactor : 1.0;
  for (final id in postOrder) {
    final panel = byId[id];
    if (panel == null) continue;
    final feederLoadW = <String, double>{};
    // Round 32 — integer micro-units: order-free board totals.
    var connectedMicroW = 0;
    var connectedMicroVa = 0;
    for (final c in panel.circuits) {
      if (c.role != CircuitRole.branch) continue;
      final load = c.feedsPanelId != null
          ? (panelDemandW[c.feedsPanelId] ?? 0) * upsIn(c.feedsPanelId)
          : circuitConnectedW(c,
              library: diversityLibrary,
              diversityLibraryId: panel.diversityLibraryId);
      if (c.feedsPanelId != null) feederLoadW[c.feedsPanelId!] = load;
      connectedMicroW += _micro(load);
      final pf = c.feedsPanelId != null
          ? (panelPowerFactor[c.feedsPanelId] ?? c.cosPhi)
          : c.cosPhi;
      connectedMicroVa += _micro(pf > 0 ? load / pf : load);
    }
    final connectedW = _fromMicro(connectedMicroW);
    final connectedVa = _fromMicro(connectedMicroVa);
    feederLoadWByPanel[id] = feederLoadW;
    panelDemandW[id] = connectedW * panel.diversityFactor;
    panelDemandVa[id] = connectedVa * panel.diversityFactor;
    if (connectedVa > 0 && connectedW > 0) {
      panelPowerFactor[id] = math.min(1.0, connectedW / connectedVa);
    }
  }

  // Round 24 — on a TT installation, each feeder's RCD follows the board it
  // feeds: the highest RCD type anywhere below it (a Type A device upstream of
  // an EV / VFD Type B is blinded), one sensitivity step per RCD feeder level
  // below (≥ 3 × IΔn discrimination), and no tripping RCD at all when every
  // load below it is life-safety. Bottom-up over the same post-order; TN ⇒
  // empty ⇒ byte-identical.
  final ttFeederRcd = <String, TtFeederRcdBasis>{};
  if (project.earthingSystem == EarthingSystem.tt) {
    final subType = <String, RcdType?>{};
    final subLifeOnly = <String, bool?>{}; // null ⇒ no load way below
    final subLevels = <String, int>{};
    // Round 55 — the largest IΔn directly below a feeder to each board (its
    // own final RCDs and the next feeder RCDs down), and the IΔn the feeder
    // to that board therefore takes (0 ⇒ no tripping RCD on it).
    final subBelowMa = <String, int>{};
    final feederMa = <String, int>{};
    RcdType? maxType(RcdType? a, RcdType? b) => a == null
        ? b
        : (b == null ? a : (rcdTypeRank(b) > rcdTypeRank(a) ? b : a));
    for (final id in postOrder) {
      final panel = byId[id];
      if (panel == null) continue;
      RcdType? best;
      var anyLoad = false;
      var allLife = true;
      var levels = 0;
      var belowMa = 0;
      for (final c in panel.circuits) {
        final child = c.feedsPanelId;
        if (child != null) {
          final lo = subLifeOnly[child];
          if (lo != null) {
            anyLoad = true;
            if (!lo) allLife = false;
          }
          final childLevels = subLevels[child] ?? 0;
          // The sub-tree's RCD TYPE always propagates (r2): a life-safety
          // feeder carries no RCD itself, but the Type B load below it still
          // sits under any RCD further up. Only the discrimination LEVEL count
          // skips a feeder that carries no tripping RCD (it, or its whole
          // sub-tree, is life-safety).
          best = maxType(best, subType[child]);
          if (!c.lifeSafety && lo != true) {
            levels = math.max(levels, childLevels + 1);
            belowMa = math.max(belowMa, feederMa[child] ?? 0);
          } else {
            levels = math.max(levels, childLevels);
            belowMa = math.max(belowMa, subBelowMa[child] ?? 0);
          }
          continue;
        }
        if (c.loadKind == LoadKind.spare) continue;
        anyLoad = true;
        if (c.lifeSafety) continue;
        allLife = false;
        // The final's own TT RCD (a VFD drive 300 mA, fixed motors 100 mA,
        // else 30 / 100 mA — at most 100 mA, which already sets the 300 mA
        // floor of the feeder ladder, so the design current is not needed).
        belowMa = math.max(
            belowMa,
            ttFinalRcdMa(c.loadKind,
                designCurrent: const Current(64),
                hasVfd: c.starterType == StarterType.vfd));
        best = maxType(
            best,
            recommendedRcdType(c.loadKind,
                    hasVfd: c.starterType == StarterType.vfd)
                .type);
      }
      subType[id] = best;
      subLifeOnly[id] = anyLoad ? allLife : null;
      subLevels[id] = levels;
      subBelowMa[id] = belowMa;
      feederMa[id] = belowMa > 0 ? ttFeederRcdMaAbove(belowMa) : 0;
    }
    for (final child in parentOf.keys) {
      ttFeederRcd[child] = (
        downstreamType: subType[child],
        rcdFeederLevelsBelow: subLevels[child] ?? 0,
        lifeSafetyOnly: subLifeOnly[child] == true,
        maxDownstreamMa: subBelowMa[child] ?? 0,
      );
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
          ttFeederRcd: ttFeederRcd,
          calibrationBySheet: calibrationBySheet,
          building: building,
          panelById: byId,
          diversityLibrary: diversityLibrary,
          priorAssignment: prior[id] ?? const {},
          phaseReassignThresholdA: phaseReassignThresholdA,
        ),
      ).capacitorCurrentA;
      if (solved > 0) capacitorFloorByPanel[id] = solved;
    }
  }

  // Round 37 (electrical-sim-4-feeder-balanced-phase-hides-fed-board-
  // imbalance) — bottom-up DIVERSIFIED line currents of every IMBALANCED
  // fed three-phase board, so the 3φ feeder supplying it carries those three
  // currents into its parent's balance (and sizes on the worst one). A board
  // can only be imbalanced when it holds a single-phase way or a feeder to an
  // imbalanced / single-phase board, so only those are re-solved (with the
  // very `computePanel` the sizing pass runs — its balance is a function of
  // its own ways + the boards below it, never of its parent or the fault
  // level). A 3φ-only tree solves nothing extra ⇒ byte-identical.
  final feederLinesByPanel = <String, List<double>>{};
  // Round 37 — and every fed 3φ board whose FOLD-2 neutral factor is above 1
  // (see [ComputePanelOptions.feederNeutralLoad]).
  final feederNeutralByPanel = <String, FedNeutralLoad>{};
  ComputePanelOptions fedOpts(ElectricalPanel panel) => ComputePanelOptions(
        feederLoadW: feederLoadWByPanel[panel.id] ?? const {},
        feederPowerFactor: panelPowerFactor,
        feederCapacitorFloorA: capacitorFloorByPanel,
        feederLineCurrentsA: feederLinesByPanel,
        feederNeutralLoad: feederNeutralByPanel,
        panelSystems: panelSystems,
        earthingSystem: project.earthingSystem,
        ttFeederRcd: ttFeederRcd,
        calibrationBySheet: calibrationBySheet,
        building: building,
        panelById: byId,
        diversityLibrary: diversityLibrary,
        priorAssignment: prior[panel.id] ?? const {},
        phaseReassignThresholdA: phaseReassignThresholdA,
      );
  ElectricalPanelResult solveFedLines(ElectricalPanel panel) =>
      computePanel(profile, panel, opts: fedOpts(panel));
  // The labelled assignment of every fed board solved by this pass.
  final fedBalance = <String, Map<String, PhaseAssignment>>{};
  Map<String, PhaseAssignment> assignmentOf(ElectricalPanelResult r) =>
      {for (final c in r.circuits) c.circuitId: c.phase};
  // A fed board whose imbalance comes only from unpinned single-phase ways —
  // its own, or (Round 49) those of the boards below it whose feeders carry
  // unequal lines, each itself rotatable (no phase pin, no capacitor bank,
  // no UPS anywhere in that sub-tree): a cyclic relabelling R->S->T of every
  // such way in the sub-tree keeps each board's spread AND worst line
  // exactly, so only the PARENT's lines change. Round 49 (elec-props-13-
  // three-level-tree-never-rotated) — a riser SDB fed by imbalanced floor
  // DBs used to be refused outright, so MDP -> SDB -> DB trees summed three
  // identical label-biased patterns (MDP 30 / 15 / 15 A, a 32 A incomer
  // where 20 / 20 / 20 A was reachable).
  bool rotatable(String id, [Set<String>? seen]) {
    final visiting = seen ?? <String>{};
    if (!visiting.add(id)) return false;
    final panel = byId[id];
    if (panel == null || panel.upsBacked) return false;
    if (panel.system != ElectricalSystem.threePhase) return false;
    if (!fedBalance.containsKey(id)) return false;
    for (final c in panel.circuits) {
      if (c.role != CircuitRole.branch) continue;
      if (c.loadKind == LoadKind.capacitor) return false;
      if (c.phaseOverride != null) return false;
      final fed = c.feedsPanelId;
      if (fed != null &&
          feederLinesByPanel.containsKey(fed) &&
          !rotatable(fed, visiting)) {
        return false;
      }
    }
    return true;
  }

  // Every board a rotation of rotatable [id] relabels: [id] and (in post-
  // order, children first) each board below it whose feeder carries unequal
  // lines.
  List<String> rotationSubtree(String id) {
    final out = <String>[];
    void walk(String b) {
      final panel = byId[b];
      if (panel == null) return;
      for (final c in panel.circuits) {
        final fed = c.feedsPanelId;
        if (c.role == CircuitRole.branch &&
            fed != null &&
            feederLinesByPanel.containsKey(fed) &&
            !out.contains(fed)) {
          walk(fed);
        }
      }
      if (!out.contains(b)) out.add(b);
    }

    walk(id);
    return out;
  }

  PhaseAssignment rotated(PhaseAssignment a, int r) => switch (a) {
        PhaseAssignment.threePhase => a,
        _ => PhaseAssignment.values[(a.index + r) % 3],
      };
  List<double> shifted(List<double> ls, int r) {
    final out = [0.0, 0.0, 0.0];
    for (var i = 0; i < 3; i++) {
      out[(i + r) % 3] = ls[i];
    }
    return out;
  }

  // Round 46 (drawings-7-phase-label-bias-inherent-verdict) — PARENT-AWARE
  // rotation of identical / imbalanced sub-boards. Each fed board balances
  // its own ways independently, and ties go to the LOWEST line, so twelve
  // identical floor DBs all left T light: the LVMDP summed twelve identical
  // patterns into a 29 % imbalance (394.9 / 394.9 / 291.7 A, every upstream
  // worst-phase basis ~10 % over-stated) that no single DB's balance could
  // see. Before a parent is solved, its rotatable fed boards are given the
  // cyclic relabelling that loads the parent's LIGHTEST accumulated line
  // (greedy in circuit order, the identity kept on a tie). A board whose
  // ways already carry persisted labels is relabelled only when the parent's
  // worst line drops by more than [phaseReassignThresholdA] (the stability
  // rule a single board's balance follows); the chosen rotation becomes the
  // board's prior here and is persisted by the store as `assignedPhase`, so
  // the document stays the one source (a re-solve keeps it: the identity is
  // then already the best). No imbalanced fed boards ⇒ byte-identical.
  void rotateFedChildren(String parentId) {
    final parent = byId[parentId];
    if (parent == null || parent.system != ElectricalSystem.threePhase) {
      return;
    }
    final kids = <String>[];
    final fixed = [0.0, 0.0, 0.0];
    for (final c in parent.circuits) {
      final k = c.feedsPanelId;
      if (c.role != CircuitRole.branch || k == null) continue;
      final ls = feederLinesByPanel[k];
      if (ls == null) continue;
      if (rotatable(k)) {
        kids.add(k);
      } else {
        final m = ls.reduce(math.min);
        for (var i = 0; i < 3; i++) {
          fixed[i] += ls[i] - m;
        }
      }
    }
    if (kids.isEmpty) return;
    (double, double) score(List<double> l) => (
          l.reduce(math.max),
          l.reduce(math.max) - l.reduce(math.min),
        );
    bool better((double, double) a, (double, double) b) =>
        a.$1 < b.$1 - 1e-9 ||
        ((a.$1 - b.$1).abs() <= 1e-9 && a.$2 < b.$2 - 1e-9);
    (List<int>, List<double>) greedy(bool Function(String) free) {
      final acc = [...fixed];
      final picks = <int>[];
      for (final k in kids) {
        final ls = feederLinesByPanel[k]!;
        final m = ls.reduce(math.min);
        final ex = [for (final v in ls) v - m];
        var best = 0;
        var bestScore = score([for (var i = 0; i < 3; i++) acc[i] + ex[i]]);
        if (free(k)) {
          for (var r = 1; r < 3; r++) {
            final sh = shifted(ex, r);
            final sc = score([for (var i = 0; i < 3; i++) acc[i] + sh[i]]);
            if (better(sc, bestScore)) {
              best = r;
              bestScore = sc;
            }
          }
        }
        final sh = shifted(ex, best);
        for (var i = 0; i < 3; i++) {
          acc[i] += sh[i];
        }
        picks.add(best);
      }
      return (picks, acc);
    }

    // A sub-tree is labelled when any board it relabels carries DOCUMENT
    // labels (Round 50 — never the engine's own in-pass relabels).
    bool labelled(String k) =>
        rotationSubtree(k).any(docLabelled.contains);
    // Each candidate is judged on the PARENT's own solved balance (its
    // single-phase ways placed against the rotated feeder lines), never on
    // the feeder lines alone: the identity, the greedy that moves only
    // unlabelled boards, and the greedy that may relabel every board.
    final original = {for (final k in kids) k: feederLinesByPanel[k]!};
    // Round 48 — the parent's ways are sized ONCE; each candidate only
    // re-runs the parent's own phase balance ([balancePhases], the very
    // assignment `computePanel` takes, its prior + stability threshold
    // included) with the rotated feeder lines substituted. A cyclic
    // relabelling never changes a fed board's worst line, so the feeder's
    // sizing current — and every other way — is candidate-invariant.
    final parentPcs =
        _panelComps(profile, parent, fedOpts(parent)).phaseCircuits;
    final kidIndex = {for (var i = 0; i < kids.length; i++) kids[i]: i};
    final feederKid = <String, int>{
      for (final c in parent.circuits)
        if (c.role == CircuitRole.branch &&
            c.feedsPanelId != null &&
            kidIndex.containsKey(c.feedsPanelId))
          c.id: kidIndex[c.feedsPanelId]!,
    };
    (double, double) parentScore(List<int> picks) {
      final pcs = [
        for (final pc in parentPcs)
          feederKid[pc.id] == null
              ? pc
              : _PhaseCircuit(pc.id, pc.threePhase, pc.currentA, pc.pinned,
                  lines: shifted(original[kids[feederKid[pc.id]!]]!,
                      picks[feederKid[pc.id]!])),
      ];
      final b = balancePhases(pcs, parent.system,
          prior: prior[parentId] ?? const {},
          reassignThresholdA: phaseReassignThresholdA);
      return score([b.l1, b.l2, b.l3]);
    }

    // Round 48 (elec-convergence-2-parent-rotation-ignores-own-singles) —
    // the greedy above scores feeder-line excess only and never sees the
    // parent's OWN single-phase ways (placed afterwards), so three
    // candidates (identity / greedy-unlabelled / greedy-all) left a 63 A
    // incomer where a cyclic relabelling reached 40 A. Search the rotation
    // space on the parent's SOLVED balance: exhaustively (3^k) for up to
    // [kRotationExhaustiveMaxBoards] rotatable boards, else the greedy seeds
    // refined by coordinate descent (re-rotate one board at a time, keep a
    // strict improvement) to a fixed point. Candidates enumerate identity
    // first, so ties keep the identity / the smaller relabelling.
    final cache = <String, (double, double)>{};
    (double, double) sc(List<int> p) =>
        cache.putIfAbsent(p.join(','), () => parentScore(p));
    final identity = List<int>.filled(kids.length, 0);
    bool movesLabelled(List<int> p) {
      for (var i = 0; i < kids.length; i++) {
        if (p[i] != 0 && labelled(kids[i])) return true;
      }
      return false;
    }

    var bestUnl = identity;
    var sUnl = sc(identity);
    var bestAll = identity;
    var sAll = sUnl;
    if (kids.length <= kRotationExhaustiveMaxBoards) {
      final p = List<int>.filled(kids.length, 0);
      while (true) {
        // Next candidate in lexicographic order (identity already scored).
        var i = kids.length - 1;
        while (i >= 0 && p[i] == 2) {
          p[i] = 0;
          i--;
        }
        if (i < 0) break;
        p[i]++;
        final s = sc(p);
        if (better(s, sAll)) {
          sAll = s;
          bestAll = [...p];
        }
        if (!movesLabelled(p) && better(s, sUnl)) {
          sUnl = s;
          bestUnl = [...p];
        }
      }
    } else {
      List<int> descent(List<int> start, bool Function(int) free) {
        var cur = [...start];
        var sCur = sc(cur);
        var improved = true;
        var passes = 0;
        while (improved && passes++ < 3 * kids.length + 3) {
          improved = false;
          for (var i = 0; i < kids.length; i++) {
            if (!free(i)) continue;
            for (var r = 0; r < 3; r++) {
              if (r == cur[i]) continue;
              final cand = [...cur]..[i] = r;
              final s = sc(cand);
              if (better(s, sCur)) {
                cur = cand;
                sCur = s;
                improved = true;
              }
            }
          }
        }
        return cur;
      }

      final kept = greedy((k) => !labelled(k)).$1;
      if (better(sc(kept), sUnl)) bestUnl = kept;
      bestUnl = descent(bestUnl, (i) => !labelled(kids[i]));
      sUnl = sc(bestUnl);
      final all = greedy((_) => true).$1;
      bestAll = better(sc(all), sUnl) ? all : bestUnl;
      bestAll = descent(bestAll, (_) => true);
      sAll = sc(bestAll);
      if (better(sUnl, sAll)) {
        bestAll = bestUnl;
        sAll = sUnl;
      }
    }
    var picks = bestUnl;
    if (!_listEq(bestAll, bestUnl)) {
      final gain = sUnl.$1 - sAll.$1;
      if (!movesLabelled(bestAll)
          ? better(sAll, sUnl)
          : gain > math.max(phaseReassignThresholdA, 1e-9)) {
        picks = bestAll;
      }
    }
    for (var i = 0; i < kids.length; i++) {
      final r = picks[i];
      if (r == 0) continue;
      // Round 49 — the whole sub-tree is relabelled by r and re-solved
      // children first, so each mid-level board's feeder lines below are
      // already the rotated ones when it is re-solved.
      for (final b in rotationSubtree(kids[i])) {
        final fb = fedBalance[b];
        if (fb == null) continue;
        prior[b] = {
          for (final e in fb.entries)
            if (e.value != PhaseAssignment.threePhase)
              e.key: rotated(e.value, r),
        };
        final solved = solveFedLines(byId[b]!);
        final bal = solved.phaseBalance;
        fedBalance[b] = assignmentOf(solved);
        final d = byId[b]!.diversityFactor;
        feederLinesByPanel[b] = [bal.l1 * d, bal.l2 * d, bal.l3 * d];
      }
    }
  }

  for (final id in postOrder) {
    rotateFedChildren(id);
    final panel = byId[id];
    if (panel == null || !parentOf.containsKey(id)) continue;
    if (panel.system != ElectricalSystem.threePhase) continue;
    final maybeImbalanced = panel.circuits.any((c) {
      if (c.role != CircuitRole.branch) return false;
      final fed = c.feedsPanelId;
      if (fed != null) {
        return panelSystems[fed] == ElectricalSystem.singlePhase ||
            feederLinesByPanel.containsKey(fed) ||
            feederNeutralByPanel.containsKey(fed);
      }
      if (c.loadKind == LoadKind.capacitor ||
          c.loadKind == LoadKind.spare) {
        return false;
      }
      return c.phaseOverride != null ||
          !circuitIsThreePhase(
            panelSystem: panel.system,
            kind: c.loadKind,
            loadW: c.loadW,
            motorKw: c.motorKw,
            phases: c.phases,
          );
    });
    if (!maybeImbalanced) continue;
    final solved = solveFedLines(panel);
    fedBalance[id] = assignmentOf(solved);
    // Round 39 r3 — the fed board's LABELLED lines (its printed TOTAL): the
    // assignment behind them is persisted in the document, so the parent's
    // balance, its feeder row R/S/T and its incomer are a function of the
    // document alone and always match the fed board's issued schedule.
    final b = solved.phaseBalance;
    final d = panel.diversityFactor;
    // Round 44 — a UPS-backed board's feeder carries the UPS INPUT (a
    // balanced rectifier draw), never the output board's imbalanced lines.
    if (!panel.upsBacked &&
        (math.max(b.l1, math.max(b.l2, b.l3)) -
                math.min(b.l1, math.min(b.l2, b.l3))) >
            1e-9) {
      feederLinesByPanel[id] = [b.l1 * d, b.l2 * d, b.l3 * d];
    }
    final nb = solved.neutralPeBars;
    if (nb.neutralOversizeFactor > 1) {
      feederNeutralByPanel[id] = (
        factor: nb.neutralOversizeFactor,
        worstPhaseA: solved.diversifiedDemandCurrent.amperes,
        triplenFraction: nb.triplenFraction,
      );
    }
    if (solved.capacitorCurrentA > 0 &&
        capacitorFloorByPanel.containsKey(id)) {
      capacitorFloorByPanel[id] = solved.capacitorCurrentA;
    }
  }

  // Round 40 (regression-largest-machine-floor-not-propagated-upstream) —
  // bottom-up, every FED board's largest single machine running current (its
  // own final ways and every board below it), so the feeder supplying it, the
  // parent incomer and the recommended daya floor at it. A final way's
  // running current is a function of the way alone (load, cos phi, phase
  // count, board voltage) — never of its parent or the fault level — so the
  // very `computePanel` the sizing pass runs gives it.
  final largestRunByPanel = <String, double>{};
  final largestRunLinesByPanel = <String, List<double>>{};
  for (final id in postOrder) {
    final panel = byId[id];
    if (panel == null || !parentOf.containsKey(id)) continue;
    final solved = computePanel(
      profile,
      panel,
      opts: ComputePanelOptions(
        feederLoadW: feederLoadWByPanel[id] ?? const {},
        feederPowerFactor: panelPowerFactor,
        feederCapacitorFloorA: capacitorFloorByPanel,
        feederLineCurrentsA: feederLinesByPanel,
        feederNeutralLoad: feederNeutralByPanel,
        feederLargestRunA: largestRunByPanel,
        feederLargestRunLinesA: largestRunLinesByPanel,
        panelSystems: panelSystems,
        earthingSystem: project.earthingSystem,
        ttFeederRcd: ttFeederRcd,
        calibrationBySheet: calibrationBySheet,
        building: building,
        panelById: byId,
        diversityLibrary: diversityLibrary,
        priorAssignment: prior[id] ?? const {},
        phaseReassignThresholdA: phaseReassignThresholdA,
      ),
    );
    if (solved.largestDownstreamRunA > 0) {
      largestRunByPanel[id] = solved.largestDownstreamRunA;
      final lines = solved.largestDownstreamRunLinesA;
      if (lines != null) largestRunLinesByPanel[id] = lines;
    }
  }

  // True building connected load = leaf loads only (feeders are aggregations).
  // Round 32 — integer micro-watts: order-free (see [_micro]).
  // Round 40 (electrical-sim-5-supply-connected-is-diversified) — the
  // CONNECTED load is UNDIVERSIFIED ([circuitUndiversifiedW]): the same basis
  // as every board's Round-30 'connected' figure, so the supply total equals
  // the roots' connected sub-trees and stays above the diversified demand
  // whenever any way carries a demand factor below 1.
  var connectedLoadMicroW = 0;
  for (final p in panels) {
    for (final c in p.circuits) {
      if (c.role == CircuitRole.branch && c.feedsPanelId == null) {
        connectedLoadMicroW += _micro(circuitUndiversifiedW(c));
      }
    }
  }
  final connectedLoadW = _fromMicro(connectedLoadMicroW);

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
  // Round 56 — the per-way ADS conductor floors (see the growth loop at the
  // end); every [sizeAll] pass reads the current map.
  final adsCsaFloors = <String, double>{};

  ElectricalSystemResult sizeAll(Map<String, double> feederBreakerFloorA,
      [Map<String, double> feederBreakerCapA = const {},
      Set<String> mccbFrameRaiseRefusedIds = const {}]) {
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
          ttFeederRcd: ttFeederRcd,
          faultLevelA: faultLevelA,
          busbarClearingTimeS: busbarClearingTimeS,
          calibrationBySheet: calibrationBySheet,
          building: building,
          panelById: byId,
          diversityLibrary: diversityLibrary,
          priorAssignment: prior[id] ?? const {},
          phaseReassignThresholdA: phaseReassignThresholdA,
          feederBreakerFloorA: feederBreakerFloorA,
          feederBreakerCapA: feederBreakerCapA,
          mccbFrameRaiseRefusedIds: mccbFrameRaiseRefusedIds,
          adsCsaFloorMm2: Map.of(adsCsaFloors),
          feederLineCurrentsA: feederLinesByPanel,
          feederNeutralLoad: feederNeutralByPanel,
          feederLargestRunA: largestRunByPanel,
          feederLargestRunLinesA: largestRunLinesByPanel,
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
        largestDownstreamRunA: pr.largestDownstreamRunA,
        largestDownstreamRunLinesA: pr.largestDownstreamRunLinesA,
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
    // DIVERSIFIED worst-phase demand exceeds that current will trip the
    // limiter. Round 32 (electrical-props-3-service-capacity-judged-on-
    // undiversified-current): the limiter trips on the real (diversified)
    // current, the same basis the advanced study's recommended daya sizes on,
    // so the judge reads [ElectricalPanelResult.diversifiedDemandCurrent]
    // (the sibling `feeder-below-fed-demand` moved there in Round 19). The
    // incomer / busbar floor stays max(undiversified demand, service) —
    // conservative sizing is untouched. Never resizes; the honest fix is a
    // bigger subscription or shedding load.
    if (serviceMinCurrentA != null && singlePhaseRootOnThreePhaseDaya) {
      final rootResult = results[roots.first.id];
      rootResult?.warnings.add(ElectricalWarning(
        code: 'service-single-phase-root-on-three-phase-daya',
        severity: WarningSeverity.warning,
        message: '${rootResult.name}: the declared '
            '${_num(serviceCapacityVa! / 1000)} kVA connection is above the '
            'single-phase PLN ladder (${_num(plnDayaVa1ph.last / 1000)} kVA), '
            'so it is a 3-phase service rated '
            '~${_num(roundTo(serviceMinCurrentA, 1))} A per phase — a '
            'single-phase root board loads only one of those phases. Make the '
            'root board 3-phase, or declare a single-phase daya step.',
        panelId: roots.first.id,
      ));
    }
    if (serviceMinCurrentA != null) {
      final rootId = roots.first.id;
      final rootResult = results[rootId];
      final rawDivA = rootResult == null
          ? 0.0
          : roundTo(rootResult.diversifiedDemandCurrent.amperes, 1);
      // Round 40 — the limiter must also pass the largest single machine on
      // the service at its UNDIVERSIFIED running current (the figure that
      // floors the incomer and the recommended daya).
      final machineA = rootResult?.largestDownstreamRunA ?? 0.0;
      final machineGoverns = machineA > rawDivA;
      final divA = machineGoverns ? machineA : rawDivA;
      if (rootResult != null && divA > serviceMinCurrentA + 1e-9) {
        rootResult.warnings.add(ElectricalWarning(
          code: 'service-capacity-below-demand',
          severity: WarningSeverity.warning,
          // Round 37 r2 — on a dual-transformer service the single root
          // sits on ONE section (coupler normally open), so the figure it is
          // judged against is that section, never misstated as the declared
          // total.
          message: '${rootResult.name}: '
              '${machineGoverns ? 'the largest single machine running current' : 'diversified demand'} '
              '${_num(divA)} A on the worst-loaded '
              'phase exceeds '
              '${project.dualTransformer ? 'one ${_num(serviceCapacityVa! / 1000)} kVA section of the declared '
                  '${_num(project.supplyCapacityVa!.voltAmperes / 1000)} kVA '
                  'connection (bus coupler normally open, '
                  '~${_num(roundTo(serviceMinCurrentA, 1))} A) — the section '
                  'would trip under the diversified demand; raise the '
                  'subscribed daya, split the load across both sections or '
                  'shed load.' : 'the declared connection capacity '
                  '${_num(serviceCapacityVa! / 1000)} kVA '
                  '(~${_num(roundTo(serviceMinCurrentA, 1))} A) — the utility '
                  'limiter would trip under the diversified demand; raise the '
                  'subscribed daya or shed load.'}',
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

    // Round 43 (electrical-sim-8-fire-path-feeder-not-frc-checked) — the
    // fire-pump / life-safety supply must survive a fire from the source to
    // the controller (NFPA 20 9.3 / 9.8, SNI 03-6574 practice): a FEEDER whose
    // sub-tree holds any life-safety way is judged like the way itself — a
    // null or non-FRC family raises the judge-only `life-safety-feeder-cable`
    // warning on the parent board, locatable on the feeder way. A feeder that
    // is itself flagged life-safety is already judged by `life-safety-cable`.
    // Bottom-up over the post-order; never resizes. // VERIFY notAnSniClause.
    final lifeBelow = <String, bool>{};
    for (final id in postOrder) {
      final panel = byId[id];
      if (panel == null) continue;
      var any = false;
      for (final c in panel.circuits) {
        final child = c.feedsPanelId;
        if (child != null) {
          if (lifeBelow[child] == true) any = true;
          continue;
        }
        if (c.lifeSafety && c.loadKind != LoadKind.spare) any = true;
      }
      lifeBelow[id] = any;
    }
    for (final p in panels) {
      final pr = results[p.id];
      if (pr == null) continue;
      for (final c in p.circuits) {
        final child = c.feedsPanelId;
        if (child == null || c.lifeSafety) continue;
        if (lifeBelow[child] != true) continue;
        if (c.cableType == 'FRC') continue;
        final childName = byId[child]?.name ?? child;
        final family = (c.cableType == null || c.cableType!.isEmpty)
            ? defaultCableFamily(c.loadKind)
            : c.cableType!;
        pr.warnings.add(ElectricalWarning(
          code: 'life-safety-feeder-cable',
          severity: WarningSeverity.warning,
          message: '${c.name}: feeder to $childName carries the fire-pump / '
              'life-safety supply but is specified as $family — specify '
              'fire-resistant cable (FRC/MICA) or a fire-rated route so the '
              'supply survives a fire.',
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

    // Round 44 — a UPS-backed board: its supply is uplifted to the UPS input,
    // but no UPS unit / battery is sized or taken off (judge-only INFO).
    for (final p in panels) {
      if (!p.upsBacked) continue;
      warnings.add(ElectricalWarning(
        code: 'ups-not-sized',
        severity: WarningSeverity.info,
        message: '${p.name}: UPS-backed board — its supply is sized on the '
            'UPS input (output ÷ ${_num(kUpsEfficiency)} efficiency + '
            '${_num(roundTo((kUpsRechargeAllowance - 1) * 100, 0))} % battery '
            'recharge), but no UPS unit or battery is sized or taken off: '
            'specify the UPS (kVA, autonomy) and enter its battery as a '
            'source.',
        panelId: p.id,
      ));
    }

    // Supply summary from the diversified demand presented by the root panel(s).
    final rootDemandW = roots.fold(
        0.0, (s, p) => s + (panelDemandW[p.id] ?? 0) * upsIn(p.id));
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
      final w = (panelDemandW[r.id] ?? 0) * upsIn(r.id);
      final va0 = panelDemandVa[r.id];
      final va = va0 == null ? null : va0 * upsIn(r.id);
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
    // Round 42 (electrical-sim-7-parallel-run-cap-4-unsizable-feeders-and-
    // silent-service-cable) — the SERVICE cable is sized like every way, up
    // to the 4-parallel-run cap; a large service (a 2000 A ACB) cannot reach
    // its ampacity that way. It used to fail silently and the main earthing
    // conductor was then derived from the inadequate cable. Judge-only: the
    // cable + earthing figures are kept, the defect is stated.
    if (!mainCable.ampacityReached) {
      final runs = mainCable.runsPerPhase ?? 1;
      final inA = (mainBreaker?.ratingA ?? incomerRating!).amperes;
      warnings.add(ElectricalWarning(
        code: 'service-cable-ampacity-inadequate',
        severity: WarningSeverity.warning,
        message: 'Service cable: the ${_num(inA)} A service needs more than '
            '$runs parallel runs of ${_num(mainCable.csaMm2)} mm2 (Iz '
            '${_num(roundTo(mainCable.deratedIz.amperes, 1))} A < required '
            '${_num(roundTo(mainCable.izRequired?.amperes ?? inA, 1))} A) — '
            'specify a busduct or more parallel runs; the main earthing '
            'conductor derived from this cable must be re-checked against '
            'the real service.',
        panelId: governingRoot?.id,
      ));
    }
    final earthing = computeEarthing(
      profile,
      system: project.earthingSystem,
      supplyPeMm2: profile.peConductorSizeMm2(mainCable.csaMm2),
      // Round 24 — parallel service runs each carry their own PE.
      runsPerPhase: mainCable.runsPerPhase ?? 1,
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
      order: preOrder.toList(),
      totalDemandW: roundTo(rootDemandW, 0),
      supply: supply,
      earthing: earthing,
      warnings: warnings,
      feederFloorsApplied: floorsApplied,
      feederFloorsCapped: floorsCapped,
    );
  }

  // Round 56 (regression-ads-fail-both-classes-no-csa-growth) — the whole
  // device / coordination pipeline below, as one function of the current
  // [adsCsaFloors].
  ElectricalSystemResult solveAll() {
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

    // Round 43 (electrical-sim-8-mccb-frame-raise-breaks-ads) — the MCCB
    // frame-minimum raise ([faultAwareBreakerClass], 6 A -> 16 A on a bus above
    // the MCB ladder) is a device-CLASS rule; like the Round-40 coordination
    // floor it must never create an ADS failure the load-sized device did not
    // have. On TN, every FINAL way the raise reached (MCCB at the frame
    // minimum, not overridden) that fails ADS is re-sized ONCE with the raise
    // refused: the load-sized MCB is kept and the existing cascade info
    // (`mcb-backup-protection-required`) names why. Refusing only ever lowers
    // that way's own device (never a cable, a board current or another way),
    // so one more pass is the fixed point. TT / no such way ⇒ verbatim.
    ElectricalSystemResult frameAds(ElectricalSystemResult r,
        Map<String, double> floors, Map<String, double> caps) {
      final tn = r.earthing.system == EarthingSystem.tnS ||
          r.earthing.system == EarthingSystem.tnCs;
      if (!tn) return r;
      // Round 54 — every non-overridden FINAL MCCB within the MCB ladder
      // (<= 63 A): the load-sized device of such a way was an MCB, so its class
      // came from the fault rule (a 16 A / 20 A / 32 A way converts at the same
      // rating and the conversion ALONE can fail ADS — the halved Zs limit).
      final mcbTopA = profile.standardBreakerRatingsA
          .where((a) => profile.breakerClassFor(a) == BreakerClass.mcb)
          .fold<double>(0, math.max);
      final candidates = <String>[
        for (final pr in r.panels.values)
          for (final w in pr.circuits)
            if (w.loadKind != LoadKind.feeder &&
                w.breaker.deviceClass == BreakerClass.mccb &&
                !w.breaker.overridden &&
                w.breaker.ratingA.amperes <= mcbTopA + 1e-9)
              w.circuitId,
      ];
      if (candidates.isEmpty) return r;
      final origin = originFaultLevel ??
          project.originFaultLevelA ??
          estimatedServiceFaultLevelA(project,
              demand: r.supply.demandVa,
              supply: studySupplyDesign(project, r)) ??
          const Current(defaultLvUtilityFaultKa * 1000);
      final f = faultStudy(r, project, profile, originFaultLevel: origin);
      final refused = <String>{
        for (final id in candidates)
          if (f.circuits[id]?.adsOk == false) id,
      };
      if (refused.isEmpty) return r;
      // Refusing keeps each listed way's load-sized MCB (raised OR merely
      // converted): its Zs limit returns to the curve multiple.
      final kept = sizeAll(floors, caps, refused);
      // Round 55 (regression-mccb-refusal-keeps-mcb-that-also-fails-ads) — a
      // way whose load-sized MCB fails the earth-fault loop TOO gains nothing
      // from the refusal: the MCB swaps an adequate-kA MCCB for a device below
      // the bus fault (a cascade warning / breaking-capacity error) on top of
      // the unchanged ADS error, under a note claiming the MCB was kept because
      // the MCCB would fail. Such a way keeps the MCCB and its ONE defect, the
      // `ads-disconnection` error. Refusal only changes the way's own device
      // (its cable and Zs are untouched), so the MCB verdict read here is the
      // final one: one more pass is the fixed point.
      final f2 = faultStudy(kept, project, profile, originFaultLevel: origin);
      final helps = <String>{
        for (final id in refused)
          if (f2.circuits[id]?.adsOk != false) id,
      };
      if (helps.length == refused.length) return kept;
      if (helps.isEmpty) return r;
      return sizeAll(floors, caps, helps);
    }

    // No feeder needed lifting (every single-panel project, and any project whose
    // feeders are overridden or already selective) ⇒ pass 1 IS the answer, handed
    // back as-is so nothing is recomputed and the output is byte-identical.
    if (feederFloors.isEmpty) return frameAds(pass1, const {}, const {});

    // PASS 2 — exactly one more pass, and provably enough: each floor is derived
    // from a CHILD's incomer rating, which is sized from that child's own load-side
    // demand (its circuit design currents × its diversity/headroom) and is
    // therefore invariant under a change to its PARENT's feeder breaker or cable.
    // So the floors computed from pass 1 are still the correct floors in pass 2,
    // and every flagged feeder emerges at or above `selectivityRatio ×` its child's
    // incomer (or clamped at the ladder top, reported honestly) — a fixed point.
    final pass2 = sizeAll(feederFloors);

    // Round 40 (electrical-sim-5-selectivity-floor-breaks-ads) — on a TN
    // installation a raised device shrinks the earth-fault loop limit
    // (Zs_max = 0.95·U0 / (multiple × In)), so a floored feeder can fail ADS on
    // the very cable its load-sized device protected. Conductor / fault
    // protection beats coordination: any floored feeder that fails ADS is
    // capped one rung lower and re-sized, until it passes or falls back to the
    // load-sized device (a failure there is the cable's own, reported as
    // before — the floor never makes it worse). The
    // cap moves only the device — the cables, and so every Zs, are identical
    // across passes — and the floor TARGET stays recorded, so the residual
    // partial selectivity is still reported (the feeder is not in
    // [ElectricalSystemResult.feederFloorsApplied]). TT (RCD-cleared) or no
    // ADS failure ⇒ pass 2 verbatim ⇒ byte-identical.
    final isTn = pass2.earthing.system == EarthingSystem.tnS ||
        pass2.earthing.system == EarthingSystem.tnCs;
    if (!isTn) return pass2;
    final faultOrigin = originFaultLevel ??
        project.originFaultLevelA ??
        estimatedServiceFaultLevelA(project,
            demand: pass2.supply.demandVa,
            supply: studySupplyDesign(project, pass2)) ??
        const Current(defaultLvUtilityFaultKa * 1000);
    final ladder = profile.standardBreakerRatingsA;
    final caps = <String, double>{};
    var current = pass2;
    for (var iter = 0; iter < ladder.length; iter++) {
      final f =
          faultStudy(current, project, profile, originFaultLevel: faultOrigin);
      var changed = false;
      for (final id in feederFloors.keys) {
        final now = f.circuits[id];
        if (now == null || now.adsOk != false) continue;
        final parentId = feederParentOf[id];
        final rNow = current.panels[parentId]?.circuits
            .where((x) => x.circuitId == id)
            .firstOrNull;
        final rLoad = pass1.panels[parentId]?.circuits
            .where((x) => x.circuitId == id)
            .firstOrNull;
        if (rNow == null || rLoad == null) continue;
        final ratingNow = rNow.breaker.ratingA.amperes;
        final loadRating = rLoad.breaker.ratingA.amperes;
        if (ratingNow <= loadRating + 1e-9) continue;
        final lower = ladder.lastWhere((x) => x < ratingNow - 1e-9,
            orElse: () => loadRating);
        caps[id] = lower < loadRating ? loadRating : lower;
        changed = true;
      }
      if (!changed) break;
      current = sizeAll(feederFloors, Map.of(caps));
    }
    return frameAds(current, feederFloors, caps);
  }

  // Round 56 — a FINAL way that still fails automatic disconnection after the
  // class fixed point (as the MCB AND as the MCCB, IEC 60364-4-41) grows its
  // CONDUCTOR: the section steps up the standard ladder one rung at a time
  // (a lower loop impedance), the whole pipeline re-runs (the MCB / MCCB
  // choice follows the new cable), and the way stops at the first rung that
  // passes. Bounded: at most [kAdsCsaGrowthMaxRungs] rungs above its load-
  // sized section and never above [kAdsCsaGrowthMaxMm2]; the ladder exhausted
  // ⇒ the load-sized cable and the `ads-disconnection` error stand. Never an
  // overridden cable or breaker, a feeder, a spare way, parallel runs or a
  // star-delta way (its field run is the motor leads). TT / no failure ⇒ the
  // first solve verbatim.
  Current growOriginFor(ElectricalSystemResult r) =>
      originFaultLevel ??
      project.originFaultLevelA ??
      estimatedServiceFaultLevelA(project,
          demand: r.supply.demandVa, supply: studySupplyDesign(project, r)) ??
      const Current(defaultLvUtilityFaultKa * 1000);
  var result = solveAll();
  final tnGrow = result.earthing.system == EarthingSystem.tnS ||
      result.earthing.system == EarthingSystem.tnCs;
  if (!tnGrow) return result;
  final sections = profile.standardSectionsMm2;
  final loadSized = <String, double>{};
  final circuitModelById = <String, ElectricalCircuit>{
    for (final p in panels)
      for (final c in p.circuits) c.id: c,
  };
  for (var iter = 0; iter < kAdsCsaGrowthMaxRungs; iter++) {
    final f = faultStudy(result, project, profile,
        originFaultLevel: growOriginFor(result));
    var grew = false;
    for (final pr in result.panels.values) {
      for (final w in pr.circuits) {
        if (f.circuits[w.circuitId]?.adsOk != false) continue;
        final m = circuitModelById[w.circuitId];
        if (m == null ||
            m.loadKind == LoadKind.feeder ||
            m.loadKind == LoadKind.spare ||
            m.feedsPanelId != null ||
            m.cableOverrideMm2 != null ||
            m.breakerOverrideA != null ||
            m.starterType == StarterType.starDelta ||
            (w.cable.runsPerPhase ?? 1) > 1) {
          continue;
        }
        final now = w.cable.csaMm2;
        final base = loadSized.putIfAbsent(w.circuitId, () => now);
        final baseIdx = sections.indexWhere((x) => x + 1e-9 >= base);
        final next = sections.where((x) => x > now + 1e-9).firstOrNull;
        if (next == null ||
            next > kAdsCsaGrowthMaxMm2 + 1e-9 ||
            sections.indexOf(next) - baseIdx > kAdsCsaGrowthMaxRungs) {
          continue;
        }
        adsCsaFloors[w.circuitId] = next;
        grew = true;
      }
    }
    if (!grew) break;
    result = solveAll();
  }
  if (adsCsaFloors.isEmpty) return result;
  // A way the bounded ladder could not bring to compliance keeps its
  // load-sized cable and its `ads-disconnection` error (Round 55: the MCCB
  // and its one defect) — never copper grown under a note claiming it
  // disconnects in time.
  final fEnd = faultStudy(result, project, profile,
      originFaultLevel: growOriginFor(result));
  final hopeless = [
    for (final id in adsCsaFloors.keys)
      if (fEnd.circuits[id]?.adsOk == false) id,
  ];
  if (hopeless.isEmpty) return result;
  hopeless.forEach(adsCsaFloors.remove);
  return solveAll();
}
