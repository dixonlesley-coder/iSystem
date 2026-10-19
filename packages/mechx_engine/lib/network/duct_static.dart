/// Fan total-static-pressure solve for a supply/return duct tree — the air-path
/// analogue of `pressure_solve.dart`. Walks the [service] subgraph from the fan
/// (BFS tree), summing Darcy air-friction (Pa) over each edge's run length, and
/// returns the worst (longest-friction) path: the index run that sets the fan's
/// total static pressure.
///
/// Static at a node = Σ over the path edges of
///   ductFrictionPaPerMetre(flow, diameter) · length · [fittingFactor].
/// The fan total static = max node static + [terminalLoss] (the diffuser/grille
/// drop at the index terminal).
///
/// PER-EDGE MATERIAL — each edge's Darcy air friction uses the wall roughness ε
/// of its [NetEdge.ductProduct] ([ductRoughnessFor]); an edge with no product
/// passes `null`, keeping `ductFrictionPaPerMetre`'s galvanised-steel default,
/// so the default path is byte-identical to today. A smoother product (PU)
/// lowers that edge's friction.
///
/// Shares the tree / missing-data semantics of the pressure solve: unsized or
/// unflowed edges add zero friction. Pure Dart, zero Flutter imports.
library;

import '../geometry/building.dart';
import '../geometry/scale_calibration.dart';
import '../sizing/duct_sizing.dart';
import '../sizing/network_sizing.dart';
import '../standards/duct_products.dart';
import '../units.dart';
import 'network.dart';
import 'oriented_paths.dart';

/// Result of [solveDuctStatic]: the fan total static pressure and the index
/// (critical, longest-friction) terminal that sets it.
class DuctStaticSolution {
  /// Total static pressure the fan must develop (index-run friction + fittings
  /// + terminal loss).
  final Pressure totalStaticPressure;

  /// Id of the index (worst-served) node.
  final String criticalNodeId;

  const DuctStaticSolution({
    required this.totalStaticPressure,
    required this.criticalNodeId,
  });
}

/// Solve the fan total static for the [service] (air) duct tree fed from
/// [fanNodeId].
DuctStaticSolution solveDuctStatic({
  required Network net,
  required ServiceType service,
  required String fanNodeId,
  required Map<String, FlowRate> edgeFlows,
  required Map<String, EdgeSizing> sizing,
  required Map<String, ScaleCalibration> calibrationBySheet,
  required BuildingLevels building,
  Pressure terminalLoss = const Pressure(30),
  double fittingFactor = 1.3,
  MountingHeights mounting = const MountingHeights(),
}) {
  // Adjacency over THIS service only.
  final adjacency = <String, List<({NetEdge edge, String other})>>{};
  for (final e in net.edges) {
    if (e.service != service) continue;
    (adjacency[e.fromId] ??= <({NetEdge edge, String other})>[])
        .add((edge: e, other: e.toId));
    (adjacency[e.toId] ??= <({NetEdge edge, String other})>[])
        .add((edge: e, other: e.fromId));
  }

  // Static (Pa) along the governing path from the fan, each duct walked in
  // its sized flow direction (mech-props-3 — see [orientedPathCost]).
  double edgePaArriving(NetEdge edge, String arriving) {
    var edgePa = 0.0;
    final edgeSizing = sizing[edge.id];
    if (edgeSizing == null) return 0.0;
    final flow = edgeFlows[edge.id] ?? const FlowRate(0);
    final length = edgeLength(
      edge,
      net,
      calibrationBySheet: calibrationBySheet,
      building: building,
      mounting: mounting,
    );
    edgePa = ductFrictionPaPerMetre(
          flow,
          edgeSizing.diameter,
          // Per-segment material → wall roughness ε. The product defaults by
          // service (PU for AC supply/return, BJLS for exhaust) when unset.
          roughness: ductRoughnessFor(effectiveDuctProductFor(edge)),
        ) *
        length.meters *
        fittingFactor;
    // Inline air restrictor (damper / VAV) we're arriving at: add its static
    // loss C·ρv²/2 (velocity from the feeding duct), so it propagates to
    // every downstream node — the air-path analogue of the valve minor
    // loss. C = 0 (no component / not a restrictor) ⇒ no change.
    final c = net.nodeById(arriving)?.component?.airLossC ?? 0;
    if (c > 0) {
      final w = edgeSizing.width;
      final h = edgeSizing.height;
      if (w != null && h != null && w.meters > 0 && h.meters > 0) {
        // Rectangular duct: the restrictor's velocity pressure uses the
        // TRUE section velocity Q/(W·H). The Huebscher equivalent diameter
        // in `edgeSizing.diameter` is an equal-FRICTION equivalent whose
        // circle is smaller than W·H, so it overstated v (~+18 % ρv²/2).
        edgePa += c *
            airVelocityPressurePa(
                Velocity(flow.cubicMetersPerSecond / (w.meters * h.meters)));
      } else {
        edgePa += ductFittingLossPa(
          c: c,
          flow: flow,
          diameter: edgeSizing.diameter,
        );
      }
    }
    return edgePa;
  }

  // Round 27 (hvac-4-1) — an air unit's OUTDOOR-AIR INTAKE (a duct whose
  // sized flow ARRIVES at the fan: the Round-16 bare intake leaf, through
  // any inline damper) is in SERIES with the supply index run through the
  // fan: the fan pulls the air through the intake and pushes it through the
  // supply. It used to be costed as one more outward branch, so the fan
  // static took max(intake, supply index) instead of their sum (a long
  // roof-louvre intake behind a short supply index run lost its whole
  // friction from the motor selection). Walk the intake AGAINST the flow from
  // the fan, take its worst path, and cost the supply on the rest.
  final intakeEdgeIds = <String>{};
  var intakePa = 0.0;
  if (!service.isExtractAir) {
    final intakeCost = <String, double>{fanNodeId: 0.0};
    final q = [fanNodeId];
    for (var i = 0; i < q.length; i++) {
      final n = q[i];
      for (final link
          in adjacency[n] ?? const <({NetEdge edge, String other})>[]) {
        if (sizing[link.edge.id]?.flowFromId != link.other) continue;
        if (intakeCost.containsKey(link.other)) continue;
        intakeEdgeIds.add(link.edge.id);
        final c = intakeCost[n]! + edgePaArriving(link.edge, n);
        intakeCost[link.other] = c;
        if (c > intakePa) intakePa = c;
        q.add(link.other);
      }
    }
  }
  final outwardAdjacency = intakeEdgeIds.isEmpty
      ? adjacency
      : {
          for (final MapEntry(key: k, value: v) in adjacency.entries)
            k: [
              for (final l in v)
                if (!intakeEdgeIds.contains(l.edge.id)) l,
            ],
        };

  final staticPa = orientedPathCost(
    sourceId: fanNodeId,
    adjacency: outwardAdjacency,
    // Round 15 — the sizer records EXTRACT air (return / exhaust) in its
    // physical direction (grilles → fan); this walk runs OUTWARD from the
    // fan, so flip it back to the fan-outward orientation.
    flowFromOf: (e) {
      final f = sizing[e.id]?.flowFromId;
      if (f == null || !e.service.isExtractAir) return f;
      return f == e.fromId ? e.toId : (f == e.toId ? e.fromId : null);
    },
    edgeCost: edgePaArriving,
  );

  // Index run = the node with the greatest accumulated friction.
  var worst = 0.0;
  var criticalNodeId = fanNodeId;
  staticPa.forEach((nodeId, pa) {
    if (pa > worst) {
      worst = pa;
      criticalNodeId = nodeId;
    }
  });

  return DuctStaticSolution(
    totalStaticPressure: Pressure(worst + intakePa + terminalLoss.pascals),
    criticalNodeId: criticalNodeId,
  );
}
