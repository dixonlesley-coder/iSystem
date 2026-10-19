/// Round 30 (mech-sim-4-ejector-pump-no-duty-no-schedule) — the duty point of
/// a drawn SEWAGE EJECTOR: a pump / booster set on the DRAINAGE service (an
/// ejector pit pumping a basement up to the building drain).
///
/// Pure ORCHESTRATION — no new hydraulics:
///   * flow  = the pit's accumulated DFU (the largest DFU on the pump's
///     drainage edges, as the sizer recorded it) through the engine's own
///     flush-tank demand curve (`probableFlowForFixtureUnits`). Converting
///     drainage fixture units on the supply demand curve is a representative
///     first-pass estimate, `// VERIFY` notAnSniClause (manufacturer pit
///     sizing / a measured inflow governs);
///   * head  = static lift from the pump to the highest point of its
///     discharge (force main) — the chain of drainage edges leaving the pump
///     away from the pit through bare pass-through nodes, ending where it
///     joins the gravity sewer — plus Hazen–Williams friction over that chain
///     at the sized bores (`// VERIFY` C 140 for an unspecified product).
///
/// Zero Flutter imports.
library;

import 'dart:math' as math;

import '../geometry/building.dart';
import '../geometry/scale_calibration.dart';
import '../hydraulics.dart';
import '../network/network.dart';
import '../standards/pipe_products.dart';
import '../standards/sni.dart';
import '../units.dart';
import 'network_sizing.dart';
import 'pump.dart';

/// Default Hazen–Williams C of an ejector force main with no product set.
// VERIFY: representative PVC / HDPE force-main value, not an SNI clause.
const double kEjectorForceMainHwC = 140;

/// Inline devices a force main passes straight through (Round 31): a
/// discharge check valve, an isolating gate / balancing valve, a strainer and
/// a riser marker never end the discharge.
const Set<NodeComponent> kEjectorForceMainInlineComponents = {
  NodeComponent.checkValve,
  NodeComponent.gateValve,
  NodeComponent.balancingValve,
  NodeComponent.strainer,
  NodeComponent.riser,
};

/// Whether the drainage leg [edge] leaving [fromId] leads — through
/// degree-2 pass-through nodes — back to another drawn ejector pump /
/// booster ([ejectorIds], see [drawnEjectorPumpIds]) or to the start pump's
/// own pit ([pitIds]) — the other legs of a duplex discharge header.
///
/// Round 32 (regression-ejector-force-main-walks-up-soil-stack-when-sewer-
/// ends-in-ground-tank): a ground tank is also how a gravity OUTFALL (STP /
/// septic / holding tank, the drainage sink plant) is drawn, so a ground
/// tank only counts as "the ejector side" when it is the pit the start pump
/// draws from. Any other tank is the building sewer's outfall, and the leg
/// to it is the force main's onward path, never a header leg.
bool _legLeadsToEjector(Network net, NetEdge edge, String fromId,
    {required Set<String> ejectorIds, required Set<String> pitIds}) {
  var here = fromId;
  var e = edge;
  final seen = <String>{fromId};
  while (true) {
    final next = e.fromId == here ? e.toId : e.fromId;
    if (!seen.add(next)) return false;
    final nn = net.nodeById(next);
    if (nn == null) return false;
    final c = nn.component;
    if (ejectorIds.contains(next) || pitIds.contains(next)) return true;
    if (c == NodeComponent.pump ||
        c == NodeComponent.boosterSet ||
        c == NodeComponent.groundTank) {
      return false;
    }
    if (nn.role != NodeRole.main ||
        (c != null && !kEjectorForceMainInlineComponents.contains(c))) {
      return false;
    }
    final onward = [
      for (final x in net.edgesAt(next))
        if (x.service == ServiceType.drainage && x.id != e.id) x,
    ];
    if (onward.length != 1) return false;
    here = next;
    e = onward.single;
  }
}

/// The drawn ejector pumps of [net]: a pump / booster set carrying a DRAINAGE
/// edge and no supply / fire edge. Sorted by id.
List<String> drawnEjectorPumpIds(Network net) {
  final ids = <String>[];
  for (final n in net.nodes) {
    if (n.component != NodeComponent.pump &&
        n.component != NodeComponent.boosterSet) {
      continue;
    }
    final services = {for (final e in net.edgesAt(n.id)) e.service};
    if (!services.contains(ServiceType.drainage)) continue;
    if (services.any((s) => s != ServiceType.drainage &&
        s != ServiceType.vent)) {
      continue;
    }
    ids.add(n.id);
  }
  return ids..sort();
}

/// The FORCE MAIN of the ejector [pumpId]: each drainage edge leaving the
/// pump away from its pit, walked through bare pass-through nodes, inline
/// devices ([kEjectorForceMainInlineComponents]) and a duplex HEADER (a
/// junction whose other legs lead back to another drawn ejector / the pump's
/// own pit) along its single onward leg, in walk order — each step the edge
/// and the node it reaches. The walk ends where gravity / fixture drainage
/// joins (more than one non-ejector onward leg), at a fixture / plant, or at
/// a dead end; that last edge is included. Pure; shared by
/// [ejectorDutyPoint] (lift + friction) and the sizer's solids-handling
/// bore floor ([kEjectorForceMainMinBoreMm]).
List<({NetEdge edge, String to})> ejectorForceMainSteps(
    Network net, String pumpId) {
  final incident = [
    for (final e in net.edgesAt(pumpId))
      if (e.service == ServiceType.drainage) e,
  ];
  bool isPit(String id) =>
      net.nodeById(id)?.component == NodeComponent.groundTank;
  final ejectorIds = drawnEjectorPumpIds(net).toSet();
  final pitIds = <String>{
    for (final e in incident)
      if (isPit(e.fromId == pumpId ? e.toId : e.fromId))
        e.fromId == pumpId ? e.toId : e.fromId,
  };
  final steps = <({NetEdge edge, String to})>[];
  for (final start in incident) {
    final far = start.fromId == pumpId ? start.toId : start.fromId;
    if (isPit(far)) continue;
    var edge = start;
    var here = pumpId;
    final seen = <String>{pumpId};
    while (true) {
      final next = edge.fromId == here ? edge.toId : edge.fromId;
      final nn = net.nodeById(next);
      if (nn == null || !seen.add(next)) break;
      steps.add((edge: edge, to: next));
      final onward = [
        for (final e in net.edgesAt(next))
          if (e.service == ServiceType.drainage && e.id != edge.id) e,
      ];
      // Round 31 (regression-ejector-force-main-walk-stops-at-valve-or-
      // header): the force main continues through an INLINE pass-through
      // device (discharge check valve, isolating gate valve, strainer, riser
      // marker) and through a duplex HEADER — a bare junction whose other
      // legs lead back to another ejector / the pit — along its single
      // onward leg. It ends only where gravity / fixture drainage joins
      // (more than one non-ejector onward leg), at a fixture / plant, or at
      // a dead end.
      final passThrough = nn.role == NodeRole.main &&
          (nn.component == null ||
              kEjectorForceMainInlineComponents.contains(nn.component));
      if (!passThrough) break;
      final forward = [
        for (final e in onward)
          if (!_legLeadsToEjector(net, e, next,
              ejectorIds: ejectorIds, pitIds: pitIds))
            e,
      ];
      if (forward.length != 1) break;
      here = next;
      edge = forward.single;
    }
  }
  return steps;
}

/// Minimum bore of a sewage-ejector force main (Round 32, binding-2): a
/// sewage pump passes 2 in (≈ 50 mm) solids, so its discharge is never below
/// DN50 whatever the DFU table gives a small pit.
// VERIFY: notAnSniClause — IPC 712.4.1 / UPC 710.4 practice (sewage pumps
// pass 2 in solids; discharge ≥ 2 in), not an SNI clause.
const double kEjectorForceMainMinBoreMm = 50.0;

/// One leg of a duplex ejector set (Round 32, binding-2): the pump, its pit
/// edge, and its discharge edges in order from the pump to the common header
/// with each edge's upstream (pump-side) node.
class DuplexEjectorLeg {
  final String pumpId;
  final String pitEdgeId;
  final List<String> dischargeEdgeIds;
  final List<String> dischargeFromIds;
  const DuplexEjectorLeg({
    required this.pumpId,
    required this.pitEdgeId,
    required this.dischargeEdgeIds,
    required this.dischargeFromIds,
  });

  /// Every edge of the leg (pit edge first).
  List<String> get edgeIds => [pitEdgeId, ...dischargeEdgeIds];
}

/// A duplex ('pompa sewage duplex') ejector set: two or more drawn ejectors
/// drawing from ONE pit and discharging to ONE header. Either pump runs alone
/// at full duty (duty / standby, alternating), so the set is never a gravity
/// ring.
class DuplexEjectorSet {
  final String pitId;
  final String headerId;

  /// The duty leg — the LOWEST pump id. The legs are identical by
  /// construction (each carries the full set flow), so no physical criterion
  /// distinguishes them: the id tie-break is the honest, order-independent
  /// choice (Round 32 dropped the 'largest incident bore' criterion, which
  /// only echoed which leg the sizer happened to put in its tree).
  final DuplexEjectorLeg duty;
  final List<DuplexEjectorLeg> standby;
  const DuplexEjectorSet({
    required this.pitId,
    required this.headerId,
    required this.duty,
    required this.standby,
  });
}

/// The duplex ejector sets of [net] (Round 32, binding-2), sorted by pit then
/// header id. A leg is a drawn ejector ([drawnEjectorPumpIds]) with exactly
/// two drainage edges — one straight to a ground-tank pit, one discharge —
/// whose discharge runs through degree-2 pass-through nodes / inline devices
/// to its first other node (the header). Two or more legs sharing a pit AND a
/// header form a set.
List<DuplexEjectorSet> duplexEjectorSets(Network net) {
  final byKey = <String, List<({String pit, String header, DuplexEjectorLeg leg})>>{};
  for (final pumpId in drawnEjectorPumpIds(net)) {
    final drain = [
      for (final e in net.edgesAt(pumpId))
        if (e.service == ServiceType.drainage) e,
    ];
    if (drain.length != 2) continue;
    String other(NetEdge e, String id) => e.fromId == id ? e.toId : e.fromId;
    final pitEdges = [
      for (final e in drain)
        if (net.nodeById(other(e, pumpId))?.component ==
            NodeComponent.groundTank)
          e,
    ];
    if (pitEdges.length != 1) continue;
    final pitEdge = pitEdges.single;
    final pit = other(pitEdge, pumpId);
    var edge = drain.firstWhere((e) => e.id != pitEdge.id);
    var here = pumpId;
    final ids = <String>[];
    final froms = <String>[];
    final seen = <String>{pumpId};
    String? header;
    while (true) {
      final next = other(edge, here);
      if (!seen.add(next)) break;
      ids.add(edge.id);
      froms.add(here);
      final nn = net.nodeById(next);
      if (nn == null) break;
      final onward = [
        for (final e in net.edgesAt(next))
          if (e.service == ServiceType.drainage && e.id != edge.id) e,
      ];
      final passThrough = nn.role == NodeRole.main &&
          (nn.component == null ||
              kEjectorForceMainInlineComponents.contains(nn.component));
      if (passThrough && onward.length == 1) {
        here = next;
        edge = onward.single;
        continue;
      }
      header = next;
      break;
    }
    if (header == null || header == pit) continue;
    byKey.putIfAbsent('$pit\u0000$header', () => []).add((
      pit: pit,
      header: header,
      leg: DuplexEjectorLeg(
        pumpId: pumpId,
        pitEdgeId: pitEdge.id,
        dischargeEdgeIds: ids,
        dischargeFromIds: froms,
      ),
    ));
  }
  final out = <DuplexEjectorSet>[];
  final keys = byKey.keys.toList()..sort();
  for (final k in keys) {
    final g = byKey[k]!;
    if (g.length < 2) continue;
    g.sort((a, b) => a.leg.pumpId.compareTo(b.leg.pumpId));
    out.add(DuplexEjectorSet(
      pitId: g.first.pit,
      headerId: g.first.header,
      duty: g.first.leg,
      standby: [for (final x in g.skip(1)) x.leg],
    ));
  }
  return out;
}

/// The ejector duty point of [pumpId] (see the library doc), or null when it
/// carries no recorded DFU.
({FlowRate flow, Head head, Head staticLift})? ejectorDutyPoint({
  required Network net,
  required String pumpId,
  required Map<String, EdgeSizing> sizing,
  required Map<String, double> edgeFixtureUnits,
  required BuildingLevels building,
  MountingHeights mounting = const MountingHeights(),
  Map<String, ScaleCalibration> calibrationBySheet = const {},
  SniProfile profile = const SniProfile(),
}) {
  final pump = net.nodeById(pumpId);
  if (pump == null || building.levelCount == 0) return null;
  final incident = [
    for (final e in net.edgesAt(pumpId))
      if (e.service == ServiceType.drainage) e,
  ];
  if (incident.isEmpty) return null;
  var dfu = 0.0;
  for (final e in incident) {
    dfu = math.max(dfu, edgeFixtureUnits[e.id] ?? 0);
  }
  if (dfu <= 0) return null;
  final flow = profile.probableFlowForFixtureUnits(dfu);

  double elevOf(NetNode n, NetEdge via) =>
      riserEndElevation(via, n, building, mounting).meters;
  final base = elevOf(pump, incident.first);

  // The force main: every discharge edge (not into the pit) walked through
  // pass-through drainage nodes, inline valves and a duplex header.
  var top = base;
  var friction = 0.0;
  for (final step in ejectorForceMainSteps(net, pumpId)) {
    final edge = step.edge;
    final nn = net.nodeById(step.to)!;
    top = math.max(top, elevOf(nn, edge));
    final sz = sizing[edge.id];
    if (sz != null && sz.diameter.meters > 0) {
      final len = edgeLength(edge, net,
          calibrationBySheet: calibrationBySheet,
          building: building,
          mounting: mounting);
      if (len.meters > 0) {
        friction += headLossHazenWilliams(
          flow: flow,
          length: len,
          diameter: sz.diameter,
          hazenWilliamsC: edge.pipeProduct != null
              ? hazenWilliamsCFor(edge.pipeProduct!)
              : kEjectorForceMainHwC,
        ).meters;
      }
    }
  }
  final lift = math.max(0.0, top - base);
  return (
    flow: flow,
    head: Head(lift + friction),
    staticLift: Head(lift),
  );
}

/// [ejectorDutyPoint] sized through [sizePump] (null when no duty point).
PumpDuty? ejectorPumpDuty({
  required Network net,
  required String pumpId,
  required Map<String, EdgeSizing> sizing,
  required Map<String, double> edgeFixtureUnits,
  required BuildingLevels building,
  MountingHeights mounting = const MountingHeights(),
  Map<String, ScaleCalibration> calibrationBySheet = const {},
}) {
  final p = ejectorDutyPoint(
    net: net,
    pumpId: pumpId,
    sizing: sizing,
    edgeFixtureUnits: edgeFixtureUnits,
    building: building,
    mounting: mounting,
    calibrationBySheet: calibrationBySheet,
  );
  if (p == null || p.head.meters <= 0) return null;
  return sizePump(flow: p.flow, head: p.head);
}
