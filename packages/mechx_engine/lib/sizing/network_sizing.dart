/// Network sizing dispatcher — turns a drawn [Network] + demands into a sized
/// pipe/duct per edge, routing each edge to the correct §7 code path.
///
/// BRANCHING: [accumulateFlows] walks the (tree) network from a root and gives
/// every edge the sum of the demands DOWNSTREAM of it — so at a tee each branch
/// carries only its own subtree's load and is sized independently, while the
/// trunk carries the total. This is how branching ducts / pipes / drains size
/// correctly.
///
/// LOOPS: a component with more edges than (nodes − 1) has parallel paths whose
/// flow split a unique-path accumulation can't resolve. For PRESSURIZED and AIR
/// services [autoSizeNetwork] balances such a ring/grid with Hardy–Cross
/// (`hardy_cross.dart`) and sizes each edge from its share. Gravity services
/// keep the tree path (physical drainage rings are nonsensical).
///
/// Pure Dart, zero Flutter imports.
library;

import '../geometry/building.dart';
import '../geometry/scale_calibration.dart';
import '../hydraulics.dart';
import '../network/hardy_cross.dart';
import '../network/network.dart';
import '../standards/sni.dart';
import '../units.dart';
import 'drainage_sizing.dart' as drain;
import 'duct_sizing.dart' as duct;
import 'storm_sizing.dart' as storm;
import 'water_supply_sizing.dart' as water;

/// Default drainage fixture units assumed at a sanitary terminal that has no
/// assigned fixture type (≈ a lavatory-plus). // VERIFY against SNI 8153.
const double kDefaultLeafDfu = 2.0;

/// Duct cross-section shape and the sizing method used for air services.
enum DuctShape { round, rectangular }

enum DuctSizingMethod { velocity, equalFriction }

/// Design parameters shared across a sizing run.
class SizingContext {
  final Velocity maxSupplyVelocity;
  final Velocity maxDuctVelocity;
  final double drainageSlope; // m/m
  final double drainageFillRatio;
  final double drainageManningN;
  final PipeMaterial pipeMaterial;

  /// HVAC duct preferences.
  final DuctShape ductShape;
  final DuctSizingMethod ductMethod;
  final double ductEqualFrictionPa; // target Pa/m for the equal-friction method
  final double ductAspectRatio; // W:H for rectangular ducts

  /// Operating-point system-curve coefficients (design inputs for the
  /// equipment-curve × system-curve analysis in `operating_point.dart`). These
  /// are USER-PROVIDED design estimates — they are NEVER fitted from the solved
  /// network (a system-curve k is an INPUT, not an output). All default null; an
  /// absent value leaves the duty operating-point analysis off (byte-identical).
  ///
  /// - [systemHeadStatic]    — the pump system's fixed static lift/residual
  ///   (the H_static term of H_sys = H_static + k·Q²). // VERIFY.
  /// - [systemResistanceK]   — pump system resistance k (head per (m³/s)²).
  /// - [airSystemResistanceK]— fan/duct system resistance k (Pa per (m³/s)²).
  final Length? systemHeadStatic;
  final double? systemResistanceK;
  final double? airSystemResistanceK;

  const SizingContext({
    this.maxSupplyVelocity = const Velocity(2.0),
    this.maxDuctVelocity = const Velocity(5.0),
    this.drainageSlope = 0.01,
    this.drainageFillRatio = 0.5,
    this.drainageManningN = 0.010,
    this.pipeMaterial = PipeMaterial.pvc,
    this.ductShape = DuctShape.round,
    this.ductMethod = DuctSizingMethod.velocity,
    this.ductEqualFrictionPa = 1.0,
    this.ductAspectRatio = 1.5,
    this.systemHeadStatic,
    this.systemResistanceK,
    this.airSystemResistanceK,
  });
}

/// Sizing outcome for one edge.
///
/// [diameter] is the circular size, or the circular-equivalent for a
/// rectangular duct; [width]/[height] are set only for rectangular ducts.
class EdgeSizing {
  final String edgeId;
  final ServiceType service;
  final FlowRate flow;
  final Diameter diameter;
  final Velocity velocity;
  final Length? width;
  final Length? height;

  /// True when this edge's size was CLAMPED at the top of its selection table
  /// with the constraint it was sized against still VIOLATED. One flag, three
  /// sources — all meaning "the printed size is a table limit, not a valid
  /// selection; the caller must surface it as a per-edge design issue":
  ///
  ///  • **air** — no standard duct meets the velocity limit / friction target
  ///    (`DuctSizingResult.overCapacity` / `RectangularDuctResult.overCapacity`);
  ///  • **storm** — the catchment exceeds the largest tabulated downpipe
  ///    (`RainwaterSizingResult.overCapacity`, M3): the runoff must be split
  ///    across more downpipes;
  ///  • **water supply** — no DN in the series keeps the mean velocity within
  ///    the supply cap (`WaterSupplySizingResult.overVelocity`, M4): the pipe
  ///    ships over the `sniVerbatim` 2.0 m/s limit.
  ///
  /// Default false ⇒ in-range edges are byte-identical.
  final bool overCapacity;

  /// True when this is a drainage STACK (riser) edge whose own DFU-table
  /// diameter was raised to match a larger horizontal branch discharging into
  /// it (directly, or via a raised stack segment further up the same stack) —
  /// see [drain.drainDiameterForDfu]'s separate stack/branch tables (N17: the
  /// stack table is more generous, so a stack can size *smaller* than a branch
  /// carrying the identical DFU load, which is a code violation — no stack may
  /// be smaller than a branch connected to it). The caller surfaces this as a
  /// per-edge note ("stack raised to match branch"). Default false ⇒ an
  /// already-adequate stack is byte-identical.
  final bool stackRaisedForBranch;

  /// The edge endpoint the flow comes FROM (== [edgeId]'s owning [NetEdge]'s
  /// `fromId` or `toId`), i.e. the upstream node — a READ-ONLY orientation
  /// record for drawing a flow-direction arrow. NEVER affects any computed size
  /// or flow number. Null when direction cannot be confidently determined (e.g.
  /// a vent, a near-zero balanced ring edge). Default null ⇒ byte-identical.
  final String? flowFromId;

  /// M5 — false when this GRAVITY DRAINAGE edge's full-bore Manning velocity at
  /// the design slope falls below the self-cleansing minimum
  /// ([drain.kSelfCleansingVelocityMps], 0.6 m/s): solids drop out of
  /// suspension and the run silts up. The DFU path picks its diameter from a
  /// code capacity table (never through `drainage_sizing.sizeForFlow`), so this
  /// verdict was computed NOWHERE for a drawn sanitary network — a DN40/DN50
  /// branch at 1:100 runs at 0.46–0.54 m/s and was labelled OK.
  ///
  /// `true` for everything with no self-cleansing duty to fail: pressurized and
  /// air edges, and VENTS (they carry no flow at all). Rainwater downpipes are
  /// also left `true` — a vertical downpipe running ≈ 1/3 full is not a
  /// self-cleansing gravity run and its tabulated capacity carries no Manning
  /// velocity to judge; inventing one would be a fabricated verdict.
  ///
  /// Default true ⇒ every edge that cannot fail this check is byte-identical.
  final bool selfCleansingOk;

  /// M17 — true when this edge belongs to a LOOPED (ring/grid) component whose
  /// Hardy–Cross balance did NOT converge within its iteration budget
  /// (`LoopBalanceResult.converged` false). The carried [flow] is then the
  /// best-effort split at the last sweep: it still satisfies continuity at
  /// every node (the corrections are divergence-free), but the loop head-loss
  /// balance was not achieved, so the split — and every size derived from it —
  /// is provisional. Default false ⇒ trees and settled loops are
  /// byte-identical.
  final bool loopUnbalanced;

  const EdgeSizing({
    required this.edgeId,
    required this.service,
    required this.flow,
    required this.diameter,
    required this.velocity,
    this.width,
    this.height,
    this.overCapacity = false,
    this.stackRaisedForBranch = false,
    this.flowFromId,
    this.selfCleansingOk = true,
    this.loopUnbalanced = false,
  });

  /// True when this edge is a rectangular duct (carries W×H).
  bool get isRectangular => width != null && height != null;

  /// A copy carrying the given flow-direction origin ([flowFromId]); all sizing
  /// fields AND every design flag are preserved unchanged (this is metadata
  /// only).
  EdgeSizing withFlowFrom(String? fromId) => EdgeSizing(
        edgeId: edgeId,
        service: service,
        flow: flow,
        diameter: diameter,
        velocity: velocity,
        width: width,
        height: height,
        overCapacity: overCapacity,
        stackRaisedForBranch: stackRaisedForBranch,
        flowFromId: fromId,
        selfCleansingOk: selfCleansingOk,
        loopUnbalanced: loopUnbalanced,
      );

  /// A copy carrying the given [loopUnbalanced] verdict; all sizing fields and
  /// every other flag are preserved unchanged (M17 metadata only).
  EdgeSizing withLoopUnbalanced(bool value) => EdgeSizing(
        edgeId: edgeId,
        service: service,
        flow: flow,
        diameter: diameter,
        velocity: velocity,
        width: width,
        height: height,
        overCapacity: overCapacity,
        stackRaisedForBranch: stackRaisedForBranch,
        flowFromId: flowFromId,
        selfCleansingOk: selfCleansingOk,
        loopUnbalanced: value,
      );
}

/// Accumulate downstream demand onto every edge of [service], treating the
/// service subgraph as a tree rooted at [rootId]. [terminalDemand] maps node
/// ids to the demand introduced AT that node (fixtures, diffusers, drains).
/// Returns edgeId → flow (the total demand beyond that edge, away from root).
///
/// Assumes the service subgraph is acyclic (a distribution/collection tree);
/// cycles would need the P4 node solve instead.
/// When [edgeParent] is supplied it is filled with edgeId → the ROOT-SIDE
/// (parent) endpoint of that edge, so the caller can orient a flow arrow.
Map<String, FlowRate> accumulateFlows({
  required Network net,
  required ServiceType service,
  required String rootId,
  required Map<String, FlowRate> terminalDemand,
  Map<String, String>? edgeParent,
}) {
  final adjacency = <String, List<({String edgeId, String other})>>{};
  for (final e in net.edges) {
    if (e.service != service) continue;
    (adjacency[e.fromId] ??= []).add((edgeId: e.id, other: e.toId));
    (adjacency[e.toId] ??= []).add((edgeId: e.id, other: e.fromId));
  }

  final edgeFlow = <String, FlowRate>{};
  final visited = <String>{};

  // Post-order DFS: returns total demand in the subtree at [node].
  double subtreeDemand(String node) {
    visited.add(node);
    var sum = terminalDemand[node]?.cubicMetersPerSecond ?? 0.0;
    final links = adjacency[node];
    if (links != null) {
      for (final link in links) {
        if (visited.contains(link.other)) continue;
        final childDemand = subtreeDemand(link.other);
        edgeFlow[link.edgeId] = FlowRate(childDemand);
        edgeParent?[link.edgeId] = node; // [node] is the root-side endpoint
        sum += childDemand;
      }
    }
    return sum;
  }

  subtreeDemand(rootId);
  return edgeFlow;
}

/// Accumulate downstream fixture-unit (UBAP) load onto every edge of [service]
/// as a tree rooted at [rootId]. [terminalUnits] maps node ids to the fixture
/// units introduced AT that node. Returns edgeId → total UBAP carried by that
/// edge (the sum over the subtree on the far side from the root).
///
/// Water supply must be sized from ACCUMULATED fixture units passed through the
/// Hunter/UBAP demand curve (diversified simultaneous demand), NOT from a sum
/// of peak fixture flows — hence units are accumulated here and converted to a
/// flow per edge by the caller.
///
/// When [edgeParent] is supplied it is filled with edgeId → the ROOT-SIDE
/// (parent) endpoint of that edge, so the caller can orient a flow arrow.
Map<String, double> accumulateFixtureUnits({
  required Network net,
  required ServiceType service,
  required String rootId,
  required Map<String, double> terminalUnits,
  Map<String, String>? edgeParent,
}) {
  final adjacency = <String, List<({String edgeId, String other})>>{};
  for (final e in net.edges) {
    if (e.service != service) continue;
    (adjacency[e.fromId] ??= []).add((edgeId: e.id, other: e.toId));
    (adjacency[e.toId] ??= []).add((edgeId: e.id, other: e.fromId));
  }

  final edgeUnits = <String, double>{};
  final visited = <String>{};

  double subtreeUnits(String node) {
    visited.add(node);
    var sum = terminalUnits[node] ?? 0.0;
    final links = adjacency[node];
    if (links != null) {
      for (final link in links) {
        if (visited.contains(link.other)) continue;
        final child = subtreeUnits(link.other);
        edgeUnits[link.edgeId] = child;
        edgeParent?[link.edgeId] = node; // [node] is the root-side endpoint
        sum += child;
      }
    }
    return sum;
  }

  subtreeUnits(rootId);
  return edgeUnits;
}

/// Size one [edge] carrying [flow] via the correct §7 path (selected by the
/// edge's service regime — pressurized / air / gravity).
EdgeSizing sizeEdge(NetEdge edge, FlowRate flow, SizingContext ctx) {
  switch (edge.service.regime) {
    case FlowRegime.pressurized:
      final r = water.sizeForFlow(
        flow: flow,
        maxVelocity: ctx.maxSupplyVelocity,
        material: ctx.pipeMaterial,
      );
      return EdgeSizing(
        edgeId: edge.id,
        service: edge.service,
        flow: flow,
        diameter: r.diameter,
        velocity: r.velocity,
        // M4 — the largest DN in the series could not hold the mean velocity
        // within the supply cap; the pipe ships OVER the limit. Same semantics
        // as the air/storm clamp, so it rides the same per-edge flag.
        overCapacity: r.overVelocity,
      );
    case FlowRegime.air:
      if (ctx.ductShape == DuctShape.rectangular) {
        // Honour the equal-friction selection for rectangular too (not just
        // round) — velocity method keeps sizeRectangularByVelocity.
        // M2 — equal friction alone does not bound velocity, so the context's
        // duct velocity cap is threaded into the equal-friction ladder too.
        final r = ctx.ductMethod == DuctSizingMethod.equalFriction
            ? duct.sizeRectangularByEqualFriction(
                airflow: flow,
                targetPaPerMetre: ctx.ductEqualFrictionPa,
                aspectRatio: ctx.ductAspectRatio,
                maxVelocity: ctx.maxDuctVelocity,
              )
            : duct.sizeRectangularByVelocity(
                airflow: flow,
                maxVelocity: ctx.maxDuctVelocity,
                aspectRatio: ctx.ductAspectRatio,
              );
        return EdgeSizing(
          edgeId: edge.id,
          service: edge.service,
          flow: flow,
          diameter: r.equivalentDiameter,
          velocity: r.actualVelocity,
          width: r.width,
          height: r.height,
          overCapacity: r.overCapacity,
        );
      }
      // M2 — same cap threading for the round equal-friction ladder.
      final r = ctx.ductMethod == DuctSizingMethod.equalFriction
          ? duct.sizeByEqualFriction(
              airflow: flow,
              targetPaPerMetre: ctx.ductEqualFrictionPa,
              maxVelocity: ctx.maxDuctVelocity,
            )
          : duct.sizeByVelocity(
              airflow: flow,
              maxVelocity: ctx.maxDuctVelocity,
            );
      return EdgeSizing(
        edgeId: edge.id,
        service: edge.service,
        flow: flow,
        diameter: r.diameter,
        velocity: r.actualVelocity,
        overCapacity: r.overCapacity,
      );
    case FlowRegime.gravity:
      final r = drain.sizeForFlow(
        flow: flow,
        slope: ctx.drainageSlope,
        fillRatio: ctx.drainageFillRatio,
        manningN: ctx.drainageManningN,
      );
      return EdgeSizing(
        edgeId: edge.id,
        service: edge.service,
        flow: flow,
        diameter: r.diameter,
        velocity: r.fullBoreVelocity,
        // M5 — a VENT carries no flow, so it has no self-cleansing duty to
        // fail; every other gravity run reports the sizer's own verdict.
        selfCleansingOk:
            edge.service == ServiceType.vent ? true : r.selfCleansing,
      );
  }
}

/// Apply a manual nominal-size [override] to an auto-computed [sizing],
/// returning a new [EdgeSizing] that carries the same flow but the overridden
/// circular diameter. The clear width/height are dropped (the override is a
/// single circular nominal size). Pure.
///
/// **Velocity** is recomputed for the overridden diameter on the same basis the
/// auto-sizer used for that service (M18):
///  • a VENT carries no flow ⇒ 0, as before;
///  • DRAINAGE reports the full-bore MANNING velocity at [ctx]'s design slope
///    and Manning n — a sanitary edge carries a placeholder `flow` of 0 (it is
///    sized from DFU, not flow), so the continuity formula returned a
///    meaningless 0 m/s for every drainage override and silently voided the
///    self-cleansing verdict with it. Without a [ctx] there is no slope to
///    compute Manning from, so the legacy continuity value is kept;
///  • everything else keeps v = Q / A at the overridden diameter (continuity).
///
/// **Design flags** ([EdgeSizing.overCapacity],
/// [EdgeSizing.stackRaisedForBranch], [EdgeSizing.loopUnbalanced]) are
/// PRESERVED across the override — they record findings about the network and
/// the auto-selection (an over-loaded catchment, a stack raised to match its
/// branch, an unsettled ring), which picking a size by hand does not retract.
/// [EdgeSizing.selfCleansingOk] is the exception: it is a property OF THE
/// CHOSEN DIAMETER, so it is re-judged at the overridden size whenever the
/// velocity was re-derived on the drainage basis (a larger hand-picked pipe at
/// the same slope genuinely runs slower).
///
/// G1 — [codeMinimum] is the smallest diameter the DFU capacity table allows
/// for this edge's load (what the auto-sizer picked). When the override is AT
/// or BELOW it, the run is already on the smallest compliant pipe: a
/// self-cleansing shortfall there is not actionable BY PIPE (the only levers
/// are the laid slope and the discharge grouped onto the branch), so the flag
/// stays true — the same gate the DFU path itself applies (see
/// [_sanitaryEdgeSizing]). Default null ⇒ the pure velocity verdict, i.e.
/// byte-identical for every existing caller.
EdgeSizing applySizeOverride(
  EdgeSizing sizing,
  Diameter override, {
  SizingContext? ctx,
  Diameter? codeMinimum,
}) {
  final isDrainage = sizing.service == ServiceType.drainage;
  final bool manningBasis = isDrainage && ctx != null && override.meters > 0;

  final Velocity velocity;
  if (override.meters <= 0) {
    velocity = const Velocity(0);
  } else if (sizing.service == ServiceType.vent) {
    velocity = const Velocity(0); // a vent carries no flow
  } else if (manningBasis) {
    velocity = manningVelocity(
      manningN: ctx.drainageManningN,
      hydraulicRadius: Length(override.meters / 4.0),
      slope: ctx.drainageSlope,
    );
  } else {
    // v = Q / A at the overridden diameter (continuity); see velocityFromFlow.
    velocity = velocityFromFlow(sizing.flow, override);
  }

  return EdgeSizing(
    edgeId: sizing.edgeId,
    service: sizing.service,
    flow: sizing.flow,
    diameter: override,
    velocity: velocity,
    overCapacity: sizing.overCapacity,
    stackRaisedForBranch: sizing.stackRaisedForBranch,
    flowFromId: sizing.flowFromId,
    selfCleansingOk: manningBasis
        ? (velocity.metersPerSecond >= drain.kSelfCleansingVelocityMps ||
            (codeMinimum != null &&
                override.meters <= codeMinimum.meters + _kDiameterEpsM))
        : sizing.selfCleansingOk,
    loopUnbalanced: sizing.loopUnbalanced,
  );
}

/// Size every edge that has an accumulated [edgeFlows] entry. Edges with no
/// flow (not reached from a root / no demand) are skipped. An edge id present
/// in [sizeOverrides] keeps its carried flow but uses the overridden diameter,
/// with velocity recomputed from that flow ([applySizeOverride]).
Map<String, EdgeSizing> sizeNetwork(
  Network net,
  Map<String, FlowRate> edgeFlows,
  SizingContext ctx, {
  Map<String, Diameter> sizeOverrides = const {},
}) {
  final result = <String, EdgeSizing>{};
  for (final edge in net.edges) {
    final flow = edgeFlows[edge.id];
    if (flow == null) continue;
    final sized = sizeEdge(edge, flow, ctx);
    final override = sizeOverrides[edge.id];
    result[edge.id] =
        override == null ? sized : applySizeOverride(sized, override, ctx: ctx);
  }
  return result;
}

/// Auto-size the whole drawn network with a default demand policy: per service,
/// split into connected components, root each at its SOURCE (a plant, else a
/// non-demand entry leaf), apply demand at every other demand-bearing node
/// (terminals plus any inline fixture/diffuser), accumulate down the branches,
/// and size every edge. Branching is handled exactly (each leg sized for its
/// own subtree, the source connection for the total); edges with no demand are
/// left unsized.
///
/// Demand model per service:
///   • Water supply (cold/hot) with an entry in [leafFixtureUnits]: accumulate
///     fixture UNITS down the tree and convert each edge's total via the
///     Hunter/UBAP curve ([flushSystem]) — diversified simultaneous demand,
///     NOT a sum of peak fixture flows.
///   • Everything else (or water without fixture-unit data): accumulate the
///     flat [leafDemand] flows.
///
/// LOOPS: a looped pressurized/air component is split with Hardy–Cross instead,
/// using resistance ∝ edge LENGTH at a consistent ring diameter (the stable,
/// standard basis — iterating resistance against velocity-sized diameters is
/// unstable, see the inline note). Pass [building] + [calibrationBySheet] so the
/// split uses REAL edge lengths (runs via calibration, risers via elevation
/// delta); without them it falls back to calibration-invariant pixel length.
/// Per-edge manual nominal-size overrides ([sizeOverrides], edgeId → diameter):
/// an edge with an entry keeps its accumulated flow but is sized to the given
/// diameter, with velocity recomputed from that flow ([applySizeOverride]).
/// Default empty ⇒ byte-identical behaviour to before.
Map<String, EdgeSizing> autoSizeNetwork(
  Network net,
  SizingContext ctx, {
  required Map<ServiceType, FlowRate> leafDemand,
  Map<ServiceType, double> leafFixtureUnits = const {},
  Map<String, double> nodeFixtureUnits = const {},
  Map<String, double> nodeDrainageUnits = const {},
  Map<String, FlowRate> nodeFlowDemand = const {},
  Map<String, Diameter> sizeOverrides = const {},
  FlushSystem flushSystem = FlushSystem.flushTank,
  BuildingLevels? building,
  Map<String, ScaleCalibration> calibrationBySheet = const {},
}) {
  const profile = SniProfile();
  final allFlows = <String, FlowRate>{};
  final sanitary = <String, EdgeSizing>{}; // DFU-sized drainage/vent edges
  final stormSizing = <String, EdgeSizing>{}; // rainwater downpipes
  // M17 — edges of any looped component whose Hardy–Cross balance did NOT
  // converge; their flow split (and every size derived from it) is provisional.
  final loopUnbalancedEdges = <String>{};

  // Read-only flow orientation per edge (edgeId → the endpoint flow comes FROM).
  // Populated below where direction is confidently known; attached to the final
  // sizings without ever altering a size/flow. Absent ⇒ EdgeSizing.flowFromId
  // stays null (byte-identical for callers that ignore it). A supply edge points
  // AWAY from the source (root → demand); a gravity edge points TOWARD the
  // collection root (demand → root); a vent carries no flow → left null.
  final edgeFlowFrom = <String, String>{};

  bool isWaterSupply(ServiceType s) =>
      s == ServiceType.coldWater || s == ServiceType.hotWater;
  bool isSanitary(ServiceType s) =>
      s == ServiceType.drainage || s == ServiceType.vent;

  for (final service in net.edges.map((e) => e.service).toSet()) {
    final demand = leafDemand[service] ?? const FlowRate(0);
    final useUbap =
        isWaterSupply(service) && leafFixtureUnits.containsKey(service);
    final fuPerLeaf = leafFixtureUnits[service] ?? 0.0;

    final adjacency = <String, List<({String edgeId, String other})>>{};
    final nodes = <String>{};
    for (final e in net.edges) {
      if (e.service != service) continue;
      nodes..add(e.fromId)..add(e.toId);
      (adjacency[e.fromId] ??= []).add((edgeId: e.id, other: e.toId));
      (adjacency[e.toId] ??= []).add((edgeId: e.id, other: e.fromId));
    }

    int degree(String n) => adjacency[n]?.length ?? 0;
    NodeRole? roleOf(String n) => net.nodeById(n)?.role;

    // The explicit per-node demand keys relevant to THIS service decide which
    // nodes "bear demand" (and so must not be chosen as the source root).
    final explicitDemandKeys = isSanitary(service)
        ? nodeDrainageUnits.keys.toSet()
        : useUbap
            ? nodeFixtureUnits.keys.toSet()
            : nodeFlowDemand.keys.toSet();

    // Pick the root (= source/sink) for a component. Accumulation gives every
    // edge the demand on its far side from the root, so the root's own demand
    // never traverses an edge — the root MUST therefore be a node that carries
    // no terminal load, or that load would silently vanish. Preference:
    //   1. an explicit plant (the marked source/sink);
    //   2. a non-fixture leaf bearing no demand (the drawn supply/outlet entry);
    //   3. the busiest interior junction bearing no demand (a manifold/collection
    //      hub — rooting here keeps EVERY terminal's load, whereas falling back
    //      to a fixture leaf would drop that fixture's demand);
    //   4. any leaf, else any node (degenerate component).
    String pickRoot(List<String> component, List<String> leaves) {
      for (final id in component) {
        if (roleOf(id) == NodeRole.plant) return id;
      }
      for (final id in leaves) {
        if (roleOf(id) != NodeRole.fixture && !explicitDemandKeys.contains(id)) {
          return id;
        }
      }
      String? hub;
      var hubDegree = 1;
      for (final id in component) {
        final d = degree(id);
        if (d > hubDegree &&
            roleOf(id) != NodeRole.fixture &&
            !explicitDemandKeys.contains(id)) {
          hub = id;
          hubDegree = d;
        }
      }
      if (hub != null) return hub;
      return leaves.isNotEmpty ? leaves.first : component.first;
    }

    // Build the terminal-demand map over EVERY demand-bearing node except the
    // root: a node with an explicit entry contributes it (even mid-run — an
    // inline fixture/diffuser is a degree-2 node), and a leaf with no entry
    // contributes the flat default. Pure interior junctions contribute nothing.
    Map<String, V> terminalMap<V>(
      List<String> component,
      String root,
      Map<String, V> explicit,
      V defaultForLeaf,
    ) {
      final out = <String, V>{};
      for (final n in component) {
        if (n == root) continue;
        final e = explicit[n];
        if (e != null) {
          out[n] = e;
        } else if (degree(n) == 1) {
          out[n] = defaultForLeaf;
        }
      }
      return out;
    }

    final seen = <String>{};
    for (final start in nodes) {
      if (seen.contains(start)) continue;
      // Collect this connected component.
      final component = <String>[];
      final stack = [start];
      seen.add(start);
      while (stack.isNotEmpty) {
        final n = stack.removeLast();
        component.add(n);
        final links = adjacency[n];
        if (links != null) {
          for (final link in links) {
            if (seen.add(link.other)) stack.add(link.other);
          }
        }
      }
      final leaves = component.where((n) => degree(n) == 1).toList();
      final root = pickRoot(component, leaves);

      // ── Looped (ring/grid) PRESSURIZED or AIR component → Hardy–Cross ───────
      // A tree has (nodes − 1) edges; more means parallel paths whose flow split
      // the unique-path accumulation can't resolve. Balance the split with
      // Hardy–Cross and size each edge from its share. Gravity services
      // (drainage/vent/rainwater) keep the tree path — physical rings there are
      // nonsensical.
      //
      // The split uses resistance ∝ EDGE LENGTH at a consistent ring diameter
      // (standard ring-main practice). We deliberately do NOT iterate resistance
      // against the sized-to-velocity diameters: with D ∝ √Q the Hazen–Williams
      // resistance becomes k ∝ L·Q^−2.435, so head loss h_f ∝ L·Q^−0.583
      // DECREASES with flow — an unstable equilibrium that drives the longer leg
      // to zero. The length split is the stable, standard design basis.
      //
      // L is the REAL length when geometry is supplied — runs via calibration,
      // RISERS via the §10 elevation delta — else the calibration-invariant
      // pixel length (riser → nominal connector).
      final componentSet = component.toSet();
      final componentEdges = net.edges
          .where((e) =>
              e.service == service &&
              componentSet.contains(e.fromId) &&
              componentSet.contains(e.toId))
          .toList();
      final isLooped = componentEdges.length > component.length - 1;
      final regime = service.regime;
      if (isLooped &&
          (regime == FlowRegime.pressurized || regime == FlowRegime.air)) {
        final demandFlow = <String, double>{};
        if (useUbap) {
          // Water supply: diversify the COMBINED fixture-unit load through the
          // Hunter/UBAP curve ONCE for the whole ring (mirrors the tree path —
          // accumulate units, then curve), then split the diversified total by
          // each node's UBAP share so Hardy–Cross balances the same spatial
          // distribution. Curving each node's units individually and summing
          // would over-size the ring (the curve is concave: Σf(uᵢ) > f(Σuᵢ)).
          final nodeUbap = <String, double>{};
          var totalUbap = 0.0;
          for (final n in component) {
            if (n == root) continue;
            final ubap = nodeFixtureUnits[n] ?? (degree(n) == 1 ? fuPerLeaf : 0.0);
            if (ubap > 0) {
              nodeUbap[n] = ubap;
              totalUbap += ubap;
            }
          }
          if (totalUbap > 0) {
            final totalFlow = profile
                .probableFlowForFixtureUnits(totalUbap, system: flushSystem)
                .cubicMetersPerSecond;
            for (final entry in nodeUbap.entries) {
              demandFlow[entry.key] = totalFlow * (entry.value / totalUbap);
            }
          }
        } else {
          for (final n in component) {
            if (n == root) continue;
            final explicit = nodeFlowDemand[n];
            final f = explicit != null
                ? explicit.cubicMetersPerSecond
                : (degree(n) == 1 ? demand.cubicMetersPerSecond : 0.0);
            if (f != 0) demandFlow[n] = f;
          }
        }

        final lengthById = <String, double>{
          for (final e in componentEdges)
            e.id: () {
              if (building != null) {
                final l = edgeLength(
                  e,
                  net,
                  calibrationBySheet: calibrationBySheet,
                  building: building,
                ).meters;
                if (l > 0) return l;
              }
              final px = runPixelLength(e, net); // 0 for a riser
              return px > 1.0 ? px : 1.0;
            }(),
        };
        final balanced = balanceFlows(
          edges: [
            for (final e in componentEdges)
              (id: e.id, from: e.fromId, to: e.toId),
          ],
          root: root,
          demand: demandFlow,
          resistance: (id) => lengthById[id]!,
          exponent: regime == FlowRegime.air ? 2.0 : 1.852,
        );
        for (final entry in balanced.edgeFlow.entries) {
          allFlows[entry.key] = FlowRate(entry.value.abs());
        }
        // M17 — record a best-effort (unsettled) split instead of presenting it
        // as balanced. Continuity still holds, so the sizes are usable; the
        // loop head-loss balance is what was not achieved.
        if (!balanced.converged) {
          for (final e in componentEdges) {
            loopUnbalancedEdges.add(e.id);
          }
        }
        // Orient each ring edge from the balanced flow SIGN (positive = from→to,
        // per LoopBalanceResult); a near-zero edge stays undirected (null).
        for (final e in componentEdges) {
          final q = balanced.edgeFlow[e.id] ?? 0.0;
          if (q > 1e-12) {
            edgeFlowFrom[e.id] = e.fromId;
          } else if (q < -1e-12) {
            edgeFlowFrom[e.id] = e.toId;
          }
        }
        continue;
      }

      if (isSanitary(service)) {
        // Accumulate DRAINAGE FIXTURE UNITS and size each edge from the code
        // capacity table (branch vs stack), not from Manning flow.
        final terminalUnits =
            terminalMap(component, root, nodeDrainageUnits, kDefaultLeafDfu);
        final edgeParents = <String, String>{};
        final edgeUnits = accumulateFixtureUnits(
          net: net,
          service: service,
          rootId: root,
          terminalUnits: terminalUnits,
          edgeParent: edgeParents,
        );
        for (final entry in edgeUnits.entries) {
          final edge = net.edges.firstWhere((e) => e.id == entry.key);
          sanitary[entry.key] = _sizeSanitaryEdge(edge, entry.value, ctx);
          // Drainage flows DOWNHILL toward the collection root, so it comes FROM
          // the away-from-root (demand) endpoint. A vent carries no flow → skip.
          if (edge.service == ServiceType.drainage) {
            final parent = edgeParents[entry.key];
            if (parent != null) {
              edgeFlowFrom[entry.key] =
                  parent == edge.fromId ? edge.toId : edge.fromId;
            }
          }
        }
        // N17 — a stack must never size smaller than a branch discharging
        // into it (two different DFU tables can otherwise disagree). Only
        // meaningful for drainage (vent has one DFU table; this `service`
        // iteration is single-service, so a vent pass is a no-op here).
        if (service == ServiceType.drainage) {
          _clampDrainageStacksToBranches(
            net: net,
            sanitary: sanitary,
            edgeParents: edgeParents,
            ctx: ctx,
          );
        }
      } else if (service == ServiceType.rainwater) {
        // Accumulate storm runoff and size each downpipe from the rainwater
        // capacity table (not Manning).
        final terminalDemand =
            terminalMap(component, root, nodeFlowDemand, demand);
        final edgeParents = <String, String>{};
        final flows = accumulateFlows(
          net: net,
          service: service,
          rootId: root,
          terminalDemand: terminalDemand,
          edgeParent: edgeParents,
        );
        for (final entry in flows.entries) {
          final r = storm.sizeRainwaterDownpipe(entry.value);
          stormSizing[entry.key] = EdgeSizing(
            edgeId: entry.key,
            service: service,
            flow: entry.value,
            diameter: r.diameter,
            velocity: velocityFromFlow(entry.value, r.diameter),
            // M3 — the catchment exceeds the largest tabulated downpipe: the
            // DN200 shown is the table top, not a size that carries the flow.
            // The runoff must be split across more downpipes.
            overCapacity: r.overCapacity,
          );
          // Storm runoff drains TOWARD the outlet root, so it comes FROM the
          // away-from-root (roof-drain) endpoint.
          final parent = edgeParents[entry.key];
          if (parent != null) {
            final edge = net.edges.firstWhere((e) => e.id == entry.key);
            edgeFlowFrom[entry.key] =
                parent == edge.fromId ? edge.toId : edge.fromId;
          }
        }
      } else if (useUbap) {
        // Per-fixture UBAP when a node carries a fixture type; else the flat
        // default for that water service.
        final terminalUnits =
            terminalMap(component, root, nodeFixtureUnits, fuPerLeaf);
        final edgeParents = <String, String>{};
        final edgeUnits = accumulateFixtureUnits(
          net: net,
          service: service,
          rootId: root,
          terminalUnits: terminalUnits,
          edgeParent: edgeParents,
        );
        for (final entry in edgeUnits.entries) {
          allFlows[entry.key] = profile.probableFlowForFixtureUnits(
            entry.value,
            system: flushSystem,
          );
          // Supply flows AWAY from the source root, so it comes FROM the
          // root-side (parent) endpoint.
          final parent = edgeParents[entry.key];
          if (parent != null) edgeFlowFrom[entry.key] = parent;
        }
      } else {
        // Per-node flow where set (e.g. a diffuser's airflow); else the flat
        // default for the service.
        final terminalDemand =
            terminalMap(component, root, nodeFlowDemand, demand);
        final edgeParents = <String, String>{};
        allFlows.addAll(
          accumulateFlows(
            net: net,
            service: service,
            rootId: root,
            terminalDemand: terminalDemand,
            edgeParent: edgeParents,
          ),
        );
        // Supply/air flows AWAY from the source root → comes FROM the root-side
        // (parent) endpoint.
        edgeFlowFrom.addAll(edgeParents);
      }
    }
  }

  final result = sizeNetwork(net, allFlows, ctx, sizeOverrides: sizeOverrides);
  // DFU-sized drainage/vent and capacity-table rainwater downpipes are built
  // directly (not via sizeNetwork), so apply any override to them here too.
  for (final entry in sanitary.entries) {
    final override = sizeOverrides[entry.key];
    result[entry.key] = override == null
        ? entry.value
        // G1 — the auto pick IS the code minimum for this edge's load, so a
        // hand pick at or below it keeps the (unactionable-by-pipe) verdict
        // true; only an OVERSIZED pick is judged on velocity alone.
        : applySizeOverride(entry.value, override,
            ctx: ctx, codeMinimum: entry.value.diameter);
  }
  for (final entry in stormSizing.entries) {
    final override = sizeOverrides[entry.key];
    result[entry.key] = override == null
        ? entry.value
        : applySizeOverride(entry.value, override, ctx: ctx);
  }
  // M17 — a ring/grid whose Hardy–Cross balance never settled: every edge of
  // that component carries a PROVISIONAL split, so mark them all (after the
  // overrides, which preserve the flag either way).
  for (final id in loopUnbalancedEdges) {
    final sized = result[id];
    if (sized != null) result[id] = sized.withLoopUnbalanced(true);
  }
  // Attach the read-only flow orientation last (after overrides), so the arrow
  // record survives an override without touching any computed size/flow.
  for (final id in edgeFlowFrom.keys) {
    final sized = result[id];
    if (sized != null) result[id] = sized.withFlowFrom(edgeFlowFrom[id]);
  }
  return result;
}

/// Build an [EdgeSizing] for a drainage/vent edge from its accumulated [dfu]
/// using the code capacity tables. Drainage edges report a reference full-bore
/// Manning velocity (for self-cleansing); vents have no flow velocity.
EdgeSizing _sizeSanitaryEdge(NetEdge edge, double dfu, SizingContext ctx) {
  final isStack = edge.kind == EdgeKind.riser;
  final Diameter d = edge.service == ServiceType.vent
      ? drain.ventDiameterForDfu(dfu)
      : drain.drainDiameterForDfu(dfu, isStack: isStack);
  // The table pick IS the code minimum for this load, so an auto-sized sanitary
  // run is never flagged as not-self-cleansing (G1) — there is no smaller
  // compliant pipe to move to.
  return _sanitaryEdgeSizing(edge, d, ctx, codeMinimum: d);
}

/// Build the [EdgeSizing] for a sanitary (drainage/vent) [edge] at an already-
/// chosen [diameter] (either the raw DFU-table pick, or a diameter raised by
/// [_clampDrainageStacksToBranches]). Factored out of [_sizeSanitaryEdge] so
/// the stack/branch clamp can rebuild a stack's sizing at its raised diameter
/// without duplicating the velocity computation.
EdgeSizing _sanitaryEdgeSizing(
  NetEdge edge,
  Diameter diameter,
  SizingContext ctx, {
  bool stackRaisedForBranch = false,
  required Diameter codeMinimum,
}) {
  final isVent = edge.service == ServiceType.vent;
  final v = isVent
      ? const Velocity(0)
      : manningVelocity(
          manningN: ctx.drainageManningN,
          hydraulicRadius: Length(diameter.meters / 4.0),
          slope: ctx.drainageSlope,
        );
  return EdgeSizing(
    edgeId: edge.id,
    service: edge.service,
    flow: const FlowRate(0),
    diameter: diameter,
    velocity: v,
    stackRaisedForBranch: stackRaisedForBranch,
    // M5 — the DFU path picks its diameter from a code capacity table, so the
    // self-cleansing verdict (the reason the reference Manning velocity above
    // is computed at all) was never actually formed. A vent carries no flow ⇒
    // no self-cleansing duty ⇒ true.
    //
    // G1 — …but the verdict is only raised when the CHOSEN diameter EXCEEDS
    // [codeMinimum], the smallest diameter the capacity table allows for this
    // load (the auto pick, or the N17-raised stack size — both are the code
    // minimum FOR THIS EDGE). At the minimum a shortfall is unactionable by
    // pipe: every smaller pipe is non-compliant, so the advisory could only
    // name a remedy the code forbids. The real levers there (the laid slope,
    // the discharge grouped onto the branch) are separate inputs, carried by
    // the app's own advisory copy and by `drainage_advisory.dart`'s min-slope
    // check — so a code-minimum run is reported honestly as OK-by-pipe, and a
    // hand-picked OVERSIZED run (which genuinely runs slower for no code
    // reason) is the case that flags.
    selfCleansingOk: isVent ||
        v.metersPerSecond >= drain.kSelfCleansingVelocityMps ||
        diameter.meters <= codeMinimum.meters + _kDiameterEpsM,
  );
}

/// Floating-point slack (metres) for comparing two nominal diameters — a
/// tolerance well under the smallest step in any nominal series (32→40 mm).
const double _kDiameterEpsM = 1e-9;

/// N17 — a drainage STACK (riser) segment must never be smaller than a
/// horizontal branch discharging into it. Branch and stack diameters come
/// from two DIFFERENT DFU capacity tables (the stack table is more generous —
/// a vertical stack self-cleanses better than a horizontal run), so a stack
/// segment can legitimately DFU-size *smaller* than a branch carrying the
/// identical load (e.g. DFU 20 ⇒ a DN65 stack vs a DN75 branch) even though
/// accumulated DFU only grows toward the root — the code violation is real,
/// not a sizing-order artifact.
///
/// For every drainage riser edge, raise its diameter to at least the largest
/// of: its own DFU-table diameter, any branch (non-riser) edge discharging
/// directly at its away-from-root node, and the (already-raised) diameter of
/// any further riser segment continuing the stack above that same node — so a
/// raise made high in the stack also propagates DOWN toward the root and a
/// lower segment never necks down below a raised segment above it. [sanitary]
/// is mutated in place; [edgeParents] is the edgeId → root-side-node map
/// [accumulateFixtureUnits] filled for this same (single-service, single-
/// component) pass. Only meaningful for [ServiceType.drainage] — vents use one
/// DFU table (no stack/branch split) and rainwater downpipes use one capacity
/// table over the same monotonically-accumulated flow, so neither can exhibit
/// this particular two-table mismatch and neither is touched here.
void _clampDrainageStacksToBranches({
  required Network net,
  required Map<String, EdgeSizing> sanitary,
  required Map<String, String> edgeParents,
  required SizingContext ctx,
}) {
  // node → edges rooted there, i.e. edges whose ROOT-SIDE endpoint is this
  // node (the continuations AWAY from root passing through it — the stack
  // segment(s) and/or branch(es) immediately upstream of this junction).
  final childEdgesAt = <String, List<String>>{};
  for (final entry in edgeParents.entries) {
    (childEdgesAt[entry.value] ??= []).add(entry.key);
  }

  String awayNodeOf(NetEdge e) {
    final rootSide = edgeParents[e.id];
    return e.fromId == rootSide ? e.toId : e.fromId;
  }

  final memo = <String, double>{};
  double effectiveMm(String edgeId) {
    final cached = memo[edgeId];
    if (cached != null) return cached;
    final edge = net.edgeById(edgeId)!;
    var maxMm = sanitary[edgeId]!.diameter.inMillimeters;
    for (final childId in childEdgesAt[awayNodeOf(edge)] ?? const <String>[]) {
      final child = net.edgeById(childId);
      if (child == null || child.service != ServiceType.drainage) continue;
      final childMm = child.kind == EdgeKind.riser
          ? effectiveMm(childId)
          : sanitary[childId]!.diameter.inMillimeters;
      if (childMm > maxMm) maxMm = childMm;
    }
    memo[edgeId] = maxMm;
    return maxMm;
  }

  for (final edgeId in edgeParents.keys) {
    final edge = net.edgeById(edgeId);
    if (edge == null ||
        edge.kind != EdgeKind.riser ||
        edge.service != ServiceType.drainage) {
      continue;
    }
    final base = sanitary[edgeId]!.diameter.inMillimeters;
    final effective = effectiveMm(edgeId);
    if (effective > base) {
      sanitary[edgeId] = _sanitaryEdgeSizing(
        edge,
        Diameter.mm(effective),
        ctx,
        stackRaisedForBranch: true,
        // The N17 raise is code-MANDATED, so the raised size IS this segment's
        // code minimum (G1): necking back down to its own DFU-table pick is
        // exactly the violation the clamp exists to prevent.
        codeMinimum: Diameter.mm(effective),
      );
    }
  }
}
