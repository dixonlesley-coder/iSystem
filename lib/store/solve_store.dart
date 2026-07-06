import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/duct_static.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/network/zoning.dart';
import 'package:mechx_engine/pressure_field.dart';
import 'package:mechx_engine/sizing/air_velocity.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/fan.dart';
import 'package:mechx_engine/sizing/hot_water.dart';
import 'package:mechx_engine/sizing/consumables.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/pipe_optimizer.dart';
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

/// The absolute pass threshold the pressure solve holds at the critical fixture
/// (the design target residual, ≈2.25 bar). Exposed so the heatmap legend's
/// threshold anchor and the per-node inspector probe (I2) read the SAME value
/// the solve used, instead of the heatmap's relative min/max alone.
final targetResidualProvider = Provider<Pressure>((ref) => _targetResidual);

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
  final net = ref.watch(sizingNetworkProvider);
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
  final net = ref.watch(sizingNetworkProvider);
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

/// Per-edge WATER / DRAINAGE velocity checks keyed by edge id — the non-air
/// (pressurized / gravity) analogue of [airVelocityChecksProvider] (I3). Pipe
/// velocity is a code-driven sizing input (SNI 03-7065-2005 caps supply velocity
/// at 2,0 m/s) that was previously invisible for water/drainage runs, showing
/// only for air ducts. Reuses the SAME [VelocityCheck] verdict idiom, judged
/// against the SNI max pipe velocity from [SniProfile] (supply 2,0 m/s / drain
/// 3,0 m/s) — the max is the compliance gate, so the band minimum is 0 (only an
/// over-velocity pipe warns; the too-low branch never fires and no NEW band is
/// invented). Only edges with a positive solved velocity are included, so a vent
/// (no flow velocity) is omitted. Read-only — it never resizes anything.
final waterVelocityChecksProvider = Provider<Map<String, VelocityCheck>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  const profile = SniProfile();
  final out = <String, VelocityCheck>{};
  for (final e in net.edges) {
    if (e.service.isAir) continue;
    final s = sizing[e.id];
    if (s == null || s.velocity.metersPerSecond <= 0) continue;
    final max = e.service.regime == FlowRegime.gravity
        ? profile.maxDrainVelocity.value
        : profile.maxSupplyVelocity.value;
    out[e.id] =
        checkVelocityBand(s.velocity, min: const Velocity(0), max: max);
  }
  return out;
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
  final net = ref.watch(sizingNetworkProvider);
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

/// Trunk airflow + index-run static for one air [service]. Zero when the
/// service has no sized edges.
({FlowRate trunk, Pressure stat}) _airSystem(
  Network net,
  Map<String, EdgeSizing> sizing,
  ProjectState project,
  ServiceType service,
) {
  final edges = net.edges.where((e) => e.service == service).toList();
  if (edges.isEmpty) return (trunk: const FlowRate(0), stat: const Pressure(0));

  var trunk = const FlowRate(0);
  final flows = <String, FlowRate>{};
  for (final e in edges) {
    final s = sizing[e.id];
    if (s == null) continue;
    flows[e.id] = s.flow;
    if (s.flow.cubicMetersPerSecond > trunk.cubicMetersPerSecond) {
      trunk = s.flow;
    }
  }
  if (trunk.cubicMetersPerSecond <= 0) {
    return (trunk: const FlowRate(0), stat: const Pressure(0));
  }

  final ids = <String>{
    for (final e in edges) ...[e.fromId, e.toId],
  };
  var fan = ids.reduce((a, b) => a.compareTo(b) < 0 ? a : b);
  for (final id in ids) {
    if (net.nodeById(id)?.role == NodeRole.plant) {
      fan = id;
      break;
    }
  }
  final s = solveDuctStatic(
    net: net,
    service: service,
    fanNodeId: fan,
    edgeFlows: flows,
    sizing: sizing,
    calibrationBySheet: project.calibrations,
    building: project.building,
  );
  return (trunk: trunk, stat: s.totalStaticPressure);
}

/// Fan duty for the air system: supply trunk airflow against the SUM of the
/// supply and return index-run statics (the AHU fan sees both). Null when
/// there's no sized air network.
final ductFanProvider = Provider<FanDuty?>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  final project = ref.watch(projectControllerProvider);

  final supply = _airSystem(net, sizing, project, ServiceType.duct);
  final ret = _airSystem(net, sizing, project, ServiceType.returnAir);
  final airflow = supply.trunk.cubicMetersPerSecond > 0
      ? supply.trunk
      : ret.trunk; // return-only systems still get a fan
  if (airflow.cubicMetersPerSecond <= 0) return null;

  return sizeFan(
    airflow: airflow,
    totalStaticPressure: Pressure(supply.stat.pascals + ret.stat.pascals),
  );
});

/// Supply vs return trunk airflow (L/s) for the air-balance readout. Null when
/// there's no sized air network.
final airBalanceProvider = Provider<({double supplyLps, double returnLps})?>(
  (ref) {
    final net = ref.watch(sizingNetworkProvider);
    final sizing = ref.watch(sizingProvider);
    final project = ref.watch(projectControllerProvider);
    final s = _airSystem(net, sizing, project, ServiceType.duct);
    final r = _airSystem(net, sizing, project, ServiceType.returnAir);
    if (s.trunk.cubicMetersPerSecond <= 0 &&
        r.trunk.cubicMetersPerSecond <= 0) {
      return null;
    }
    return (
      supplyLps: s.trunk.inLitersPerSecond,
      returnLps: r.trunk.inLitersPerSecond,
    );
  },
);

/// Pressure zones for a downfeed building. Zones are bounded so the lowest
/// fixture stays under the SNI max-fixture-pressure limit AFTER the PRV holds
/// the target residual at the zone top — i.e. the effective span ceiling is
/// (max-fixture − target-residual).
final zonesProvider = Provider<List<PressureZone>>((ref) {
  final building = ref.watch(projectControllerProvider).building;
  final maxFix = const SniProfile().maxFixtureStaticPressure.value;
  final effective = Pressure(
    (maxFix.pascals - _targetResidual.pascals).clamp(1.0, double.infinity),
  );
  return computeDownfeedZones(building: building, maxStaticPressure: effective);
});

/// Per-zone PRV static profile (top residual → bottom static, within-limit) for
/// a downfeed system holding [_targetResidual] at each zone top.
final zoneStaticsProvider = Provider<List<DownfeedZoneStatic>>((ref) {
  final building = ref.watch(projectControllerProvider).building;
  final zones = ref.watch(zonesProvider);
  return downfeedZoneStatics(
    building: building,
    zones: zones,
    prvSetpoint: _targetResidual,
    maxStatic: const SniProfile().maxFixtureStaticPressure.value,
  );
});

/// Bill of materials for the sized network.
final bomProvider = Provider<List<BomLine>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
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

/// Continuous pipe chains (maximal collinear same-service/-diameter run
/// segments merged through pass-through vertices) — the basis for placing stock
/// couplings efficiently and for the cut plan. Empty when nothing is sized.
final pipeChainsProvider = Provider<List<PipeChain>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  if (sizing.isEmpty) return const [];
  final project = ref.watch(projectControllerProvider);
  return buildPipeChains(
    net: net,
    sizing: sizing,
    calibrationBySheet: project.calibrations,
    building: project.building,
  );
});

/// The stock-pipe CUT PLAN per (service, diameter): how many 4 m (PVC/PPR) /
/// 6 m (steel) stock bars are needed, with offcut reuse, and the resulting
/// waste. The efficiency engine behind the on-canvas coupling marks.
final pipeCutPlanProvider = Provider<List<PipeCutGroup>>((ref) {
  return buildPipeCutPlan(ref.watch(pipeChainsProvider));
});

/// Hot-water recirculation design for the drawn hot-water network: the loop is
/// the total hot-water pipe length, heat loss is estimated per metre, and the
/// return diameter defaults to the smallest hot-water size. Null when there's
/// no hot-water network.
final hotWaterRecircProvider = Provider<HotWaterRecircDesign?>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  final project = ref.watch(projectControllerProvider);
  final hwEdges =
      net.edges.where((e) => e.service == ServiceType.hotWater).toList();
  if (hwEdges.isEmpty) return null;

  var lenM = 0.0;
  var minDia = double.infinity;
  for (final e in hwEdges) {
    lenM += edgeLength(
      e,
      net,
      calibrationBySheet: project.calibrations,
      building: project.building,
    ).meters;
    final s = sizing[e.id];
    if (s != null) minDia = math.min(minDia, s.diameter.meters);
  }
  if (lenM <= 0) return null;
  final loop = Length(lenM);
  return sizeHotWaterRecirculation(
    heatLoss: heatLossFromLength(loopLength: loop),
    loopLength: loop,
    returnDiameter: minDia.isFinite ? Diameter(minDia) : Diameter.mm(20),
  );
});

/// Anti-Legionella advisory over the modelled hot-water recirculation: the
/// modelled return temperature (°C) when it falls below the safe floor
/// (`kLegionellaMinReturnTempC` ≈ 55 °C), else null. Read-only — it never
/// resizes; the Review panel surfaces it. Null when there's no hot-water loop or
/// the return is hot enough. // VERIFY threshold vs SNI / WHO guidance.
final hotWaterLegionellaProvider = Provider<double?>((ref) {
  final hwr = ref.watch(hotWaterRecircProvider);
  if (hwr == null || !hwr.legionellaRisk) return null;
  return hwr.returnTempC;
});

/// Jointing-consumables estimate (PVC solvent cement cans, duct sealant
/// cartridges, thread-tape rolls) for the quotation. Joints come from the
/// fittings + inline pipe couplings; duct sealant from the duct joint length.
final consumablesProvider = Provider<ConsumablesEstimate>((ref) {
  final fittings = ref.watch(fittingsProvider);
  final chains = ref.watch(pipeChainsProvider);
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  final project = ref.watch(projectControllerProvider);

  final solventByDn = <int, int>{};
  var threaded = 0;
  // Fitting sockets (each is a made joint), grouped by the service join method.
  for (final f in fittings) {
    final joints = fittingSockets(f.type) * f.count;
    switch (joinMethodForService(f.service)) {
      case PipeJoinMethod.solventWeld:
        solventByDn[f.diameterMm] = (solventByDn[f.diameterMm] ?? 0) + joints;
      case PipeJoinMethod.threaded:
        threaded += joints;
      case PipeJoinMethod.heatFusion:
      case PipeJoinMethod.other:
        break;
    }
  }
  // Inline couplings along straight pipe chains (sections − 1 per chain).
  for (final c in chains) {
    if (c.service.regime == FlowRegime.air) continue;
    final sections = (c.lengthM / c.stockLengthM).ceil();
    final couplings = sections > 1 ? sections - 1 : 0;
    if (couplings == 0) continue;
    switch (joinMethodForService(c.service)) {
      case PipeJoinMethod.solventWeld:
        solventByDn[c.diameterMm] =
            (solventByDn[c.diameterMm] ?? 0) + couplings;
      case PipeJoinMethod.threaded:
        threaded += couplings;
      case PipeJoinMethod.heatFusion:
      case PipeJoinMethod.other:
        break;
    }
  }
  // Duct joint sealant: total gasket length over the duct runs.
  var sealM = 0.0;
  for (final e in net.edges) {
    if (e.kind != EdgeKind.run || e.service.regime != FlowRegime.air) continue;
    final s = sizing[e.id];
    if (s == null) continue;
    final len = edgeLength(e, net,
            calibrationBySheet: project.calibrations, building: project.building)
        .meters;
    final acc = computeDuctAccessories(e, s, len);
    if (acc != null) sealM += acc.gasketM;
  }

  return estimateConsumables(
    solventJointsByDn: solventByDn,
    ductSealMetres: sealM,
    threadedJoints: threaded,
  );
});

/// Estimated fittings (elbows/tees/crosses/reducers) for the sized network.
final fittingsProvider = Provider<List<FittingLine>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final sizing = ref.watch(sizingProvider);
  if (sizing.isEmpty) return const [];
  return buildFittings(net: net, sizing: sizing);
});

/// Key for [heatmapFieldProvider]: the sheet/floor being rendered plus the
/// sheet's content extent (which fixes the sample grid). The viewport transform
/// is deliberately NOT part of the key — panning/zooming must reuse the cached
/// field, not re-sample it (K3).
typedef HeatmapFieldKey = ({
  String sheetId,
  int floorIndex,
  double width,
  double height,
});

/// The sampled residual-pressure scalar field for the heatmap overlay (K3),
/// memoized on the solve result ([residualByNodeProvider]) + node positions +
/// sheet + sample grid. Because the viewport transform is not an input, panning
/// or zooming the canvas reuses the SAME cached [ScalarField] object instead of
/// re-running the O(cells·nodes) inverse-distance-weighting every frame — only a
/// new solve (or a node move that shifts positions/residuals) recomputes it.
/// Null when there is no residual data for this sheet/floor. The `~28 cells
/// across the longer edge` resolution matches the painter's prior inline sample.
final heatmapFieldProvider =
    Provider.family<ScalarField?, HeatmapFieldKey>((ref, key) {
  final residual = ref.watch(residualByNodeProvider);
  if (residual.isEmpty) return null;
  final net = ref.watch(sizingNetworkProvider);
  final nodes = <FieldNode>[
    for (final n in net.nodes)
      if (n.sheetId == key.sheetId && n.floorIndex == key.floorIndex)
        if (residual[n.id] != null)
          FieldNode(n.x, n.y, residual[n.id]!.inKiloPascals),
  ];
  if (nodes.isEmpty) return null;
  final resolution = (math.max(key.width, key.height) / 28).clamp(1.0, 1e9);
  return sampleField(
    nodes: nodes,
    bounds: FieldBounds(0, 0, key.width, key.height),
    resolution: resolution,
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
