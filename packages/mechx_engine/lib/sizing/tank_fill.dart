// Backlog W-1 / W-2 / W-3 (2026-11-14) — a storage tank's FILL RATE and the
// heads that deliver it. Pure Dart (golden rule 1).
//
// W-1: a tank fills at its capacity / its refill time ([tankFillFlow]). That
//   is the design flow of a ground tank's meter feed and of the transfer
//   pipework into a roof tank (the sizer, `network_sizing.dart`, reads it);
//   a tank with no capacity keeps the demand basis and is flagged by the app.
// W-2: the mains at a water meter must lift the fill to the ground tank's
//   inlet, pass the meter feed's friction at that flow, and leave the float
//   valve its residual ([mainsPressureCheck]) — judge-only, never resizes.
// W-3: a transfer pump lifts to the WORST of the tanks it fills (the app's
//   `transferPumpHead`), each inlet owed [kTankInletResidualHeadM].
//
// Every default here is `// VERIFY` and listed once in
// `SniProfile.tankFillBasis`.
import '../hydraulics.dart';
import '../network/network.dart';
import '../standards/pipe_products.dart';
import '../standards/sni.dart';
import '../units.dart';

export '../standards/sni.dart'
    show
        kGroundTankRefillHoursDefault,
        kRoofTankRefillHoursDefault,
        kTankInletResidualHeadM,
        kDefaultMainsHeadM;

/// True for a ground or roof storage tank node.
bool isStorageTankNode(NetNode? n) =>
    n != null &&
    (n.component == NodeComponent.groundTank ||
        n.component == NodeComponent.roofTank);

/// The refill time (hours) of tank [n]: its own [NetNode.tankRefillHours],
/// else the type default (ground 4 h, roof 1 h, `// VERIFY`).
double tankRefillHoursOf(NetNode n) {
  final own = n.tankRefillHours;
  if (own != null && own > 0) return own;
  return n.component == NodeComponent.roofTank
      ? kRoofTankRefillHoursDefault
      : kGroundTankRefillHoursDefault;
}

/// Backlog W-1 — the FILL FLOW of storage tank [n]: its capacity / its
/// refill time, Q = L / 1000 / (h x 3600) m³/s. Null for a non-tank node or
/// a tank with no (positive) capacity: never fabricated.
FlowRate? tankFillFlow(NetNode? n) {
  if (!isStorageTankNode(n)) return null;
  final litres = n!.tankCapacityLitres;
  if (litres == null || litres <= 0) return null;
  return FlowRate(litres / 1000.0 / (tankRefillHoursOf(n) * 3600.0));
}

/// Backlog W-2 — one drawn MAINS FEED: a degree-1 water meter whose cold-
/// water chain (through degree-2 bare `main` / inline-device nodes) ends at
/// a ground tank. [edgeIds] are in meter → tank order.
typedef MeterFeed = ({String meterId, String tankId, List<String> edgeIds});

/// Every [MeterFeed] of [net], sorted by meter id (order-independent).
List<MeterFeed> meterFeedsToGroundTanks(Network net) {
  final at = <String, List<NetEdge>>{};
  for (final e in net.edges) {
    if (e.service != ServiceType.coldWater) continue;
    (at[e.fromId] ??= []).add(e);
    (at[e.toId] ??= []).add(e);
  }
  final out = <MeterFeed>[];
  final meters = [
    for (final n in net.nodes)
      if (n.component == NodeComponent.waterMeter &&
          (at[n.id]?.length ?? 0) == 1)
        n.id,
  ]..sort();
  for (final m in meters) {
    final edges = <String>[];
    final seen = <String>{m};
    var cur = m;
    var edge = at[m]!.single;
    String? tank;
    while (true) {
      final next = edge.fromId == cur ? edge.toId : edge.fromId;
      if (!seen.add(next)) break;
      edges.add(edge.id);
      final nn = net.nodeById(next);
      if (nn == null) break;
      if (nn.component == NodeComponent.groundTank) {
        tank = next;
        break;
      }
      final links = at[next] ?? const <NetEdge>[];
      if (links.length != 2 ||
          nn.role != NodeRole.main ||
          (nn.component != null && !isInlineDeviceComponent(nn.component))) {
        break;
      }
      cur = next;
      edge = links.firstWhere((e) => e.id != edge.id);
    }
    if (tank != null) out.add((meterId: m, tankId: tank, edgeIds: edges));
  }
  return out;
}

/// The Hazen–Williams C a cold-water pipe reads: its pipe product's C, else
/// the service default (PVC) — the SAME basis the transfer head and the
/// pressure solves read.
double coldWaterHazenWilliamsC(NetEdge e) => e.pipeProduct != null
    ? hazenWilliamsCFor(e.pipeProduct!)
    : const SniProfile().hazenWilliamsC(PipeMaterial.pvc);

/// Backlog W-2 — the mains-pressure verdict of one [MeterFeed].
class MainsPressureCheck {
  final String meterId;
  final String tankId;

  /// The available mains head at the meter (the project input).
  final Head available;

  /// The flow the feed was sized on (the tank's fill flow, else the demand
  /// basis when the tank has no capacity — [fillBasis] false).
  final FlowRate flow;
  final bool fillBasis;

  /// Tank inlet elevation − meter elevation (true elevation delta, m).
  final double liftM;

  /// Hazen–Williams friction of [flow] over the feed at its sized bores (m).
  final double frictionM;

  /// The float-valve residual owed at the inlet (m).
  final double inletResidualM;

  const MainsPressureCheck({
    required this.meterId,
    required this.tankId,
    required this.available,
    required this.flow,
    required this.fillBasis,
    required this.liftM,
    required this.frictionM,
    required this.inletResidualM,
  });

  /// lift + friction + inlet residual (m).
  Head get required => Head(liftM + frictionM + inletResidualM);

  /// True when the mains head reaches the requirement.
  bool get ok => available.meters >= required.meters - 1e-9;
}

/// Backlog W-2 — judge [feed]: required = (tank − meter elevation) + the
/// Hazen–Williams friction of each feed pipe's SIZED flow over its length at
/// its sized bore + [kTankInletResidualHeadM]. Judge-only (never resizes).
/// Null when a feed pipe is unsized.
MainsPressureCheck? mainsPressureCheck({
  required Network net,
  required MeterFeed feed,
  required Map<String, ({FlowRate flow, Diameter diameter})> sized,
  required Head available,
  required double Function(NetEdge e) lengthOf,
  required double Function(NetNode n) elevationOf,
}) {
  final meter = net.nodeById(feed.meterId);
  final tank = net.nodeById(feed.tankId);
  if (meter == null || tank == null || feed.edgeIds.isEmpty) return null;
  var friction = 0.0;
  FlowRate? flow;
  for (final id in feed.edgeIds) {
    final e = net.edgeById(id);
    final sz = sized[id];
    if (e == null || sz == null || sz.diameter.meters <= 0) return null;
    flow ??= sz.flow;
    friction += headLossHazenWilliams(
      flow: sz.flow,
      length: Length(lengthOf(e)),
      diameter: sz.diameter,
      hazenWilliamsC: coldWaterHazenWilliamsC(e),
    ).meters;
  }
  final fill = tankFillFlow(tank);
  return MainsPressureCheck(
    meterId: feed.meterId,
    tankId: feed.tankId,
    available: available,
    flow: flow!,
    fillBasis: fill != null &&
        (fill.cubicMetersPerSecond - flow.cubicMetersPerSecond).abs() <=
            1e-12,
    liftM: elevationOf(tank) - elevationOf(meter),
    frictionM: friction,
    inletResidualM: kTankInletResidualHeadM,
  );
}
