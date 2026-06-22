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

/// Accumulate downstream fixture-unit (UBAP) load onto every edge of [service]
/// as a tree rooted at [rootId]. [terminalUnits] maps node ids to the fixture
/// units introduced AT that node. Returns edgeId → total UBAP carried by that
/// edge (the sum over the subtree on the far side from the root).
///
/// Water supply must be sized from ACCUMULATED fixture units passed through the
/// Hunter/UBAP demand curve (diversified simultaneous demand), NOT from a sum
/// of peak fixture flows — hence units are accumulated here and converted to a
/// flow per edge by the caller.
Map<String, double> accumulateFixtureUnits({
  required Network net,
  required ServiceType service,
  required String rootId,
  required Map<String, double> terminalUnits,
}) {
  final adjacency = <String, List<({String edgeId, String other})>>{};
  for (final e in net.edges) {
    if (e.service != service) continue;
    (adjacency[e.fromId] ??= []).add((edgeId: e.id, other: e.toId));
    (adjacency[e.toId] ??= []).add((edgeId: e.id, other: e.fromId));
  }

  final edgeUnits = <String, double>{};
  final visited = <String>{};

  double subtreeUnits(String node) {
    visited.add(node);
    var sum = terminalUnits[node] ?? 0.0;
    final links = adjacency[node];
    if (links != null) {
      for (final link in links) {
        if (visited.contains(link.other)) continue;
        final child = subtreeUnits(link.other);
        edgeUnits[link.edgeId] = child;
        sum += child;
      }
    }
    return sum;
  }

  subtreeUnits(rootId);
  return edgeUnits;
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
/// split into connected components, root each at one of its leaves, apply demand
/// at every *other* leaf, accumulate down the branches, and size every edge.
/// Branching is handled exactly (each leg sized for its own subtree); edges with
/// no demand are left unsized.
///
/// Demand model per service:
///   • Water supply (cold/hot) with an entry in [leafFixtureUnits]: accumulate
///     fixture UNITS down the tree and convert each edge's total via the
///     Hunter/UBAP curve ([flushSystem]) — diversified simultaneous demand,
///     NOT a sum of peak fixture flows.
///   • Everything else (or water without fixture-unit data): accumulate the
///     flat [leafDemand] flows.
Map<String, EdgeSizing> autoSizeNetwork(
  Network net,
  SizingContext ctx, {
  required Map<ServiceType, FlowRate> leafDemand,
  Map<ServiceType, double> leafFixtureUnits = const {},
  Map<String, double> nodeFixtureUnits = const {},
  FlushSystem flushSystem = FlushSystem.flushTank,
}) {
  const profile = SniProfile();
  final allFlows = <String, FlowRate>{};

  bool isWaterSupply(ServiceType s) =>
      s == ServiceType.coldWater || s == ServiceType.hotWater;

  for (final service in net.edges.map((e) => e.service).toSet()) {
    final demand = leafDemand[service] ?? const FlowRate(0);
    final useUbap =
        isWaterSupply(service) && leafFixtureUnits.containsKey(service);
    final fuPerLeaf = leafFixtureUnits[service] ?? 0.0;

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

      if (useUbap) {
        // Per-fixture UBAP when a node carries a fixture type; else the flat
        // default for that water service.
        final terminalUnits = <String, double>{
          for (final leaf in leaves)
            if (leaf != root) leaf: nodeFixtureUnits[leaf] ?? fuPerLeaf,
        };
        final edgeUnits = accumulateFixtureUnits(
          net: net,
          service: service,
          rootId: root,
          terminalUnits: terminalUnits,
        );
        for (final entry in edgeUnits.entries) {
          allFlows[entry.key] = profile.probableFlowForFixtureUnits(
            entry.value,
            system: flushSystem,
          );
        }
      } else {
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
  }

  return sizeNetwork(net, allFlows, ctx);
}
