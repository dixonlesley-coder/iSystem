import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_sprinkler_hydraulic.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/geometry/building.dart' show BuildingLevels;
import 'package:mechx_engine/network/network.dart' show ServiceType;
import 'package:mechx_engine/units.dart' show FlowRate, Head;

import 'network_store.dart';
import 'project_store.dart';

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

/// Static lift (m) from the fire-pump datum (floor 0) to the top-floor
/// ceiling — the sprinkler lower-bound lift [sprinklerPumpCheckProvider] and
/// the sprinkler-only rated point share.
double _sprinklerStaticLiftM(BuildingLevels building) {
  final top = building.floors.length - 1;
  return top < 0
      ? 0.0
      : building.ceilingElevationOf(top).meters -
          building.elevationOf(0).meters;
}

/// Round 17 (report-recompute-2-fire-sections-not-gated-per-system) — the
/// fire pump's RATED POINT on the governing DRAWN system: the standpipe
/// (flow + head from the building height) whenever a hydrant / standpipe is
/// drawn (or nothing is — the advisory inspector basis); for a SPRINKLER-ONLY
/// network the sprinkler remote-area demand at lift + branch pressure +
/// friction allowance (`sprinklerPumpRatedPoint`), never the 31.5 L/s
/// standpipe rating of a system that is not drawn.
final fireRatedPointProvider =
    Provider<({FlowRate flow, Head head, bool sprinklerOnly})>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final hasHydrant =
      net.edges.any((e) => e.service == ServiceType.fireHydrant);
  final hasSprinkler =
      net.edges.any((e) => e.service == ServiceType.fireSprinkler);
  if (hasSprinkler && !hasHydrant) {
    final p = sprinklerPumpRatedPoint(
      remote: ref.watch(sprinklerRemoteAreaProvider),
      staticLiftM: _sprinklerStaticLiftM(
          ref.watch(projectControllerProvider).building),
    );
    return (flow: p.flow, head: p.head, sprinklerOnly: true);
  }
  final st = ref.watch(standpipeDesignProvider);
  return (flow: st.requiredFlow, head: st.pumpHead, sprinklerOnly: false);
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
  final net = ref.watch(networkControllerProvider).network;
  if (!net.edges.any((e) =>
      e.service == ServiceType.fireSprinkler ||
      e.service == ServiceType.fireHydrant)) {
    return null;
  }
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
/// The one scheduled + electrically fed fire pump ([firePumpDutyProvider]) is
/// rated on the STANDPIPE flow and head; nothing compared it with the sprinkler
/// design-area demand, so at Extra Hazard (≈ 43 L/s) the only pump (≈ 31.5 L/s)
/// could not deliver the sprinklers it was scheduled for. Reported only when a
/// sprinkler system is actually DRAWN (fireSprinkler edges):
///  * flow:  remote-area demand (`sprinklerRemoteAreaProvider`) vs the pump's
///           rated flow;
///  * head:  a LOWER-BOUND sprinkler requirement — static lift from the pump
///           datum (floor 0) to the top-floor ceiling + the branch-base pressure
///           as head (P/ρg) — vs the pump head. Riser / main friction is NOT
///           added, so a flagged shortfall is certain, never speculative.
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
  final net = ref.watch(networkControllerProvider).network;
  if (!net.edges.any((e) => e.service == ServiceType.fireSprinkler)) {
    return null;
  }
  final pump = ref.watch(firePumpDutyProvider);
  if (pump == null) return null;
  final remote = ref.watch(sprinklerRemoteAreaProvider);
  final lift =
      _sprinklerStaticLiftM(ref.watch(projectControllerProvider).building);
  const rhoG = 1000 * 9.81;
  final required = lift + remote.branchBasePressure.pascals / rhoG;
  final demand = remote.remoteAreaDemand.inLitersPerSecond;
  final pumpLps = pump.flow.inLitersPerSecond;
  return (
    demandLps: demand,
    pumpLps: pumpLps,
    requiredHeadM: required,
    pumpHeadM: pump.head.meters,
    flowShort: demand > pumpLps + 1e-9,
    headShort: required > pump.head.meters + 1e-9,
  );
});
