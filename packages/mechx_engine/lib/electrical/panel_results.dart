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

  /// Connected load (W) on the circuit — for the accessory takeoff (light
  /// points / sockets). Additive (default 0).
  final double loadW;

  /// Physical outlet points on the way (1, or more when loads were chained) —
  /// the explicit accessory count floor in the BOM. Additive (default 1).
  final int points;

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
    this.points = 1,
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
        points: points,
      );
}

/// The incoming device for a panel.
class IncomerResult {
  final BreakerResult breaker;

  /// Pole count (2 = 1-phase L+N, 4 = 3-phase + N).
  final int poles;

  const IncomerResult({required this.breaker, required this.poles});
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

  final PhaseBalanceResult phaseBalance;

  /// Phase imbalance (%) — convenience alias of [phaseBalance.imbalancePercent].
  double get imbalancePercent => phaseBalance.imbalancePercent;

  final List<ElectricalWarning> warnings;

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
    this.futureLoadW = 0,
    this.headroomApplied = false,
    this.spareWaysReserved = 0,
    required this.phaseBalance,
    required this.warnings,
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

  const ElectricalSystemResult({
    required this.projectId,
    required this.panels,
    required this.order,
    required this.totalDemandW,
    required this.supply,
    required this.earthing,
    required this.warnings,
    this.feederFloorsApplied = const {},
  });
}
