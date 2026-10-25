/// Pure-Dart network connectivity / supply-integrity DETECTOR (zero Flutter
/// imports, runnable under `dart test`).
///
/// This is a READ-ONLY validation helper layered alongside `network_sizing.dart`
/// — it changes NO sizing. It re-uses the same per-service adjacency +
/// connected-components walk the sizer performs, then flags two integrity
/// defects that the sizer silently tolerates:
///
///   • [NetworkDefectKind.noSource] — a pressurized/air component with no
///     [NodeRole.plant] node. The sizer's `pickRoot` falls back to a heuristic
///     root (a non-fixture entry leaf, or the busiest junction) so the network
///     STILL sizes, as if a supply existed where there is none. That is exactly
///     the unfed case worth surfacing before sizing/export.
///   • [NetworkDefectKind.disconnectedIsland] — when a service has MORE than one
///     component AND at least one of them carries a plant, every OTHER
///     (plant-less) component is a branch that fell off the rooted tree (rather
///     than "the whole service is unfed").
///
/// GRAVITY services (drainage / vent / rainwater) are SKIPPED: a physical
/// source/ring there is nonsensical — a drain legitimately has no plant — so a
/// gravity component is never a defect here (see CLAUDE.md gravity-loop note).
library;

import '../sizing/fire_index_friction.dart' show isFireService;
import '../sizing/network_sizing.dart' show airOpenBoundaryLeaves;
import 'network.dart';

/// What kind of supply-integrity problem a component has.
enum NetworkDefectKind {
  /// The component (pressurized/air) has no plant/source node at all.
  noSource,

  /// The component is plant-less but its SERVICE has another component WITH a
  /// plant — i.e. this branch is disconnected from the rooted/fed tree.
  disconnectedIsland,

  /// Round 25 — a cold/hot WATER component with no plant whose open END is a
  /// water meter: it is fed straight from the mains (PDAM). Not a drawing
  /// defect, but the mains pressure is not modelled — an ADVISORY (the app
  /// surfaces it as an acknowledgeable info), never the no-source warning.
  mainsFed,
}

/// One detected supply-integrity defect: the [service] it belongs to, the
/// [nodeIds] of the offending component (sorted for deterministic output), and
/// the [kind].
class NetworkComponentDefect {
  final ServiceType service;
  final List<String> nodeIds;
  final NetworkDefectKind kind;

  const NetworkComponentDefect({
    required this.service,
    required this.nodeIds,
    required this.kind,
  });

  /// True for the "no plant anywhere in the component" defect.
  bool get isNoSource => kind == NetworkDefectKind.noSource;

  /// True for the "branch fell off the rooted tree" defect.
  bool get isIsland => kind == NetworkDefectKind.disconnectedIsland;

  /// True for a water component fed from the mains through a drawn meter.
  bool get isMainsFed => kind == NetworkDefectKind.mainsFed;

  /// A representative node id for locating the defect on a sheet (the first
  /// node id, deterministic since [nodeIds] is sorted). Null only when the
  /// component is empty (never, for a defect).
  String? get representativeNodeId => nodeIds.isEmpty ? null : nodeIds.first;
}

/// Detect every supply-integrity defect in [net] across all PRESSURIZED/AIR
/// services. Pure: re-uses the sizer's connected-components walk, never sizes.
///
/// For each such service:
///   1. build the per-service adjacency over EVERY edge of the service
///      (regardless of run/riser — risers connect floors, exactly as the sizer
///      includes them);
///   2. split into connected components;
///   3. a component with ZERO plant nodes is a defect — classified as an
///      [NetworkDefectKind.disconnectedIsland] when the SAME service has another
///      component that DOES carry a plant, else [NetworkDefectKind.noSource].
List<NetworkComponentDefect> networkConnectivityDefects(Network net) {
  final defects = <NetworkComponentDefect>[];

  // Round 48 (mech-convergence-3-combined-standpipe-false-no-source) — the
  // two FIRE services form ONE adjacency class: a sprinkler branch tapped off
  // a hydrant riser (the combined sprinkler/standpipe high-rise riser) is fed
  // by the riser's fire pump, exactly as `fireSystems` / the fire stores read
  // it. Every other service is its own class. Defects are still reported per
  // SERVICE present in an unfed component, so kinds / locates stay stable.
  Object classOf(ServiceType s) => isFireService(s) ? 'fire' : s;
  final classes = <Object, Set<ServiceType>>{};
  for (final e in net.edges) {
    if (e.service.regime == FlowRegime.gravity) continue;
    (classes[classOf(e.service)] ??= <ServiceType>{}).add(e.service);
  }
  for (final members in classes.values) {
    // Adjacency over every edge of the class (runs and risers alike).
    final adjacency = <String, List<String>>{};
    final nodes = <String>{};
    final nodesByService = <ServiceType, Set<String>>{};
    for (final e in net.edges) {
      if (!members.contains(e.service)) continue;
      nodes..add(e.fromId)..add(e.toId);
      (adjacency[e.fromId] ??= []).add(e.toId);
      (adjacency[e.toId] ??= []).add(e.fromId);
      (nodesByService[e.service] ??= <String>{})
        ..add(e.fromId)
        ..add(e.toId);
    }

    bool isPlant(String id) => net.nodeById(id)?.role == NodeRole.plant;

    // Connected components (same walk shape as network_sizing.dart).
    final seen = <String>{};
    final components = <List<String>>[];
    for (final start in nodes) {
      if (seen.contains(start)) continue;
      final component = <String>[];
      final stack = [start];
      seen.add(start);
      while (stack.isNotEmpty) {
        final n = stack.removeLast();
        component.add(n);
        final links = adjacency[n];
        if (links != null) {
          for (final other in links) {
            if (seen.add(other)) stack.add(other);
          }
        }
      }
      component.sort();
      components.add(component);
    }

    // Round 25 — a degree-1 water meter on a cold/hot water service is the
    // mains connection (a direct-from-PDAM building draws no tank or pump).
    final isWater = members.contains(ServiceType.coldWater) ||
        members.contains(ServiceType.hotWater);
    bool isMainsEntry(String id) =>
        isWater &&
        net.nodeById(id)?.component == NodeComponent.waterMeter &&
        (adjacency[id]?.length ?? 0) == 1;
    bool mainsFed(List<String> c) => c.any(isMainsEntry);

    // A class "has a source somewhere" when any component carries a plant
    // (or, on water, a mains meter).
    final serviceHasPlant =
        components.any((c) => c.any(isPlant) || mainsFed(c));

    final ordered = members.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    for (final component in components) {
      if (component.isEmpty) continue;
      if (component.any(isPlant)) continue; // this component is fed
      final kind = mainsFed(component)
          ? NetworkDefectKind.mainsFed
          // A plant-less component: an island if the class is otherwise
          // fed, else the whole class has no source.
          : serviceHasPlant
              ? NetworkDefectKind.disconnectedIsland
              : NetworkDefectKind.noSource;
      for (final service in ordered) {
        final own = nodesByService[service]!;
        final ids = members.length == 1
            ? component
            : [
                for (final id in component)
                  if (own.contains(id)) id,
              ];
        if (ids.isEmpty) continue;
        defects.add(NetworkComponentDefect(
          service: service,
          nodeIds: ids,
          kind: kind,
        ));
      }
    }
  }

  return defects;
}

/// What kind of per-ELEMENT (node-level) connectivity problem a node has —
/// complementary to the component-level [NetworkDefectKind]. Where that flags a
/// whole pressurized/air component with no source, this flags an INDIVIDUAL node
/// drawn wrong.
enum NetworkElementDefectKind {
  /// A degree-1 distribution [NodeRole.main] on a PRESSURIZED or AIR service that
  /// dead-ends WITHOUT a valid termination — a pressure pipe / duct drawn to
  /// nowhere (it should end at a fixture / terminal / plant). GRAVITY services
  /// (drainage / vent / rainwater) are excluded: a bare degree-1 end there is a
  /// legitimate terminus (soil-stack outfall, vent-through-roof, rainwater
  /// discharge), so it is never a loose-end (see [networkElementDefects]).
  looseEnd,

  /// A degree-0 node — placed on the sheet but connected to nothing (an unplaced
  /// tank/pump/fixture, or a stray click). Applies to a node of any role.
  orphan,
}

/// One per-node connectivity defect: the [nodeId], the [kind], and — for a
/// [NetworkElementDefectKind.looseEnd] — the [service] of the single incident
/// edge. [service] is null for an [NetworkElementDefectKind.orphan] (a degree-0
/// node has no incident edge, hence no service).
class NetworkElementDefect {
  final String nodeId;
  final ServiceType? service;
  final NetworkElementDefectKind kind;

  const NetworkElementDefect({
    required this.nodeId,
    this.service,
    required this.kind,
  });

  /// True for the "placed but connected to nothing" defect.
  bool get isOrphan => kind == NetworkElementDefectKind.orphan;

  /// True for the "dangling degree-1 main" defect.
  bool get isLooseEnd => kind == NetworkElementDefectKind.looseEnd;
}

/// Whether [node] is a legitimate END of a run — a terminal / equipment where a
/// pipe/duct is SUPPOSED to stop, so a degree-1 node there is by design and
/// never a [NetworkElementDefectKind.looseEnd]. True when ANY of:
///   • a non-[NodeRole.main] role ([NodeRole.fixture] / [NodeRole.plant] are
///     ends by definition);
///   • a served plumbing [NetNode.fixture] or user [NetNode.customFixtureId];
///   • a design [NetNode.airflow] (a diffuser / grille air terminal);
///   • a [NetNode.roofAreaM2] (a rainwater outlet catchment);
///   • ANY placed [NetNode.component] — every [NodeComponent] value is real
///     equipment or a real marker (pump / tank / valve / meter / drain /
///     diffuser / AC / riser connection point); the enum has NO "bare junction"
///     value, so a bare fitting is exactly `component == null`.
bool _isValidTermination(NetNode node) =>
    node.role != NodeRole.main ||
    node.fixture != null ||
    node.customFixtureId != null ||
    node.airflow != null ||
    node.roofAreaM2 != null ||
    node.component != null;

/// Round 31 (hvac-5-2) — whether the bare degree-1 node [leafId] is an AIR
/// unit's OPEN BOUNDARY: its single duct reaches an air-unit PLANT (AHU, FCU,
/// supply / exhaust fan, AC unit) directly or through degree-2 inline dampers
/// that carry no airflow. That is exactly the drawing the sizer treats as the
/// unit's outdoor-air INTAKE (Round 16/17 — sized on the delivered airflow,
/// its friction added to the fan static) or an extract unit's DISCHARGE to
/// outside, so it is a legitimate end, never a loose end. A bare leaf off a
/// bare junction is still an undrawn terminal (not walked through). Round
/// 32: only when the unit is the one the sizer ROOTS the component at
/// ([airOpenBoundaryLeaves]) — a bare leaf off a non-root FCU is a default
/// terminal the sizer loads, so it stays a loose end. Pure.
bool isAirOpenBoundaryLeaf(Network net, String leafId) {
  final leaf = net.nodeById(leafId);
  if (leaf == null ||
      leaf.role != NodeRole.main ||
      leaf.component != null ||
      leaf.airflow != null) {
    return false;
  }
  final first = net.edgesAt(leafId);
  if (first.length != 1 || first.single.service.regime != FlowRegime.air) {
    return false;
  }
  var edge = first.single;
  var here = leafId;
  final seen = <String>{leafId};
  while (true) {
    final next = edge.fromId == here ? edge.toId : edge.fromId;
    if (!seen.add(next)) return false;
    final n = net.nodeById(next);
    if (n == null) return false;
    // Round 32 — the structural walk is only a prefilter: the leaf is an
    // open boundary exactly when the SIZER treats it as one (an intake off
    // the component's ROOT unit, [airOpenBoundaryLeaves]). A bare leaf off a
    // non-root terminal FCU is loaded as a default terminal there, so it is
    // still a loose end here.
    if (n.role == NodeRole.plant) {
      return _isAirUnitComponent(n.component) &&
          airOpenBoundaryLeaves(net).contains(leafId);
    }
    final c = n.component;
    final damper = c == NodeComponent.motorizedDamper ||
        c == NodeComponent.volumeDamper ||
        c == NodeComponent.fireDamper;
    final onward = [
      for (final e in net.edgesAt(next))
        if (e.id != edge.id) e,
    ];
    if (!damper || n.airflow != null || onward.length != 1) return false;
    here = next;
    edge = onward.single;
  }
}

bool _isAirUnitComponent(NodeComponent? c) => switch (c) {
      NodeComponent.ahu ||
      NodeComponent.fcu ||
      NodeComponent.supplyFan ||
      NodeComponent.exhaustFan ||
      NodeComponent.acCassette ||
      NodeComponent.acSplitWall ||
      NodeComponent.acDucted =>
        true,
      _ => false,
    };

/// Detect every per-ELEMENT connectivity defect in [net]:
///   • [NetworkElementDefectKind.orphan] — a node in [Network.nodes] with degree
///     0 (connected to nothing);
///   • [NetworkElementDefectKind.looseEnd] — a degree-1 [NodeRole.main] that is
///     not a valid termination ([_isValidTermination]).
///
/// A node's degree counts every incident edge across the WHOLE graph (all
/// services), matching [Network.edgesAt]. Pure + read-only — never sizes.
/// Deterministic: the result is sorted by node id.
List<NetworkElementDefect> networkElementDefects(Network net) {
  // Incident edges per node across every service. An edge is counted once per
  // node (a degenerate self-loop counts once), mirroring Network.edgesAt.
  final incident = <String, List<NetEdge>>{};
  for (final e in net.edges) {
    (incident[e.fromId] ??= []).add(e);
    if (e.toId != e.fromId) (incident[e.toId] ??= []).add(e);
  }

  final defects = <NetworkElementDefect>[];
  for (final node in net.nodes) {
    final edges = incident[node.id];
    final degree = edges?.length ?? 0;
    if (degree == 0) {
      defects.add(NetworkElementDefect(
        nodeId: node.id,
        kind: NetworkElementDefectKind.orphan,
      ));
    } else if (degree == 1 &&
        node.role == NodeRole.main &&
        edges!.single.service.regime != FlowRegime.gravity &&
        !_isValidTermination(node) &&
        !isAirOpenBoundaryLeaf(net, node.id)) {
      // GRAVITY (drainage / vent / rainwater) is SKIPPED for loose-ends, exactly
      // as networkConnectivityDefects skips it (lines 19-21): a degree-1 bare end
      // there is the NORMAL way to draw a legitimate terminus — a soil-stack
      // outfall to the sewer, a vent-through-roof, a rainwater discharge — none
      // of which the sizer needs connected (it roots gravity components at these
      // bare leaves). Only PRESSURIZED + AIR bare ends are genuinely "drawn to
      // nowhere" (a pressure pipe/duct should terminate at a fixture/terminal/
      // plant, never open air). A degree-0 gravity node is still an orphan above.
      defects.add(NetworkElementDefect(
        nodeId: node.id,
        service: edges.single.service,
        kind: NetworkElementDefectKind.looseEnd,
      ));
    }
  }

  defects.sort((a, b) => a.nodeId.compareTo(b.nodeId));
  return defects;
}
