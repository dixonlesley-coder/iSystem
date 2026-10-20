/// Round 28 — fire SYSTEMS (connected fire networks) and the friction of the
/// SIZED index path a fire pump has to overcome.
///
/// Pure Dart, zero Flutter imports.
///
///  * [fireSystems] — the connected fire-protection networks of a drawing
///    (sprinkler + hydrant edges joined through shared nodes). Each one is its
///    own system with its own pump rating: a sprinkler pump on a separate
///    network is never rated on a standpipe drawn elsewhere, and two
///    independent single-stack standpipes are two 500 gpm systems, never one
///    750 gpm system (fire-3-standpipe-stacks-counted-across-independent-
///    systems / fire-3-sprinkler-pump-gets-standpipe-duty).
///  * [fireIndexPathFrictionM] — the Hazen–Williams friction head, in metres,
///    of the worst (largest-friction) path from a fire pump to a fire terminal
///    over the pipes the sizer actually picked, at their sized flows. Since
///    Round 21 the fire sizer runs at up to 6 m/s ([kMaxFireVelocityMps]),
///    where small-bore pipe loses ~1.4 m per metre — far above the fixed 15 m
///    allowance the rated head used to carry (fire-3-pump-head-ignores-sized-
///    fire-pipe-friction). Null when any flowing pipe the pump reaches is
///    unmeasured (an uncalibrated run): the allowance then stands.
library;

import 'dart:collection' show SplayTreeSet;

import 'package:mechx_engine/geometry/building.dart' show BuildingLevels;
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_sprinkler_hydraulic.dart'
    show kSprinklerBranchHazenC;
import 'package:mechx_engine/sizing/fire_standpipe.dart'
    show StandpipeClass, kHoseOutletHeightM, parallelStandpipeCount;
import 'package:mechx_engine/sizing/network_sizing.dart' show EdgeSizing;
import 'package:mechx_engine/units.dart';

/// True for the fire-protection services (sprinkler + hydrant).
bool isFireService(ServiceType s) =>
    s == ServiceType.fireSprinkler || s == ServiceType.fireHydrant;

/// One connected fire-protection network.
class FireSystem {
  /// Every node the system's fire edges touch.
  final Set<String> nodeIds;

  /// Its fire edges (sprinkler + hydrant), in drawing order.
  final List<NetEdge> edges;

  const FireSystem(this.nodeIds, this.edges);

  /// True when a hydrant / standpipe edge is part of this system.
  bool get hasHydrant => edges.any((e) => e.service == ServiceType.fireHydrant);

  /// True when a sprinkler edge is part of this system.
  bool get hasSprinkler =>
      edges.any((e) => e.service == ServiceType.fireSprinkler);

  /// The standpipe stacks of THIS system that run in parallel (at least 1).
  int standpipeRisers(Network net) {
    final n = parallelStandpipeCount(net, edges);
    return n < 1 ? 1 : n;
  }

  /// Round 49 (fire-convergence-hose-reel-rated-as-class-i-standpipe) — the
  /// standpipe CLASS this system's drawn outlets make it: hose reels only ⇒
  /// [StandpipeClass.classII] (occupant hose stations, 100 gpm / 450 kPa);
  /// hose reels AND hydrant boxes ⇒ [StandpipeClass.classIII] (the 65 mm
  /// outlet governs, so the Class I figures); anything else (hydrant boxes,
  /// or no outlet drawn) ⇒ [StandpipeClass.classI]. `// VERIFY`
  /// notAnSniClause (the hose-reel ⇒ Class II mapping, `SniProfile.
  /// verifyChecklist`).
  StandpipeClass standpipeClass(Network net) {
    var reel = false;
    var box = false;
    for (final n in net.nodes) {
      if (!nodeIds.contains(n.id)) continue;
      if (n.component == NodeComponent.hoseReel) reel = true;
      if (n.component == NodeComponent.hydrantBox) box = true;
    }
    if (reel && !box) return StandpipeClass.classII;
    if (reel && box) return StandpipeClass.classIII;
    return StandpipeClass.classI;
  }

  /// Round 49 (fire-convergence-zone-lift-is-whole-building) — the floor the
  /// system's pump datum sits on: the LOWEST floor of its drawn fire pumps /
  /// booster sets, else the lowest floor any of its nodes is on, else 0.
  int datumFloor(Network net) {
    int? pumpFloor;
    int? anyFloor;
    for (final n in net.nodes) {
      if (!nodeIds.contains(n.id)) continue;
      final f = n.floorIndex;
      anyFloor = anyFloor == null || f < anyFloor ? f : anyFloor;
      if (n.component == NodeComponent.pump ||
          n.component == NodeComponent.boosterSet) {
        pumpFloor = pumpFloor == null || f < pumpFloor ? f : pumpFloor;
      }
    }
    return pumpFloor ?? anyFloor ?? 0;
  }

  /// Round 49 — the highest floor holding one of this system's terminals of
  /// [kind] (hydrant: hydrant boxes / hose reels; sprinkler: heads), at or
  /// below [belowFloor] − 1 when given. Null when none is drawn there.
  int? topTerminalFloor(Network net, FireTerminalKind kind,
      {int? belowFloor}) {
    final servicesAt = <String, Set<ServiceType>>{};
    for (final e in edges) {
      (servicesAt[e.fromId] ??= {}).add(e.service);
      (servicesAt[e.toId] ??= {}).add(e.service);
    }
    int? top;
    for (final n in net.nodes) {
      if (!nodeIds.contains(n.id)) continue;
      if (n.role != NodeRole.fixture || isSupplyInletComponent(n.component)) {
        continue;
      }
      final ok = switch (kind) {
        FireTerminalKind.any => true,
        FireTerminalKind.hydrant =>
          servicesAt[n.id]?.contains(ServiceType.fireHydrant) ?? false,
        FireTerminalKind.sprinkler =>
          servicesAt[n.id]?.contains(ServiceType.fireSprinkler) ?? false,
      };
      if (!ok) continue;
      if (belowFloor != null && n.floorIndex >= belowFloor) continue;
      if (top == null || n.floorIndex > top) top = n.floorIndex;
    }
    return top;
  }

  /// Round 49 (fire-convergence-zone-lift-is-whole-building) — this
  /// system's STATIC LIFT (m) for the [kind] basis: from its pump datum
  /// floor's surface ([datumFloor], or [datumFloorOverride]) to its own
  /// topmost terminal — a hose outlet [kHoseOutletHeightM] above its floor
  /// ([FireTerminalKind.hydrant]) or a sprinkler at its floor's ceiling
  /// ([FireTerminalKind.sprinkler]) — never the whole building's height: a
  /// mid-level pump room serving L10-L19 lifts 30 m, not 60 m. With no
  /// terminal of [kind] drawn (at or below [belowFloor] − 1 when given) the
  /// legacy whole-building top floor is the target. Floors are clamped to
  /// [building]; an empty building lifts 0.
  double staticLiftM(
    Network net,
    BuildingLevels building,
    FireTerminalKind kind, {
    int? datumFloorOverride,
    int? belowFloor,
  }) {
    final nFloors = building.floors.length;
    if (nFloors == 0) return 0;
    int clampF(int f) => f < 0 ? 0 : (f >= nFloors ? nFloors - 1 : f);
    final datum = clampF(datumFloorOverride ?? datumFloor(net));
    final top =
        clampF(topTerminalFloor(net, kind, belowFloor: belowFloor) ?? nFloors - 1);
    final base = building.elevationOf(datum).meters;
    final target = kind == FireTerminalKind.sprinkler
        ? building.ceilingElevationOf(top).meters
        : building.elevationOf(top).meters + kHoseOutletHeightM;
    final lift = target - base;
    return lift > 0 ? lift : 0;
  }
}

/// Round 49 (fire-convergence-series-booster-fire-pump-standby) — the two
/// LEG ENDS of fire pump [pumpId] in [system]: walking from the pump along
/// its fire pipes through bare degree-2 nodes and inline devices (valves,
/// strainers — [isInlineDeviceComponent]) to the first node that is
/// neither (a junction, a leaf, a tank, another pump). Two pumps whose legs
/// share BOTH ends are a PARALLEL set (duty / standby / jockey, drawn
/// between one suction and one discharge); pumps whose legs do not — one
/// reached from the other through the network — are in SERIES (a mid-level
/// booster), each a duty machine of its own stage. Sorted pair; a pump with
/// fewer than two fire pipes repeats its only end (or itself).
(String, String) fireDrawnPumpLegEnds(
    Network net, FireSystem system, String pumpId) {
  final adj = <String, List<NetEdge>>{};
  for (final e in system.edges) {
    (adj[e.fromId] ??= []).add(e);
    (adj[e.toId] ??= []).add(e);
  }
  bool passThrough(String id) {
    if ((adj[id]?.length ?? 0) != 2) return false;
    final c = net.nodeById(id)?.component;
    return c == null || isInlineDeviceComponent(c);
  }

  String walk(NetEdge first) {
    var prev = pumpId;
    var cur = first.fromId == pumpId ? first.toId : first.fromId;
    var via = first;
    final seen = <String>{pumpId};
    while (passThrough(cur) && seen.add(cur)) {
      final next = adj[cur]!.firstWhere((x) => x.id != via.id);
      prev = cur;
      via = next;
      cur = next.fromId == prev ? next.toId : next.fromId;
    }
    return cur;
  }

  final legs = [for (final e in adj[pumpId] ?? const <NetEdge>[]) walk(e)];
  if (legs.isEmpty) return (pumpId, pumpId);
  if (legs.length == 1) return (legs.first, legs.first);
  legs.sort();
  return (legs.first, legs.last);
}

/// The connected fire networks of [net] (union over sprinkler + hydrant
/// edges), ordered by their smallest node id. Pure + deterministic.
List<FireSystem> fireSystems(Network net) {
  final parent = <String, String>{};
  String find(String x) {
    var r = x;
    while (parent[r] != r) {
      r = parent[r]!;
    }
    var c = x;
    while (parent[c] != r) {
      final next = parent[c]!;
      parent[c] = r;
      c = next;
    }
    return r;
  }

  final fire = [
    for (final e in net.edges)
      if (isFireService(e.service)) e,
  ];
  for (final e in fire) {
    parent.putIfAbsent(e.fromId, () => e.fromId);
    parent.putIfAbsent(e.toId, () => e.toId);
    final a = find(e.fromId), b = find(e.toId);
    if (a != b) parent[a] = b;
  }
  final nodes = <String, Set<String>>{};
  final edges = <String, List<NetEdge>>{};
  for (final e in fire) {
    final r = find(e.fromId);
    (nodes[r] ??= <String>{})
      ..add(e.fromId)
      ..add(e.toId);
    (edges[r] ??= <NetEdge>[]).add(e);
  }
  final out = [
    for (final r in nodes.keys) FireSystem(nodes[r]!, edges[r]!),
  ];
  String minId(FireSystem s) =>
      s.nodeIds.reduce((a, b) => a.compareTo(b) < 0 ? a : b);
  out.sort((a, b) => minId(a).compareTo(minId(b)));
  return out;
}

/// Hazen–Williams friction of the SIZED index path from [pumpId] over the
/// fire [system], in metres: Dijkstra on each pipe's friction
/// `hf = 10.67 L Q^1.852 / (C^1.852 D^4.87)` at its sized flow and bore
/// ([sizing]) and its true length ([lengthOf], metres), then the LARGEST
/// friction to any fire terminal (a fixture-role node — sprinkler head,
/// hydrant box — else any leaf other than the pump). A pipe with no sized
/// flow weighs nothing.
///
/// Null when [pumpId] is not in the system, or when any FLOWING pipe the pump
/// reaches has no length (an uncalibrated run — its friction is unknown, so
/// the caller keeps the fixed allowance). C defaults to the clean-steel
/// sprinkler branch figure ([kSprinklerBranchHazenC] = 120, `// VERIFY`).
/// Round 37 — which fire terminals an index path may end at: every fixture
/// ([any], the legacy rule), hydrant outlets only (the HOSE basis) or
/// sprinkler heads only (the sprinkler basis).
enum FireTerminalKind { any, hydrant, sprinkler }

double? fireIndexPathFrictionM({
  required Network net,
  required FireSystem system,
  required String pumpId,
  required Map<String, EdgeSizing> sizing,
  required double Function(NetEdge e) lengthOf,
  double hazenWilliamsC = kSprinklerBranchHazenC,
  FireTerminalKind terminals = FireTerminalKind.any,
}) {
  if (!system.nodeIds.contains(pumpId)) return null;
  final adj = <String, List<NetEdge>>{};
  for (final e in system.edges) {
    (adj[e.fromId] ??= []).add(e);
    (adj[e.toId] ??= []).add(e);
  }
  final weight = <String, double>{};
  var unmeasured = false;
  for (final e in system.edges) {
    final s = sizing[e.id];
    final q = s?.flow.cubicMetersPerSecond ?? 0.0;
    if (s == null || q <= 0 || s.diameter.meters <= 0) {
      weight[e.id] = 0.0;
      continue;
    }
    final l = lengthOf(e);
    if (!(l > 0) || !l.isFinite) {
      weight[e.id] = 0.0;
      unmeasured = true;
      continue;
    }
    weight[e.id] = headLossHazenWilliams(
      flow: s.flow,
      length: Length(l),
      diameter: s.diameter,
      hazenWilliamsC: hazenWilliamsC,
    ).meters;
  }
  final d = <String, double>{pumpId: 0.0};
  final done = <String>{};
  final queue = SplayTreeSet<(double, String)>((x, y) {
    final c = x.$1.compareTo(y.$1);
    return c != 0 ? c : x.$2.compareTo(y.$2);
  })
    ..add((0.0, pumpId));
  while (queue.isNotEmpty) {
    final top = queue.first;
    queue.remove(top);
    final n = top.$2;
    if (!done.add(n)) continue;
    for (final e in adj[n] ?? const <NetEdge>[]) {
      final m = e.fromId == n ? e.toId : e.fromId;
      if (done.contains(m)) continue;
      final nd = d[n]! + weight[e.id]!;
      final old = d[m];
      if (old == null || nd < old) {
        if (old != null) queue.remove((old, m));
        d[m] = nd;
        queue.add((nd, m));
      }
    }
  }
  // An unmeasured flowing pipe the pump reaches: the friction is unknown.
  if (unmeasured &&
      system.edges.any((e) =>
          d.containsKey(e.fromId) &&
          (sizing[e.id]?.flow.cubicMetersPerSecond ?? 0) > 0 &&
          !(lengthOf(e) > 0))) {
    return null;
  }
  // Round 37 (mech-sim-5-combined-fire-pump-head-adds-sprinkler-friction-
  // to-standpipe) — a COMBINED system's hose basis and sprinkler basis are
  // two operating conditions: the hydrant basis reads only hydrant outlets'
  // paths, the sprinkler basis only sprinkler heads' paths. Mixing them added
  // the sprinkler riser's friction at its 6 L/s duty to the 47 L/s hose duty
  // at 6.9 bar (+27.5 m on a 13-level tower).
  final servicesAt = <String, Set<ServiceType>>{};
  for (final e in system.edges) {
    (servicesAt[e.fromId] ??= {}).add(e.service);
    (servicesAt[e.toId] ??= {}).add(e.service);
  }
  bool keep(NetNode n) => switch (terminals) {
        FireTerminalKind.any => true,
        FireTerminalKind.hydrant =>
          servicesAt[n.id]?.contains(ServiceType.fireHydrant) ?? false,
        FireTerminalKind.sprinkler =>
          servicesAt[n.id]?.contains(ServiceType.fireSprinkler) ?? false,
      };
  final fixtures = <String>{
    for (final n in net.nodes)
      if (system.nodeIds.contains(n.id) &&
          n.role == NodeRole.fixture &&
          !isSupplyInletComponent(n.component) &&
          keep(n))
        n.id,
  };
  final terminals0 = fixtures.isNotEmpty
      ? fixtures
      : {
          for (final MapEntry(key: n, value: es) in adj.entries)
            if (es.length == 1 && n != pumpId) n,
        };
  double? worst;
  for (final t in terminals0) {
    final v = d[t];
    if (v == null) continue;
    if (worst == null || v > worst) worst = v;
  }
  return worst;
}

/// Round 49 (fire-convergence-series-booster-fire-pump-standby) — [pumpIds]
/// (fire pumps of [system]) partitioned into PARALLEL SETS: pumps whose legs
/// share both ends ([fireDrawnPumpLegEnds]) form one set (duty + standby +
/// jockey); a pump whose leg shares its ends with no other pump is a set of
/// its own — a SERIES stage (a mid-level booster). Sets are ordered by their
/// lowest pump floor, then their smallest pump id; each set's ids sorted.
List<List<String>> fireParallelPumpSets(
    Network net, FireSystem system, Iterable<String> pumpIds) {
  final byEnds = <(String, String), List<String>>{};
  for (final id in pumpIds) {
    if (!system.nodeIds.contains(id)) continue;
    (byEnds[fireDrawnPumpLegEnds(net, system, id)] ??= []).add(id);
  }
  int floorOf(String id) => net.nodeById(id)?.floorIndex ?? 0;
  final sets = [
    for (final g in byEnds.values) [...g]..sort(),
  ];
  int minFloor(List<String> g) =>
      g.map(floorOf).reduce((a, b) => a < b ? a : b);
  sets.sort((a, b) {
    final f = minFloor(a).compareTo(minFloor(b));
    return f != 0 ? f : a.first.compareTo(b.first);
  });
  return sets;
}
