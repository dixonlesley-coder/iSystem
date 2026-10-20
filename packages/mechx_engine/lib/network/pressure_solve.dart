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
}) =>
    _deliveryOverPressure(
      deliveryNodeIds: solution.deliveryNodeIds,
      residual: solution.residualPressure,
      noFlow: solution.noFlowStaticPressure,
      profile: profile,
    );

/// Round 16 (plumbing-plant-downfeed-prv-unmodelled) — the SAME judge-only
/// fixture over-pressure check on a gravity DOWNFEED solve: a 20-storey roof
/// tank with no PRV drawn delivers ~600 kPa to the ground floor (over the
/// 392 kPa fixture maximum AND the 490 kPa relief trigger) and Review used to
/// stay silent, because the PRV zone table assumes a PRV at every zone top
/// whether one is drawn or not. Drawn PRVs now hold their setpoint in
/// [solveDownfeed], so a correctly zoned riser passes here and an unzoned one
/// does not.
List<UpfeedOverPressure> downfeedOverPressure(
  DownfeedSolution solution, {
  StandardsProfile profile = const SniProfile(),
}) =>
    _deliveryOverPressure(
      deliveryNodeIds: solution.deliveryNodeIds,
      residual: solution.residualPressure,
      noFlow: solution.noFlowStaticPressure,
      profile: profile,
    );

List<UpfeedOverPressure> _deliveryOverPressure({
  required Set<String> deliveryNodeIds,
  required Map<String, Pressure> residual,
  required Map<String, Pressure> noFlow,
  required StandardsProfile profile,
}) {
  final maxFix = profile.maxFixtureStaticPressure.value.pascals;
  final relief = profile.mandatoryPressureReliefThreshold.value.pascals;
  final noFlowMap = noFlow;
  final out = <UpfeedOverPressure>[];
  for (final id in deliveryNodeIds) {
    final flowing = residual[id];
    final noFlow = noFlowMap[id];
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
/// critical node. See [pressureDeliveryNodes].
Set<String> _deliveryNodes(
  Network net,
  Iterable<String> reached,
  String sourceId,
  Map<String, List<({NetEdge edge, String other})>> adjacency,
  Map<String, EdgeSizing> sizing, {
  Set<String>? loadedOpenEndsOut,
}) =>
    pressureDeliveryNodes(
      net: net,
      candidates: reached,
      sourceId: sourceId,
      degreeOf: (id) => adjacency[id]?.length ?? 0,
      incidentEdges: (id) => [
        for (final l
            in adjacency[id] ?? const <({NetEdge edge, String other})>[])
          l.edge,
      ],
      sizing: sizing,
      loadedOpenEndsOut: loadedOpenEndsOut,
    );

/// Round 33 (hydraulics-3-1 / 3-4) — the ONE delivery-node rule of the
/// pressure solves and the app's mover / booster duties: the sizer's own
/// DEMAND set, so a pipe the sizer loaded is a pipe the solve judges.
///   1. every [isDeliveryFixture] among [candidates] (a fixture-role node
///      other than a cleanout / air vent / extinguisher — an AAV at a riser
///      top is not a draw-off and must never become the critical node);
///   2. PLUS every LOADED open leaf: a degree-1 node that is not a plant, a
///      non-demand terminal or an inline device, whose single pipe the sizer
///      sized with flow ARRIVING at it ([EdgeSizing.flowFromId] the far end,
///      flow > 0) — the sizer gave it the default terminal demand, so it is
///      owed the residual too, judged where that default terminal hangs
///      ([pressureJudgeElevation]: fixture height for a bare cold / hot
///      water end, never the ceiling the main itself runs at). A fill-line
///      inlet (flow leaving it) is never one;
///   3. else every degree-1 leaf (legacy, a drawing with no sized flow);
///   4. else every candidate (degenerate — keeps the old behaviour), unless
///      [fallbackToAll] is false (a mover's served subset owes nothing then).
/// [sourceId] is never a delivery node in rungs 1-3.
///
/// Round 33 r2 — [loadedOpenEndsOut], when given, receives exactly the
/// rung-2 nodes (loaded open ends that are not fixtures) that end up in the
/// returned set — the ones [pressureJudgeElevation] moves to fixture height.
Set<String> pressureDeliveryNodes({
  required Network net,
  required Iterable<String> candidates,
  required int Function(String id) degreeOf,
  required Iterable<NetEdge> Function(String id) incidentEdges,
  required Map<String, EdgeSizing> sizing,
  String? sourceId,
  bool fallbackToAll = true,
  Set<String>? loadedOpenEndsOut,
}) {
  final out = <String>{};
  final loaded = <String>{};
  for (final id in candidates) {
    if (id == sourceId) continue;
    final n = net.nodeById(id);
    if (n == null) continue;
    if (isDeliveryFixture(n)) {
      out.add(id);
      continue;
    }
    if (n.role == NodeRole.plant ||
        isNonDemandTerminal(n.component) ||
        isInlineDeviceComponent(n.component) ||
        isSupplyInletComponent(n.component) ||
        degreeOf(id) != 1) {
      continue;
    }
    final e = incidentEdges(id).first;
    final sz = sizing[e.id];
    if (sz != null &&
        sz.flowFromId != null &&
        sz.flowFromId != id &&
        sz.flow.cubicMetersPerSecond > 0) {
      out.add(id);
      loaded.add(id);
    }
  }
  if (out.isNotEmpty) {
    loadedOpenEndsOut?.addAll(loaded);
    return out;
  }
  final leaves = <String>{
    for (final id in candidates)
      if (id != sourceId && degreeOf(id) == 1) id,
  };
  if (leaves.isNotEmpty || !fallbackToAll) return leaves;
  return candidates.toSet();
}

/// Round 33 r2 (hydraulics-3-4) — the elevation a pressure solve judges
/// [node] at. A LOADED open water end ([isLoadedOpenEnd]: a
/// [pressureDeliveryNodes] rung-2 node — a bare `main` with no explicit
/// elevation / mount height, on cold or hot water, whose one pipe the sizer
/// sized with flow arriving)
/// carries the sizer's DEFAULT TERMINAL demand — a fixture — so its residual
/// is owed where a fixture hangs, the floor's fixture height (the same
/// connection elevation [runConnectionElevation] gives a plumbing fixture),
/// NOT the ceiling the main runs at: judging it 2.6 m higher demanded ~25 kPa
/// more than any fixture there needs and failed the SNI floor beside a real
/// outlet on the same main that passed. Every other node keeps
/// [nodeElevation].
Length pressureJudgeElevation(
  NetNode node, {
  required ServiceType service,
  required BuildingLevels building,
  MountingHeights mounting = const MountingHeights(),
  required bool isLoadedOpenEnd,
}) {
  if (isLoadedOpenEnd &&
      (service == ServiceType.coldWater || service == ServiceType.hotWater) &&
      node.role == NodeRole.main &&
      node.elevation == null &&
      node.mountHeight == null &&
      !isDeliveryFixture(node)) {
    return building.fixtureElevationOf(node.floorIndex, mounting);
  }
  return nodeElevation(node, building, mounting);
}

/// Internal per-node accumulation along the path from the source.
class _NodeCost {
  final Head friction;
  final Length elevationGain;

  const _NodeCost(this.friction, this.elevationGain);
}

/// Round 16 / 22 — the inline devices that change the head DOWNSTREAM of
/// them, applied source-outward over the source-rooted BFS tree (the same
/// tree the friction walk treats the service as):
///
/// * a drawn PRV ([NodeComponent.prv]) whose inlet head exceeds
///   [setpointHead] lowers itself and every node below it by the excess
///   (flowing and no-flow separately), so its outlet holds the setpoint;
/// * a mover in [moverHeads] raises itself and every node below it by its
///   head (a booster adds head to what it serves).
///
/// Nearer-the-source devices go first, so a booster then a PRV below it (or
/// PRVs in series) compose in turn. Mutates [flowingHead] / [staticHead].
///
/// Returns true when any PRV actually REDUCED the flowing head below it
/// (Round 23 — the upfeed solve then re-judges its delivery nodes instead of
/// claiming the target is held by design).
bool _applyInlineDevices({
  required Network net,
  required String sourceId,
  required Map<String, List<({NetEdge edge, String other})>> adjacency,
  required Iterable<String> reached,
  required Map<String, double> flowingHead,
  required Map<String, double> staticHead,
  required double setpointHead,
  Map<String, Head> moverHeads = const {},
}) {
  final devices = [
    for (final id in reached)
      if (id != sourceId &&
          (net.nodeById(id)?.component == NodeComponent.prv ||
              (moverHeads[id]?.meters ?? 0) > 0))
        id,
  ];
  if (devices.isEmpty) return false;
  final parent = <String, String>{};
  final hop = <String, int>{sourceId: 0};
  final queue = [sourceId];
  for (var i = 0; i < queue.length; i++) {
    final n = queue[i];
    for (final l in adjacency[n] ?? const <({NetEdge edge, String other})>[]) {
      if (hop.containsKey(l.other)) continue;
      hop[l.other] = hop[n]! + 1;
      parent[l.other] = n;
      queue.add(l.other);
    }
  }
  final children = <String, List<String>>{};
  parent.forEach((c, p) => (children[p] ??= []).add(c));
  devices.sort((a, b) {
    final c = (hop[a] ?? 0).compareTo(hop[b] ?? 0);
    return c != 0 ? c : a.compareTo(b);
  });
  void shift(String root, double dFlow, double dStatic) {
    final stack = [root];
    while (stack.isNotEmpty) {
      final n = stack.removeLast();
      final f = flowingHead[n];
      if (f != null) flowingHead[n] = f + dFlow;
      final st = staticHead[n];
      if (st != null) staticHead[n] = st + dStatic;
      stack.addAll(children[n] ?? const <String>[]);
    }
  }

  var reducedFlowing = false;
  for (final r in devices) {
    final inFlow = flowingHead[r];
    if (inFlow == null) continue;
    final boost = moverHeads[r]?.meters ?? 0;
    if (boost > 0) {
      shift(r, boost, boost);
      continue;
    }
    final dFlow = inFlow - setpointHead;
    final dStatic = (staticHead[r] ?? inFlow) - setpointHead;
    if (dFlow <= 0 && dStatic <= 0) continue;
    if (dFlow > 0) reducedFlowing = true;
    shift(r, dFlow > 0 ? -dFlow : 0, dStatic > 0 ? -dStatic : 0);
  }
  return reducedFlowing;
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
  Pressure? prvSetpoint,
  Map<String, Head> moverHeads = const {},
}) {
  const profile = SniProfile();
  final hwC = profile.hazenWilliamsC(material);
  final targetHead = headFromPressure(targetResidual);
  final setpointHead = headFromPressure(prvSetpoint ?? targetResidual).meters;

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
  // (water-drainage-5: a ceiling main above its fixtures is not where the
  // target residual is owed.)
  final loadedEnds = <String>{};
  final delivery = _deliveryNodes(
      net, friction.keys, sourceId, adjacency, sizing,
      loadedOpenEndsOut: loadedEnds);
  final costs = <String, _NodeCost>{
    for (final entry in friction.entries)
      entry.key: () {
        final n = net.nodeById(entry.key);
        final elev = n == null
            ? sourceElevation
            : pressureJudgeElevation(n,
                service: service,
                building: building,
                mounting: mounting,
                isLoadedOpenEnd: loadedEnds.contains(entry.key));
        return _NodeCost(
          Head(entry.value),
          Length(elev.meters - sourceElevation.meters),
        );
      }(),
  };

  // requiredPumpHead = max over reachable DELIVERY nodes of
  //   friction-from-source + elevation-gain + target-as-head.
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

  final criticalBeforePrv = criticalNodeId;
  // residual(node) = pump - friction(node) - elevationGain(node), as pressure;
  // the no-flow static drops the friction term (mech-building-2).
  //
  // Round 33 (hydraulics-3-2) — with [moverHeads] the field is the one the
  // DRAWN movers deliver: the source develops only its own mover's head (an
  // open tank outlet: zero) and every other mover adds its head to what it
  // serves (the same source-outward pass as [solveDownfeed]).
  // [requiredPumpHead] stays the unboosted single-source sizing basis.
  final sourceHead = moverHeads.isEmpty
      ? requiredPumpHead
      : (moverHeads[sourceId]?.meters ?? 0);
  final flowingHead = <String, double>{};
  final staticHead = <String, double>{};
  costs.forEach((nodeId, cost) {
    flowingHead[nodeId] =
        sourceHead - cost.friction.meters - cost.elevationGain.meters;
    staticHead[nodeId] = sourceHead - cost.elevationGain.meters;
  });
  // Round 22 (pressurized-3-2) — a drawn PRV holds its setpoint downstream on
  // the upfeed too (the same pass as [solveDownfeed]), so 'zone the riser with
  // PRVs' really lowers the residuals and no-flow statics below each PRV. The
  // pump head is unchanged (it is the pump's duty without the PRV loss).
  // Round 23 — a PRV that reduces can starve the fixtures it serves (a PRV at
  // the pump discharge or below the top riser fixture), so the identity
  // 'every residual >= target' no longer holds by construction: re-judge.
  final prvReduced = _applyInlineDevices(
    net: net,
    sourceId: sourceId,
    adjacency: adjacency,
    reached: costs.keys,
    flowingHead: flowingHead,
    staticHead: staticHead,
    setpointHead: setpointHead,
    moverHeads: {
      for (final m in moverHeads.entries)
        if (m.key != sourceId) m.key: m.value,
    },
  );
  final residualPressure = <String, Pressure>{
    for (final e in flowingHead.entries) e.key: pressureFromHead(Head(e.value)),
  };
  final noFlowStatic = <String, Pressure>{
    for (final e in staticHead.entries) e.key: pressureFromHead(Head(e.value)),
  };

  // Without a reducing PRV the pump head above was DEFINED as the max of
  // (friction + elevation + target), so every residual is >= target as an
  // algebraic identity — the consumer must not read them as a verdict. With
  // a reducing PRV that identity is broken: the critical node becomes the
  // least-margin delivery node and the verdict is falsifiable again.
  var heldByDesign = true;
  // Round 33 — the delivered (moverHeads) field is a falsifiable outcome too:
  // a fixture no drawn mover serves can sit below the target.
  if (prvReduced || moverHeads.isNotEmpty) {
    const tolM = 1e-6;
    double? worst;
    for (final id in delivery) {
      if (id == sourceId) continue;
      final h = flowingHead[id];
      if (h == null) continue;
      if (worst == null ||
          h < worst ||
          (h == worst && id.compareTo(criticalNodeId) < 0)) {
        worst = h;
        criticalNodeId = id;
      }
    }
    if (worst != null && worst < targetHead.meters - tolM) {
      heldByDesign = false;
    } else {
      // Every delivery node still meets the target — keep the original
      // (pump-governing) critical node and the by-design reading.
      criticalNodeId = criticalBeforePrv;
    }
  }

  return PressureSolution(
    residualPressure: residualPressure,
    requiredPumpHead: Head(requiredPumpHead),
    criticalNodeId: criticalNodeId,
    targetHeldByDesign: heldByDesign,
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

  /// Round 16 — the NO-FLOW static at each reachable node (tank head less
  /// elevation, held at a drawn PRV's setpoint below it). Empty for a legacy
  /// construction.
  final Map<String, Pressure> noFlowStaticPressure;

  /// Round 16 — the DELIVERY nodes (fixtures, else open leaves) a fixture
  /// pressure check judges.
  final Set<String> deliveryNodeIds;

  const DownfeedSolution({
    required this.residualPressure,
    required this.criticalNodeId,
    required this.minResidual,
    required this.boosterHeadRequired,
    this.targetHeldByDesign = false,
    this.noFlowStaticPressure = const {},
    this.deliveryNodeIds = const {},
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
///
/// Round 16 (plumbing-plant-downfeed-prv-unmodelled) — a drawn PRV
/// ([NodeComponent.prv]) REDUCES pressure: where the head arriving at it
/// exceeds its setpoint ([prvSetpoint], default the target residual), every
/// node downstream of it is lowered by the excess, so the PRV outlet holds
/// the setpoint and each node below gains only `ρg·drop − friction` from
/// there (the no-flow static likewise). A PRV whose inlet is already below
/// its setpoint passes the flow through (its minor loss only). PRVs in series
/// are applied tank-outward. It used to be only a minor-loss K: the heatmap
/// and residuals ignored it and the ground floor of a 20-storey downfeed read
/// 601 kPa with or without a PRV drawn.
///
/// Round 22 (pressurized-3-3) — [moverHeads] (node id → head) are the heads
/// of the drawn, SIZED inline movers (boosters): each adds its head to the
/// flowing and no-flow head of every node it serves, applied tank-outward
/// together with the PRVs. Empty (the default) ⇒ the unboosted field the
/// booster duty itself is sized on; the app solves a second, DELIVERED field
/// with the sized heads for the heatmap, the node probe and the over-pressure
/// judgement.
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
  Pressure? prvSetpoint,
  Map<String, Head> moverHeads = const {},
}) {
  const profile = SniProfile();
  final hwC = profile.hazenWilliamsC(material);
  final targetHead = headFromPressure(targetResidual);
  final setpointHead = headFromPressure(prvSetpoint ?? targetResidual).meters;

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
  final loadedEnds = <String>{};
  final delivery = _deliveryNodes(net, friction.keys, tankId, adjacency, sizing,
      loadedOpenEndsOut: loadedEnds);
  final flowingHead = <String, double>{};
  final staticHead = <String, double>{};
  friction.forEach((nodeId, f) {
    final n = net.nodeById(nodeId);
    final nElev = n == null
        ? tankElevation
        : pressureJudgeElevation(n,
            service: service,
            building: building,
            mounting: mounting,
            isLoadedOpenEnd: loadedEnds.contains(nodeId));
    final gravity =
        tankStaticHead.meters + (tankElevation.meters - nElev.meters);
    flowingHead[nodeId] = gravity - f;
    staticHead[nodeId] = gravity;
  });

  // Round 16 — drawn PRVs hold their setpoint downstream; Round 22 — a drawn
  // mover in [moverHeads] adds its head to everything it serves (see
  // [_applyInlineDevices]).
  _applyInlineDevices(
    net: net,
    sourceId: tankId,
    adjacency: adjacency,
    reached: friction.keys,
    flowingHead: flowingHead,
    staticHead: staticHead,
    setpointHead: setpointHead,
    moverHeads: moverHeads,
  );

  final residualPressure = <String, Pressure>{};
  final noFlowStatic = <String, Pressure>{};
  var minResidualHead = double.infinity;
  String? criticalNodeId;
  friction.forEach((nodeId, _) {
    final residualHead = flowingHead[nodeId]!;
    residualPressure[nodeId] = pressureFromHead(Head(residualHead));
    noFlowStatic[nodeId] = pressureFromHead(Head(staticHead[nodeId]!));
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
    noFlowStaticPressure: noFlowStatic,
    deliveryNodeIds: delivery.difference({tankId}),
  );
}
