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
import 'package:mechx_engine/sizing/ejector.dart';
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
    // Round 22 (pressurized-3-2) — a drawn PRV holds the same setpoint on the
    // upfeed as on the downfeed, so the over-pressure remedy works.
    prvSetpoint: _prvSetpoint,
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
  // Round 22 (pressurized-3-3) — judged on what the drawn system DELIVERS,
  // sized boosters running.
  // Round 25 follow-up — no drawn roof tank ⇒ no gravity field to judge.
  if (!ref.watch(gravityDownfeedDrawnProvider)) return const [];
  final solution = ref.watch(downfeedDeliveredProvider);
  if (solution == null) return const [];
  return downfeedOverPressure(solution);
});

/// Round 25 (ui-journeys-4-direct-mains-feed-contradiction) — THE drawn-feed
/// predicate: a downfeed SETTING whose gravity source is actually drawn (a
/// roof tank on the network). [downfeedProvider] solves from the highest node
/// whenever the strategy is downfeed — with no tank that is a phantom source
/// (a meter or a fixture), so its booster head / top residual / zone verdict
/// describe a tank that does not exist. The inspector headline + rows, the
/// calc report and the Review pressure judgement all gate on THIS, so the four
/// surfaces describe one feed.
///
/// Round 26 (regression-untyped-roof-source-downfeed-silenced) — the gravity
/// source test is the ONE Round-23 rule [downfeedTankElevationProvider]
/// encodes (a roof tank, OR a plant above the top-storey fixture — the
/// untyped 'Source / tank' on the top storey sits at the roof), never a
/// roofTank-only component check: a generic roof plant feeding a downfeed is
/// judged exactly like a typed roof tank. A drawn supply network with a
/// pickable source is still required — with nothing drawn the tank-elevation
/// provider returns the declared roof datum, and an empty network stays
/// un-judged.
final gravityDownfeedDrawnProvider = Provider<bool>((ref) {
  if (ref.watch(feedStrategyProvider) != FeedStrategy.downfeed) return false;
  final net = ref.watch(sizingNetworkProvider);
  final project = ref.watch(projectControllerProvider);
  final edges = _supplyEdges(net);
  if (edges.isEmpty) return false;
  final source = _pickSource(net, edges, project.building,
      preferHighest: true, mounting: project.mounting);
  if (source == null || net.nodeById(source) == null) return false;
  return ref.watch(downfeedTankElevationProvider) != null;
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

/// Round 22 (pressurized-3-3) — the DOWNFEED field the drawn system actually
/// delivers: the gravity solve with every sized non-transfer mover
/// ([supplyMoverDutiesProvider]) adding its head to what it serves. With no
/// sized booster it IS [downfeedProvider] (same object). [downfeedProvider]
/// stays the UNBOOSTED field the booster duties are sized on; the heatmap,
/// node probe and over-pressure judgement read this one.
final downfeedDeliveredProvider = Provider<DownfeedSolution?>((ref) {
  final base = ref.watch(downfeedProvider);
  if (base == null) return null;
  final transfers = ref.watch(transferPumpNodeIdsProvider);
  final heads = <String, Head>{
    for (final e in ref.watch(supplyMoverDutiesProvider).entries)
      if (!transfers.contains(e.key) && e.value.head.meters > 0)
        e.key: e.value.head,
  };
  if (heads.isEmpty) return base;
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  final project = ref.watch(projectControllerProvider);
  final edges = _supplyEdges(net);
  final tank = _pickSource(net, edges, project.building,
      preferHighest: true, mounting: project.mounting);
  if (tank == null) return base;
  return solveDownfeed(
    net: net,
    service: kSupplyService,
    tankId: tank,
    edgeFlows: _supplyFlows(edges, sizing),
    sizing: sizing,
    calibrationBySheet: project.calibrations,
    building: project.building,
    targetResidual: _targetResidual,
    mounting: project.mounting,
    prvSetpoint: _prvSetpoint,
    moverHeads: heads,
  );
});

/// Round 32 (binding-1) — the SNI 8153 MINIMUM residual a solve's critical
/// node must meet: [SniProfile.minResidualPressureFlushValve] (1 kgf/cm²,
/// ≈98 kPa) when a flush-valve fixture ([flushValveNodeIds]) lies on the
/// supply path from [sourceId] to [criticalNodeId] (the critical node itself
/// included), else [SniProfile.minResidualPressureFaucet] (0.5 kgf/cm²,
/// ≈49 kPa). Path-derived, never project-wide: a flush-valve WC on another
/// branch does not raise the floor of a faucet-fed critical node. A missing
/// source / unreachable critical node reads the critical node alone.
///
/// The path is an unweighted, id-ordered BFS over every supply edge from the
/// SAME source the solve uses (upfeed `preferHighest: false`, downfeed
/// `preferHighest: true`). On a tree that is the unique supply path. On a
/// LOOPED (Hardy–Cross) supply the fewest-hop route need not be the
/// hydraulic one, so a flush valve on the other ring leg can be missed or
/// wrongly counted — a recorded approximation, not a hydraulic path.
Pressure sniMinimumResidualAt({
  required Network net,
  required String? sourceId,
  required String criticalNodeId,
  required Set<String> flushValveNodeIds,
  SniProfile profile = const SniProfile(),
}) {
  final onPath = <String>{criticalNodeId};
  if (sourceId != null && sourceId != criticalNodeId) {
    final adj = <String, List<String>>{};
    for (final e in _supplyEdges(net)) {
      adj.putIfAbsent(e.fromId, () => []).add(e.toId);
      adj.putIfAbsent(e.toId, () => []).add(e.fromId);
    }
    for (final l in adj.values) {
      l.sort();
    }
    final parent = <String, String?>{sourceId: null};
    final queue = <String>[sourceId];
    for (var i = 0; i < queue.length; i++) {
      final here = queue[i];
      if (here == criticalNodeId) break;
      for (final next in adj[here] ?? const <String>[]) {
        if (parent.containsKey(next)) continue;
        parent[next] = here;
        queue.add(next);
      }
    }
    if (parent.containsKey(criticalNodeId)) {
      String? cur = criticalNodeId;
      while (cur != null) {
        onPath.add(cur);
        cur = parent[cur];
      }
    }
  }
  return onPath.any(flushValveNodeIds.contains)
      ? profile.minResidualPressureFlushValve.value
      : profile.minResidualPressureFaucet.value;
}

/// Round 32 (binding-1) — the SNI minimum at the UPFEED solve's critical node
/// (null with no upfeed solve).
final upfeedSniMinimumResidualProvider = Provider<Pressure?>((ref) {
  final up = ref.watch(solveProvider);
  if (up == null) return null;
  final net = ref.watch(sizingNetworkProvider);
  final project = ref.watch(projectControllerProvider);
  final source = _pickSource(net, _supplyEdges(net), project.building,
      preferHighest: false, mounting: project.mounting);
  return sniMinimumResidualAt(
    net: net,
    sourceId: source,
    criticalNodeId: up.criticalNodeId,
    flushValveNodeIds: ref.watch(supplyFlushValveNodeIdsProvider),
  );
});

/// Round 32 (binding-1) — the SNI minimum at the DELIVERED downfeed solve's
/// critical node (null with no downfeed solve).
final downfeedSniMinimumResidualProvider = Provider<Pressure?>((ref) {
  final down = ref.watch(downfeedDeliveredProvider);
  if (down == null) return null;
  final net = ref.watch(sizingNetworkProvider);
  final project = ref.watch(projectControllerProvider);
  final tank = _pickSource(net, _supplyEdges(net), project.building,
      preferHighest: true, mounting: project.mounting);
  return sniMinimumResidualAt(
    net: net,
    sourceId: tank,
    criticalNodeId: down.criticalNodeId,
    flushValveNodeIds: ref.watch(supplyFlushValveNodeIdsProvider),
  );
});

/// Residual pressure at every solved node, regardless of feed strategy — the
/// single field the heatmap renders (§12). Round 22: the downfeed field is the
/// DELIVERED one ([downfeedDeliveredProvider], sized boosters running).
final residualByNodeProvider = Provider<Map<String, Pressure>>((ref) {
  final up = ref.watch(solveProvider);
  if (up != null) return up.residualPressure;
  // Round 25 follow-up — a downfeed SETTING with no roof tank drawn has no
  // gravity source: its solve runs from a phantom (the highest node), so the
  // heatmap / node probe must not paint that field while the inspector, calc
  // report and Review all say 'no roof tank drawn' ([gravityDownfeedDrawnProvider]).
  if (!ref.watch(gravityDownfeedDrawnProvider)) return const {};
  final down = ref.watch(downfeedDeliveredProvider);
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
            ? ref.watch(sizingContextProvider).maxFireVelocity
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
      // Round 27 — THIS system's curve branch (residuals-6).
      flushSystem: flushSystemForRoot(net, kSupplyService, root,
          ref.watch(supplyFlushValveNodeIdsProvider)),
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

/// Round 30 (mech-sim-4-ejector-pump-no-duty-no-schedule) — the solved duty
/// of every drawn SEWAGE EJECTOR (a pump / booster set on the drainage
/// service), keyed by node id: the pit's DFU inflow at the lift + friction of
/// its force main (`sizing/ejector.dart`). The panel feed and the equipment
/// schedule read it, so the MDP way and the schedule describe the same
/// machine (it used to be fed the 1.5 kW component default with no row).
final ejectorDutiesProvider = Provider<Map<String, PumpDuty>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final ids = drawnEjectorPumpIds(net);
  if (ids.isEmpty) return const {};
  final sizing = ref.watch(sizingProvider);
  final fu = ref.watch(edgeFixtureUnitsProvider);
  final project = ref.watch(projectControllerProvider);
  final out = <String, PumpDuty>{};
  for (final id in ids) {
    final d = ejectorPumpDuty(
      net: net,
      pumpId: id,
      sizing: sizing,
      edgeFixtureUnits: fu,
      building: project.building,
      mounting: project.mounting,
      calibrationBySheet: project.calibrations,
    );
    if (d != null) out[id] = d;
  }
  return out;
});

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
            flushSystem: flushSystemForRoot(net, kSupplyService, root,
                ref.watch(supplyFlushValveNodeIdsProvider)),
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
/// rooted at. Round 31 (hvac-5-3): [intake] is the part of [stat] spent on
/// the unit's outdoor-air intake path (0 when none is drawn).
typedef AirSystem = ({
  FlowRate trunk,
  Pressure stat,
  String fanNodeId,
  Pressure intake,
});

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
    out.add((
      trunk: trunk,
      stat: s.totalStaticPressure,
      fanNodeId: unit,
      intake: s.intakeStaticPressure,
    ));
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
    // Round 31 (hvac-5-3) — the outdoor-air INTAKE and a RETURN drawn to the
    // same unit enter its mixing box in PARALLEL, so the inlet side governs
    // at max(intake, return), never their sum: (supply index excluding the
    // intake) + max(intake, return) + internal. With no return the intake
    // stays in series with the supply (Round 27).
    final supplyIndexPa = s.stat.pascals - s.intake.pascals;
    final inletPa = ret == null
        ? s.intake.pascals
        : math.max(s.intake.pascals, ret.stat.pascals);
    out[s.fanNodeId] = sizeFan(
      airflow: s.trunk,
      totalStaticPressure: Pressure(
          supplyIndexPa + inletPa + internalOf(s.fanNodeId).pascals),
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
///
/// Round 22 (pressurized-3-1) — the TOP zone is fed straight from the roof
/// tank ([downfeedTankElevationProvider]): it spans every floor the tank's
/// own gravity head keeps under the limit, with no PRV (a PRV cannot raise
/// pressure); only the floors below it take PRV stations. A building the tank
/// head never over-pressures is one zone with no PRV.
final zonesProvider = Provider<List<PressureZone>>((ref) {
  final project = ref.watch(projectControllerProvider);
  final maxFix = const SniProfile().maxFixtureStaticPressure.value;
  final effective = Pressure(
    (maxFix.pascals - _prvSetpoint.pascals).clamp(1.0, double.infinity),
  );
  // The span is ceiling(top) − fixture(bottom), so it must use the PROJECT
  // mounting heights (F8) — the same ones the solves/BOM/report use.
  // Round 30 (mech-sim-4-phantom-basement-prv-zone) — with a supply network
  // drawn, the walk stops at the lowest floor carrying a cold / hot water
  // DELIVERY node: a fixture-less basement the riser only passes opens no
  // PRV station. Nothing drawn ⇒ the full-building walk.
  final net = ref.watch(sizingNetworkProvider);
  final waterIds = <String>{
    for (final e in net.edges)
      if (e.service == ServiceType.coldWater ||
          e.service == ServiceType.hotWater) ...[e.fromId, e.toId],
  };
  int? lowest;
  for (final n in net.nodes) {
    if (n.role != NodeRole.fixture || !waterIds.contains(n.id)) continue;
    if (lowest == null || n.floorIndex < lowest) lowest = n.floorIndex;
  }
  return computeDownfeedZones(
    building: project.building,
    mounting: project.mounting,
    maxStaticPressure: effective,
    tankElevation: ref.watch(downfeedTankElevationProvider),
    maxFixtureStatic: maxFix,
    lowestServedFloor: lowest ?? 0,
  );
});

/// Round 22 (pressurized-3-1) — the elevation of the DOWNFEED source the zone
/// table hangs from: the drawn tank the gravity solve picks (its role-aware
/// [nodeElevation]).
///
/// Round 23 (regression-zones-phantom-roof-tank-datum) — NULL unless a real
/// gravity tank feeds the top zone: on UPFEED the pump holds the target at the
/// top fixture (no tank head exists, the legacy PRV-budget walk applies), and
/// a downfeed whose picked source is NOT a roof tank / a plant above the top
/// fixture (a ground booster with no roof tank drawn) has no tank head either
/// (a downfeed with nothing drawn yet keeps the declared roof-tank datum)
/// — hanging the zones off a phantom roof tank or a ground pump reported one
/// zone and 'tank head OK' for a pressurized building.
final downfeedTankElevationProvider = Provider<Length?>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final project = ref.watch(projectControllerProvider);
  if (ref.watch(feedStrategyProvider) != FeedStrategy.downfeed) return null;
  final edges = _supplyEdges(net);
  final tank = edges.isEmpty
      ? null
      : _pickSource(net, edges, project.building,
          preferHighest: true, mounting: project.mounting);
  final node = tank == null ? null : net.nodeById(tank);
  // Nothing drawn yet: the downfeed strategy itself declares a roof tank, at
  // the datum a roof tank defaults to.
  if (node == null) return project.building.roofElevation;
  final elev = nodeElevation(node, project.building, project.mounting);
  final topFixture = project.building.fixtureElevationOf(
      project.building.levelCount - 1, project.mounting);
  // Round 26 — a PLANT above the top fixture (the invariant's wording): a
  // bare top-storey main junction (the highest node when no plant is drawn)
  // is not a tank, whatever its ceiling elevation.
  final isGravityTank = node.component == NodeComponent.roofTank ||
      (node.role == NodeRole.plant && elev.meters > topFixture.meters);
  return isGravityTank ? elev : null;
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
    tankElevation: ref.watch(downfeedTankElevationProvider),
  );
});

/// Bill of materials for the sized network.
final bomProvider = Provider<List<BomLine>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  if (sizing.isEmpty) return const [];
  final project = ref.watch(projectControllerProvider);
  final drawn = buildBom(
    net: net,
    sizing: sizing,
    calibrationBySheet: project.calibrations,
    building: project.building,
    mounting: project.mounting,
  );
  // Round 26 (hot-water-2-mirrored-return-missing-from-bom) — the DN20
  // return the recirculation calculation ASSUMES when none is drawn (its
  // length drives the heat loss + head, and the riser sheet draws it as HWR)
  // is taken off too, flagged `assumed` and tagged so it never reads as
  // measured drawn work.
  final assumed = [
    for (final sys in ref.watch(hotWaterRecircSystemsProvider))
      if (!sys.drawnReturn && sys.assumedReturnLengthM > 0)
        BomLine(
          service: ServiceType.hotWater,
          kind: EdgeKind.run,
          diameterMm: kDefaultRecircReturnDiameter.inMillimeters.round(),
          totalLength: Length(sys.assumedReturnLengthM),
          segmentCount: 1,
          material: 'PPR',
          tag: 'HWR-ASSUMED',
          assumed: true,
        ),
  ];
  return assumed.isEmpty ? drawn : [...drawn, ...assumed];
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

/// Round 26 (hot-water-2-separate-systems-merged) — ONE hot-water
/// recirculation system per hot-water connected component (keyed by the
/// component's [serviceComponentRoots] root): its design, its node set (which
/// drawn HW pump carries it) and the ASSUMED return the calculation relies on
/// when none is drawn.
@immutable
class HotWaterRecircSystem {
  /// The component's source / root node id.
  final String rootId;

  /// The sized recirculation duty of THIS system.
  final HotWaterRecircDesign design;

  /// True when the loop is a DRAWN return (no assumed DN20 return).
  final bool drawnReturn;

  /// The length of the ASSUMED DN20 return the heat loss + head include when
  /// no return is drawn (0 when drawn) — taken off as an 'assumed' BOM line.
  final double assumedReturnLengthM;

  /// Every node of the hot-water component.
  final Set<String> nodeIds;

  const HotWaterRecircSystem({
    required this.rootId,
    required this.design,
    required this.drawnReturn,
    required this.assumedReturnLengthM,
    required this.nodeIds,
  });
}

/// Every hot-water recirculation system of the drawn network, ordered by
/// recirculation flow (largest first, ties by root id) — the first is the
/// PRIMARY system ([hotWaterRecircProvider]).
///
/// Round 16 (plumbing-plant-hw-recirc-loop-head) — each loop is the CIRCULATED
/// pipework only ([hotWaterRecircLoops]): the mains / risers the recirculation
/// keeps hot, never the fixture branches. Heat loss is 25 W/m over that
/// pipework plus the assumed return leg (one return run back along the index
/// path at [kDefaultRecircReturnDiameter] — `// VERIFY`), and the head is the
/// index run's friction at each segment's OWN sized bore plus the return leg.
/// Round 26 — PARALLEL drawn loops each carry their heat-loss share of the
/// flow (shared trunks the sum); two heaters are two systems; a system with no
/// return drawn, no hot-water pump drawn and a developed length ≤
/// [kRecircMinDevelopedLengthM] assumes no recirculation at all.
final hotWaterRecircSystemsProvider =
    Provider<List<HotWaterRecircSystem>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  final project = ref.watch(projectControllerProvider);
  final loops = hotWaterRecircLoops(net, sizing,
      lengthOf: (e) => edgeLength(
            e,
            net,
            calibrationBySheet: project.calibrations,
            building: project.building,
            mounting: project.mounting,
          ).meters);
  final flowTemp = ref.watch(hotWaterFlowTempProvider);
  final dT = ref.watch(hotWaterDeltaTProvider);
  final out = <HotWaterRecircSystem>[];
  for (final loop in loops) {
    final design = sizeHotWaterRecirculation(
      heatLoss: heatLossFromLength(
          loopLength: Length(loop.circulatedLengthM + loop.returnLengthM)),
      loopLength: Length(loop.returnLengthM),
      returnDiameter: kDefaultRecircReturnDiameter,
      supplyPath: loop.indexPath,
      supplyPathFlowShares: loop.indexFlowShares,
      // M14 — the flow temperature and allowable loop drop are DESIGN INPUTS
      // (Building page), not engine constants.
      flowTempC: flowTemp,
      allowableDropK: dT,
    );
    // Round 17 follow-up — a DRAWN return: the reported loop length is the
    // drawn loop the head was computed around (no phantom DN20 leg added).
    final drawn = loop.drawnLoopLengthM;
    out.add(HotWaterRecircSystem(
      rootId: loop.rootId,
      design: drawn == null
          ? design
          : HotWaterRecircDesign(
              recircFlow: design.recircFlow,
              loopHead: design.loopHead,
              pump: design.pump,
              returnTempC: design.returnTempC,
              loopLength: Length(drawn),
            ),
      drawnReturn: drawn != null,
      assumedReturnLengthM: drawn == null ? loop.returnLengthM : 0,
      nodeIds: loop.nodeIds,
    ));
  }
  out.sort((a, b) {
    final c = b.design.recircFlow.cubicMetersPerSecond
        .compareTo(a.design.recircFlow.cubicMetersPerSecond);
    return c != 0 ? c : a.rootId.compareTo(b.rootId);
  });
  return out;
});

/// The PRIMARY hot-water recirculation design (the largest system of
/// [hotWaterRecircSystemsProvider]). Null when no hot-water pipework needs
/// recirculation.
final hotWaterRecircProvider = Provider<HotWaterRecircDesign?>((ref) {
  final systems = ref.watch(hotWaterRecircSystemsProvider);
  return systems.isEmpty ? null : systems.first.design;
});

/// Round 26 (hot-water-2-phantom-hwr-leg-on-drawn-return) — true when some
/// hot-water system's recirculation relies on an ASSUMED (undrawn) return:
/// the ONE signal the riser canvas + export draw the dashed HWR leg on. A
/// drawn return is drawn as itself — never a second phantom leg beside it.
final hotWaterAssumedReturnProvider = Provider<bool>((ref) => ref
    .watch(hotWaterRecircSystemsProvider)
    .any((s) => !s.drawnReturn));

/// One hot-water recirculation loop of [hotWaterRecircLoops].
typedef HotWaterRecircLoop = ({
  String rootId,
  double circulatedLengthM,
  double returnLengthM,
  List<({Length length, Diameter diameter})> indexPath,
  List<double>? indexFlowShares,
  double? drawnLoopLengthM,
  Set<String> nodeIds,
});

/// The PRIMARY loop of [hotWaterRecircLoops] — the single-system view. Null
/// when nothing needs recirculation. Round 26 r2 — the SAME primary as
/// [hotWaterRecircSystemsProvider]: the largest recirculation FLOW, which is
/// proportional to the heat-losing pipework (circulated + assumed return,
/// [heatLossFromLength] at one flow temperature / ΔT for every system), ties
/// by root id.
HotWaterRecircLoop? hotWaterRecircLoop(
  Network net,
  Map<String, EdgeSizing> sizing, {
  required double Function(NetEdge e) lengthOf,
  double minDevelopedLengthM = kRecircMinDevelopedLengthM,
}) {
  final loops = hotWaterRecircLoops(net, sizing,
      lengthOf: lengthOf, minDevelopedLengthM: minDevelopedLengthM);
  if (loops.isEmpty) return null;
  final sorted = [...loops]..sort((a, b) {
      final c = (b.circulatedLengthM + b.returnLengthM)
          .compareTo(a.circulatedLengthM + a.returnLengthM);
      return c != 0 ? c : a.rootId.compareTo(b.rootId);
    });
  return sorted.first;
}

/// Shortest-path distances (by [lengthOf]) from [src] over [adj] — Dijkstra
/// with equal-length ties broken by node id, so the result never depends on
/// edge ids or drawing order (Round 26, hot-water-2-ring-index-run-bfs-id-
/// dependent: a hop-order BFS took whichever ring branch sorted first).
({Map<String, double> dist, Map<String, NetEdge> via}) _shortestPaths(
  Map<String, List<NetEdge>> adj,
  String src,
  double Function(NetEdge e) lengthOf,
) {
  final dist = <String, double>{src: 0};
  final via = <String, NetEdge>{};
  final done = <String>{};
  String otherEnd(NetEdge e, String n) => e.fromId == n ? e.toId : e.fromId;
  while (true) {
    String? best;
    for (final en in dist.entries) {
      if (done.contains(en.key)) continue;
      final b = best;
      if (b == null ||
          en.value < dist[b]! - 1e-12 ||
          ((en.value - dist[b]!).abs() <= 1e-12 && en.key.compareTo(b) < 0)) {
        best = en.key;
      }
    }
    if (best == null) break;
    done.add(best);
    final d = dist[best]!;
    for (final e in adj[best] ?? const <NetEdge>[]) {
      final m = otherEnd(e, best);
      if (done.contains(m)) continue;
      final nd = d + lengthOf(e);
      final old = dist[m];
      if (old == null || nd < old - 1e-12) {
        dist[m] = nd;
        via[m] = e;
      } else if ((nd - old).abs() <= 1e-12) {
        // Equal length: keep the predecessor with the lower NODE id.
        final cur = via[m];
        if (cur != null && best.compareTo(otherEnd(cur, m)) < 0) via[m] = e;
      }
    }
  }
  return (dist: dist, via: via);
}

/// Round 16 / 26 — the CIRCULATED hot-water pipework of [net], one loop per
/// hot-water connected component that needs recirculation (pure; testable
/// without a container): every hot-water edge with NO fixture-role endpoint
/// and no bare open-ended leaf (a dead leg the recirculation never reaches),
/// its total length, and the INDEX run from the component's source (the
/// longest circulated path by length, each segment at its sized bore) whose
/// length the return leg mirrors. A component with no DRAWN return and no
/// drawn hot-water pump whose developed length (source → farthest fixture) is
/// at or below [minDevelopedLengthM] is omitted — no recirculation is assumed.
List<HotWaterRecircLoop> hotWaterRecircLoops(
  Network net,
  Map<String, EdgeSizing> sizing, {
  required double Function(NetEdge e) lengthOf,
  double minDevelopedLengthM = kRecircMinDevelopedLengthM,
}) {
  final hwAll = [
    for (final e in net.edges)
      if (e.service == ServiceType.hotWater) e,
  ];
  if (hwAll.isEmpty) return const [];
  final roots = serviceComponentRoots(net, ServiceType.hotWater,
      demandNodeIds: {
        for (final n in net.nodes)
          if (n.role == NodeRole.fixture) n.id,
      });
  final byRoot = <String, List<NetEdge>>{};
  for (final e in hwAll) {
    final r = roots[e.fromId] ?? roots[e.toId];
    if (r == null) continue;
    (byRoot[r] ??= []).add(e);
  }
  final out = <HotWaterRecircLoop>[];
  for (final root in byRoot.keys.toList()..sort()) {
    final loop = _hotWaterRecircLoopOf(net, sizing, byRoot[root]!, root, roots,
        lengthOf: lengthOf, minDevelopedLengthM: minDevelopedLengthM);
    if (loop != null) out.add(loop);
  }
  return out;
}

/// True when [nodeIds] (one hot-water component) holds a drawn pump /
/// booster set that serves hot water only — not the cold-water supply, not a
/// fire service (mirrors the HW recirc pump test of the duty binding).
bool _hasDrawnHotWaterPump(Network net, Set<String> nodeIds) {
  for (final id in nodeIds) {
    final c = net.nodeById(id)?.component;
    if (c != NodeComponent.pump && c != NodeComponent.boosterSet) continue;
    final svc = {
      for (final e in net.edges)
        if (e.fromId == id || e.toId == id) e.service,
    };
    if (svc.contains(ServiceType.hotWater) &&
        !svc.contains(kSupplyService) &&
        !svc.contains(ServiceType.fireHydrant) &&
        !svc.contains(ServiceType.fireSprinkler)) {
      return true;
    }
  }
  return false;
}

HotWaterRecircLoop? _hotWaterRecircLoopOf(
  Network net,
  Map<String, EdgeSizing> sizing,
  List<NetEdge> hw,
  String root,
  Map<String, String> roots, {
  required double Function(NetEdge e) lengthOf,
  required double minDevelopedLengthM,
}) {
  final degree = <String, int>{};
  for (final e in hw) {
    degree[e.fromId] = (degree[e.fromId] ?? 0) + 1;
    degree[e.toId] = (degree[e.toId] ?? 0) + 1;
  }
  final nodeIds = degree.keys.toSet();
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
  for (final l in adj.values) {
    l.sort((a, b) => a.id.compareTo(b.id));
  }
  // A component whose source sits on a dead leg starts from the circulated
  // node nearest it (deterministic: the lowest-id circulated node).
  final src =
      adj.containsKey(root) ? root : (adj.keys.toList()..sort()).first;

  // Round 17 follow-up / Round 19 — a DRAWN return closes a cycle in the
  // circulated pipework through the source / a plant or a check valve (a
  // stub-fed RING MAIN is distribution, not a return). When such cycles exist
  // they ARE the loops: no phantom return.
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

  final returnCycles = <List<NetEdge>>[];
  {
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
        if (isReturnCycle(cycle)) returnCycles.add(cycle);
      }
    }
  }
  if (returnCycles.isNotEmpty) {
    // Round 26 (hot-water-2-multi-loop-full-flow-one-loop) — the loops run in
    // PARALLEL: each carries the share of the circulating flow its own
    // pipework loses (a segment shared by n loops splits its length n ways;
    // circulated pipework on no loop is spread pro rata), and a segment
    // carries the SUM of the shares of the loops through it. The index loop
    // is the one with the greatest friction at those flows (Hazen–Williams
    // h ∝ Σ s^1.852 · L / D^4.871 — the common Q factor cancels).
    final count = <String, int>{};
    for (final c in returnCycles) {
      for (final e in c) {
        count[e.id] = (count[e.id] ?? 0) + 1;
      }
    }
    final loopHeat = [
      for (final c in returnCycles)
        c.fold<double>(0, (a, e) => a + lengthOf(e) / count[e.id]!),
    ];
    final heatSum = loopHeat.fold<double>(0, (a, b) => a + b);
    final shareOf = [
      for (final h in loopHeat)
        heatSum > 0 ? h / heatSum : 1.0 / returnCycles.length,
    ];
    final edgeShare = <String, double>{};
    for (var i = 0; i < returnCycles.length; i++) {
      for (final e in returnCycles[i]) {
        edgeShare[e.id] = (edgeShare[e.id] ?? 0) + shareOf[i];
      }
    }
    double dOf(NetEdge e) =>
        (sizing[e.id]?.diameter ?? kDefaultRecircReturnDiameter).meters;
    var bestI = 0;
    var bestH = -1.0;
    var bestLen = 0.0;
    for (var i = 0; i < returnCycles.length; i++) {
      var h = 0.0;
      var len = 0.0;
      for (final e in returnCycles[i]) {
        final l = lengthOf(e);
        len += l;
        final d = dOf(e);
        if (l <= 0 || d <= 0) continue;
        h += math.pow(edgeShare[e.id]!, 1.852).toDouble() *
            l /
            math.pow(d, 4.871).toDouble();
      }
      if (h > bestH * (1 + 1e-12) + 1e-300 ||
          ((h - bestH).abs() <= bestH.abs() * 1e-12 && len > bestLen + 1e-12)) {
        bestH = h;
        bestI = i;
        bestLen = len;
      }
    }
    final index = returnCycles[bestI];
    final single = returnCycles.length == 1;
    return (
      rootId: root,
      circulatedLengthM: total,
      returnLengthM: 0.0,
      indexPath: [
        for (final e in index)
          (
            length: Length(lengthOf(e)),
            diameter: sizing[e.id]?.diameter ?? kDefaultRecircReturnDiameter,
          ),
      ],
      indexFlowShares:
          single ? null : [for (final e in index) edgeShare[e.id]!],
      drawnLoopLengthM: index.fold<double>(0, (a, e) => a + lengthOf(e)),
      nodeIds: nodeIds,
    );
  }

  // Round 26 (hot-water-2-house-fabricated-recirc-pump) — with NO return
  // drawn, recirculation is only ASSUMED where the developed length (source →
  // farthest hot-water fixture, over every hot-water pipe) exceeds the
  // threshold (IPC 607.2, `// VERIFY`): a house gets no pump, way or HWR leg.
  // Round 26 r2 — a pump / booster DRAWN on the hot-water service (the same
  // test [mepDutyBindingProvider] uses for a HW recirc pump: not on the
  // cold-water or a fire service) is an explicit recirculation signal: the
  // gate never silences the engineer's drawn circulator.
  final drawnPump = _hasDrawnHotWaterPump(net, nodeIds);
  final allAdj = <String, List<NetEdge>>{};
  for (final e in hw) {
    (allAdj[e.fromId] ??= []).add(e);
    (allAdj[e.toId] ??= []).add(e);
  }
  final dev = _shortestPaths(
      allAdj, allAdj.containsKey(root) ? root : src, lengthOf);
  var developed = 0.0;
  for (final en in dev.dist.entries) {
    if (net.nodeById(en.key)?.role != NodeRole.fixture) continue;
    if (en.value > developed) developed = en.value;
  }
  if (!drawnPump && developed <= minDevelopedLengthM + 1e-9) return null;

  // Index run: the longest circulated path (by length) from the source, on
  // SHORTEST-path distances (Round 26 — Dijkstra, never hop order).
  final sp = _shortestPaths(adj, src, lengthOf);
  var bestLen = 0.0;
  String? far;
  final entries = sp.dist.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  for (final en in entries) {
    if (en.value <= bestLen + 1e-12) continue;
    bestLen = en.value;
    far = en.key;
  }
  final path = <NetEdge>[];
  var cur = far;
  while (cur != null && sp.via[cur] != null) {
    final e = sp.via[cur]!;
    path.add(e);
    cur = e.fromId == cur ? e.toId : e.fromId;
  }
  final bestPath = path.reversed.toList();
  return (
    rootId: root,
    circulatedLengthM: total,
    returnLengthM: bestLen,
    indexPath: [
      for (final e in bestPath)
        (
          length: Length(lengthOf(e)),
          diameter: sizing[e.id]?.diameter ?? kDefaultRecircReturnDiameter,
        ),
    ],
    indexFlowShares: null,
    drawnLoopLengthM: null,
    nodeIds: nodeIds,
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
  final drawn =
      buildComponentTakeoff(net: net, sizing: ref.watch(sizingProvider));
  // Round 26 — the recirculation pump an ASSUMED (undrawn) return relies on,
  // when no pump / booster is drawn on that hot-water system.
  final assumed = [
    for (final sys in ref.watch(hotWaterRecircSystemsProvider))
      if (!sys.drawnReturn &&
          !sys.nodeIds.any((id) {
            final c = net.nodeById(id)?.component;
            return c == NodeComponent.pump || c == NodeComponent.boosterSet;
          }))
        ComponentLine(
          service: ServiceType.hotWater,
          component: NodeComponent.pump,
          sizeLabel:
              '${sys.design.pump.selectedMotor.inKiloWatts.toStringAsFixed(2)} kW',
          count: 1,
          assumed: true,
        ),
  ];
  return assumed.isEmpty ? drawn : [...drawn, ...assumed];
});

/// Estimated fittings (elbows/tees/crosses/reducers) for the sized network.
final fittingsProvider = Provider<List<FittingLine>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  if (sizing.isEmpty) return const [];
  final project = ref.watch(projectControllerProvider);
  return buildFittings(
      net: net,
      sizing: sizing,
      building: project.building,
      mounting: project.mounting);
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
