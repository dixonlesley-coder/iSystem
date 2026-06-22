import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/network/zoning.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/sizing/supply_design.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

import 'network_store.dart';
import 'project_store.dart';
import 'sizing_store.dart';

/// Live node-pressure solve for the cold-water network — the single solve that
/// feeds the pump-head readout and the pressure heatmap (§12). Recomputes
/// whenever the network, sizing, or building change. Null when there's no
/// cold-water network to solve.
final solveProvider = Provider<PressureSolution?>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final sizing = ref.watch(sizingProvider);
  final project = ref.watch(projectControllerProvider);

  final coldEdges =
      net.edges.where((e) => e.service == ServiceType.coldWater).toList();
  if (coldEdges.isEmpty) return null;
  final source = _pickSource(net, coldEdges, project.building);
  if (source == null) return null;

  final edgeFlows = <String, FlowRate>{
    for (final e in coldEdges)
      if (sizing[e.id] != null) e.id: sizing[e.id]!.flow,
  };

  return solvePressurized(
    net: net,
    service: ServiceType.coldWater,
    sourceId: source,
    edgeFlows: edgeFlows,
    sizing: sizing,
    calibrationBySheet: project.calibrations,
    building: project.building,
    targetResidual:
        SupplyDesignCriteria.recommended().targetFixtureResidualPressure,
  );
});

/// Pick the supply source for the solve. The source is the pump/tank entry, NOT
/// an arbitrary fixture: choosing the wrong leaf would invert the tree and
/// mis-assign static lift. Preference order over the cold-water subgraph:
///   1. an explicit [NodeRole.plant] node (the tank/pump);
///   2. otherwise the LOWEST-elevation node — the supply entry for an upfeed
///      system (water rises from the riser base to the fixtures).
/// Ties break on a degree-1 leaf, then the first node seen (deterministic).
String? _pickSource(Network net, List<NetEdge> edges, BuildingLevels building) {
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

  // 1. An explicit plant node wins (the lowest, if several).
  final plants = candidates.where((n) => n.role == NodeRole.plant).toList();
  if (plants.isNotEmpty) {
    plants.sort((a, b) => nodeElevation(a, building)
        .meters
        .compareTo(nodeElevation(b, building).meters));
    return plants.first.id;
  }

  // 2. Lowest-elevation node; tie-break to a leaf, then deterministic order.
  NetNode? best;
  for (final n in candidates) {
    if (best == null) {
      best = n;
      continue;
    }
    final ne = nodeElevation(n, building).meters;
    final be = nodeElevation(best, building).meters;
    if (ne < be ||
        (ne == be && (degree[n.id] ?? 0) < (degree[best.id] ?? 0)) ||
        (ne == be &&
            (degree[n.id] ?? 0) == (degree[best.id] ?? 0) &&
            n.id.compareTo(best.id) < 0)) {
      best = n;
    }
  }
  return best?.id;
}

/// Pump duty for the cold-water system: the solved required head at the trunk
/// (largest-flow) cold-water flow. Null when there's nothing to pump.
final pumpDutyProvider = Provider<PumpDuty?>((ref) {
  final solution = ref.watch(solveProvider);
  if (solution == null) return null;
  final sizing = ref.watch(sizingProvider);
  final net = ref.watch(networkControllerProvider).network;
  var flow = const FlowRate(0);
  for (final e in net.edges) {
    if (e.service != ServiceType.coldWater) continue;
    final s = sizing[e.id];
    if (s != null &&
        s.flow.cubicMetersPerSecond > flow.cubicMetersPerSecond) {
      flow = s.flow;
    }
  }
  if (flow.cubicMetersPerSecond <= 0) return null;
  return sizePump(flow: flow, head: solution.requiredPumpHead);
});

/// Pressure zones for the building under the SNI max-fixture-pressure limit.
final zonesProvider = Provider<List<PressureZone>>((ref) {
  final building = ref.watch(projectControllerProvider).building;
  return computeDownfeedZones(
    building: building,
    maxStaticPressure: const SniProfile().maxFixtureStaticPressure.value,
  );
});

/// Bill of materials for the sized network.
final bomProvider = Provider<List<BomLine>>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final sizing = ref.watch(sizingProvider);
  if (sizing.isEmpty) return const [];
  final project = ref.watch(projectControllerProvider);
  return buildBom(
    net: net,
    sizing: sizing,
    calibrationBySheet: project.calibrations,
    building: project.building,
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
