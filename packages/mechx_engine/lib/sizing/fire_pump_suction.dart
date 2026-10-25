// Round 61 (fire-convergence-13-fire-pump-suction-below-nfpa20) — the fire
// pump's SUCTION and DISCHARGE pipe.
//
// Every fire pipe is velocity-sized at the 6 m/s fire cap on its RATED flow
// ([kMaxFireVelocityMps]) with the class code floors. A fire pump's suction is
// governed by more: NFPA 20 (to which SNI 03-1745 / 03-6570 defer) limits the
// suction-pipe velocity to 15 ft/s (4.57 m/s) with the pump at 150 % of its
// rated flow (NFPA 20-2019 4.16.6; 4.14.3 in older editions), and Table
// 4.28(a) sets the minimum suction and discharge pipe sizes per rated flow.
// A 500 gpm pump on DN100 suction ran at 1.5 x 0.031545 / (pi 0.1^2 / 4) =
// 6.02 m/s at overload — one size below the table's 5 in.
//
// Pure, judge-and-raise only: an edge is never sized DOWN; a hand-overridden
// edge keeps its size.
library;

import 'dart:math' as math;

import '../hydraulics.dart' show velocityFromFlow;
import '../network/network.dart';
import '../standards/sni.dart' show StandardValue, VerificationStatus;
import '../units.dart';
import 'fire_standpipe.dart'
    show kMinYardMainDiameterMm, kYardHydrantFlowLps;
import 'network_sizing.dart' show EdgeSizing, SizingContext;
import 'water_supply_sizing.dart' as water;

/// NFPA 20 suction velocity limit (m/s) at 150 % of rated flow: 15 ft/s.
const double kFirePumpSuctionMaxVelocityMps = 4.572;

/// The overload multiple the suction velocity is judged at (NFPA 20: 150 %).
const double kFirePumpSuctionOverloadFactor = 1.5;

/// NFPA 20 Table 4.28(a) — minimum suction / discharge pipe sizes (mm, the
/// inch size as its DN) by rated pump capacity (gpm): the first row whose
/// rated flow is at or above the pump's governs. `// VERIFY` — reproduced
/// from the 2019 table; confirm against the edition SNI 03-6570 adopts.
const List<({double gpm, double suctionMm, double dischargeMm})>
    kFirePumpPipeTable = [
  (gpm: 25, suctionMm: 25, dischargeMm: 25),
  (gpm: 50, suctionMm: 40, dischargeMm: 32),
  (gpm: 100, suctionMm: 50, dischargeMm: 50),
  (gpm: 150, suctionMm: 65, dischargeMm: 65),
  (gpm: 200, suctionMm: 80, dischargeMm: 80),
  (gpm: 250, suctionMm: 90, dischargeMm: 80),
  (gpm: 300, suctionMm: 100, dischargeMm: 100),
  (gpm: 400, suctionMm: 100, dischargeMm: 100),
  (gpm: 450, suctionMm: 125, dischargeMm: 125),
  (gpm: 500, suctionMm: 125, dischargeMm: 125),
  (gpm: 750, suctionMm: 150, dischargeMm: 150),
  (gpm: 1000, suctionMm: 200, dischargeMm: 150),
  (gpm: 1250, suctionMm: 200, dischargeMm: 200),
  (gpm: 1500, suctionMm: 200, dischargeMm: 200),
  (gpm: 2000, suctionMm: 250, dischargeMm: 200),
  (gpm: 2500, suctionMm: 250, dischargeMm: 250),
  (gpm: 3000, suctionMm: 300, dischargeMm: 250),
];

const double _gpmPerLps = 60 / 3.785411784;

/// The Table 4.28(a) row for a pump rated at [flow] (the first row at or
/// above it; above the last row, the last).
({double gpm, double suctionMm, double dischargeMm}) firePumpPipeRow(
    FlowRate flow) {
  final gpm = flow.inLitersPerSecond * _gpmPerLps;
  for (final r in kFirePumpPipeTable) {
    if (r.gpm >= gpm - 1e-6) return r;
  }
  return kFirePumpPipeTable.last;
}

/// The unverified items behind the suction / discharge rule (golden rule 6).
const List<StandardValue<Object?>> firePumpSuctionVerifyChecklist = [
  StandardValue<Object?>(kFirePumpSuctionMaxVelocityMps,
      unit: 'm/s',
      citation: 'NFPA 20 4.16.6 — fire-pump suction velocity at 150 % flow',
      status: VerificationStatus.notAnSniClause,
      note: 'The fire-pump suction pipe keeps <= 15 ft/s (4.57 m/s) with the '
          'pump at 150 % of rated flow (SNI 03-1745 / 03-6570 defer to '
          'NFPA 20); verify the edition adopted.'),
  StandardValue<Object?>(500.0,
      unit: 'gpm',
      citation: 'NFPA 20 Table 4.28(a) — minimum suction / discharge sizes',
      status: VerificationStatus.notAnSniClause,
      note: 'Fire-pump suction and discharge pipes floor at the Table '
          '4.28(a) size for the rated flow (500 gpm: 5 in / 5 in; 750 gpm: '
          '6 in / 6 in); verify against the adopted NFPA 20 edition.'),
];

bool _isFire(NetEdge e) =>
    e.service == ServiceType.fireHydrant ||
    e.service == ServiceType.fireSprinkler;

bool _isMover(NetNode? n) =>
    n?.component == NodeComponent.pump ||
    n?.component == NodeComponent.boosterSet;

/// Raise every fire pump's SUCTION pipe (the fire edges carrying flow INTO
/// the pump, walked upstream through bare / inline nodes and suction headers
/// to the tank / source) to the smallest DN that keeps the velocity at
/// [kFirePumpSuctionOverloadFactor] x its sized flow within
/// [kFirePumpSuctionMaxVelocityMps], and at least the Table 4.28(a) suction
/// size; and every DISCHARGE pipe (out of the pump, through inline devices
/// and bends — and on through a header where several pump legs merge — up to
/// the first junction, terminal or riser) to at least the table's discharge
/// size. Both are keyed
/// on the edge's own sized flow (the pump's set flow). Edges in [overridden]
/// keep their hand-picked size. Mutates [sizing] in place; returns the ids of
/// the raised edges. Pure apart from that.
Set<String> raiseFirePumpSuctionAndDischarge(
  Network net,
  Map<String, EdgeSizing> sizing, {
  Set<String> overridden = const {},
}) {
  final raised = <String>{};
  final pumps = <String>{
    for (final e in net.edges)
      if (_isFire(e)) ...[
        if (_isMover(net.nodeById(e.fromId))) e.fromId,
        if (_isMover(net.nodeById(e.toId))) e.toId,
      ],
  };
  if (pumps.isEmpty) return raised;
  final adj = <String, List<NetEdge>>{};
  for (final e in net.edges) {
    if (!_isFire(e)) continue;
    (adj[e.fromId] ??= []).add(e);
    (adj[e.toId] ??= []).add(e);
  }
  String other(NetEdge e, String id) => e.fromId == id ? e.toId : e.fromId;
  bool inflowAt(NetEdge e, String id) {
    final s = sizing[e.id];
    return s != null && s.flowFromId != null && s.flowFromId != id;
  }

  bool outflowAt(NetEdge e, String id) {
    final s = sizing[e.id];
    return s != null && s.flowFromId == id;
  }

  // A pipe leaving [from] along [e] that reaches a mover through bare /
  // inline degree-2 nodes only (a suction-header leg).
  bool leadsToMover(NetEdge e, String from) {
    var cur = from;
    var edge = e;
    final walked = <String>{};
    while (walked.add(edge.id)) {
      final next = other(edge, cur);
      final n = net.nodeById(next);
      if (_isMover(n)) return true;
      final links = adj[next] ?? const <NetEdge>[];
      if (n == null || links.length != 2 || n.role == NodeRole.plant) {
        return false;
      }
      cur = next;
      edge = links.firstWhere((x) => x.id != edge.id);
    }
    return false;
  }

  final suction = <String>{};
  final discharge = <String>{};
  for (final p in [...pumps]..sort()) {
    // Suction: upstream through every node that is not a source (tank /
    // plant / inlet) or another mover.
    final stack = [p];
    final seen = <String>{p};
    while (stack.isNotEmpty) {
      final cur = stack.removeLast();
      for (final e in adj[cur] ?? const <NetEdge>[]) {
        if (!inflowAt(e, cur)) continue;
        suction.add(e.id);
        final up = other(e, cur);
        final n = net.nodeById(up);
        if (n == null || n.role == NodeRole.plant || _isMover(n)) continue;
        if (isSupplyInletComponent(n.component)) continue;
        // Past a junction only when it is a SUCTION HEADER: every pipe it
        // sends on leads to a mover (never up an interstage riser that
        // also feeds terminals).
        final links = adj[up] ?? const <NetEdge>[];
        if (links.length > 2 &&
            !links
                .where((x) => outflowAt(x, up))
                .every((x) => leadsToMover(x, up))) {
          continue;
        }
        if (n.role == NodeRole.fixture) continue;
        if (seen.add(up)) stack.add(up);
      }
    }
    // Discharge: downstream through inline devices / bare bends (degree 2)
    // to the first junction or terminal — and on through a DISCHARGE
    // HEADER (a junction where two or more pump legs merge, every pipe
    // into it coming from a mover) to the main it feeds.
    final dstack = [p];
    final dseen = <String>{p};
    while (dstack.isNotEmpty) {
      final cur = dstack.removeLast();
      for (final e in adj[cur] ?? const <NetEdge>[]) {
        if (!outflowAt(e, cur)) continue;
        // The discharge piping ends where the standpipe / sprinkler riser
        // begins (the riser keeps its own class sizing).
        if (e.kind == EdgeKind.riser) continue;
        discharge.add(e.id);
        final next = other(e, cur);
        final n = net.nodeById(next);
        if (n == null ||
            n.role == NodeRole.plant ||
            n.role == NodeRole.fixture ||
            _isMover(n)) {
          continue;
        }
        final links = adj[next] ?? const <NetEdge>[];
        if (links.length > 2) {
          final ins = links.where((x) => inflowAt(x, next)).toList();
          if (ins.length < 2 || !ins.every((x) => leadsToMover(x, next))) {
            continue;
          }
        }
        if (dseen.add(next)) dstack.add(next);
      }
    }
  }
  final maxMm = water.standardPipeDiametersMm.last;
  void raise(String id, {required bool isSuction}) {
    if (overridden.contains(id)) return;
    final s = sizing[id];
    if (s == null || s.flow.cubicMetersPerSecond <= 0) return;
    final row = firePumpPipeRow(s.flow);
    final tableMm = _seriesAtLeast(
        math.min(maxMm, isSuction ? row.suctionMm : row.dischargeMm));
    var floorMm = math.max(s.diameter.inMillimeters, tableMm);
    var over = s.overCapacity;
    if (isSuction) {
      final r = water.sizeForFlow(
        flow: FlowRate(
            s.flow.cubicMetersPerSecond * kFirePumpSuctionOverloadFactor),
        maxVelocity: const Velocity(kFirePumpSuctionMaxVelocityMps),
        minDiameter: Diameter.mm(floorMm),
      );
      floorMm = math.max(floorMm, r.diameter.inMillimeters);
      over = over || r.overVelocity;
    }
    if (floorMm <= s.diameter.inMillimeters + 1e-9) return;
    final d = Diameter.mm(floorMm);
    sizing[id] = s.withBore(d, velocityFromFlow(s.flow, d),
        overCapacity: over);
    raised.add(id);
  }

  for (final id in suction) {
    raise(id, isSuction: true);
  }
  for (final id in discharge) {
    if (!suction.contains(id)) raise(id, isSuction: false);
  }
  return raised;
}

/// The smallest DN of the pressurized pipe series at or above [mm] (the
/// largest when [mm] exceeds the series).
double _seriesAtLeast(double mm) {
  for (final d in water.standardPipeDiametersMm) {
    if (d >= mm - 1e-9) return d;
  }
  return water.standardPipeDiametersMm.last;
}

/// Round 61 (fire-convergence-13-yard-hydrants-rated-as-building-standpipe)
/// — every fire pipe with a yard (pillar) hydrant downstream of it (along
/// the sized flow direction) carries at least [kYardHydrantFlowLps] and is at
/// least DN [kMinYardMainDiameterMm] (the private fire service main / hydrant
/// lateral), re-sized on the fire velocity cap. Only ever RAISES a flow or a
/// bore; edges in [overridden] keep their size (their flow is still raised).
/// A network with no pillar hydrant is untouched (byte-identical). Mutates
/// [sizing]; returns the raised edge ids.
Set<String> raiseYardHydrantMains(
  Network net,
  Map<String, EdgeSizing> sizing,
  SizingContext ctx, {
  Set<String> overridden = const {},
}) {
  final raised = <String>{};
  if (!net.nodes.any((n) => n.component == NodeComponent.pillarHydrant)) {
    return raised;
  }
  final out = <String, List<NetEdge>>{};
  for (final e in net.edges) {
    if (!_isFire(e)) continue;
    final from = sizing[e.id]?.flowFromId;
    if (from == null) continue;
    (out[from] ??= []).add(e);
  }
  final memo = <String, bool>{};
  bool down(String id, Set<String> path) {
    final m = memo[id];
    if (m != null) return m;
    if (net.nodeById(id)?.component == NodeComponent.pillarHydrant) {
      return memo[id] = true;
    }
    if (!path.add(id)) return false;
    var any = false;
    for (final e in out[id] ?? const <NetEdge>[]) {
      final to = e.fromId == id ? e.toId : e.fromId;
      if (down(to, path)) any = true;
    }
    path.remove(id);
    return memo[id] = any;
  }

  const yard = FlowRate(kYardHydrantFlowLps / 1000);
  for (final e in net.edges) {
    if (!_isFire(e)) continue;
    final s = sizing[e.id];
    final from = s?.flowFromId;
    if (s == null || from == null) continue;
    final to = e.fromId == from ? e.toId : e.fromId;
    if (!down(to, <String>{})) continue;
    final q = s.flow.cubicMetersPerSecond >= yard.cubicMetersPerSecond
        ? s.flow
        : yard;
    if (overridden.contains(e.id)) {
      if (q != s.flow) {
        sizing[e.id] = s.withBore(s.diameter, velocityFromFlow(q, s.diameter),
            flow: q);
        raised.add(e.id);
      }
      continue;
    }
    final minMm = math.max(kMinYardMainDiameterMm,
        ctx.fireMinimumFor(e)?.inMillimeters ?? 0.0);
    final r = water.sizeForFlow(
      flow: q,
      maxVelocity: ctx.maxFireVelocity,
      minDiameter: Diameter.mm(minMm),
    );
    final dMm = math.max(s.diameter.inMillimeters, r.diameter.inMillimeters);
    if (q == s.flow && dMm <= s.diameter.inMillimeters + 1e-9) continue;
    final d = Diameter.mm(dMm);
    sizing[e.id] = s.withBore(d, velocityFromFlow(q, d),
        flow: q, overCapacity: s.overCapacity || r.overVelocity);
    raised.add(e.id);
  }
  return raised;
}
