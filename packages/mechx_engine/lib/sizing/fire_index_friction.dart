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

  /// Round 52 — the edges of a SHARED source part (a suction header two
  /// independent pump rooms draw from) this system carries only as its
  /// supply: they never decide the system's KIND ([hasHydrant] /
  /// [hasSprinkler]). Empty for every system [fireSystems] returns; set only
  /// on the sub-systems of [splitFireSystemAtSharedSource].
  final Set<String> sourceEdgeIds;

  const FireSystem(this.nodeIds, this.edges, {this.sourceEdgeIds = const {}});

  /// True when a hydrant / standpipe edge is part of this system.
  bool get hasHydrant => edges.any((e) =>
      e.service == ServiceType.fireHydrant && !sourceEdgeIds.contains(e.id));

  /// True when a sprinkler edge is part of this system.
  bool get hasSprinkler => edges.any((e) =>
      e.service == ServiceType.fireSprinkler && !sourceEdgeIds.contains(e.id));

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
  int? topTerminalFloor(Network net, FireTerminalKind kind, {int? belowFloor}) {
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

  /// Round 52 — the highest floor any of this system's nodes sits on (at or
  /// below [belowFloor] − 1 when given); null when none.
  int? highestNodeFloor(Network net, {int? belowFloor}) {
    int? top;
    for (final n in net.nodes) {
      if (!nodeIds.contains(n.id)) continue;
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
  /// Round 52 (regression-transfer-pump-into-tank-rated-whole-building-
  /// standpipe) — with no terminal of [kind] drawn the target is this
  /// system's OWN highest node (at or below [belowFloor] − 1 when given), never
  /// the whole-building top floor: a transfer fragment GT -> TP -> TT(L10)
  /// of a 20-storey tower lifts to L10, not L19. With no node at all the lift
  /// is 0. Floors are clamped to [building]; an empty building lifts 0.
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
    final topRaw = topTerminalFloor(net, kind, belowFloor: belowFloor) ??
        highestNodeFloor(net, belowFloor: belowFloor);
    if (topRaw == null) return 0;
    final top = clampF(topRaw);
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

/// Round 51 (fire-convergence-3-shared-tank-merges-independent-sprinkler-
/// and-hydrant-pumps-into-one-rating) — a STORAGE TANK (ground / roof tank)
/// is a hydraulic break: the pressure on one side of it never reaches the
/// other. [fireSystems] joins fire edges only through non-tank nodes, so a
/// sprinkler pump and a hydrant pump drawn off one shared ground tank are two
/// systems, each rated on its own terminals.
bool isFireSystemBoundary(NetNode? n) =>
    n != null &&
    (n.component == NodeComponent.groundTank ||
        n.component == NodeComponent.roofTank);

/// The connected fire networks of [net] (union over sprinkler + hydrant
/// edges), ordered by their smallest node id. Pure + deterministic.
///
/// Round 51 — the union runs only through NON-TANK nodes
/// ([isFireSystemBoundary]); a tank belongs to EVERY system whose pipes touch
/// it (its node id is in each system's [FireSystem.nodeIds]). A pipe between
/// two tanks joins only those two tanks.
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
  bool tank(String id) => isFireSystemBoundary(net.nodeById(id));
  // The node an edge joins its system through: a non-tank end (both ends
  // non-tank are unioned), else the from-tank (a tank-to-tank pipe).
  String anchor(NetEdge e) => !tank(e.fromId)
      ? e.fromId
      : !tank(e.toId)
          ? e.toId
          : e.fromId;
  for (final e in fire) {
    final ta = tank(e.fromId), tb = tank(e.toId);
    if (ta != tb) {
      final x = ta ? e.toId : e.fromId;
      parent.putIfAbsent(x, () => x);
      continue;
    }
    parent.putIfAbsent(e.fromId, () => e.fromId);
    parent.putIfAbsent(e.toId, () => e.toId);
    final a = find(e.fromId), b = find(e.toId);
    if (a != b) parent[a] = b;
  }
  final nodes = <String, Set<String>>{};
  final edges = <String, List<NetEdge>>{};
  for (final e in fire) {
    final r = find(anchor(e));
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

/// Round 52 (regression-shared-suction-header-pump-rooms-still-combined-
/// duty) — [system] split per INDEPENDENT pump room: when its pump chain
/// ([fireSeriesPumpStages]) has two or more ROOT stages (stages drawing from
/// the system's pump-free source part — a bare suction header both a
/// sprinkler pump and a hydrant pump tee off), each root stage and every stage
/// downstream of it is its own sub-system, carrying the shared source part as
/// [FireSystem.sourceEdgeIds] (its supply, never its kind), the legs of its
/// own pumps and the discharge parts of its own stages. The header is the
/// same hydraulic break a shared tank is ([isFireSystemBoundary]): neither
/// pump room's pressure reaches the other's terminals. Any other system
/// (one pump room, a series chain, an unreadable chain) is returned as is.
List<FireSystem> splitFireSystemAtSharedSource(Network net, FireSystem system) {
  final pumps = [
    for (final n in net.nodes)
      if (system.nodeIds.contains(n.id) &&
          (n.component == NodeComponent.pump ||
              n.component == NodeComponent.boosterSet))
        n.id,
  ]..sort();
  if (pumps.length < 2) return [system];
  final sets = fireParallelPumpSets(net, system, pumps);
  final topo = fireSeriesPumpStages(net, system, sets);
  if (topo == null) return [system];
  final roots = [
    for (var k = 0; k < topo.length; k++)
      if (topo[k].upstream == null) k,
  ];
  if (roots.length < 2) return [system];
  final pumpSet = pumps.toSet();
  final dischargeEdgeIds = <String>{
    for (final st in topo)
      for (final e in st.discharge.edges) e.id,
  };
  final sourceEdgeIds = <String>{
    for (final e in system.edges)
      if (!pumpSet.contains(e.fromId) &&
          !pumpSet.contains(e.toId) &&
          !dischargeEdgeIds.contains(e.id))
        e.id,
  };
  // A root pump's SUCTION leg (pump -> a node of the shared source part) is
  // supply too: its service never decides the pump room's kind.
  final sourceNodes = <String>{
    for (final e in system.edges)
      if (sourceEdgeIds.contains(e.id)) ...[e.fromId, e.toId],
  };
  final suctionLegIds = <String>{
    for (final e in system.edges)
      if (pumpSet.contains(e.fromId) != pumpSet.contains(e.toId) &&
          sourceNodes.contains(
              pumpSet.contains(e.fromId) ? e.toId : e.fromId))
        e.id,
  };
  final out = <FireSystem>[];
  for (final r in roots) {
    final stages = <int>{r};
    var grew = true;
    while (grew) {
      grew = false;
      for (var k = 0; k < topo.length; k++) {
        final up = topo[k].upstream;
        if (up != null && stages.contains(up) && stages.add(k)) grew = true;
      }
    }
    final ownPumps = {for (final k in stages) ...topo[k].pumpIds};
    final ownDischarge = {
      for (final k in stages)
        for (final e in topo[k].discharge.edges) e.id,
    };
    final edges = [
      for (final e in system.edges)
        if (sourceEdgeIds.contains(e.id) ||
            ownDischarge.contains(e.id) ||
            ownPumps.contains(e.fromId) ||
            ownPumps.contains(e.toId))
          e,
    ];
    out.add(FireSystem(
      {for (final e in edges) ...[e.fromId, e.toId]},
      edges,
      sourceEdgeIds: {
        for (final e in edges)
          if (sourceEdgeIds.contains(e.id) || suctionLegIds.contains(e.id))
            e.id,
      },
    ));
  }
  return out;
}

/// Round 52 — the fire systems each RATED on its own pump: [fireSystems]
/// (in their order), each split per independent pump room
/// ([splitFireSystemAtSharedSource], in root-stage order). [fireSystems]
/// itself stays the edge partition the sizer reads.
List<FireSystem> fireRatingSystems(Network net) => [
      for (final s in fireSystems(net)) ...splitFireSystemAtSharedSource(net, s),
    ];

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
  Set<String>? targetIds,
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
  // Round 52 — an explicit target set (a transfer pump's destination tank).
  final terminals0 = targetIds != null
      ? targetIds
      : fixtures.isNotEmpty
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
///
/// Round 50 (regression-1 / fire-convergence-2-jockey-on-downstream-tee) —
/// equal leg ends are only how a set is RECOGNISED, not what makes pumps
/// parallel: a pump room drawn with a suction and a discharge HEADER where
/// each pump tees in at its own point (GT-S1-S2-S3, Si-FPi-Di, D1-D2-D3), or
/// a jockey discharging onto a tee downstream of the main header, gives
/// every pump distinct leg ends. Pumps on ONE floor are one pump room, so
/// every leg-end part whose lowest pump floor is the same is MERGED into one
/// set; only pumps on DIFFERENT floors (a series booster reached through the
/// network) stay separate stages — the same floor rule the fire basis uses to
/// group stages.
///
/// Round 50 r2 — a same-floor merge also needs the parts to sit between the
/// SAME two pipe networks: each leg end is labelled by its PUMP-FREE
/// connected part of the system (the fire pipework with every pump in
/// [pumpIds] removed), and only parts whose (suction, discharge) label pair
/// is equal merge. A pump room's headers join every suction pump-free (and
/// every discharge), so it still merges; two INDEPENDENT machines on one
/// floor (a sprinkler pump and a hydrant pump drawn off one shared tank)
/// share only the suction side and stay separate duty machines; so does a
/// same-floor series booster (its suction is the main pump's discharge).
List<List<String>> fireParallelPumpSets(
    Network net, FireSystem system, Iterable<String> pumpIds) {
  final pumps = {
    for (final id in pumpIds)
      if (system.nodeIds.contains(id)) id,
  };
  // Pump-free parts of the system (union-find over pipes touching no pump).
  final parent = <String, String>{};
  String find(String x) {
    parent.putIfAbsent(x, () => x);
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

  for (final e in system.edges) {
    if (pumps.contains(e.fromId) || pumps.contains(e.toId)) continue;
    final a = find(e.fromId), b = find(e.toId);
    if (a != b) parent[a] = b;
  }
  final byEnds = <(String, String), List<String>>{};
  for (final id in [...pumps]..sort()) {
    (byEnds[fireDrawnPumpLegEnds(net, system, id)] ??= []).add(id);
  }
  int floorOf(String id) => net.nodeById(id)?.floorIndex ?? 0;
  int minFloor(List<String> g) =>
      g.map(floorOf).reduce((a, b) => a < b ? a : b);
  // A leg end that is itself a pump (pumps drawn back-to-back) keeps its own
  // id as its label.
  String label(String end) => pumps.contains(end) ? end : find(end);
  final byKey = <(int, String, String), List<String>>{};
  for (final MapEntry(key: ends, value: g) in byEnds.entries) {
    final a = label(ends.$1), b = label(ends.$2);
    final pair = a.compareTo(b) <= 0 ? (a, b) : (b, a);
    (byKey[(minFloor(g), pair.$1, pair.$2)] ??= []).addAll(g);
  }
  final sets = [
    for (final g in byKey.values) [...g]..sort(),
  ];
  sets.sort((a, b) {
    final f = minFloor(a).compareTo(minFloor(b));
    return f != 0 ? f : a.first.compareTo(b.first);
  });
  return sets;
}

/// Round 51 (regression-same-floor-series-booster-full-head) — one STAGE of a
/// fire system's pump chain: the parallel pump set(s) [pumpIds] that take
/// suction from one pump-free part of the system and discharge into another
/// ([discharge], the pump-free pipework + terminals that stage serves
/// directly), fed by the stage [upstream] (an index into the list, null for a
/// stage drawing from the system's source).
class FirePumpStage {
  final List<String> pumpIds;
  final FireSystem discharge;
  final int? upstream;
  const FirePumpStage(this.pumpIds, this.discharge, this.upstream);
}

/// Round 51 (regression-same-floor-series-booster-full-head) — the pump
/// [sets] of [system] (from [fireParallelPumpSets]) ordered TOPOLOGICALLY
/// along the flow, never by floor: every pump-free part of the system (the
/// fire pipework with every pump removed) is a label; the source label is
/// the part holding a non-pump plant (a tank / source — never a supply
/// inlet); a set whose one label is already reached takes suction from it and
/// discharges into its other label, so a ground-floor series booster
/// (main pump discharge -> booster -> upper zone, both in one pump room)
/// follows the main pump exactly as a booster drawn on the upper floor does.
/// Sets between the SAME two labels are one stage (duty / standby on two
/// floors). Stages are returned in breadth-first order from the source, each
/// after the stage feeding it.
///
/// Null when the chain cannot be read from the topology — no source part, a
/// pump whose two leg ends lie in one part or reach another pump directly, a
/// set whose both labels are
/// reached (a bypass), a set never reached, or a part fed by two different
/// stages — the caller then keeps its legacy floor grouping.
List<FirePumpStage>? fireSeriesPumpStages(
    Network net, FireSystem system, List<List<String>> sets) {
  final pumps = {for (final g in sets) ...g};
  if (pumps.isEmpty) return null;
  final parent = <String, String>{};
  String find(String x) {
    parent.putIfAbsent(x, () => x);
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

  for (final e in system.edges) {
    if (pumps.contains(e.fromId) || pumps.contains(e.toId)) continue;
    final a = find(e.fromId), b = find(e.toId);
    if (a != b) parent[a] = b;
  }
  String label(String end) => pumps.contains(end) ? end : find(end);

  // Each set's (unordered) label pair — every pump of a set shares it.
  final pairs = <(String, String)>[];
  for (final g in sets) {
    if (g.isEmpty) return null;
    final ends = fireDrawnPumpLegEnds(net, system, g.first);
    final a = label(ends.$1), b = label(ends.$2);
    // One part on both sides, or pumps drawn back-to-back (a leg end that is
    // another pump — no pump-free part between them to order by): unreadable.
    if (a == b || pumps.contains(a) || pumps.contains(b)) return null;
    for (final id in g.skip(1)) {
      final o = fireDrawnPumpLegEnds(net, system, id);
      final oa = label(o.$1), ob = label(o.$2);
      if (!((oa == a && ob == b) || (oa == b && ob == a))) return null;
    }
    pairs.add((a, b));
  }

  // Source labels: parts holding a non-pump, non-inlet plant node.
  final sources = <String>{
    for (final n in net.nodes)
      if (system.nodeIds.contains(n.id) &&
          !pumps.contains(n.id) &&
          n.role == NodeRole.plant &&
          !isSupplyInletComponent(n.component))
        label(n.id),
  };
  if (sources.isEmpty) return null;

  final reached = <String>{...sources};
  final suction = <int, String>{};
  final dischargeLabel = <int, String>{};
  final order = <int>[];
  var progress = true;
  while (progress && order.length < sets.length) {
    progress = false;
    for (var i = 0; i < sets.length; i++) {
      if (suction.containsKey(i)) continue;
      final (a, b) = pairs[i];
      final ra = reached.contains(a), rb = reached.contains(b);
      // Both sides reached in an earlier round: a bypass / second feed.
      // (Sets between the same two labels are reached in the SAME round —
      // `reached` grows only after it — and grouped into one stage below.)
      if (ra && rb) return null;
      if (!ra && !rb) continue;
      suction[i] = ra ? a : b;
      dischargeLabel[i] = ra ? b : a;
      order.add(i);
      progress = true;
    }
    // Only now mark this round's discharges reached, so two sets touching a
    // label in the same round are judged together.
    for (final i in order) {
      reached.add(dischargeLabel[i]!);
    }
  }
  if (order.length < sets.length) return null;

  // Group sets with the same (suction, discharge) into one stage.
  final stageOfPair = <(String, String), int>{};
  final stagePumps = <List<String>>[];
  final stageSuction = <String>[];
  final stageDischarge = <String>[];
  for (final i in order) {
    final key = (suction[i]!, dischargeLabel[i]!);
    final k = stageOfPair[key];
    if (k != null) {
      stagePumps[k].addAll(sets[i]);
      continue;
    }
    stageOfPair[key] = stagePumps.length;
    stagePumps.add([...sets[i]]);
    stageSuction.add(key.$1);
    stageDischarge.add(key.$2);
  }
  // A part fed by two different stages: ambiguous.
  if (stageDischarge.toSet().length != stageDischarge.length) return null;

  final out = <FirePumpStage>[];
  for (var k = 0; k < stagePumps.length; k++) {
    final lab = stageDischarge[k];
    final nodes = <String>{};
    final edges = <NetEdge>[];
    for (final e in system.edges) {
      if (pumps.contains(e.fromId) || pumps.contains(e.toId)) continue;
      if (find(e.fromId) != lab) continue;
      nodes
        ..add(e.fromId)
        ..add(e.toId);
      edges.add(e);
    }
    if (!pumps.contains(lab)) nodes.add(lab);
    final up = stageDischarge.indexOf(stageSuction[k]);
    out.add(FirePumpStage([...stagePumps[k]]..sort(), FireSystem(nodes, edges),
        up < 0 ? null : up));
  }
  return out;
}
