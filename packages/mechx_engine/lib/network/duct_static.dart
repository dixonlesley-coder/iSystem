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

  // BFS from the fan accumulating cumulative friction (Pa) along the tree path.
  final staticPa = <String, double>{fanNodeId: 0.0};
  final queue = <String>[fanNodeId];
  var head = 0;
  while (head < queue.length) {
    final current = queue[head];
    head++;
    final currentStatic = staticPa[current]!;
    final links = adjacency[current];
    if (links == null) continue;
    for (final link in links) {
      if (staticPa.containsKey(link.other)) continue; // visited (tree)
      final edge = link.edge;
      var edgePa = 0.0;
      final edgeSizing = sizing[edge.id];
      if (edgeSizing != null) {
        final flow = edgeFlows[edge.id] ?? const FlowRate(0);
        final length = edgeLength(
          edge,
          net,
          calibrationBySheet: calibrationBySheet,
          building: building,
        );
        edgePa = ductFrictionPaPerMetre(
              flow,
              edgeSizing.diameter,
              roughness: edge.ductProduct == null
                  ? null
                  : ductRoughnessFor(edge.ductProduct!),
            ) *
            length.meters *
            fittingFactor;
      }
      staticPa[link.other] = currentStatic + edgePa;
      queue.add(link.other);
    }
  }

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
    totalStaticPressure: Pressure(worst + terminalLoss.pascals),
    criticalNodeId: criticalNodeId,
  );
}
