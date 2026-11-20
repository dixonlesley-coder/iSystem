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
// K-2: the delivered pressure field upstream of a ground tank is on MAINS
//   pressure ([mainsFeedHeads]): the same available head, lift and sized
//   feed friction [mainsPressureCheck] judges — one source.
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
        kDefaultMainsHeadM,
        kGroundStorageDaysDefault,
        kRoofStorageFractionDefault,
        kTankSizeLadderLitres,
        standardTankLitres;

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

  /// Backlog K-2 — the head the mains leaves at the tank inlet (the float
  /// valve): available − lift − friction (m). [ok] exactly when it is at
  /// least [inletResidualM].
  Head get inletHead => Head(available.meters - liftM - frictionM);

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
  final frictions = _feedFrictions(net, feed, sized, lengthOf);
  if (frictions == null) return null;
  final friction = frictions.fold(0.0, (a, f) => a + f);
  final flow = sized[feed.edgeIds.first]!.flow;
  final fill = tankFillFlow(tank);
  return MainsPressureCheck(
    meterId: feed.meterId,
    tankId: feed.tankId,
    available: available,
    flow: flow,
    fillBasis: fill != null &&
        (fill.cubicMetersPerSecond - flow.cubicMetersPerSecond).abs() <=
            1e-12,
    liftM: elevationOf(tank) - elevationOf(meter),
    frictionM: friction,
    inletResidualM: kTankInletResidualHeadM,
  );
}

/// The Hazen–Williams friction (m) of each pipe of [feed] at its SIZED flow
/// over its length at its sized bore, in meter → tank order — the ONE term
/// [mainsPressureCheck] sums and [mainsFeedHeads] accumulates. Null when a
/// feed pipe is unsized.
List<double>? _feedFrictions(
  Network net,
  MeterFeed feed,
  Map<String, ({FlowRate flow, Diameter diameter})> sized,
  double Function(NetEdge e) lengthOf,
) {
  final out = <double>[];
  for (final id in feed.edgeIds) {
    final e = net.edgeById(id);
    final sz = sized[id];
    if (e == null || sz == null || sz.diameter.meters <= 0) return null;
    out.add(headLossHazenWilliams(
      flow: sz.flow,
      length: Length(lengthOf(e)),
      diameter: sz.diameter,
      hazenWilliamsC: coldWaterHazenWilliamsC(e),
    ).meters);
  }
  return out;
}

/// Backlog K-2 — one node of a mains feed on MAINS pressure.
typedef MainsFeedHead = ({String nodeId, Head flowing, Head noFlow});

/// Backlog K-2 (2026-11-20) — the MAINS-side heads of [feed]: the meter and
/// every node of its chain up to (never including) the ground tank, whose
/// free surface stays the pump-side datum. At node i, with z the
/// [elevationOf] and F the cumulative sized feed friction from the meter
/// ([_feedFrictions], the same terms [mainsPressureCheck] judges):
///   flowing = available − (z_i − z_meter) − F_i,
///   no-flow = available − (z_i − z_meter).
/// The meter itself reads the available mains head. The tank inlet's
/// remaining head is [MainsPressureCheck.inletHead]. Null when a feed pipe is
/// unsized (the field then keeps the solve's value — never a fabricated
/// one). Meter → tank order.
List<MainsFeedHead>? mainsFeedHeads({
  required Network net,
  required MeterFeed feed,
  required Map<String, ({FlowRate flow, Diameter diameter})> sized,
  required Head available,
  required double Function(NetEdge e) lengthOf,
  required double Function(NetNode n) elevationOf,
}) {
  final meter = net.nodeById(feed.meterId);
  if (meter == null || net.nodeById(feed.tankId) == null) return null;
  if (feed.edgeIds.isEmpty) return null;
  final frictions = _feedFrictions(net, feed, sized, lengthOf);
  if (frictions == null) return null;
  final z0 = elevationOf(meter);
  final out = <MainsFeedHead>[
    (nodeId: meter.id, flowing: available, noFlow: available),
  ];
  var cur = meter.id;
  var f = 0.0;
  for (var i = 0; i < feed.edgeIds.length; i++) {
    final e = net.edgeById(feed.edgeIds[i])!;
    final next = e.fromId == cur ? e.toId : e.fromId;
    f += frictions[i];
    if (next == feed.tankId) break;
    final n = net.nodeById(next);
    if (n == null) return null;
    final lift = elevationOf(n) - z0;
    out.add((
      nodeId: next,
      flowing: Head(available.meters - lift - f),
      noFlow: Head(available.meters - lift),
    ));
    cur = next;
  }
  return out;
}

/// Backlog W-4 (2026-11-14) — the daily water demand (litres / day) of
/// [population] persons at [litresPerPersonDay]. Null when the population is
/// unknown (never invented).
double? dailyDemandLitres(int? population, double litresPerPersonDay) =>
    population == null || population <= 0
        ? null
        : population * litresPerPersonDay;

/// Backlog W-4 — one domestic storage tank's contribution to the water
/// reserve: its capacity less any fire reserve held in it (a tank shared by
/// a fire system), null when no capacity is entered (excluded, named).
typedef ReserveTank = ({
  String tankId,
  bool roof,
  double? capacityLitres,
  double fireReserveLitres,
});

/// Backlog W-4 (2026-11-14) — the domestic WATER RESERVE: the total
/// potable storage (Σ capacity − fire reserve of the domestic cold-water
/// tanks that have a capacity) over the daily demand, in days. Report only:
/// the owner's decision is that a tank's fill rate is outside the
/// designer's control, so no fill-rate judge exists; the reserve is the
/// reported figure. Never invented: [days] is null with no daily demand or
/// no stored volume.
class WaterReserve {
  final List<ReserveTank> tanks;

  /// The daily demand (litres / day); null when the population is unknown.
  final double? dailyLitres;

  const WaterReserve({required this.tanks, required this.dailyLitres});

  /// The tanks counted (a capacity entered).
  List<ReserveTank> get counted =>
      [for (final t in tanks) if (t.capacityLitres != null) t];

  /// The tanks excluded for having no capacity.
  List<String> get excludedTankIds =>
      [for (final t in tanks) if (t.capacityLitres == null) t.tankId];

  /// The potable volume a counted tank holds (capacity − fire reserve,
  /// never below 0).
  static double domesticLitres(ReserveTank t) => (t.capacityLitres! -
          t.fireReserveLitres)
      .clamp(0.0, double.infinity)
      .toDouble();

  /// Σ domestic storage (litres); null when no tank has a capacity.
  double? get storedLitres => counted.isEmpty
      ? null
      : counted.fold<double>(0, (a, t) => a + domesticLitres(t));

  /// Reserve in days = stored / daily demand; null when either is unknown.
  double? get days {
    final s = storedLitres;
    final d = dailyLitres;
    if (s == null || d == null || d <= 0 || s <= 0) return null;
    return s / d;
  }
}

/// "X.X days (Y h)" for a sub-day reserve, "X.X days" otherwise.
/// (hours to 0.1 h below 10 h).
String formatReserveDays(double days) {
  if (days >= 1) return '${days.toStringAsFixed(1)} days';
  final h = days * 24;
  return '${days.toStringAsFixed(1)} days '
      '(${h < 10 ? h.toStringAsFixed(1) : h.toStringAsFixed(0)} h)';
}

/// Backlog W-5 (2026-11-14) — one auto-sized tank capacity and its
/// arithmetic.
class AutoTankCapacity {
  final String tankId;

  /// True when sized on the roof fraction, false on the ground days.
  final bool roofTarget;

  /// The tank's share of the daily demand (0..1) among tanks of its role.
  final double share;

  /// The target: ground days, or the roof fraction.
  final double target;

  /// share x daily demand x target (litres), before the ladder.
  final double rawLitres;

  /// [rawLitres] rounded up to [kTankSizeLadderLitres].
  final double litres;

  const AutoTankCapacity({
    required this.tankId,
    required this.roofTarget,
    required this.share,
    required this.target,
    required this.rawLitres,
    required this.litres,
  });
}

/// Backlog W-5 — the auto capacity of every DOMESTIC storage tank (a cold-
/// water pipe, no fire pipe) with no entered capacity. Role: a roof tank in
/// a cold-water system that also holds a ground tank takes [roofFraction];
/// every other tank (a ground tank, a system's only tank, a mains-fed roof
/// tank beside another roof tank) takes [groundDays]. Share: the units on
/// the tank's cold-water edges whose solved flow LEAVES it ([flowFromOf];
/// mirrored standby legs [excludeEdgeIds] skipped) over the sum for every
/// domestic tank of the same role (entered-capacity tanks included). An
/// entered capacity always wins (the tank is not returned); a fire tank is
/// never auto-sized. Empty without a daily demand. Order-independent (sums
/// over sorted ids).
Map<String, AutoTankCapacity> autoTankCapacities({
  required Network net,
  required Map<String, double> edgeUnits,
  required String? Function(String edgeId) flowFromOf,
  required double? dailyLitres,
  double groundDays = kGroundStorageDaysDefault,
  double roofFraction = kRoofStorageFractionDefault,
  Set<String> excludeEdgeIds = const {},
}) {
  if (dailyLitres == null || dailyLitres <= 0) return const {};
  final cold = <String, List<NetEdge>>{};
  final fire = <String>{};
  for (final e in net.edges) {
    if (e.service == ServiceType.fireHydrant ||
        e.service == ServiceType.fireSprinkler) {
      fire
        ..add(e.fromId)
        ..add(e.toId);
    }
    if (e.service != ServiceType.coldWater) continue;
    (cold[e.fromId] ??= []).add(e);
    (cold[e.toId] ??= []).add(e);
  }
  final tanks = [
    for (final n in net.nodes)
      if (isStorageTankNode(n) && cold.containsKey(n.id) && !fire.contains(n.id))
        n,
  ]..sort((a, b) => a.id.compareTo(b.id));
  if (!tanks.any((t) => (t.tankCapacityLitres ?? 0) <= 0)) return const {};
  // The cold-water system (component) of each tank.
  final compOf = <String, int>{};
  var next = 0;
  for (final t in tanks) {
    if (compOf.containsKey(t.id)) continue;
    final id = next++;
    final stack = [t.id];
    final seen = <String>{t.id};
    while (stack.isNotEmpty) {
      final n = stack.removeLast();
      if (net.nodeById(n) case final nn? when isStorageTankNode(nn)) {
        compOf[n] = id;
      }
      for (final e in cold[n] ?? const <NetEdge>[]) {
        final o = e.fromId == n ? e.toId : e.fromId;
        if (seen.add(o)) stack.add(o);
      }
    }
  }
  final hasGround = <int>{
    for (final t in tanks)
      if (t.component == NodeComponent.groundTank) compOf[t.id]!,
  };
  bool roofRole(NetNode t) =>
      t.component == NodeComponent.roofTank && hasGround.contains(compOf[t.id]);
  double unitsOf(NetNode t) => cold[t.id]!
      .where((e) => flowFromOf(e.id) == t.id && !excludeEdgeIds.contains(e.id))
      .fold<double>(0, (a, e) => a + (edgeUnits[e.id] ?? 0.0));
  final roofSum =
      tanks.where(roofRole).fold<double>(0, (a, t) => a + unitsOf(t));
  final groundSum = tanks
      .where((t) => !roofRole(t))
      .fold<double>(0, (a, t) => a + unitsOf(t));
  final out = <String, AutoTankCapacity>{};
  for (final t in tanks) {
    if ((t.tankCapacityLitres ?? 0) > 0) continue;
    final roof = roofRole(t);
    final sum = roof ? roofSum : groundSum;
    if (sum <= 0) continue;
    final share = unitsOf(t) / sum;
    if (share <= 0) continue;
    final target = roof ? roofFraction : groundDays;
    final raw = share * dailyLitres * target;
    out[t.id] = AutoTankCapacity(
      tankId: t.id,
      roofTarget: roof,
      share: share,
      target: target,
      rawLitres: raw,
      litres: standardTankLitres(raw),
    );
  }
  return out;
}
