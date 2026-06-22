import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/duct_static.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/network/zoning.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/fan.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/sizing/supply_design.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

import 'app_state.dart';
import 'network_store.dart';
import 'project_store.dart';
import 'sizing_store.dart';

Pressure get _targetResidual =>
    SupplyDesignCriteria.recommended().targetFixtureResidualPressure;

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
  final net = ref.watch(networkControllerProvider).network;
  final sizing = ref.watch(sizingProvider);
  final project = ref.watch(projectControllerProvider);
  final edges = _supplyEdges(net);
  if (edges.isEmpty) return null;
  final source = _pickSource(net, edges, project.building, preferHighest: false);
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
  );
});

/// DOWNFEED gravity solve (roof tank distributing down). Null when the strategy
/// is upfeed or there is no supply network.
final downfeedProvider = Provider<DownfeedSolution?>((ref) {
  if (ref.watch(feedStrategyProvider) != FeedStrategy.downfeed) return null;
  final net = ref.watch(networkControllerProvider).network;
  final sizing = ref.watch(sizingProvider);
  final project = ref.watch(projectControllerProvider);
  final edges = _supplyEdges(net);
  if (edges.isEmpty) return null;
  final tank = _pickSource(net, edges, project.building, preferHighest: true);
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
  );
});

/// Residual pressure at every solved node, regardless of feed strategy — the
/// single field the heatmap renders (§12).
final residualByNodeProvider = Provider<Map<String, Pressure>>((ref) {
  final up = ref.watch(solveProvider);
  if (up != null) return up.residualPressure;
  final down = ref.watch(downfeedProvider);
  if (down != null) return down.residualPressure;
  return const {};
});

/// Pick the supply source/tank. The source is the pump/tank entry, NOT an
/// arbitrary fixture: the wrong leaf would invert the tree and mis-assign static
/// lift. Preference: an explicit [NodeRole.plant] node, else the extreme-
/// elevation node — LOWEST for upfeed (riser base), HIGHEST for downfeed (roof
/// tank). [preferHighest] selects the direction.
String? _pickSource(
  Network net,
  List<NetEdge> edges,
  BuildingLevels building, {
  required bool preferHighest,
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
  double elev(NetNode n) => nodeElevation(n, building).meters;
  bool better(double a, double b) => preferHighest ? a > b : a < b;

  // 1. An explicit plant node wins (the extreme one for this strategy).
  final plants = candidates.where((n) => n.role == NodeRole.plant).toList();
  if (plants.isNotEmpty) {
    plants.sort((a, b) =>
        preferHighest ? elev(b).compareTo(elev(a)) : elev(a).compareTo(elev(b)));
    return plants.first.id;
  }

  // 2. Extreme-elevation node; tie-break to a leaf, then deterministic order.
  NetNode? best;
  for (final n in candidates) {
    if (best == null) {
      best = n;
      continue;
    }
    final ne = elev(n);
    final be = elev(best);
    if (better(ne, be) ||
        (ne == be && (degree[n.id] ?? 0) < (degree[best.id] ?? 0)) ||
        (ne == be &&
            (degree[n.id] ?? 0) == (degree[best.id] ?? 0) &&
            n.id.compareTo(best.id) < 0)) {
      best = n;
    }
  }
  return best?.id;
}

/// Pump duty for an UPFEED supply at the trunk (largest-flow) cold-water flow.
/// Null in downfeed (gravity-fed) or when there's nothing to pump.
final pumpDutyProvider = Provider<PumpDuty?>((ref) {
  final solution = ref.watch(solveProvider);
  if (solution == null) return null;
  final sizing = ref.watch(sizingProvider);
  final net = ref.watch(networkControllerProvider).network;
  var flow = const FlowRate(0);
  for (final e in net.edges) {
    if (e.service != kSupplyService) continue;
    final s = sizing[e.id];
    if (s != null &&
        s.flow.cubicMetersPerSecond > flow.cubicMetersPerSecond) {
      flow = s.flow;
    }
  }
  if (flow.cubicMetersPerSecond <= 0) return null;
  return sizePump(flow: flow, head: solution.requiredPumpHead);
});

/// Fan duty for the supply/return duct system: total airflow at the trunk
/// (largest-flow duct) against the fan total static pressure from the index
/// run. Null when there's no duct network sized.
final ductFanProvider = Provider<FanDuty?>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final sizing = ref.watch(sizingProvider);
  final project = ref.watch(projectControllerProvider);

  final ductEdges =
      net.edges.where((e) => e.service == ServiceType.duct).toList();
  if (ductEdges.isEmpty) return null;

  // Trunk airflow = the largest sized duct flow.
  var airflow = const FlowRate(0);
  final edgeFlows = <String, FlowRate>{};
  for (final e in ductEdges) {
    final s = sizing[e.id];
    if (s == null) continue;
    edgeFlows[e.id] = s.flow;
    if (s.flow.cubicMetersPerSecond > airflow.cubicMetersPerSecond) {
      airflow = s.flow;
    }
  }
  if (airflow.cubicMetersPerSecond <= 0) return null;

  // Fan node: a plant (AHU) on the duct subgraph, else any duct node
  // (deterministic) — the index-run static is the same magnitude regardless.
  final ductNodeIds = <String>{
    for (final e in ductEdges) ...[e.fromId, e.toId],
  };
  String fan = ductNodeIds.reduce((a, b) => a.compareTo(b) < 0 ? a : b);
  for (final id in ductNodeIds) {
    if (net.nodeById(id)?.role == NodeRole.plant) {
      fan = id;
      break;
    }
  }

  final stat = solveDuctStatic(
    net: net,
    service: ServiceType.duct,
    fanNodeId: fan,
    edgeFlows: edgeFlows,
    sizing: sizing,
    calibrationBySheet: project.calibrations,
    building: project.building,
  );
  return sizeFan(airflow: airflow, totalStaticPressure: stat.totalStaticPressure);
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
