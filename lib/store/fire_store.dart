import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_sprinkler_hydraulic.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/network/network.dart'
    show
        NetEdge,
        NetNode,
        Network,
        NodeComponent,
        NodeRole,
        ServiceType,
        edgeLength,
        isSupplyInletComponent,
        nodeElevation;
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/network_sizing.dart' show EdgeSizing;
import 'package:mechx_engine/units.dart' show FlowRate, Head, Length;

import 'network_store.dart';
import 'project_store.dart';
import 'sizing_store.dart' show sizingProvider;

/// Selected sprinkler hazard class (drives the sprinkler design).
final fireHazardProvider =
    NotifierProvider<FireHazardController, FireHazardClass>(
  FireHazardController.new,
);

class FireHazardController extends Notifier<FireHazardClass> {
  @override
  FireHazardClass build() => FireHazardClass.ordinaryHazard1;

  void set(FireHazardClass hazard) => state = hazard;
}

/// Sprinkler system design for the selected hazard class (SNI 03-3989-2000
/// density/area values; coverage defaults to the SNI per-class maximum).
final sprinklerDesignProvider = Provider<SprinklerDesign>(
  (ref) => designSprinklerSystem(hazard: ref.watch(fireHazardProvider)),
);

/// Standpipe + fire-pump design for the building height (single Class I riser
/// default; SNI 03-1745-2000 flow + residual pressure).
///
/// The static lift is pump datum (lowest floor) → the TOPMOST HOSE OUTLET on
/// the top floor ([standpipeStaticLift]), per `designStandpipe`'s contract —
/// not the roof (`building.totalHeight`), which overstated it by the top
/// floor's height less the outlet height.
///
/// Round 21 (fire-3-standpipe-riser-count-fixed-at-one) — the riser count is
/// the DRAWN one ([drawnStandpipeRiserCount]: distinct fire-hydrant riser
/// stacks, at least 1), so two drawn stacks rate the pump, schedule,
/// electrical way and hydrant sizing at 750 gpm (SNI 03-1745 / NFPA 14),
/// never the single-riser 500 gpm.
final standpipeDesignProvider = Provider<FireStandpipeDesign>((ref) {
  final building = ref.watch(projectControllerProvider).building;
  // The throttled sizing network (frozen during a node drag) — this design
  // feeds the hydrant sizing, so it must not re-run the heavy chain per
  // drag frame (K1).
  final net = ref.watch(sizingNetworkProvider);
  return designStandpipe(
      risers: drawnStandpipeRiserCount(net),
      buildingHeight: standpipeStaticLift(building));
});

/// Nominal per-head K-factor for the sprinkler remote-area check (L/min/bar^0.5).
/// Defaults to a standard 15 mm pendent head (K = 80). // VERIFY — head-model
/// dependent; see [kDefaultPendentKFactor].
final firePerHeadKFactorProvider =
    NotifierProvider<FirePerHeadKFactorController, double>(
  FirePerHeadKFactorController.new,
);

class FirePerHeadKFactorController extends Notifier<double> {
  @override
  double build() => kDefaultPendentKFactor;

  void set(double k) => state = k;
}

/// Remote-area hydraulic check for the sprinkler design — K-factor flow at the
/// most-remote head, branch-line friction, and the minimum-operating-pressure
/// verdict (orchestration over `hydraulics.dart`).
final sprinklerRemoteAreaProvider = Provider<SprinklerRemoteAreaResult>((ref) {
  final design = ref.watch(sprinklerDesignProvider);
  final k = ref.watch(firePerHeadKFactorProvider);
  return remoteAreaHydraulics(design: design, kFactor: k);
});

/// Round 17 (report-recompute-2-fire-sections-not-gated-per-system) — the
/// fire pump's RATED POINT on the governing DRAWN system: the standpipe
/// (flow + head from the building height) whenever a hydrant / standpipe is
/// drawn (or nothing is — the advisory inspector basis); for a SPRINKLER-ONLY
/// network the sprinkler remote-area demand at lift + branch pressure +
/// friction allowance (`sprinklerPumpRatedPoint`), never the 31.5 L/s
/// standpipe rating of a system that is not drawn.
///
/// Round 28 — the project-level figure is the GOVERNING fire SYSTEM's
/// ([fireSystemBasesProvider]): the hydrant system with the largest rated
/// point whenever a hydrant is drawn, else the sprinkler system with the
/// largest head; each drawn pump is rated on its OWN system
/// ([firePumpBasisByNodeProvider]).
final fireRatedPointProvider =
    Provider<({FlowRate flow, Head head, bool sprinklerOnly})>((ref) {
  final best = ref.watch(governingFireBasisProvider);
  if (best != null) {
    return (flow: best.flow, head: best.head, sprinklerOnly: best.sprinklerOnly);
  }
  // Round 52 r2 — fire systems ARE drawn but none is a fire pump to rate
  // (every one gravity-fed or a transfer fill): the point of a DRAWN system
  // (the transfer pump's, else the gravity system's own demand) — never the
  // advisory standpipe of a pump that does not exist. Every rating surface
  // stands down on [fireAllGravityFedProvider] anyway.
  final bases = ref.watch(fireSystemBasesProvider);
  if (bases.isNotEmpty) {
    final drawn = bases.firstWhere((b) => b.transfer, orElse: () => bases.first);
    return (
      flow: drawn.flow,
      head: drawn.head,
      sprinklerOnly: drawn.sprinklerOnly,
    );
  }
  final st = ref.watch(standpipeDesignProvider);
  return (flow: st.requiredFlow, head: st.pumpHead, sprinklerOnly: false);
});

/// Round 29 — the GOVERNING fire system basis (the one [fireRatedPointProvider]
/// rates the project-level pump on): the hydrant system with the largest
/// rated point whenever a hydrant is drawn, else the sprinkler system with the
/// largest flow / head. Null when no fire system is drawn.
final governingFireBasisProvider = Provider<FireSystemBasis?>((ref) {
  // Round 50 — a gravity-fed system has no pump: it never governs.
  // Round 52 — nor does a TRANSFER system (a pump filling a break tank is
  // not the fire pump the project is rated on).
  final bases = [
    for (final b in ref.watch(fireSystemBasesProvider))
      if (!b.gravityFed && !b.transfer) b,
  ];
  if (bases.isEmpty) return null;
  final hydrant = [
    for (final b in bases)
      if (!b.sprinklerOnly) b,
  ];
  final pool = hydrant.isNotEmpty ? hydrant : bases;
  var best = pool.first;
  for (final b in pool.skip(1)) {
    final f = b.flow.cubicMetersPerSecond - best.flow.cubicMetersPerSecond;
    if (f > 1e-12 || (f.abs() <= 1e-12 && b.head.meters > best.head.meters)) {
      best = b;
    }
  }
  return best;
});

/// Round 48 (mech-convergence-3-fire-pressure-rating-unjudged) — every drawn
/// fire SYSTEM carrying sprinklers whose pump CHURN pressure (NFPA 20
/// shut-off, 140 % of its rated head) exceeds the [kFireComponentMaxPressureKpa] (175 psi) rating of
/// standard listed components, with the friction share of its rated head.
/// JUDGE-ONLY (`fireOverPressureCheck`): the fire sizer caps velocity at
/// 6 m/s, so a tall system can build half its rated head out of friction and
/// churn at ~17 bar on DN40 pipe — the review says so, it never resizes.
///
/// Round 52 (fire-convergence-4-staged-sprinkler-system-false-over-
/// pressure) — a SERIES (zoned) system is judged at every stage's discharge
/// ([fireStagedOverPressureCheck]: the chain's churn heads less the static
/// lift up to that stage), never 1.4 x the summed system head at one point;
/// [pumpId] names the pump whose discharge sees the reported maximum (the
/// system's duty pump for a single stage). A TRANSFER system is not judged.
final fireOverPressureProvider = Provider<
    List<
        ({
          FireSystemBasis basis,
          ({double churnKpa, double ratedKpa, bool over, double? frictionShare})
              check,
          String? pumpId,
        })>>((ref) {
  final out = <({
    FireSystemBasis basis,
    ({double churnKpa, double ratedKpa, bool over, double? frictionShare})
        check,
    String? pumpId,
  })>[];
  for (final b in ref.watch(fireSystemBasesProvider)) {
    // The 175 psi limit is the SPRINKLER component listing (NFPA 13); a
    // hydrant-only standpipe is built from high-pressure hose valves with
    // pressure-regulating outlets (NFPA 14), so it is not judged here.
    if (b.gravityFed ||
        b.transfer ||
        b.flow.cubicMetersPerSecond <= 0 ||
        !b.system.hasSprinkler) {
      continue;
    }
    if (b.stages.length >= 2) {
      final c = fireStagedOverPressureCheck(
        stages: [
          for (final st in b.stages)
            FireStageLift(st.rating, st.suctionLiftM, st.upstream),
        ],
        systemRatedHeadM: b.head.meters,
        indexFrictionM: b.indexFrictionM,
      );
      if (!c.over) continue;
      out.add((
        basis: b,
        check: (
          churnKpa: c.churnKpa,
          ratedKpa: c.ratedKpa,
          over: c.over,
          frictionShare: c.frictionShare,
        ),
        pumpId: b.stages[c.stage].dutyPumpId,
      ));
      continue;
    }
    final c = fireOverPressureCheck(
        rating: b.rating, indexFrictionM: b.indexFrictionM);
    if (c.over) out.add((basis: b, check: c, pumpId: b.dutyPumpId));
  }
  return out;
});

/// Round 29 (regression-report-standpipe-head-contradicts-rated-head) — the
/// standpipe design the calc report PRINTS: the governing hydrant system's
/// design (the SAME friction-inclusive head the fire-pump rating, schedule and
/// MDP way use), falling back to the friction-free [standpipeDesignProvider]
/// only when no hydrant system basis exists. [standpipeDesignProvider] stays
/// friction-free because it feeds the sizer (friction depends on sizing).
///
/// Round 52 (fire-convergence-4-report-prints-phantom-class-i-pump-for-
/// gravity-system) — NULLABLE: the standpipe of the hydrant-bearing PUMPED
/// system (never gravity-fed, never a transfer) with the largest rated point;
/// null when no such system exists — never the friction-free Class I
/// default, which printed a 31.5 L/s / 91 m / 40 kW pump and a 100 mm riser
/// for a gravity hose-reel system with no pump (and beside a sprinkler-only
/// governing basis). The Fire inspector's advisory [standpipeDesignProvider]
/// is untouched.
final reportStandpipeDesignProvider = Provider<FireStandpipeDesign?>((ref) {
  FireSystemBasis? best;
  for (final b in ref.watch(fireSystemBasesProvider)) {
    if (b.gravityFed || b.transfer || b.standpipe == null) continue;
    if (best == null) {
      best = b;
      continue;
    }
    final f = b.flow.cubicMetersPerSecond - best.flow.cubicMetersPerSecond;
    if (f > 1e-12 || (f.abs() <= 1e-12 && b.head.meters > best.head.meters)) {
      best = b;
    }
  }
  return best?.standpipe;
});

/// Round 28 — one connected fire SYSTEM (sprinkler + hydrant edges joined
/// through shared nodes) and the pump rating it needs.
class FireSystemBasis {
  /// The connected fire network.
  final FireSystem system;

  /// The pumps / booster sets drawn on it (sorted).
  final List<String> pumpIds;

  /// True when no hydrant / standpipe is part of this system: its pump is a
  /// SPRINKLER pump, rated on the remote-area demand.
  final bool sprinklerOnly;

  /// The parallel standpipe stacks of THIS system (at least 1).
  final int standpipeRisers;

  /// Hazen–Williams friction of the sized index path from the duty pump
  /// (`fireIndexPathFrictionM`); null when unmeasured (uncalibrated) or no
  /// pump is drawn — the 15 m allowance then stands.
  final double? indexFrictionM;

  /// The rated point.
  final FlowRate flow;
  final Head head;

  /// NFPA 20 curve check on the rated point.
  final FirePumpRatingResult rating;

  /// The standpipe design of a hydrant-bearing system (carrying the sized
  /// index-path friction); null for a sprinkler-only system.
  final FireStandpipeDesign? standpipe;

  /// The main pump duty (NFPA 20 motor) and the jockey duty.
  final PumpDuty? duty;
  final PumpDuty? jockey;

  /// Round 54 (fire-convergence-6-staged-system-jockey-rated-at-summed-
  /// system-churn) — the NFPA 20 curve the JOCKEY is sized on: on a series-
  /// staged system the ROOT stage's (the jockey sits on the stage-1
  /// discharge, where the main pumps develop only that stage's churn), else
  /// the system [rating].
  final FirePumpRatingResult? stagedJockeyRating;
  FirePumpRatingResult get jockeyRating => stagedJockeyRating ?? rating;

  /// Round 37 r2 — a COMBINED (sprinkler + hydrant) system whose sprinkler
  /// HEAD exceeds the standpipe head: the pump is rated on the sprinkler point
  /// (its small remote-area flow), so the standpipe flow ([standpipe]) at the
  /// standpipe head is not a rated point — judge-only
  /// `combined-fire-sprinkler-governs` (the Round-37 'larger head at its own
  /// flow, never both' residual, surfaced rather than silent).
  final bool sprinklerGovernsCombined;

  /// Round 49 (fire-convergence-hose-reel-rated-as-class-i-standpipe) — the
  /// standpipe class the system's drawn outlets make it
  /// ([FireSystem.standpipeClass]).
  final StandpipeClass standpipeClass;

  /// Round 49 (fire-convergence-zone-lift-is-whole-building) — the static
  /// lift (m) the rated head carries: pump datum floor -> this system's own
  /// topmost terminal ([FireSystem.staticLiftM]).
  final double staticLiftM;

  /// Round 49 (fire-convergence-series-booster-fire-pump-standby) — with
  /// pumps in SERIES (a mid-level booster), each pump's OWN stage head and
  /// duty: the lower stage is rated on its own zone (or the lift to the next
  /// stage's suction), the upper on the remaining system head, so the stage
  /// heads sum to [head]. Empty for a single-stage system (every pump then
  /// takes [duty]).
  final Map<String, Head> stageHeads;
  final Map<String, PumpDuty> stageDuties;

  /// The main duty of pump [pumpId]: its series-stage duty, else [duty].
  PumpDuty? dutyFor(String pumpId) => stageDuties[pumpId] ?? duty;

  /// Round 52 (fire-convergence-4-series-stage-report-line-prints-system-
  /// pump-under-booster-tag) — the system's DUTY pump (the largest sized
  /// incident bore, ties to the lowest id — never a jockey / standby that
  /// sorts first); null when no pump is drawn. Surfaces tag the system by it.
  final String? dutyPumpId;

  /// Round 52 — the series stages in topological order (each with its own
  /// rating, duty pump, upstream stage and static lift from the datum); empty
  /// for a single-stage system. The calc report prints one line per stage
  /// and the over-pressure judge walks them ([fireStagedOverPressureCheck]).
  final List<FireStageRating> stages;

  /// Round 52 (regression-transfer-pump-into-tank-rated-whole-building-
  /// standpipe) — a TRANSFER system: pumps drawn, no fire terminal, the
  /// discharge ending at a storage tank above the pumps ([transferTankId]).
  /// Rated on the lift to the tank + the sized friction to it, with NO hose /
  /// sprinkler residual; it never governs the project fire pump and is never
  /// judged for churn over-pressure.
  final bool transfer;
  final String? transferTankId;

  /// Round 50 (fire-convergence-2-gravity-roof-tank-fire-system-gets-
  /// phantom-pump) — no fire pump / booster is drawn and every plant source
  /// is a roof tank (or a plant at / above the topmost terminal): a GRAVITY
  /// system. It has NO pump duty ([duty] / [jockey] null), never governs the
  /// project fire pump, raises no churn over-pressure and feeds no fire-pump
  /// way; it is judged on its available head instead.
  final bool gravityFed;

  /// The gravity source (the highest gravity tank) of a [gravityFed] system.
  final String? gravitySourceId;

  /// Head (m) left at the most demanding terminal of a [gravityFed] system:
  /// source elevation − terminal elevation − the sized index-path friction
  /// (0 when unmeasured — then an UPPER bound, so a shortfall is certain).
  final double? gravityAvailableHeadM;

  /// Head (m) that terminal needs (sprinkler: the remote-head pressure;
  /// hydrant: the class residual), as P / (rho g).
  final double? gravityRequiredHeadM;

  /// True when [gravityAvailableHeadM] < [gravityRequiredHeadM].
  bool get gravityHeadShort =>
      gravityFed &&
      gravityAvailableHeadM != null &&
      gravityRequiredHeadM != null &&
      gravityAvailableHeadM! < gravityRequiredHeadM! - 1e-9;

  const FireSystemBasis({
    required this.system,
    required this.pumpIds,
    required this.sprinklerOnly,
    required this.standpipeRisers,
    required this.indexFrictionM,
    required this.flow,
    required this.head,
    required this.rating,
    this.standpipe,
    required this.duty,
    required this.jockey,
    this.stagedJockeyRating,
    this.sprinklerGovernsCombined = false,
    this.standpipeClass = StandpipeClass.classI,
    this.staticLiftM = 0,
    this.stageHeads = const {},
    this.stageDuties = const {},
    this.gravityFed = false,
    this.gravitySourceId,
    this.gravityAvailableHeadM,
    this.gravityRequiredHeadM,
    this.dutyPumpId,
    this.stages = const [],
    this.transfer = false,
    this.transferTankId,
  });
}

/// Round 52 — one SERIES stage of a fire system ([FireSystemBasis.stages]).
class FireStageRating {
  /// The stage's pumps (duty / standby / jockey of one stage), sorted.
  final List<String> pumpIds;

  /// Its duty pump (the largest sized incident bore, ties to the lowest id).
  final String dutyPumpId;

  /// The head this stage develops, its NFPA 20 rating and duty.
  final Head head;
  final FirePumpRatingResult rating;
  final PumpDuty duty;

  /// Index of the stage feeding this one; null at the source.
  final int? upstream;

  /// Static lift (m) from the system datum up to this stage's pumps.
  final double suctionLiftM;

  /// Round 53 (regression-stage-head-clamp-silent) — the head (m) this
  /// stage's own derivation gave when it was below [kMinFireStageHeadM] and
  /// [head] was raised to that minimum; null when not clamped. The following
  /// stages are not reduced, so the stage heads then sum above the system
  /// head — surfaced as the judge-only `fire-stage-head-clamped:<pumpId>`
  /// info, never hidden.
  final double? clampedFromM;

  const FireStageRating({
    required this.pumpIds,
    required this.dutyPumpId,
    required this.head,
    required this.rating,
    required this.duty,
    required this.upstream,
    required this.suctionLiftM,
    this.clampedFromM,
  });
}

/// Round 52 (regression-same-room-series-first-stage-rated-zero-head) — the
/// smallest head any series fire-pump stage is rated on (m). A stage whose
/// own derivation gives less (a same-room booster chain with no terminal on
/// the interstage pipe — 0 m of floor lift) is clamped up to it: a 0 m /
/// 0.37 kW life-safety fire pump is never a valid duty. `// VERIFY
/// notAnSniClause` (a representative minimum, not a code figure).
const double kMinFireStageHeadM = 5.0;

/// Round 52 — the static lift (m) below which an interstage pipe with no
/// terminal is not a readable stage boundary: the stage head cannot be read
/// from the floor delta, so the remaining system head is split equally along
/// the chain instead.
const double kMinFireStageLiftM = 1.0;

/// Round 28 (fire-3-sprinkler-pump-gets-standpipe-duty /
/// fire-3-standpipe-stacks-counted-across-independent-systems /
/// fire-3-pump-head-ignores-sized-fire-pipe-friction) — every drawn fire
/// SYSTEM rated on its OWN demand:
///  * a system with a hydrant edge: the standpipe point for ITS stacks
///    (500 gpm for one stack, never the project-wide count of independent
///    towers), at the topmost-outlet lift;
///  * a sprinkler-only system: the remote-area demand at lift + pressure;
///  * on a calibrated drawing the friction term is the larger of the 15 m
///    allowance and the Hazen–Williams friction of the SIZED index path from
///    the duty pump (the fire sizer runs at up to 6 m/s, where small bore
///    loses ~1.4 m/m — a fixed 15 m printed heads 2x low).
/// Ordered as [fireSystems]. Empty when no fire service is drawn.
final fireSystemBasesProvider = Provider<List<FireSystemBasis>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  // Round 52 (regression-shared-suction-header-pump-rooms-still-combined-
  // duty) — the RATING systems: a pump-free suction header two independent
  // pump rooms draw from splits them like a shared tank does.
  final systems = fireRatingSystems(net);
  if (systems.isEmpty) return const [];
  final project = ref.watch(projectControllerProvider);
  final building = project.building;
  final sizing = ref.watch(sizingProvider);
  final remote = ref.watch(sprinklerRemoteAreaProvider);
  double lengthOf(NetEdge e) => edgeLength(
        e,
        net,
        calibrationBySheet: project.calibrations,
        building: building,
        mounting: project.mounting,
      ).meters;
  // The duty pump of [ids]: the largest sized incident bore (a jockey sits on
  // a small leg), ties to the lowest id.
  String? dutyOf(FireSystem sys, Iterable<String> ids) {
    String? duty;
    var dutyBore = -1.0;
    for (final p in [...ids]..sort()) {
      var bore = 0.0;
      for (final e in sys.edges) {
        if (e.fromId != p && e.toId != p) continue;
        final d = sizing[e.id]?.diameter.inMillimeters ?? 0.0;
        if (d > bore) bore = d;
      }
      if (bore > dutyBore + 1e-9) {
        duty = p;
        dutyBore = bore;
      }
    }
    return duty;
  }

  // Round 53 — one transfer-destination rule with the sizer
  // ([fireTransferDestinationTank]: the highest tank above the system's
  // lowest pump, a terminal-less system only).
  NetNode? transferTankOf(FireSystem s) => fireTransferDestinationTank(net, s,
      (n) => nodeElevation(n, building, project.mounting).meters);
  final out = <FireSystemBasis>[];
  for (final sys in systems) {
    final pumps = [
      for (final n in net.nodes)
        if (sys.nodeIds.contains(n.id) &&
            (n.component == NodeComponent.pump ||
                n.component == NodeComponent.boosterSet))
          n.id,
    ]..sort();
    final hasTerminal = sys.topTerminalFloor(net, FireTerminalKind.any) != null;
    // Round 52 (regression-pumpless-tank-fragment-becomes-governing-phantom-
    // pump) — a fragment with no pump AND no terminal (an FDC -> tank inlet
    // pipe, a tank-to-tank equalising pipe behind the Round-51 tank boundary)
    // is not a fire system to rate: no phantom pump is built for it.
    if (pumps.isEmpty && !hasTerminal) continue;
    final duty = dutyOf(sys, pumps);
    // Round 37 (mech-sim-5-combined-fire-pump-head-adds-sprinkler-
    // friction-to-standpipe) — each basis reads the friction of ITS OWN
    // terminals: the hose basis the hydrant outlets' index path, the
    // sprinkler basis the heads'. A combined system computes both and the
    // pump is rated on the larger HEAD at that basis's own flow (never Σ).
    double? frictionTo(FireTerminalKind kind) => duty == null
        ? null
        : fireIndexPathFrictionM(
            net: net,
            system: sys,
            pumpId: duty,
            sizing: sizing,
            lengthOf: lengthOf,
            terminals: kind,
          );
    final sprinklerOnly = !sys.hasHydrant;
    final risers = sys.standpipeRisers(net);
    // Round 49 (fire-convergence-hose-reel-rated-as-class-i-standpipe) — a
    // hose-reel-only system is a Class II (hose-station) standpipe.
    final cls = sys.standpipeClass(net);
    // Round 49 (fire-convergence-zone-lift-is-whole-building) — the lift is
    // THIS system's: its pump datum floor -> its own topmost terminal (a
    // mid-level pump room on a transfer tank serving L10-L19 lifts 30 m, not
    // the whole 60 m building).
    double liftTo(FireTerminalKind kind, {int? belowFloor}) =>
        sys.staticLiftM(net, building, kind, belowFloor: belowFloor);
    FlowRate flow;
    Head head;
    double? friction;
    FireStandpipeDesign? standpipe;
    var sprinklerGoverns = false;
    ({FlowRate flow, Head head}) sprinklerPoint(double? f, double liftM) =>
        sprinklerPumpRatedPoint(
          remote: remote,
          staticLiftM: liftM,
          indexPathFriction: f == null ? null : Head(f),
        );
    FireStandpipeDesign standpipeAt(double? f, double liftM) =>
        designStandpipe(
          risers: risers,
          buildingHeight: Length(liftM),
          standpipeClass: cls,
          indexPathFriction: f == null ? null : Head(f),
        );
    final FireTerminalKind basisKind;
    if (sprinklerOnly) {
      friction = frictionTo(FireTerminalKind.sprinkler);
      final p = sprinklerPoint(friction, liftTo(FireTerminalKind.sprinkler));
      flow = p.flow;
      head = p.head;
      basisKind = FireTerminalKind.sprinkler;
    } else {
      final hydrantFriction = frictionTo(FireTerminalKind.hydrant);
      final st =
          standpipeAt(hydrantFriction, liftTo(FireTerminalKind.hydrant));
      standpipe = st;
      if (sys.hasSprinkler) {
        final sprinklerFriction = frictionTo(FireTerminalKind.sprinkler);
        final sp = sprinklerPoint(
            sprinklerFriction, liftTo(FireTerminalKind.sprinkler));
        if (sp.flow.cubicMetersPerSecond >
            st.requiredFlow.cubicMetersPerSecond + 1e-12) {
          // Round 50 (regression-3) — the sprinkler remote-area flow exceeds
          // the standpipe flow (a Class II hose-reel standpipe at 100 gpm
          // beside an OH sprinkler system needing ~12 L/s): rate on the
          // sprinkler FLOW at the larger of the two heads, so ONE rated point
          // covers both conditions (never a 6.3 L/s pump the engine's own
          // sprinkler-vs-pump judge then warns against). The head is
          // supplied by whichever basis needs more; the standpipe point is
          // covered (flow and head both >=), so this is not the Round-37
          // 'sprinkler governs' residual.
          flow = sp.flow;
          if (sp.head.meters > st.pumpHead.meters + 1e-9) {
            head = sp.head;
            friction = sprinklerFriction;
            basisKind = FireTerminalKind.sprinkler;
          } else {
            head = st.pumpHead;
            friction = hydrantFriction;
            basisKind = FireTerminalKind.hydrant;
          }
        } else if (sp.head.meters > st.pumpHead.meters + 1e-9) {
          flow = sp.flow;
          head = sp.head;
          friction = sprinklerFriction;
          sprinklerGoverns = true;
          basisKind = FireTerminalKind.sprinkler;
        } else {
          flow = st.requiredFlow;
          head = st.pumpHead;
          friction = hydrantFriction;
          basisKind = FireTerminalKind.hydrant;
        }
      } else {
        flow = st.requiredFlow;
        head = st.pumpHead;
        friction = hydrantFriction;
        basisKind = FireTerminalKind.hydrant;
      }
    }
    var staticLift = liftTo(basisKind);
    // Round 52 (regression-transfer-pump-into-tank-rated-whole-building-
    // standpipe) — a TRANSFER system (pumps, no terminal, discharging into a
    // storage tank above them — a GT -> TP -> riser -> TT break tank) lifts
    // water into the tank: rated on the static lift pump -> tank plus the
    // sized friction to the tank, with NO hose / sprinkler residual and no
    // 15 m allowance (never the whole-building Class I head).
    final transferTank = pumps.isNotEmpty && !hasTerminal && duty != null
        ? transferTankOf(sys)
        : null;
    if (transferTank != null) {
      // Round 53 (regression-transfer-pump-rated-class-i-flow / fire-
      // convergence-5-transfer-pump-rated-below-its-own-discharge-flow) —
      // rated on the flow the zone it fills draws ([fireTransferFedFlow]: a
      // 6.3 L/s hose-reel zone, a 47.3 L/s two-stack zone), the figure the
      // sizer carries on the transfer pipe — never the fragment's own
      // one-riser Class I 31.5 L/s. Nothing fed ⇒ the standpipe figure stays.
      final fed = fireTransferFedFlow(net, sys, transferTank.id, systems,
          sprinklerDemand: remote.remoteAreaDemand,
          destinationTankOf: (s) => transferTankOf(s)?.id);
      if (fed != null && fed.cubicMetersPerSecond > 0) flow = fed;
      final pumpZ = nodeElevation(net.nodeById(duty!)!, building,
              project.mounting)
          .meters;
      final tankZ =
          nodeElevation(transferTank, building, project.mounting).meters;
      final f = fireIndexPathFrictionM(
        net: net,
        system: sys,
        pumpId: duty,
        sizing: sizing,
        lengthOf: lengthOf,
        targetIds: {transferTank.id},
      );
      friction = f;
      staticLift = math.max(0.0, tankZ - pumpZ);
      head = Head(staticLift + math.max(0.0, f ?? 0.0));
      standpipe = null;
      sprinklerGoverns = false;
    }
    final rating = checkFirePumpRating(ratedFlow: flow, ratedHead: head);
    // Round 50 (fire-convergence-2-gravity-roof-tank-fire-system-gets-
    // phantom-pump) — a system with no pump drawn whose every plant source
    // is a roof tank (or a plant at / above its topmost terminal) is fed by
    // GRAVITY: no pump is invented for it; it is judged on the head the tank
    // leaves at its most demanding terminal.
    final gravity = pumps.isEmpty
        ? _gravityCheck(
            sys: sys,
            net: net,
            project: project,
            sizing: sizing,
            remote: remote,
            standpipeClass: cls,
            lengthOf: lengthOf,
          )
        : null;
    final dutyPump = gravity != null || flow.cubicMetersPerSecond <= 0
        ? null
        : firePumpDuty(ratedFlow: flow, ratedHead: head, rating: rating);
    var jockey = transferTank != null ||
            dutyPump == null ||
            rating.jockeyFlow.cubicMetersPerSecond <= 0
        ? null
        : sizePump(flow: rating.jockeyFlow, head: rating.jockeyHead);
    // Round 49 (fire-convergence-series-booster-fire-pump-standby) — pumps
    // in SERIES (parallel sets on different floors) each develop only their
    // own STAGE: stage k is rated on the head its own zone (terminals below
    // the next stage's floor) needs from the system datum, less the stages
    // below it — or, with no terminal in its zone, the static lift to the
    // next stage's suction; the top stage takes the rest of [head]. So the
    // stage heads sum to the system head (never two pumps at the full head).
    // Round 50 (regression-1) — pumps on one floor are ONE parallel set
    // ([fireParallelPumpSets] merges a pump room's leg-end parts), and every
    // parallel duty / standby pump develops the WHOLE stage head (never a
    // half each).
    final stageHeads = <String, Head>{};
    final stageDuties = <String, PumpDuty>{};
    final stagesOut = <FireStageRating>[];
    void addStage(List<String> ids, double stageM, int? upstream,
        double suctionLiftM) {
      // Round 52 (regression-same-room-series-first-stage-rated-zero-head)
      // — never a stage below [kMinFireStageHeadM].
      final clamped = stageM < kMinFireStageHeadM - 1e-9;
      final perSet = Head(math.max(kMinFireStageHeadM, stageM));
      final r = checkFirePumpRating(ratedFlow: flow, ratedHead: perSet);
      final d = firePumpDuty(ratedFlow: flow, ratedHead: perSet, rating: r);
      for (final id in ids) {
        stageHeads[id] = perSet;
        stageDuties[id] = d;
      }
      stagesOut.add(FireStageRating(
        pumpIds: [...ids]..sort(),
        dutyPumpId: dutyOf(sys, ids) ?? ([...ids]..sort()).first,
        head: perSet,
        rating: r,
        duty: d,
        upstream: upstream,
        suctionLiftM: suctionLiftM,
        clampedFromM: clamped ? math.max(0.0, stageM) : null,
      ));
    }

    if (transferTank == null &&
        dutyPump != null &&
        pumps.length >= 2 &&
        building.floors.isNotEmpty) {
      final sets = fireParallelPumpSets(net, sys, pumps);
      final nF = building.floors.length;
      int clampF(int f) => f < 0 ? 0 : (f >= nF ? nF - 1 : f);
      final datum = clampF(sys.datumFloor(net));
      double liftToFloor(int f) =>
          building.elevationOf(clampF(f)).meters -
          building.elevationOf(datum).meters;
      // Round 51 (regression-same-floor-series-booster-full-head) — the
      // stage chain is read from the TOPOLOGY (a set follows the set whose
      // discharge part it takes suction from), never by floor: a ground-floor
      // series booster in the main pump room is a stage of its own, rated on
      // the head above the main pump's zone (P1 93.5 m + P2 10.5 m, never
      // both at the 104 m system head). The floor grouping below stays only
      // as the fallback when the chain cannot be read.
      final topo = fireSeriesPumpStages(net, sys, sets);
      if (topo != null && topo.length >= 2) {
        int floorOfStage(FirePumpStage st) => st.pumpIds
            .map((id) => net.nodeById(id)?.floorIndex ?? 0)
            .reduce((a, b) => a < b ? a : b);
        // The head the terminals of [zone] need from the system datum, or
        // null when the zone holds no terminal of the basis kind.
        double? zoneNeed(FireSystem zone) {
          if (zone.topTerminalFloor(net, basisKind) == null) return null;
          final lift = zone.staticLiftM(net, building, basisKind,
              datumFloorOverride: datum);
          return basisKind == FireTerminalKind.sprinkler
              ? sprinklerPoint(friction, lift).head.meters
              : standpipeAt(friction, lift).pumpHead.meters;
        }

        final tips = [
          for (var k = 0; k < topo.length; k++)
            if (!topo.any((x) => x.upstream == k)) k,
        ];
        // Stages from k to the deepest tip of its chain (k included).
        final depth = <int, int>{};
        int depthOf(int k) => depth[k] ??= 1 +
            [
              for (var x = 0; x < topo.length; x++)
                if (topo[x].upstream == k) depthOf(x),
            ].fold<int>(0, math.max);
        final cum = <int, double>{};
        for (var k = 0; k < topo.length; k++) {
          final st = topo[k];
          final base = st.upstream == null ? 0.0 : cum[st.upstream!] ?? 0.0;
          final downs = [
            for (final x in topo)
              if (x.upstream == k) x,
          ];
          double need;
          if (downs.isEmpty) {
            // The top of a single chain develops the rest of the system head;
            // a branch tip its own zone's need.
            need = tips.length == 1
                ? head.meters
                : zoneNeed(st.discharge) ?? head.meters;
          } else {
            final nextFloor =
                downs.map(floorOfStage).reduce((a, b) => a < b ? a : b);
            final z = zoneNeed(st.discharge);
            final floorLift = liftToFloor(nextFloor) - base;
            if (z != null) {
              need = z;
            } else if (floorLift >= kMinFireStageLiftM) {
              need = liftToFloor(nextFloor);
            } else {
              // Round 52 — no terminal on the interstage pipe and no floor
              // lift to read (a same-room series chain): the remaining
              // system head is split equally along the chain.
              need = base + (head.meters - base) / depthOf(k);
            }
          }
          final raw = need - base;
          final stage = math.max(kMinFireStageHeadM, raw);
          cum[k] = base + stage;
          addStage(st.pumpIds, raw, st.upstream,
              math.max(0.0, liftToFloor(floorOfStage(st))));
        }
      }
      int floorOf(List<String> g) => g
          .map((id) => net.nodeById(id)?.floorIndex ?? 0)
          .reduce((a, b) => a < b ? a : b);
      final stages = <List<List<String>>>[];
      for (final g in sets) {
        if (stages.isNotEmpty && floorOf(stages.last.first) == floorOf(g)) {
          stages.last.add(g);
        } else {
          stages.add([g]);
        }
      }
      if (topo == null && stages.length >= 2) {
        var below = 0.0;
        for (var k = 0; k < stages.length; k++) {
          double need;
          if (k == stages.length - 1) {
            need = head.meters;
          } else {
            final nextFloor = floorOf(stages[k + 1].first);
            final zoneTop =
                sys.topTerminalFloor(net, basisKind, belowFloor: nextFloor);
            if (zoneTop == null) {
              need = liftToFloor(nextFloor);
            } else {
              final lift = liftTo(basisKind, belowFloor: nextFloor);
              need = basisKind == FireTerminalKind.sprinkler
                  ? sprinklerPoint(friction, lift).head.meters
                  : standpipeAt(friction, lift).pumpHead.meters;
            }
          }
          final raw = need - below;
          final stage = math.max(kMinFireStageHeadM, raw);
          below += stage;
          addStage([for (final g in stages[k]) ...g], raw,
              k == 0 ? null : k - 1,
              math.max(0.0, liftToFloor(floorOf(stages[k].first))));
        }
      }
    }
    // Round 54 (fire-convergence-6-staged-system-jockey-rated-at-summed-
    // system-churn) — on a series-staged system the jockey keeps the
    // STAGE-1 discharge pressurised: 1 % of the rated flow at the ROOT
    // stage's churn + 5 m (1.4 x 132.15 + 5 = 190.0 m on a two-stage tower),
    // never 1.4 x the SUMMED system head + 5 m (254 m, 70 m above anything the
    // main pumps develop there).
    FirePumpRatingResult? stagedJockeyRating;
    if (stagesOut.length >= 2) {
      final root = stagesOut.firstWhere((st) => st.upstream == null,
          orElse: () => stagesOut.first);
      stagedJockeyRating = root.rating;
      if (jockey != null) {
        jockey =
            sizePump(flow: rating.jockeyFlow, head: root.rating.jockeyHead);
      }
    }
    out.add(FireSystemBasis(
      system: sys,
      pumpIds: pumps,
      sprinklerOnly: sprinklerOnly,
      standpipeRisers: risers,
      indexFrictionM: friction,
      flow: flow,
      head: head,
      rating: rating,
      standpipe: standpipe,
      duty: dutyPump,
      jockey: jockey,
      stagedJockeyRating: stagedJockeyRating,
      sprinklerGovernsCombined: sprinklerGoverns,
      standpipeClass: cls,
      staticLiftM: staticLift,
      stageHeads: stageHeads,
      stageDuties: stageDuties,
      gravityFed: gravity != null,
      gravitySourceId: gravity?.sourceId,
      gravityAvailableHeadM: gravity?.availableM,
      gravityRequiredHeadM: gravity?.requiredM,
      dutyPumpId: duty,
      stages: stagesOut,
      transfer: transferTank != null,
      transferTankId: transferTank?.id,
    ));
  }
  return out;
});

/// Round 50 — the gravity verdict of a pump-less fire system [sys], or null
/// when it is not gravity-fed (no plant source, or a source below its
/// terminals — a ground tank / mains-fed system keeps the suggested pump).
/// Each terminal kind drawn is judged: available = the least, over that
/// kind's terminals, of the highest gravity source's elevation − the
/// terminal's own elevation (a sprinkler at its floor's ceiling, a hose
/// outlet [kHoseOutletHeightM] above its floor) − the sized friction of ITS
/// path from the source ([fireIndexPathFrictionM]; unmeasured ⇒ the topmost
/// terminal with no friction); required = the remote-head pressure (sprinkler) or the class
/// residual (hydrant) as P / (rho g). The worst margin is reported.
({String sourceId, double availableM, double requiredM})? _gravityCheck({
  required FireSystem sys,
  required Network net,
  required ProjectState project,
  required Map<String, EdgeSizing> sizing,
  required SprinklerRemoteAreaResult remote,
  required StandpipeClass standpipeClass,
  required double Function(NetEdge e) lengthOf,
}) {
  final building = project.building;
  final nF = building.floors.length;
  if (nF == 0) return null;
  int clampF(int f) => f < 0 ? 0 : (f >= nF ? nF - 1 : f);
  const rhoG = 1000 * 9.81;
  final kinds = [
    if (sys.hasSprinkler) FireTerminalKind.sprinkler,
    if (sys.hasHydrant) FireTerminalKind.hydrant,
  ];
  double targetOf(FireTerminalKind k) {
    final top = clampF(sys.topTerminalFloor(net, k) ?? nF - 1);
    return k == FireTerminalKind.sprinkler
        ? building.ceilingElevationOf(top).meters
        : building.elevationOf(top).meters + kHoseOutletHeightM;
  }

  final topTarget = kinds.map(targetOf).fold<double>(
      double.negativeInfinity, (a, b) => a > b ? a : b);
  String? best;
  var bestElev = double.negativeInfinity;
  var any = false;
  for (final n in net.nodes) {
    if (!sys.nodeIds.contains(n.id) || n.role != NodeRole.plant) continue;
    if (isSupplyInletComponent(n.component)) continue;
    any = true;
    final z = nodeElevation(n, building, project.mounting).meters;
    final gravitySource =
        n.component == NodeComponent.roofTank || z >= topTarget - 1e-9;
    if (!gravitySource) return null;
    if (z > bestElev + 1e-9 ||
        ((z - bestElev).abs() <= 1e-9 && best != null && n.id.compareTo(best) < 0)) {
      best = n.id;
      bestElev = z;
    }
  }
  if (!any || best == null) return null;
  double? worstAvail;
  double? worstNeed;
  // Round 54 (fire-convergence-6-gravity-head-check-subtracts-worst-
  // friction-from-top-terminal-static) — judged PER TERMINAL: each terminal
  // keeps the tank head above ITS OWN elevation less the friction of ITS OWN
  // path. Pairing the top terminal's static head with the far low terminal's
  // (worst) friction — two different terminals — raised a false 'head
  // insufficient' on a satisfied system (a top floor beside the tank plus a
  // long ground-floor run).
  double terminalZ(String id, FireTerminalKind k) {
    final f = clampF(net.nodeById(id)?.floorIndex ?? nF - 1);
    return k == FireTerminalKind.sprinkler
        ? building.ceilingElevationOf(f).meters
        : building.elevationOf(f).meters + kHoseOutletHeightM;
  }

  for (final k in kinds) {
    final byTerminal = <String, double>{};
    final f = fireIndexPathFrictionM(
          net: net,
          system: sys,
          pumpId: best,
          sizing: sizing,
          lengthOf: lengthOf,
          terminals: k,
          frictionByTerminalOut: byTerminal,
        ) ??
        0.0;
    var avail = bestElev - targetOf(k) - f;
    if (byTerminal.isNotEmpty) {
      avail = double.infinity;
      for (final t in byTerminal.entries) {
        final a = bestElev - terminalZ(t.key, k) - t.value;
        if (a < avail) avail = a;
      }
    }
    final need = k == FireTerminalKind.sprinkler
        ? remote.remoteHeadPressure.pascals / rhoG
        : residualPressureKpa(standpipeClass) * 1000 / rhoG;
    if (worstAvail == null || avail - need < worstAvail - worstNeed!) {
      worstAvail = avail;
      worstNeed = need;
    }
  }
  if (worstAvail == null) return null;
  return (sourceId: best, availableM: worstAvail, requiredM: worstNeed!);
}

/// Round 28 — each drawn fire pump -> the basis of its OWN fire system (its
/// duty, jockey duty and service label), read by the panel feed, the
/// equipment schedule and the riser detail.
final firePumpBasisByNodeProvider = Provider<Map<String, FireSystemBasis>>(
  (ref) => {
    for (final b in ref.watch(fireSystemBasesProvider))
      for (final p in b.pumpIds) p: b,
  },
);

/// Round 50 r2 — true when fire systems are drawn and EVERY one is fed by
/// gravity (a roof tank, no pump drawn). The rated point
/// ([fireRatedPointProvider]) then falls back to the advisory standpipe
/// design, so every surface that prints a fire-pump rating (the Fire
/// inspector's headline, the calc report's rating block) must stand down on
/// this — there is no pump to rate.
///
/// Round 52 r2 (r52-review-transfer-exclusion-leaks-phantom-pump-into-report)
/// — a TRANSFER system (a pump only filling a break / roof tank) is not a
/// fire pump to rate either: with every system gravity-fed OR a transfer
/// fill ([governingFireBasisProvider] null) there is no project fire pump,
/// so [firePumpDutyProvider], the jockey and the report's rating block stand
/// down instead of rating the advisory standpipe — a 55 kW pump no drawn
/// machine carries. The transfer pump keeps its own schedule row / MDP way
/// / report line on its own basis.
final fireAllGravityFedProvider = Provider<bool>((ref) {
  final bases = ref.watch(fireSystemBasesProvider);
  return bases.isNotEmpty && bases.every((b) => b.gravityFed || b.transfer);
});

/// NFPA 20 fire-pump rating-curve check for the fire pump — churn / rated /
/// overload duty points, motor selection on the governing point, jockey-pump
/// recommendation, and duty/standby designation — at the governing DRAWN
/// rated point ([fireRatedPointProvider]).
final firePumpRatingProvider = Provider<FirePumpRatingResult>((ref) {
  final rp = ref.watch(fireRatedPointProvider);
  return checkFirePumpRating(
    ratedFlow: rp.flow,
    ratedHead: rp.head,
  );
});

/// The ONE fire-pump duty every downstream surface uses — the equipment
/// schedule's FP-01 row AND the MEP→electrical auto-feed. The hydraulic duty is
/// the standpipe rated point ([sizePump] on the required flow / pump head), but
/// the MOTOR is the NFPA 20 selection from [firePumpRatingProvider] (the
/// smallest standard frame covering the OVERLOAD shaft power) — so the schedule,
/// the Fire ResultCard's motor and the board-schedule circuit all name the same
/// kW. Null when no standpipe flow is required.
///
/// Round 15 (drafting-visual-2-5) — also null unless the project actually
/// DRAWS a fire service (a sprinkler or hydrant edge): the standpipe design is
/// advisory (it always exists from the building height and stays in the Fire
/// inspector), but a 55 kW / 94 m FP-01 on the procurement schedule and a
/// 55 kW life-safety way on the MDP of a building with no fire system is a
/// wrong deliverable.
final firePumpDutyProvider = Provider<PumpDuty?>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  if (!net.edges.any((e) =>
      e.service == ServiceType.fireSprinkler ||
      e.service == ServiceType.fireHydrant)) {
    return null;
  }
  // Round 50 — every drawn fire system fed by gravity (a roof tank, no pump
  // drawn): there is no fire pump to schedule or feed.
  if (ref.watch(fireAllGravityFedProvider)) return null;
  // Round 17 — rated on the governing DRAWN system (sprinkler-only ⇒ the
  // remote-area demand, else the standpipe).
  final rp = ref.watch(fireRatedPointProvider);
  if (rp.flow.cubicMetersPerSecond <= 0) return null;
  // Round 12 — the engine's shared `firePumpDuty` (the export harness calls
  // the same function, so the sample set issues the app's FP-01 duty).
  return firePumpDuty(
    ratedFlow: rp.flow,
    ratedHead: rp.head,
    rating: ref.watch(firePumpRatingProvider),
  );
});

/// Round 21 (fire-3-parallel-fire-pumps-each-full-duty) — the JOCKEY pump's
/// duty: the rating's pressure-maintenance point ([FirePumpRatingResult.
/// jockeyFlow] = 1 % rated flow at [FirePumpRatingResult.jockeyHead] = churn
/// + 5 m), sized by [sizePump] on the standard ladder. Fed to a drawn jockey
/// pump's way and its schedule row — never the 55-75 kW main motor. Null
/// whenever [firePumpDutyProvider] is (no fire service drawn).
final fireJockeyDutyProvider = Provider<PumpDuty?>((ref) {
  if (ref.watch(firePumpDutyProvider) == null) return null;
  // Round 54 — a series-staged governing system's jockey sits on its root
  // stage ([FireSystemBasis.jockeyRating]).
  final g = ref.watch(governingFireBasisProvider);
  final r = g != null && g.stages.length >= 2
      ? g.jockeyRating
      : ref.watch(firePumpRatingProvider);
  if (r.jockeyFlow.cubicMetersPerSecond <= 0) return null;
  return sizePump(flow: r.jockeyFlow, head: r.jockeyHead);
});

/// Sprinkler-vs-fire-pump coverage check (audit r8 fire-hvac-3) — JUDGE-ONLY.
///
/// Compares each drawn SPRINKLER-bearing fire system's demand with the pump
/// that actually serves it. Reported only when a sprinkler system is DRAWN
/// (fireSprinkler edges):
///  * flow:  remote-area demand (`sprinklerRemoteAreaProvider`) vs the pump's
///           rated flow;
///  * head:  a LOWER-BOUND sprinkler requirement — static lift from the pump
///           datum (floor 0) to the top-floor ceiling + the branch-base pressure
///           as head (P/ρg) — vs the pump head. Riser / main friction is NOT
///           added, so a flagged shortfall is certain, never speculative.
///
/// Round 29 (regression-sprinkler-check-uses-other-systems-pump) — Round 28
/// rates every connected fire system on its OWN demand
/// ([fireSystemBasesProvider]), so the pump compared is that SYSTEM's duty
/// (its drawn pump, or — for a combined sprinkler + hydrant system — its
/// standpipe-rated pump), never the project-level governing (hydrant) pump of
/// a separate tower. Only a sprinkler-only system with NO pump drawn falls back
/// to the governing [firePumpDutyProvider] (the scheduled FP-01 is then the
/// only candidate). The worst short system is reported (flow deficit first,
/// then head deficit); with none short, the tightest flow margin.
/// Never resizes anything. Null when no sprinkler is drawn or no pump duty.
final sprinklerPumpCheckProvider = Provider<
    ({
      double demandLps,
      double pumpLps,
      double requiredHeadM,
      double pumpHeadM,
      bool flowShort,
      bool headShort,
    })?>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  if (!net.edges.any((e) => e.service == ServiceType.fireSprinkler)) {
    return null;
  }
  final remote = ref.watch(sprinklerRemoteAreaProvider);
  final building = ref.watch(projectControllerProvider).building;
  const rhoG = 1000 * 9.81;
  final demand = remote.remoteAreaDemand.inLitersPerSecond;
  // The pump serving each sprinkler-bearing system, judged against THAT
  // system's own lift (Round 49 — pump datum floor -> its highest head's
  // ceiling, never the whole building).
  final pumps = <(PumpDuty, double)>[];
  for (final b in ref.watch(fireSystemBasesProvider)) {
    if (!b.system.hasSprinkler) continue;
    // Round 50 — a gravity system is judged on its tank head
    // ([FireSystemBasis.gravityHeadShort]), never against another system's
    // pump or a phantom duty.
    if (b.gravityFed) continue;
    // Round 52 — a transfer system fills a tank; it serves no head.
    if (b.transfer) continue;
    final own = b.pumpIds.isNotEmpty || b.system.hasHydrant;
    final pump = own ? b.duty : ref.watch(firePumpDutyProvider);
    final lift =
        b.system.staticLiftM(net, building, FireTerminalKind.sprinkler);
    if (pump != null) {
      pumps.add((pump, lift + remote.branchBasePressure.pascals / rhoG));
    }
  }
  if (pumps.isEmpty) return null;
  ({
    double demandLps,
    double pumpLps,
    double requiredHeadM,
    double pumpHeadM,
    bool flowShort,
    bool headShort,
  })? worst;
  for (final (pump, required) in pumps) {
    final pumpLps = pump.flow.inLitersPerSecond;
    final r = (
      demandLps: demand,
      pumpLps: pumpLps,
      requiredHeadM: required,
      pumpHeadM: pump.head.meters,
      flowShort: demand > pumpLps + 1e-9,
      headShort: required > pump.head.meters + 1e-9,
    );
    if (worst == null) {
      worst = r;
      continue;
    }
    final rShort = r.flowShort || r.headShort;
    final wShort = worst.flowShort || worst.headShort;
    if (rShort != wShort) {
      if (rShort) worst = r;
      continue;
    }
    final df = (demand - r.pumpLps) - (demand - worst.pumpLps);
    if (df > 1e-9 ||
        (df.abs() <= 1e-9 &&
            (r.requiredHeadM - r.pumpHeadM) >
                (worst.requiredHeadM - worst.pumpHeadM) + 1e-9)) {
      worst = r;
    }
  }
  return worst;
});
