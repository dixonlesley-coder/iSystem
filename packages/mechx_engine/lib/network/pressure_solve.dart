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

/// Result of [solvePressurized]: the residual pressure at every reachable node,
/// the pump head the source must develop, and which node set that requirement.
class PressureSolution {
  /// Residual (flowing) pressure at each reachable node id, including the
  /// source. The [criticalNodeId]'s value ≈ the requested target residual;
  /// every other node's value is ≥ the target.
  final Map<String, Pressure> residualPressure;

  /// Head the source pump must develop so the worst-served node still meets the
  /// target residual: max over reachable nodes of
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

  const PressureSolution({
    required this.residualPressure,
    required this.requiredPumpHead,
    required this.criticalNodeId,
    this.targetHeldByDesign = false,
  });
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
      : nodeElevation(source, building);

  // BFS from the source; each visited node records cumulative friction +
  // elevation gain along its (unique, tree) path back to the source.
  final costs = <String, _NodeCost>{sourceId: const _NodeCost(Head(0), Length(0))};
  final queue = <String>[sourceId];
  var head = 0;
  while (head < queue.length) {
    final current = queue[head];
    head++;
    final currentCost = costs[current]!;
    final links = adjacency[current];
    if (links == null) continue;
    for (final link in links) {
      if (costs.containsKey(link.other)) continue; // already visited (tree)
      final edge = link.edge;

      // Friction over this edge. Unsized edge → skip (0 friction). Absent flow
      // → FlowRate(0) → Hazen–Williams loss is exactly 0.
      var edgeFriction = 0.0;
      final edgeSizing = sizing[edge.id];
      if (edgeSizing != null) {
        final flow = edgeFlows[edge.id] ?? const FlowRate(0);
        final length = edgeLength(
          edge,
          net,
          calibrationBySheet: calibrationBySheet,
          building: building,
        );
        // Per-edge C: the edge's pipe product if set, else the service-wide C.
        final edgeC = edge.pipeProduct != null
            ? hazenWilliamsCFor(edge.pipeProduct!)
            : hwC;
        edgeFriction = headLossHazenWilliams(
          flow: flow,
          length: length,
          diameter: edgeSizing.diameter,
          hazenWilliamsC: edgeC,
        ).meters;
        // Minor (local) loss if we're arriving at an inline restrictor
        // (valve/strainer/meter): h = K·v²/2g at the feeding edge's velocity.
        // Added to this node's accumulated friction, so it propagates to every
        // downstream node. K = 0 (no component / not a restrictor) ⇒ no change.
        final k = net.nodeById(link.other)?.component?.minorLossK ?? 0;
        if (k > 0) {
          final v = velocityFromFlow(flow, edgeSizing.diameter);
          edgeFriction += minorLossHead(k: k, velocity: v).meters;
        }
      }

      final neighbour = net.nodeById(link.other);
      final neighbourElevation = neighbour == null
          ? sourceElevation
          : nodeElevation(neighbour, building);

      costs[link.other] = _NodeCost(
        Head(currentCost.friction.meters + edgeFriction),
        Length(neighbourElevation.meters - sourceElevation.meters),
      );
      queue.add(link.other);
    }
  }

  // requiredPumpHead = max over reachable nodes of
  //   friction-from-source + elevation-gain + target-as-head.
  var requiredPumpHead = targetHead.meters;
  var criticalNodeId = sourceId;
  costs.forEach((nodeId, cost) {
    final required =
        cost.friction.meters + cost.elevationGain.meters + targetHead.meters;
    if (required > requiredPumpHead) {
      requiredPumpHead = required;
      criticalNodeId = nodeId;
    }
  });

  // residual(node) = pump - friction(node) - elevationGain(node), as pressure.
  final residualPressure = <String, Pressure>{};
  costs.forEach((nodeId, cost) {
    final residualHead =
        requiredPumpHead - cost.friction.meters - cost.elevationGain.meters;
    residualPressure[nodeId] = pressureFromHead(Head(residualHead));
  });

  return PressureSolution(
    residualPressure: residualPressure,
    requiredPumpHead: Head(requiredPumpHead),
    criticalNodeId: criticalNodeId,
    // The pump head above was DEFINED as the max of (friction + elevation +
    // target), so every residual is ≥ target as an algebraic identity — the
    // numbers are unchanged, but the consumer must not read them as a verdict.
    targetHeldByDesign: true,
  );
}

/// Result of [solveDownfeed]: gravity-fed residual pressure at every reachable
/// node, the worst-served (critical) node, and any booster head still needed to
/// guarantee the target residual there.
class DownfeedSolution {
  /// Residual (flowing) pressure at each reachable node id, by gravity from the
  /// tank, after friction. Can be negative where gravity cannot deliver.
  final Map<String, Pressure> residualPressure;

  /// Id of the worst-served node (least residual) — excludes the tank itself;
  /// typically the highest / most-distant fixture, nearest the tank.
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
}) {
  const profile = SniProfile();
  final hwC = profile.hazenWilliamsC(material);
  final targetHead = headFromPressure(targetResidual);

  final tank = net.nodeById(tankId);
  final tankElevation =
      tank == null ? building.roofElevation : nodeElevation(tank, building);

  // Adjacency over THIS service only.
  final adjacency = <String, List<({NetEdge edge, String other})>>{};
  for (final e in net.edges) {
    if (e.service != service) continue;
    (adjacency[e.fromId] ??= <({NetEdge edge, String other})>[])
        .add((edge: e, other: e.toId));
    (adjacency[e.toId] ??= <({NetEdge edge, String other})>[])
        .add((edge: e, other: e.fromId));
  }

  // BFS from the tank accumulating cumulative friction along the tree path.
  final friction = <String, double>{tankId: 0.0};
  final queue = <String>[tankId];
  var head = 0;
  while (head < queue.length) {
    final current = queue[head];
    head++;
    final currentFriction = friction[current]!;
    final links = adjacency[current];
    if (links == null) continue;
    for (final link in links) {
      if (friction.containsKey(link.other)) continue; // visited (tree)
      final edge = link.edge;
      var edgeFriction = 0.0;
      final edgeSizing = sizing[edge.id];
      if (edgeSizing != null) {
        final flow = edgeFlows[edge.id] ?? const FlowRate(0);
        final length = edgeLength(
          edge,
          net,
          calibrationBySheet: calibrationBySheet,
          building: building,
        );
        // Per-edge C: the edge's pipe product if set, else the service-wide C.
        final edgeC = edge.pipeProduct != null
            ? hazenWilliamsCFor(edge.pipeProduct!)
            : hwC;
        edgeFriction = headLossHazenWilliams(
          flow: flow,
          length: length,
          diameter: edgeSizing.diameter,
          hazenWilliamsC: edgeC,
        ).meters;
        // Minor (local) loss at an inline restrictor we're arriving at — same
        // h = K·v²/2g treatment as the upfeed solve (K = 0 ⇒ no change).
        final k = net.nodeById(link.other)?.component?.minorLossK ?? 0;
        if (k > 0) {
          final v = velocityFromFlow(flow, edgeSizing.diameter);
          edgeFriction += minorLossHead(k: k, velocity: v).meters;
        }
      }
      friction[link.other] = currentFriction + edgeFriction;
      queue.add(link.other);
    }
  }

  // residual(node) = tankStaticHead + (tankElev − nodeElev) − friction, as head.
  final residualPressure = <String, Pressure>{};
  var minResidualHead = double.infinity;
  String? criticalNodeId;
  friction.forEach((nodeId, f) {
    final n = net.nodeById(nodeId);
    final nElev = n == null ? tankElevation : nodeElevation(n, building);
    final residualHead =
        tankStaticHead.meters + (tankElevation.meters - nElev.meters) - f;
    residualPressure[nodeId] = pressureFromHead(Head(residualHead));
    if (nodeId != tankId && residualHead < minResidualHead) {
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
