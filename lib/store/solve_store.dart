import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  final source = _pickSource(coldEdges);
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

/// Pick a source node for the solve: prefer a leaf (degree 1) of the cold-water
/// subgraph (the supply entry / most-remote end), else the first node seen.
String? _pickSource(List<NetEdge> edges) {
  final degree = <String, int>{};
  String? first;
  for (final e in edges) {
    first ??= e.fromId;
    degree[e.fromId] = (degree[e.fromId] ?? 0) + 1;
    degree[e.toId] = (degree[e.toId] ?? 0) + 1;
  }
  for (final entry in degree.entries) {
    if (entry.value == 1) return entry.key;
  }
  return first;
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
