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

  /// True for the EXTRACT air services (return + exhaust): air that travels
  /// from the grilles TOWARD the fan / AHU, the reverse of supply air.
  bool get isExtractAir =>
      this == ServiceType.returnAir || this == ServiceType.exhaust;
}

/// The default duct PRODUCT for an air [service] when the engineer hasn't picked
/// one per segment: **AC installs** (supply + return air) default to **PU**
/// pre-insulated panel; **exhaust-fan installs** to **BJLS** galvanised steel.
/// Only meaningful for air services (the duct disciplines).
DuctProduct defaultDuctProductForService(ServiceType service) =>
    service == ServiceType.exhaust ? DuctProduct.bjls : DuctProduct.pu;

/// The effective duct product for [edge]: its explicit [NetEdge.ductProduct]
/// when set, else the service default (PU for AC supply/return, BJLS for
/// exhaust). Call only for air edges.
DuctProduct effectiveDuctProductFor(NetEdge edge) =>
    edge.ductProduct ?? defaultDuctProductForService(edge.service);

/// A horizontal [run] (length from the sheet's calibrated scale) or a vertical
/// [riser] (length from a true-elevation delta — never from a PDF, §10). A
/// riser also covers a "drop" between a ceiling main and a fixture or the
/// plant, since both are vertical legs measured from elevations.
enum EdgeKind { run, riser }

/// What a node represents vertically. Drives its true elevation within a floor
/// (§10): a [main] sits at the ceiling, a [fixture] at fixture height, and the
/// [plant] (transfer pump / tank base) at an explicit datum (default roof).
enum NodeRole { main, fixture, plant }

/// The pipe fitting a junction node represents where runs meet. [auto] (the
/// default) lets the renderer pick from the joint's geometry — an end cap (1
/// pipe), a coupling (2 in-line), an elbow (2 at an angle), a tee (3) or a
/// cross (4+). A non-[auto] value is a user override (right-click → Fitting) so
/// a 3-way branch can be drawn/specified as a square tee, a 45° wye, or a
/// tee-wye regardless of the drawn angle. Additive — null/[auto] is the prior
/// behaviour and carries no head-loss term (a drawing/BOM concern).
enum JunctionFitting { auto, coupling, elbow, tee, wye, teeWye, cross, cap }

extension JunctionFittingInfo on JunctionFitting {
  /// Short human label for menus / BOM.
  String get label => switch (this) {
        JunctionFitting.auto => 'Auto',
        JunctionFitting.coupling => 'Coupling',
        JunctionFitting.elbow => 'Elbow',
        JunctionFitting.tee => 'Tee',
        JunctionFitting.wye => 'Wye (Y)',
        JunctionFitting.teeWye => 'Tee-wye',
        JunctionFitting.cross => 'Cross',
        JunctionFitting.cap => 'End cap',
      };
}

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
  // A riser start/connection marker (role: main) — where a vertical riser meets
  // the horizontal main, so a run can be connected from it.
  riser,
  // Meters & misc.
  waterMeter,
  strainer,
  expansionTank,
  airVent,
  // A clean-water OUTLET (role: fixture) — a placement marker for where a
  // potable-water outlet / tap / fixture connection is delivered.
  waterOutlet,
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
  // Air-conditioning indoor units (role: plant). A conditioned-air source that
  // also represents the room's AC equipment + its electrical load. Placed inside
  // a drawn room, it triggers the room's cooling-load (BTU/h · PK) calc.
  acCassette,
  acSplitWall,
  acDucted,
}

/// Round 33 (hydraulics-3-1) — the ONE non-demand TERMINAL predicate: a
/// fixture-role component that is not a draw-off point — a cleanout (an
/// access fitting), an air vent (an air-release valve / AAV), a fire
/// extinguisher (not piped). The sizer gives it no load and the pressure
/// solves owe it no residual (it is never a delivery / critical node).
bool isNonDemandTerminal(NodeComponent? c) =>
    c == NodeComponent.cleanout ||
    c == NodeComponent.airVent ||
    c == NodeComponent.fireExtinguisher;

/// Round 34 (fire-hvac-drawings-fdc-drawn-and-sized-as-outlet) — a SUPPLY
/// INLET: a fire department connection (siamese) is where the fire brigade
/// pumps water INTO the system. It is never a draw-off point (no demand, never
/// a delivery / critical node, never counted as a hydrant outlet) and its
/// branch is oriented INTO the system, like a ground tank's fill line.
bool isSupplyInletComponent(NodeComponent? c) =>
    c == NodeComponent.fireDeptConnection;

/// Round 33 (hydraulics-3-3) — INLINE DEVICES: a valve, meter, strainer or
/// expansion tank is never a draw-off point, even drawn at a run's end (a
/// PDAM water meter is the supply ENTRY of a mains-fed system).
const Set<NodeComponent> kInlineDeviceComponents = {
  NodeComponent.waterMeter,
  NodeComponent.expansionTank,
  NodeComponent.gateValve,
  NodeComponent.checkValve,
  NodeComponent.prv,
  NodeComponent.strainer,
  NodeComponent.balancingValve,
};

/// Round 33 — whether [c] is one of [kInlineDeviceComponents].
bool isInlineDeviceComponent(NodeComponent? c) =>
    c != null && kInlineDeviceComponents.contains(c);

/// Round 33 (hydraulics-3-1) — a DELIVERY fixture: a fixture-role node that
/// is a real draw-off point (not a [isNonDemandTerminal]).
bool isDeliveryFixture(NetNode? n) =>
    n != null && n.role == NodeRole.fixture && !isNonDemandTerminal(n.component);

/// Round 31 (hvac-5-1) — the ONE supply-air terminal predicate: a supply
/// diffuser or a LINEAR (slot) diffuser. Both carry the delivered airflow of
/// a conditioned room; every room-served / stale / Auto-place test reads this
/// so a room fed only through linear diffusers is never mistaken for unserved.
bool isSupplyAirTerminal(NodeComponent? c) =>
    c == NodeComponent.supplyDiffuser || c == NodeComponent.linearDiffuser;

/// Round 52 (plumbing-hvac-convergence-2-1) — an air SOURCE unit (AHU,
/// supply fan, exhaust fan): it delivers / draws its system's air, so it is
/// never an air TERMINAL carrying a design airflow of its own (that made it a
/// demand-bearing fixture, re-rooted the system at a bare junction and
/// doubled the trunk flow). FCU / AC units are terminal units, not sources.
bool isAirSourceUnitComponent(NodeComponent? c) =>
    c == NodeComponent.ahu ||
    c == NodeComponent.supplyFan ||
    c == NodeComponent.exhaustFan;

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
        // A clean-water outlet is a delivery endpoint on the supply → fixture.
        NodeComponent.waterOutlet ||
        // HVAC air terminals carry the airflow demand → fixture.
        NodeComponent.supplyDiffuser ||
        NodeComponent.returnGrille ||
        NodeComponent.exhaustGrille ||
        NodeComponent.linearDiffuser =>
          NodeRole.fixture,
        // Air units + AC indoor units are the air source → plant.
        NodeComponent.ahu ||
        NodeComponent.fcu ||
        NodeComponent.supplyFan ||
        NodeComponent.exhaustFan ||
        NodeComponent.acCassette ||
        NodeComponent.acSplitWall ||
        NodeComponent.acDucted =>
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
        NodeComponent.riser => 'Riser',
        NodeComponent.waterMeter => 'Water meter',
        NodeComponent.strainer => 'Strainer',
        NodeComponent.expansionTank => 'Expansion tank',
        NodeComponent.airVent => 'Air vent',
        NodeComponent.waterOutlet => 'Water outlet',
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
        NodeComponent.acCassette => 'Cassette AC',
        NodeComponent.acSplitWall => 'Split wall AC',
        NodeComponent.acDucted => 'Ducted AC',
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

  /// Air-side fitting loss coefficient C (dimensionless, against the velocity
  /// pressure ρv²/2) for an inline DUCT restrictor — a damper or VAV box —
  /// folded into the fan total static (`duct_static`). 0 for components that
  /// aren't an inline air restriction. Representative values from general HVAC
  /// practice, NOT an SNI clause — `// VERIFY` against the damper/VAV schedule.
  double get airLossC => switch (this) {
        NodeComponent.volumeDamper => 0.2,
        NodeComponent.fireDamper => 0.3,
        NodeComponent.motorizedDamper => 0.4,
        // A VAV terminal box's effective drop (a higher coefficient stands in
        // for its minimum static requirement).
        NodeComponent.vavBox => 1.5,
        _ => 0.0,
      };

  /// Whether this component is also an ELECTRICAL load — a motorised piece of
  /// equipment that draws power, so a pump/fan/air-unit placed on the mechanical
  /// plan is INTER-RELATED with the electrical model (it appears as a circuit on
  /// the panel). The mechanical and electrical disciplines share the one node.
  bool get isElectricalLoad => switch (this) {
        NodeComponent.pump ||
        NodeComponent.boosterSet ||
        NodeComponent.supplyFan ||
        NodeComponent.exhaustFan ||
        NodeComponent.ahu ||
        NodeComponent.fcu ||
        NodeComponent.acCassette ||
        NodeComponent.acSplitWall ||
        NodeComponent.acDucted =>
          true,
        _ => false,
      };

  /// A representative motor rating (kW) for an [isElectricalLoad] component, used
  /// as the electrical load when the node carries no explicit override. General
  /// practice, NOT a PUIL/SNI clause — `// VERIFY` against the equipment
  /// schedule. 0 for non-electrical components.
  double get defaultMotorKw => switch (this) {
        NodeComponent.pump => 1.5,
        NodeComponent.boosterSet => 3.0,
        NodeComponent.supplyFan => 1.1,
        NodeComponent.exhaustFan => 0.75,
        NodeComponent.ahu => 5.5,
        NodeComponent.fcu => 0.25,
        // AC indoor-unit input power (representative; depends on PK/COP). The
        // room cooling calc surfaces the PK; this is the panel default.
        NodeComponent.acSplitWall => 0.9,
        NodeComponent.acCassette => 1.8,
        NodeComponent.acDucted => 2.6,
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

  /// Explicit electrical load (W) for a motorised equipment node (pump / fan /
  /// air unit) — overrides the component's [NodeComponentInfo.defaultMotorKw]
  /// when the mechanical node is fed into the electrical model. Null ⇒ use the
  /// default rating. Lets a pump exist on BOTH the plumbing and electrical sides
  /// with one edited power.
  final double? electricalLoadW;

  /// Manually chosen grille/diffuser FACE size (gross width × height, mm) for an
  /// air-terminal node — set when the engineer picks a specific diffuser size
  /// (for aesthetic / ceiling-grid reasons) rather than letting the engine size
  /// it. The face velocity (airflow ÷ free face area) is checked against the
  /// recommended band for a too-high / too-low warning. Both null ⇒ no chosen
  /// face (byte-identical; the warning layer simply has nothing to judge).
  final double? faceWidthMm;
  final double? faceHeightMm;

  /// Optional fitting-type override for a junction (right-click → Fitting). Null
  /// or [JunctionFitting.auto] ⇒ the renderer derives the fitting from the joint
  /// geometry. A specific value pins it (e.g. tee vs wye). Additive — a
  /// drawing/BOM concern, never read by the sizing core.
  final JunctionFitting? fittingType;

  /// Round 20 — the id of the room whose 'Auto-place diffusers' generated this
  /// air terminal (null for a hand-placed / pasted terminal). The app's
  /// idempotence clean-up and the stale-terminal judge read it FIRST (while
  /// the terminal still sits inside that room), so a terminal an open office
  /// generated inside a nested meeting room stays the office's — re-running
  /// Auto-place never stacks a second generation on it. Additive — the sizing
  /// core never reads it; null ⇒ byte-identical.
  final String? autoPlacedRoomId;

  /// Round 33 (engineer-walkthrough-equipment-tag-global-ordinal) — the
  /// equipment TAG NUMBER this node was minted with, per tag prefix (the 1 of
  /// `P-01`), so the first pump is P-01 however many fixtures were drawn
  /// before it. Assigned once at mint from a per-prefix sequence that never
  /// re-issues a deleted number (C6 stability); null on a legacy node (its
  /// tag still derives from the node-id ordinal — unchanged). Additive.
  final int? tagNo;

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
    this.electricalLoadW,
    this.faceWidthMm,
    this.faceHeightMm,
    this.fittingType,
    this.autoPlacedRoomId,
    this.tagNo,
  });

  NetNode copyWith({
    String? sheetId,
    double? x,
    double? y,
    int? floorIndex,
    NodeRole? role,
    Length? elevation,
    bool clearElevation = false,
    Length? mountHeight,
    bool clearMountHeight = false,
    PlumbingFixture? fixture,
    bool clearFixture = false,
    FlowRate? airflow,
    bool clearAirflow = false,
    String? customFixtureId,
    bool clearCustomFixtureId = false,
    double? roofAreaM2,
    bool clearRoofAreaM2 = false,
    NodeComponent? component,
    bool clearComponent = false,
    double? tankCapacityLitres,
    bool clearTankCapacity = false,
    double? electricalLoadW,
    bool clearElectricalLoad = false,
    double? faceWidthMm,
    double? faceHeightMm,
    bool clearFace = false,
    JunctionFitting? fittingType,
    bool clearJunctionFitting = false,
    String? autoPlacedRoomId,
    bool clearAutoPlacedRoomId = false,
    int? tagNo,
    bool clearTagNo = false,
  }) =>
      NetNode(
        id: id,
        sheetId: sheetId ?? this.sheetId,
        x: x ?? this.x,
        y: y ?? this.y,
        floorIndex: floorIndex ?? this.floorIndex,
        role: role ?? this.role,
        elevation: clearElevation ? null : (elevation ?? this.elevation),
        mountHeight:
            clearMountHeight ? null : (mountHeight ?? this.mountHeight),
        fixture: clearFixture ? null : (fixture ?? this.fixture),
        airflow: clearAirflow ? null : (airflow ?? this.airflow),
        customFixtureId: clearCustomFixtureId
            ? null
            : (customFixtureId ?? this.customFixtureId),
        roofAreaM2: clearRoofAreaM2 ? null : (roofAreaM2 ?? this.roofAreaM2),
        component: clearComponent ? null : (component ?? this.component),
        tankCapacityLitres: clearTankCapacity
            ? null
            : (tankCapacityLitres ?? this.tankCapacityLitres),
        electricalLoadW: clearElectricalLoad
            ? null
            : (electricalLoadW ?? this.electricalLoadW),
        faceWidthMm: clearFace ? null : (faceWidthMm ?? this.faceWidthMm),
        faceHeightMm: clearFace ? null : (faceHeightMm ?? this.faceHeightMm),
        fittingType:
            clearJunctionFitting ? null : (fittingType ?? this.fittingType),
        autoPlacedRoomId: clearAutoPlacedRoomId
            ? null
            : (autoPlacedRoomId ?? this.autoPlacedRoomId),
        tagNo: clearTagNo ? null : (tagNo ?? this.tagNo),
      );
}

/// Round 45 (mech-convergence-1) — true when [n] carries DESIGN CONTENT a
/// merge must never silently discard: a component, a non-`main` role, a
/// fixture / custom fixture, an airflow, a tank capacity, a roof area, an
/// electrical load, a face size, or an elevation / mounting override. A bare
/// run-end junction carries none. The node-merge paths (drag-end snap, a
/// base-point Move / Copy landing on a node) keep the content-bearing node
/// and drop the bare one, and never join two content-bearing nodes. Pure.
bool nodeCarriesContent(NetNode n) =>
    n.component != null ||
    n.role != NodeRole.main ||
    n.fixture != null ||
    n.customFixtureId != null ||
    n.airflow != null ||
    n.tankCapacityLitres != null ||
    n.roofAreaM2 != null ||
    n.electricalLoadW != null ||
    n.faceWidthMm != null ||
    n.faceHeightMm != null ||
    n.elevation != null ||
    n.mountHeight != null;

/// True elevation of [node] (§10), used for riser/drop length and static lift:
///   • explicit [NetNode.elevation] if set;
///   • [NetNode.mountHeight] (above its floor) if set — the per-node wall height;
///   • [NodeRole.main]    → ceiling of its floor;
///   • [NodeRole.fixture] → fixture height above its floor — except a GRAVITY
///     outlet: [NodeComponent.floorDrain] / [NodeComponent.cleanout] at its
///     floor surface, [NodeComponent.roofDrain] at the roof on the top storey
///     (its own floor surface below it);
///   • [NodeRole.plant]   → depends on WHAT the plant is ([NetNode.component]):
///       – [NodeComponent.roofTank] → roof level (it sits on the roof slab);
///       – water plant that sits on its own floor — [NodeComponent.pump],
///         [NodeComponent.groundTank], [NodeComponent.boosterSet] — and the
///         floor-standing air plant ([NodeComponent.ahu],
///         [NodeComponent.supplyFan], [NodeComponent.exhaustFan]) → the floor
///         surface of the node's OWN floor (a ground-floor pump lifts water the
///         whole building height; rooting it at the roof dropped that static
///         lift out of the pump head — audit 2026-10 water-drainage-1);
///       – ceiling-hung air plant ([NodeComponent.fcu], the AC indoor units)
///         → the ceiling of its own floor (where the unit and its ducts hang);
///       – no component → its own floor surface below the top storey, the
///         roof on the top storey (Round 17 — see the inline note);
///       – any other component → roof level (legacy default).
///     Override via [NetNode.elevation] for a tank on a stand, a basement pump
///     on a plinth, or a rooftop fan.
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
  // Round 17 follow-up (gravity-3-3) — a GRAVITY outlet sits ON its surface,
  // not at tap height: a floor drain / cleanout at its own floor surface, a
  // roof drain at the roof slab on the top storey (at its own floor's surface
  // below it — a terrace / podium roof). Placing them at the 1.1 m fixture
  // height cut 1.1 m (and more at the roof) off every downpipe / stack riser
  // the BOM, cut plan and riser diagram read. // VERIFY notAnSniClause (a
  // modelling datum; set the node elevation for a sunk / raised outlet).
  switch (node.component) {
    case NodeComponent.floorDrain:
    case NodeComponent.cleanout:
      return building.elevationOf(node.floorIndex);
    case NodeComponent.roofDrain:
      final top = building.levelCount - 1;
      if (building.levelCount > 0 && node.floorIndex < top) {
        return building.elevationOf(node.floorIndex);
      }
      return building.roofElevation;
    default:
      break;
  }
  switch (node.role) {
    case NodeRole.main:
      return building.ceilingElevationOf(node.floorIndex, mounting);
    case NodeRole.fixture:
      return building.fixtureElevationOf(node.floorIndex, mounting);
    case NodeRole.plant:
      switch (node.component) {
        case NodeComponent.pump:
        case NodeComponent.groundTank:
        case NodeComponent.boosterSet:
        case NodeComponent.ahu:
        case NodeComponent.supplyFan:
        case NodeComponent.exhaustFan:
          return building.elevationOf(node.floorIndex);
        case NodeComponent.fcu:
        case NodeComponent.acCassette:
        case NodeComponent.acSplitWall:
        case NodeComponent.acDucted:
          return building.ceilingElevationOf(node.floorIndex, mounting);
        case null:
          // Round 17 (report-recompute-2-component-less-source-at-roof-on-
          // upfeed) — an UNTYPED plant (the inspector's 'Source / tank') sits
          // on its OWN floor when drawn below the top storey: a ground-floor
          // source / heater placed at the roof dropped the whole building
          // height out of the upfeed pump head (24.8 m printed for a 45.0 m
          // lift on 6 × 3.5 m) and added a phantom vertical to every length
          // consumer (HW recirc loop, BOM). On the TOP storey (and so in a
          // one-level building) it keeps the legacy roof datum — the roof
          // source a gravity downfeed hangs from.
          // VERIFY — notAnSniClause (a modelling default; type the plant or set
          // its elevation for the real datum).
          final top = building.levelCount - 1;
          if (building.levelCount > 0 && node.floorIndex < top) {
            return building.elevationOf(node.floorIndex);
          }
          return building.roofElevation;
        default:
          // roofTank, and a plant with a non-plant component.
          return building.roofElevation;
      }
  }
}

/// Round 21 (riser-drafting-2-6) — the elevation a GRAVITY riser
/// (drainage / vent / rainwater) reads at [node]. A bare stack junction
/// (`main` role, no component, no explicit elevation / mount height) is where
/// that floor's soil / waste / rain branch joins the stack — UNDER the
/// floor's own slab, i.e. in the ceiling space of the floor below
/// (`ceilingElevationOf(floor - 1)`); on the lowest level the stack foot /
/// downpipe exit sits ON THE LOWEST SLAB (`elevationOf(0)` — grade with no
/// basement, the lowest basement slab when `groundIndex > 0`). Every other node (a drain
/// or cleanout on its surface, plant, a fixture, an explicit datum) keeps
/// [nodeElevation]. Mixing the two datums (a cleanout on its surface beside a
/// junction at its own floor's CEILING) printed a 6.9 m single-storey base
/// riser, a stack top ~3.6 m long and a downpipe stopping 3.3 m above grade.
/// `// VERIFY` notAnSniClause (a modelling datum, no invert model; set the
/// node elevation for a real invert).
///
/// Round 22 (regression-vent-stack-top-under-top-slab) — a VENT stack
/// ([service] == [ServiceType.vent]) does not stop under the top floor's slab:
/// it continues through the top storey and penetrates the roof (the VTR the
/// riser drawing extends to the ATAP line), so a bare vent junction on the
/// TOP storey reads [BuildingLevels.roofElevation]. The summed vent stack is
/// then roof − foot datum, not one storey short. Drainage / rainwater keep the
/// under-slab datum. `// VERIFY` notAnSniClause (the VTR is taken at the roof
/// slab; the upstand above it is not modelled).
Length gravityRiserEndElevation(
  NetNode node,
  BuildingLevels building, [
  MountingHeights mounting = const MountingHeights(),
  ServiceType? service,
]) {
  final bareJunction = node.elevation == null &&
      node.mountHeight == null &&
      node.component == null &&
      node.role == NodeRole.main &&
      building.levelCount > 0;
  if (!bareJunction) return nodeElevation(node, building, mounting);
  final f = node.floorIndex.clamp(0, building.levelCount - 1);
  if (service == ServiceType.vent &&
      building.levelCount > 1 &&
      f == building.levelCount - 1) {
    return building.roofElevation;
  }
  if (f == 0) return building.elevationOf(0);
  return building.ceilingElevationOf(f - 1, mounting);
}

/// The elevation a RISER [edge] reads at its end [node] — the ONE riser-end
/// datum every riser length goes through ([edgeLength], the Riser canvas
/// label, the Riser system summary): a gravity riser (drainage / vent /
/// rainwater) reads [gravityRiserEndElevation], every other service the
/// height its pipe / duct actually MEETS the element —
/// [runConnectionElevation] (Round 35, regression-1): a datum-less AHU /
/// supply fan / exhaust fan at the top of its casing
/// ([MountingHeights.airUnitConnection], ceiling-capped) and a ceiling-hung
/// diffuser / grille / sprinkler head at the ceiling, exactly the datum a RUN
/// leg uses — so one physical duct measures the same whether it is drawn as a
/// single riser or as a run + riser. [nodeElevation] stays the STATIC datum
/// of the pressure solves.
Length riserEndElevation(
  NetEdge edge,
  NetNode node,
  BuildingLevels building, [
  MountingHeights mounting = const MountingHeights(),
]) =>
    edge.service.regime == FlowRegime.gravity
        ? gravityRiserEndElevation(node, building, mounting, edge.service)
        : runConnectionElevation(node, building, mounting);

/// The elevation a node is SHOWN at (inspector readout, hover FFL chip): a
/// node on ANY riser reads the same riser-end datum its riser length is
/// measured from ([riserEndElevation] — a bare gravity stack junction sits
/// under its floor's slab, an air unit at its casing top; Round 35); a
/// gravity riser wins when a node sits on both kinds. Every other node reads
/// [nodeElevation]. One helper so the two readouts can never disagree.
Length displayedNodeElevation(
  Network net,
  NetNode node,
  BuildingLevels building, [
  MountingHeights mounting = const MountingHeights(),
]) {
  NetEdge? pressurized;
  for (final e in net.edges) {
    if (e.kind != EdgeKind.riser || (e.fromId != node.id && e.toId != node.id)) {
      continue;
    }
    if (e.service.regime == FlowRegime.gravity) {
      return riserEndElevation(e, node, building, mounting);
    }
    pressurized ??= e;
  }
  if (pressurized != null) {
    return riserEndElevation(pressurized, node, building, mounting);
  }
  return nodeElevation(node, building, mounting);
}

/// The vertical length of a riser [edge] between its ends [a] and [b]
/// (`|Δ` [riserEndElevation]`|`) — never measured from the PDF.
Length riserElevationDelta(
  NetEdge edge,
  NetNode a,
  NetNode b,
  BuildingLevels building, [
  MountingHeights mounting = const MountingHeights(),
]) =>
    Length((riserEndElevation(edge, b, building, mounting).meters -
            riserEndElevation(edge, a, building, mounting).meters)
        .abs());

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

  // Round 28 (regression-classifier-quadratic-dijkstra) — id lookups go
  // through a lazily built index (first occurrence wins, exactly as the
  // linear scan did), re-built whenever the list instance or its length
  // changes: the sizer looks nodes up per edge relaxation, and a linear scan
  // there made sizing quadratic in the drawing.
  static final _nodeIndex = Expando<(int, Map<String, NetNode>)>();
  static final _edgeIndex = Expando<(int, Map<String, NetEdge>)>();
  static final _incidenceIndex =
      Expando<(int, Map<String, List<NetEdge>>)>();

  NetNode? nodeById(String id) {
    var idx = _nodeIndex[nodes];
    if (idx == null || idx.$1 != nodes.length) {
      final m = <String, NetNode>{};
      for (final n in nodes) {
        m.putIfAbsent(n.id, () => n);
      }
      _nodeIndex[nodes] = idx = (nodes.length, m);
    }
    return idx.$2[id];
  }

  NetEdge? edgeById(String id) {
    var idx = _edgeIndex[edges];
    if (idx == null || idx.$1 != edges.length) {
      final m = <String, NetEdge>{};
      for (final e in edges) {
        m.putIfAbsent(e.id, () => e);
      }
      _edgeIndex[edges] = idx = (edges.length, m);
    }
    return idx.$2[id];
  }

  /// The edges touching [nodeId], in edge-list order (a self-loop once).
  ///
  /// Drafting-feel perf — served from a lazily built incidence index (the same
  /// list-instance + length invalidation as [nodeById]); the linear scan made
  /// every per-node caller (connectivity, riser tags, the Design-Issues fan-in,
  /// the BOM) quadratic in the drawing.
  Iterable<NetEdge> edgesAt(String nodeId) {
    var idx = _incidenceIndex[edges];
    if (idx == null || idx.$1 != edges.length) {
      final m = <String, List<NetEdge>>{};
      for (final e in edges) {
        (m[e.fromId] ??= <NetEdge>[]).add(e);
        if (e.toId != e.fromId) (m[e.toId] ??= <NetEdge>[]).add(e);
      }
      _incidenceIndex[edges] = idx = (edges.length, m);
    }
    return idx.$2[nodeId] ?? const <NetEdge>[];
  }

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

/// The elevation a RUN connects to [node] at — the height the run's pipe/duct
/// actually meets that element, used ONLY for a run's vertical leg
/// ([runVerticalLeg]) and the plan setting-out label built on it. It is
/// [nodeElevation] (an explicit `elevation` / `mountHeight` always wins),
/// EXCEPT a datum-less ceiling-hung terminal: an air terminal
/// (supply diffuser / linear diffuser / return or exhaust grille) or a
/// sprinkler head is a [NodeRole.fixture] for DEMAND, but it hangs AT the
/// ceiling, not at the plumbing fixture height — so a run from a ceiling main
/// to it has no vertical leg. Plumbing fixtures, water outlets, hose reels and
/// hydrant boxes keep the fixture height. Round 34: a datum-less AHU /
/// supply fan / exhaust fan connects at [MountingHeights.airUnitConnection]
/// above its floor surface (capped at the ceiling). Pure.
Length runConnectionElevation(
  NetNode node,
  BuildingLevels building, [
  MountingHeights mounting = const MountingHeights(),
]) {
  if (node.elevation == null && node.mountHeight == null) {
    switch (node.component) {
      case NodeComponent.supplyDiffuser:
      case NodeComponent.linearDiffuser:
      case NodeComponent.returnGrille:
      case NodeComponent.exhaustGrille:
      case NodeComponent.sprinklerHead:
        return building.ceilingElevationOf(node.floorIndex, mounting);
      // Round 34 — a floor-standing air unit takes its ducts at the top of
      // its casing ([MountingHeights.airUnitConnection] above its floor
      // surface, never above the ceiling main), not at the slab: the full
      // storey height used to ride every AHU duct as a phantom vertical leg.
      case NodeComponent.ahu:
      case NodeComponent.supplyFan:
      case NodeComponent.exhaustFan:
        final surface = nodeElevation(node, building, mounting).meters;
        final ceiling =
            building.ceilingElevationOf(node.floorIndex, mounting).meters;
        return Length(
            math.min(surface + mounting.airUnitConnection.meters, ceiling));
      default:
        break;
    }
  }
  return nodeElevation(node, building, mounting);
}

/// The VERTICAL leg of a RUN (m): the absolute difference between its two
/// endpoints' run-connection elevations ([runConnectionElevation] — a pump on
/// the floor surface, a main and a ceiling-hung diffuser / sprinkler at the
/// ceiling, a plumbing fixture at fixture height). A run drawn between a
/// ceiling main and a WC, or a floor-mounted pump and the ceiling main, rises
/// or drops by this much on site even though the plan only shows its
/// horizontal span. Zero for a riser (its whole length IS the elevation delta),
/// a broken edge, a run whose endpoints sit at one level, and every
/// GRAVITY-regime run (drainage / vent / rainwater): their `main` nodes carry
/// no below-slab datum yet (they resolve to the same floor's ceiling), so a
/// fixture-to-main leg there would be an upside-down fiction — the branch
/// quantity stays its calibrated horizontal span until gravity mains get a
/// real invert datum.
Length runVerticalLeg(
  NetEdge edge,
  Network net, {
  required BuildingLevels building,
  MountingHeights mounting = const MountingHeights(),
}) {
  if (edge.kind == EdgeKind.riser) return const Length(0);
  final a = net.nodeById(edge.fromId);
  final b = net.nodeById(edge.toId);
  if (a == null || b == null) return const Length(0);
  if (edge.service.regime == FlowRegime.gravity) {
    // Round 30 (mech-sim-4-rainwater-top-junction-under-slab) — the one
    // gravity exception: a ROOF DRAIN's leader run to a bare rainwater
    // junction drops from the roof (the drain sits ON it) to the junction's
    // under-slab datum ([gravityRiserEndElevation]). Without it the storey
    // between the roof and the top floor's under-slab datum was in no BOM /
    // riser length, while drawing the same downpipe as a riser counted it.
    // `// VERIFY` notAnSniClause (modelling datum, no invert model).
    if (edge.service != ServiceType.rainwater) return const Length(0);
    NetNode? drain, junction;
    for (final (x, y) in [(a, b), (b, a)]) {
      if (x.component == NodeComponent.roofDrain &&
          x.elevation == null &&
          x.mountHeight == null &&
          y.component == null &&
          y.role == NodeRole.main &&
          y.elevation == null &&
          y.mountHeight == null) {
        drain = x;
        junction = y;
      }
    }
    if (drain == null || junction == null) return const Length(0);
    final dz = (nodeElevation(drain, building, mounting).meters -
            gravityRiserEndElevation(
                    junction, building, mounting, ServiceType.rainwater)
                .meters)
        .abs();
    return Length(dz < 1e-6 ? 0 : dz);
  }
  final dz = (runConnectionElevation(b, building, mounting).meters -
          runConnectionElevation(a, building, mounting).meters)
      .abs();
  // Sub-millimetre float noise between two nodes on one level is not a leg.
  return Length(dz < 1e-6 ? 0 : dz);
}

/// Real length of [edge] from the §10 sources of truth: a run uses the
/// from-node sheet's calibration for its HORIZONTAL span PLUS its vertical leg
/// ([runVerticalLeg]) when its endpoints sit at different solved elevations
/// (pump → ceiling main, main → fixture drop); a riser/drop uses the
/// true-elevation delta of its endpoints (role-aware — ceiling main, fixture,
/// or plant). Neither part is ever measured from the PDF. The vertical leg is
/// pipe the installer pulls and friction the water sees, so every quantity
/// (BOM, run schedule, tags) and the friction term read it; the STATIC lift is
/// a separate additive term in the pressure solve, so it is not double
/// counted. Returns zero length for an uncalibrated run (its horizontal span
/// is unknown — never a partial vertical-only figure) or a broken edge.
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
    return riserElevationDelta(edge, a, b, building, mounting);
  }
  final cal = calibrationBySheet[a.sheetId];
  if (cal == null) return const Length(0);
  final horizontal = cal.lengthForPixels(runPixelLength(edge, net)).meters;
  final vertical =
      runVerticalLeg(edge, net, building: building, mounting: mounting).meters;
  return Length(horizontal + vertical);
}
