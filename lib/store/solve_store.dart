import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/hydraulics.dart'
    show headFromPressure, headLossHazenWilliams, pressureFromHead;
import 'package:mechx_engine/network/duct_static.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/network/zoning.dart';
import 'package:mechx_engine/pressure_field.dart';
import 'package:mechx_engine/sizing/air_velocity.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart'
    show kSelfCleansingVelocityMps;
import 'package:mechx_engine/sizing/fan.dart';
import 'package:mechx_engine/sizing/hot_water.dart';
import 'package:mechx_engine/sizing/consumables.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/pipe_optimizer.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/sizing/room_air.dart'
    show AirEquipmentKind, defaultInternalStatic;
import 'package:mechx_engine/sizing/supply_design.dart';
import 'package:mechx_engine/standards/pipe_products.dart' show hazenWilliamsCFor;
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

import 'app_state.dart';
import 'network_store.dart';
import 'project_store.dart';
import 'sizing_store.dart';

Pressure get _targetResidual =>
    SupplyDesignCriteria.recommended().targetFixtureResidualPressure;

/// Round 17 — the setpoint a downfeed PRV holds: the target residual plus a
/// floor-branch friction allowance (`defaultPrvSetpoint`), ONE figure for the
/// drawn-PRV solve, the zone sizing and the zone static table.
Pressure get _prvSetpoint => defaultPrvSetpoint(
      targetResidual: _targetResidual,
      maxFixtureStatic: const SniProfile().maxFixtureStaticPressure.value,
    );

/// The absolute pass threshold the pressure solve holds at the critical fixture
/// (the design target residual, ≈2.25 bar). Exposed so the heatmap legend's
/// threshold anchor and the per-node inspector probe (I2) read the SAME value
/// the solve used, instead of the heatmap's relative min/max alone.
final targetResidualProvider = Provider<Pressure>((ref) => _targetResidual);

List<NetEdge> _supplyEdges(Network net) =>
    net.edges.where((e) => e.service == kSupplyService).toList();

Map<String, FlowRate> _supplyFlows(
    List<NetEdge> edges, Map<String, EdgeSizing> sizing) {
  return {
    for (final e in edges)
      if (sizing[e.id] != null) e.id: sizing[e.id]!.flow,
  };
}

/// UPFEED node-pressure solve (pump pushing up from a low plant). Null when the
/// strategy is downfeed or there is no supply network.
final solveProvider = Provider<PressureSolution?>((ref) {
  if (ref.watch(feedStrategyProvider) != FeedStrategy.upfeed) return null;
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  final project = ref.watch(projectControllerProvider);
  final edges = _supplyEdges(net);
  if (edges.isEmpty) return null;
  final source = _pickSource(net, edges, project.building,
      preferHighest: false, mounting: project.mounting);
  if (source == null) return null;

  return solvePressurized(
    net: net,
    service: kSupplyService,
    sourceId: source,
    edgeFlows: _supplyFlows(edges, sizing),
    sizing: sizing,
    calibrationBySheet: project.calibrations,
    building: project.building,
    targetResidual: _targetResidual,
    // water-drainage-8 — static lift + riser friction on the project's
    // mounting heights, the same basis the drawings and report print.
    mounting: project.mounting,
  );
});

/// mech-building-2 — upfeed DELIVERY nodes over the SNI fixture pressure
/// limits (judge-only; see the engine's [upfeedOverPressure]). Empty on a
/// downfeed (its PRV zones are the check there) or with no upfeed solve.
final upfeedOverPressureProvider = Provider<List<UpfeedOverPressure>>((ref) {
  final solution = ref.watch(solveProvider);
  if (solution == null) return const [];
  return upfeedOverPressure(solution);
});

/// Round 16 (plumbing-plant-downfeed-prv-unmodelled) — DOWNFEED delivery
/// nodes over the SNI fixture pressure limits, on the gravity solve in which
/// every DRAWN PRV holds its setpoint (the engine's [downfeedOverPressure]).
/// The PRV zone table is a design intent (it assumes a PRV at every zone top);
/// this is the check of what is actually drawn. Empty on upfeed.
final downfeedOverPressureProvider =
    Provider<List<UpfeedOverPressure>>((ref) {
  final solution = ref.watch(downfeedProvider);
  if (solution == null) return const [];
  return downfeedOverPressure(solution);
});

/// DOWNFEED gravity solve (roof tank distributing down). Null when the strategy
/// is upfeed or there is no supply network.
final downfeedProvider = Provider<DownfeedSolution?>((ref) {
  if (ref.watch(feedStrategyProvider) != FeedStrategy.downfeed) return null;
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  final project = ref.watch(projectControllerProvider);
  final edges = _supplyEdges(net);
  if (edges.isEmpty) return null;
  final tank = _pickSource(net, edges, project.building,
      preferHighest: true, mounting: project.mounting);
  if (tank == null) return null;

  return solveDownfeed(
    net: net,
    service: kSupplyService,
    tankId: tank,
    edgeFlows: _supplyFlows(edges, sizing),
    sizing: sizing,
    calibrationBySheet: project.calibrations,
    building: project.building,
    targetResidual: _targetResidual,
    // water-drainage-8 — static lift + riser friction on the project's
    // mounting heights, the same basis the drawings and report print.
    mounting: project.mounting,
    // Round 17 — a drawn PRV holds target + the floor-branch friction margin.
    prvSetpoint: _prvSetpoint,
  );
});

/// Residual pressure at every solved node, regardless of feed strategy — the
/// single field the heatmap renders (§12).
final residualByNodeProvider = Provider<Map<String, Pressure>>((ref) {
  final up = ref.watch(solveProvider);
  if (up != null) return up.residualPressure;
  final down = ref.watch(downfeedProvider);
  if (down != null) return down.residualPressure;
  return const {};
});

/// Per-edge WATER / DRAINAGE velocity checks keyed by edge id — the non-air
/// (pressurized / gravity) analogue of [airVelocityChecksProvider] (I3). Pipe
/// velocity is a code-driven sizing input (SNI 03-7065-2005 caps supply velocity
/// at 2,0 m/s) that was previously invisible for water/drainage runs, showing
/// only for air ducts. Reuses the SAME [VelocityCheck] verdict idiom, judged
/// against the SNI max pipe velocity from [SniProfile] (supply 2,0 m/s / drain
/// 3,0 m/s).
///
/// The band MINIMUM differs by regime (M5):
///  • PRESSURIZED (cold/hot water) — 0: the max is the compliance gate and no
///    lower bound is an SNI clause, so only an over-velocity pipe warns and no
///    NEW band is invented.
///  • GRAVITY SANITARY DRAINAGE — [kSelfCleansingVelocityMps] (0.6 m/s), the
///    engine's own self-cleansing floor. The drain band's 3,0 m/s ceiling is
///    mathematically unreachable on the DFU path (the table maxes near
///    1.1 m/s), so with a zero floor EVERY drainage branch read "OK" — a
///    DN40/DN50 branch at 1:100 runs at 0.46–0.54 m/s and silts up. The floor
///    is the SAME constant the sizer stamps [EdgeSizing.selfCleansingOk] from,
///    so the inspector verdict and the engine flag can never disagree.
///  • RAINWATER — 0. A vertical downpipe running ≈ 1/3 full is not a
///    self-cleansing gravity run; the engine deliberately declines to form that
///    verdict (`selfCleansingOk` stays true for a downpipe), so judging it
///    against 0.6 m/s here would fabricate a verdict the engine refused to make.
///    A horizontal COLLECTOR does carry the engine's Manning verdict, surfaced
///    via `selfCleansingDefectsProvider` (not duplicated here).
///
/// Only edges with a positive solved velocity are included, so a vent (no flow
/// velocity) is omitted. Read-only — it never resizes anything.
final waterVelocityChecksProvider = Provider<Map<String, VelocityCheck>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  const profile = SniProfile();
  final out = <String, VelocityCheck>{};
  for (final e in net.edges) {
    if (e.service.isAir) continue;
    final s = sizing[e.id];
    if (s == null || s.velocity.metersPerSecond <= 0) continue;
    final gravity = e.service.regime == FlowRegime.gravity;
    // Round 17 follow-up (gravity-3-5) — a vertical gravity STACK / downpipe is
    // not a sloped run: its "velocity" is the horizontal full-bore Manning
    // value at the laid slope, physically meaningless for a riser, so no
    // verdict is formed (the engine forms none either).
    if (gravity && e.kind == EdgeKind.riser) continue;
    // Round 21 review — a FIRE pipe (sprinkler / hydrant) is judged against
    // the SAME fire velocity cap the sizer used ([SizingContext.maxFireVelocity],
    // [kMaxFireVelocityMps]); the domestic 2.0 m/s supply cap would flag every
    // auto-sized fire pipe between 2 and 6 m/s as "too high".
    final max = gravity
        ? profile.maxDrainVelocity.value
        : fireMinimumDiameter(e) != null
            ? const SizingContext().maxFireVelocity
            : profile.maxSupplyVelocity.value;
    // The drainage floor REPEATS the engine verdict instead of re-deriving it:
    // at the code-minimum size no smaller pipe is allowed (G1), so a run the
    // engine judged self-cleansing-OK is never shown LOW here.
    final min = e.service == ServiceType.drainage && !s.selfCleansingOk
        ? const Velocity(kSelfCleansingVelocityMps)
        : const Velocity(0);
    out[e.id] = checkVelocityBand(s.velocity, min: min, max: max);
  }
  return out;
});

/// Pick the supply source/tank. The source is the pump/tank entry, NOT an
/// arbitrary fixture: the wrong leaf would invert the tree and mis-assign static
/// lift.
///
/// UPFEED (Round 15, root-metamorphic-picksource-*) — the solve sources at the
/// SAME node the sizer accumulated from ([serviceComponentRoots] of the largest
/// supply component) when that root is a plant; else the best-ranked plant
/// ([supplyPlantRank], then lowest, then id — a ground tank beats a same-floor
/// pump whatever order the pipes were drawn in, so the suction-leg friction is
/// always in the pump head); with NO plant at all, the sizer's demand-free
/// entry (never a ground-floor fixture, which used to win on elevation alone
/// and route the solve through its own branch).
///
/// DOWNFEED — the highest plant (the roof tank), ties by id; else the highest
/// node, ties to a leaf, then id.
String? _pickSource(
  Network net,
  List<NetEdge> edges,
  BuildingLevels building, {
  required bool preferHighest,
  MountingHeights mounting = const MountingHeights(),
}) {
  final ids = <String>{
    for (final e in edges) ...[e.fromId, e.toId],
  };
  if (ids.isEmpty) return null;

  final degree = <String, int>{};
  for (final e in edges) {
    degree[e.fromId] = (degree[e.fromId] ?? 0) + 1;
    degree[e.toId] = (degree[e.toId] ?? 0) + 1;
  }

  final candidates = ids.map((id) => net.nodeById(id)).whereType<NetNode>();
  double elev(NetNode n) => nodeElevation(n, building, mounting).meters;
  final plants = candidates.where((n) => n.role == NodeRole.plant).toList();

  if (!preferHighest) {
    final roots = serviceComponentRoots(net, kSupplyService, demandNodeIds: {
      for (final n in net.nodes)
        if (n.role == NodeRole.fixture) n.id,
    });
    final edgeCount = <String, int>{};
    for (final e in edges) {
      final r = roots[e.fromId];
      if (r != null) edgeCount[r] = (edgeCount[r] ?? 0) + 1;
    }
    String? sizerRoot;
    for (final entry in edgeCount.entries) {
      if (sizerRoot == null ||
          entry.value > edgeCount[sizerRoot]! ||
          (entry.value == edgeCount[sizerRoot]! &&
              entry.key.compareTo(sizerRoot) < 0)) {
        sizerRoot = entry.key;
      }
    }
    if (sizerRoot != null &&
        net.nodeById(sizerRoot)?.role == NodeRole.plant) {
      return sizerRoot;
    }
    if (plants.isNotEmpty) {
      plants.sort((a, b) {
        var c = supplyPlantRank(a.component, degree[a.id] ?? 0)
            .compareTo(supplyPlantRank(b.component, degree[b.id] ?? 0));
        if (c != 0) return c;
        c = elev(a).compareTo(elev(b));
        return c != 0 ? c : a.id.compareTo(b.id);
      });
      return plants.first.id;
    }
    return sizerRoot;
  }

  // DOWNFEED 1. An explicit plant node wins (the highest, ties by id).
  if (plants.isNotEmpty) {
    plants.sort((a, b) {
      final c = elev(b).compareTo(elev(a));
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    return plants.first.id;
  }

  // 2. Highest node; tie-break to a leaf, then deterministic order.
  NetNode? best;
  for (final n in candidates) {
    if (best == null) {
      best = n;
      continue;
    }
    final ne = elev(n);
    final be = elev(best);
    if (ne > be ||
        (ne == be && (degree[n.id] ?? 0) < (degree[best.id] ?? 0)) ||
        (ne == be &&
            (degree[n.id] ?? 0) == (degree[best.id] ?? 0) &&
            n.id.compareTo(best.id) < 0)) {
      best = n;
    }
  }
  return best?.id;
}

/// Round 15 (root-metamorphic-hybrid-booster-duty) — the supply pump /
/// booster set drawn INLINE (degree >= 2, not its component's root) that a
/// pump duty must be sized on, with the flow THROUGH it: the sized flow of
/// its incoming pipe (the incident supply edge whose flow does not leave the
/// booster), mirrored standby legs ([parallelLegEdgeIdsProvider]) excluded.
/// That edge's flow is already the demand curve of every fixture beyond the
/// booster, i.e. its own diversified load. Several boosters ⇒ the one moving
/// the most water (ties by id). Null when no inline booster carries flow.
///
/// Round 15 r2 — a mover whose SERVED set (every node reached beyond its
/// incoming pipe) contains a storage TANK is a TRANSFER pump (the standard
/// Indonesian downfeed: ground tank → transfer pump → roof tank → riser), not
/// a booster: its duty is the lift to the tank, never the fixtures' residual
/// shortfall, so it is excluded here and the trunk-duty path stays in charge
/// (null on downfeed, as before Round 15).
typedef SupplyBooster = ({String nodeId, FlowRate flow, String inEdgeId});

final supplyBoosterProvider = Provider<SupplyBooster?>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  final legs = ref.watch(parallelLegEdgeIdsProvider);
  return inlineSupplyBooster(net, sizing, excludeEdgeIds: legs);
});

/// Every supply node reached from [nodeId] without crossing [inEdgeId] (the
/// mover itself excluded) — what an inline mover SERVES.
///
/// With [sizing], the walk follows the SOLVED flow direction (an edge is
/// crossed only when its `flowFromId` is the node being left) and skips the
/// mirrored standby legs in [excludeEdgeIds]: a booster drawn as a
/// duty/standby PAIR (T → B1 → CV1 → J and T → B2 → CV2 → J) must not reach
/// back to its source tank through the standby leg and be misread as a
/// transfer pump, while a genuine transfer pump still reaches the tank it
/// fills (its discharge pipe flows away from the pump). Without [sizing] the
/// walk is undirected (legacy).
Set<String> boosterServedNodes(
  Network net,
  String nodeId,
  String inEdgeId, {
  Map<String, EdgeSizing>? sizing,
  Set<String> excludeEdgeIds = const {},
}) {
  final adj = <String, List<({String edgeId, String other})>>{};
  for (final e in net.edges) {
    if (e.service != kSupplyService) continue;
    if (excludeEdgeIds.contains(e.id)) continue;
    (adj[e.fromId] ??= []).add((edgeId: e.id, other: e.toId));
    (adj[e.toId] ??= []).add((edgeId: e.id, other: e.fromId));
  }
  final served = <String>{nodeId};
  final stack = [nodeId];
  while (stack.isNotEmpty) {
    final n = stack.removeLast();
    for (final l in adj[n] ?? const <({String edgeId, String other})>[]) {
      if (l.edgeId == inEdgeId) continue;
      if (sizing != null) {
        final from = sizing[l.edgeId]?.flowFromId;
        if (from == null || from != n) continue;
      }
      if (served.add(l.other)) stack.add(l.other);
    }
  }
  served.remove(nodeId);
  return served;
}

bool _isStorageTank(NetNode? n) =>
    n != null &&
    (n.component == NodeComponent.roofTank ||
        n.component == NodeComponent.groundTank);

/// Pure core of [supplyBoosterProvider] (testable without a container).
SupplyBooster? inlineSupplyBooster(
  Network net,
  Map<String, EdgeSizing> sizing, {
  Set<String> excludeEdgeIds = const {},
}) {
  final roots = serviceComponentRoots(net, kSupplyService, demandNodeIds: {
    for (final n in net.nodes)
      if (n.role == NodeRole.fixture) n.id,
  });
  SupplyBooster? best;
  for (final n in net.nodes) {
    if (n.component != NodeComponent.pump &&
        n.component != NodeComponent.boosterSet) {
      continue;
    }
    if (roots[n.id] == null || roots[n.id] == n.id) continue;
    final incident = [
      for (final e in net.edges)
        if (e.service == kSupplyService && (e.fromId == n.id || e.toId == n.id))
          e,
    ];
    if (incident.length < 2) continue;
    for (final e in incident) {
      if (excludeEdgeIds.contains(e.id)) continue;
      final sz = sizing[e.id];
      if (sz == null || sz.flowFromId == null || sz.flowFromId == n.id) {
        continue;
      }
      final q = sz.flow.cubicMetersPerSecond;
      if (q <= 0) continue;
      // Round 15 r2 — a transfer pump (it fills a tank) is not a booster.
      if (boosterServedNodes(net, n.id, e.id,
              sizing: sizing, excludeEdgeIds: excludeEdgeIds)
          .any((id) => _isStorageTank(net.nodeById(id)))) {
        continue;
      }
      if (best == null ||
          q > best.flow.cubicMetersPerSecond + 1e-15 ||
          ((q - best.flow.cubicMetersPerSecond).abs() <= 1e-15 &&
              n.id.compareTo(best.nodeId) < 0)) {
        best = (nodeId: n.id, flow: sz.flow, inEdgeId: e.id);
      }
    }
  }
  return best;
}

/// Round 15 — the head an inline booster must add: the largest shortfall of
/// the residual below the target over the DELIVERY nodes it serves (every
/// node reached from the booster without crossing its incoming pipe;
/// fixtures, else those nodes' leaves), where [residual] is what the network
/// delivers WITHOUT the booster (the gravity solve on downfeed; the upfeed
/// solve shifted to zero source head — see [pumpDutyProvider]). Zero or less
/// ⇒ the supply already serves them.
Head boosterShortfallHead({
  required Network net,
  required SupplyBooster booster,
  required Map<String, Pressure> residual,
  required Pressure target,
  Map<String, EdgeSizing>? sizing,
  Set<String> excludeEdgeIds = const {},
}) {
  final served = boosterServedNodes(net, booster.nodeId, booster.inEdgeId,
      sizing: sizing, excludeEdgeIds: excludeEdgeIds);
  final degree = <String, int>{};
  for (final e in net.edges) {
    if (e.service != kSupplyService) continue;
    degree[e.fromId] = (degree[e.fromId] ?? 0) + 1;
    degree[e.toId] = (degree[e.toId] ?? 0) + 1;
  }
  var delivery = [
    for (final id in served)
      if (net.nodeById(id)?.role == NodeRole.fixture) id,
  ];
  if (delivery.isEmpty) {
    delivery = [
      for (final id in served)
        if ((degree[id] ?? 0) == 1) id,
    ];
  }
  var worstPa = double.negativeInfinity;
  for (final id in delivery) {
    final r = residual[id];
    if (r == null) continue;
    worstPa = math.max(worstPa, target.pascals - r.pascals);
  }
  if (worstPa == double.negativeInfinity) return const Head(0);
  return headFromPressure(Pressure(worstPa));
}

/// Round 15 r2 — the BUILDING peak design flow on an UPFEED supply: the
/// trunk (largest-flow) cold-water flow, or the flow the source delivers when
/// a tee at its discharge splits it. This is what the KETERANGAN system notes
/// print as 'Peak design flow' — never an inline booster's partial flow.
/// Null in downfeed (gravity-fed) or when nothing flows (the notes never
/// fabricate a figure; the same upfeed-only line as before Round 15).
final supplyPeakFlowProvider = Provider<FlowRate?>((ref) {
  final solution = ref.watch(solveProvider);
  if (solution == null) return null;
  final sizing = ref.watch(sizingProvider);
  final net = ref.watch(sizingNetworkProvider);
  var flow = const FlowRate(0);
  NetEdge? trunkEdge;
  for (final e in net.edges) {
    if (e.service != kSupplyService) continue;
    final s = sizing[e.id];
    if (s != null &&
        s.flow.cubicMetersPerSecond > flow.cubicMetersPerSecond) {
      flow = s.flow;
      trunkEdge = e;
    }
  }
  if (flow.cubicMetersPerSecond <= 0 || trunkEdge == null) return null;
  // Round 11 (hvac-network-1) — the pump delivers the flow LEAVING its source
  // node: with a tee at the discharge that is every branch together, not the
  // single largest edge. Re-diversified through the demand curve once (the
  // summed UBAP), never Σ of already-diversified branch flows.
  final roots = serviceComponentRoots(net, kSupplyService, demandNodeIds: {
    for (final n in net.nodes)
      if (n.role == NodeRole.fixture) n.id,
  });
  final root = roots[trunkEdge.fromId];
  if (root != null) {
    final delivered = sourceDeliveredFlow(
      net,
      sizing,
      kSupplyService,
      root,
      edgeFixtureUnits: ref.watch(edgeFixtureUnitsProvider),
      flushSystem: ref.watch(supplyFlushSystemProvider),
      excludeEdgeIds: ref.watch(parallelLegEdgeIdsProvider),
    );
    if (delivered.cubicMetersPerSecond > flow.cubicMetersPerSecond) {
      flow = delivered;
    }
  }
  return flow;
});

/// The duty of the supply PUMP the design actually contains: the trunk pump
/// of an UPFEED supply ([supplyPeakFlowProvider] at the solve's required
/// head), or — Round 15 — an INLINE booster ([supplyBoosterProvider]) on the
/// flow THROUGH it, in BOTH feed strategies. Null in a pure gravity downfeed
/// (incl. a ground-tank → transfer-pump → roof-tank scheme, whose transfer
/// duty is not modelled) or when there's nothing to pump.
///
/// Consumers that need the BUILDING peak flow (the KETERANGAN notes) read
/// [supplyPeakFlowProvider], never this duty's flow — with a booster this is
/// the booster's partial flow. The pump-motor ResultCard, the plant-detail
/// BOOSTER kW, the equipment-schedule P-01 row and the MEP→E feed describe
/// the one pump drawn, which with an inline booster IS the booster.
final pumpDutyProvider = Provider<PumpDuty?>((ref) {
  // Round 16 — the drawn domestic movers are sized in series
  // ([supplyMoverDutiesProvider]); this single duty is the PRIMARY one (the
  // largest-flow non-transfer mover, ties by id) — the root / main pump of a
  // root-pump + zone-booster scheme, not the booster on the system head.
  final movers = ref.watch(supplyMoverDutiesProvider);
  final transfers = ref.watch(transferPumpNodeIdsProvider);
  String? primary;
  for (final e in movers.entries) {
    if (transfers.contains(e.key)) continue;
    final p = primary == null ? null : movers[primary]!;
    if (p == null ||
        e.value.flow.cubicMetersPerSecond > p.flow.cubicMetersPerSecond + 1e-15 ||
        ((e.value.flow.cubicMetersPerSecond - p.flow.cubicMetersPerSecond)
                    .abs() <=
                1e-15 &&
            e.key.compareTo(primary!) < 0)) {
      primary = e.key;
    }
  }
  if (primary != null) return movers[primary];
  final solution = ref.watch(solveProvider);
  final booster = ref.watch(supplyBoosterProvider);
  if (booster != null) {
    // The head the booster must ADD downstream of its inlet: the residual
    // shortfall at the fixtures it serves with NO pump in the system.
    final Map<String, Pressure> unboosted;
    if (solution != null) {
      // Upfeed: the solve sources at the sizer root (a roof tank in the
      // hybrid case) and every residual is linear in the source head
      // (r = p(H) − static − friction), so shifting by −p(requiredPumpHead)
      // gives the residual at zero source head (the open tank's outlet). The
      // whole system's required head at the root would over-state the
      // booster whenever a lower, non-boosted floor is the critical node.
      final pH = pressureFromHead(solution.requiredPumpHead).pascals;
      unboosted = {
        for (final e in solution.residualPressure.entries)
          e.key: Pressure(e.value.pascals - pH),
      };
    } else {
      final down = ref.watch(downfeedProvider);
      if (down == null) return null;
      unboosted = down.residualPressure;
    }
    final head = boosterShortfallHead(
      net: ref.watch(sizingNetworkProvider),
      booster: booster,
      residual: unboosted,
      target: _targetResidual,
      sizing: ref.watch(sizingProvider),
      excludeEdgeIds: ref.watch(parallelLegEdgeIdsProvider),
    );
    if (head.meters <= 0) return null;
    return sizePump(flow: booster.flow, head: head);
  }
  if (solution == null) return null;
  final flow = ref.watch(supplyPeakFlowProvider);
  if (flow == null) return null;
  return sizePump(flow: flow, head: solution.requiredPumpHead);
});

/// Round 16 — one drawn supply MOVER (a pump / booster set on the cold-water
/// service, not piped to a fire service): the flow THROUGH it, the nodes it
/// SERVES (everything reached beyond its incoming pipe along the solved flow;
/// for a ROOT mover, its whole component) and whether it fills a storage tank
/// (a TRANSFER pump).
typedef SupplyMover = ({
  String nodeId,
  String? inEdgeId,
  FlowRate flow,
  Set<String> served,
  bool transfer,
});

/// Pure core of [supplyMoverDutiesProvider]: every supply mover, in a
/// deterministic order (by id). A ROOT mover's flow is [rootFlowOf] (the flow
/// its component's source delivers); an inline mover's is its incoming pipe's
/// sized flow (mirrored standby legs in [excludeEdgeIds] skipped). A mover
/// with no flow is omitted.
List<SupplyMover> supplyMovers(
  Network net,
  Map<String, EdgeSizing> sizing, {
  Set<String> excludeEdgeIds = const {},
  required FlowRate Function(String rootId) rootFlowOf,
}) {
  final roots = serviceComponentRoots(net, kSupplyService, demandNodeIds: {
    for (final n in net.nodes)
      if (n.role == NodeRole.fixture) n.id,
  });
  final out = <SupplyMover>[];
  final ids = [
    for (final n in net.nodes)
      if (n.component == NodeComponent.pump ||
          n.component == NodeComponent.boosterSet)
        n.id,
  ]..sort();
  for (final id in ids) {
    final incident = [
      for (final e in net.edges)
        if (e.fromId == id || e.toId == id) e,
    ];
    if (incident.any((e) =>
        e.service == ServiceType.fireHydrant ||
        e.service == ServiceType.fireSprinkler)) {
      continue;
    }
    final supply = [
      for (final e in incident)
        if (e.service == kSupplyService) e,
    ];
    if (supply.isEmpty || roots[id] == null) continue;
    String? inEdge;
    FlowRate flow;
    if (roots[id] == id) {
      flow = rootFlowOf(id);
    } else {
      var best = 0.0;
      for (final e in supply) {
        if (excludeEdgeIds.contains(e.id)) continue;
        final sz = sizing[e.id];
        if (sz == null || sz.flowFromId == null || sz.flowFromId == id) {
          continue;
        }
        final q = sz.flow.cubicMetersPerSecond;
        if (q > best) {
          best = q;
          inEdge = e.id;
        }
      }
      if (inEdge == null) continue;
      flow = FlowRate(best);
    }
    if (flow.cubicMetersPerSecond <= 0) continue;
    final served = boosterServedNodes(net, id, inEdge ?? '',
        sizing: sizing, excludeEdgeIds: excludeEdgeIds);
    out.add((
      nodeId: id,
      inEdgeId: inEdge,
      flow: flow,
      served: served,
      transfer: served.any((n) => _isStorageTank(net.nodeById(n))),
    ));
  }
  return out;
}

/// Round 16 (plumbing-plant-root-pump-plus-booster /
/// plumbing-plant-multi-booster-single-duty) — the head each NON-transfer
/// mover adds, sized IN SERIES: movers are processed source-outward (a mover
/// is downstream of another when it sits in that one's served set); each is
/// sized on the largest shortfall, below [target], of the residual its OWN
/// delivery nodes see — [residual] is what the network delivers with NO
/// mover running (an open tank's outlet head) plus the heads of the movers
/// already upstream of that node. A mover's OWN delivery nodes are the
/// fixtures it serves that no downstream booster serves (else its open
/// leaves), plus each immediately-downstream booster's inlet, which it owes a
/// non-negative suction residual. So a root pump carries the floors it feeds
/// directly at the trunk flow, and a zone booster only its own zone's
/// SHORTFALL given that upstream head (it used to carry the WHOLE system head
/// while the root pump got no duty), and every one of several zone boosters
/// gets its own duty (only the largest-flow one used to). Pure.
Map<String, Head> seriesMoverHeads({
  required Network net,
  required List<SupplyMover> movers,
  required Map<String, Pressure> residual,
  required Pressure target,
}) {
  final boosters = [
    for (final m in movers)
      if (!m.transfer) m,
  ];
  int depth(SupplyMover m) =>
      boosters.where((u) => u.nodeId != m.nodeId && u.served.contains(m.nodeId)).length;
  boosters.sort((a, b) {
    final c = depth(a).compareTo(depth(b));
    return c != 0 ? c : a.nodeId.compareTo(b.nodeId);
  });
  final degree = <String, int>{};
  for (final e in net.edges) {
    if (e.service != kSupplyService) continue;
    degree[e.fromId] = (degree[e.fromId] ?? 0) + 1;
    degree[e.toId] = (degree[e.toId] ?? 0) + 1;
  }
  final heads = <String, double>{}; // head in Pa
  for (final m in boosters) {
    double upstream(String node) {
      var h = 0.0;
      for (final u in boosters) {
        if (u.nodeId == m.nodeId) continue;
        final hu = heads[u.nodeId];
        if (hu != null && u.served.contains(node)) h += hu;
      }
      return h;
    }

    final downstream = [
      for (final d in boosters)
        if (d.nodeId != m.nodeId && m.served.contains(d.nodeId)) d,
    ];
    bool ownedByDownstream(String n) =>
        downstream.any((d) => d.nodeId == n || d.served.contains(n));
    var own = [
      for (final n in m.served)
        if (net.nodeById(n)?.role == NodeRole.fixture && !ownedByDownstream(n))
          n,
    ];
    if (own.isEmpty) {
      own = [
        for (final n in m.served)
          if ((degree[n] ?? 0) == 1 && !ownedByDownstream(n)) n,
      ];
    }
    var worst = double.negativeInfinity;
    for (final n in own) {
      final r = residual[n];
      if (r == null) continue;
      worst = math.max(worst, target.pascals - (r.pascals + upstream(n)));
    }
    // The immediately-downstream boosters' inlets (not behind another one).
    for (final d in downstream) {
      if (downstream.any((o) => o.nodeId != d.nodeId && o.served.contains(d.nodeId))) {
        continue;
      }
      final r = residual[d.nodeId];
      if (r == null) continue;
      worst = math.max(worst, 0 - (r.pascals + upstream(d.nodeId)));
    }
    if (worst > 0) heads[m.nodeId] = worst;
  }
  return {
    for (final e in heads.entries) e.key: headFromPressure(Pressure(e.value)),
  };
}

/// Round 16 (plumbing-plant-transfer-pump-no-duty) — the head a TRANSFER pump
/// lifts at [flow]: the elevation from its source (the storage tank, else the
/// component root, reached walking UP the solved flow from the pump) to the
/// tank it fills, plus the Hazen–Williams friction of [flow] over every
/// drawn pipe on that source → pump → tank path at its sized bore and its
/// pipe product's C (the service default C otherwise). The tank inlet is a
/// free discharge (0 m residual, `// VERIFY` — a float valve's inlet
/// pressure is not modelled). Pure; null when no tank is reached.
Head? transferPumpHead({
  required Network net,
  required Map<String, EdgeSizing> sizing,
  required SupplyMover mover,
  required FlowRate flow,
  required double Function(NetEdge e) lengthOf,
  required double Function(NetNode n) elevationOf,
}) {
  final hwC = const SniProfile().hazenWilliamsC(PipeMaterial.pvc);
  String other(NetEdge e, String n) => e.fromId == n ? e.toId : e.fromId;
  List<NetEdge> supplyAt(String n) => [
        for (final e in net.edges)
          if (e.service == kSupplyService && (e.fromId == n || e.toId == n)) e,
      ];
  final path = <NetEdge>[];
  // Upstream: against the flow to the first storage tank (or the root).
  var node = mover.nodeId;
  final seen = <String>{node};
  while (!_isStorageTank(net.nodeById(node)) || node == mover.nodeId) {
    NetEdge? inE;
    for (final e in supplyAt(node)) {
      final f = sizing[e.id]?.flowFromId;
      if (f != null && f != node) {
        inE = e;
        break;
      }
    }
    if (inE == null) break;
    final up = other(inE, node);
    if (!seen.add(up)) break;
    path.add(inE);
    node = up;
  }
  final source = net.nodeById(node);
  // Downstream: with the flow, along the branch that reaches the tank.
  String? tank;
  node = mover.nodeId;
  final visited = <String>{node};
  while (tank == null) {
    NetEdge? next;
    for (final e in supplyAt(node)) {
      if (sizing[e.id]?.flowFromId != node) continue;
      final far = other(e, node);
      if (visited.contains(far)) continue;
      if (_isStorageTank(net.nodeById(far)) ||
          boosterServedNodes(net, far, e.id, sizing: sizing)
              .any((n) => _isStorageTank(net.nodeById(n)))) {
        next = e;
        break;
      }
    }
    if (next == null) return null;
    path.add(next);
    node = other(next, node);
    visited.add(node);
    if (_isStorageTank(net.nodeById(node))) tank = node;
  }
  final tankNode = net.nodeById(tank);
  if (tankNode == null || source == null) return null;
  var h = elevationOf(tankNode) - elevationOf(source);
  for (final e in path) {
    final sz = sizing[e.id];
    if (sz == null) continue;
    h += headLossHazenWilliams(
      flow: flow,
      length: Length(lengthOf(e)),
      diameter: sz.diameter,
      hazenWilliamsC: e.pipeProduct != null ? hazenWilliamsCFor(e.pipeProduct!) : hwC,
    ).meters;
  }
  return Head(math.max(0, h));
}

/// Round 16 — the solved duty of EVERY drawn supply mover, keyed by node id:
/// the root pump / inline boosters sized in series ([seriesMoverHeads]) on
/// the flow through each, and each transfer pump on its lift
/// ([transferPumpHead]) at the flow its discharge carries. A mover whose
/// head is not positive (the supply already serves its set) is absent. The
/// panel feed, the equipment schedule (one row per mover) and the riser read
/// this map, so a drawn root pump, a second zone booster and a transfer pump
/// are no longer fed at their component defaults and left off the schedule.
final supplyMoverDutiesProvider = Provider<Map<String, PumpDuty>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  final project = ref.watch(projectControllerProvider);
  final legs = ref.watch(parallelLegEdgeIdsProvider);
  final peak = ref.watch(supplyPeakFlowProvider);
  final movers = supplyMovers(net, sizing,
      excludeEdgeIds: legs,
      rootFlowOf: (root) {
        final d = sourceDeliveredFlow(net, sizing, kSupplyService, root,
            edgeFixtureUnits: ref.watch(edgeFixtureUnitsProvider),
            flushSystem: ref.watch(supplyFlushSystemProvider),
            excludeEdgeIds: legs);
        return d.cubicMetersPerSecond > 0 ? d : (peak ?? const FlowRate(0));
      });
  if (movers.isEmpty) return const {};
  final out = <String, PumpDuty>{};

  // Series movers on the no-mover residual.
  final solution = ref.watch(solveProvider);
  Map<String, Pressure>? unboosted;
  if (solution != null) {
    final pH = pressureFromHead(solution.requiredPumpHead).pascals;
    unboosted = {
      for (final e in solution.residualPressure.entries)
        e.key: Pressure(e.value.pascals - pH),
    };
  } else {
    unboosted = ref.watch(downfeedProvider)?.residualPressure;
  }
  if (unboosted != null) {
    final heads = seriesMoverHeads(
        net: net, movers: movers, residual: unboosted, target: _targetResidual);
    for (final m in movers) {
      final h = heads[m.nodeId];
      if (h == null || h.meters <= 0) continue;
      out[m.nodeId] = sizePump(flow: m.flow, head: h);
    }
  }

  // Transfer pumps on their lift.
  double lengthOf(NetEdge e) => edgeLength(
        e,
        net,
        calibrationBySheet: project.calibrations,
        building: project.building,
        mounting: project.mounting,
      ).meters;
  for (final m in movers) {
    if (!m.transfer) continue;
    final h = transferPumpHead(
      net: net,
      sizing: sizing,
      mover: m,
      flow: m.flow,
      lengthOf: lengthOf,
      elevationOf: (n) =>
          nodeElevation(n, project.building, project.mounting).meters,
    );
    if (h == null || h.meters <= 0) continue;
    out[m.nodeId] = sizePump(flow: m.flow, head: h);
  }
  return out;
});

/// Round 16 — the node [pumpDutyProvider]'s duty belongs to (null when that
/// duty is the legacy undrawn upfeed pump, or there is none).
final primarySupplyPumpNodeProvider = Provider<String?>((ref) {
  final duty = ref.watch(pumpDutyProvider);
  if (duty == null) return null;
  for (final e in ref.watch(supplyMoverDutiesProvider).entries) {
    if (identical(e.value, duty)) return e.key;
  }
  return null;
});

/// Round 16 — the TRANSFER pumps among [supplyMoverDutiesProvider] (node ids).
final transferPumpNodeIdsProvider = Provider<Set<String>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  final legs = ref.watch(parallelLegEdgeIdsProvider);
  return {
    for (final m in supplyMovers(net, sizing,
        excludeEdgeIds: legs, rootFlowOf: (_) => const FlowRate(1)))
      if (m.transfer) m.nodeId,
  };
});

/// Round 11 (hvac-network-1) — the flow a SOURCE node (the fan / AHU / pump a
/// service component is rooted at) actually delivers: the sum of the sized
/// flows on the [service] edges incident to [rootId]. The old fan / pump duty
/// took the single LARGEST edge, which equals the delivery only when exactly
/// one duct / pipe leaves the source — an AHU feeding two 0.5 m³/s trunks was
/// sized on 0.5 m³/s (one motor frame small, and the MEP→E feed with it).
///
/// When [flushSystem] is given (water supply) and every incident edge carries
/// its accumulated fixture units ([edgeFixtureUnits]), the summed UBAP is
/// diversified ONCE through the demand curve (Σ of already-diversified branch
/// flows would over-state a Hunter load), never below the largest branch.
/// A single incident edge returns that edge's flow verbatim (byte-identical to
/// the old trunk for the common single-trunk layout); no sized incident edge ⇒
/// zero.
///
/// Round 14 — [excludeEdgeIds] are the MIRRORED parallel legs the sizer
/// recorded ([parallelLegEdgeIdsProvider]: duty/standby standby legs, peer
/// source bridges). A standby suction leg leaving the same ground tank carries
/// the full set flow but only one pump runs, so summing it counted the set
/// flow twice (curve(160) = 4.05 L/s for a curve(80) = 2.55 L/s set).
FlowRate sourceDeliveredFlow(
  Network net,
  Map<String, EdgeSizing> sizing,
  ServiceType service,
  String rootId, {
  Map<String, double> edgeFixtureUnits = const {},
  FlushSystem? flushSystem,
  Set<String> excludeEdgeIds = const {},
}) {
  // Round 15 (root-metamorphic-pdam-fill-phantom) — only the edges whose flow
  // LEAVES the source (or, for extract air, ARRIVES at it) are its delivery:
  // a ground tank's fill line is incident but carries water INTO the tank.
  bool delivers(NetEdge e) {
    final from = sizing[e.id]?.flowFromId;
    if (from == null) return true;
    return service.isExtractAir ? from != rootId : from == rootId;
  }

  final incident = <NetEdge>[
    for (final e in net.edges)
      if (e.service == service &&
          !excludeEdgeIds.contains(e.id) &&
          (e.fromId == rootId || e.toId == rootId) &&
          (sizing[e.id]?.flow.cubicMetersPerSecond ?? 0) > 0 &&
          delivers(e))
        e,
  ];
  if (incident.isEmpty) return const FlowRate(0);
  if (incident.length == 1) return sizing[incident.single.id]!.flow;
  var summed = 0.0;
  var largest = 0.0;
  for (final e in incident) {
    final q = sizing[e.id]!.flow.cubicMetersPerSecond;
    summed += q;
    largest = math.max(largest, q);
  }
  if (flushSystem != null) {
    final units = [for (final e in incident) edgeFixtureUnits[e.id]];
    if (units.every((u) => u != null && u > 0)) {
      final total = units.fold<double>(0, (a, u) => a + u!);
      final q = const SniProfile()
          .probableFlowForFixtureUnits(total, system: flushSystem)
          .cubicMetersPerSecond;
      return FlowRate(math.max(q, largest));
    }
  }
  return FlowRate(summed);
}

/// One drawn air SYSTEM (a connected component of one air service): the
/// airflow its source delivers, its index-run static, and the node it is
/// rooted at.
typedef AirSystem = ({FlowRate trunk, Pressure stat, String fanNodeId});

/// Every drawn system of one air [service] — ONE per connected component,
/// each rooted at the SAME source the sizer accumulated from (plant → demand-
/// free entry leaf → demand-free hub), never at an arbitrary (e.g. a diffuser)
/// node. Sorted by delivered airflow, largest first (ties by root id), so the
/// head is the building's primary system.
///
/// Round 11 (hvac-network-1/4): the airflow is what LEAVES the source
/// ([sourceDeliveredFlow] — every trunk out of an AHU, not the single largest
/// edge), and a second AHU on another floor is its OWN system with its own
/// airflow + static instead of being dropped. Empty when nothing is sized.
List<AirSystem> airSystemsFor(
  Network net,
  Map<String, EdgeSizing> sizing,
  ProjectState project,
  ServiceType service, {
  Set<String> parallelLegs = const {},
}) {
  final edges = net.edges.where((e) => e.service == service).toList();
  if (edges.isEmpty) return const [];
  final flows = <String, FlowRate>{};
  for (final e in edges) {
    final s = sizing[e.id];
    if (s != null) flows[e.id] = s.flow;
  }
  if (!flows.values.any((f) => f.cubicMetersPerSecond > 0)) return const [];

  final roots = serviceComponentRoots(
    net,
    service,
    demandNodeIds: {
      for (final n in net.nodes)
        if (n.airflow != null) n.id,
    },
  );
  // The largest sized edge per component (keyed by its root) — the fallback
  // airflow when the root itself has no sized incident edge.
  final largest = <String, FlowRate>{};
  for (final e in edges) {
    final root = roots[e.fromId];
    final f = flows[e.id];
    if (root == null || f == null) continue;
    if (f.cubicMetersPerSecond >
        (largest[root]?.cubicMetersPerSecond ?? 0)) {
      largest[root] = f;
    }
  }
  final out = <AirSystem>[];
  for (final entry in largest.entries) {
    final root = entry.key;
    final delivered = sourceDeliveredFlow(net, sizing, service, root,
        excludeEdgeIds: parallelLegs);
    final trunk = delivered.cubicMetersPerSecond > 0 ? delivered : entry.value;
    if (trunk.cubicMetersPerSecond <= 0) continue;
    final s = solveDuctStatic(
      net: net,
      service: service,
      fanNodeId: root,
      edgeFlows: flows,
      sizing: sizing,
      calibrationBySheet: project.calibrations,
      building: project.building,
      mounting: project.mounting,
    );
    // Round 14 (inline-booster-fan-phantom) — an INLINE fan no longer roots
    // its system (the sizer roots at the demand-free outlet/intake leaf so
    // the discharge duct carries the whole airflow), but the DUTY still
    // belongs to the drawn machine: report the system's air-unit plant node
    // (lowest id) when the root itself is not one, so the MEP→E feed fills
    // that node's way instead of minting a second duty way beside it.
    //
    // Round 16 (regression-inline-fan-duty-attributed-to-fcu) — the unit is
    // chosen by ROLE, never by id: an inline MOVER (supply / exhaust fan)
    // first, then an AHU, then any other source plant. A terminal air unit
    // (FCU / AC) and a demand-bearing plant (one with its own airflow) are
    // DELIVERY points on the fresh-air fan's duct, never its machine — the
    // lowest-id rule used to hand the PAU fan's duty (and its panel way and
    // schedule tag) to an FCU whose id happened to sort first.
    var unit = root;
    if (net.nodeById(root)?.role != NodeRole.plant) {
      int rank(NetNode n) => switch (n.component) {
            NodeComponent.supplyFan || NodeComponent.exhaustFan => 0,
            NodeComponent.ahu => 1,
            _ => 2,
          };
      final machines = [
        for (final n in net.nodes)
          if (roots[n.id] == root &&
              n.role == NodeRole.plant &&
              n.airflow == null &&
              !isTerminalAirUnit(n.component) &&
              (n.component?.isElectricalLoad ?? false))
            n,
      ]..sort((a, b) {
          final c = rank(a).compareTo(rank(b));
          return c != 0 ? c : a.id.compareTo(b.id);
        });
      if (machines.isNotEmpty) {
        unit = machines.first.id;
      } else {
        // Round 17 (regression-ducted-ac-intake-phantom-fan-way) — no fan /
        // AHU / source plant: a DEMAND-FREE terminal air unit (a stand-alone
        // ducted AC / FCU) is the system's machine before the bare root leaf,
        // so its duty never lands on an open intake end as a phantom fan.
        final units = [
          for (final n in net.nodes)
            if (roots[n.id] == root &&
                n.role == NodeRole.plant &&
                n.airflow == null &&
                isTerminalAirUnit(n.component))
              n,
        ]..sort((a, b) => a.id.compareTo(b.id));
        if (units.isNotEmpty) unit = units.first.id;
      }
    }
    out.add((trunk: trunk, stat: s.totalStaticPressure, fanNodeId: unit));
  }
  out.sort((a, b) {
    final c = b.trunk.cubicMetersPerSecond.compareTo(a.trunk.cubicMetersPerSecond);
    return c != 0 ? c : a.fanNodeId.compareTo(b.fanNodeId);
  });
  return out;
}

/// The PRIMARY system of one air [service] (the largest delivered airflow) —
/// zero (and no fan node) when nothing is sized.
({FlowRate trunk, Pressure stat, String? fanNodeId}) _airSystem(
  Network net,
  Map<String, EdgeSizing> sizing,
  ProjectState project,
  ServiceType service, {
  Set<String> parallelLegs = const {},
}) {
  final all = airSystemsFor(net, sizing, project, service,
      parallelLegs: parallelLegs);
  if (all.isEmpty) {
    return (trunk: const FlowRate(0), stat: const Pressure(0), fanNodeId: null);
  }
  final s = all.first;
  return (trunk: s.trunk, stat: s.stat, fanNodeId: s.fanNodeId);
}

/// mech-building-4 — the equipment INTERNAL static (filter + coil + casing) of
/// the air unit a drawn duct system is rooted at: the drawn-network solve only
/// sums duct friction + the terminal loss (the EXTERNAL static), so an AHU fan
/// sized on it alone came out ≈2× under-motored. The same
/// [defaultInternalStatic] the room-air path uses (AHU 250 Pa, FCU / ducted AC
/// 50 Pa, `// VERIFY` representative allowances), added ONCE per fan. A bare
/// fan, an un-typed source node or no node ⇒ 0 Pa (byte-identical).
Pressure airUnitInternalStatic(NetNode? source) {
  final kind = switch (source?.component) {
    NodeComponent.ahu => AirEquipmentKind.ahu,
    NodeComponent.fcu || NodeComponent.acDucted => AirEquipmentKind.fcu,
    _ => null,
  };
  return kind == null ? const Pressure(0) : defaultInternalStatic(kind);
}

/// Round 11 (hvac-network-4) — one supply/return FAN DUTY per drawn air
/// unit, keyed by the node the system is rooted at. Each supply system's
/// delivered airflow runs against its OWN supply index-run static plus the
/// return system rooted at the SAME unit (the unit's fan sees both legs) plus
/// the unit's internal static, once. The PRIMARY supply system (largest
/// airflow) also adopts the primary return system when no return shares its
/// root (the historic single-system pairing); any other return-only system
/// gets its own fan. A second AHU on another floor therefore gets its own
/// duty instead of being dropped. Empty when nothing is sized.
final supplyFanDutiesByRootProvider = Provider<Map<String, FanDuty>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  final project = ref.watch(projectControllerProvider);
  final supplies = airSystemsFor(net, sizing, project, ServiceType.duct,
      parallelLegs: ref.watch(parallelLegEdgeIdsProvider));
  final rets = airSystemsFor(net, sizing, project, ServiceType.returnAir,
      parallelLegs: ref.watch(parallelLegEdgeIdsProvider));
  final supplyRoots = {for (final s in supplies) s.fanNodeId};
  final consumed = <String>{};
  final out = <String, FanDuty>{};
  Pressure internalOf(String root) => airUnitInternalStatic(net.nodeById(root));
  for (var i = 0; i < supplies.length; i++) {
    final s = supplies[i];
    AirSystem? ret;
    for (final r in rets) {
      if (r.fanNodeId == s.fanNodeId) ret = r;
    }
    if (ret == null &&
        i == 0 &&
        rets.isNotEmpty &&
        !supplyRoots.contains(rets.first.fanNodeId)) {
      ret = rets.first;
    }
    if (ret != null) consumed.add(ret.fanNodeId);
    out[s.fanNodeId] = sizeFan(
      airflow: s.trunk,
      totalStaticPressure: Pressure(s.stat.pascals +
          (ret?.stat.pascals ?? 0) +
          internalOf(s.fanNodeId).pascals),
    );
  }
  // Return-only systems still get a fan.
  for (final r in rets) {
    if (consumed.contains(r.fanNodeId) || out.containsKey(r.fanNodeId)) {
      continue;
    }
    out[r.fanNodeId] = sizeFan(
      airflow: r.trunk,
      totalStaticPressure:
          Pressure(r.stat.pascals + internalOf(r.fanNodeId).pascals),
    );
  }
  // Round 16 (air-systems-2-shared-main-second-ahu-fed-default) — a PEER
  // source on the same duct (a second AHU the sizer mirrored as a parallel
  // source leg) carries the SAME system duty — the duty/standby convention
  // the pumps use — so it is scheduled and fed on it instead of the 5.5 kW
  // component default.
  final legs = ref.watch(parallelLegEdgeIdsProvider);
  if (legs.isNotEmpty) {
    for (final service in const [ServiceType.duct, ServiceType.returnAir]) {
      final roots = serviceComponentRoots(net, service, demandNodeIds: {
        for (final n in net.nodes)
          if (n.airflow != null) n.id,
      });
      for (final n in net.nodes) {
        if (out.containsKey(n.id) || n.role != NodeRole.plant) continue;
        if (n.airflow != null || isTerminalAirUnit(n.component)) continue;
        final root = roots[n.id];
        if (root == null || root == n.id) continue;
        final duty = out[root];
        if (duty == null) continue;
        if (net.nodeById(root)?.component != n.component) continue;
        final onLeg = net.edges.any((e) =>
            e.service == service &&
            legs.contains(e.id) &&
            (e.fromId == n.id || e.toId == n.id));
        if (onLeg) out[n.id] = duty;
      }
    }
  }
  return out;
});

/// Round 11 — one EXHAUST fan duty per drawn exhaust system, keyed by its root.
final exhaustFanDutiesByRootProvider = Provider<Map<String, FanDuty>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  final project = ref.watch(projectControllerProvider);
  return {
    for (final ex in airSystemsFor(net, sizing, project, ServiceType.exhaust,
      parallelLegs: ref.watch(parallelLegEdgeIdsProvider)))
      ex.fanNodeId:
          sizeFan(airflow: ex.trunk, totalStaticPressure: ex.stat),
  };
});

/// Fan duty for the PRIMARY air system: its delivered airflow against the SUM
/// of the supply and return index-run statics (the AHU fan sees both) plus the
/// unit's internal static. The entry of [supplyFanDutiesByRootProvider] for the
/// primary root. Null when there's no sized air network.
final ductFanProvider = Provider<FanDuty?>((ref) {
  final roots = ref.watch(airSystemRootNodesProvider);
  final id = roots.supply;
  if (id == null) return null;
  return ref.watch(supplyFanDutiesByRootProvider)[id];
});

/// The plant nodes the drawn air systems are ROOTED at (the same source the
/// fan duties are solved from): the supply (else return) duct system's unit,
/// and the exhaust system's fan. Null when that system has no sized edges.
/// Read by the MEP→electrical feed + the equipment schedule so the duty, the
/// panel way and the schedule tag all name ONE drawn machine (audit r8).
final airSystemRootNodesProvider =
    Provider<({String? supply, String? exhaust})>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  final project = ref.watch(projectControllerProvider);
  final supply = _airSystem(net, sizing, project, ServiceType.duct,
      parallelLegs: ref.watch(parallelLegEdgeIdsProvider));
  final ret = _airSystem(net, sizing, project, ServiceType.returnAir,
      parallelLegs: ref.watch(parallelLegEdgeIdsProvider));
  final ex = _airSystem(net, sizing, project, ServiceType.exhaust,
      parallelLegs: ref.watch(parallelLegEdgeIdsProvider));
  return (
    supply: supply.fanNodeId ?? ret.fanNodeId,
    exhaust: ex.fanNodeId,
  );
});

/// Fan duty for a drawn EXHAUST system (toilet / kitchen extract): its own
/// trunk airflow against its OWN index-run static — a separate fan, so it is
/// never folded into [ductFanProvider]'s supply + return sum. Null when no
/// exhaust duct is sized.
final exhaustFanProvider = Provider<FanDuty?>((ref) {
  final id = ref.watch(airSystemRootNodesProvider).exhaust;
  if (id == null) return null;
  return ref.watch(exhaustFanDutiesByRootProvider)[id];
});

/// Supply vs return airflow (L/s) for the air-balance readout — the TOTAL each
/// service's sources deliver, summed over every drawn system (Round 11: it
/// read the single largest edge, halving an AHU with two trunks). Null when
/// there's no sized air network.
final airBalanceProvider = Provider<({double supplyLps, double returnLps})?>(
  (ref) {
    final net = ref.watch(sizingNetworkProvider);
    final sizing = ref.watch(sizingProvider);
    final project = ref.watch(projectControllerProvider);
    double total(ServiceType service) =>
        airSystemsFor(net, sizing, project, service,
      parallelLegs: ref.watch(parallelLegEdgeIdsProvider))
            .fold(0.0, (a, s) => a + s.trunk.inLitersPerSecond);
    final supply = total(ServiceType.duct);
    final ret = total(ServiceType.returnAir);
    if (supply <= 0 && ret <= 0) return null;
    return (supplyLps: supply, returnLps: ret);
  },
);

/// Pressure zones for a downfeed building. Zones are bounded so the lowest
/// fixture stays under the SNI max-fixture-pressure limit AFTER the PRV holds
/// the target residual at the zone top — i.e. the effective span ceiling is
/// (max-fixture − target-residual).
final zonesProvider = Provider<List<PressureZone>>((ref) {
  final project = ref.watch(projectControllerProvider);
  final maxFix = const SniProfile().maxFixtureStaticPressure.value;
  final effective = Pressure(
    (maxFix.pascals - _prvSetpoint.pascals).clamp(1.0, double.infinity),
  );
  // The span is ceiling(top) − fixture(bottom), so it must use the PROJECT
  // mounting heights (F8) — the same ones the solves/BOM/report use.
  return computeDownfeedZones(
    building: project.building,
    mounting: project.mounting,
    maxStaticPressure: effective,
  );
});

/// Per-zone PRV static profile (top residual → bottom static, within-limit) for
/// a downfeed system holding [_targetResidual] at each zone top.
final zoneStaticsProvider = Provider<List<DownfeedZoneStatic>>((ref) {
  final project = ref.watch(projectControllerProvider);
  final zones = ref.watch(zonesProvider);
  return downfeedZoneStatics(
    building: project.building,
    mounting: project.mounting,
    zones: zones,
    prvSetpoint: _prvSetpoint,
    maxStatic: const SniProfile().maxFixtureStaticPressure.value,
  );
});

/// Bill of materials for the sized network.
final bomProvider = Provider<List<BomLine>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  if (sizing.isEmpty) return const [];
  final project = ref.watch(projectControllerProvider);
  return buildBom(
    net: net,
    sizing: sizing,
    calibrationBySheet: project.calibrations,
    building: project.building,
    mounting: project.mounting,
  );
});

/// Continuous pipe chains (maximal collinear same-service/-diameter run
/// segments merged through pass-through vertices) — the basis for placing stock
/// couplings efficiently and for the cut plan. Empty when nothing is sized.
final pipeChainsProvider = Provider<List<PipeChain>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  if (sizing.isEmpty) return const [];
  final project = ref.watch(projectControllerProvider);
  return buildPipeChains(
    net: net,
    sizing: sizing,
    calibrationBySheet: project.calibrations,
    building: project.building,
    mounting: project.mounting,
  );
});

/// The stock-pipe CUT PLAN per (service, diameter): how many 4 m (PVC/PPR) /
/// 6 m (steel) stock bars are needed, with offcut reuse, and the resulting
/// waste. The efficiency engine behind the on-canvas coupling marks.
final pipeCutPlanProvider = Provider<List<PipeCutGroup>>((ref) {
  return buildPipeCutPlan(ref.watch(pipeChainsProvider));
});

/// Hot-water recirculation design for the drawn hot-water network. Null when
/// there's no circulated hot-water pipework.
///
/// Round 16 (plumbing-plant-hw-recirc-loop-head) — the loop is the CIRCULATED
/// pipework only ([hotWaterRecircLoop]): the mains / risers the recirculation
/// keeps hot, never the fixture branches (dead legs the circulating flow does
/// not pass through). Heat loss is 25 W/m over that pipework plus the return
/// leg (one return run back along the index path, at
/// [kDefaultRecircReturnDiameter] — `// VERIFY`, a return is rarely drawn),
/// and the head is the index run's friction at each segment's OWN sized bore
/// plus the return leg. It used to sum EVERY hot-water edge (fixture branches
/// included) into one length and push the recirc flow through all of it at
/// the network's SMALLEST bore (a DN15 branch): 1711 m of head and a 30 kW
/// circulator on a 20-storey building.
final hotWaterRecircProvider = Provider<HotWaterRecircDesign?>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  final project = ref.watch(projectControllerProvider);
  final loop = hotWaterRecircLoop(net, sizing,
      lengthOf: (e) => edgeLength(
            e,
            net,
            calibrationBySheet: project.calibrations,
            building: project.building,
            mounting: project.mounting,
          ).meters);
  if (loop == null) return null;
  final design = sizeHotWaterRecirculation(
    heatLoss: heatLossFromLength(
        loopLength: Length(loop.circulatedLengthM + loop.returnLengthM)),
    loopLength: Length(loop.returnLengthM),
    returnDiameter: kDefaultRecircReturnDiameter,
    supplyPath: loop.indexPath,
    // M14 — the flow temperature and allowable loop drop are DESIGN INPUTS
    // (Building page), not engine constants: they set the recirc flow AND the
    // modelled return temperature the anti-Legionella check judges. The
    // defaults (60 °C / 5 K) reproduce the engine's own values exactly — but a
    // project that departs (55 °C stored, or a 10 K drop) now actually trips
    // the check.
    flowTempC: ref.watch(hotWaterFlowTempProvider),
    allowableDropK: ref.watch(hotWaterDeltaTProvider),
  );
  // Round 17 follow-up — a DRAWN return: the reported loop length is the drawn
  // loop the head was computed around (no phantom DN20 leg was added).
  final drawn = loop.drawnLoopLengthM;
  if (drawn == null) return design;
  return HotWaterRecircDesign(
    recircFlow: design.recircFlow,
    loopHead: design.loopHead,
    pump: design.pump,
    returnTempC: design.returnTempC,
    loopLength: Length(drawn),
  );
});

/// Round 16 — the CIRCULATED hot-water pipework of [net] (pure; testable
/// without a container): every hot-water edge with NO fixture-role endpoint
/// and no bare open-ended leaf (a dead leg the recirculation never reaches),
/// its total length, and the INDEX run from the component's source (the
/// longest circulated path by length, each segment at its sized bore) whose
/// length the return leg mirrors. Null when nothing is circulated.
({
  double circulatedLengthM,
  double returnLengthM,
  List<({Length length, Diameter diameter})> indexPath,
  double? drawnLoopLengthM,
})? hotWaterRecircLoop(
  Network net,
  Map<String, EdgeSizing> sizing, {
  required double Function(NetEdge e) lengthOf,
}) {
  final hw = [
    for (final e in net.edges)
      if (e.service == ServiceType.hotWater) e,
  ];
  if (hw.isEmpty) return null;
  final degree = <String, int>{};
  for (final e in hw) {
    degree[e.fromId] = (degree[e.fromId] ?? 0) + 1;
    degree[e.toId] = (degree[e.toId] ?? 0) + 1;
  }
  final roots = serviceComponentRoots(net, ServiceType.hotWater,
      demandNodeIds: {
        for (final n in net.nodes)
          if (n.role == NodeRole.fixture) n.id,
      });
  bool deadEnd(String id) {
    final n = net.nodeById(id);
    if (n?.role == NodeRole.fixture) return true;
    // A bare open leaf (not the source) is a branch end, not a loop.
    return (degree[id] ?? 0) == 1 &&
        roots[id] != id &&
        n?.role != NodeRole.plant;
  }

  final circulated = [
    for (final e in hw)
      if (!deadEnd(e.fromId) && !deadEnd(e.toId)) e,
  ];
  if (circulated.isEmpty) return null;
  var total = 0.0;
  final adj = <String, List<NetEdge>>{};
  for (final e in circulated) {
    total += lengthOf(e);
    (adj[e.fromId] ??= []).add(e);
    (adj[e.toId] ??= []).add(e);
  }
  if (total <= 0) return null;

  final sources = {
    for (final e in circulated) ...[
      if (roots[e.fromId] == e.fromId) e.fromId,
      if (roots[e.toId] == e.toId) e.toId,
    ],
  };
  // A component whose source sits on a dead leg starts from the circulated
  // node nearest it (deterministic: the lowest-id circulated node).
  if (sources.isEmpty) sources.add((adj.keys.toList()..sort()).first);
  for (final l in adj.values) {
    l.sort((a, b) => a.id.compareTo(b.id));
  }

  // Round 17 follow-up (regression-hw-recirc-phantom-return-on-drawn-loop) — a
  // DRAWN return closes a cycle in the circulated pipework (the G2 HWR leg, the
  // Round-12 check-valve cut). Its length is already inside [total], so adding
  // the mirrored DN20 return on top counted the return twice (+40 % flow,
  // +49 % head on a 100 m loop). When a cycle exists, the loop IS that cycle:
  // no phantom return, and the head is the friction around the drawn loop at
  // each segment's own bore. The longest fundamental cycle (BFS tree from the
  // source + one closing edge) is taken — deterministic by edge id.
  //
  // Round 19 (regression-hw-ring-main-taken-as-drawn-return) — only a cycle
  // that IS a recirculation return counts: it must pass through the source /
  // heater (a plant, or the component's own root) or carry the check valve
  // that marks a drawn return (the Round-12 convention). A RING MAIN fed by a
  // stub (heater → feed → ring) is distribution pipework, not a return: it
  // still needs the feed AND a return to the heater, so it falls through to
  // the index run + mirrored DN20 return (taking the ring as the loop dropped
  // the heater feed and the return — ~32× low head on the probe).
  bool isReturnCycle(List<NetEdge> cycle) {
    for (final c in cycle) {
      for (final id in [c.fromId, c.toId]) {
        final n = net.nodeById(id);
        if (roots[id] == id ||
            n?.role == NodeRole.plant ||
            n?.component == NodeComponent.checkValve) {
          return true;
        }
      }
    }
    return false;
  }

  var bestCycleLen = 0.0;
  var bestCycle = const <NetEdge>[];
  for (final src in sources.toList()..sort()) {
    final parent = <String, NetEdge>{};
    final depth = <String, int>{src: 0};
    final queue = [src];
    final treeEdgeIds = <String>{};
    for (var i = 0; i < queue.length; i++) {
      final n = queue[i];
      for (final e in adj[n] ?? const <NetEdge>[]) {
        final m = e.fromId == n ? e.toId : e.fromId;
        if (depth.containsKey(m)) continue;
        depth[m] = depth[n]! + 1;
        parent[m] = e;
        treeEdgeIds.add(e.id);
        queue.add(m);
      }
    }
    final seen = <String>{};
    for (final n in queue) {
      for (final e in adj[n] ?? const <NetEdge>[]) {
        if (treeEdgeIds.contains(e.id) || !seen.add(e.id)) continue;
        if (e.fromId == e.toId) continue;
        // Walk both ends up to their lowest common ancestor.
        var a = e.fromId;
        var b = e.toId;
        final up = <NetEdge>[];
        final down = <NetEdge>[];
        while (a != b) {
          if (depth[a]! >= depth[b]!) {
            final pe = parent[a]!;
            up.add(pe);
            a = pe.fromId == a ? pe.toId : pe.fromId;
          } else {
            final pe = parent[b]!;
            down.add(pe);
            b = pe.fromId == b ? pe.toId : pe.fromId;
          }
        }
        final cycle = [...up.reversed, e, ...down];
        if (!isReturnCycle(cycle)) continue;
        final len = cycle.fold<double>(0, (acc, c) => acc + lengthOf(c));
        if (len > bestCycleLen + 1e-12) {
          bestCycleLen = len;
          bestCycle = cycle;
        }
      }
    }
  }
  if (bestCycle.isNotEmpty) {
    return (
      circulatedLengthM: total,
      returnLengthM: 0.0,
      indexPath: [
        for (final e in bestCycle)
          (
            length: Length(lengthOf(e)),
            diameter: sizing[e.id]?.diameter ?? kDefaultRecircReturnDiameter,
          ),
      ],
      drawnLoopLengthM: bestCycleLen,
    );
  }

  // Index run: the longest circulated path (by length) from a source.
  var bestLen = 0.0;
  var bestPath = const <NetEdge>[];
  for (final src in sources.toList()..sort()) {
    final dist = <String, double>{src: 0};
    final via = <String, NetEdge>{};
    final queue = [src];
    for (var i = 0; i < queue.length; i++) {
      final n = queue[i];
      for (final e in adj[n] ?? const <NetEdge>[]) {
        final m = e.fromId == n ? e.toId : e.fromId;
        if (dist.containsKey(m)) continue;
        dist[m] = dist[n]! + lengthOf(e);
        via[m] = e;
        queue.add(m);
      }
    }
    for (final en in dist.entries) {
      if (en.value <= bestLen + 1e-12) continue;
      bestLen = en.value;
      final path = <NetEdge>[];
      var cur = en.key;
      while (via[cur] != null) {
        final e = via[cur]!;
        path.add(e);
        cur = e.fromId == cur ? e.toId : e.fromId;
      }
      bestPath = path.reversed.toList();
    }
  }
  return (
    circulatedLengthM: total,
    returnLengthM: bestLen,
    indexPath: [
      for (final e in bestPath)
        (
          length: Length(lengthOf(e)),
          diameter: sizing[e.id]?.diameter ?? kDefaultRecircReturnDiameter,
        ),
    ],
    drawnLoopLengthM: null,
  );
}

/// Anti-Legionella advisory over the modelled hot-water recirculation: the
/// modelled return temperature (°C) when it falls below the safe floor
/// (`kLegionellaMinReturnTempC` ≈ 55 °C), else null. Read-only — it never
/// resizes; the Review panel surfaces it. Null when there's no hot-water loop or
/// the return is hot enough. // VERIFY threshold vs SNI / WHO guidance.
final hotWaterLegionellaProvider = Provider<double?>((ref) {
  final hwr = ref.watch(hotWaterRecircProvider);
  if (hwr == null || !hwr.legionellaRisk) return null;
  return hwr.returnTempC;
});

/// Jointing-consumables estimate (PVC solvent cement cans, duct sealant
/// cartridges, thread-tape rolls) for the quotation. Joints come from the
/// fittings + inline pipe couplings; duct sealant from the duct joint length.
final consumablesProvider = Provider<ConsumablesEstimate>((ref) {
  final fittings = ref.watch(fittingsProvider);
  final chains = ref.watch(pipeChainsProvider);
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  final project = ref.watch(projectControllerProvider);

  final solventByDn = <int, int>{};
  var threaded = 0;
  // Fitting sockets (each is a made joint), grouped by the service join method.
  for (final f in fittings) {
    final joints = fittingSockets(f.type) * f.count;
    switch (joinMethodFor(f.service, f.material)) {
      case PipeJoinMethod.solventWeld:
        solventByDn[f.diameterMm] = (solventByDn[f.diameterMm] ?? 0) + joints;
      case PipeJoinMethod.threaded:
        threaded += joints;
      case PipeJoinMethod.heatFusion:
      case PipeJoinMethod.other:
        break;
    }
  }
  // Inline couplings along straight pipe chains (sections − 1 per chain).
  for (final c in chains) {
    if (c.service.regime == FlowRegime.air) continue;
    final sections = (c.lengthM / c.stockLengthM).ceil();
    final couplings = sections > 1 ? sections - 1 : 0;
    if (couplings == 0) continue;
    switch (joinMethodFor(c.service, c.material)) {
      case PipeJoinMethod.solventWeld:
        solventByDn[c.diameterMm] =
            (solventByDn[c.diameterMm] ?? 0) + couplings;
      case PipeJoinMethod.threaded:
        threaded += couplings;
      case PipeJoinMethod.heatFusion:
      case PipeJoinMethod.other:
        break;
    }
  }
  // Duct joint sealant: total gasket length over the duct runs.
  var sealM = 0.0;
  for (final e in net.edges) {
    if (e.kind != EdgeKind.run || e.service.regime != FlowRegime.air) continue;
    final s = sizing[e.id];
    if (s == null) continue;
    final len = edgeLength(e, net,
            calibrationBySheet: project.calibrations,
            building: project.building,
            mounting: project.mounting)
        .meters;
    final acc = computeDuctAccessories(e, s, len);
    if (acc != null) sealM += acc.gasketM;
  }

  return estimateConsumables(
    solventJointsByDn: solventByDn,
    ductSealMetres: sealM,
    threadedJoints: threaded,
  );
});

/// Round 21 (bom-quote-3) — the drawn components (valves, heads, terminals,
/// drains, dampers) taken off per piece for the mechanical quotation.
final componentTakeoffProvider = Provider<List<ComponentLine>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  return buildComponentTakeoff(net: net, sizing: ref.watch(sizingProvider));
});

/// Estimated fittings (elbows/tees/crosses/reducers) for the sized network.
final fittingsProvider = Provider<List<FittingLine>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  if (sizing.isEmpty) return const [];
  return buildFittings(net: net, sizing: sizing);
});

/// Key for [heatmapFieldProvider]: the sheet/floor being rendered plus the
/// sheet's content extent (which fixes the sample grid). The viewport transform
/// is deliberately NOT part of the key — panning/zooming must reuse the cached
/// field, not re-sample it (K3).
typedef HeatmapFieldKey = ({
  String sheetId,
  int floorIndex,
  double width,
  double height,
});

/// The sampled residual-pressure scalar field for the heatmap overlay (K3),
/// memoized on the solve result ([residualByNodeProvider]) + node positions +
/// sheet + sample grid. Because the viewport transform is not an input, panning
/// or zooming the canvas reuses the SAME cached [ScalarField] object instead of
/// re-running the O(cells·nodes) inverse-distance-weighting every frame — only a
/// new solve (or a node move that shifts positions/residuals) recomputes it.
/// Null when there is no residual data for this sheet/floor. The `~28 cells
/// across the longer edge` resolution matches the painter's prior inline sample.
final heatmapFieldProvider =
    Provider.family<ScalarField?, HeatmapFieldKey>((ref, key) {
  final nodes = _heatmapFieldNodes(ref, key);
  if (nodes == null) return null;
  final resolution = (math.max(key.width, key.height) / 28).clamp(1.0, 1e9);
  return sampleField(
    nodes: nodes,
    bounds: FieldBounds(0, 0, key.width, key.height),
    resolution: resolution,
  );
});

/// The solved sample points feeding the heatmap on one sheet/floor: every node
/// that carries a residual. Null when there is no residual data at all (the
/// caller renders nothing). Shared by [heatmapFieldProvider] and
/// [heatmapMaskProvider] so the field and its mask can never sample different
/// node sets.
List<FieldNode>? _heatmapFieldNodes(Ref ref, HeatmapFieldKey key) {
  final residual = ref.watch(residualByNodeProvider);
  if (residual.isEmpty) return null;
  final net = ref.watch(sizingNetworkProvider);
  final nodes = <FieldNode>[
    for (final n in net.nodes)
      if (n.sheetId == key.sheetId && n.floorIndex == key.floorIndex)
        if (residual[n.id] != null)
          FieldNode(n.x, n.y, residual[n.id]!.inKiloPascals),
  ];
  return nodes.isEmpty ? null : nodes;
}

/// J3 — how far the painted heatmap corridor reaches, as a MULTIPLE of the
/// network's own characteristic node spacing (the mean nearest-neighbour
/// distance over the sampled nodes). Two spacings out, the interpolation is
/// still bracketed by real solved values on at least one side; beyond that the
/// IDW is pure extrapolation and must not be presented as measurement.
const double kHeatmapCorridorSpacings = 2.0;

/// J3 — the fraction of [kHeatmapCorridorSpacings] over which the corridor
/// FADES to nothing (a soft edge rather than a hard cut, which would itself
/// read as a drawn boundary). Full opacity out to the core radius, zero at
/// `core * (1 + this)`.
const double kHeatmapCorridorFeather = 0.6;

/// J3 — the per-cell opacity MASK that keeps the heatmap wash "along the
/// pipework". Cell (col, row) matches [heatmapFieldProvider]'s grid exactly
/// (it is derived from that field), and carries a 0..1 multiplier the painter
/// applies to the cell's colour alpha:
///
///  * 1.0 within [coreRadius] of the nearest solved node — the corridor the
///    solve actually measured;
///  * a linear fade to 0.0 at `coreRadius * (1 + kHeatmapCorridorFeather)`;
///  * 0.0 beyond — empty sheet corners stay bare plan, because the solve says
///    nothing about them.
///
/// The radius is derived from the drawing, not from the paper: the mean
/// NEAREST-NEIGHBOUR distance between sampled nodes (the network's own
/// characteristic spacing) x [kHeatmapCorridorSpacings]. A single sampled node
/// has no spacing to measure, so it falls back to three sample cells. The floor
/// of two cells keeps a sparse network from dissolving into speckle smaller
/// than the sample grid itself.
///
/// Memoized on the same inputs as the field (K3), so pan/zoom reuses it.
@immutable
class HeatmapMask {
  final int cols;
  final int rows;
  final double cellSize;
  final double originX;
  final double originY;

  /// The corridor's full-opacity radius in sheet (world) pixels — surfaced for
  /// tests and for anyone reasoning about the derivation.
  final double coreRadius;

  /// Row-major 0..1 alpha multipliers, one per grid cell.
  final List<double> alpha;

  const HeatmapMask({
    required this.cols,
    required this.rows,
    required this.cellSize,
    required this.originX,
    required this.originY,
    required this.coreRadius,
    required this.alpha,
  });

  double alphaAt(int col, int row) => alpha[row * cols + col];

  /// Whether every cell is fully painted (nothing is masked away) — the mask is
  /// then a no-op and the render is exactly the pre-J3 wash.
  bool get isOpaqueEverywhere => alpha.every((a) => a >= 1.0);
}

final heatmapMaskProvider =
    Provider.family<HeatmapMask?, HeatmapFieldKey>((ref, key) {
  final field = ref.watch(heatmapFieldProvider(key));
  if (field == null) return null;
  final nodes = _heatmapFieldNodes(ref, key);
  if (nodes == null) return null;

  // The network's characteristic spacing: mean nearest-neighbour distance.
  var spacingSum = 0.0;
  var spacingCount = 0;
  for (var i = 0; i < nodes.length; i++) {
    var nearest = double.infinity;
    for (var j = 0; j < nodes.length; j++) {
      if (i == j) continue;
      final dx = nodes[i].x - nodes[j].x;
      final dy = nodes[i].y - nodes[j].y;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d < nearest) nearest = d;
    }
    if (nearest.isFinite && nearest > 0) {
      spacingSum += nearest;
      spacingCount++;
    }
  }
  final spacing = spacingCount == 0 ? 0.0 : spacingSum / spacingCount;
  final core = math.max(
    field.cellSize * 2,
    spacingCount == 0
        ? field.cellSize * 3
        : spacing * kHeatmapCorridorSpacings,
  );
  final outer = core * (1 + kHeatmapCorridorFeather);

  final alpha = List<double>.filled(field.cols * field.rows, 0.0);
  for (var row = 0; row < field.rows; row++) {
    final cy = field.centerY(row);
    for (var col = 0; col < field.cols; col++) {
      final cx = field.centerX(col);
      var nearest = double.infinity;
      for (final n in nodes) {
        final dx = n.x - cx;
        final dy = n.y - cy;
        final d2 = dx * dx + dy * dy;
        if (d2 < nearest) nearest = d2;
      }
      final d = math.sqrt(nearest);
      final a = d <= core
          ? 1.0
          : d >= outer
              ? 0.0
              : 1.0 - (d - core) / (outer - core);
      alpha[row * field.cols + col] = a;
    }
  }
  return HeatmapMask(
    cols: field.cols,
    rows: field.rows,
    cellSize: field.cellSize,
    originX: field.originX,
    originY: field.originY,
    coreRadius: core,
    alpha: alpha,
  );
});

/// Whether to overlay the pressure heatmap on the canvas.
final showHeatmapProvider =
    NotifierProvider<ShowHeatmapController, bool>(ShowHeatmapController.new);

class ShowHeatmapController extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
}

/// Real §10 length of [e] with the PROJECT's calibrations, building AND mounting
/// heights — the exact inputs `sizingProvider` hands `autoSizeNetwork`, so every
/// printed / displayed length (plan PDF/DXF labels, inspector, BOM) equals the
/// solved one (audit water-drainage-8: the display paths used the default
/// MountingHeights while the solve used the project's, so a riser to a ceiling
/// main printed a different length than it was sized on).
Length projectEdgeLength(NetEdge e, Network net, ProjectState project) =>
    edgeLength(
      e,
      net,
      calibrationBySheet: project.calibrations,
      building: project.building,
      mounting: project.mounting,
    );

/// [projectEdgeLength] for every edge of [net], keyed by edge id.
Map<String, Length> projectEdgeLengths(Network net, ProjectState project) => {
      for (final e in net.edges) e.id: projectEdgeLength(e, net, project),
    };
