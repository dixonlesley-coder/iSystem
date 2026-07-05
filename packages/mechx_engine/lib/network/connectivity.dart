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

import 'network.dart';

/// What kind of supply-integrity problem a component has.
enum NetworkDefectKind {
  /// The component (pressurized/air) has no plant/source node at all.
  noSource,

  /// The component is plant-less but its SERVICE has another component WITH a
  /// plant — i.e. this branch is disconnected from the rooted/fed tree.
  disconnectedIsland,
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

  for (final service in net.edges.map((e) => e.service).toSet()) {
    // Only pressurized + air have a meaningful source/plant; skip gravity.
    if (service.regime == FlowRegime.gravity) continue;

    // Per-service adjacency over every edge of the service.
    final adjacency = <String, List<String>>{};
    final nodes = <String>{};
    for (final e in net.edges) {
      if (e.service != service) continue;
      nodes..add(e.fromId)..add(e.toId);
      (adjacency[e.fromId] ??= []).add(e.toId);
      (adjacency[e.toId] ??= []).add(e.fromId);
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

    // A service "has a source somewhere" when any component carries a plant.
    final serviceHasPlant =
        components.any((c) => c.any(isPlant));

    for (final component in components) {
      if (component.isEmpty) continue;
      if (component.any(isPlant)) continue; // this component is fed
      // A plant-less component: an island if the service is otherwise fed,
      // else the whole service has no source.
      defects.add(NetworkComponentDefect(
        service: service,
        nodeIds: component,
        kind: serviceHasPlant
            ? NetworkDefectKind.disconnectedIsland
            : NetworkDefectKind.noSource,
      ));
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
        !_isValidTermination(node)) {
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
