import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/hydraulics.dart'
    show headFromPressure, pressureFromHead;
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
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

import 'app_state.dart';
import 'network_store.dart';
import 'project_store.dart';
import 'sizing_store.dart';

Pressure get _targetResidual =>
    SupplyDesignCriteria.recommended().targetFixtureResidualPressure;

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
    final max = gravity
        ? profile.maxDrainVelocity.value
        : profile.maxSupplyVelocity.value;
    final min = e.service == ServiceType.drainage
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
    var unit = root;
    if (net.nodeById(root)?.role != NodeRole.plant) {
      final machines = [
        for (final n in net.nodes)
          if (roots[n.id] == root &&
              n.role == NodeRole.plant &&
              (n.component?.isElectricalLoad ?? false))
            n.id,
      ]..sort();
      if (machines.isNotEmpty) unit = machines.first;
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
    (maxFix.pascals - _targetResidual.pascals).clamp(1.0, double.infinity),
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
    prvSetpoint: _targetResidual,
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

/// Hot-water recirculation design for the drawn hot-water network: the loop is
/// the total hot-water pipe length, heat loss is estimated per metre, and the
/// return diameter defaults to the smallest hot-water size. Null when there's
/// no hot-water network.
final hotWaterRecircProvider = Provider<HotWaterRecircDesign?>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  final project = ref.watch(projectControllerProvider);
  final hwEdges =
      net.edges.where((e) => e.service == ServiceType.hotWater).toList();
  if (hwEdges.isEmpty) return null;

  var lenM = 0.0;
  var minDia = double.infinity;
  for (final e in hwEdges) {
    lenM += edgeLength(
      e,
      net,
      calibrationBySheet: project.calibrations,
      building: project.building,
      mounting: project.mounting,
    ).meters;
    final s = sizing[e.id];
    if (s != null) minDia = math.min(minDia, s.diameter.meters);
  }
  if (lenM <= 0) return null;
  final loop = Length(lenM);
  return sizeHotWaterRecirculation(
    heatLoss: heatLossFromLength(loopLength: loop),
    loopLength: loop,
    returnDiameter: minDia.isFinite ? Diameter(minDia) : Diameter.mm(20),
    // M14 — the flow temperature and allowable loop drop are DESIGN INPUTS
    // (Building page), not engine constants: they set the recirc flow AND the
    // modelled return temperature the anti-Legionella check judges. The
    // defaults (60 °C / 5 K) reproduce the engine's own values exactly, so an
    // untouched project is byte-identical — but a project that departs (55 °C
    // stored, or a 10 K drop) now actually trips the check.
    flowTempC: ref.watch(hotWaterFlowTempProvider),
    allowableDropK: ref.watch(hotWaterDeltaTProvider),
  );
});

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
