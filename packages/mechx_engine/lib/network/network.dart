import 'dart:math' as math;

import '../geometry/building.dart';
import '../geometry/scale_calibration.dart';
import '../standards/duct_products.dart';
import '../standards/pipe_products.dart';
import '../standards/sni.dart';
import '../units.dart';

/// Service a network element carries.
enum ServiceType {
  coldWater,
  hotWater,
  drainage,
  vent,
  rainwater,
  duct, // HVAC supply air
  returnAir, // HVAC return air
  exhaust, // HVAC exhaust air
  fireSprinkler,
  fireHydrant,
}

/// The sizing code path a service uses (§7): pressurized vs gravity vs air.
/// These MUST stay separate — a shared "size a pipe" routine breaks drainage
/// and fire.
enum FlowRegime { pressurized, gravity, air }

extension ServiceRegime on ServiceType {
  FlowRegime get regime => switch (this) {
        ServiceType.coldWater ||
        ServiceType.hotWater ||
        ServiceType.fireSprinkler ||
        ServiceType.fireHydrant =>
          FlowRegime.pressurized,
        ServiceType.drainage ||
        ServiceType.vent ||
        ServiceType.rainwater =>
          FlowRegime.gravity,
        ServiceType.duct ||
        ServiceType.returnAir ||
        ServiceType.exhaust =>
          FlowRegime.air,
      };

  /// True for the HVAC air services (supply / return / exhaust).
  bool get isAir => regime == FlowRegime.air;
}

/// A horizontal [run] (length from the sheet's calibrated scale) or a vertical
/// [riser] (length from a true-elevation delta — never from a PDF, §10). A
/// riser also covers a "drop" between a ceiling main and a fixture or the
/// plant, since both are vertical legs measured from elevations.
enum EdgeKind { run, riser }

/// What a node represents vertically. Drives its true elevation within a floor
/// (§10): a [main] sits at the ceiling, a [fixture] at fixture height, and the
/// [plant] (transfer pump / tank base) at an explicit datum (default roof).
enum NodeRole { main, fixture, plant }

/// A connection point, located at ([x], [y]) sheet pixels on [sheetId] /
/// [floorIndex]. Its vertical position comes from [role] (+ optional explicit
/// [elevation]) via [nodeElevation], never from the PDF.
class NetNode {
  final String id;
  final String sheetId;
  final double x;
  final double y;
  final int floorIndex;

  /// Vertical role within the floor (default: a ceiling-level distribution
  /// [NodeRole.main]).
  final NodeRole role;

  /// Optional absolute elevation override (e.g. a roof tank on a stand, or a
  /// basement plant datum). When set it wins over [role]-derived elevation.
  final Length? elevation;

  /// Plumbing fixture served at this node (for [NodeRole.fixture] terminals on
  /// a water service). Drives the per-fixture UBAP demand upstream.
  final PlumbingFixture? fixture;

  /// Design airflow at this node (for an air-terminal — diffuser/grille — on a
  /// duct service). Drives the accumulated duct airflow demand upstream.
  final FlowRate? airflow;

  const NetNode({
    required this.id,
    required this.sheetId,
    required this.x,
    required this.y,
    required this.floorIndex,
    this.role = NodeRole.main,
    this.elevation,
    this.fixture,
    this.airflow,
  });

  NetNode copyWith({
    String? sheetId,
    double? x,
    double? y,
    int? floorIndex,
    NodeRole? role,
    Length? elevation,
    PlumbingFixture? fixture,
    FlowRate? airflow,
  }) =>
      NetNode(
        id: id,
        sheetId: sheetId ?? this.sheetId,
        x: x ?? this.x,
        y: y ?? this.y,
        floorIndex: floorIndex ?? this.floorIndex,
        role: role ?? this.role,
        elevation: elevation ?? this.elevation,
        fixture: fixture ?? this.fixture,
        airflow: airflow ?? this.airflow,
      );
}

/// True elevation of [node] (§10), used for riser/drop length and static lift:
///   • explicit [NetNode.elevation] if set;
///   • [NodeRole.main]    → ceiling of its floor;
///   • [NodeRole.fixture] → fixture height above its floor;
///   • [NodeRole.plant]   → roof level (override via [NetNode.elevation] for a
///     basement pump or a tank on a stand).
Length nodeElevation(
  NetNode node,
  BuildingLevels building, [
  MountingHeights mounting = const MountingHeights(),
]) {
  final explicit = node.elevation;
  if (explicit != null) return explicit;
  switch (node.role) {
    case NodeRole.main:
      return building.ceilingElevationOf(node.floorIndex, mounting);
    case NodeRole.fixture:
      return building.fixtureElevationOf(node.floorIndex, mounting);
    case NodeRole.plant:
      return building.roofElevation;
  }
}

/// A pipe/duct/riser segment between two nodes, carrying one [service].
class NetEdge {
  final String id;
  final String fromId;
  final String toId;
  final ServiceType service;
  final EdgeKind kind;

  /// Optional pipe **product** specified for this segment (PPR PN10/16/20, PVC
  /// AW/D/JIS, cast iron, acoustic PVC, HDPE). A per-segment material label /
  /// BOM concern — the sizing routing is still by [ServiceType.regime]. `null`
  /// for an unset edge or a duct (air) segment.
  final PipeProduct? pipeProduct;

  /// Optional duct **product** specified for an air segment (BJLS / PU). `null`
  /// for an unset edge or a pipe segment.
  final DuctProduct? ductProduct;

  /// Optional manual nominal-size override (diameter). When set, the sizing
  /// engine uses this diameter for the edge and recomputes its velocity from the
  /// carried flow (see `autoSizeNetwork(sizeOverrides:)`). `null` ⇒ auto-sized.
  final Diameter? sizeOverride;

  const NetEdge({
    required this.id,
    required this.fromId,
    required this.toId,
    required this.service,
    this.kind = EdgeKind.run,
    this.pipeProduct,
    this.ductProduct,
    this.sizeOverride,
  });

  /// A copy with selected fields replaced. To CLEAR an optional field, pass the
  /// matching `clearX: true` flag (a plain `null` argument means "unchanged",
  /// since the named params can't distinguish absent from null).
  NetEdge copyWith({
    String? fromId,
    String? toId,
    ServiceType? service,
    EdgeKind? kind,
    PipeProduct? pipeProduct,
    bool clearPipeProduct = false,
    DuctProduct? ductProduct,
    bool clearDuctProduct = false,
    Diameter? sizeOverride,
    bool clearSizeOverride = false,
  }) =>
      NetEdge(
        id: id,
        fromId: fromId ?? this.fromId,
        toId: toId ?? this.toId,
        service: service ?? this.service,
        kind: kind ?? this.kind,
        pipeProduct:
            clearPipeProduct ? null : (pipeProduct ?? this.pipeProduct),
        ductProduct:
            clearDuctProduct ? null : (ductProduct ?? this.ductProduct),
        sizeOverride:
            clearSizeOverride ? null : (sizeOverride ?? this.sizeOverride),
      );
}

/// The drawn network — the single graph that sizing (P3) and the node-pressure
/// solve (P4) consume.
class Network {
  final List<NetNode> nodes;
  final List<NetEdge> edges;

  const Network({this.nodes = const [], this.edges = const []});

  NetNode? nodeById(String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  Iterable<NetEdge> edgesAt(String nodeId) =>
      edges.where((e) => e.fromId == nodeId || e.toId == nodeId);

  Network copyWith({List<NetNode>? nodes, List<NetEdge>? edges}) =>
      Network(nodes: nodes ?? this.nodes, edges: edges ?? this.edges);
}

/// Pixel span of a run between its endpoints (0 for a riser or a broken edge).
double runPixelLength(NetEdge edge, Network net) {
  if (edge.kind == EdgeKind.riser) return 0;
  final a = net.nodeById(edge.fromId);
  final b = net.nodeById(edge.toId);
  if (a == null || b == null) return 0;
  final dx = b.x - a.x;
  final dy = b.y - a.y;
  return math.sqrt(dx * dx + dy * dy);
}

/// Real length of [edge] from the §10 sources of truth: a run uses the
/// from-node sheet's calibration; a riser/drop uses the true-elevation delta of
/// its endpoints (role-aware — ceiling main, fixture, or plant). Returns zero
/// length for an uncalibrated run or a broken edge.
Length edgeLength(
  NetEdge edge,
  Network net, {
  required Map<String, ScaleCalibration> calibrationBySheet,
  required BuildingLevels building,
  MountingHeights mounting = const MountingHeights(),
}) {
  final a = net.nodeById(edge.fromId);
  final b = net.nodeById(edge.toId);
  if (a == null || b == null) return const Length(0);
  if (edge.kind == EdgeKind.riser) {
    final ea = nodeElevation(a, building, mounting);
    final eb = nodeElevation(b, building, mounting);
    return Length((eb.meters - ea.meters).abs());
  }
  final cal = calibrationBySheet[a.sheetId];
  if (cal == null) return const Length(0);
  return cal.lengthForPixels(runPixelLength(edge, net));
}
