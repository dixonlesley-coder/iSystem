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

/// A placed equipment / component on the network — a labelled node that renders
/// with its own schematic symbol. Each component implies a default [NodeRole]
/// (plant for pumps/tanks, fixture for drains/vents, main for inline
/// valves/meters), set at placement, so sizing reads the role exactly as
/// before — a pump or roof tank therefore feeds the pressure solve as a plant
/// source with no extra code. Per-component head loss (valve K-factors, meter
/// loss) is a later refinement (`// VERIFY`); for now a component is a labelled,
/// role-bearing symbol. Additive: `NetNode.component` is null for an ordinary
/// node, so nothing changes for existing networks.
enum NodeComponent {
  // Plant (role: plant — a solve source / boundary).
  pump,
  roofTank,
  groundTank,
  boosterSet,
  // Valves (role: main — inline on a run).
  gateValve,
  checkValve,
  prv,
  balancingValve,
  // Drains (role: fixture — a drainage/storm endpoint).
  roofDrain,
  floorDrain,
  cleanout,
  // Meters & misc.
  waterMeter,
  strainer,
  expansionTank,
  airVent,
  // Fire protection (role: fixture — points on the sprinkler/hydrant services;
  // the FDC is an inline main inlet).
  sprinklerHead,
  fireExtinguisher,
  hydrantBox,
  hoseReel,
  fireDeptConnection,
  // ── HVAC / ducting ──────────────────────────────────────────────────────
  // Air terminals (role: fixture — carry the airflow demand).
  supplyDiffuser,
  returnGrille,
  exhaustGrille,
  linearDiffuser,
  // Dampers + VAV (role: main — inline on a duct run).
  volumeDamper,
  fireDamper,
  motorizedDamper,
  vavBox,
  // Air units (role: plant — an air source / handling unit).
  ahu,
  fcu,
  supplyFan,
  exhaustFan,
}

extension NodeComponentInfo on NodeComponent {
  /// The vertical [NodeRole] this component takes when placed.
  NodeRole get role => switch (this) {
        NodeComponent.pump ||
        NodeComponent.roofTank ||
        NodeComponent.groundTank ||
        NodeComponent.boosterSet =>
          NodeRole.plant,
        NodeComponent.roofDrain ||
        NodeComponent.floorDrain ||
        NodeComponent.cleanout ||
        NodeComponent.airVent ||
        NodeComponent.sprinklerHead ||
        NodeComponent.fireExtinguisher ||
        NodeComponent.hydrantBox ||
        NodeComponent.hoseReel ||
        // HVAC air terminals carry the airflow demand → fixture.
        NodeComponent.supplyDiffuser ||
        NodeComponent.returnGrille ||
        NodeComponent.exhaustGrille ||
        NodeComponent.linearDiffuser =>
          NodeRole.fixture,
        // Air units are the air source → plant.
        NodeComponent.ahu ||
        NodeComponent.fcu ||
        NodeComponent.supplyFan ||
        NodeComponent.exhaustFan =>
          NodeRole.plant,
        // Inline valves + meters / strainer / expansion tank + FDC inlet +
        // inline dampers / VAV.
        _ => NodeRole.main,
      };

  /// A short human-readable label.
  String get label => switch (this) {
        NodeComponent.pump => 'Pump',
        NodeComponent.roofTank => 'Roof tank',
        NodeComponent.groundTank => 'Ground tank',
        NodeComponent.boosterSet => 'Booster set',
        NodeComponent.gateValve => 'Gate valve',
        NodeComponent.checkValve => 'Check valve',
        NodeComponent.prv => 'PRV',
        NodeComponent.balancingValve => 'Balancing valve',
        NodeComponent.roofDrain => 'Roof drain',
        NodeComponent.floorDrain => 'Floor drain',
        NodeComponent.cleanout => 'Cleanout',
        NodeComponent.waterMeter => 'Water meter',
        NodeComponent.strainer => 'Strainer',
        NodeComponent.expansionTank => 'Expansion tank',
        NodeComponent.airVent => 'Air vent',
        NodeComponent.sprinklerHead => 'Sprinkler head',
        NodeComponent.fireExtinguisher => 'Fire extinguisher',
        NodeComponent.hydrantBox => 'Hydrant box',
        NodeComponent.hoseReel => 'Hose reel',
        NodeComponent.fireDeptConnection => 'Fire dept. connection',
        NodeComponent.supplyDiffuser => 'Supply diffuser',
        NodeComponent.returnGrille => 'Return grille',
        NodeComponent.exhaustGrille => 'Exhaust grille',
        NodeComponent.linearDiffuser => 'Linear diffuser',
        NodeComponent.volumeDamper => 'Volume damper',
        NodeComponent.fireDamper => 'Fire damper',
        NodeComponent.motorizedDamper => 'Motorized damper',
        NodeComponent.vavBox => 'VAV box',
        NodeComponent.ahu => 'AHU',
        NodeComponent.fcu => 'FCU',
        NodeComponent.supplyFan => 'Supply fan',
        NodeComponent.exhaustFan => 'Exhaust fan',
      };

  /// Minor-loss coefficient K for an inline RESTRICTOR (valve / strainer /
  /// meter), used for the local head loss h = K·v²/2g folded into the
  /// pressurized solve. 0 for components that aren't an inline restriction
  /// (pumps add head, tanks are sources, drains/fire points sit off the supply
  /// path). These are representative fully-open values from general hydraulics
  /// practice (Crane TP-410-class), NOT an SNI clause — `// VERIFY` against the
  /// project's actual valve schedule / Cv data. A PRV is intentionally 0 here:
  /// it sets a downstream pressure (handled by the PRV zoning), not a simple K.
  double get minorLossK => switch (this) {
        NodeComponent.gateValve => 0.2,
        NodeComponent.checkValve => 2.0,
        NodeComponent.balancingValve => 3.0,
        NodeComponent.strainer => 2.0,
        NodeComponent.waterMeter => 6.0,
        _ => 0.0,
      };
}

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

  /// Optional mounting height of THIS node above its own floor surface — "how
  /// high up the wall" the fixture/outlet sits. When set it places the node at
  /// `floorElevation + mountHeight`, so the vertical pipe/cable to it is sized
  /// from the real wall height rather than the role default (§10). `null` ⇒ use
  /// the role-derived elevation (fixture-height default / ceiling / roof).
  /// An explicit absolute [elevation] still wins over this.
  final Length? mountHeight;

  /// Plumbing fixture served at this node (for [NodeRole.fixture] terminals on
  /// a water service). Drives the per-fixture UBAP demand upstream.
  final PlumbingFixture? fixture;

  /// Design airflow at this node (for an air-terminal — diffuser/grille — on a
  /// duct service). Drives the accumulated duct airflow demand upstream.
  final FlowRate? airflow;

  /// Id of a user-defined custom fixture type (see the app's fixture library)
  /// served at this node. When set it overrides the built-in [fixture] for the
  /// per-fixture demand lookup; the app resolves the id to its UBAP load. Null =
  /// no custom fixture (use the built-in [fixture]). Additive — the engine core
  /// never reads it directly (the integration layer resolves the load).
  final String? customFixtureId;

  /// Catchment roof area (m²) draining to this node, for a rainwater outlet on a
  /// storm service. When set it overrides the storm sizing's flat default
  /// catchment for this outlet; null = use the default. Additive — a null value
  /// keeps storm sizing byte-identical.
  final double? roofAreaM2;

  /// Optional equipment/component this node represents (pump, roof tank, valve,
  /// roof drain, meter…). Drives the on-canvas symbol; the implied [role] is set
  /// at placement. Null ⇒ an ordinary node (byte-identical). Additive — the
  /// sizing core reads the [role], not this label.
  final NodeComponent? component;

  /// Stored capacity (litres) for a TANK component node — e.g. a prebuilt
  /// fibreglass/HDPE tank where you enter the bought size directly (as opposed
  /// to a cast concrete reservoir whose capacity comes from its drawn
  /// footprint × depth). Null for a non-tank node or an unspecified size.
  final double? tankCapacityLitres;

  const NetNode({
    required this.id,
    required this.sheetId,
    required this.x,
    required this.y,
    required this.floorIndex,
    this.role = NodeRole.main,
    this.elevation,
    this.mountHeight,
    this.fixture,
    this.airflow,
    this.customFixtureId,
    this.roofAreaM2,
    this.component,
    this.tankCapacityLitres,
  });

  NetNode copyWith({
    String? sheetId,
    double? x,
    double? y,
    int? floorIndex,
    NodeRole? role,
    Length? elevation,
    Length? mountHeight,
    bool clearMountHeight = false,
    PlumbingFixture? fixture,
    FlowRate? airflow,
    String? customFixtureId,
    bool clearCustomFixtureId = false,
    double? roofAreaM2,
    bool clearRoofAreaM2 = false,
    NodeComponent? component,
    bool clearComponent = false,
    double? tankCapacityLitres,
    bool clearTankCapacity = false,
  }) =>
      NetNode(
        id: id,
        sheetId: sheetId ?? this.sheetId,
        x: x ?? this.x,
        y: y ?? this.y,
        floorIndex: floorIndex ?? this.floorIndex,
        role: role ?? this.role,
        elevation: elevation ?? this.elevation,
        mountHeight:
            clearMountHeight ? null : (mountHeight ?? this.mountHeight),
        fixture: fixture ?? this.fixture,
        airflow: airflow ?? this.airflow,
        customFixtureId:
            clearCustomFixtureId ? null : (customFixtureId ?? this.customFixtureId),
        roofAreaM2: clearRoofAreaM2 ? null : (roofAreaM2 ?? this.roofAreaM2),
        component: clearComponent ? null : (component ?? this.component),
        tankCapacityLitres: clearTankCapacity
            ? null
            : (tankCapacityLitres ?? this.tankCapacityLitres),
      );
}

/// True elevation of [node] (§10), used for riser/drop length and static lift:
///   • explicit [NetNode.elevation] if set;
///   • [NetNode.mountHeight] (above its floor) if set — the per-node wall height;
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
  // A per-node mounting height places it that far up its own floor's wall — the
  // single source for the vertical run to this fixture/outlet.
  final mount = node.mountHeight;
  if (mount != null) {
    return Length(building.elevationOf(node.floorIndex).meters + mount.meters);
  }
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
