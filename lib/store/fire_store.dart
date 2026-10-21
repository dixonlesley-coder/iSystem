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
  final st = ref.watch(standpipeDesignProvider);
  return (flow: st.requiredFlow, head: st.pumpHead, sprinklerOnly: false);
});

/// Round 29 — the GOVERNING fire system basis (the one [fireRatedPointProvider]
/// rates the project-level pump on): the hydrant system with the largest
/// rated point whenever a hydrant is drawn, else the sprinkler system with the
/// largest flow / head. Null when no fire system is drawn.
final governingFireBasisProvider = Provider<FireSystemBasis?>((ref) {
  // Round 50 — a gravity-fed system has no pump: it never governs.
  final bases = [
    for (final b in ref.watch(fireSystemBasesProvider))
      if (!b.gravityFed) b,
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
final fireOverPressureProvider = Provider<
    List<
        ({
          FireSystemBasis basis,
          ({double churnKpa, double ratedKpa, bool over, double? frictionShare})
              check,
        })>>((ref) {
  return [
    for (final b in ref.watch(fireSystemBasesProvider))
      // The 175 psi limit is the SPRINKLER component listing (NFPA 13); a
      // hydrant-only standpipe is built from high-pressure hose valves with
      // pressure-regulating outlets (NFPA 14), so it is not judged here.
      if (!b.gravityFed &&
          b.flow.cubicMetersPerSecond > 0 &&
          b.system.hasSprinkler)
        if (fireOverPressureCheck(
                rating: b.rating, indexFrictionM: b.indexFrictionM)
            case final c when c.over)
          (basis: b, check: c),
  ];
});

/// Round 29 (regression-report-standpipe-head-contradicts-rated-head) — the
/// standpipe design the calc report PRINTS: the governing hydrant system's
/// design (the SAME friction-inclusive head the fire-pump rating, schedule and
/// MDP way use), falling back to the friction-free [standpipeDesignProvider]
/// only when no hydrant system basis exists. [standpipeDesignProvider] stays
/// friction-free because it feeds the sizer (friction depends on sizing).
final reportStandpipeDesignProvider = Provider<FireStandpipeDesign>((ref) {
  final gov = ref.watch(governingFireBasisProvider);
  return gov?.standpipe ?? ref.watch(standpipeDesignProvider);
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
    this.sprinklerGovernsCombined = false,
    this.standpipeClass = StandpipeClass.classI,
    this.staticLiftM = 0,
    this.stageHeads = const {},
    this.stageDuties = const {},
    this.gravityFed = false,
    this.gravitySourceId,
    this.gravityAvailableHeadM,
    this.gravityRequiredHeadM,
  });
}

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
  final systems = fireSystems(net);
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
  final out = <FireSystemBasis>[];
  for (final sys in systems) {
    final pumps = [
      for (final n in net.nodes)
        if (sys.nodeIds.contains(n.id) &&
            (n.component == NodeComponent.pump ||
                n.component == NodeComponent.boosterSet))
          n.id,
    ]..sort();
    // The duty pump: the largest sized incident bore (a jockey sits on a
    // small leg), ties to the lowest id.
    String? duty;
    var dutyBore = -1.0;
    for (final p in pumps) {
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
    final FlowRate flow;
    final Head head;
    final double? friction;
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
    final jockey = dutyPump == null || rating.jockeyFlow.cubicMetersPerSecond <= 0
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
    if (dutyPump != null && pumps.length >= 2 && building.floors.isNotEmpty) {
      final sets = fireParallelPumpSets(net, sys, pumps);
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
      if (stages.length >= 2) {
        final nF = building.floors.length;
        int clampF(int f) => f < 0 ? 0 : (f >= nF ? nF - 1 : f);
        final datum = clampF(sys.datumFloor(net));
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
              need = building.elevationOf(clampF(nextFloor)).meters -
                  building.elevationOf(datum).meters;
            } else {
              final lift = liftTo(basisKind, belowFloor: nextFloor);
              need = basisKind == FireTerminalKind.sprinkler
                  ? sprinklerPoint(friction, lift).head.meters
                  : standpipeAt(friction, lift).pumpHead.meters;
            }
          }
          final stage = math.max(0.0, need - below);
          below += stage;
          final perSet = Head(stage);
          final r = checkFirePumpRating(ratedFlow: flow, ratedHead: perSet);
          final d = firePumpDuty(ratedFlow: flow, ratedHead: perSet, rating: r);
          for (final g in stages[k]) {
            for (final id in g) {
              stageHeads[id] = perSet;
              stageDuties[id] = d;
            }
          }
        }
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
      sprinklerGovernsCombined: sprinklerGoverns,
      standpipeClass: cls,
      staticLiftM: liftTo(basisKind),
      stageHeads: stageHeads,
      stageDuties: stageDuties,
      gravityFed: gravity != null,
      gravitySourceId: gravity?.sourceId,
      gravityAvailableHeadM: gravity?.availableM,
      gravityRequiredHeadM: gravity?.requiredM,
    ));
  }
  return out;
});

/// Round 50 — the gravity verdict of a pump-less fire system [sys], or null
/// when it is not gravity-fed (no plant source, or a source below its
/// terminals — a ground tank / mains-fed system keeps the suggested pump).
/// Each terminal kind drawn is judged: available = the highest gravity
/// source's elevation − the topmost terminal (a sprinkler at its floor's
/// ceiling, a hose outlet [kHoseOutletHeightM] above its floor) − the sized
/// index-path friction from the source ([fireIndexPathFrictionM], 0 when
/// unmeasured); required = the remote-head pressure (sprinkler) or the class
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
  for (final k in kinds) {
    final f = fireIndexPathFrictionM(
          net: net,
          system: sys,
          pumpId: best,
          sizing: sizing,
          lengthOf: lengthOf,
          terminals: k,
        ) ??
        0.0;
    final avail = bestElev - targetOf(k) - f;
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
final fireAllGravityFedProvider = Provider<bool>((ref) {
  final bases = ref.watch(fireSystemBasesProvider);
  return bases.isNotEmpty && bases.every((b) => b.gravityFed);
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
  final r = ref.watch(firePumpRatingProvider);
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
