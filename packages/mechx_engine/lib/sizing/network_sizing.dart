/// Network sizing dispatcher — turns a drawn [Network] + demands into a sized
/// pipe/duct per edge, routing each edge to the correct §7 code path.
///
/// BRANCHING: [accumulateFlows] walks the (tree) network from a root and gives
/// every edge the sum of the demands DOWNSTREAM of it — so at a tee each branch
/// carries only its own subtree's load and is sized independently, while the
/// trunk carries the total. This is how branching ducts / pipes / drains size
/// correctly.
///
/// LOOPS: a component with more edges than (nodes − 1) has parallel paths whose
/// flow split a unique-path accumulation can't resolve. For PRESSURIZED and AIR
/// services [autoSizeNetwork] balances such a ring/grid with Hardy–Cross
/// (`hardy_cross.dart`) and sizes each edge from its share. Gravity services
/// keep the tree path (physical drainage rings are nonsensical).
///
/// Pure Dart, zero Flutter imports.
library;

import '../hydraulics.dart';
import '../network/hardy_cross.dart';
import '../network/network.dart';
import '../standards/sni.dart';
import '../units.dart';
import 'drainage_sizing.dart' as drain;
import 'duct_sizing.dart' as duct;
import 'storm_sizing.dart' as storm;
import 'water_supply_sizing.dart' as water;

/// Default drainage fixture units assumed at a sanitary terminal that has no
/// assigned fixture type (≈ a lavatory-plus). // VERIFY against SNI 8153.
const double kDefaultLeafDfu = 2.0;

/// Duct cross-section shape and the sizing method used for air services.
enum DuctShape { round, rectangular }

enum DuctSizingMethod { velocity, equalFriction }

/// Design parameters shared across a sizing run.
class SizingContext {
  final Velocity maxSupplyVelocity;
  final Velocity maxDuctVelocity;
  final double drainageSlope; // m/m
  final double drainageFillRatio;
  final double drainageManningN;
  final PipeMaterial pipeMaterial;

  /// HVAC duct preferences.
  final DuctShape ductShape;
  final DuctSizingMethod ductMethod;
  final double ductEqualFrictionPa; // target Pa/m for the equal-friction method
  final double ductAspectRatio; // W:H for rectangular ducts

  const SizingContext({
    this.maxSupplyVelocity = const Velocity(2.0),
    this.maxDuctVelocity = const Velocity(5.0),
    this.drainageSlope = 0.01,
    this.drainageFillRatio = 0.5,
    this.drainageManningN = 0.010,
    this.pipeMaterial = PipeMaterial.pvc,
    this.ductShape = DuctShape.round,
    this.ductMethod = DuctSizingMethod.velocity,
    this.ductEqualFrictionPa = 1.0,
    this.ductAspectRatio = 1.5,
  });
}

/// Sizing outcome for one edge.
///
/// [diameter] is the circular size, or the circular-equivalent for a
/// rectangular duct; [width]/[height] are set only for rectangular ducts.
class EdgeSizing {
  final String edgeId;
  final ServiceType service;
  final FlowRate flow;
  final Diameter diameter;
  final Velocity velocity;
  final Length? width;
  final Length? height;

  const EdgeSizing({
    required this.edgeId,
    required this.service,
    required this.flow,
    required this.diameter,
    required this.velocity,
    this.width,
    this.height,
  });

  /// True when this edge is a rectangular duct (carries W×H).
  bool get isRectangular => width != null && height != null;
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
      if (ctx.ductShape == DuctShape.rectangular) {
        final r = duct.sizeRectangularByVelocity(
          airflow: flow,
          maxVelocity: ctx.maxDuctVelocity,
          aspectRatio: ctx.ductAspectRatio,
        );
        return EdgeSizing(
          edgeId: edge.id,
          service: edge.service,
          flow: flow,
          diameter: r.equivalentDiameter,
          velocity: r.actualVelocity,
          width: r.width,
          height: r.height,
        );
      }
      final r = ctx.ductMethod == DuctSizingMethod.equalFriction
          ? duct.sizeByEqualFriction(
              airflow: flow,
              targetPaPerMetre: ctx.ductEqualFrictionPa,
            )
          : duct.sizeByVelocity(
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
/// split into connected components, root each at its SOURCE (a plant, else a
/// non-demand entry leaf), apply demand at every other demand-bearing node
/// (terminals plus any inline fixture/diffuser), accumulate down the branches,
/// and size every edge. Branching is handled exactly (each leg sized for its
/// own subtree, the source connection for the total); edges with no demand are
/// left unsized.
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
  Map<String, double> nodeDrainageUnits = const {},
  Map<String, FlowRate> nodeFlowDemand = const {},
  FlushSystem flushSystem = FlushSystem.flushTank,
}) {
  const profile = SniProfile();
  final allFlows = <String, FlowRate>{};
  final sanitary = <String, EdgeSizing>{}; // DFU-sized drainage/vent edges
  final stormSizing = <String, EdgeSizing>{}; // rainwater downpipes

  bool isWaterSupply(ServiceType s) =>
      s == ServiceType.coldWater || s == ServiceType.hotWater;
  bool isSanitary(ServiceType s) =>
      s == ServiceType.drainage || s == ServiceType.vent;

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
    NodeRole? roleOf(String n) => net.nodeById(n)?.role;

    // The explicit per-node demand keys relevant to THIS service decide which
    // nodes "bear demand" (and so must not be chosen as the source root).
    final explicitDemandKeys = isSanitary(service)
        ? nodeDrainageUnits.keys.toSet()
        : useUbap
            ? nodeFixtureUnits.keys.toSet()
            : nodeFlowDemand.keys.toSet();

    // Pick the root (= source/sink) for a component. Accumulation gives every
    // edge the demand on its far side from the root, so the root's own demand
    // never traverses an edge — the root MUST therefore be a node that carries
    // no terminal load, or that load would silently vanish. Preference:
    //   1. an explicit plant (the marked source/sink);
    //   2. a non-fixture leaf bearing no demand (the drawn supply/outlet entry);
    //   3. the busiest interior junction bearing no demand (a manifold/collection
    //      hub — rooting here keeps EVERY terminal's load, whereas falling back
    //      to a fixture leaf would drop that fixture's demand);
    //   4. any leaf, else any node (degenerate component).
    String pickRoot(List<String> component, List<String> leaves) {
      for (final id in component) {
        if (roleOf(id) == NodeRole.plant) return id;
      }
      for (final id in leaves) {
        if (roleOf(id) != NodeRole.fixture && !explicitDemandKeys.contains(id)) {
          return id;
        }
      }
      String? hub;
      var hubDegree = 1;
      for (final id in component) {
        final d = degree(id);
        if (d > hubDegree &&
            roleOf(id) != NodeRole.fixture &&
            !explicitDemandKeys.contains(id)) {
          hub = id;
          hubDegree = d;
        }
      }
      if (hub != null) return hub;
      return leaves.isNotEmpty ? leaves.first : component.first;
    }

    // Build the terminal-demand map over EVERY demand-bearing node except the
    // root: a node with an explicit entry contributes it (even mid-run — an
    // inline fixture/diffuser is a degree-2 node), and a leaf with no entry
    // contributes the flat default. Pure interior junctions contribute nothing.
    Map<String, V> terminalMap<V>(
      List<String> component,
      String root,
      Map<String, V> explicit,
      V defaultForLeaf,
    ) {
      final out = <String, V>{};
      for (final n in component) {
        if (n == root) continue;
        final e = explicit[n];
        if (e != null) {
          out[n] = e;
        } else if (degree(n) == 1) {
          out[n] = defaultForLeaf;
        }
      }
      return out;
    }

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
      final root = pickRoot(component, leaves);

      // ── Looped (ring/grid) PRESSURIZED or AIR component → Hardy–Cross ───────
      // A tree has (nodes − 1) edges; more means parallel paths whose flow split
      // the unique-path accumulation can't resolve. Balance the split with
      // Hardy–Cross and size each edge from its share. Gravity services
      // (drainage/vent/rainwater) keep the tree path — physical rings there are
      // nonsensical. The resistance uses planar PIXEL length (calibration-
      // invariant for a same-sheet loop) under a uniform-diameter first-pass
      // assumption; risers count as short connectors. // VERIFY: a full design
      // re-balances against the sized diameters.
      final componentSet = component.toSet();
      final componentEdges = net.edges
          .where((e) =>
              e.service == service &&
              componentSet.contains(e.fromId) &&
              componentSet.contains(e.toId))
          .toList();
      final isLooped = componentEdges.length > component.length - 1;
      final regime = service.regime;
      if (isLooped &&
          (regime == FlowRegime.pressurized || regime == FlowRegime.air)) {
        final demandFlow = <String, double>{};
        for (final n in component) {
          if (n == root) continue;
          double f;
          if (useUbap) {
            final ubap = nodeFixtureUnits[n] ?? (degree(n) == 1 ? fuPerLeaf : 0.0);
            f = ubap <= 0
                ? 0.0
                : profile
                    .probableFlowForFixtureUnits(ubap, system: flushSystem)
                    .cubicMetersPerSecond;
          } else {
            final explicit = nodeFlowDemand[n];
            f = explicit != null
                ? explicit.cubicMetersPerSecond
                : (degree(n) == 1 ? demand.cubicMetersPerSecond : 0.0);
          }
          if (f != 0) demandFlow[n] = f;
        }
        final pxById = <String, double>{
          for (final e in componentEdges)
            e.id: () {
              final px = runPixelLength(e, net);
              return px > 1.0 ? px : 1.0;
            }(),
        };
        final balanced = balanceFlows(
          edges: [
            for (final e in componentEdges)
              (id: e.id, from: e.fromId, to: e.toId),
          ],
          root: root,
          demand: demandFlow,
          resistance: (id) => pxById[id]!,
          exponent: regime == FlowRegime.air ? 2.0 : 1.852,
        );
        for (final entry in balanced.edgeFlow.entries) {
          allFlows[entry.key] = FlowRate(entry.value.abs());
        }
        continue;
      }

      if (isSanitary(service)) {
        // Accumulate DRAINAGE FIXTURE UNITS and size each edge from the code
        // capacity table (branch vs stack), not from Manning flow.
        final terminalUnits =
            terminalMap(component, root, nodeDrainageUnits, kDefaultLeafDfu);
        final edgeUnits = accumulateFixtureUnits(
          net: net,
          service: service,
          rootId: root,
          terminalUnits: terminalUnits,
        );
        for (final entry in edgeUnits.entries) {
          final edge = net.edges.firstWhere((e) => e.id == entry.key);
          sanitary[entry.key] = _sizeSanitaryEdge(edge, entry.value, ctx);
        }
      } else if (service == ServiceType.rainwater) {
        // Accumulate storm runoff and size each downpipe from the rainwater
        // capacity table (not Manning).
        final terminalDemand =
            terminalMap(component, root, nodeFlowDemand, demand);
        final flows = accumulateFlows(
          net: net,
          service: service,
          rootId: root,
          terminalDemand: terminalDemand,
        );
        for (final entry in flows.entries) {
          final r = storm.sizeRainwaterDownpipe(entry.value);
          stormSizing[entry.key] = EdgeSizing(
            edgeId: entry.key,
            service: service,
            flow: entry.value,
            diameter: r.diameter,
            velocity: velocityFromFlow(entry.value, r.diameter),
          );
        }
      } else if (useUbap) {
        // Per-fixture UBAP when a node carries a fixture type; else the flat
        // default for that water service.
        final terminalUnits =
            terminalMap(component, root, nodeFixtureUnits, fuPerLeaf);
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
        // Per-node flow where set (e.g. a diffuser's airflow); else the flat
        // default for the service.
        final terminalDemand =
            terminalMap(component, root, nodeFlowDemand, demand);
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

  final result = sizeNetwork(net, allFlows, ctx);
  result.addAll(sanitary); // DFU-sized drainage/vent
  result.addAll(stormSizing); // capacity-table rainwater downpipes
  return result;
}

/// Build an [EdgeSizing] for a drainage/vent edge from its accumulated [dfu]
/// using the code capacity tables. Drainage edges report a reference full-bore
/// Manning velocity (for self-cleansing); vents have no flow velocity.
EdgeSizing _sizeSanitaryEdge(NetEdge edge, double dfu, SizingContext ctx) {
  final isStack = edge.kind == EdgeKind.riser;
  final Diameter d = edge.service == ServiceType.vent
      ? drain.ventDiameterForDfu(dfu)
      : drain.drainDiameterForDfu(dfu, isStack: isStack);
  final v = edge.service == ServiceType.vent
      ? const Velocity(0)
      : manningVelocity(
          manningN: ctx.drainageManningN,
          hydraulicRadius: Length(d.meters / 4.0),
          slope: ctx.drainageSlope,
        );
  return EdgeSizing(
    edgeId: edge.id,
    service: edge.service,
    flow: const FlowRate(0),
    diameter: d,
    velocity: v,
  );
}
