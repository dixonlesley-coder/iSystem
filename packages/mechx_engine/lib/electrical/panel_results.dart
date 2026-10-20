/// Panel- and system-level result records produced by the A4 orchestrator
/// (`compute.dart`). Immutable plain data — the orchestrator is the ONLY
/// constructor (the "only constructors" pattern); everything else reads them.
/// Mirrors the CORE of PanelMaker's `CircuitResult` / `PanelResult` /
/// `SystemResult` (the deferred fault/PF/source/etc. fields are omitted).
///
/// Zero Flutter imports.
library;

import '../units.dart';
import 'earthing.dart' show EarthingResult, GroundingResult, RcdSpec;
import 'load_kind.dart' show LoadKind;
import 'model.dart' show ElectricalSystem;
import 'results.dart'
    show BreakerResult, BusbarResult, CableResult, NeutralPeBars, VoltageDropResult;

/// A circuit's phase assignment after balancing: a single line, or all three.
enum PhaseAssignment { l1, l2, l3, threePhase }

extension PhaseAssignmentInfo on PhaseAssignment {
  String get label => switch (this) {
        PhaseAssignment.l1 => 'L1',
        PhaseAssignment.l2 => 'L2',
        PhaseAssignment.l3 => 'L3',
        PhaseAssignment.threePhase => '3ph',
      };

  bool get isThreePhase => this == PhaseAssignment.threePhase;
}

/// A validation message attached to a panel / system.
enum WarningSeverity { info, warning, error }

class ElectricalWarning {
  final String code;
  final WarningSeverity severity;
  final String message;
  final String? panelId;
  final String? circuitId;

  const ElectricalWarning({
    required this.code,
    required this.severity,
    required this.message,
    this.panelId,
    this.circuitId,
  });
}

/// Whether a sized way's voltage drop is OVER its limit, on exactly the gate
/// `computeSystem` warns on: the way's OWN drop over its limit
/// (`voltageDrop.withinLimit == false`), OR — for a FINAL way only — the
/// CUMULATIVE drop from the supply origin over the same limit (the
/// `cumulative-voltage-drop-exceeded` warning; a feeder's cumulative is the
/// sub-bus drop its downstream ways already carry, so it is never judged on
/// it). Every issued surface (board-schedule `VD!`, calc-report verdict) reads
/// this one gate so none can disagree with the warning list.
bool voltageDropOverLimit(ElectricalCircuitResult c, {required bool isFeeder}) {
  if (!c.voltageDrop.withinLimit) return true;
  if (isFeeder) return false;
  return c.cumulativeDropPercent > c.voltageDrop.limitPercent + 1e-9;
}

/// Per-circuit sizing result.
class ElectricalCircuitResult {
  final String circuitId;
  final String name;
  final LoadKind loadKind;

  /// Design (load) current Ib, rounded to 1 dp.
  final Current designCurrent;

  /// Whether the circuit is supplied three-phase.
  final bool threePhase;

  /// Phase assignment after balancing (3ph loads all lines).
  final PhaseAssignment phase;

  final BreakerResult breaker;
  final CableResult cable;
  final VoltageDropResult voltageDrop;

  /// Cumulative origin→load voltage drop (%) along the feeder tree. Equal to the
  /// circuit's own drop for a root-panel way; set by `computeSystem`.
  final double cumulativeDropPercent;

  final GroundingResult grounding;
  final RcdSpec rcd;

  /// Effective run length used for sizing (m) — geo-derived when placed, else
  /// the manual circuit length. Drives the cable quantity in the BOM. Additive
  /// (default 0).
  final double lengthM;

  /// DIVERSIFIED load (W) on the circuit — the way's connected input × its
  /// demand factor ([circuitConnectedW]); a feeder carries the fed board's
  /// diversified demand. The demand / phase-balance basis. Additive (default 0).
  final double loadW;

  /// Round 25 — the UNDIVERSIFIED connected load (W): the way's input before
  /// its demand factor (0 for a capacitor bank; the fed board's W for a
  /// feeder). The accessory takeoff (light points / sockets) and the
  /// schedule's per-way DAYA read it. Null (a result built the legacy way) ⇒
  /// [loadW]; read it through [connectedWOrLoad].
  final double? connectedW;

  /// [connectedW] when recorded, else [loadW].
  double get connectedWOrLoad => connectedW ?? loadW;

  /// Physical outlet points on the way (1, or more when loads were chained) —
  /// the explicit accessory count floor in the BOM. Additive (default 1).
  final int points;

  /// Round 17 (report-recompute-2-elec-report-ib-not-sizing-basis) — the
  /// current the run REALLY carries when its load runs (rounded to 0.1 A): the
  /// UNDIVERSIFIED current a final way's device, conductor and printed voltage
  /// drop are sized on, the aggregated Ib for a feeder (raised to a fed
  /// capacitor bank's rated current). [designCurrent] stays the DIVERSIFIED
  /// figure for the phase balance and demand roll-up. Null (a result built the
  /// legacy way) ⇒ [designCurrent]; read it through [runCurrentA].
  final Current? runCurrent;

  /// [runCurrent] when recorded, else [designCurrent] — the Ib a reviewer can
  /// recompute In / Iz / Vd from.
  Current get runCurrentA => runCurrent ?? designCurrent;

  /// Round 38 (elec-ui-drawings-2) — a 3φ FEEDER's per-line currents (A,
  /// L1 / L2 / L3): the fed board's diversified lines exactly as they enter
  /// this board's phase balance. Null for every other way (a balanced 3φ way
  /// loads its three lines with [designCurrent]). The schedule prints these in
  /// R / S / T so the column sums to the board TOTAL.
  final List<double>? lineCurrentsA;

  const ElectricalCircuitResult({
    required this.circuitId,
    required this.name,
    required this.loadKind,
    required this.designCurrent,
    required this.threePhase,
    required this.phase,
    required this.breaker,
    required this.cable,
    required this.voltageDrop,
    required this.cumulativeDropPercent,
    required this.grounding,
    required this.rcd,
    this.lengthM = 0,
    this.loadW = 0,
    this.connectedW,
    this.points = 1,
    this.runCurrent,
    this.lineCurrentsA,
  });

  /// Copy with a new phase assignment + cumulative drop (the only fields the
  /// orchestrator finalises after the per-circuit pass).
  ElectricalCircuitResult copyWith({
    PhaseAssignment? phase,
    double? cumulativeDropPercent,
  }) =>
      ElectricalCircuitResult(
        circuitId: circuitId,
        name: name,
        loadKind: loadKind,
        designCurrent: designCurrent,
        threePhase: threePhase,
        phase: phase ?? this.phase,
        breaker: breaker,
        cable: cable,
        voltageDrop: voltageDrop,
        cumulativeDropPercent:
            cumulativeDropPercent ?? this.cumulativeDropPercent,
        grounding: grounding,
        rcd: rcd,
        lengthM: lengthM,
        loadW: loadW,
        connectedW: connectedW,
        points: points,
        runCurrent: runCurrent,
        lineCurrentsA: lineCurrentsA,
      );
}

/// The incoming device for a panel.
class IncomerResult {
  final BreakerResult breaker;

  /// Pole count (2 = 1-phase L+N, 4 = 3-phase + N).
  final int poles;

  /// Round 23 (elec-drafting-2-5) — the current the incomer was SIZED on
  /// (headroom / capacitor / service floors applied); null on legacy
  /// hand-built results.
  final Current? sizingCurrent;

  const IncomerResult(
      {required this.breaker, required this.poles, this.sizingCurrent});

  /// True when even the largest standard frame sits BELOW its sizing current
  /// (the ladder saturated) — every printed surface must say so, never print
  /// the saturated device silently.
  bool get overRange =>
      sizingCurrent != null &&
      breaker.ratingA.amperes + 1e-9 < sizingCurrent!.amperes;
}

/// Round 23 (elec-drafting-2-5) — the token every printed surface appends to
/// an incomer whose largest standard frame still sits below its sizing
/// current (the ladder saturated), so a saturated device is never printed
/// silently (the Round-8 rule the genset ladder already follows).
const String kIncomerOverRangeToken = 'OVER RANGE';

/// Round 24 — the ONE suffix every printed incomer goes through (SLD schedule
/// header + compact nodes, equipment schedule, calc report, plan export,
/// canvas card): `' OVER RANGE (needs 4330A)'` for a saturated incomer
/// ([IncomerResult.overRange]), `''` otherwise. [withNeeds] false drops the
/// needed-current figure for space-limited labels.
String incomerOverRangeSuffix(IncomerResult incomer, {bool withNeeds = true}) {
  if (!incomer.overRange) return '';
  if (!withNeeds) return ' $kIncomerOverRangeToken';
  final a = incomer.sizingCurrent!.amperes;
  final needs = a == a.roundToDouble() ? a.toInt().toString() : a.toStringAsFixed(1);
  return ' $kIncomerOverRangeToken (needs ${needs}A)';
}

/// One busbar section a panel's ways are grouped onto (radially fed from the
/// incomer, IEC 61439-1) — see `splitBusbarSections`.
class BusbarSectionResult {
  /// 1-based section index.
  final int index;

  /// The circuit ids carried on this section.
  final List<String> circuitIds;

  /// Number of ways on this section.
  final int ways;

  /// Worst-phase current the section carries (A).
  final Current sectionCurrent;

  final BusbarResult busbar;

  /// True when this section began at a user-forced manual break.
  final bool manualBreak;

  const BusbarSectionResult({
    required this.index,
    required this.circuitIds,
    required this.ways,
    required this.sectionCurrent,
    required this.busbar,
    required this.manualBreak,
  });
}

/// Per-phase line currents (A) and the resulting imbalance.
class PhaseBalanceResult {
  final double l1;
  final double l2;
  final double l3;
  final double imbalancePercent;

  /// True when a DIFFERENT phase assignment would materially cut this board's
  /// imbalance — i.e. the imbalance is something the engineer can act on (a phase
  /// pin holding a way on a loaded line, a sticky prior assignment). False when
  /// the imbalance is inherent to the board's own single-phase loads (two ways
  /// can never load three lines evenly), because the balancer has already spread
  /// them as evenly as they go.
  ///
  /// Only determined for a board whose imbalance is over the reporting limit; on
  /// an already-even board it is false (there is nothing to reduce). Additive —
  /// defaults to false.
  final bool imbalanceReducible;

  const PhaseBalanceResult({
    required this.l1,
    required this.l2,
    required this.l3,
    required this.imbalancePercent,
    this.imbalanceReducible = false,
  });
}

/// One panel's full sizing result.
class ElectricalPanelResult {
  final String panelId;
  final String name;
  final String? tag;
  final ElectricalSystem system;

  final List<ElectricalCircuitResult> circuits;

  final IncomerResult incomer;

  /// Main bus (rated for the incomer's In, IEC 61439-1).
  final BusbarResult busbar;

  /// Distribution busbar sections (≥ 1).
  final List<BusbarSectionResult> busbarSections;

  /// Neutral + PE bars derived from the main phase bar.
  final NeutralPeBars neutralPeBars;

  /// Total connected (demand-factored) load on the panel (W), rounded.
  final double connectedW;

  /// Diversified demand (W) this panel pushes upstream = connectedW × diversity.
  final double demandW;

  /// Demand line current (A) — the worst-loaded phase on a 3-phase board.
  final Current demandCurrent;

  /// Round 15 (regression-essential-genset-uses-building-pf /
  /// drafting-visual-2-3) — the board's diversified APPARENT-power demand
  /// (VA): each leaf way's W ÷ its OWN cos φ, each feeder at its fed board's
  /// VA, × diversity — the per-board basis `computeSystem` aggregates the
  /// supply kVA from, never below [demandW]. 0 = not recorded (a bare
  /// `computePanel` result); read [demandVaOrEstimate] for a figure.
  final double demandVa;

  /// [demandVa] when recorded, else [demandW] ÷ [fallbackPf] (the flat
  /// building power factor, `// VERIFY`).
  double demandVaOrEstimate({double fallbackPf = 0.85}) => demandVa > 0
      ? demandVa
      : (fallbackPf > 0 ? demandW / fallbackPf : demandW);

  /// Round 14 (elec-building-sim-4) — the line current the board's METERING
  /// (CT primary, meter range) must cover: the larger of today's demand and
  /// the current the incomer + busbar were SIZED for (`busbar.totalCurrentA`
  /// — the service-capacity floor, future-load headroom or capacitor floor).
  /// A 197 kVA entrance board demanding 150 A but rated for 284 A used to
  /// print a CT 150/5 that would run at 190 % of primary under the subscribed
  /// load. Equals [demandCurrent] when nothing floors the board.
  Current get meteringCurrent =>
      busbar.totalCurrentA.amperes > demandCurrent.amperes
          ? busbar.totalCurrentA
          : demandCurrent;

  /// Future (spare-uplifted) demand (W) the incomer + busbar were sized for when
  /// panel headroom is set = demandW × (1 + sparePercentage/100). Equal to
  /// [demandW] (no uplift) when no headroom is applied. Additive (default 0 —
  /// read [headroomApplied] to tell "no headroom" from a literal 0 W demand).
  final double futureLoadW;

  /// True when spare-ways / future-load headroom was applied to this panel's
  /// incomer + busbar sizing. Additive (default false ⇒ byte-identical path).
  final bool headroomApplied;

  /// Reserved spare outgoing ways counted toward the busbar capacity. Additive
  /// (default 0).
  final int spareWaysReserved;

  /// Round 13 — the worst line current (A) this board's CAPACITOR ways (own +
  /// fed downstream) draw at the switching multiple; it floors the incomer +
  /// busbar so a dedicated PFC board is rated for its bank. 0 (the default)
  /// when the board holds no capacitor way.
  final double capacitorCurrentA;

  final PhaseBalanceResult phaseBalance;

  /// Phase imbalance (%) — convenience alias of [phaseBalance.imbalancePercent].
  double get imbalancePercent => phaseBalance.imbalancePercent;

  final List<ElectricalWarning> warnings;

  /// The board's own diversity factor (Round 19) — [demandW] =
  /// [connectedW] × this. 1.0 on a hand-built result.
  final double diversityFactor;

  /// True when the board diversifies ([diversityFactor] < 1): its
  /// [demandCurrent] (the worst-phase balance current BEFORE diversity, the
  /// incomer / busbar sizing basis) then differs from [diversifiedDemandCurrent].
  bool get isDiversified => diversityFactor < 1 - 1e-9;

  /// The diversified worst-phase current, [demandCurrent] × [diversityFactor]
  /// (Round 19, electrical-parity-2-board-demand-current-undiversified) — the
  /// figure that pairs with the diversified [demandW] and that the
  /// `feeder-below-fed-demand` judge compares the feeder breaker against.
  Current get diversifiedDemandCurrent =>
      Current(demandCurrent.amperes * diversityFactor);

  const ElectricalPanelResult({
    required this.panelId,
    required this.name,
    this.tag,
    required this.system,
    required this.circuits,
    required this.incomer,
    required this.busbar,
    required this.busbarSections,
    required this.neutralPeBars,
    required this.connectedW,
    required this.demandW,
    required this.demandCurrent,
    this.demandVa = 0,
    this.futureLoadW = 0,
    this.headroomApplied = false,
    this.spareWaysReserved = 0,
    this.capacitorCurrentA = 0,
    required this.phaseBalance,
    required this.warnings,
    this.diversityFactor = 1.0,
  });
}

/// A simple supply / connected-power summary for the project. Daya-tersambung
/// step tables are NOT invented here (PanelMaker reads them from a `pln.ts`
/// table not present in this profile) — only the demand figures are reported.
class SupplySummary {
  /// True building connected load (leaf loads only — no feeder double-counting).
  final double connectedW;

  /// Diversified demand presented by the root panel(s) (W).
  final double demandW;

  /// Diversified demand as apparent power (VA), demandW / assumed building PF.
  final ApparentPower demandVa;

  /// The supply phase (follows the root panel).
  final ElectricalSystem system;

  /// Nominal supply voltage (V).
  final Voltage voltage;

  const SupplySummary({
    required this.connectedW,
    required this.demandW,
    required this.demandVa,
    required this.system,
    required this.voltage,
  });
}

/// The whole-project result.
class ElectricalSystemResult {
  final String projectId;

  /// Panel results keyed by panel id.
  final Map<String, ElectricalPanelResult> panels;

  /// Panel ids in root-first order.
  final List<String> order;

  /// Total diversified demand at the origin (W).
  final double totalDemandW;

  final SupplySummary supply;

  /// Installation earthing-system design.
  final EarthingResult earthing;

  final List<ElectricalWarning> warnings;

  /// Circuit ids of the FEEDER ways whose protective device `computeSystem`
  /// lifted onto the selectivity floor AND which reached the full
  /// `selectivityRatio ×` the fed board's incomer.
  ///
  /// A pair in this set is the sizer's own deliberate coordination choice, so
  /// `faultStudy` suppresses the `selectivity-partial` ADVISORY for it (landing
  /// in the 1.6×..2.5× band is what the floor targets — it is not a finding).
  /// A feeder whose floor was CAPPED by its load-sized cable's ampacity is NOT
  /// listed: the residual partial (or non-) selectivity is real and stays
  /// reported. `non-selective` is never suppressed. Empty (the default) ⇒
  /// nothing is suppressed ⇒ byte-identical for legacy-constructed results.
  final Set<String> feederFloorsApplied;

  /// G3 — circuit ids of the FEEDER ways whose selectivity floor was LIMITED by
  /// the conductor-protection CAP: the rung the floor targets sits above the
  /// largest rung the way's LOAD-sized cable's derated Iz protects, so `In ≤ Iz`
  /// (which always wins) held the device below the `selectivityRatio ×` target.
  ///
  /// Disjoint from [feederFloorsApplied] by construction (a capped floor never
  /// reaches its target). Purely EXPLANATORY: it changes no sizing, and lets
  /// `faultStudy` say WHY the residual pair cannot simply be given a bigger
  /// breaker — the lever is the cable, not the device. Empty (the default) ⇒
  /// every message keeps its legacy wording ⇒ byte-identical.
  final Set<String> feederFloorsCapped;

  const ElectricalSystemResult({
    required this.projectId,
    required this.panels,
    required this.order,
    required this.totalDemandW,
    required this.supply,
    required this.earthing,
    required this.warnings,
    this.feederFloorsApplied = const {},
    this.feederFloorsCapped = const {},
  });
}

// ── Round 35 — one service-current basis (elec-core-2) ──────────────────────

/// The line current (A) a supply of [va] passes at a board of [system] /
/// [volts] — 3φ `VA / (√3·V_LL)`, 1φ `VA / V`. The ONE conversion the
/// service-capacity floor / judge (`computeSystem`), the recommended PLN daya
/// and the genset per-phase check share, so they can never disagree. Pure.
double lineCurrentForCapacityA(
        double va, ElectricalSystem system, double volts) =>
    volts <= 0
        ? 0
        : system == ElectricalSystem.threePhase
            ? va / (_sqrt3 * volts)
            : va / volts;

/// The exact inverse of [lineCurrentForCapacityA]: the apparent power (VA)
/// whose per-phase rating is [amps] — 3φ `√3·V_LL·I`, 1φ `V·I`. A 3φ PLN
/// limiter / alternator is rated PER PHASE, so the heaviest line governs:
/// two 1φ 5 kW heaters (21.6 A on L1 and L2, 10 kVA in total) need
/// √3·400·21.6 = 15.0 kVA of per-phase rating, not 10 kVA. Pure.
double capacityForLineCurrentVa(
        double amps, ElectricalSystem system, double volts) =>
    system == ElectricalSystem.threePhase
        ? _sqrt3 * volts * amps
        : volts * amps;

const double _sqrt3 = 1.7320508075688772;
