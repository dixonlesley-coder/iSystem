/// Network sizing dispatcher — turns a drawn [Network] + demands into a sized
/// pipe/duct per edge, routing each edge to the correct §7 code path.
///
/// BRANCHING: [accumulateFlows] walks the (tree) network from a root and gives
/// every edge the sum of the demands DOWNSTREAM of it — so at a tee each branch
/// carries only its own subtree's load and is sized independently, while the
/// trunk carries the total. This is how branching ducts / pipes / drains size
/// correctly.
///
/// Pure Dart, zero Flutter imports.
library;

import '../network/network.dart';
import '../standards/sni.dart';
import '../units.dart';
import 'drainage_sizing.dart' as drain;
import 'duct_sizing.dart' as duct;
import 'water_supply_sizing.dart' as water;

/// Design parameters shared across a sizing run.
class SizingContext {
  final Velocity maxSupplyVelocity;
  final Velocity maxDuctVelocity;
  final double drainageSlope; // m/m
  final double drainageFillRatio;
  final double drainageManningN;
  final PipeMaterial pipeMaterial;

  const SizingContext({
    this.maxSupplyVelocity = const Velocity(2.0),
    this.maxDuctVelocity = const Velocity(5.0),
    this.drainageSlope = 0.01,
    this.drainageFillRatio = 0.5,
    this.drainageManningN = 0.010,
    this.pipeMaterial = PipeMaterial.pvc,
  });
}

/// Sizing outcome for one edge.
class EdgeSizing {
  final String edgeId;
  final ServiceType service;
  final FlowRate flow;
  final Diameter diameter;
  final Velocity velocity;

  const EdgeSizing({
    required this.edgeId,
    required this.service,
    required this.flow,
    required this.diameter,
    required this.velocity,
  });
}

/// Accumulate downstream demand onto every edge of [service], treating the
/// service subgraph as a tree rooted at [rootId]. [terminalDemand] maps node
/// ids to the demand introduced AT that node (fixtures, diffusers, drains).
/// Returns edgeId → flow (the total demand beyond that edge, away from root).
///
/// Assumes the service subgraph is acyclic (a distribution/collection tree);
/// cycles would need the P4 node solve instead.
Map<String, FlowRate> accumulateFlows({
  required Network net,
  required ServiceType service,
  required String rootId,
  required Map<String, FlowRate> terminalDemand,
}) {
  final adjacency = <String, List<({String edgeId, String other})>>{};
  for (final e in net.edges) {
    if (e.service != service) continue;
    (adjacency[e.fromId] ??= []).add((edgeId: e.id, other: e.toId));
    (adjacency[e.toId] ??= []).add((edgeId: e.id, other: e.fromId));
  }

  final edgeFlow = <String, FlowRate>{};
  final visited = <String>{};

  // Post-order DFS: returns total demand in the subtree at [node].
  double subtreeDemand(String node) {
    visited.add(node);
    var sum = terminalDemand[node]?.cubicMetersPerSecond ?? 0.0;
    final links = adjacency[node];
    if (links != null) {
      for (final link in links) {
        if (visited.contains(link.other)) continue;
        final childDemand = subtreeDemand(link.other);
        edgeFlow[link.edgeId] = FlowRate(childDemand);
        sum += childDemand;
      }
    }
    return sum;
  }

  subtreeDemand(rootId);
  return edgeFlow;
}

/// Size one [edge] carrying [flow] via the correct §7 path (selected by the
/// edge's service regime — pressurized / air / gravity).
EdgeSizing sizeEdge(NetEdge edge, FlowRate flow, SizingContext ctx) {
  switch (edge.service.regime) {
    case FlowRegime.pressurized:
      final r = water.sizeForFlow(
        flow: flow,
        maxVelocity: ctx.maxSupplyVelocity,
        material: ctx.pipeMaterial,
      );
      return EdgeSizing(
        edgeId: edge.id,
        service: edge.service,
        flow: flow,
        diameter: r.diameter,
        velocity: r.velocity,
      );
    case FlowRegime.air:
      final r = duct.sizeByVelocity(
        airflow: flow,
        maxVelocity: ctx.maxDuctVelocity,
      );
      return EdgeSizing(
        edgeId: edge.id,
        service: edge.service,
        flow: flow,
        diameter: r.diameter,
        velocity: r.actualVelocity,
      );
    case FlowRegime.gravity:
      final r = drain.sizeForFlow(
        flow: flow,
        slope: ctx.drainageSlope,
        fillRatio: ctx.drainageFillRatio,
        manningN: ctx.drainageManningN,
      );
      return EdgeSizing(
        edgeId: edge.id,
        service: edge.service,
        flow: flow,
        diameter: r.diameter,
        velocity: r.fullBoreVelocity,
      );
  }
}

/// Size every edge that has an accumulated [edgeFlows] entry. Edges with no
/// flow (not reached from a root / no demand) are skipped.
Map<String, EdgeSizing> sizeNetwork(
  Network net,
  Map<String, FlowRate> edgeFlows,
  SizingContext ctx,
) {
  final result = <String, EdgeSizing>{};
  for (final edge in net.edges) {
    final flow = edgeFlows[edge.id];
    if (flow == null) continue;
    result[edge.id] = sizeEdge(edge, flow, ctx);
  }
  return result;
}

/// Auto-size the whole drawn network with a default demand policy: per service,
/// split into connected components, root each at one of its leaves, apply
/// [leafDemand] at every *other* leaf (fixtures/diffusers/drains), accumulate
/// down the branches, and size every edge. A pragmatic default until per-fixture
/// loads are assigned; branching is handled exactly (each leg sized for its own
/// subtree). Edges with no demand are left unsized.
Map<String, EdgeSizing> autoSizeNetwork(
  Network net,
  SizingContext ctx, {
  required Map<ServiceType, FlowRate> leafDemand,
}) {
  final allFlows = <String, FlowRate>{};

  for (final service in net.edges.map((e) => e.service).toSet()) {
    final demand = leafDemand[service] ?? const FlowRate(0);

    final adjacency = <String, List<({String edgeId, String other})>>{};
    final nodes = <String>{};
    for (final e in net.edges) {
      if (e.service != service) continue;
      nodes..add(e.fromId)..add(e.toId);
      (adjacency[e.fromId] ??= []).add((edgeId: e.id, other: e.toId));
      (adjacency[e.toId] ??= []).add((edgeId: e.id, other: e.fromId));
    }

    int degree(String n) => adjacency[n]?.length ?? 0;

    final seen = <String>{};
    for (final start in nodes) {
      if (seen.contains(start)) continue;
      // Collect this connected component.
      final component = <String>[];
      final stack = [start];
      seen.add(start);
      while (stack.isNotEmpty) {
        final n = stack.removeLast();
        component.add(n);
        final links = adjacency[n];
        if (links != null) {
          for (final link in links) {
            if (seen.add(link.other)) stack.add(link.other);
          }
        }
      }
      final leaves = component.where((n) => degree(n) == 1).toList();
      final root = leaves.isNotEmpty ? leaves.first : component.first;
      final terminalDemand = <String, FlowRate>{
        for (final leaf in leaves)
          if (leaf != root) leaf: demand,
      };
      allFlows.addAll(
        accumulateFlows(
          net: net,
          service: service,
          rootId: root,
          terminalDemand: terminalDemand,
        ),
      );
    }
  }

  return sizeNetwork(net, allFlows, ctx);
}
