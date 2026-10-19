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
/// degree-2 pass-through nodes — back to an ejector pump / booster or a pit
/// (the other legs of a duplex discharge header).
bool _legLeadsToEjector(Network net, NetEdge edge, String fromId) {
  var here = fromId;
  var e = edge;
  final seen = <String>{fromId};
  while (true) {
    final next = e.fromId == here ? e.toId : e.fromId;
    if (!seen.add(next)) return false;
    final nn = net.nodeById(next);
    if (nn == null) return false;
    final c = nn.component;
    if (c == NodeComponent.pump ||
        c == NodeComponent.boosterSet ||
        c == NodeComponent.groundTank) {
      return true;
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
  bool isPit(String id) =>
      net.nodeById(id)?.component == NodeComponent.groundTank;
  final base = elevOf(pump, incident.first);

  // Walk each discharge edge (not into the pit) through pass-through
  // drainage nodes, inline valves and a duplex header: the force main.
  var top = base;
  var friction = 0.0;
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
          if (!_legLeadsToEjector(net, e, next)) e,
      ];
      if (forward.length != 1) break;
      here = next;
      edge = forward.single;
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
