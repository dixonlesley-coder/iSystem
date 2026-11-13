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
        drawOrderCompare,
        naturalIdCompare,
        Network,
        NodeComponent,
        NodeRole,
        ServiceType,
        edgeLength,
        isSupplyInletComponent,
        nodeElevation;
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/network_sizing.dart'
    show EdgeSizing, fireHopSources;
import 'package:mechx_engine/sizing/standpipe_outlet_pressure.dart';
import 'package:mechx_engine/sizing/fire_water_reserve.dart';
import 'package:mechx_engine/units.dart' show FlowRate, Head, Length;

import 'network_store.dart';
import 'project_store.dart';
import 'sizing_store.dart' show parallelLegEdgeIdsProvider, sizingProvider;

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
      if (!b.standsDown) b,
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

/// Backlog A-3 (2026-11-13) — one pumped fire system's WORKING pressure (the
/// churn pressure at its pump discharge — at the stage discharge that sees
/// the maximum on a series system, [fireStagedOverPressureCheck]) and the
/// pressure class ([firePressureClassFor]) its pipework and fittings
/// downstream of the pump must carry. [pumpId] names the pump whose discharge
/// sees it. Never clamped: the solved churn is printed.
class FirePressureClassLine {
  final FireSystemBasis basis;
  final String? pumpId;
  final double churnKpa;
  final double ratedKpa;
  final double? frictionShare;
  final FirePressureClass pressureClass;

  /// A hydrant-only standpipe (no sprinkler head drawn).
  final bool standpipe;

  const FirePressureClassLine({
    required this.basis,
    required this.pumpId,
    required this.churnKpa,
    required this.ratedKpa,
    required this.frictionShare,
    required this.pressureClass,
    required this.standpipe,
  });
}

/// Backlog A-3 — the working pressure and pressure class of every pumped
/// (not gravity / dry / transfer) fire system carrying sprinklers or
/// hydrants, in [fireSystemBasesProvider] order.
final firePressureClassesProvider =
    Provider<List<FirePressureClassLine>>((ref) {
  final out = <FirePressureClassLine>[];
  final net = ref.watch(sizingNetworkProvider);
  for (final b in ref.watch(fireSystemBasesProvider)) {
    if (b.standsDown ||
        b.flow.cubicMetersPerSecond <= 0 ||
        (!b.system.hasSprinkler && !b.system.hasHydrant)) {
      continue;
    }
    final standpipe = !b.system.hasSprinklerHead(net);
    double churn, rated;
    double? share;
    String? pump;
    if (b.stages.length >= 2) {
      final c = fireStagedOverPressureCheck(
        stages: [
          for (final st in b.stages)
            FireStageLift(st.rating, st.suctionLiftM, st.upstream),
        ],
        systemRatedHeadM: b.head.meters,
        indexFrictionM: b.indexFrictionM,
      );
      churn = c.churnKpa;
      rated = c.ratedKpa;
      share = c.frictionShare;
      pump = b.stages[c.stage].dutyPumpId;
    } else {
      final c = fireOverPressureCheck(
          rating: b.rating, indexFrictionM: b.indexFrictionM);
      churn = c.churnKpa;
      rated = c.ratedKpa;
      share = c.frictionShare;
      pump = b.dutyPumpId;
    }
    out.add(FirePressureClassLine(
      basis: b,
      pumpId: pump,
      churnKpa: churn,
      ratedKpa: rated,
      frictionShare: share,
      pressureClass: firePressureClassFor(churn),
      standpipe: standpipe,
    ));
  }
  return out;
});

/// Round 48 (mech-convergence-3-fire-pressure-rating-unjudged) — every drawn
/// fire SYSTEM whose pump CHURN pressure is too high for the components.
/// JUDGE-ONLY: it never resizes.
///
/// Backlog A-3 (2026-11-13, superseding the Round-48 175 psi component limit
/// for sprinkler-bearing systems) — a churn above 175 psi now sets a higher
/// pressure CLASS for the pipework and fittings ([firePressureClassesProvider]:
/// PN16 to 1600 kPa, PN25 to 2413 kPa), printed on the fire results and BOM.
/// Only a churn above [kStandpipeMaxSystemPressureKpa] (350 psi, NFPA 14
/// 7.2.1.1) is listed here: no class permits a single zone above it, the
/// standpipe must be split into vertical zones. A series system is judged at
/// every stage's discharge (Round 52); [pumpId] names the pump whose
/// discharge sees the maximum. A TRANSFER system is not judged.
final fireOverPressureProvider = Provider<
    List<
        ({
          FireSystemBasis basis,
          ({double churnKpa, double ratedKpa, bool over, double? frictionShare})
              check,
          String? pumpId,
          bool standpipe,
        })>>((ref) {
  return [
    for (final l in ref.watch(firePressureClassesProvider))
      if (l.pressureClass == FirePressureClass.zoneRequired)
        (
          basis: l.basis,
          check: (
            churnKpa: l.churnKpa,
            ratedKpa: l.ratedKpa,
            over: true,
            frictionShare: l.frictionShare,
          ),
          pumpId: l.pumpId,
          standpipe: l.standpipe,
        ),
  ];
});

/// Round 76 (fire-convergence-27-hose-outlet-static-over-175psi-unjudged) —
/// one CONTIGUOUS floor range of hose outlets of one pumped fire system whose
/// pressure exceeds an NFPA 14 hose-connection limit
/// ([standpipeOutletPressures]): [residual] false ⇒ the 175 psi STATIC at
/// pump churn (7.2.3.2, every hose outlet), true ⇒ the 100 psi RESIDUAL at
/// the rated flow of a 1.5 in hose station (7.2.3.1, hose reels). [maxKpa] /
/// [minKpa] are the worst / least offending outlets; [lowestOutletId] the
/// lowest offending outlet (the locate). An outlet fed through a drawn PRV is
/// regulated and never listed.
class StandpipeOutletOverPressure {
  final FireSystemBasis basis;
  final String? pumpId;
  final bool residual;
  final int lowFloor;
  final int highFloor;
  final double maxKpa;
  final double minKpa;
  final String lowestOutletId;
  const StandpipeOutletOverPressure({
    required this.basis,
    required this.pumpId,
    required this.residual,
    required this.lowFloor,
    required this.highFloor,
    required this.maxKpa,
    required this.minKpa,
    required this.lowestOutletId,
  });

  double get limitKpa =>
      residual ? kHoseStationMaxResidualKpa : kStandpipeOutletMaxStaticKpa;
}

/// Round 76 — every pumped standpipe's over-pressured hose-outlet floor
/// ranges (JUDGE-ONLY, beside the [fireOverPressureProvider] system judge,
/// which is unchanged). A series system's outlets take the churn / rated
/// heads of the stages on their own path; a hose-reel residual is judged
/// only when the friction to the reel is measured (calibrated).
///
/// Backlog A-3 (2026-11-13) — a STATIC range ([residual] false) is no longer a
/// defect to fix outside the app: every outlet in it is DESIGNATED a
/// pressure-regulating hose valve ([StandpipeOutletPressure.prvHoseValve],
/// [prvHoseValvesProvider]); the Review states it as the INFO
/// `standpipe-prv-hose-valves`. The residual (hose-reel) ranges are unchanged.
final standpipeOutletOverPressureProvider =
    Provider<List<StandpipeOutletOverPressure>>((ref) {
  final out = <StandpipeOutletOverPressure>[];
  for (final (basis: b, outlets: outlets)
      in ref.watch(standpipeOutletPressuresProvider)) {
    for (final residual in [false, true]) {
      // Over outlets per floor, then contiguous floor runs.
      final byFloor = <int, List<StandpipeOutletPressure>>{};
      for (final o in outlets) {
        if (residual ? o.overResidual : o.overStatic) {
          (byFloor[o.floorIndex] ??= []).add(o);
        }
      }
      final floors = byFloor.keys.toList()..sort();
      var i = 0;
      while (i < floors.length) {
        var j = i;
        while (j + 1 < floors.length && floors[j + 1] == floors[j] + 1) {
          j++;
        }
        final run = [
          for (var k = i; k <= j; k++) ...byFloor[floors[k]]!,
        ];
        double kpa(StandpipeOutletPressure o) =>
            residual ? o.residualKpa! : o.staticKpa;
        var mx = kpa(run.first), mn = kpa(run.first);
        for (final o in run) {
          if (kpa(o) > mx) mx = kpa(o);
          if (kpa(o) < mn) mn = kpa(o);
        }
        out.add(StandpipeOutletOverPressure(
          basis: b,
          pumpId: b.dutyPumpId,
          residual: residual,
          lowFloor: floors[i],
          highFloor: floors[j],
          maxKpa: mx,
          minKpa: mn,
          lowestOutletId: run.first.outletId,
        ));
        i = j + 1;
      }
    }
  }
  return out;
});

/// Backlog A-3 — every hose outlet designated a pressure-regulating hose
/// valve (static at churn above 175 psi, unregulated), keyed by outlet id —
/// the per-outlet flag the fire results, the component take-off and the
/// riser tag read.
final prvHoseValvesProvider =
    Provider<Map<String, StandpipeOutletPressure>>((ref) => {
          for (final (basis: _, outlets: outlets)
              in ref.watch(standpipeOutletPressuresProvider))
            for (final o in outlets)
              if (o.prvHoseValve) o.outletId: o,
        });

/// Round 76 / backlog A-3 — the pressure at EVERY hose outlet of every
/// pumped standpipe ([standpipeOutletPressures]), per system.
final standpipeOutletPressuresProvider = Provider<
    List<({FireSystemBasis basis, List<StandpipeOutletPressure> outlets})>>(
    (ref) {
  final net = ref.watch(sizingNetworkProvider);
  final bases = ref.watch(fireSystemBasesProvider);
  if (bases.isEmpty) return const [];
  final project = ref.watch(projectControllerProvider);
  final sizing = ref.watch(sizingProvider);
  double lengthOf(NetEdge e) => edgeLength(
        e,
        net,
        calibrationBySheet: project.calibrations,
        building: project.building,
        mounting: project.mounting,
      ).meters;
  final out =
      <({FireSystemBasis basis, List<StandpipeOutletPressure> outlets})>[];
  for (final b in bases) {
    if (b.standsDown || b.pumpIds.isEmpty || b.flow.cubicMetersPerSecond <= 0) {
      continue;
    }
    if (!b.system.hasHoseOutlet(net)) continue;
    final churn = <String, double>{};
    final rated = <String, double>{};
    if (b.stages.length >= 2) {
      for (final st in b.stages) {
        for (final id in st.pumpIds) {
          churn[id] = st.rating.churn.head.meters;
          rated[id] = st.rating.ratedHead.meters;
        }
      }
    } else {
      // Round 80 (regression-outlet-overpressure-ignores-per-pump-stage-
      // head) — a merged peer-room booster drawing from its OWN suction tank
      // carries its reduced per-pump head ([FireSystemBasis.stageHeads]: the
      // system head less the rise to its tank — the duty, motor and MDP way
      // already use it); its churn is 140 % of THAT head, never the system
      // churn (the outlet walk already resets the head at its tank). No
      // per-pump entry ⇒ the system rating (byte-identical).
      for (final id in b.pumpIds) {
        final own = b.stageHeads[id];
        if (own == null) {
          churn[id] = b.rating.churn.head.meters;
          rated[id] = b.rating.ratedHead.meters;
        } else {
          final r = checkFirePumpRating(ratedFlow: b.flow, ratedHead: own);
          churn[id] = r.churn.head.meters;
          rated[id] = r.ratedHead.meters;
        }
      }
    }
    String? rootPump = b.dutyPumpId;
    for (final st in b.stages) {
      if (st.upstream == null) {
        rootPump = st.dutyPumpId;
        break;
      }
    }
    final friction = <String, double>{};
    if (rootPump != null) {
      final f = fireIndexPathFrictionM(
        net: net,
        system: b.system,
        pumpId: rootPump,
        sizing: sizing,
        lengthOf: lengthOf,
        terminals: FireTerminalKind.hydrant,
        frictionByTerminalOut: friction,
      );
      if (f == null) friction.clear(); // unmeasured ⇒ residual not judged
    }
    final outlets = standpipeOutletPressures(
      net: net,
      system: b.system,
      sizing: sizing,
      building: project.building,
      churnHeadByPump: churn,
      ratedHeadByPump: rated,
      frictionToOutletM: friction,
    );
    out.add((basis: b, outlets: outlets));
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
    if (b.standsDown || b.standpipe == null) continue;
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

  /// Round 37 r2, superseded by reference apartment A1 — a COMBINED
  /// (sprinkler + hydrant) system whose sprinkler HEAD exceeds the standpipe
  /// head: the sprinkler sets the pump HEAD while the standpipe ([standpipe])
  /// sets the FLOW (rated at max flow, max head — both points covered); the
  /// INFO `combined-fire-sprinkler-governs` names the split.
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

  /// Round 61 (fire-convergence-13-dry-fdc-standpipe-phantom-55kw-pump) — a
  /// DRY (brigade-fed) system: no pump and no tank drawn, its only plant(s)
  /// fire department connections ([isSupplyInletComponent]). The fire
  /// brigade's pumper supplies it, so — like a [gravityFed] system — it has
  /// NO pump duty ([duty] / [jockey] null), never governs the project fire
  /// pump, raises no churn over-pressure and feeds no fire-pump way; the
  /// Review states the pressure the brigade must deliver at the inlet
  /// ([dryRequiredInletHeadM]) instead of asking for a pump / tank a dry
  /// riser design cannot add.
  final bool dry;

  /// The inlet (FDC) of a [dry] system that the required pressure is
  /// reckoned from (the first drawn).
  final String? dryInletId;

  /// Head (m) the brigade must deliver at [dryInletId]: the static lift from
  /// the inlet to the topmost terminal + the class residual (hose) or the
  /// remote-head pressure (sprinkler) + the larger of the sized friction from
  /// the inlet and the 15 m allowance — the point a pump at the inlet would
  /// be rated on.
  final double? dryRequiredInletHeadM;

  /// Backlog A-1 (2026-11-13, office O3) — the SPRINKLER POINT head (m) of a
  /// system that carries a sprinkler head: `sprinklerPumpRatedPoint` over
  /// this system's sprinkler lift, the remote-area result and the sized
  /// sprinkler index friction from the duty pump — the SAME figure the
  /// rating basis reads. The sprinkler-vs-pump judge
  /// ([sprinklerPumpCheckProvider]) requires exactly this head, so the judge
  /// and the rating never give two heads for one requirement. Null when no
  /// sprinkler head is drawn on the system.
  final double? sprinklerPointHeadM;

  /// True when this system has no pump of its own to rate: gravity-fed, a
  /// transfer fill or a dry (brigade-fed) system.
  bool get standsDown => gravityFed || transfer || dry;

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
    this.dry = false,
    this.dryInletId,
    this.dryRequiredInletHeadM,
    this.sprinklerPointHeadM,
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
  int byDraw(String a, String b) {
    final na = net.nodeById(a);
    final nb = net.nodeById(b);
    if (na == null || nb == null) return naturalIdCompare(a, b);
    return drawOrderCompare(na, nb);
  }

  // Round 62 (regression-duty-pick-sizer-vs-basis-disagree) — ONE rule
  // with the panel feed's roles ([parallelFirePumpRoles]): the largest
  // incident bore, then a pump OFF the sizer's mirrored standby legs, then
  // the first drawn — so the calc report's tag names the pump the MDP and
  // the schedule call duty, never the one they call '(standby)'.
  final parallelLegs = ref.watch(parallelLegEdgeIdsProvider);
  bool onLeg(FireSystem sys, String p) => sys.edges.any((e) =>
      (e.fromId == p || e.toId == p) && parallelLegs.contains(e.id));
  String? dutyOf(FireSystem sys, Iterable<String> ids) {
    double boreOf(String p) {
      var bore = 0.0;
      for (final e in sys.edges) {
        if (e.fromId != p && e.toId != p) continue;
        final d = sizing[e.id]?.diameter.inMillimeters ?? 0.0;
        if (d > bore) bore = d;
      }
      return bore;
    }

    final ranked = [...ids]..sort((a, b) {
        final d = boreOf(b).compareTo(boreOf(a));
        if (d != 0) return d;
        final la = onLeg(sys, a) ? 1 : 0, lb = onLeg(sys, b) ? 1 : 0;
        if (la != lb) return la - lb;
        return byDraw(a, b);
      });
    return ranked.isEmpty ? null : ranked.first;
  }

  // Round 53 — one transfer-destination rule with the sizer
  // ([fireTransferDestinationTank]: the highest tank above the system's
  // lowest pump, a terminal-less system only).
  NetNode? transferTankOf(FireSystem s) => fireTransferDestinationTank(net, s,
      (n) => nodeElevation(n, building, project.mounting).meters);
  // Round 70 — the break tank a ZONE room also fills (the sizer's rule).
  NetNode? fillTankOf(FireSystem s) => fireFillDestinationTank(net, s,
      (n) => nodeElevation(n, building, project.mounting).meters);
  String? destinationOf(FireSystem s) =>
      transferTankOf(s)?.id ?? fillTankOf(s)?.id;
  // Round 80 — the hop reading's discharge-only (gravity standby) tanks,
  // computed once on demand for the series-stage topology.
  Set<String>? dischargeOnlyMemo;
  Set<String> dischargeOnlyTanks() => dischargeOnlyMemo ??= fireHopSources(
          net,
          elevationOf: (n) =>
              nodeElevation(n, building, project.mounting).meters)
      .dischargeOnly
      .keys
      .toSet();
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
    // Round 62 (fire-convergence-14-sprinkler-plus-yard-rated-as-phantom-
    // class-i-standpipe) — a yard (pillar) hydrant sits on hydrant pipe but
    // is no building standpipe: sprinklers + yard pillars with NO hose
    // outlet are rated on the sprinkler point and the yard point (the yard
    // block below), never on a phantom Class I standpipe lifted to the
    // building top (75 kW and a false churn over-pressure for a 37 kW
    // duty).
    final hasBuildingStandpipe =
        sys.topTerminalFloor(net, FireTerminalKind.hydrant) != null;
    final sprinklerOnly = !sys.standpipeTermApplies(net);
    final ratedOnSprinkler = sprinklerOnly ||
        (!hasBuildingStandpipe &&
            sys.hasSprinklerHead(net) &&
            sys.yardHydrantIds(net).isNotEmpty);
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
    // Backlog A-1 — the system's sprinkler point head (one source of truth
    // for the rating basis AND the sprinkler-vs-pump judge).
    double? sprinklerPointHead;
    if (ratedOnSprinkler) {
      friction = frictionTo(FireTerminalKind.sprinkler);
      final p = sprinklerPoint(friction, liftTo(FireTerminalKind.sprinkler));
      flow = p.flow;
      head = p.head;
      if (sys.hasSprinklerHead(net)) sprinklerPointHead = p.head.meters;
      basisKind = FireTerminalKind.sprinkler;
    } else {
      final hydrantFriction = frictionTo(FireTerminalKind.hydrant);
      final st =
          standpipeAt(hydrantFriction, liftTo(FireTerminalKind.hydrant));
      standpipe = st;
      // Round 64 — only a drawn HEAD gives a system a sprinkler point (a
      // suction leg drawn on the sprinkler service is no remote area).
      if (sys.hasSprinklerHead(net)) {
        final sprinklerFriction = frictionTo(FireTerminalKind.sprinkler);
        final sp = sprinklerPoint(
            sprinklerFriction, liftTo(FireTerminalKind.sprinkler));
        sprinklerPointHead = sp.head.meters;
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
          // Reference apartment A1 (supersedes the Round-37 'larger head at
          // its own flow') — one pump serving both systems is rated at the
          // LARGER flow (the standpipe's) and the LARGER head (the
          // sprinkler's): a centrifugal pump rated on the small remote-area
          // flow delivers at most 150 % of it, never the hose flow. At the
          // smaller sprinkler flow the curve gives at least the rated head,
          // so both points are covered (conservative by the head gap).
          // `sprinklerGovernsCombined` now means: the sprinkler sets the
          // HEAD, the standpipe the FLOW.
          flow = st.requiredFlow;
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
    // Round 61 (fire-convergence-13-yard-hydrants-rated-as-building-
    // standpipe) — drawn YARD (pillar) hydrants are rated on their own
    // basis: [kYardHydrantFlowLps] at [kYardHydrantResidualKpa] at the
    // hydrant, + the larger of the sized friction to them and the 15 m
    // allowance. A yard-only system is rated on it alone; beside a building
    // standpipe / sprinklers the pump covers max(flow) at max(head).
    final yardIds = sys.yardHydrantIds(net);
    if (yardIds.isNotEmpty && building.floors.isNotEmpty) {
      final nF = building.floors.length;
      final datum = building
          .elevationOf(sys.datumFloor(net).clamp(0, nF - 1))
          .meters;
      var lift = 0.0;
      for (final id in yardIds) {
        final z =
            nodeElevation(net.nodeById(id)!, building, project.mounting).meters;
        lift = math.max(lift, z - datum);
      }
      final yf = duty == null
          ? null
          : fireIndexPathFrictionM(
              net: net,
              system: sys,
              pumpId: duty,
              sizing: sizing,
              lengthOf: lengthOf,
              targetIds: yardIds.toSet(),
            );
      const yardFlow = FlowRate(kYardHydrantFlowLps / 1000);
      final yardHead = Head(lift +
          kYardHydrantResidualKpa * 1000 / (1000 * 9.81) +
          math.max(15.0, yf ?? 0.0)); // the designStandpipe allowance
      final hasHose = sys.topTerminalFloor(net, FireTerminalKind.hydrant) !=
          null;
      if (!hasHose && !sys.hasSprinklerHead(net)) {
        flow = yardFlow;
        head = yardHead;
        friction = yf;
        standpipe = null;
        staticLift = lift;
      } else {
        if (yardFlow.cubicMetersPerSecond > flow.cubicMetersPerSecond) {
          flow = yardFlow;
        }
        if (yardHead.meters > head.meters + 1e-9) {
          head = yardHead;
          friction = yf;
          staticLift = lift;
        }
      }
    }
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
          destinationTankOf: destinationOf);
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
    // Round 70 (fire-convergence-22-intermediate-zone-room-filling-next-
    // break-tank-rated-on-own-zone-only) — a ZONE room that also fills the
    // next break tank ([fireFillDestinationTank]) must deliver that tank's
    // whole fed flow when the zone above is on fire: rated on the larger
    // flow at the larger head (its own zone point, or the lift to the tank
    // plus the sized friction to it) — the combined-room max-flow-at-max-head
    // convention.
    final fillTank = pumps.isNotEmpty && hasTerminal && duty != null
        ? fillTankOf(sys)
        : null;
    if (fillTank != null) {
      final fed = fireTransferFedFlow(net, sys, fillTank.id, systems,
          sprinklerDemand: remote.remoteAreaDemand,
          destinationTankOf: destinationOf);
      if (fed != null && fed.cubicMetersPerSecond > flow.cubicMetersPerSecond) {
        flow = fed;
      }
      final pumpZ = nodeElevation(net.nodeById(duty!)!, building,
              project.mounting)
          .meters;
      final tankZ = nodeElevation(fillTank, building, project.mounting).meters;
      final f = fireIndexPathFrictionM(
        net: net,
        system: sys,
        pumpId: duty,
        sizing: sizing,
        lengthOf: lengthOf,
        targetIds: {fillTank.id},
      );
      final fillHead = math.max(0.0, tankZ - pumpZ) + math.max(0.0, f ?? 0.0);
      if (fillHead > head.meters + 1e-9) head = Head(fillHead);
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
    // Round 61 — a DRY (brigade-fed) system: no pump, no tank, only fire
    // department inlets. Rated at the inlet (what the brigade must supply),
    // never a phantom pump.
    final inlets = [
      for (final n in net.nodes)
        if (sys.nodeIds.contains(n.id) && isSupplyInletComponent(n.component))
          n,
    ]..sort(drawOrderCompare);
    final otherPlant = net.nodes.any((n) =>
        sys.nodeIds.contains(n.id) &&
        n.role == NodeRole.plant &&
        !isSupplyInletComponent(n.component));
    // Round 79 (fire-convergence-30-meter-fed-fire-system-phantom-pump-or-
    // false-dry) — a degree-1 WATER METER on the fire pipework is a MAINS
    // entry: the system is wet from the mains whether or not an FDC is also
    // drawn, so it is never 'dry' (brigade-fed). It keeps the meter-fed
    // reading (the Round-50 assumed fire pump at the meter, named by the
    // `fire-pump-assumed:<service>` info) — the verdict and the MDP way can
    // never depend on whether an FDC is drawn.
    final mainsEntry = sys.nodeIds.any((id) {
      if (net.nodeById(id)?.component != NodeComponent.waterMeter) {
        return false;
      }
      var deg = 0;
      for (final e in sys.edges) {
        if (e.fromId == id || e.toId == id) deg++;
      }
      return deg == 1;
    });
    final dry = pumps.isEmpty &&
        gravity == null &&
        hasTerminal &&
        inlets.isNotEmpty &&
        !otherPlant &&
        !mainsEntry;
    double? dryHeadM;
    if (dry) {
      final inlet = inlets.first;
      final f = fireIndexPathFrictionM(
        net: net,
        system: sys,
        pumpId: inlet.id,
        sizing: sizing,
        lengthOf: lengthOf,
        terminals: basisKind,
      );
      final lift = sys.staticLiftM(net, building, basisKind,
          datumFloorOverride: inlet.floorIndex);
      dryHeadM = basisKind == FireTerminalKind.sprinkler
          ? sprinklerPoint(f, lift).head.meters
          : standpipeAt(f, lift).pumpHead.meters;
    }
    final dutyPump = gravity != null || dry || flow.cubicMetersPerSecond <= 0
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
        dutyPumpId: dutyOf(sys, ids) ?? ([...ids]..sort(byDraw)).first,
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
      // Round 80 — a roof gravity-standby tank (no mover draws from it) is
      // never a stage source.
      final topo = fireSeriesPumpStages(net, sys, sets,
          dischargeOnlySourceIds: dischargeOnlyTanks());
      // Round 60 (fire-convergence-12-series-lower-stage-rated-with-whole-
      // system-friction) — a LOWER stage's zone is priced on ITS OWN index
      // path: the sized friction from the root stage's duty pump to the
      // zone's own terminals of the basis kind (the larger of that and the
      // 15 m allowance, inside the standpipe / sprinkler point), never the
      // whole system's friction to the TOP terminal (a 35-storey series
      // tower rated its lower stage 9.7 m high and the upper stage 9.7 m
      // short). Unmeasured (null) ⇒ the allowance, as for the system.
      double? zoneFrictionOf(bool Function(String id) inZone, String? from) {
        if (friction == null || from == null) return friction;
        final byTerminal = <String, double>{};
        final f = fireIndexPathFrictionM(
          net: net,
          system: sys,
          pumpId: from,
          sizing: sizing,
          lengthOf: lengthOf,
          terminals: basisKind,
          frictionByTerminalOut: byTerminal,
        );
        if (f == null) return friction;
        double? worst;
        for (final MapEntry(key: id, value: v) in byTerminal.entries) {
          if (!inZone(id)) continue;
          if (worst == null || v > worst) worst = v;
        }
        return worst ?? friction;
      }

      if (topo != null && topo.length >= 2) {
        int floorOfStage(FirePumpStage st) => st.pumpIds
            .map((id) => net.nodeById(id)?.floorIndex ?? 0)
            .reduce((a, b) => a < b ? a : b);
        final rootStage = topo.firstWhere((st) => st.upstream == null,
            orElse: () => topo.first);
        final rootPump = dutyOf(sys, rootStage.pumpIds);
        // The head the terminals of [zone] need from the system datum, or
        // null when the zone holds no terminal of the basis kind.
        double? zoneNeed(FireSystem zone) {
          if (zone.topTerminalFloor(net, basisKind) == null) return null;
          final lift = zone.staticLiftM(net, building, basisKind,
              datumFloorOverride: datum);
          final zf = zoneFrictionOf(zone.nodeIds.contains, rootPump);
          return basisKind == FireTerminalKind.sprinkler
              ? sprinklerPoint(zf, lift).head.meters
              : standpipeAt(zf, lift).pumpHead.meters;
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
      // Round 79 (regression-roof-booster-peer-rated-with-datum-lift) — a
      // ROOT stage merged from peer pump rooms (Round 78: rooms drawing from
      // DIFFERENT tanks into one network) rates each pump above its OWN
      // suction source: a booster drawing from a roof tank develops the
      // stage head less the rise of that tank above the system datum (it
      // never lifts water it already has), clamped at
      // [kMinFireStageHeadM]. A pump drawing from a tank at / below the
      // datum keeps the full stage head; a standby on the same leg ends
      // shares the suction part, so it takes the same figure. A root stage
      // fed from ONE suction part (a single pump room) is untouched.
      if (topo != null) {
        final datumZ = building.elevationOf(datum).meters;
        for (final st in topo) {
          if (st.upstream != null) continue;
          final keys = {
            for (final id in st.pumpIds)
              (st.suctionSourceIds[id] ?? const <String>[]).join(','),
          };
          if (keys.length < 2) continue;
          for (final id in st.pumpIds) {
            final srcs = [
              for (final sid in st.suctionSourceIds[id] ?? const <String>[])
                if (net.nodeById(sid) != null) net.nodeById(sid)!,
            ];
            if (srcs.isEmpty) continue;
            final srcZ = srcs
                .map((n) => nodeElevation(n, building, project.mounting).meters)
                .reduce(math.min);
            final rise = srcZ - datumZ;
            if (rise <= 1e-9) continue;
            final base = stageHeads[id]?.meters ?? head.meters;
            final perPump = Head(math.max(kMinFireStageHeadM, base - rise));
            final r = checkFirePumpRating(ratedFlow: flow, ratedHead: perPump);
            stageHeads[id] = perPump;
            stageDuties[id] =
                firePumpDuty(ratedFlow: flow, ratedHead: perPump, rating: r);
          }
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
              // Round 60 — the zone's own friction (terminals below the
              // next stage's floor), from the first stage's duty pump.
              final zf = zoneFrictionOf(
                  (id) => (net.nodeById(id)?.floorIndex ?? 0) < nextFloor,
                  dutyOf(sys, [for (final g in stages.first) ...g]));
              need = basisKind == FireTerminalKind.sprinkler
                  ? sprinklerPoint(zf, lift).head.meters
                  : standpipeAt(zf, lift).pumpHead.meters;
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
      dry: dry,
      dryInletId: dry ? inlets.first.id : null,
      dryRequiredInletHeadM: dryHeadM,
      sprinklerPointHeadM: sprinklerPointHead,
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
    if (sys.hasSprinklerHead(net)) FireTerminalKind.sprinkler,
    if (sys.standpipeTermApplies(net)) FireTerminalKind.hydrant,
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
  return bases.isNotEmpty && bases.every((b) => b.standsDown);
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
///  * head:  the system's SPRINKLER POINT ([FireSystemBasis.
///           sprinklerPointHeadM], `sprinklerPumpRatedPoint`: static lift +
///           the remote-head pressure + the sized sprinkler index friction, the
///           15 m allowance basis as its floor) vs the pump head — the SAME head
///           the rating basis reads. Backlog A-1 (2026-11-13, office O3)
///           superseded the audit-round-8 LOWER BOUND (lift + branch-base, no
///           friction): one requirement, one head.
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
/// Round 65 (regression-3) — a SPRINKLER SYSTEM is drawn only when a drawn
/// fire system carries a sprinkler HEAD (`FireSystem.hasSprinklerHead`, the
/// Round-64 basis rule) — never merely a pipe labelled sprinkler (a pump
/// room's suction drawn on the sprinkler service feeds a hydrant riser).
/// The ONE gate for the calc report's sprinkler design / remote-area check,
/// the Fire inspector's sprinkler rows and the sprinkler-vs-pump judge.
final sprinklerHeadDrawnProvider = Provider<bool>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  if (!net.edges.any((e) => e.service == ServiceType.fireSprinkler)) {
    return false;
  }
  return fireRatingSystems(net).any((s) => s.hasSprinklerHead(net));
});

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
  if (!ref.watch(sprinklerHeadDrawnProvider)) return null;
  final remote = ref.watch(sprinklerRemoteAreaProvider);
  final demand = remote.remoteAreaDemand.inLitersPerSecond;
  // The pump serving each sprinkler-bearing system, judged against THAT
  // system's own lift (Round 49 — pump datum floor -> its highest head's
  // ceiling, never the whole building).
  final pumps = <(PumpDuty, double)>[];
  for (final b in ref.watch(fireSystemBasesProvider)) {
    if (!b.system.hasSprinklerHead(net)) continue;
    // Round 50 — a gravity system is judged on its tank head
    // ([FireSystemBasis.gravityHeadShort]), never against another system's
    // pump or a phantom duty.
    if (b.gravityFed) continue;
    // Round 61 — a dry (brigade-fed) system has no pump to judge.
    if (b.dry) continue;
    // Round 52 — a transfer system fills a tank; it serves no head.
    if (b.transfer) continue;
    // Round 66 r2 — the ONE standpipe predicate: a pump-less system whose
    // pipes are hydrant-LABELLED but carry no hose outlet is a sprinkler-
    // only system, judged against the project fire pump (Round 29).
    final own = b.pumpIds.isNotEmpty || b.system.standpipeTermApplies(net);
    final pump = own ? b.duty : ref.watch(firePumpDutyProvider);
    // Backlog A-1 — the requirement is the system's own sprinkler point
    // (the rating basis' figure), never a parallel re-derivation.
    final required = b.sprinklerPointHeadM;
    if (pump != null && required != null) pumps.add((pump, required));
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

/// Backlog A-2 (2026-11-13, reference office backlog b) — the fire-water
/// reserve of one FIRE TANK: a ground tank on a fire service
/// ([NodeComponent.groundTank] incident to a sprinkler / hydrant pipe) that
/// belongs to a drawn, wet fire system. [reserve] is the system's rated demand
/// flow x the required duration ([fireWaterReserve]); [capacityLitres] the
/// tank node's OWN entered capacity (null when unset — never fabricated).
class FireTankReserve {
  final String tankId;
  final String sheetId;
  final FireSystemBasis basis;
  final FireWaterReserve reserve;
  final double? capacityLitres;
  final FireTankVerdict verdict;
  const FireTankReserve({
    required this.tankId,
    required this.sheetId,
    required this.basis,
    required this.reserve,
    required this.capacityLitres,
    required this.verdict,
  });

  double get requiredLitres => reserve.volumeLitres;
}

/// Backlog A-2 — every fire tank and its required reserve (JUDGE-ONLY: the
/// Review raises `fire-tank-undersized` / `fire-tank-capacity-unset`, the Fire
/// inspector and the calc report print the requirement; nothing is resized).
/// A tank on several systems takes the largest requirement. A dry (brigade-
/// fed) or transfer-only system holds no reserve of its own. Sorted by id.
final fireTankReservesProvider = Provider<List<FireTankReserve>>((ref) {
  final bases = ref.watch(fireSystemBasesProvider);
  if (bases.isEmpty) return const [];
  final net = ref.watch(sizingNetworkProvider);
  final hazard = ref.watch(fireHazardProvider);
  final best = <String, FireTankReserve>{};
  for (final b in bases) {
    if (b.dry || b.transfer || b.flow.cubicMetersPerSecond <= 0) continue;
    final r = fireWaterReserve(
      ratedFlow: b.flow,
      standpipe: b.system.hasHoseOutlet(net),
      sprinkler: b.system.hasSprinklerHead(net),
      hazard: hazard,
    );
    if (r == null) continue;
    for (final id in b.system.nodeIds) {
      final n = net.nodeById(id);
      if (n == null || n.component != NodeComponent.groundTank) continue;
      final onFire = net.edgesAt(id).any((e) =>
          e.service == ServiceType.fireSprinkler ||
          e.service == ServiceType.fireHydrant);
      if (!onFire) continue;
      final prev = best[id];
      if (prev != null && prev.requiredLitres >= r.volumeLitres - 1e-9) {
        continue;
      }
      best[id] = FireTankReserve(
        tankId: id,
        sheetId: n.sheetId,
        basis: b,
        reserve: r,
        capacityLitres: n.tankCapacityLitres,
        verdict: judgeFireTank(
            capacityLitres: n.tankCapacityLitres,
            requiredLitres: r.volumeLitres),
      );
    }
  }
  final ids = best.keys.toList()..sort(naturalIdCompare);
  return [for (final id in ids) best[id]!];
});

/// Backlog A-3 — the pressure-class label of every fire pipe downstream of a
/// pump whose system working pressure is above the standard 175 psi class
/// ([firePumpDownstreamEdgeIds]; a pipe on several systems takes the higher
/// class). A standard-class system adds nothing (its BOM is byte-identical).
final firePipePressureClassByEdgeProvider =
    Provider<Map<String, String>>((ref) {
  final lines = ref.watch(firePressureClassesProvider);
  if (lines.isEmpty) return const {};
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  final cls = <String, FirePressureClass>{};
  for (final l in lines) {
    if (l.pressureClass == FirePressureClass.standard) continue;
    for (final id in firePumpDownstreamEdgeIds(
        net: net, system: l.basis.system, sizing: sizing)) {
      final cur = cls[id];
      if (cur == null || cur.index < l.pressureClass.index) {
        cls[id] = l.pressureClass;
      }
    }
  }
  return {
    for (final MapEntry(:key, :value) in cls.entries)
      key: firePressureClassLabel(value),
  };
});

/// Backlog A-3 — the take-off VARIANT of every hose valve designated
/// pressure-regulating ([prvHoseValvesProvider]): its inlet static at churn
/// and its set residual.
final prvHoseValveVariantsProvider = Provider<Map<String, String>>((ref) => {
      for (final MapEntry(:key, :value)
          in ref.watch(prvHoseValvesProvider).entries)
        key: 'pressure-regulating, inlet ${value.staticKpa.toStringAsFixed(0)} '
            'kPa static, set ${kStandpipePrvSetResidualKpa.toStringAsFixed(0)} '
            'kPa residual',
    });
