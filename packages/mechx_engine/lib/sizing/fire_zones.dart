/// Backlog Z-1 (2026-11-14) — DESIGNED fire vertical zones.
///
/// A tall building is split by the engineer DRAWING the break: on a plant
/// floor a fire BREAK TANK (a storage tank on a fire pipe, read at its own
/// floor's surface — golden rule 3, Round 71) is filled by the lower zone's
/// riser, and a relay pump set drawing from it feeds the risers above. No
/// abstract input: the zones are read from the drawn topology.
///
/// A fire ZONE is the fire network one fire pump (set) serves — one
/// terminal-bearing pumped RATING system ([fireRatingSystems]; Round 51:
/// a storage tank is a hydraulic break, so the systems already end at every
/// tank). It is bounded upstream by its suction tank and downstream by the
/// break tank it fills ([fireFillDestinationTank], Round 70). Each zone keeps
/// the rating basis the EXISTING single-system routines compute for it (the
/// app's `fireSystemBasesProvider`) — this file adds only the zone CHAIN
/// (numbering, which zone fills which break tank), the fill path, the relay
/// fill head and the break-tank requirement. A building with no break tank
/// is one zone per pump room, every one numbered 1 ([fireZoned] false), and
/// nothing downstream changes.
///
/// Pure Dart, zero Flutter imports. Order-independent: zones are numbered by
/// topology (the chain depth), the fill path is the union of every shortest
/// path, and ties sort by elevation then draw order.
library;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/standards/sni.dart' show kTankInletResidualHeadM;
import 'package:mechx_engine/units.dart';

/// Backlog Z-1 — the time a fire BREAK tank must run its relay pump at the
/// rated flow with no refill, minutes: the required capacity is the upper
/// zone pump's rated flow x this. NFPA 14 / NFPA 20 break-tank practice
/// (an automatically refilled break tank holding at least 30 min of the
/// downstream rating). `// VERIFY notAnSniClause` against SNI 03-1745;
/// surfaced in `SniProfile.verifyChecklist`.
const double kFireBreakTankDurationMin = 30;

bool _isMover(NetNode? n) =>
    n != null &&
    (n.component == NodeComponent.pump ||
        n.component == NodeComponent.boosterSet);

/// One fire zone ([fireZones]).
class FireZone {
  /// 1-based zone number: 1 for a pump room whose suction tank no other
  /// zone fills, else one more than the zone filling its suction tank.
  final int number;

  /// The rating system the zone's pump serves.
  final FireSystem system;

  /// The zone's pumps / booster sets (sorted).
  final List<String> pumpIds;

  /// The break tank the zone draws from (filled by another fire system:
  /// a zone room below or a terminal-less transfer); null for a zone fed
  /// from its own source tank.
  final String? suctionTankId;

  /// The break tank this zone also fills ([fireFillDestinationTank]); null
  /// when it fills none.
  final String? fillTankId;

  /// Index (in the [fireZones] list) of the zone that fills
  /// [suctionTankId]; null when none does.
  final int? upstream;

  const FireZone({
    required this.number,
    required this.system,
    required this.pumpIds,
    required this.suctionTankId,
    required this.fillTankId,
    required this.upstream,
  });
}

/// The fire zones of [net]: one per pumped, terminal-bearing rating system
/// of [systems] (default [fireRatingSystems]), numbered along the break-tank
/// chain. [elevationOf] reads a node's elevation (metres) the same way the
/// sizer and the rating do (`nodeElevation`). Sorted by (number, lowest
/// pump elevation, draw order of the first pump).
List<FireZone> fireZones(
  Network net, {
  List<FireSystem>? systems,
  required double Function(NetNode n) elevationOf,
}) {
  final all = systems ?? fireRatingSystems(net);
  final rooms = <FireSystem>[];
  final pumpsOf = <FireSystem, List<String>>{};
  for (final s in all) {
    if (!fireSystemHasTerminal(net, s)) continue;
    final pumps = [
      for (final n in net.nodes)
        if (s.nodeIds.contains(n.id) && _isMover(n)) n.id,
    ]..sort();
    if (pumps.isEmpty) continue;
    rooms.add(s);
    pumpsOf[s] = pumps;
  }
  if (rooms.isEmpty) return const [];
  final fillOf = <FireSystem, String?>{
    for (final s in rooms) s: fireFillDestinationTank(net, s, elevationOf)?.id,
  };
  // Every tank another fire system fills (a zone room's fill, a transfer's
  // destination) -> the filling systems.
  final filledBy = <String, List<FireSystem>>{};
  for (final s in all) {
    final t = rooms.contains(s)
        ? fillOf[s]
        : fireTransferDestinationTank(net, s, elevationOf)?.id;
    if (t != null) (filledBy[t] ??= []).add(s);
  }
  String? suctionOf(FireSystem s) {
    String? best;
    for (final id in s.nodeIds) {
      final n = net.nodeById(id);
      if (!isFireSystemBoundary(n)) continue;
      if (id == fillOf[s]) continue;
      final by = filledBy[id];
      if (by == null || by.every((o) => identical(o, s))) continue;
      if (best == null || naturalIdCompare(id, best) < 0) best = id;
    }
    return best;
  }

  final suction = {for (final s in rooms) s: suctionOf(s)};
  FireSystem? upstreamOf(FireSystem s) {
    final t = suction[s];
    if (t == null) return null;
    final ups = [
      for (final o in rooms)
        if (!identical(o, s) && fillOf[o] == t) o,
    ];
    if (ups.isEmpty) return null;
    ups.sort((a, b) => _roomOrder(net, a, b, pumpsOf, elevationOf));
    return ups.first;
  }

  final numberOf = <FireSystem, int>{};
  int numberFor(FireSystem s, Set<FireSystem> path) {
    final known = numberOf[s];
    if (known != null) return known;
    final up = upstreamOf(s);
    final n = up == null || !path.add(up) ? 1 : 1 + numberFor(up, path);
    return numberOf[s] = n;
  }

  for (final s in rooms) {
    numberFor(s, {s});
  }
  final ordered = [...rooms]..sort((a, b) {
      final d = numberOf[a]!.compareTo(numberOf[b]!);
      if (d != 0) return d;
      return _roomOrder(net, a, b, pumpsOf, elevationOf);
    });
  final index = {for (var i = 0; i < ordered.length; i++) ordered[i]: i};
  return [
    for (final s in ordered)
      FireZone(
        number: numberOf[s]!,
        system: s,
        pumpIds: pumpsOf[s]!,
        suctionTankId: suction[s],
        fillTankId: fillOf[s],
        upstream: switch (upstreamOf(s)) {
          final FireSystem u => index[u],
          null => null,
        },
      ),
  ];
}

int _roomOrder(
  Network net,
  FireSystem a,
  FireSystem b,
  Map<FireSystem, List<String>> pumpsOf,
  double Function(NetNode n) elevationOf,
) {
  double low(FireSystem s) => pumpsOf[s]!
      .map((id) => elevationOf(net.nodeById(id)!))
      .reduce((x, y) => x < y ? x : y);
  final d = low(a).compareTo(low(b));
  if (d != 0) return d;
  NetNode first(FireSystem s) =>
      (pumpsOf[s]!.map((id) => net.nodeById(id)!).toList()
            ..sort(drawOrderCompare))
          .first;
  return drawOrderCompare(first(a), first(b));
}

/// True when [zones] hold a designed break (some zone numbered 2 or more).
bool fireZoned(List<FireZone> zones) => zones.any((z) => z.number >= 2);

/// Backlog Z-1 — the FILL PATH of a zone room [sys] into the break tank
/// [tankId] it fills: every fire pipe of [sys] on a SHORTEST path (fewest
/// pipes) from the tank to a node on a pump's discharge (the node a pump
/// leg ends at), never through another storage tank, a terminal or a pump;
/// the pump legs themselves are excluded (they are rated on the pump's own
/// flow). The union of all shortest paths, so ids and drawing order never
/// pick between two equal arms. Empty when the tank is not reached.
Set<String> fireFillPathEdgeIds(Network net, FireSystem sys, String tankId) {
  bool isMover(String id) => _isMover(net.nodeById(id));
  final adj = <String, List<NetEdge>>{};
  final starts = <String>{};
  for (final e in sys.edges) {
    if (sys.sourceEdgeIds.contains(e.id)) continue;
    final ma = isMover(e.fromId), mb = isMover(e.toId);
    if (ma || mb) {
      if (ma && !mb) starts.add(e.toId);
      if (mb && !ma) starts.add(e.fromId);
      continue;
    }
    (adj[e.fromId] ??= []).add(e);
    (adj[e.toId] ??= []).add(e);
  }
  // A pump leg's tank end is a suction side, never a discharge start.
  starts.removeWhere((id) => isFireSystemBoundary(net.nodeById(id)));
  if (starts.isEmpty || !sys.nodeIds.contains(tankId)) return const {};
  bool passable(String id) {
    if (id == tankId) return true;
    final n = net.nodeById(id);
    if (n == null || isFireSystemBoundary(n)) return false;
    return n.role != NodeRole.fixture;
  }

  Map<String, int> bfs(Iterable<String> seeds) {
    final dist = <String, int>{for (final s in seeds) s: 0};
    final queue = [...seeds];
    for (var i = 0; i < queue.length; i++) {
      final cur = queue[i];
      if (cur == tankId && !seeds.contains(cur)) continue;
      for (final e in adj[cur] ?? const <NetEdge>[]) {
        final o = e.fromId == cur ? e.toId : e.fromId;
        if (dist.containsKey(o) || !passable(o)) continue;
        dist[o] = dist[cur]! + 1;
        queue.add(o);
      }
    }
    return dist;
  }

  final fromStarts = bfs(starts);
  final total = fromStarts[tankId];
  if (total == null) return const {};
  final fromTank = bfs([tankId]);
  final out = <String>{};
  for (final e in sys.edges) {
    final a = e.fromId, b = e.toId;
    for (final (u, v) in [(a, b), (b, a)]) {
      final du = fromStarts[u], dv = fromTank[v];
      if (du != null && dv != null && du + 1 + dv == total) out.add(e.id);
    }
  }
  return out;
}

/// Backlog Z-2 — the head (m) a zone room's pump needs to REFILL the break
/// tank it feeds: the static lift from the pump to the tank (its floor
/// surface, `nodeElevation`), the friction of the fill path at the fill flow
/// and the tank inlet's residual [kTankInletResidualHeadM] (the float valve
/// passing the fill flow — the W-3 transfer convention). Negative terms are
/// read as 0; never clamped below the sum.
double fireRelayFillHeadM({required double liftM, required double frictionM}) =>
    (liftM > 0 ? liftM : 0) +
    (frictionM > 0 ? frictionM : 0) +
    kTankInletResidualHeadM;

/// Backlog Z-2 — what a fire BREAK tank must provide for the relay pump
/// drawing from it: [durationMin] (default [kFireBreakTankDurationMin]) of
/// that pump's rated flow, refilled automatically at least at that flow.
class FireBreakTankRequirement {
  /// The upper zone pump's rated flow (the draw on the tank).
  final FlowRate ratedFlow;

  /// The run time with no refill (minutes).
  final double durationMin;

  const FireBreakTankRequirement({
    required this.ratedFlow,
    this.durationMin = kFireBreakTankDurationMin,
  });

  /// Required capacity, litres: Q (L/s) x t (s).
  double get volumeLitres => ratedFlow.inLitersPerSecond * durationMin * 60;

  /// Required automatic fill flow: at least the draw (`// VERIFY`, with
  /// [kFireBreakTankDurationMin]).
  FlowRate get fillFlow => ratedFlow;
}

/// Backlog Z-4 — the printed name of a fire ZONE BREAK tank (whatever its
/// drawn tank typing): it is not a roof / ground domestic tank.
const String kFireBreakTankLabel = 'Fire break tank';

/// Backlog Z-4 — the Indonesian name ([kFireBreakTankLabel]).
const String kFireBreakTankLabelId = 'Tangki antara kebakaran';

/// Backlog Z-4 — the zone BREAK tanks of [zones]: a tank one zone fills
/// ([FireZone.fillTankId]) and another zone draws from
/// ([FireZone.suctionTankId]). Empty unless [fireZoned].
Set<String> fireZoneBreakTankIds(List<FireZone> zones) => {
      for (final z in zones)
        if (z.fillTankId case final t?)
          if (zones.any((o) => o.suctionTankId == t)) t,
    };
