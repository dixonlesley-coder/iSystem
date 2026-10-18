/// Node-pressure solve for a pressurized supply tree (§12 keystone: ONE solve
/// feeds pump duty, zoning, and the pressure heatmap).
///
/// MODEL — radial / tree pressurized network. Water is pushed from a single
/// source node out along a branching distribution tree. For every node we walk
/// the unique path back to the source and sum two independent head terms along
/// the way:
///   • friction head loss (Hazen–Williams) over each edge's physical run/riser
///     length, and
///   • static lift = the floor-elevation gain from the source's floor to the
///     node's floor.
/// The pump must overcome both PLUS deliver a target residual at the worst
/// (critical) node; every other node then sees ≥ that residual.
///
/// TREE TRAVERSAL (node heads): the BFS walks a spanning tree of the [service]
/// subgraph from the source, accumulating friction/elevation along each node's
/// tree path; chord edges in a loop are skipped for this walk. This is exact for
/// a tree, and stays correct for LOOPS provided the [edgeFlows] handed in are
/// already loop-BALANCED — the sizing layer balances ring/grid pressurized & air
/// flows with Hardy–Cross (`hardy_cross.dart`) before sizing, and the solve
/// consumes those per-edge flows, so head loss around each loop ≈ 0 and the node
/// head is path-independent (the tree path gives the true value). The sizing
/// balance splits ring flow by resistance ∝ real edge length at a consistent
/// ring diameter (the stable design basis); the residual loop-vs-tree friction
/// from per-segment diameter differences is second-order. // VERIFY for a final
/// design with strongly non-uniform ring segments.
///
/// FRICTION vs STATIC LIFT — NOT double-counted. A riser edge contributes its
/// vertical run to FRICTION via [edgeLength] (a riser's length is the
/// floor-elevation delta, §10) and ALSO contributes to STATIC LIFT via the
/// nodes' [NetNode.floorIndex] elevations. These are two distinct, additive
/// head terms (h_f along the pipe + ρgh static head); summing both is correct,
/// not a duplication.
///
/// MISSING DATA — degrades gracefully. An edge with no [EdgeSizing] (unsized)
/// is skipped entirely: with no diameter there is no defined friction, and a
/// skipped edge contributes zero friction. An edge with no entry in
/// [edgeFlows] is treated as carrying `FlowRate(0)`, which makes its
/// Hazen–Williams loss exactly zero. Either way an unsized/unflowed edge adds
/// 0 to the friction accumulation (documented, intentional).
///
/// PER-EDGE MATERIAL — the Hazen–Williams C is resolved per edge: an edge
/// carrying a [NetEdge.pipeProduct] uses that product's C
/// ([hazenWilliamsCFor]); an edge with no product falls back to the
/// service-wide C derived from the [material] parameter
/// ([SniProfile.hazenWilliamsC]). Only the C value is swapped — the friction
/// law stays Hazen–Williams (this is the pressurized regime; guardrail §12.4
/// keeps gravity/pressurized/air separate, so NO Darcy/roughness is introduced
/// here). With no edge product set the result is byte-identical to today.
///
/// Pure Dart, ZERO Flutter imports.
library;

import '../geometry/building.dart';
import '../geometry/scale_calibration.dart';
import '../hydraulics.dart';
import '../sizing/network_sizing.dart';
import '../standards/pipe_products.dart';
import '../standards/sni.dart';
import '../units.dart';
import 'network.dart';
import 'oriented_paths.dart';

/// Result of [solvePressurized]: the residual pressure at every reachable node,
/// the pump head the source must develop, and which node set that requirement.
class PressureSolution {
  /// Residual (flowing) pressure at each reachable node id, including the
  /// source. The [criticalNodeId]'s value ≈ the requested target residual;
  /// every other DELIVERY node's (fixture / outlet — see [_deliveryNodes])
  /// value is ≥ the target. A ceiling-level main above the fixtures can read
  /// below target (it is not a delivery point).
  final Map<String, Pressure> residualPressure;

  /// Head the source pump must develop so the worst-served DELIVERY node still
  /// meets the target residual: max over reachable delivery nodes of
  /// (friction-from-source + elevation-gain + target-as-head).
  final Head requiredPumpHead;

  /// Id of the node that drives [requiredPumpHead] (the argmax — typically the
  /// highest and/or most distant node).
  final String criticalNodeId;

  /// True when the residuals in [residualPressure] hold the design target BY
  /// CONSTRUCTION rather than as a falsifiable outcome (M9).
  ///
  /// [solvePressurized] (upfeed) DEFINES the pump head as
  /// `max over nodes of (friction + elevation + target)`, then reports
  /// `residual(node) = requiredPumpHead − friction(node) − elevation(node)`.
  /// Substituting the definition gives `residual(node) ≥ target` for every
  /// node, with equality at [criticalNodeId] — the inequality is an algebraic
  /// identity of the two formulas, not a property of the drawn network. No
  /// input (a longer run, a smaller pipe, a taller building) can make an upfeed
  /// residual fall below the target: the pump head simply rises to match. So a
  /// PASS/LOW verdict read off these residuals is unfalsifiable and must not be
  /// presented as a check — the honest label is "target held by design", with
  /// the falsifiable question being whether a real pump can deliver
  /// [requiredPumpHead].
  ///
  /// False for genuinely falsifiable results (the gravity downfeed solve: its
  /// residuals come from a FIXED tank elevation, so friction or a high fixture
  /// really can push them below target — see [DownfeedSolution]).
  final bool targetHeldByDesign;

  /// mech-building-2 — the NO-FLOW static pressure at each reachable node:
  /// the pump head less the node's elevation gain (friction vanishes at zero
  /// flow), i.e. `residual + friction`. On an upfeed the LOWEST fixtures see
  /// nearly the whole pump head, which is exactly what the SNI maximum fixture
  /// pressure / mandatory pressure-relief trigger judge. Empty for a result
  /// built without it (byte-identical for legacy constructions).
  final Map<String, Pressure> noFlowStaticPressure;

  /// The DELIVERY nodes (fixtures, else open leaves) the residual is a
  /// requirement at — the set a fixture-pressure check judges.
  final Set<String> deliveryNodeIds;

  const PressureSolution({
    required this.residualPressure,
    required this.requiredPumpHead,
    required this.criticalNodeId,
    this.targetHeldByDesign = false,
    this.noFlowStaticPressure = const {},
    this.deliveryNodeIds = const {},
  });
}

/// One upfeed DELIVERY node whose pressure exceeds the SNI fixture limits
/// (mech-building-2): [flowing] is the solved residual, [noFlow] the static
/// at zero flow. [overRelief] when the no-flow static reaches the mandatory
/// pressure-relief threshold (5 kgf/cm²); otherwise it is over the 4 kgf/cm²
/// maximum fixture pressure.
typedef UpfeedOverPressure = ({
  String nodeId,
  Pressure flowing,
  Pressure noFlow,
  bool overRelief,
});

/// JUDGE-ONLY upfeed fixture over-pressure check (mech-building-2). An upfeed
/// pump sized to hold the target at the TOP fixture delivers nearly its whole
/// head to the BOTTOM fixtures: on 8 × 3.5 m the ground-floor residual is
/// ≈ 488 kPa flowing and ≈ 491 kPa at no flow — over the SNI 8153 392 kPa
/// maximum and the 490 kPa mandatory-relief trigger — yet only the DOWNFEED
/// PRV zones (compliant by construction) were ever judged. Every delivery node
/// whose flowing residual OR no-flow static exceeds
/// [SniProfile.maxFixtureStaticPressure] is returned (worst first); never
/// resizes. Empty for a solution with no delivery set (legacy construction).
List<UpfeedOverPressure> upfeedOverPressure(
  PressureSolution solution, {
  StandardsProfile profile = const SniProfile(),
}) {
  final maxFix = profile.maxFixtureStaticPressure.value.pascals;
  final relief = profile.mandatoryPressureReliefThreshold.value.pascals;
  final out = <UpfeedOverPressure>[];
  for (final id in solution.deliveryNodeIds) {
    final flowing = solution.residualPressure[id];
    final noFlow = solution.noFlowStaticPressure[id];
    if (flowing == null || noFlow == null) continue;
    if (flowing.pascals <= maxFix && noFlow.pascals <= maxFix) continue;
    out.add((
      nodeId: id,
      flowing: flowing,
      noFlow: noFlow,
      overRelief: noFlow.pascals >= relief,
    ));
  }
  out.sort((a, b) {
    final c = b.noFlow.pascals.compareTo(a.noFlow.pascals);
    return c != 0 ? c : a.nodeId.compareTo(b.nodeId);
  });
  return out;
}

/// The DELIVERY nodes among [reached] — the points the design residual is a
/// requirement AT (audit 2026-10 water-drainage-5). The target residual is a
/// fixture/outlet requirement: a ceiling-level distribution main sits ABOVE the
/// fixtures it feeds (ceiling − fixture height ≈ 2.6 m on a 4 m storey), so
/// demanding the target there oversized the pump / booster and mis-tagged the
/// critical node. Preference:
///   1. every reached [NodeRole.fixture] node other than [sourceId];
///   2. else every reached degree-1 leaf (in the [adjacency] of this service)
///      other than [sourceId] — a drawn run's open end is where it delivers;
///   3. else every reached node (degenerate — keeps the old behaviour).
/// Residuals are still REPORTED for every node (the heatmap shows mains too).
Set<String> _deliveryNodes(
  Network net,
  Iterable<String> reached,
  String sourceId,
  Map<String, List<({NetEdge edge, String other})>> adjacency,
) {
  final fixtures = <String>{
    for (final id in reached)
      if (id != sourceId && net.nodeById(id)?.role == NodeRole.fixture) id,
  };
  if (fixtures.isNotEmpty) return fixtures;
  final leaves = <String>{
    for (final id in reached)
      if (id != sourceId && (adjacency[id]?.length ?? 0) == 1) id,
  };
  if (leaves.isNotEmpty) return leaves;
  return reached.toSet();
}

/// Internal per-node accumulation along the path from the source.
class _NodeCost {
  final Head friction;
  final Length elevationGain;

  const _NodeCost(this.friction, this.elevationGain);
}

/// Solve a pressurized supply [service] tree fed from [sourceId].
///
/// Walks the [service] subgraph from [sourceId] (BFS, skipping visited nodes
/// and ignoring edges of other services), accumulating per-edge Hazen–Williams
/// friction and per-floor elevation gain. Returns the required pump head, the
/// critical (worst-served) node, and the residual pressure at every reachable
/// node.
///
/// [edgeFlows] maps edge id → design flow (fallback `FlowRate(0)` if absent).
/// [sizing] maps edge id → its [EdgeSizing] (an edge with no entry is unsized
/// and skipped, contributing zero friction). [targetResidual] is the minimum
/// residual pressure to guarantee at the critical node.
PressureSolution solvePressurized({
  required Network net,
  required ServiceType service,
  required String sourceId,
  required Map<String, FlowRate> edgeFlows,
  required Map<String, EdgeSizing> sizing,
  required Map<String, ScaleCalibration> calibrationBySheet,
  required BuildingLevels building,
  required Pressure targetResidual,
  PipeMaterial material = PipeMaterial.pvc,
  MountingHeights mounting = const MountingHeights(),
}) {
  const profile = SniProfile();
  final hwC = profile.hazenWilliamsC(material);
  final targetHead = headFromPressure(targetResidual);

  final source = net.nodeById(sourceId);
  // Adjacency over THIS service only: nodeId → list of (edge, neighbour).
  final adjacency = <String, List<({NetEdge edge, String other})>>{};
  for (final e in net.edges) {
    if (e.service != service) continue;
    (adjacency[e.fromId] ??= <({NetEdge edge, String other})>[])
        .add((edge: e, other: e.toId));
    (adjacency[e.toId] ??= <({NetEdge edge, String other})>[])
        .add((edge: e, other: e.fromId));
  }

  final sourceElevation = source == null
      ? const Length(0)
      : nodeElevation(source, building, mounting);

  // Friction along the GOVERNING path to each node, walking every edge in
  // its sized flow direction (mech-props-3 — see [orientedPathCost]); on a
  // tree this is exactly the unique source path.
  double edgeFrictionArriving(NetEdge edge, String arriving) {
    // Friction over this edge. Unsized edge → skip (0 friction). Absent flow
    // → FlowRate(0) → Hazen–Williams loss is exactly 0.
    final edgeSizing = sizing[edge.id];
    if (edgeSizing == null) return 0.0;
    final flow = edgeFlows[edge.id] ?? const FlowRate(0);
    final length = edgeLength(
      edge,
      net,
      calibrationBySheet: calibrationBySheet,
      building: building,
      mounting: mounting,
    );
    // Per-edge C: the edge's pipe product if set, else the service-wide C.
    final edgeC =
        edge.pipeProduct != null ? hazenWilliamsCFor(edge.pipeProduct!) : hwC;
    var edgeFriction = headLossHazenWilliams(
      flow: flow,
      length: length,
      diameter: edgeSizing.diameter,
      hazenWilliamsC: edgeC,
    ).meters;
    // Minor (local) loss if we're arriving at an inline restrictor
    // (valve/strainer/meter): h = K·v²/2g at the feeding edge's velocity.
    // Added to this node's accumulated friction, so it propagates to every
    // downstream node. K = 0 (no component / not a restrictor) ⇒ no change.
    final k = net.nodeById(arriving)?.component?.minorLossK ?? 0;
    if (k > 0) {
      final v = velocityFromFlow(flow, edgeSizing.diameter);
      edgeFriction += minorLossHead(k: k, velocity: v).meters;
    }
    return edgeFriction;
  }

  final friction = orientedPathCost(
    sourceId: sourceId,
    adjacency: adjacency,
    flowFromOf: (e) => sizing[e.id]?.flowFromId,
    edgeCost: edgeFrictionArriving,
  );
  final costs = <String, _NodeCost>{
    for (final entry in friction.entries)
      entry.key: () {
        final n = net.nodeById(entry.key);
        final elev =
            n == null ? sourceElevation : nodeElevation(n, building, mounting);
        return _NodeCost(
          Head(entry.value),
          Length(elev.meters - sourceElevation.meters),
        );
      }(),
  };

  // requiredPumpHead = max over reachable DELIVERY nodes of
  //   friction-from-source + elevation-gain + target-as-head.
  // (water-drainage-5: a ceiling main above its fixtures is not where the
  // target residual is owed.)
  final delivery = _deliveryNodes(net, costs.keys, sourceId, adjacency);
  var requiredPumpHead = targetHead.meters;
  var criticalNodeId = sourceId;
  costs.forEach((nodeId, cost) {
    if (!delivery.contains(nodeId)) return;
    final required =
        cost.friction.meters + cost.elevationGain.meters + targetHead.meters;
    if (required > requiredPumpHead) {
      requiredPumpHead = required;
      criticalNodeId = nodeId;
    }
  });

  // residual(node) = pump - friction(node) - elevationGain(node), as pressure;
  // the no-flow static drops the friction term (mech-building-2).
  final residualPressure = <String, Pressure>{};
  final noFlowStatic = <String, Pressure>{};
  costs.forEach((nodeId, cost) {
    final residualHead =
        requiredPumpHead - cost.friction.meters - cost.elevationGain.meters;
    residualPressure[nodeId] = pressureFromHead(Head(residualHead));
    noFlowStatic[nodeId] =
        pressureFromHead(Head(requiredPumpHead - cost.elevationGain.meters));
  });

  return PressureSolution(
    residualPressure: residualPressure,
    requiredPumpHead: Head(requiredPumpHead),
    criticalNodeId: criticalNodeId,
    // The pump head above was DEFINED as the max of (friction + elevation +
    // target), so every residual is ≥ target as an algebraic identity — the
    // numbers are unchanged, but the consumer must not read them as a verdict.
    targetHeldByDesign: true,
    noFlowStaticPressure: noFlowStatic,
    deliveryNodeIds: delivery.difference({sourceId}),
  );
}

/// Result of [solveDownfeed]: gravity-fed residual pressure at every reachable
/// node, the worst-served (critical) node, and any booster head still needed to
/// guarantee the target residual there.
class DownfeedSolution {
  /// Residual (flowing) pressure at each reachable node id, by gravity from the
  /// tank, after friction. Can be negative where gravity cannot deliver.
  final Map<String, Pressure> residualPressure;

  /// Id of the worst-served DELIVERY node (least residual; fixtures, else open
  /// leaves) — excludes the tank itself; typically the highest / most-distant
  /// fixture, nearest the tank.
  final String criticalNodeId;

  /// Residual at [criticalNodeId].
  final Pressure minResidual;

  /// Extra head a booster pump (or a higher tank) must add so the critical node
  /// meets the target residual. Zero when gravity already suffices.
  final Head boosterHeadRequired;

  /// Always **false** for a downfeed solve — the counterpart of
  /// [PressureSolution.targetHeldByDesign] (M9), carried so a consumer can ask
  /// the same question of either solve.
  ///
  /// These residuals are FALSIFIABLE: they are measured down from a fixed tank
  /// elevation minus real friction, and nothing here is defined in terms of the
  /// target — the target only appears afterwards, as the shortfall in
  /// [boosterHeadRequired]. A high fixture or a long lossy run genuinely can
  /// (and does) drive [minResidual] below target, so a PASS/LOW verdict on a
  /// downfeed residual is a real check.
  final bool targetHeldByDesign;

  const DownfeedSolution({
    required this.residualPressure,
    required this.criticalNodeId,
    required this.minResidual,
    required this.boosterHeadRequired,
    this.targetHeldByDesign = false,
  });

  /// True when gravity alone meets the target residual everywhere.
  bool get gravitySufficient => boosterHeadRequired.meters <= 0;
}

/// Solve a gravity DOWNFEED distribution fed from a roof tank at [tankId]
/// (the strategy chosen for this project).
///
/// The tank provides head purely by elevation: residual at a node is the
/// gravity head from the tank down to the node, plus the tank's own water depth
/// [tankStaticHead], minus Hazen–Williams friction along the path. Because the
/// tank is the high point, the WORST-served node is the one with the LEAST
/// residual — the highest / most-distant fixture, which is nearest the tank and
/// so gains the least gravity head. When that falls below [targetResidual],
/// [DownfeedSolution.boosterHeadRequired] reports the shortfall (a booster pump
/// or a higher tank is then needed for that upper zone).
///
/// Shares the tree/`// VERIFY`/missing-data semantics of [solvePressurized]:
/// the [service] subgraph is treated as a tree rooted at the tank; unsized or
/// unflowed edges add zero friction.
DownfeedSolution solveDownfeed({
  required Network net,
  required ServiceType service,
  required String tankId,
  required Map<String, FlowRate> edgeFlows,
  required Map<String, EdgeSizing> sizing,
  required Map<String, ScaleCalibration> calibrationBySheet,
  required BuildingLevels building,
  required Pressure targetResidual,
  Head tankStaticHead = const Head(0),
  PipeMaterial material = PipeMaterial.pvc,
  MountingHeights mounting = const MountingHeights(),
}) {
  const profile = SniProfile();
  final hwC = profile.hazenWilliamsC(material);
  final targetHead = headFromPressure(targetResidual);

  final tank = net.nodeById(tankId);
  final tankElevation = tank == null
      ? building.roofElevation
      : nodeElevation(tank, building, mounting);

  // Adjacency over THIS service only.
  final adjacency = <String, List<({NetEdge edge, String other})>>{};
  for (final e in net.edges) {
    if (e.service != service) continue;
    (adjacency[e.fromId] ??= <({NetEdge edge, String other})>[])
        .add((edge: e, other: e.toId));
    (adjacency[e.toId] ??= <({NetEdge edge, String other})>[])
        .add((edge: e, other: e.fromId));
  }

  // Friction along the governing path from the tank, each edge walked in its
  // sized flow direction (mech-props-3 — see [orientedPathCost]).
  double edgeFrictionArriving(NetEdge edge, String arriving) {
    final edgeSizing = sizing[edge.id];
    if (edgeSizing == null) return 0.0;
    final flow = edgeFlows[edge.id] ?? const FlowRate(0);
    final length = edgeLength(
      edge,
      net,
      calibrationBySheet: calibrationBySheet,
      building: building,
      mounting: mounting,
    );
    // Per-edge C: the edge's pipe product if set, else the service-wide C.
    final edgeC =
        edge.pipeProduct != null ? hazenWilliamsCFor(edge.pipeProduct!) : hwC;
    var edgeFriction = headLossHazenWilliams(
      flow: flow,
      length: length,
      diameter: edgeSizing.diameter,
      hazenWilliamsC: edgeC,
    ).meters;
    // Minor (local) loss at an inline restrictor we're arriving at — same
    // h = K·v²/2g treatment as the upfeed solve (K = 0 ⇒ no change).
    final k = net.nodeById(arriving)?.component?.minorLossK ?? 0;
    if (k > 0) {
      final v = velocityFromFlow(flow, edgeSizing.diameter);
      edgeFriction += minorLossHead(k: k, velocity: v).meters;
    }
    return edgeFriction;
  }

  final friction = orientedPathCost(
    sourceId: tankId,
    adjacency: adjacency,
    flowFromOf: (e) => sizing[e.id]?.flowFromId,
    edgeCost: edgeFrictionArriving,
  );

  // residual(node) = tankStaticHead + (tankElev − nodeElev) − friction, as head.
  // The critical node is the least-served DELIVERY node (water-drainage-5).
  final delivery = _deliveryNodes(net, friction.keys, tankId, adjacency);
  final residualPressure = <String, Pressure>{};
  var minResidualHead = double.infinity;
  String? criticalNodeId;
  friction.forEach((nodeId, f) {
    final n = net.nodeById(nodeId);
    final nElev =
        n == null ? tankElevation : nodeElevation(n, building, mounting);
    final residualHead =
        tankStaticHead.meters + (tankElevation.meters - nElev.meters) - f;
    residualPressure[nodeId] = pressureFromHead(Head(residualHead));
    if (nodeId != tankId &&
        delivery.contains(nodeId) &&
        residualHead < minResidualHead) {
      minResidualHead = residualHead;
      criticalNodeId = nodeId;
    }
  });
  if (criticalNodeId == null) {
    // Only the tank is reachable (degenerate).
    criticalNodeId = tankId;
    minResidualHead = tankStaticHead.meters;
  }

  final deficit = targetHead.meters - minResidualHead;
  return DownfeedSolution(
    residualPressure: residualPressure,
    criticalNodeId: criticalNodeId!,
    minResidual: pressureFromHead(Head(minResidualHead)),
    boosterHeadRequired: Head(deficit > 0 ? deficit : 0),
  );
}
