/// §P5 Fire standpipe / hydrant system + fire-pump sizing module.
///
/// ─────────────────────────────── PROVENANCE ─────────────────────────────────
/// The design flows, residual pressures, riser-diameter minimum, and flow-
/// accumulation rules in this file are taken from the Indonesian national
/// standards below. Engineering assumptions that the standards do NOT fix
/// (friction allowance, pump efficiency) remain tagged `// VERIFY`.
///
///   • SNI 03-1745-2000 — Tata Cara Perencanaan dan Pemasangan Sistem Pipa
///     Tegak dan Slang untuk Pencegahan Bahaya Kebakaran pada Bangunan Rumah
///     dan Gedung (standpipe & hose-cabinet system — flow, pressure, riser
///     rules).
///
///   • SNI 03-6570-2001 — Instalasi Pompa yang Dipasang Tetap untuk Proteksi
///     Kebakaran (fixed fire-pump installation — head, power, duty-point rules).
/// ─────────────────────────────────────────────────────────────────────────────
///
/// Pure Dart; zero Flutter imports (§12: engine is framework-free).
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/network.dart'
    show
        EdgeKind,
        NetEdge,
        Network,
        NodeComponent,
        NodeRole,
        ServiceType,
        isSupplyInletComponent;
import 'package:mechx_engine/sizing/fire_index_friction.dart'
    show fireRatingSystems, fireSystems, isFireSystemBoundary;
import 'package:mechx_engine/standards/sni.dart'
    show StandardValue, VerificationStatus;
import 'package:mechx_engine/units.dart';

// ── Unit conversion ──────────────────────────────────────────────────────────

/// US liquid gallon → litre. SNI 03-1745-2000 states standpipe flow demands in
/// US gpm (adopted from NFPA 14); we work internally in L/min.
const double _usGallonToLitre = 3.785411784;

// ── Standpipe class ──────────────────────────────────────────────────────────

/// Standpipe system class per SNI 03-1745-2000 §4, selected by hose-outlet size
/// and intended user. The class fixes the minimum residual pressure required at
/// the topmost (most remote) outlet.
enum StandpipeClass {
  /// Class I — 65 mm (2½") connections for trained fire-fighters. Residual
  /// 6.9 bar (690 kPa) at the most remote outlet.
  classI,

  /// Class II — 40 mm (1½") hose stations for building occupants. Residual
  /// 4.5 bar (450 kPa) at the most remote outlet.
  classII,

  /// Class III — both 65 mm and 40 mm outlets. The 65 mm outlet governs, so the
  /// higher Class I residual (6.9 bar) applies.
  classIII,
}

// ── Design constants (SNI 03-1745-2000) ──────────────────────────────────────

/// Minimum flow demand of the most remote (first) standpipe riser, in L/min.
///
/// SNI 03-1745-2000 (adopted from NFPA 14): 500 gpm (≈ 1893 L/min) at the
/// hydraulically most remote standpipe. (Corrected 2026-10-18 from a
/// web-seeded 550 gpm that contradicted the 1250 gpm cap's own 4-riser
/// arithmetic: 500 + 3 × 250 = 1250.) // VERIFY — secondarySource until the
/// SNI PDF is read.
const double kFirstRiserFlowLpm = 500.0 * _usGallonToLitre; // ≈ 1893 L/min

/// Additional flow added for each riser beyond the first, in L/min.
///
/// SNI 03-1745-2000: 250 gpm per additional standpipe.
const double kAdditionalRiserFlowLpm = 250.0 * _usGallonToLitre; // ≈ 946 L/min

/// Maximum total standpipe system flow demand, in L/min, regardless of riser
/// count.
///
/// SNI 03-1745-2000: the sum need not exceed 1250 gpm.
const double kMaxStandpipeFlowLpm = 1250.0 * _usGallonToLitre; // ≈ 4732 L/min

/// Round 49 (fire-convergence-hose-reel-rated-as-class-i-standpipe) — the
/// flow demand (L/min) of a CLASS II (occupant hose-station / hose-reel)
/// standpipe system: NFPA 14 Class II 100 gpm (≈ 379 L/min, 6.31 L/s), with
/// no addition per extra riser. A hose-reel-only system was rated as a Class I
/// 500 gpm standpipe (31.5 L/s, 55 kW on a 3-storey shophouse).
/// // VERIFY — NFPA 14 Class II, notAnSniClause (SNI 03-1745 hose-reel
/// practice); surfaced via `SniProfile.verifyChecklist`.
const double kClassIIStandpipeFlowLpm = 100.0 * _usGallonToLitre; // ≈ 379 L/min

/// Round 49 — minimum riser (mm) of a CLASS II hose-station system (a 40 mm
/// hose station on a 50 mm riser, NFPA 14). // VERIFY notAnSniClause.
const double kMinClassIIRiserDiameterMm = 50.0;

/// Round 49 — minimum horizontal run (mm) feeding a CLASS II 40 mm hose
/// station / hose reel (the outlet size). // VERIFY notAnSniClause.
const double kMinHoseStationBranchDiameterMm = 40.0;

/// Minimum residual pressure at the most remote 65 mm (Class I/III) outlet, kPa.
///
/// SNI 03-1745-2000: 6.9 bar (100 psi) at the farthest 65 mm hose connection.
const double kResidualPressureClassIKpa = 690.0;

/// Minimum residual pressure at the most remote 40 mm (Class II) outlet, kPa.
///
/// SNI 03-1745-2000: 4.5 bar (65 psi) at the farthest 40 mm hose-box outlet.
const double kResidualPressureClassIIKpa = 450.0;

/// Minimum standpipe (riser) diameter for Class I and Class III systems.
///
/// SNI 03-1745-2000: standpipes for Class I and III must be at least 100 mm
/// (4"). (Class II systems may use smaller risers.)
const double kMinRiserDiameterMm = 100.0;

/// Minimum nominal diameter (mm) of a drawn HORIZONTAL hydrant run (the pipe
/// feeding a hose cabinet / landing valve) in the network sizer.
///
/// A Class I hose connection is 65 mm (2½"), so the pipe serving it is never
/// smaller than the valve it feeds. The vertical standpipe itself takes the
/// SNI 100 mm minimum ([kMinRiserDiameterMm]).
///
/// // VERIFY — follows from the 65 mm Class I outlet size (general practice),
/// NOT an explicit SNI 03-1745-2000 pipe-size clause. Surfaced via
/// `SniProfile.verifyChecklist` (status `notAnSniClause`).
const double kMinHydrantBranchDiameterMm = 65.0;

/// Round 61 (fire-convergence-13-yard-hydrants-rated-as-building-standpipe)
/// — the YARD (pillar / hidran halaman) hydrant design flow: 38 L/s, the
/// flow SNI 03-1735-2000 asks of the yard hydrant supply. `// VERIFY`
/// secondarySource (the exact clause pending the official text).
const double kYardHydrantFlowLps = 38.0;

/// Round 61 — the residual at the yard hydrant outlet: 3.5 bar (350 kPa),
/// SNI 03-1735-2000 hidran halaman. `// VERIFY` secondarySource.
const double kYardHydrantResidualKpa = 350.0;

/// Round 61 — the minimum bore of a private fire service main and of a yard
/// hydrant lateral: 6 in (DN150), NFPA 24 10.1.1. `// VERIFY`
/// notAnSniClause.
const double kMinYardMainDiameterMm = 150.0;

/// Round 61 — the unverified items behind the yard hydrant basis.
const List<StandardValue<Object?>> yardHydrantVerifyChecklist = [
  StandardValue<Object?>(kYardHydrantFlowLps,
      unit: 'L/s',
      citation: 'SNI 03-1735-2000 — yard (pillar) hydrant flow',
      note: 'The yard hydrant supply delivers 38 L/s; secondary source '
          'pending the official clause.'),
  StandardValue<Object?>(kYardHydrantResidualKpa,
      unit: 'kPa',
      citation: 'SNI 03-1735-2000 — yard hydrant residual pressure',
      note: '3.5 bar (350 kPa) at the yard hydrant outlet; secondary source '
          'pending the official clause.'),
  StandardValue<Object?>(kMinYardMainDiameterMm,
      unit: 'mm',
      citation: 'NFPA 24 10.1.1 — private fire service main minimum',
      status: VerificationStatus.notAnSniClause,
      note: 'Yard fire mains and hydrant laterals are at least 6 in (DN150) '
          '(NFPA 24); confirm against the SNI 03-1735 practice adopted.'),
];

/// Round 37 (mech-sim-5-fdc-line-sized-at-zero-flow) — minimum nominal
/// diameter (mm) of the FIRE-DEPARTMENT-CONNECTION inlet pipe (the FDC and
/// its unbranched chain to the system). The brigade pumps the system design
/// flow in through it, so it is sized on that flow and never below 100 mm.
///
/// // VERIFY — NFPA 14 / general practice (FDC piping ≥ 100 mm), NOT an
/// explicit SNI 03-1745-2000 clause. Surfaced via `SniProfile.verifyChecklist`
/// (status `notAnSniClause`).
const double kFdcMinBoreMm = 100.0;

/// Height of a hose-cabinet landing valve above its own finished floor (m).
///
/// // VERIFY — representative Indonesian hydrant-box mounting (≈ 0.9–1.5 m,
/// 1.2 m typical), general practice NOT an SNI clause. Surfaced via
/// `SniProfile.verifyChecklist` (status `notAnSniClause`).
const double kHoseOutletHeightM = 1.2;

/// Round 21 (fire-3-fire-pipe-sized-on-domestic-velocity-cap) — the velocity
/// cap the FIRE services (sprinkler + hydrant) are sized against, in m/s.
/// The domestic SNI 03-7065 2.0 m/s limit is a water-hammer / noise limit for
/// a system that runs daily; a fire system runs only in a fire. EN 12845
/// caps 6 m/s at valves / flow switches (10 m/s elsewhere) and NFPA 13 sets
/// no velocity cap at all, so 6 m/s is the conservative fire figure.
/// `// VERIFY` notAnSniClause (general fire-engineering practice); the code
/// minimum diameters still floor every fire pipe.
const double kMaxFireVelocityMps = 6.0;

/// Minimum residual pressure required at the topmost outlet for [cls], in kPa.
double residualPressureKpa(StandpipeClass cls) {
  switch (cls) {
    case StandpipeClass.classI:
    case StandpipeClass.classIII:
      return kResidualPressureClassIKpa;
    case StandpipeClass.classII:
      return kResidualPressureClassIIKpa;
  }
}

// ── Flow-demand helper ────────────────────────────────────────────────────────

/// Total standpipe system flow demand for [risers] active risers
/// (SNI 03-1745-2000):
///
///   Q = kFirstRiserFlowLpm + kAdditionalRiserFlowLpm × (risers − 1)
///
/// clamped to the range `[kFirstRiserFlowLpm, kMaxStandpipeFlowLpm]`
/// (i.e. 500 gpm minimum, 1250 gpm cap).
///
/// Examples (gpm → L/min):
///   risers = 1 →  500 gpm ≈ 1893 L/min
///   risers = 2 →  750 gpm ≈ 2839 L/min
///   risers = 3 → 1000 gpm ≈ 3785 L/min
///   risers = 4 → 1250 gpm ≈ 4732 L/min [500 + 3×250 — exactly the cap]
///   risers = 6 → 1250 gpm (cap applies)
///
/// Round 49 — a [StandpipeClass.classII] (hose-reel / hose-station only)
/// system demands [kClassIIStandpipeFlowLpm] (100 gpm) whatever its riser
/// count; Class I / III are unchanged.
FlowRate standpipeFlow(int risers,
    {StandpipeClass standpipeClass = StandpipeClass.classI}) {
  assert(risers >= 1, 'risers must be ≥ 1');
  if (standpipeClass == StandpipeClass.classII) {
    return FlowRate.litersPerMinute(kClassIIStandpipeFlowLpm);
  }
  final lpm = (kFirstRiserFlowLpm + kAdditionalRiserFlowLpm * (risers - 1))
      .clamp(kFirstRiserFlowLpm, kMaxStandpipeFlowLpm);
  return FlowRate.litersPerMinute(lpm);
}

/// Round 21 (fire-3-standpipe-riser-count-fixed-at-one) — the number of
/// STANDPIPE RISERS drawn in [net] that run IN PARALLEL. Feeds
/// [standpipeFlow] (500 gpm + 250 gpm per additional riser), so two drawn
/// side-by-side stacks rate the fire pump at 750 gpm, not 500. At least 1 —
/// with no hydrant riser drawn the draft single-riser basis stands. Pure.
///
/// Round 22 (regression-jogged-standpipe-counted-twice) — a stack is a
/// connected component of fire-hydrant RISER edges (joined only through riser
/// edges, so a common pump header does not merge two stacks), but a single
/// standpipe that JOGS at a transfer floor (riser, horizontal run, riser) is
/// two such components covering DISJOINT floor spans — hydraulically one
/// standpipe. So the count is the maximum, over every storey interval
/// (f, f+1), of the components whose floor span covers it
/// ([parallelStandpipeCount]).
///
/// Round 28 (fire-3-standpipe-stacks-counted-across-independent-systems) —
/// stacks are counted PER CONNECTED FIRE SYSTEM ([fireSystems]) and the
/// largest system's count is returned: two towers, each with its own pump
/// and one stack, are two 500 gpm systems, never one 750 gpm system (each
/// pump rated 50 % high, contradicting the per-system trunk sizing). The
/// per-system count is [FireSystem.standpipeRisers].
///
/// Round 53 (regression-shared-header-sizer-partitions-on-fireSystems) — the
/// systems are the RATING systems ([fireRatingSystems]): two pump rooms
/// teed off one bare suction header are two systems (one stack each), never
/// one two-stack system (750 gpm on the header and a hose-reel tower sized
/// as Class III).
int drawnStandpipeRiserCount(Network net) {
  var best = 1;
  for (final s in fireRatingSystems(net)) {
    best = math.max(best, parallelStandpipeCount(net, s.edges));
  }
  return best;
}

/// Round 22 — the number of standpipe stacks among [edges] (only fire-hydrant
/// RISER edges count) that run in PARALLEL: riser components are found by
/// union-find over those edges, each spans [min floor, max floor] of its
/// nodes, and the result is the largest number of components covering any one
/// storey interval (f, f+1). Stacks in SERIES (a jogged standpipe) cover
/// disjoint intervals and count once; side-by-side stacks count each. 0 when
/// no riser edge is given. Pure.
int parallelStandpipeCount(Network net, Iterable<NetEdge> edges) {
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

  // Round 54 (regression-hydrant-standpipe-flow-lost-on-sprinkler-drawn-
  // riser) — a combined riser drawn on the SPRINKLER service with hydrant
  // outlets teed off it is a standpipe stack too: sprinkler risers join the
  // union, and a component counts when it holds a hydrant riser OR a hydrant
  // pipe tees off one of its nodes ABOVE its lowest floor (a sprinkler riser
  // teed only at its base off a hydrant header is no stack).
  //
  // Round 55 (regression-hydrant-cross-tie-adds-phantom-standpipe-stack) —
  // the hydrant pipe teed off the sprinkler riser must reach a HOSE OUTLET
  // (hydrant box / hose reel) of its own: a top-floor cross-tie from a
  // hydrant stack to a sprinkler riser touched that riser above its base and
  // counted it as a second stack (750 gpm and DN125 on a 500 gpm pump). The
  // hydrant branch region reached from the node (hydrant edges only, never
  // through a riser node or a plant) counts when it holds an outlet and
  // touches NO other riser component — a pipe joining another stack is a
  // cross-tie, not this riser's outlet.
  final edgeList = edges.toList();
  final risers = <NetEdge>[
    for (final e in edgeList)
      if ((e.service == ServiceType.fireHydrant ||
              e.service == ServiceType.fireSprinkler) &&
          e.kind == EdgeKind.riser)
        e,
  ];
  final hydrantRiserNodes = <String>{
    for (final e in risers)
      if (e.service == ServiceType.fireHydrant) ...[e.fromId, e.toId],
  };
  for (final e in risers) {
    parent.putIfAbsent(e.fromId, () => e.fromId);
    parent.putIfAbsent(e.toId, () => e.toId);
    final a = find(e.fromId);
    final b = find(e.toId);
    if (a != b) parent[a] = b;
  }
  if (parent.isEmpty) return 0;
  final floorOf = {for (final n in net.nodes) n.id: n.floorIndex};
  final lo = <String, int>{};
  final hi = <String, int>{};
  for (final id in parent.keys) {
    final root = find(id);
    final f = floorOf[id] ?? 0;
    lo[root] = math.min(lo[root] ?? f, f);
    hi[root] = math.max(hi[root] ?? f, f);
  }
  final nodeById = {for (final n in net.nodes) n.id: n};
  bool isHoseOutlet(String id) {
    final n = nodeById[id];
    return n != null &&
        n.role == NodeRole.fixture &&
        (n.component == NodeComponent.hydrantBox ||
            n.component == NodeComponent.hoseReel);
  }

  // Round 56 (fire-convergence-8-standpipe-stack-count-includes-ring-legs-
  // pillar-drops-and-fdc-riser) — two kinds of hydrant riser are no stack:
  //  * an INLET riser — the fire-department connection's drop to the pump
  //    discharge: its branches above its base reach an inlet
  //    ([isSupplyInletComponent]) and no hose outlet;
  //  * a BRANCH DROP — a ONE-storey riser (a ring leg down a car-park ramp,
  //    a drop to a pillar hydrant) the fire source reaches only THROUGH
  //    another riser component spanning that same storey: it is that
  //    stack's distribution, already sized by the ring / trunk rules, never
  //    a second standpipe in parallel with it.
  // Both are classified on the WHOLE drawn fire network, so a sub-list of
  // [edges] (the sizer's downstream walks) counts consistently.
  final fireAdj = <String, List<String>>{};
  final fullParent = <String, String>{};
  String findFull(String x) {
    var r = x;
    while (fullParent[r] != r) {
      r = fullParent[r]!;
    }
    return r;
  }

  for (final e in net.edges) {
    if (e.service != ServiceType.fireHydrant &&
        e.service != ServiceType.fireSprinkler) {
      continue;
    }
    (fireAdj[e.fromId] ??= []).add(e.toId);
    (fireAdj[e.toId] ??= []).add(e.fromId);
    if (e.kind != EdgeKind.riser) continue;
    fullParent.putIfAbsent(e.fromId, () => e.fromId);
    fullParent.putIfAbsent(e.toId, () => e.toId);
    final a = findFull(e.fromId);
    final b = findFull(e.toId);
    if (a != b) fullParent[a] = b;
  }
  final fullLo = <String, int>{};
  final fullHi = <String, int>{};
  for (final id in fullParent.keys) {
    final r = findFull(id);
    final f = floorOf[id] ?? 0;
    fullLo[r] = math.min(fullLo[r] ?? f, f);
    fullHi[r] = math.max(fullHi[r] ?? f, f);
  }
  final sources = <String>[
    for (final id in fireAdj.keys)
      if (nodeById[id]?.role == NodeRole.plant &&
          !isSupplyInletComponent(nodeById[id]?.component))
        id,
  ];

  bool isInletRiser(String root) {
    final members = [
      for (final id in parent.keys)
        if (find(id) == root) id,
    ];
    var inlet = false;
    final seen = <String>{...members};
    final queue = <String>[];
    for (final id in members) {
      if (isSupplyInletComponent(nodeById[id]?.component)) inlet = true;
      if (isHoseOutlet(id)) return false;
      if ((floorOf[id] ?? 0) > lo[root]!) queue.add(id);
    }
    for (var i = 0; i < queue.length; i++) {
      for (final o in fireAdj[queue[i]] ?? const <String>[]) {
        if (!seen.add(o)) continue;
        if (fullParent.containsKey(o)) continue; // another riser: a wall
        if (isHoseOutlet(o)) return false;
        final n = nodeById[o];
        if (isSupplyInletComponent(n?.component)) inlet = true;
        if (n?.role == NodeRole.plant) continue;
        queue.add(o);
      }
    }
    return inlet;
  }

  // Round 58 (regression-pillar-drops-off-riser-base-count-as-stacks /
  // regression-top-fed-twin-stacks-count-one / fire-convergence-10-outletless-
  // supply-riser-counted-as-standpipe-stack / fire-convergence-10-pillar-
  // drops-reached-directly-counted-as-stacks) — a riser is decided by its OWN
  // hose outlets first: the outlets at its member nodes or reached from a
  // member over HYDRANT pipe (the whole drawn network, so a sub-list counts
  // the same), a hose outlet ending the walk, a plant stopping it and every
  // OTHER riser component a wall. A hydrant riser walks from every member (a
  // base-level box is still this stack's outlet); a sprinkler-only riser from
  // its members above its base (Round 54: a sprinkler riser teed only at its
  // base off a hydrant header is no stack).
  //  * no own outlet => no stack (a pump-room riser, a break-tank fill riser
  //    off the zone header carries no standpipe outlet);
  //  * a ONE-storey riser whose own outlets sit on ONE floor => a pillar /
  //    branch drop when a TALL stack of its fire system serves that storey
  //    (Round 60, replacing Round 59's fire-pipe-cycle test); with no such
  //    stack it is a standpipe of its own;
  //  * a one-storey riser with own outlets on BOTH floors => a stack, unless
  //    it lies on a RING (its two ends stay joined with its own risers
  //    removed — a ring leg down a car-park ramp) AND the fire source reaches
  //    it only through another riser spanning that storey (the Round-56 /
  //    57 reach test, a riser's BASE node never blocking);
  //  * a multi-storey riser with any own outlet => a stack, counted from
  //    the storey just below its lowest own outlet (below that it is a
  //    transfer main to a higher zone).
  final fullHydrantAdj = <String, List<String>>{};
  for (final e in net.edges) {
    if (e.service != ServiceType.fireHydrant) continue;
    (fullHydrantAdj[e.fromId] ??= []).add(e.toId);
    (fullHydrantAdj[e.toId] ??= []).add(e.fromId);
  }
  final membersOf = <String, Set<String>>{};
  for (final id in parent.keys) {
    (membersOf[find(id)] ??= <String>{}).add(id);
  }

  // Round 60 (fire-convergence-12-wall-hydrant-on-ring-makes-one-storey-
  // drops-standpipe-stacks) — the nodes on a CYCLE of the fire network with
  // every riser edge removed (the endpoints of its non-bridge edges): the
  // ring mains. A walk seeded from a hydrant riser's BASE member never steps
  // onto another ring node, so a wall hydrant elsewhere on the ring is never
  // this drop's own L0 outlet; a box hanging off the base node through
  // non-ring pipe still is (Round 58's base-level box rule).
  final cycleNodes = _fireRingNodes(net);
  final fullHydrantRiserNodes = <String>{
    for (final e in net.edges)
      if (e.service == ServiceType.fireHydrant && e.kind == EdgeKind.riser)
        ...[e.fromId, e.toId],
  };

  Set<int> outletFloorsOf(Set<String> members,
      {required bool hydrant, required int base}) {
    final ownFull = <String>{for (final id in members) findFull(id)};
    final floors = <int>{};
    void walk(Iterable<String> seeds, {required bool fromBase}) {
      final seen = <String>{...members};
      final queue = <String>[...seeds];
      for (var i = 0; i < queue.length; i++) {
        for (final o in fullHydrantAdj[queue[i]] ?? const <String>[]) {
          if (fromBase && cycleNodes.contains(o) && !members.contains(o)) {
            continue; // another ring node: the ring's own outlets
          }
          if (!seen.add(o)) continue;
          if (fullParent.containsKey(o) && !ownFull.contains(findFull(o))) {
            continue; // another riser: a wall
          }
          if (isHoseOutlet(o)) {
            floors.add(floorOf[o] ?? 0);
            continue; // an outlet ends the walk
          }
          if (nodeById[o]?.role == NodeRole.plant) continue;
          queue.add(o);
        }
      }
    }

    final upper = <String>[];
    final lower = <String>[];
    for (final id in members) {
      final f = floorOf[id] ?? 0;
      if (!hydrant && f <= base) continue;
      if (isHoseOutlet(id)) floors.add(f);
      (f <= base ? lower : upper).add(id);
    }
    walk(upper, fromBase: false);
    walk(lower, fromBase: true);
    return floors;
  }

  Set<int> ownOutletFloors(String root) {
    final members = membersOf[root]!;
    return outletFloorsOf(members,
        hydrant: members.any(hydrantRiserNodes.contains), base: lo[root]!);
  }

  // Round 60 (regression-tree-fed-pillar-drops-now-count-as-stacks /
  // regression-ring-fed-one-storey-twins-count-one) — the TALL stacks of the
  // whole drawn fire network: riser components with an own outlet that are
  // multi-storey or carry own outlets on >= 2 floors, each with the storey
  // span it serves (from the storey just below its lowest own outlet) and
  // its fire-system label (connectivity over fire pipe, never through a
  // storage tank — [isFireSystemBoundary]).
  final systemOf = _fireSystemLabels(net);
  // Round 61 (regression-fire-system-label-tank-member-order) — a riser
  // component's fire systems are the labels of its NON-tank members (a
  // storage tank bounds systems and carries no label of its own), so the
  // reading never depends on which member a Set happens to list first.
  Set<int> systemLabelsOf(Iterable<String> members) => {
        for (final id in members)
          if (systemOf[id] != null) systemOf[id]!,
      };
  final fullMembers = <String, Set<String>>{};
  for (final id in fullParent.keys) {
    (fullMembers[findFull(id)] ??= <String>{}).add(id);
  }
  final tall = <(String, int, int, Set<int>)>[]; // (root, from, to, systems)
  for (final r in fullMembers.keys) {
    final members = fullMembers[r]!;
    final floors = outletFloorsOf(members,
        hydrant: members.any(fullHydrantRiserNodes.contains),
        base: fullLo[r]!);
    if (floors.isEmpty) continue;
    if (fullHi[r]! - fullLo[r]! < 2 && floors.length < 2) continue;
    final from = math.max(fullLo[r]!, floors.reduce(math.min) - 1);
    tall.add((r, from, fullHi[r]!, systemLabelsOf(members)));
  }

  // A ONE-storey riser whose own outlets sit on ONE floor is a pillar /
  // branch drop when a TALL stack of its own fire system serves its storey
  // (it is that stack's distribution — pillar drops off a ring or off a
  // dead-end yard main alike); with no such stack it is a standpipe of its
  // own (one-storey twin stacks, tree- or ring-fed, count each).
  bool dropOfTallStack(String root) {
    final members = membersOf[root]!;
    final own = <String>{for (final id in members) findFull(id)};
    final a = lo[root]!;
    final sys = systemLabelsOf(members);
    for (final (r, from, to, s) in tall) {
      if (own.contains(r) || !s.any(sys.contains)) continue;
      if (from <= a && to >= a + 1) return true;
    }
    return false;
  }

  // Does the riser lie on a ring: its lowest and highest members stay joined
  // over fire pipe with its OWN riser edges removed?
  final riserEdgeIds = <String>{
    for (final e in net.edges)
      if (e.kind == EdgeKind.riser &&
          (e.service == ServiceType.fireHydrant ||
              e.service == ServiceType.fireSprinkler))
        e.id,
  };
  final fireEdgeAdj = <String, List<NetEdge>>{};
  for (final e in net.edges) {
    if (e.service != ServiceType.fireHydrant &&
        e.service != ServiceType.fireSprinkler) {
      continue;
    }
    (fireEdgeAdj[e.fromId] ??= []).add(e);
    (fireEdgeAdj[e.toId] ??= []).add(e);
  }
  bool onRing(String root) {
    final members = membersOf[root]!;
    final bottom = <String>{
      for (final id in members)
        if ((floorOf[id] ?? 0) == lo[root]) id,
    };
    final top = <String>{
      for (final id in members)
        if ((floorOf[id] ?? 0) == hi[root]) id,
    };
    bool ownRiser(NetEdge x) =>
        riserEdgeIds.contains(x.id) &&
        members.contains(x.fromId) &&
        members.contains(x.toId);
    final seen = <String>{...bottom};
    final queue = [...bottom];
    for (var i = 0; i < queue.length; i++) {
      for (final x in fireEdgeAdj[queue[i]] ?? const <NetEdge>[]) {
        if (ownRiser(x)) continue;
        final o = x.fromId == queue[i] ? x.toId : x.fromId;
        if (top.contains(o)) return true;
        if (seen.add(o)) queue.add(o);
      }
    }
    return false;
  }

  bool isBranchDrop(String root) {
    final a = lo[root]!;
    if (hi[root]! != a + 1 || sources.isEmpty) return false;
    final members = membersOf[root]!;
    final own = <String>{for (final id in members) findFull(id)};
    // Round 57 — the reach test: a tee off another riser's BASE node (where
    // its supply main lands) never blocks; only a riser's INTERIOR / TOP
    // nodes are its distribution. Nodes of every OTHER riser component
    // spanning the storey (a, a+1).
    bool blocks(String id) {
      if (!fullParent.containsKey(id)) return false;
      final r = findFull(id);
      return !own.contains(r) &&
          fullLo[r]! <= a &&
          fullHi[r]! >= a + 1 &&
          (floorOf[id] ?? 0) > fullLo[r]!;
    }

    bool reaches({required bool blocked}) {
      final seen = <String>{...sources};
      final queue = [...sources];
      for (var i = 0; i < queue.length; i++) {
        final cur = queue[i];
        if (members.contains(cur)) return true;
        if (blocked && blocks(cur)) continue;
        for (final o in fireAdj[cur] ?? const <String>[]) {
          if (seen.add(o)) queue.add(o);
        }
      }
      return false;
    }

    return onRing(root) && reaches(blocked: false) && !reaches(blocked: true);
  }

  final isStack = <String>{};
  // Round 58 — the storey a stack starts serving: the one just below its
  // LOWEST own outlet (never below its base). Beneath that the riser is a
  // supply / transfer main to a higher zone (an upper-zone riser rising from
  // the ground pump room past the lower zone), not a standpipe in parallel
  // with the lower stack.
  final serveFrom = <String, int>{};
  for (final root in membersOf.keys) {
    final floors = ownOutletFloors(root);
    if (floors.isEmpty) continue; // no own outlet: no stack
    if (hi[root]! == lo[root]! + 1 &&
        floors.length < 2 &&
        dropOfTallStack(root)) {
      continue; // a one-storey drop of a taller stack to outlets on one floor
    }
    isStack.add(root);
    final minOut = floors.reduce(math.min);
    serveFrom[root] = math.max(lo[root]!, minOut - 1);
  }
  isStack.removeWhere((r) => isInletRiser(r) || isBranchDrop(r));
  lo.removeWhere((r, _) => !isStack.contains(r));
  if (lo.isEmpty) return 0;
  // cover[f] = number of stacks spanning the storey interval (f, f+1).
  final cover = <int, int>{};
  var best = 0;
  for (final root in lo.keys) {
    final a = serveFrom[root] ?? lo[root]!;
    final b = hi[root]!;
    if (b <= a) {
      // A riser drawn between two nodes on one floor still is a stack.
      best = math.max(best, 1);
      continue;
    }
    for (var f = a; f < b; f++) {
      final c = (cover[f] ?? 0) + 1;
      cover[f] = c;
      if (c > best) best = c;
    }
  }
  return best;
}

/// Round 60 — the nodes on a cycle of the fire (sprinkler + hydrant) network
/// with every RISER edge removed: the endpoints of its non-bridge edges
/// (Tarjan bridge-finding, iterative). Pure.
Set<String> _fireRingNodes(Network net) {
  final adj = <String, List<NetEdge>>{};
  for (final e in net.edges) {
    if (e.service != ServiceType.fireHydrant &&
        e.service != ServiceType.fireSprinkler) {
      continue;
    }
    if (e.kind == EdgeKind.riser || e.fromId == e.toId) continue;
    (adj[e.fromId] ??= []).add(e);
    (adj[e.toId] ??= []).add(e);
  }
  final disc = <String, int>{};
  final low = <String, int>{};
  final bridges = <String>{};
  var t = 0;
  final starts = adj.keys.toList()..sort();
  for (final s in starts) {
    if (disc.containsKey(s)) continue;
    // Stack frames: (node, parent edge id, next adjacency index).
    final stack = <(String, String?, int)>[(s, null, 0)];
    disc[s] = low[s] = t++;
    while (stack.isNotEmpty) {
      final (u, pe, i) = stack.last;
      final list = adj[u]!;
      if (i < list.length) {
        stack[stack.length - 1] = (u, pe, i + 1);
        final e = list[i];
        if (e.id == pe) continue;
        final v = e.fromId == u ? e.toId : e.fromId;
        if (!disc.containsKey(v)) {
          disc[v] = low[v] = t++;
          stack.add((v, e.id, 0));
        } else {
          low[u] = math.min(low[u]!, disc[v]!);
        }
      } else {
        stack.removeLast();
        if (stack.isNotEmpty) {
          final p = stack.last.$1;
          low[p] = math.min(low[p]!, low[u]!);
          if (low[u]! > disc[p]!) bridges.add(pe!);
        }
      }
    }
  }
  return <String>{
    for (final list in adj.values)
      for (final e in list)
        if (!bridges.contains(e.id)) ...[e.fromId, e.toId],
  };
}

/// Round 60 — a fire-system label per fire node: connectivity over sprinkler
/// + hydrant pipe that never passes THROUGH a storage tank
/// ([isFireSystemBoundary]). Round 61 — a tank carries NO label (it used to
/// take the label of whichever system dequeued it first, so a stack touching
/// the tank inherited another system's label by edge order). Pure +
/// deterministic.
Map<String, int> _fireSystemLabels(Network net) {
  final byId = {for (final n in net.nodes) n.id: n};
  final adj = <String, List<String>>{};
  for (final e in net.edges) {
    if (e.service != ServiceType.fireHydrant &&
        e.service != ServiceType.fireSprinkler) {
      continue;
    }
    (adj[e.fromId] ??= []).add(e.toId);
    (adj[e.toId] ??= []).add(e.fromId);
  }
  final label = <String, int>{};
  var next = 0;
  final ids = adj.keys.toList()..sort();
  for (final s in ids) {
    if (label.containsKey(s) || isFireSystemBoundary(byId[s])) continue;
    final l = next++;
    label[s] = l;
    final queue = [s];
    for (var i = 0; i < queue.length; i++) {
      final cur = queue[i];
      for (final o in adj[cur] ?? const <String>[]) {
        if (label.containsKey(o) || isFireSystemBoundary(byId[o])) continue;
        label[o] = l;
        queue.add(o);
      }
    }
  }
  return label;
}

// ── Static lift from the building geometry ───────────────────────────────────

/// The static lift [designStandpipe] expects as its `buildingHeight`: the
/// elevation from the PUMP DATUM to the TOPMOST HOSE OUTLET (§10 — vertical
/// length from true floor elevations, never the PDF).
///
///   lift = elevation(top floor) − elevation(lowest floor) + [hoseOutletHeight]
///
/// The fire pump + ground reservoir sit on the LOWEST level (a basement when
/// there is one), so the datum is floor 0's surface — the delta is the same in
/// any datum frame (`groundIndex` only offsets every elevation equally). The
/// topmost outlet is a landing valve on the TOP floor, [hoseOutletHeight] above
/// that floor's surface — NOT the roof slab: passing `building.totalHeight`
/// (the roof) overstated the lift by `topFloorHeight − hoseOutletHeight`
/// (2.8 m on a 4 m top floor).
///
/// An empty building yields 0 (nothing to lift to).
Length standpipeStaticLift(
  BuildingLevels building, {
  Length hoseOutletHeight = const Length(kHoseOutletHeightM),
}) {
  if (building.floors.isEmpty) return const Length(0);
  final top = building.floors.length - 1;
  return Length(building.elevationOf(top).meters -
      building.elevationOf(0).meters +
      hoseOutletHeight.meters);
}

// ── Design result ─────────────────────────────────────────────────────────────

/// All quantities produced by [designStandpipe] for one fire standpipe system.
///
/// Every field is a typed SI quantity from `units.dart`.
class FireStandpipeDesign {
  /// Standpipe class governing the residual-pressure requirement.
  final StandpipeClass standpipeClass;

  /// Total flow the fire pump must deliver to the standpipe system.
  final FlowRate requiredFlow;

  /// Minimum residual pressure required at the topmost hose outlet
  /// (SNI 03-1745-2000: 6.9 bar Class I/III, 4.5 bar Class II).
  final Pressure topResidualPressure;

  /// Minimum riser diameter for the system (100 mm for Class I/III).
  final Diameter minRiserDiameter;

  /// Total pump head: static lift + friction allowance + residual-pressure head.
  final Head pumpHead;

  /// Useful (hydraulic) power delivered to the fluid: P = ρ · g · Q · H.
  final Power pumpHydraulicPower;

  /// Shaft (brake) power the pump motor must supply: P_shaft = P_hyd / η.
  final Power pumpShaftPower;

  const FireStandpipeDesign({
    required this.standpipeClass,
    required this.requiredFlow,
    required this.topResidualPressure,
    required this.minRiserDiameter,
    required this.pumpHead,
    required this.pumpHydraulicPower,
    required this.pumpShaftPower,
  });
}

// ── Public sizing API ─────────────────────────────────────────────────────────

/// Size a fire standpipe + pump system for a building with [risers] risers and
/// a roof / topmost-outlet height of [buildingHeight].
///
/// ### Head budget (SNI 03-6570-2001 — verify against a full network analysis)
///
///   pumpHead = buildingHeight       (static lift to the topmost outlet)
///            + frictionAllowance    (allowance for pipe friction losses)
///            + headFromPressure(topResidual)   (residual pressure as head)
///
/// ### Parameters
///
/// * [risers] — number of active standpipe risers (≥ 1).
/// * [buildingHeight] — elevation from pump datum to the topmost hose outlet.
/// * [standpipeClass] — system class (default [StandpipeClass.classI]); fixes
///   the topmost-outlet residual pressure per SNI 03-1745-2000.
/// * [frictionAllowance] — conservative fixed head allowance for pipe friction
///   losses in the standpipe mains (default 15 m).
///   // VERIFY against a full Hazen–Williams network calculation per
///   SNI 03-1745-2000 once pipe diameters and routes are fixed.
/// * [pumpEfficiency] — overall pump + motor efficiency η (0 < η ≤ 1, default
///   0.70). // VERIFY against the selected pump's certified performance curve
///   per SNI 03-6570-2001.
///
/// ### Returns
///
/// A [FireStandpipeDesign] with all quantities computed using the hydraulic
/// kernel from `hydraulics.dart` (ρ = 1000 kg/m³, g = 9.81 m/s²).
FireStandpipeDesign designStandpipe({
  required int risers,
  required Length buildingHeight,
  StandpipeClass standpipeClass = StandpipeClass.classI,
  Head frictionAllowance = const Head(15),
  double pumpEfficiency = 0.70,
  Head? indexPathFriction,
}) {
  assert(risers >= 1, 'risers must be ≥ 1');
  // Round 28 (fire-3-pump-head-ignores-sized-fire-pipe-friction) — the
  // friction of the SIZED index path (pump -> topmost outlet, at the sized
  // flows; `fireIndexPathFrictionM`) replaces the fixed allowance when it is
  // larger; the allowance stays the floor (more information never lowers the
  // rated head). Null ⇒ byte-identical.
  if (indexPathFriction != null &&
      indexPathFriction.meters > frictionAllowance.meters) {
    frictionAllowance = indexPathFriction;
  }
  assert(
    pumpEfficiency > 0 && pumpEfficiency <= 1,
    'pumpEfficiency must be in (0, 1]',
  );

  // Required system flow demand (SNI 03-1745-2000).
  final requiredFlow = standpipeFlow(risers, standpipeClass: standpipeClass);

  // Minimum residual pressure at the topmost hose outlet for this class.
  final topResidual = Pressure.kiloPascals(residualPressureKpa(standpipeClass));

  // Convert residual pressure to an equivalent head of water (h = P / ρg).
  final residualHead = headFromPressure(topResidual);

  // Total pump head = static lift + friction allowance + residual head.
  final totalHeadMeters =
      buildingHeight.meters + frictionAllowance.meters + residualHead.meters;
  final pumpHead = Head(totalHeadMeters);

  // Pump power calculations using the hydraulic kernel.
  final pumpHydraulicPower = hydraulicPower(
    flow: requiredFlow,
    head: pumpHead,
  );
  final pumpShaftPower = shaftPower(
    flow: requiredFlow,
    head: pumpHead,
    efficiency: pumpEfficiency,
  );

  return FireStandpipeDesign(
    standpipeClass: standpipeClass,
    requiredFlow: requiredFlow,
    topResidualPressure: topResidual,
    minRiserDiameter: Diameter.mm(standpipeClass == StandpipeClass.classII
        ? kMinClassIIRiserDiameterMm
        : kMinRiserDiameterMm),
    pumpHead: pumpHead,
    pumpHydraulicPower: pumpHydraulicPower,
    pumpShaftPower: pumpShaftPower,
  );
}

/// Round 12 (report-recompute-verify-items-incomplete) — the unverified
/// constants behind the PRINTED standpipe line (flow / pump head / shaft
/// power), so the calc report's Unverified section lists what the figure
/// rests on (golden rule 6). Defaults of [designStandpipe].
///
/// Round 21 — split: [firePumpBasisVerifyChecklist] holds the two items a
/// SPRINKLER-ONLY fire pump also uses (the 15 m friction allowance and η);
/// the 690 kPa Class I residual applies only when a standpipe is drawn.
const List<StandardValue<Object?>> standpipeVerifyChecklist = [
  ...firePumpBasisVerifyChecklist,
  StandardValue<Object?>(kResidualPressureClassIKpa,
      unit: 'kPa',
      citation: 'SNI 03-1745-2000 — Class I topmost-outlet residual',
      note: '690 kPa (100 psi) residual at the topmost Class I hose outlet; '
          'secondary source pending the official clause.'),
];

/// The fire-system basis items every drawn fire system uses (the standpipe
/// AND the sprinkler-only rated point): the 15 m friction allowance, the
/// representative η and (Round 21) the 6 m/s fire-pipe velocity cap. See
/// [standpipeVerifyChecklist].
const List<StandardValue<Object?>> firePumpBasisVerifyChecklist = [
  StandardValue<Object?>(kMaxFireVelocityMps,
      unit: 'm/s',
      citation: 'Fire-pipe velocity cap (EN 12845 valves 6 m/s; NFPA 13 none)',
      status: VerificationStatus.notAnSniClause,
      note: 'Sprinkler + hydrant pipes are sized to 6 m/s, not the 2.0 m/s '
          'domestic SNI 03-7065 limit (a fire system runs only in a fire); '
          'the code-minimum diameters still apply. General fire-engineering '
          'practice — confirm vs SNI 03-3989 / 03-1745.'),
  StandardValue<Object?>(15.0,
      unit: 'm',
      citation: 'Standpipe friction allowance (designStandpipe default)',
      status: VerificationStatus.notAnSniClause,
      note: 'Fixed 15 m head allowance for standpipe-main friction — general '
          'practice pending a full Hazen–Williams route calculation '
          '(SNI 03-1745-2000).'),
  StandardValue<Object?>(0.70,
      unit: '-',
      citation: 'Fire-pump overall efficiency η (designStandpipe default)',
      status: VerificationStatus.notAnSniClause,
      note: 'Representative pump + motor efficiency 0.70 — verify against the '
          "selected pump's certified curve (SNI 03-6570-2001)."),
];
