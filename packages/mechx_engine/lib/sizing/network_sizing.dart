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

import 'dart:collection' show SplayTreeSet;
import 'dart:math' as math;

import '../geometry/building.dart';
import '../geometry/scale_calibration.dart';
import '../hydraulics.dart';
import '../network/hardy_cross.dart';
import '../network/network.dart';
import '../standards/sni.dart';
import '../units.dart';
import 'drainage_advisory.dart' show effectiveDrainageSlope, laidGravitySlope;
import 'drainage_sizing.dart' as drain;
import 'duct_sizing.dart' as duct;
import 'ejector.dart' as ejector;
import 'fire_sprinkler.dart' show kMinSprinklerPipeDiameterMm;
import 'fire_standpipe.dart'
    show
        kMaxFireVelocityMps,
        kMinHydrantBranchDiameterMm,
        kMinRiserDiameterMm,
        parallelStandpipeCount,
        standpipeFlow;
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

  /// Round 21 — the velocity cap for the FIRE services (sprinkler / hydrant),
  /// [kMaxFireVelocityMps] by default; the domestic [maxSupplyVelocity] no
  /// longer sizes fire pipe 1-2 DN up. `// VERIFY` notAnSniClause.
  final Velocity maxFireVelocity;
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
    this.maxFireVelocity = const Velocity(kMaxFireVelocityMps),
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
  /// velocity to judge; inventing one would be a fabricated verdict. A sloped
  /// HORIZONTAL rainwater collector, however, IS sized by Manning
  /// (water-drainage-2), so it carries that sizer's own verdict.
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

  /// Audit 2026-10 water-drainage-6 — true when this WATER-SUPPLY edge's
  /// fixture-unit load lies beyond the last charted point of the demand curve
  /// (`SniProfile.demandCurveExceeded`, > 3000 UBAP), so its [flow] is a LINEAR
  /// EXTRAPOLATION of the curve, not a curve read-off — an engineer-review
  /// flag. Default false ⇒ every in-range edge is byte-identical.
  final bool demandCurveExtrapolated;

  /// Round 17 (gravity-3-1) — true when a HAND-PICKED size ([applySizeOverride]
  /// with a `minimumCompliant` diameter) on a GRAVITY edge (drain / vent / storm)
  /// is SMALLER than the smallest size the code tables allow for its load: the
  /// DFU / WC-count / trap floor for a sanitary edge, the downpipe-table or
  /// usable part-full Manning capacity for a rainwater edge. The auto pick IS
  /// that minimum, so the hand pick under-sizes a code-governed pipe. A
  /// distinct flag from [overCapacity] (whose action — split the load — would
  /// be wrong here; the action is "pick a larger size or clear the override").
  /// Default false ⇒ every auto-sized / up-sized edge is byte-identical.
  final bool belowCodeMinimum;

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
    this.demandCurveExtrapolated = false,
    this.belowCodeMinimum = false,
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
        demandCurveExtrapolated: demandCurveExtrapolated,
        belowCodeMinimum: belowCodeMinimum,
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
        demandCurveExtrapolated: demandCurveExtrapolated,
        belowCodeMinimum: belowCodeMinimum,
      );

  /// A copy carrying the given [demandCurveExtrapolated] verdict; every other
  /// field and flag is preserved unchanged (water-drainage-6 metadata only).
  EdgeSizing withDemandCurveExtrapolated(bool value) => EdgeSizing(
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
        loopUnbalanced: loopUnbalanced,
        demandCurveExtrapolated: value,
        belowCodeMinimum: belowCodeMinimum,
      );

  /// Round 25 — a copy carrying the given [stackRaisedForBranch] /
  /// [belowCodeMinimum] verdicts; every other field preserved.
  EdgeSizing withGravityFlags({bool? raised, bool? belowMinimum}) => EdgeSizing(
        edgeId: edgeId,
        service: service,
        flow: flow,
        diameter: diameter,
        velocity: velocity,
        width: width,
        height: height,
        overCapacity: overCapacity,
        stackRaisedForBranch: raised ?? stackRaisedForBranch,
        flowFromId: flowFromId,
        selfCleansingOk: selfCleansingOk,
        loopUnbalanced: loopUnbalanced,
        demandCurveExtrapolated: demandCurveExtrapolated,
        belowCodeMinimum: belowMinimum ?? belowCodeMinimum,
      );
}

/// The deterministic SPANNING TREE of [service]'s subgraph reachable from
/// [rootId] (Round 12, mech-props-2 gravity-loop / recirc-checkvalve).
///
/// Breadth-first with every node's links sorted by EDGE ID, so the tree — and
/// hence every accumulated load — depends only on the drawn data, never on
/// the order edges were added (the old recursive DFS let the drawing order
/// decide which edge of a gravity loop went unvisited). On a TREE the result
/// is identical to any traversal (paths are unique). On a LOOP each node
/// drains to the root along its fewest-hops path (ties to the lower edge id),
/// i.e. nearest-outlet assignment, and the edges left out are the loop's
/// CLOSING edges — the caller sizes them (see [autoSizeNetwork]).
///
/// [deferredEdgeIds] are traversed only to reach nodes no other edge reaches
/// (a check-valve directional cut: the recirc return never becomes a parallel
/// supply path). Returns the BFS [order] (root first) and each non-root
/// node's parent link.
///
/// [extraRootIds] (Round 15) seed the breadth-first search alongside
/// [rootId] — a gravity component with SEVERAL outfalls (two downpipes off
/// one roof collector): every node drains to its NEAREST outfall, and the
/// collector splits at the drainage divide.
({
  List<String> order,
  Map<String, ({String edgeId, String parent})> parentOf,
}) serviceSpanningTree({
  required Network net,
  required ServiceType service,
  required String rootId,
  Set<String> deferredEdgeIds = const {},
  List<String> extraRootIds = const [],
}) {
  final adjacency = <String, List<({String edgeId, String other})>>{};
  for (final e in net.edges) {
    if (e.service != service) continue;
    (adjacency[e.fromId] ??= []).add((edgeId: e.id, other: e.toId));
    (adjacency[e.toId] ??= []).add((edgeId: e.id, other: e.fromId));
  }
  for (final links in adjacency.values) {
    links.sort((a, b) {
      final c = a.edgeId.compareTo(b.edgeId);
      return c != 0 ? c : a.other.compareTo(b.other);
    });
  }
  const none = <({String edgeId, String other})>[];
  final order = <String>[rootId];
  final visited = <String>{rootId};
  for (final r in extraRootIds) {
    if (visited.add(r)) order.add(r);
  }
  final parentOf = <String, ({String edgeId, String parent})>{};
  var head = 0;
  while (true) {
    while (head < order.length) {
      final n = order[head++];
      for (final link in adjacency[n] ?? none) {
        if (deferredEdgeIds.contains(link.edgeId)) continue;
        if (visited.add(link.other)) {
          parentOf[link.other] = (edgeId: link.edgeId, parent: n);
          order.add(link.other);
        }
      }
    }
    var grew = false;
    for (final n in List<String>.of(order)) {
      for (final link in adjacency[n] ?? none) {
        if (!deferredEdgeIds.contains(link.edgeId)) continue;
        if (visited.add(link.other)) {
          parentOf[link.other] = (edgeId: link.edgeId, parent: n);
          order.add(link.other);
          grew = true;
        }
      }
    }
    if (!grew) break;
  }
  return (order: order, parentOf: parentOf);
}

/// Sum [terminal] loads up the [serviceSpanningTree] — edgeId → the total
/// beyond that edge (away from the root); fills [edgeParent] with each edge's
/// root-side endpoint.
Map<String, double> _accumulateOnTree({
  required Network net,
  required ServiceType service,
  required String rootId,
  required double Function(String node) terminal,
  Map<String, String>? edgeParent,
  Set<String> deferredEdgeIds = const {},
  List<String> extraRootIds = const [],
}) {
  final tree = serviceSpanningTree(
    net: net,
    service: service,
    rootId: rootId,
    deferredEdgeIds: deferredEdgeIds,
    extraRootIds: extraRootIds,
  );
  final sum = <String, double>{for (final n in tree.order) n: terminal(n)};
  final out = <String, double>{};
  for (final n in tree.order.reversed) {
    final p = tree.parentOf[n];
    if (p == null) continue;
    out[p.edgeId] = sum[n]!;
    edgeParent?[p.edgeId] = p.parent; // the root-side endpoint
    sum[p.parent] = sum[p.parent]! + sum[n]!;
  }
  return out;
}

/// Accumulate downstream demand onto every edge of [service], treating the
/// service subgraph as a tree rooted at [rootId]. [terminalDemand] maps node
/// ids to the demand introduced AT that node (fixtures, diffusers, drains).
/// Returns edgeId → flow (the total demand beyond that edge, away from root).
///
/// The tree is the deterministic [serviceSpanningTree]; on a looped subgraph
/// the loop's closing edges are absent from the result (the caller sizes
/// them). When [edgeParent] is supplied it is filled with edgeId → the
/// ROOT-SIDE (parent) endpoint of that edge, so the caller can orient a flow
/// arrow.
Map<String, FlowRate> accumulateFlows({
  required Network net,
  required ServiceType service,
  required String rootId,
  required Map<String, FlowRate> terminalDemand,
  Map<String, String>? edgeParent,
  Set<String> deferredEdgeIds = const {},
  List<String> extraRootIds = const [],
}) =>
    _accumulateOnTree(
      net: net,
      service: service,
      rootId: rootId,
      terminal: (n) => terminalDemand[n]?.cubicMetersPerSecond ?? 0.0,
      edgeParent: edgeParent,
      deferredEdgeIds: deferredEdgeIds,
      extraRootIds: extraRootIds,
    ).map((k, v) => MapEntry(k, FlowRate(v)));

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
  Set<String> deferredEdgeIds = const {},
  List<String> extraRootIds = const [],
}) =>
    _accumulateOnTree(
      net: net,
      service: service,
      rootId: rootId,
      terminal: (n) => terminalUnits[n] ?? 0.0,
      edgeParent: edgeParent,
      deferredEdgeIds: deferredEdgeIds,
      extraRootIds: extraRootIds,
    );

/// Code-minimum pipe diameter for a FIRE edge, or null for any other service.
///
/// The fire services share the pressurized velocity sizer with domestic water,
/// but their pipe is governed by code minimums the small per-outlet flows never
/// reach on velocity alone (a sprinkler head at ~1 L/s sizes DN25 at best and
/// DN20 at a 0.5 L/s share; a 5 L/s hose box sizes DN65):
///  • sprinkler — every drawn pipe >= [kMinSprinklerPipeDiameterMm] (25 mm);
///  • hydrant RISER — the standpipe >= [kMinRiserDiameterMm] (100 mm, SNI
///    03-1745-2000 Class I/III, the same figure `designStandpipe` reports);
///  • hydrant RUN — the pipe feeding a 65 mm Class I landing valve >=
///    [kMinHydrantBranchDiameterMm] (65 mm).
/// The velocity sizer still raises the size above the floor when the flow
/// needs it. `// VERIFY` — see the constants' provenance.
Diameter? fireMinimumDiameter(NetEdge edge) => switch (edge.service) {
      ServiceType.fireSprinkler => Diameter.mm(kMinSprinklerPipeDiameterMm),
      ServiceType.fireHydrant => Diameter.mm(edge.kind == EdgeKind.riser
          ? kMinRiserDiameterMm
          : kMinHydrantBranchDiameterMm),
      _ => null,
    };

/// Size one [edge] carrying [flow] via the correct §7 path (selected by the
/// edge's service regime — pressurized / air / gravity).
EdgeSizing sizeEdge(NetEdge edge, FlowRate flow, SizingContext ctx) {
  switch (edge.service.regime) {
    case FlowRegime.pressurized:
      final r = water.sizeForFlow(
        flow: flow,
        // Round 21 — fire pipe on the fire velocity cap, domestic water on
        // the SNI 03-7065 supply cap.
        maxVelocity: fireMinimumDiameter(edge) != null
            ? ctx.maxFireVelocity
            : ctx.maxSupplyVelocity,
        material: ctx.pipeMaterial,
        // Fire services floor at their code-minimum DN (null for water).
        minDiameter: fireMinimumDiameter(edge),
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
  Diameter? minimumCompliant,
  bool manningRun = false,
}) {
  final isDrainage = sizing.service == ServiceType.drainage;
  // [manningRun] — a non-drainage edge the auto-sizer ALSO sized by Manning (a
  // horizontal rainwater collector, water-drainage-2): its override keeps the
  // same full-bore Manning velocity basis and re-judges self-cleansing at the
  // chosen diameter. Default false ⇒ byte-identical for every other caller.
  final bool manningBasis =
      (isDrainage || manningRun) && ctx != null && override.meters > 0;

  final Velocity velocity;
  if (override.meters <= 0) {
    velocity = const Velocity(0);
  } else if (sizing.service == ServiceType.vent) {
    velocity = const Velocity(0); // a vent carries no flow
  } else if (manningBasis) {
    velocity = manningVelocity(
      manningN: ctx.drainageManningN,
      hydraulicRadius: Length(override.meters / 4.0),
      // Round 33 — a drainage pipe is laid at least at its own minimum fall.
      slope: isDrainage
          ? effectiveDrainageSlope(ctx.drainageSlope, override.inMillimeters)
          : ctx.drainageSlope,
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
    demandCurveExtrapolated: sizing.demandCurveExtrapolated,
    // Round 17 (gravity-3-1) — an override strictly SMALLER than the smallest
    // compliant size for this load is a code violation the hand pick creates.
    belowCodeMinimum: sizing.belowCodeMinimum ||
        (minimumCompliant != null &&
            override.meters > 0 &&
            override.meters < minimumCompliant.meters - _kDiameterEpsM),
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
    // Round 9 (mech-store-fuzz-3) — an AIR edge carrying ZERO flow (a duct
    // joining two plant nodes — AHU→fan, AHU→AHU — drawn before any terminal,
    // since a non-root plant leaf carries no phantom demand) is left unsized
    // exactly like an unreached edge: the duct sizers require a positive
    // airflow (a debug assert aborted the whole solve) and a release build
    // printed a 0 L/s Ø100 duct into the BOM. Water / gravity sizers take a
    // zero flow to their minimum size without asserting (a transfer leg with
    // no modelled demand keeps its minimum-size tag), so only air is gated.
    if (edge.service.regime == FlowRegime.air &&
        flow.cubicMetersPerSecond <= 0) {
      continue;
    }
    final sized = sizeEdge(edge, flow, ctx);
    final override = sizeOverrides[edge.id];
    result[edge.id] =
        override == null ? sized : applySizeOverride(sized, override, ctx: ctx);
  }
  return result;
}

/// The root-choice ladder [autoSizeNetwork] applies to one connected component
/// (see the inline note there): plant → non-fixture demand-free leaf → busiest
/// demand-free hub → any leaf → any node. Shared by [serviceComponentRoots] so
/// downstream consumers (e.g. the fan index-run static) root a system at the
/// SAME source the sizer accumulated from.
///
/// Every rung is DETERMINISTIC and physical (mech-props-2 / mech-building-1):
/// the old ladder took the FIRST candidate in component (= edge-insertion)
/// order, so the same building drawn in a different order could root a
/// drainage stack at its roof or a transfer system at its roof tank.
///  • plants — on a pressurized/air service a degree-1 GROUND tank (the
///    suction source), then any degree-1 tank, then the lowest plant; on a
///    gravity service the lowest SINK plant (a ground tank / component-less
///    plant, or a degree-1 pump/booster = an ejector pit; an INLINE sump pump or
///    booster is pass-through, Round 12); the VENT the
///    highest (the atmosphere);
///  • demand-free leaves — on a supply (pressurized/air) service the leaf the
///    run was DRAWN FROM (the `fromId` of its edge — a property of the drawn
///    data, not of the order edges were added), then a leaf on a RISER end
///    (the vertical supply connection — a roof tank or riser-base entry, not
///    an open horizontal run end awaiting its fixture), then the lowest; on a
///    gravity
///    service the LOWEST (the building drain), then drawn-from; for a vent the
///    HIGHEST (the VTR), then drawn-from;
///  • ties always fall to the node id.
/// "Lowest" is the floor index, then any explicit elevation.
String _pickComponentRoot({
  required List<String> component,
  required List<String> leaves,
  required int Function(String) degree,
  required NodeRole? Function(String) roleOf,
  required Set<String> demandKeys,
  required ServiceType service,
  required NetNode? Function(String) nodeOf,
  required Set<String> drawnFromIds,
  Set<String> riserEndIds = const {},
  Set<String> riserTopIds = const {},
  Map<String, int> riserTopSpan = const {},
  Iterable<String> Function(String)? neighboursOf,
}) {
  Iterable<String> neighbours(String id) =>
      neighboursOf?.call(id) ?? const <String>[];
  final highestFirst = service == ServiceType.vent;
  int heightCmp(String a, String b) {
    final na = nodeOf(a), nb = nodeOf(b);
    var c = (na?.floorIndex ?? 0).compareTo(nb?.floorIndex ?? 0);
    if (c == 0) {
      c = (na?.elevation?.meters ?? 0).compareTo(nb?.elevation?.meters ?? 0);
    }
    return highestFirst ? -c : c;
  }

  int byHeight(String a, String b) {
    final c = heightCmp(a, b);
    return c != 0 ? c : a.compareTo(b);
  }

  // Round 13 (regression-degree2-groundtank-not-root) — a GROUND TANK is the
  // source of a pressurized system at ANY degree: a duty/standby set draws
  // from it through two (or more) suction legs, so it has degree >= 2.
  //
  // Round 14 (regression-groundtank-rank-inline-tank-steals-root) — but a
  // TERMINUS tank (degree 1) always beats an INLINE one: a raw-water GWT →
  // filter → treated GWT → booster chain used to tie both tanks at rank 0 and
  // fall to the node id, so `n10` < `n9` rooted the treated tank and left the
  // whole raw→treated transfer main unsized (0 L/s, DN15). Ladder:
  //   0 degree-1 ground tank · 1 inline ground tank · 2 degree-1 roof tank ·
  //   3 any other plant (heater, AHU, terminus pump…) — and an INLINE mover
  //   (see [isInlineMover]) is never ranked with them at all.
  int plantRank(String id) {
    if (service.regime == FlowRegime.gravity) return 0;
    return _supplyPlantRank(nodeOf(id)?.component, degree(id));
  }

  // Round 12 (mech-props-2 gravity-pump-root) — on a GRAVITY service only a
  // SINK plant may root the component: a ground tank (sump / STP / holding
  // tank) or a component-less plant. A sump/ejector PUMP, booster set, roof
  // tank or air unit drawn INLINE (degree >= 2) on a drainage network is a
  // node the flow passes THROUGH, never the outfall — rooting there sized the
  // real building drain for the outfall leaf's phantom 2 DFU, with its flow
  // arrow reversed. A degree-1 plant is a TERMINUS: a branch that ends at a
  // sump pump (the ejector pit — the pump IS the gravity sink) roots there,
  // exactly like a ground tank, so its fixtures' load reaches the pit.
  //
  // Round 14 (mech-props-3 sump-ejector-outfall) — an INLINE ground tank with
  // a pump / booster-set neighbour is an EJECTOR PIT: its contents are pumped
  // ONWARD to the building drain, so it is pass-through too and the component
  // roots at the real outfall. Rooting at the pit drained the ground-floor
  // fixtures DOWN into the basement and gave the outfall a phantom 2 DFU.
  final gravity = service.regime == FlowRegime.gravity;
  bool isMoverComponent(NodeComponent? c) =>
      c == NodeComponent.pump || c == NodeComponent.boosterSet;
  bool isPassThroughPlant(String id) {
    if (!gravity || roleOf(id) != NodeRole.plant) return false;
    if (degree(id) < 2) return false;
    final comp = nodeOf(id)?.component;
    if (comp == null) return false;
    if (comp != NodeComponent.groundTank) return true;
    // Round 33 (regression-ejector-pit-valve-reverses-force-main) — the
    // mover may sit behind a suction gate valve / strainer / bare bend: walk
    // each leg through degree-2 pass-through nodes (the SAME rule as
    // `ejector.ejectorPitOf`) to a pump / booster set.
    bool leadsToMover(String m) {
      var prev = id;
      var cur = m;
      final seen = <String>{id};
      while (seen.add(cur)) {
        final n = nodeOf(cur);
        if (roleOf(cur) == NodeRole.plant &&
            isMoverComponent(n?.component)) {
          return true;
        }
        if (!ejector.isEjectorPassThroughNode(n) || degree(cur) != 2) {
          return false;
        }
        final p = prev;
        final next = neighbours(cur).firstWhere((x) => x != p,
            orElse: () => '');
        if (next.isEmpty) return false;
        prev = cur;
        cur = next;
      }
      return false;
    }

    return neighbours(id).any(leadsToMover);
  }

  // Round 14 (mech-props-3 recirc-pump-root / inline-booster-fan-phantom) — on
  // a supply (pressurized / air) service a pump, booster set or fan drawn
  // INLINE (degree >= 2) is a machine the flow passes THROUGH (a recirc pump on
  // the HW return, a booster on the PDAM line, an inline exhaust fan before its
  // louvre), never the source: it ranks below every other plant AND below a
  // demand-free entry/outlet leaf. Rooting there tied with the heater on the
  // node id (the supply main lost a DN on a renamed drawing) and handed the
  // real entry leaf the flat phantom default, reversing the suction main.
  bool isInlineMover(String id) {
    if (gravity || roleOf(id) != NodeRole.plant || degree(id) < 2) {
      return false;
    }
    final c = nodeOf(id)?.component;
    return isMoverComponent(c) ||
        c == NodeComponent.supplyFan ||
        c == NodeComponent.exhaustFan;
  }

  // Round 15 (regression-inline-fan-lets-fcu-root-supply-duct) — a TERMINAL
  // air unit (FCU / AC cassette / split / ducted AC) on a supply service is a
  // delivery point of a fan- or AHU-driven duct, never its source: it ranked
  // with the AHU at rank 3 and, once Round 14 dropped the inline fan, beat
  // both the fan and the demand-free intake leaf — reversing the trunk and
  // losing the unit's own airflow. And a plant that CARRIES demand (an
  // explicit load for this service) must never root either: the root's own
  // demand never traverses an edge ('Network rooting' invariant). Both move
  // to a late rung (below free leaves and inline movers); a stand-alone FCU
  // feeding only its own diffusers still roots there.
  bool isDeferredPlant(String id) =>
      !gravity &&
      roleOf(id) == NodeRole.plant &&
      (_isTerminalAirUnit(nodeOf(id)?.component) || demandKeys.contains(id));
  final plants = [
    for (final id in component)
      if (roleOf(id) == NodeRole.plant &&
          !isPassThroughPlant(id) &&
          !isInlineMover(id) &&
          !isDeferredPlant(id))
        id,
  ]..sort((a, b) {
      final c = plantRank(a).compareTo(plantRank(b));
      return c != 0 ? c : byHeight(a, b);
    });
  if (plants.isNotEmpty) {
    // Round 33 (hydraulics-3-3) — a mains-fed roof tank (PDAM meter ->
    // [pompa dorong] -> riser -> roof tank -> downfeed): a degree-1 WATER
    // METER is the supply ENTRY, and an INLINE roof tank is storage the
    // flow passes through. Rooting at the tank sized the fill line flowing
    // BACK to the meter (a phantom draw-off there) and left the fill pump a
    // bogus booster instead of a transfer pump.
    final best = nodeOf(plants.first);
    if ((service == ServiceType.coldWater ||
            service == ServiceType.hotWater) &&
        best?.component == NodeComponent.roofTank &&
        degree(plants.first) >= 2) {
      final meters = [
        for (final id in leaves)
          if (nodeOf(id)?.component == NodeComponent.waterMeter &&
              !demandKeys.contains(id))
            id,
      ]..sort(byHeight);
      if (meters.isNotEmpty) return meters.first;
    }
    return plants.first;
  }

  int drawnRank(String id) => drawnFromIds.contains(id) ? 0 : 1;
  final supply = !gravity;
  // Round 17 (regression-ducted-ac-intake-phantom-fan-way) — a bare leaf
  // whose duct joins a DEMAND-FREE terminal air unit (directly, or through
  // inline dampers) is that unit's fresh-air INTAKE, not the system's entry:
  // with no source plant drawn the stand-alone FCU / ducted AC is the source
  // of its own diffuser run. Rooting at the intake leaf sized the intake as a
  // supply trunk OUT of the open end and handed the unit's duty to a phantom
  // fan (an F-01 row + a second MDP way beside the AC's own rated input).
  bool isIntakeOfTerminalUnit(String leaf) {
    if (gravity || service.regime != FlowRegime.air) return false;
    final n = nodeOf(leaf);
    if (n == null || n.component != null || n.role != NodeRole.main) {
      return false;
    }
    var prev = leaf;
    var cur = neighbours(leaf).isEmpty ? null : neighbours(leaf).first;
    final seen = <String>{leaf};
    while (cur != null && seen.add(cur)) {
      final c = nodeOf(cur)?.component;
      if (isDeferredPlant(cur)) {
        return !demandKeys.contains(cur) && _isTerminalAirUnit(c);
      }
      final isDamper = c == NodeComponent.motorizedDamper ||
          c == NodeComponent.volumeDamper ||
          c == NodeComponent.fireDamper;
      if (!isDamper || degree(cur) != 2 || demandKeys.contains(cur)) {
        return false;
      }
      final p = prev;
      prev = cur;
      cur = neighbours(cur).firstWhere((m) => m != p, orElse: () => '');
      if (cur.isEmpty) return false;
    }
    return false;
  }

  final freeLeaves = [
    for (final id in leaves)
      if (roleOf(id) != NodeRole.fixture &&
          !demandKeys.contains(id) &&
          !isPassThroughPlant(id) &&
          !isDeferredPlant(id) &&
          !isIntakeOfTerminalUnit(id))
        id,
  ]..sort((a, b) {
      if (supply) {
        var c = drawnRank(a).compareTo(drawnRank(b));
        if (c != 0) return c;
        c = (riserEndIds.contains(a) ? 0 : 1)
            .compareTo(riserEndIds.contains(b) ? 0 : 1);
        return c != 0 ? c : byHeight(a, b);
      }
      final h = heightCmp(a, b);
      if (h != 0) return h;
      final c = drawnRank(a).compareTo(drawnRank(b));
      return c != 0 ? c : a.compareTo(b);
    });
  if (freeLeaves.isNotEmpty) return freeLeaves.first;

  // Round 30 (mech-sim-4-vent-stack-without-vtr-stub-undersized) — a vent
  // stack drawn with no VTR stub ends at its top-floor tie node: that bare
  // stack TOP is the roof penetration (`gravityRiserEndElevation` already
  // reads it so), so the vent air leaves there. Rooting at the busiest
  // junction instead sized the stack on the floors above that hub only
  // (72 vs 90 DFU, DN75 where DN100 is needed).
  if (service == ServiceType.vent) {
    final tops = [
      for (final id in component)
        if (riserTopIds.contains(id) &&
            roleOf(id) != NodeRole.fixture &&
            !demandKeys.contains(id))
          id,
    ]..sort((a, b) {
        // Round 30 (r2) — the STACK's top, not a branch vent's: a fixture's
        // own vent riser (A2 -> A3) tied by a run into the stack top also
        // ends at a riser top on the top storey. Rooting there carried the
        // whole stack through the tie (20 -> 60 DFU); the stubbed drawing's
        // VTR sits on the stack, so prefer the top whose riser chain spans
        // the most storeys, then the usual height / id order.
        final c = (riserTopSpan[b] ?? 0).compareTo(riserTopSpan[a] ?? 0);
        return c != 0 ? c : byHeight(a, b);
      });
    if (tops.isNotEmpty) return tops.first;
  }

  final movers = [
    for (final id in component)
      if (isInlineMover(id)) id,
  ]..sort(byHeight);
  if (movers.isNotEmpty) return movers.first;

  // Round 15 — the deferred plants: a demand-free terminal air unit first (a
  // stand-alone FCU / ducted AC is the source of its own diffuser run), then a
  // demand-bearing one; ties by height, then id.
  final deferredPlants = [
    for (final id in component)
      if (isDeferredPlant(id) && !isPassThroughPlant(id)) id,
  ]..sort((a, b) {
      final da = demandKeys.contains(a) ? 1 : 0;
      final db = demandKeys.contains(b) ? 1 : 0;
      final c = da.compareTo(db);
      return c != 0 ? c : byHeight(a, b);
    });
  if (deferredPlants.isNotEmpty) return deferredPlants.first;

  String? hub;
  var hubDegree = 1;
  for (final id in component) {
    final d = degree(id);
    if (d <= 1) continue;
    if (roleOf(id) == NodeRole.fixture || demandKeys.contains(id)) continue;
    if (hub == null ||
        d > hubDegree ||
        (d == hubDegree && id.compareTo(hub) < 0)) {
      hub = id;
      hubDegree = d;
    }
  }
  if (hub != null) return hub;
  if (leaves.isNotEmpty) return ([...leaves]..sort()).first;
  return ([...component]..sort()).first;
}

/// Round 30 (r2) — for each riser TOP of [service], the number of storeys
/// its riser-only chain spans below it (top floor less the lowest floor
/// reachable through riser edges).
Map<String, int> _riserTopSpans(
    Network net, ServiceType service, Set<String> tops) {
  if (tops.isEmpty) return const {};
  final adj = <String, List<String>>{};
  for (final e in net.edges) {
    if (e.service != service || e.kind != EdgeKind.riser) continue;
    (adj[e.fromId] ??= []).add(e.toId);
    (adj[e.toId] ??= []).add(e.fromId);
  }
  final out = <String, int>{};
  for (final t in tops) {
    final top = net.nodeById(t)?.floorIndex ?? 0;
    var low = top;
    final seen = <String>{t};
    final stack = [t];
    while (stack.isNotEmpty) {
      final n = stack.removeLast();
      final f = net.nodeById(n)?.floorIndex ?? top;
      if (f < low) low = f;
      for (final o in adj[n] ?? const <String>[]) {
        if (seen.add(o)) stack.add(o);
      }
    }
    out[t] = top - low;
  }
  return out;
}

/// Round 30 — record a riser's UPPER / LOWER end by floor (then explicit
/// elevation); a riser between two nodes at one height records nothing.
void _noteRiserEnds(
    Network net, NetEdge e, Set<String> uppers, Set<String> lowers) {
  final a = net.nodeById(e.fromId), b = net.nodeById(e.toId);
  if (a == null || b == null) return;
  var c = a.floorIndex.compareTo(b.floorIndex);
  if (c == 0) {
    c = (a.elevation?.meters ?? 0).compareTo(b.elevation?.meters ?? 0);
  }
  if (c == 0) return;
  uppers.add(c > 0 ? a.id : b.id);
  lowers.add(c > 0 ? b.id : a.id);
}

/// Round 15 (root-metamorphic-rain-multi-downpipe) — the OUTFALLS of a
/// drainage / rainwater component that discharges at more than one point,
/// ordered by plan position (floor, x, y, then id) so the nearest-outfall
/// split never depends on node names. Empty unless there are >= 2.
///
/// An outfall is the picked [root] itself, or a demand-free, non-fixture,
/// non-plant LEAF whose single edge is a RISER rising to a higher node (a
/// downpipe / stack foot) tied at the root's height (same floor and explicit
/// elevation). The root counts only when it is a non-plant leaf too (a sump
/// or STP plant is a single sink by construction). Vents and supply services
/// never split.
List<String> _gravityOutfalls({
  required Network net,
  required ServiceType service,
  required List<String> component,
  required String root,
  required int Function(String) degree,
  required Set<String> demandKeys,
  required List<({String edgeId, String other})> Function(String) incident,
}) {
  if (service != ServiceType.drainage && service != ServiceType.rainwater) {
    return const [];
  }
  final rootNode = net.nodeById(root);
  if (rootNode == null ||
      rootNode.role == NodeRole.plant ||
      rootNode.role == NodeRole.fixture ||
      degree(root) != 1) {
    return const [];
  }
  bool tiedWithRoot(NetNode n) =>
      n.floorIndex == rootNode.floorIndex &&
      (n.elevation?.meters ?? 0) == (rootNode.elevation?.meters ?? 0);
  bool isStackFoot(String id) {
    final links = incident(id);
    if (links.length != 1) return false;
    final edge = net.edgeById(links.single.edgeId);
    if (edge == null || edge.kind != EdgeKind.riser) return false;
    final me = net.nodeById(id), up = net.nodeById(links.single.other);
    if (me == null || up == null) return false;
    if (up.floorIndex != me.floorIndex) return up.floorIndex > me.floorIndex;
    return (up.elevation?.meters ?? 0) > (me.elevation?.meters ?? 0);
  }

  final out = <NetNode>[rootNode];
  for (final id in component) {
    if (id == root || degree(id) != 1 || demandKeys.contains(id)) continue;
    final n = net.nodeById(id);
    if (n == null ||
        n.role == NodeRole.plant ||
        n.role == NodeRole.fixture ||
        n.component != null) {
      continue;
    }
    if (!tiedWithRoot(n) || !isStackFoot(id)) continue;
    out.add(n);
  }
  if (out.length < 2) return const [];
  out.sort((a, b) {
    var c = a.floorIndex.compareTo(b.floorIndex);
    if (c != 0) return c;
    c = a.x.compareTo(b.x);
    if (c != 0) return c;
    c = a.y.compareTo(b.y);
    return c != 0 ? c : a.id.compareTo(b.id);
  });
  return [for (final n in out) n.id];
}

/// Round 14 — the supply-side (pressurized / air) source rank of a plant node
/// (lower roots first): 0 a degree-1 ground tank, 1 an inline ground tank, 2 a
/// degree-1 roof tank, 3 any other plant. Shared by the root ladder and the
/// parallel-source mirror so "equal rank" means the same thing in both.
///
/// Round 15 — a TERMINAL air unit ([_isTerminalAirUnit]: FCU / AC units) is
/// rank 4: a delivery point, never a peer of the AHU that feeds it.
int _supplyPlantRank(NodeComponent? comp, int degree) {
  if (comp == NodeComponent.groundTank) return degree == 1 ? 0 : 1;
  if (comp == NodeComponent.roofTank && degree == 1) return 2;
  if (_isTerminalAirUnit(comp)) return 4;
  return 3;
}

/// Public view of the supply-plant source rank (Round 15) — the app's upfeed
/// pressure solve ranks plants on the SAME ladder the sizer roots on, so a
/// ground tank and a same-floor pump never tie on elevation.
int supplyPlantRank(NodeComponent? comp, int degree) =>
    _supplyPlantRank(comp, degree);

/// Round 15 — an air unit that DELIVERS conditioned air to its room (fan-coil
/// unit, AC cassette / split-wall / ducted AC), as opposed to a SOURCE plant
/// (AHU, supply/exhaust fan, tanks). On a duct fed by an AHU or fan it is a
/// terminal: it never roots the component and never mirrors a parallel-source
/// flow.
bool _isTerminalAirUnit(NodeComponent? comp) => switch (comp) {
      NodeComponent.fcu ||
      NodeComponent.acCassette ||
      NodeComponent.acSplitWall ||
      NodeComponent.acDucted =>
        true,
      _ => false,
    };

/// Public view of [_isTerminalAirUnit] (Round 16) — the app's air-system
/// unit choice excludes the same delivery units the sizer never roots at.
bool isTerminalAirUnit(NodeComponent? comp) => _isTerminalAirUnit(comp);

/// The source ROOT of every connected component of [service], keyed by each
/// member node id → its component's root — the exact root [autoSizeNetwork]
/// accumulates from (same component traversal, same [_pickComponentRoot]
/// ladder). [demandNodeIds] are the nodes carrying an explicit demand for this
/// service (for air: the nodes with an `airflow`), which must never be chosen
/// as the root. Pure; empty when the service has no edges.
Map<String, String> serviceComponentRoots(
  Network net,
  ServiceType service, {
  Set<String> demandNodeIds = const {},
}) {
  final adjacency = <String, List<String>>{};
  final nodes = <String>{};
  final drawnFromIds = <String>{};
  final riserEndIds = <String>{};
  final riserUppers = <String>{}, riserLowers = <String>{};
  for (final e in net.edges) {
    if (e.service != service) continue;
    nodes
      ..add(e.fromId)
      ..add(e.toId);
    drawnFromIds.add(e.fromId);
    if (e.kind == EdgeKind.riser) {
      riserEndIds
        ..add(e.fromId)
        ..add(e.toId);
      _noteRiserEnds(net, e, riserUppers, riserLowers);
    }
    (adjacency[e.fromId] ??= []).add(e.toId);
    (adjacency[e.toId] ??= []).add(e.fromId);
  }
  int degree(String n) => adjacency[n]?.length ?? 0;
  NodeRole? roleOf(String n) => net.nodeById(n)?.role;
  final riserTops = riserUppers.difference(riserLowers);
  final riserTopSpan = service == ServiceType.vent
      ? _riserTopSpans(net, service, riserTops)
      : const <String, int>{};

  final out = <String, String>{};
  final seen = <String>{};
  for (final start in nodes) {
    if (seen.contains(start)) continue;
    final component = <String>[];
    final stack = [start];
    seen.add(start);
    while (stack.isNotEmpty) {
      final n = stack.removeLast();
      component.add(n);
      for (final other in adjacency[n] ?? const <String>[]) {
        if (seen.add(other)) stack.add(other);
      }
    }
    final root = _pickComponentRoot(
      component: component,
      leaves: component.where((n) => degree(n) == 1).toList(),
      degree: degree,
      roleOf: roleOf,
      demandKeys: demandNodeIds,
      service: service,
      nodeOf: net.nodeById,
      drawnFromIds: drawnFromIds,
      riserEndIds: riserEndIds,
      riserTopIds: riserTops,
      riserTopSpan: riserTopSpan,
      neighboursOf: (n) => adjacency[n] ?? const <String>[],
    );
    for (final n in component) {
      out[n] = root;
    }
  }
  return out;
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
///     NOT a sum of peak fixture flows. Round 22: [flushSystem] applies to
///     COLD water only; hot water always takes the flush-tank branch (it
///     never serves a flush valve). Round 27: with [flushValveNodeIds] the
///     branch is chosen per cold-water COMPONENT (flush valve only where one
///     of those nodes is on it) — see [flushSystemForRoot].
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
///
/// SPRINKLER REMOTE-AREA CAP ([sprinklerDemandCap]): a wet sprinkler system is
/// designed for the heads of ONE remote design area operating at once (density
/// × area, uplifted by the head minimum pressure — `remoteAreaDemand` in
/// `fire_sprinkler_hydraulic.dart`), never for every drawn head together. When
/// the cap is given, every accumulated `fireSprinkler` edge flow is clamped to
/// it, so a cross-main feeding 60 heads carries the design-area demand, not
/// 60 × the per-head share. Null ⇒ byte-identical (flat accumulation).
///
/// HYDRANT STANDPIPE FLOW ([hydrantDesignFlow]) — mech-building-5: a hydrant
/// system is designed for the STANDPIPE flow the fire pump delivers (SNI
/// 03-1745-2000: 500 gpm + 250 gpm per additional riser, `designStandpipe`),
/// never for Σ (every drawn box × 5 L/s). When given, every `fireHydrant`
/// RISER and every TRUNK run (one carrying more than a single box) carries
/// exactly that design flow — so a 10-box riser is no longer sized for 50 L/s
/// while the pump delivers 31.5 L/s, nor a 4-box riser for 20 L/s that the
/// pump's 31.5 L/s would push past the velocity cap. A branch run serving a
/// single box keeps its per-box flow. Round 22: [hydrantDesignFlow] is the
/// multi-riser TOTAL, carried only by the common supply upstream of the split;
/// a riser, or a trunk serving fewer stacks, carries `standpipeFlow(n)` for
/// the n stacks running in parallel downstream of it (one stack ⇒ 500 gpm),
/// never more than [hydrantDesignFlow]. Null ⇒ byte-identical (flat
/// accumulation).
///
/// WATER-CLOSET NODES ([waterClosetNodeIds]): node ids the caller knows carry a
/// water closet beyond the built-in [PlumbingFixture] WC types — a user-defined
/// custom fixture flagged `CustomFixture.isWaterCloset` (the app resolves the
/// library; the engine never reads it). A drainage edge carrying one is floored
/// at [drain.kMinWcDrainMm] exactly like a built-in WC (water-drainage-7).
/// Default empty ⇒ byte-identical.
///
/// FIXTURE-UNIT RECORD ([fixtureUnitsOut], Round 9): when given, every TREE
/// edge sized by accumulated fixture units — water supply by UBAP, drainage /
/// vent by DFU — writes its accumulated units here (edgeId → units), the SAME
/// numbers the sizer turned into a size, so the calc report's run schedule
/// can print the basis ('why DN100') without re-deriving it. Ring edges of a
/// looped water component are split by Hardy–Cross and are not recorded.
///
/// PARALLEL-LEG RECORD ([parallelLegEdgeIdsOut], Round 14): when given, every
/// edge sized by MIRRORING a set flow rather than by accumulation — a
/// duty/standby STANDBY leg, or the bridge of a parallel peer source (a second
/// ground-tank compartment / AHU) — is added here. Those legs carry the full
/// set flow so each machine can run alone, but they are NOT additional
/// delivery: a consumer summing the flow leaving a source (the pump / fan duty)
/// must skip them or it counts one set flow twice.
///
/// CHECK-VALVE FEED ADVISORY ([checkValveFeedsRingOut], Round 27 r3): when
/// given, every HOT-WATER cycle check valve classified as a FEED (its drawn
/// permitted direction does not point toward the source) whose outlet the
/// source still reaches with that valve and every return valve closed is
/// added here (node ids) — the drawing a recirculation return with its arrow
/// drawn backwards produces. Judge-only: the valve is sized as drawn.
///
/// AMBIGUOUS CHECK VALVES ([checkValveAmbiguousOut], Round 27 r5): when given,
/// every pressurized cycle check valve drawn with NO direction (both pipes
/// into, or both out of, the valve node) is added here with how it was
/// assumed ([CheckValveAmbiguity]) — a judge-only, locatable advisory.
///
/// MOVER LEGS AGAINST THE BALANCE ([checkValveAgainstPumpOut], Round 27 r7):
/// a check valve on a pump / booster / supply-fan leg is never closed by the
/// Hardy–Cross balance; when the balanced split runs AGAINST the leg's pump
/// direction the leg is kept open, sized on |flow| in the pump's direction,
/// and the valve's node id is added here (judge-only, locatable).
///
/// Round 27 r8 (binding orchestrator decision) — a mover leg (valved OR
/// valveless) whose balanced split runs against its coherently drawn pump is
/// sized on the ENVELOPE of two scenarios: (a) the leg CLOSED (zero draw-off,
/// the r4 closed-return treatment incl. the zero pockets) and (b) the leg
/// OPEN as balanced — every edge on the larger |flow|, the leg itself on its
/// scenario-(b) |flow| in the pump's direction (the mover duty, never 0).
/// Scenario (a) is skipped when closing the leg starves a draw-off point. A
/// VALVELESS leg against the balance is named on [moverAgainstBalanceOut]
/// (its pump node ids). Envelope honesty: a scenario's side outputs (these
/// advisories, [checkValveFeedsRingOut], [checkValveAmbiguousOut], the
/// loop-unbalanced flag, [parallelLegEdgeIdsOut]) are reported only when
/// that scenario WINS at least one edge of the element they name (a valve:
/// its two pipes; a leg advisory: an edge of that leg; an edge flag: the
/// edge itself).
Map<String, EdgeSizing> autoSizeNetwork(
  Network net,
  SizingContext ctx, {
  required Map<ServiceType, FlowRate> leafDemand,
  Map<ServiceType, double> leafFixtureUnits = const {},
  Map<String, double> nodeFixtureUnits = const {},
  Map<String, double> nodeDrainageUnits = const {},
  Map<String, FlowRate> nodeFlowDemand = const {},
  Map<String, Diameter> sizeOverrides = const {},
  FlowRate? sprinklerDemandCap,
  FlowRate? hydrantDesignFlow,
  FlushSystem flushSystem = FlushSystem.flushTank,
  Set<String> flushValveNodeIds = const {},
  BuildingLevels? building,
  Map<String, ScaleCalibration> calibrationBySheet = const {},
  MountingHeights mounting = const MountingHeights(),
  Set<String> waterClosetNodeIds = const {},
  Map<String, double>? fixtureUnitsOut,
  Set<String>? parallelLegEdgeIdsOut,
  Set<String>? checkValveFeedsRingOut,
  Map<String, CheckValveAmbiguity>? checkValveAmbiguousOut,
  Set<String>? checkValveAgainstPumpOut,
  Set<String>? moverAgainstBalanceOut,
  Set<String>? airIntakeLeavesOut,
}) {
  // Round 32 (binding-2) — a DUPLEX sewage ejector set (PIT -> EJ / EJ2 ->
  // header) is duty / standby, never a gravity ring: the standby legs are
  // taken OUT of the solve (so no closing edge, no `loopUnbalanced`, no
  // 0-DFU DN40 standby discharge), the network is sized through the duty
  // leg, and each standby leg MIRRORS the duty leg edge by edge (size,
  // fixture units, flow orientation pump -> header) and is recorded on
  // [parallelLegEdgeIdsOut] so a consumer summing a set flow reads it once.
  final sets = net.edges.any((e) => e.service == ServiceType.drainage)
      ? ejector.duplexEjectorSets(net)
      : const <ejector.DuplexEjectorSet>[];
  final standbyIds = <String>{
    for (final st in sets)
      for (final leg in st.standby) ...leg.edgeIds,
  };
  final solveNet = standbyIds.isEmpty
      ? net
      : Network(
          nodes: net.nodes,
          edges: [
            for (final e in net.edges)
              if (!standbyIds.contains(e.id)) e,
          ]);
  final result = _autoSizeNetworkCore(
    solveNet,
    ctx,
    leafDemand: leafDemand,
    leafFixtureUnits: leafFixtureUnits,
    nodeFixtureUnits: nodeFixtureUnits,
    nodeDrainageUnits: nodeDrainageUnits,
    nodeFlowDemand: nodeFlowDemand,
    sizeOverrides: sizeOverrides,
    sprinklerDemandCap: sprinklerDemandCap,
    hydrantDesignFlow: hydrantDesignFlow,
    flushSystem: flushSystem,
    flushValveNodeIds: flushValveNodeIds,
    building: building,
    calibrationBySheet: calibrationBySheet,
    mounting: mounting,
    waterClosetNodeIds: waterClosetNodeIds,
    fixtureUnitsOut: fixtureUnitsOut,
    parallelLegEdgeIdsOut: parallelLegEdgeIdsOut,
    checkValveFeedsRingOut: checkValveFeedsRingOut,
    checkValveAmbiguousOut: checkValveAmbiguousOut,
    checkValveAgainstPumpOut: checkValveAgainstPumpOut,
    moverAgainstBalanceOut: moverAgainstBalanceOut,
    airIntakeLeavesOut: airIntakeLeavesOut,
  );
  if (!net.edges.any((e) => e.service == ServiceType.drainage)) return result;

  // Round 32 (binding-2) — the solids-handling bore floor of every drawn
  // ejector's force main (pump -> header -> riser to the sewer junction):
  // never below [ejector.kEjectorForceMainMinBoreMm] whatever the DFU table
  // gives a small pit (`// VERIFY notAnSniClause`). The DFU / WC / trap
  // floors already applied stay (the larger wins); a hand override is never
  // touched (its own `belowCodeMinimum` judge applies).
  const minBore = ejector.kEjectorForceMainMinBoreMm;
  // Round 33 (regression-force-main-floor-reducer-downstream) — gravity
  // drainage DOWNSTREAM of a force main carries the pumped discharge (and
  // its 2 in solids) too, so it is never smaller than the force main (IPC
  // 704.2: no reduction in the direction of flow). node -> the drainage
  // edges whose SIZED flow leaves it.
  final leaving = <String, List<NetEdge>>{};
  for (final e in solveNet.edges) {
    if (e.service != ServiceType.drainage) continue;
    final from = result[e.id]?.flowFromId;
    if (from != null) (leaving[from] ??= []).add(e);
  }
  void floorEdge(NetEdge edge, {required bool forceMain}) {
    final id = edge.id;
    final sized = result[id];
    if (sized == null ||
        sized.service != ServiceType.drainage ||
        sized.diameter.inMillimeters >= minBore - 1e-9) {
      return;
    }
    if (sizeOverrides.containsKey(id)) {
      // A hand pick below the bore it receives: flagged, never resized (a
      // force-main step override keeps its own judge, as before).
      if (!forceMain) {
        result[id] = sized.withGravityFlags(belowMinimum: true);
      }
      return;
    }
    final raised = _sanitaryEdgeSizing(edge, Diameter.mm(minBore), ctx,
        codeMinimum: Diameter.mm(minBore), overCapacity: sized.overCapacity);
    result[id] = raised
        .withGravityFlags(raised: forceMain ? sized.stackRaisedForBranch : true)
        .withLoopUnbalanced(sized.loopUnbalanced)
        .withFlowFrom(sized.flowFromId);
  }

  for (final pumpId in ejector.drawnEjectorPumpIds(solveNet)) {
    final steps = ejector.ejectorForceMainSteps(solveNet, pumpId);
    for (final step in steps) {
      floorEdge(step.edge, forceMain: true);
    }
    if (steps.isEmpty) continue;
    final stepIds = {for (final s in steps) s.edge.id};
    // Walk the sized flow from the force main's last node to the outfall.
    var at = steps.last.to;
    final seenNodes = <String>{pumpId};
    while (seenNodes.add(at)) {
      final out = [
        for (final e in leaving[at] ?? const <NetEdge>[])
          if (!stepIds.contains(e.id)) e,
      ];
      if (out.length != 1) break;
      final e = out.single;
      floorEdge(e, forceMain: false);
      at = e.fromId == at ? e.toId : e.fromId;
    }
  }

  for (final st in sets) {
    final duty = st.duty;
    EdgeSizing? dutyAt(List<String> ids, int i) {
      if (ids.isEmpty) return null;
      return result[ids[i < ids.length ? i : ids.length - 1]];
    }

    void mirror(String id, String fromId, EdgeSizing? src, String? srcId) {
      final edge = net.edgeById(id);
      if (src == null || edge == null) return;
      var m = EdgeSizing(
        edgeId: id,
        service: edge.service,
        flow: src.flow,
        diameter: src.diameter,
        velocity: src.velocity,
        width: src.width,
        height: src.height,
        overCapacity: src.overCapacity,
        stackRaisedForBranch: src.stackRaisedForBranch,
        flowFromId: fromId,
        selfCleansingOk: src.selfCleansingOk,
        loopUnbalanced: src.loopUnbalanced,
        demandCurveExtrapolated: src.demandCurveExtrapolated,
        belowCodeMinimum: src.belowCodeMinimum,
      );
      final override = sizeOverrides[id];
      if (override != null) {
        m = applySizeOverride(m, override,
                ctx: ctx, codeMinimum: m.diameter, minimumCompliant: m.diameter)
            .withFlowFrom(fromId);
      }
      result[id] = m;
      final u = srcId == null ? null : fixtureUnitsOut?[srcId];
      if (u != null) fixtureUnitsOut?[id] = u;
      parallelLegEdgeIdsOut?.add(id);
    }

    for (final leg in st.standby) {
      // Round 33 — the suction chain (pit -> [valve] -> pump) mirrors the
      // duty leg's edge by edge, oriented from the pit.
      for (var i = 0; i < leg.pitEdgeIds.length; i++) {
        final srcIds = duty.pitEdgeIds;
        final srcId = srcIds[i < srcIds.length ? i : srcIds.length - 1];
        mirror(leg.pitEdgeIds[i], leg.pitFromIds[i], result[srcId], srcId);
      }
      for (var i = 0; i < leg.dischargeEdgeIds.length; i++) {
        final srcIds = duty.dischargeEdgeIds;
        final srcId = srcIds.isEmpty
            ? null
            : srcIds[i < srcIds.length ? i : srcIds.length - 1];
        mirror(leg.dischargeEdgeIds[i], leg.dischargeFromIds[i],
            dutyAt(srcIds, i), srcId);
      }
    }
  }
  return result;
}

Map<String, EdgeSizing> _autoSizeNetworkCore(
  Network net,
  SizingContext ctx, {
  required Map<ServiceType, FlowRate> leafDemand,
  Map<ServiceType, double> leafFixtureUnits = const {},
  Map<String, double> nodeFixtureUnits = const {},
  Map<String, double> nodeDrainageUnits = const {},
  Map<String, FlowRate> nodeFlowDemand = const {},
  Map<String, Diameter> sizeOverrides = const {},
  FlowRate? sprinklerDemandCap,
  FlowRate? hydrantDesignFlow,
  FlushSystem flushSystem = FlushSystem.flushTank,
  Set<String> flushValveNodeIds = const {},
  BuildingLevels? building,
  Map<String, ScaleCalibration> calibrationBySheet = const {},
  MountingHeights mounting = const MountingHeights(),
  Set<String> waterClosetNodeIds = const {},
  Map<String, double>? fixtureUnitsOut,
  Set<String>? parallelLegEdgeIdsOut,
  Set<String>? checkValveFeedsRingOut,
  Map<String, CheckValveAmbiguity>? checkValveAmbiguousOut,
  Set<String>? checkValveAgainstPumpOut,
  Set<String>? moverAgainstBalanceOut,
  Set<String>? airIntakeLeavesOut,
}) {
  const profile = SniProfile();
  final allFlows = <String, FlowRate>{};
  final sanitary = <String, EdgeSizing>{}; // DFU-sized drainage/vent edges
  final stormSizing = <String, EdgeSizing>{}; // rainwater downpipes
  // M17 — edges of any looped component whose Hardy–Cross balance did NOT
  // converge; their flow split (and every size derived from it) is provisional.
  final loopUnbalancedEdges = <String>{};
  // water-drainage-6 — water-supply edges whose UBAP load is beyond the charted
  // demand curve (their flow is an extrapolation; flagged for review).
  final demandExtrapolatedEdges = <String>{};

  // Read-only flow orientation per edge (edgeId → the endpoint flow comes FROM).
  // Populated below where direction is confidently known; attached to the final
  // sizings without ever altering a size/flow. Absent ⇒ EdgeSizing.flowFromId
  // stays null (byte-identical for callers that ignore it). A supply edge points
  // AWAY from the source (root → demand); a gravity edge points TOWARD the
  // collection root (demand → root); a vent carries no flow → left null.
  final edgeFlowFrom = <String, String>{};
  // Round 15 — a ground tank's FILL line, oriented INTO the tank (applied
  // after every accumulation; see the inline note in the component loop).
  final fillEdgeFlowFrom = <String, String>{};

  bool isWaterSupply(ServiceType s) =>
      s == ServiceType.coldWater || s == ServiceType.hotWater;

  // mech-building-6 — a fixture node fed by BOTH a cold and a hot branch loads
  // [SniProfile.dualSupplyFixtureUnitFactor] (3/4) of its total UBAP onto each
  // supply, not the full total onto both. Nodes on one supply are unchanged.
  final coldNodes = <String>{};
  final hotNodes = <String>{};
  for (final e in net.edges) {
    if (e.service == ServiceType.coldWater) {
      coldNodes
        ..add(e.fromId)
        ..add(e.toId);
    } else if (e.service == ServiceType.hotWater) {
      hotNodes
        ..add(e.fromId)
        ..add(e.toId);
    }
  }
  final dualSupplyNodes = coldNodes.intersection(hotNodes);
  final dualFactor = profile.dualSupplyFixtureUnitFactor.value;
  bool isSanitary(ServiceType s) =>
      s == ServiceType.drainage || s == ServiceType.vent;

  // mech-building-3 — the VENT pass reads the DFU the drainage system carries
  // at each node a vent ties into, so drainage is always processed first.
  final services = net.edges.map((e) => e.service).toSet().toList();
  if (services.contains(ServiceType.vent)) {
    services
      ..remove(ServiceType.vent)
      ..add(ServiceType.vent);
  }
  // Drainage through-DFU per node (the DFU on the drainage edge leaving that
  // node toward the drainage root) and the drainage tree's parent links —
  // filled by the drainage pass, read by the vent pass.
  final drainageThroughDfu = <String, double>{};
  final drainageParentNode = <String, String>{};

  for (final service in services) {
    // Round 22 (pressurized-3-4) — the flush-VALVE branch of the demand curve
    // exists for the valve WC's high instantaneous draw; the hot-water service
    // never carries a flush valve, so it always takes the flush-tank branch
    // (one valve WC on cold water used to put every HW main one or two DN up).
    final serviceFlushDefault =
        service == ServiceType.hotWater ? FlushSystem.flushTank : flushSystem;
    final demand = leafDemand[service] ?? const FlowRate(0);
    final useUbap =
        isWaterSupply(service) && leafFixtureUnits.containsKey(service);
    final fuPerLeaf = leafFixtureUnits[service] ?? 0.0;

    final adjacency = <String, List<({String edgeId, String other})>>{};
    final nodes = <String>{};
    final drawnFromIds = <String>{};
    final riserEndIds = <String>{};
    final riserUppers = <String>{}, riserLowers = <String>{};
    for (final e in net.edges) {
      if (e.service != service) continue;
      drawnFromIds.add(e.fromId);
      if (e.kind == EdgeKind.riser) {
        riserEndIds
          ..add(e.fromId)
          ..add(e.toId);
        _noteRiserEnds(net, e, riserUppers, riserLowers);
      }
      nodes
        ..add(e.fromId)
        ..add(e.toId);
      (adjacency[e.fromId] ??= []).add((edgeId: e.id, other: e.toId));
      (adjacency[e.toId] ??= []).add((edgeId: e.id, other: e.fromId));
    }

    int degree(String n) => adjacency[n]?.length ?? 0;
    NodeRole? roleOf(String n) => net.nodeById(n)?.role;

    // A node that bears the flat per-terminal default when it has no explicit
    // entry: any LEAF (a drawn run's open end), AND any demand TERMINAL wherever
    // it sits — audit 2026-10 water-drainage-3 / fire-1. A roof/floor drain,
    // water outlet, sprinkler head, hydrant box or diffuser drawn ALONG a run
    // (degree 2 — what tee-in / drop-merge produce) used to contribute zero,
    // so a collector through three roof drains carried one drain's runoff and
    // a sprinkler branch line one head's flow. Fixture-role components that are
    // NOT demand points — a cleanout (an access fitting), an air vent (an
    // air-release valve), a fire extinguisher (not piped) — stay at zero, as do
    // pure main/valve junctions.
    // A PLANT (tank, pump, AHU…) is a source/sink, never a terminal: a plant
    // leaf that is not the root (a ground tank when the component happened to
    // root elsewhere) used to bear a phantom 2-UBAP / default-flow load
    // (mech-props-2 / mech-building-1).
    // Round 12 (mech-props-2 cleanout-leaf) — the non-demand components are
    // exempt WHEREVER they sit: a cleanout at the head of a drain or an air
    // vent at a riser top is a LEAF, and the degree-1 rule used to run first
    // and hand it the phantom default load.
    bool bearsDefaultDemand(String n) {
      final node = net.nodeById(n);
      // Round 33 — ONE non-demand predicate shared with the pressure solves
      // (`isNonDemandTerminal`), and an INLINE DEVICE (meter, valve,
      // strainer, expansion tank) is never a draw-off even at a run's end
      // (hydraulics-3-3: a PDAM meter leaf drew a phantom default load and
      // reversed the roof-tank fill line).
      if (isNonDemandTerminal(node?.component) ||
          isInlineDeviceComponent(node?.component)) {
        return false;
      }
      if (node?.role == NodeRole.plant) return false;
      if (degree(n) == 1) return true;
      return node != null && node.role == NodeRole.fixture;
    }

    // mech-building-3 — a vent TIE (a vent-graph node that is also on the
    // drainage graph: a soil-stack tie, or a fixture's individual vent) is
    // seeded with the DFU it actually VENTS: the drainage through-DFU at that
    // node minus what already enters through the nearest tie(s) below it in
    // the drainage tree (so a stack tied at every floor counts each floor's
    // DFU once, and the vent accumulates to the stack total at its VTR). The
    // bare 2-DFU leaf default used to size a vent stack serving a 96-DFU soil
    // stack on 4 ties x 2 = 8 DFU -> DN32 instead of the table's DN75.
    final ventSeeds = <String, double>{};
    if (service == ServiceType.vent && drainageThroughDfu.isNotEmpty) {
      final ties = nodes.where(drainageThroughDfu.containsKey).toSet();
      for (final t in ties) {
        ventSeeds[t] = drainageThroughDfu[t]!;
      }
      for (final t in ties) {
        var up = drainageParentNode[t];
        while (up != null && !ties.contains(up)) {
          up = drainageParentNode[up];
        }
        if (up != null) ventSeeds[up] = ventSeeds[up]! - drainageThroughDfu[t]!;
      }
      // Round 25 (drainage-4-3) — a tie whose net seed is 0 (the soil-stack
      // FOOT, every DFU already counted at the ties above it) stays an
      // explicit 0: dropping it let the degree-1 leaf default hand the base
      // connection a phantom 2 DFU (a 24-DFU stack sized DN65, not DN50).
      ventSeeds.updateAll((_, v) => v <= 1e-9 ? 0.0 : v);
    }
    final drainageUnitsForService = ventSeeds.isEmpty
        ? nodeDrainageUnits
        : {...nodeDrainageUnits, ...ventSeeds};

    // The explicit per-node demand keys relevant to THIS service decide which
    // nodes "bear demand" (and so must not be chosen as the source root).
    final explicitDemandKeys = isSanitary(service)
        ? drainageUnitsForService.keys.toSet()
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
    final riserTops = riserUppers.difference(riserLowers);
    final riserTopSpan = service == ServiceType.vent
        ? _riserTopSpans(net, service, riserTops)
        : const <String, int>{};
    String pickRoot(List<String> component, List<String> leaves) =>
        _pickComponentRoot(
          component: component,
          leaves: leaves,
          degree: degree,
          roleOf: roleOf,
          demandKeys: explicitDemandKeys,
          service: service,
          nodeOf: net.nodeById,
          drawnFromIds: drawnFromIds,
          riserEndIds: riserEndIds,
          riserTopIds: riserTops,
          riserTopSpan: riserTopSpan,
          neighboursOf: (n) => [
            for (final l
                in adjacency[n] ?? const <({String edgeId, String other})>[])
              l.other,
          ],
        );

    // Build the terminal-demand map over EVERY demand-bearing node except the
    // root: a node with an explicit entry contributes it (even mid-run — an
    // inline fixture/diffuser is a degree-2 node), and a leaf OR a demand
    // terminal with no entry contributes the flat default
    // ([bearsDefaultDemand]). Pure interior junctions contribute nothing.
    // Round 15 — the component's LOAD-FREE nodes besides the root (set per
    // component below): its gravity OUTFALLS and a ground tank's FILL inlets.
    // Like the root, they never bear a terminal load.
    var loadFreeSet = const <String>{};
    Map<String, V> terminalMap<V>(
      List<String> component,
      String root,
      Map<String, V> explicit,
      V defaultForLeaf,
    ) {
      final out = <String, V>{};
      for (final n in component) {
        if (n == root || loadFreeSet.contains(n)) continue;
        final e = explicit[n];
        if (e != null) {
          out[n] = e;
        } else if (bearsDefaultDemand(n)) {
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
      final pickedRoot = pickRoot(component, leaves);
      final regime = service.regime;
      // Round 27 (residuals-6) — Hunter's method picks the demand curve per
      // SUPPLY SYSTEM: with [flushValveNodeIds] given, a cold-water component
      // takes the flush-VALVE branch only when it holds a flush-valve fixture
      // itself. One valve WC on a separate system (or typed on the drainage
      // layer only) used to re-curve every cold-water system in the project
      // (+76 % flow, one DN up). Empty set ⇒ the single [flushSystem].
      final serviceFlush =
          service == ServiceType.hotWater || flushValveNodeIds.isEmpty
              ? serviceFlushDefault
              : (component.any(flushValveNodeIds.contains)
                  ? FlushSystem.flushValve
                  : FlushSystem.flushTank);

      // Round 15 (root-metamorphic-rain-multi-downpipe) — a DRAINAGE or
      // RAINWATER component can discharge at SEVERAL outfalls: two downpipes
      // off one roof collector, two soil stacks to separate grade outlets.
      // Every demand-free, non-fixture, non-plant LEAF at the foot of a riser
      // (its single edge rises to a higher node) tied at the picked root's
      // height is an outfall. They all seed the tree (each terminal drains to
      // its NEAREST outfall, ties by plan position — never by node id), none
      // carries a phantom default load, and the collector's divide edge is a
      // closing edge sized conservatively and flagged `loopUnbalanced`.
      final outfalls = _gravityOutfalls(
        net: net,
        service: service,
        component: component,
        root: pickedRoot,
        degree: degree,
        demandKeys: explicitDemandKeys,
        incident: (n) => [
          for (final l
              in adjacency[n] ?? const <({String edgeId, String other})>[])
            (edgeId: l.edgeId, other: l.other),
        ],
      );
      final root = outfalls.isEmpty ? pickedRoot : outfalls.first;
      final extraRoots =
          outfalls.length > 1 ? outfalls.sublist(1) : const <String>[];

      // Round 15 (root-metamorphic-pdam-fill-phantom) — a pressurized
      // component rooted at an INLINE ground tank whose other side holds the
      // pump / booster: every branch off the tank WITHOUT a mover and without
      // any fixture / explicit demand is the FILL line (the PDAM main topping
      // the tank up). Its bare leaves are inlets, not draw-off points — no
      // phantom default load (it inflated the pump duty) — and its pipes are
      // oriented INTO the tank.
      final fillLeaves = <String>{};
      final rootNodeForFill = net.nodeById(root);
      if (regime == FlowRegime.pressurized &&
          rootNodeForFill?.component == NodeComponent.groundTank &&
          degree(root) >= 2) {
        bool isMoverNode(String n) {
          final c = net.nodeById(n)?.component;
          return c == NodeComponent.pump || c == NodeComponent.boosterSet;
        }

        final claimed = <String>{root};
        final branches = <({
          List<String> nodes,
          Map<String, String> flowFrom,
        })>[];
        for (final first in adjacency[root]!) {
          if (claimed.contains(first.other)) continue;
          final nodesInBranch = <String>[first.other];
          final flowFrom = <String, String>{first.edgeId: first.other};
          claimed.add(first.other);
          for (var i = 0; i < nodesInBranch.length; i++) {
            final n = nodesInBranch[i];
            for (final l in adjacency[n]!) {
              if (l.other == root || !claimed.add(l.other)) continue;
              nodesInBranch.add(l.other);
              flowFrom[l.edgeId] = l.other; // away from the tank → toward it
            }
          }
          branches.add((nodes: nodesInBranch, flowFrom: flowFrom));
        }
        if (branches.any((b) => b.nodes.any(isMoverNode))) {
          for (final b in branches) {
            if (b.nodes.any(isMoverNode)) continue;
            if (b.nodes.any((n) =>
                roleOf(n) == NodeRole.fixture ||
                explicitDemandKeys.contains(n))) {
              continue;
            }
            for (final n in b.nodes) {
              if (degree(n) == 1 && roleOf(n) != NodeRole.plant) {
                fillLeaves.add(n);
              }
            }
            fillEdgeFlowFrom.addAll(b.flowFrom);
          }
        }
      }
      // Round 16 (air-systems-2-ahu-intake-leaf-phantom-supply) — on an AIR
      // service rooted at an air-unit PLANT (AHU, fan, ducted unit), a BARE
      // leaf whose single duct joins the unit itself is its fresh-air INTAKE
      // (or, on an extract system, its discharge to outside) — an open
      // boundary, not a terminal. It used to bear the flat per-terminal
      // default (0.05 m³/s) pointing OUT of the unit: +8 % on the fan
      // airflow, a phantom 50 L/s on the supply balance and a Ø125 intake in
      // the BOM. It now bears no load, and its duct is sized on the airflow
      // the unit delivers, oriented toward the unit (a 100 % outdoor-air
      // basis — `// VERIFY` conservative for a mixed-air AHU, whose outdoor
      // air is a fraction of the supply).
      //
      // Round 17 (regression-ahu-intake-behind-damper-phantom) — the intake is
      // usually drawn WITH its outdoor-air damper (AHU -> motorised damper ->
      // bare leaf), so the walk now passes through degree-2 inline DAMPERS
      // that carry no airflow of their own to reach the bare leaf; every edge
      // of that chain is an intake edge (load-free, carrying the delivered
      // flow inward). A bare junction is NOT walked through (an AHU -> j ->
      // bare end is an undrawn terminal, judged as before).
      final airIntakeEdges = <String, String>{}; // edge id -> its upstream node
      final airIntakeLeaves = <String>{};
      if (regime == FlowRegime.air && roleOf(root) == NodeRole.plant) {
        bool isIntakeAccessory(String id) {
          final n = net.nodeById(id);
          return n != null &&
              degree(id) == 2 &&
              !explicitDemandKeys.contains(id) &&
              (n.component == NodeComponent.motorizedDamper ||
                  n.component == NodeComponent.volumeDamper ||
                  n.component == NodeComponent.fireDamper);
        }

        for (final l
            in adjacency[root] ?? const <({String edgeId, String other})>[]) {
          // Walk outward from the unit: (edge, far node) pairs of the chain.
          final chain = <({String edgeId, String node})>[
            (edgeId: l.edgeId, node: l.other),
          ];
          final seen = <String>{root, l.other};
          var cur = l.other;
          var via = l.edgeId;
          while (isIntakeAccessory(cur)) {
            final next = adjacency[cur]!.firstWhere((x) => x.edgeId != via);
            if (!seen.add(next.other)) break;
            chain.add((edgeId: next.edgeId, node: next.other));
            via = next.edgeId;
            cur = next.other;
          }
          final ln = net.nodeById(cur);
          if (degree(cur) == 1 &&
              ln != null &&
              ln.component == null &&
              ln.role == NodeRole.main &&
              !explicitDemandKeys.contains(cur)) {
            airIntakeLeaves.add(cur);
            // Each chain edge's flow comes FROM its outer (leaf-side) node.
            for (final c in chain) {
              airIntakeEdges[c.edgeId] = c.node;
            }
          }
        }
      }
      // Round 26 r3 — a VENT leaf at the UPPER end of a vent riser, joined by
      // nothing else (no tie, no drainage, no fitting, no explicit load), is
      // an open VTR: air leaves the system there, no vent load enters. With
      // two VTRs on one vent component (two stacks headered together) only
      // one is the tree root; the other used to take the 2-DFU leaf default
      // as a phantom load (a 8-DFU stack's header read 10 DFU, one DN up).
      bool isOpenVtr(String n) {
        if (n == root || degree(n) != 1 || explicitDemandKeys.contains(n)) {
          return false;
        }
        final node = net.nodeById(n);
        if (node == null ||
            node.component != null ||
            node.role != NodeRole.main) {
          return false;
        }
        final e = net.edgeById(adjacency[n]!.first.edgeId);
        if (e == null) return false;
        final o = net.nodeById(e.fromId == n ? e.toId : e.fromId);
        if (o == null) return false;
        if (e.kind == EdgeKind.riser) return o.floorIndex < node.floorIndex;
        // Round 26 r4 — a VTR drawn as a short RUN on the TOP storey (the
        // Round-22 'bare vent junction on the top storey reads the roof'
        // idiom), reached horizontally from the top of a vent stack: o is
        // the UPPER end of a vent riser (rising from a lower floor, nothing
        // rising above it) on the component's top storey. It took the 2-DFU
        // default, so a header read B's 8 DFU + 2 and B's stack went one DN
        // up (DN50 vs DN40 alone).
        // Round 27 (residuals-5) — tested against ITS OWN stack top (o, with
        // nothing rising above it), not the component's top storey: another
        // stack's riser VTR one storey higher used to turn this run VTR into
        // a 2-DFU phantom load (the small stack one DN up).
        if (o.floorIndex != node.floorIndex) return false;
        var fromBelow = false;
        for (final l
            in adjacency[o.id] ?? const <({String edgeId, String other})>[]) {
          final r = net.edgeById(l.edgeId);
          if (r == null || r.kind != EdgeKind.riser) continue;
          final f = net.nodeById(l.other)?.floorIndex;
          if (f == null) continue;
          if (f > o.floorIndex) return false;
          if (f < o.floorIndex) fromBelow = true;
        }
        return fromBelow;
      }

      final ventTerminals = <String>{
        if (service == ServiceType.vent)
          for (final n in component)
            if (isOpenVtr(n)) n,
      };
      loadFreeSet = {
        ...outfalls,
        ...fillLeaves,
        ...airIntakeLeaves,
        ...ventTerminals,
      };
      airIntakeLeavesOut?.addAll(airIntakeLeaves);

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

      // Round 12 (mech-props-2 recirc-checkvalve) — a CHECK VALVE is a
      // directional cut. A hot-water recirculation return closed back to the
      // heater through a check valve carries NO draw-off flow (the valve
      // blocks it), so it is not a parallel supply path: Hardy–Cross used to
      // route ~26 % of the peak backwards through it and size the supply main
      // for ~74 % of its draw-off. When cutting the edges at every check valve
      // leaves the component acyclic, it is sized as a TREE with those edges
      // traversed last ([serviceSpanningTree] `deferredEdgeIds`), so the
      // return is a zero-draw-off branch and the supply carries the full
      // curve(UBAP). A genuine ring that stays looped after the cut keeps the
      // Hardy–Cross split.
      //
      // Round 13 (regression-checkvalve-cut-ignores-direction) — the cut now
      // reads the valve's DIRECTION (its drawn in-edge -> out-edge). Only check
      // valves that sit ON a cycle are considered ([_classifyLoopCheckValves]):
      //   * every one a RETURN valve (it passes flow TOWARD the root — the HW
      //     return closing back to the heater) => the Round-12 cut;
      //   * every one a PARALLEL DISCHARGE valve (its outlet is reachable from
      //     the root only THROUGH a check valve — duty/standby pump legs onto a
      //     common header) => the tree runs through the first leg and EVERY
      //     other leg is sized on the same full set flow afterwards (a standby
      //     pump is a full-duty machine, never a DN15 leg);
      //   * Round 27 r3 (binding design decision) — the DRAWN direction is
      //     authoritative when unambiguous; each valve is classified with
      //     only itself removed: permitted direction toward the root => a
      //     RETURN (zeroed), else a FEED (a transparent pipe; a parallel
      //     duty/standby set keeps the standby-leg rule). Mixed sets zero
      //     exactly the returns. Hop / shortest-path draw-off heuristics
      //     could not tell a mis-drawn return from a genuine second feed (the
      //     same graph) and failed review three times.
      //   * Round 27 r6 (binding refinement) — a valve on a MOVER leg is
      //     never zero-forced; parallel sets also form structurally.
      //   * Round 27 r7 (binding orchestrator decision) — orientation
      //     precedence: drawn valve > coherent mover on the leg > structural
      //     root-chain cue > ENVELOPE (several undecided root chains: every
      //     plausible discharge solved, each edge sized on the max |flow|).
      //     Classification reads NO distance (rule 2 counts hops), so
      //     calibration and plan coordinates never move it. A mover leg is
      //     never zero-forced or reversed.
      //
      // Round 28 (regression-classifier-quadratic-dijkstra) — the node
      // predicates are resolved ONCE per component into sets: the classifier
      // calls them on every edge relaxation, and `net.nodeById` is a linear
      // scan, which made one sizing of a 30-riser hotel with return valves
      // cost over a second.
      final cvNodeIds = <String>{};
      final moverNodeIds = <String>{};
      final demandNodeIds = <String>{};
      if (isLooped && regime == FlowRegime.pressurized) {
        final byId = {for (final n in net.nodes) n.id: n};
        final ends = <String>{
          for (final e in componentEdges) ...[e.fromId, e.toId],
        };
        for (final id in ends) {
          final c = byId[id]?.component;
          if (c == NodeComponent.checkValve) cvNodeIds.add(id);
          if (c == NodeComponent.pump ||
              c == NodeComponent.boosterSet ||
              c == NodeComponent.supplyFan) {
            moverNodeIds.add(id);
          }
          if (id != root &&
              (explicitDemandKeys.contains(id) || bearsDefaultDemand(id))) {
            demandNodeIds.add(id);
          }
        }
      }
      final returnChainKeys = <String>{};
      List<_CheckValvePlan> classify(
              [Set<String> closedMoverLegs = const {}]) =>
          _classifyLoopCheckValves(
            componentEdges: componentEdges,
            root: root,
            isCheckValve: cvNodeIds.contains,
            isMover: moverNodeIds.contains,
            isDemand: demandNodeIds.contains,
            closedMoverLegs: closedMoverLegs,
            returnChainEnvelope: service == ServiceType.hotWater,
            returnChainKeysOut: returnChainKeys,
          );
      final cvPlans = (isLooped && regime == FlowRegime.pressurized)
          ? classify()
          : const <_CheckValvePlan>[];

      // The flow solve of this component under one check-valve plan; returns
      // the keys of the mover legs whose BALANCED split ran against their
      // pump (Round 27 r8 — the Hardy–Cross path only: the tree path has no
      // balance to run against a pump).
      Set<String> runComponent(_CheckValvePlan? cvPlan) {
        if (service == ServiceType.hotWater && cvPlan != null) {
          checkValveFeedsRingOut?.addAll(cvPlan.feedsRingValveIds);
        }
        if (cvPlan != null) {
          checkValveAmbiguousOut?.addAll(cvPlan.ambiguousValves);
        }
        final checkValveEdgeIds = cvPlan?.deferredEdgeIds ?? const <String>{};
        final cutBreaksLoops = checkValveEdgeIds.isNotEmpty &&
            _isForest([
              for (final e in componentEdges)
                if (!checkValveEdgeIds.contains(e.id)) (e.fromId, e.toId),
            ]);
        final deferred = cutBreaksLoops ? checkValveEdgeIds : const <String>{};
        final standbyLegs = cutBreaksLoops
            ? (cvPlan?.standbyLegs ?? const <_StandbyLeg>[])
            : const <_StandbyLeg>[];
        // Round 26 r4 (binding design decision) — a RETURN check valve carries
        // NO draw-off, whatever the return-side walk decided. A RETURN valve's
        // two edges (Round 27 r3: each valve classified on its own drawn
        // direction; feed valves stay pipes) are ALWAYS out of the
        // Hardy–Cross loop set and sized at zero flow, oriented in the physical
        // return direction (up-node -> valve -> down-node). If the rest of the
        // component is a forest the tree path above does it (the valve edges
        // are deferred); if it still loops (a ring main with a return teed from
        // its bare tee, a hotel return teed at / beyond the top fixture) the
        // Hardy–Cross split runs on that REMAINDER — never on the network
        // including the valve, which used to route up to ~40 % of the peak
        // forward through the return valve and size the heater feed for the
        // rest. The walk cannot tell a ring segment from a return riser (both
        // orientations of that ambiguity exist), so the valve cut does not
        // depend on it; only the ring-vs-return split of the ambiguous segment
        // does.
        final returnValveFlowFrom =
            cvPlan?.returnValveFlowFrom ?? const <String, String>{};
        final returnFreeLoopEdges = returnValveFlowFrom.isEmpty
            ? componentEdges
            : [
                for (final e in componentEdges)
                  if (!returnValveFlowFrom.containsKey(e.id)) e,
              ];
        void zeroReturnValves() {
          for (final en in returnValveFlowFrom.entries) {
            allFlows[en.key] = const FlowRate(0);
            edgeFlowFrom[en.key] = en.value;
            if (useUbap) fixtureUnitsOut?[en.key] = 0;
          }
        }

        // Round 27 r4 (orchestrator sign-off) — a ZERO-FLOW check valve (a
        // classified RETURN, or a FEED the Hardy–Cross balance CLOSED) isolates
        // the pipes behind it from every draw-off point. Those pipes are sized
        // at ZERO flow (the DN15 minimum, fixture units 0) — never silently left
        // out of the result because the balance (mech-props-6: an exactly-zero
        // edge stays unsized) or the tree (a demand-free dead end) dropped
        // them, which made the BOM / canvas / riser lose the return pipework
        // depending only on whether the drawing was calibrated. Walked from
        // each side of the valve over unsized / zero-flow pipes (never through
        // another check valve), oriented in the valve's permitted direction:
        // toward the valve on its inlet side, away from it on its outlet side.
        // Pipes that carry flow are left untouched.
        void sizeZeroPockets(Iterable<_Cv> valves) {
          if (valves.isEmpty) return;
          final cAdj = <String, List<NetEdge>>{};
          for (final e in componentEdges) {
            (cAdj[e.fromId] ??= []).add(e);
            (cAdj[e.toId] ??= []).add(e);
          }
          bool zero(NetEdge e) =>
              (allFlows[e.id]?.cubicMetersPerSecond ?? 0.0).abs() <= 1e-15;
          final pocketEdges = <String>{};
          for (final c in valves) {
            for (final (start, inletSide) in [
              (c.upNode, true),
              (c.downNode, false),
            ]) {
              final seen = <String>{start};
              final stack = [start];
              while (stack.isNotEmpty) {
                final n = stack.removeLast();
                for (final e in cAdj[n] ?? const <NetEdge>[]) {
                  final m = e.fromId == n ? e.toId : e.fromId;
                  if (m == c.id ||
                      net.nodeById(m)?.component == NodeComponent.checkValve ||
                      !zero(e)) {
                    continue;
                  }
                  // Round 27 r7 — a zero-flow pipe the tree already holds
                  // (a demand-free dead end behind a return valve) is
                  // oriented the same way, never root-outward (the first
                  // walk to reach a pipe orients it).
                  if (pocketEdges.add(e.id)) {
                    allFlows[e.id] = const FlowRate(0);
                    edgeFlowFrom[e.id] = inletSide ? m : n;
                    if (useUbap) fixtureUnitsOut?[e.id] = 0;
                  }
                  if (seen.add(m)) stack.add(m);
                }
              }
            }
          }
        }

        // Round 27 r7 — MOVER LEGS ARE NEVER ZERO-FORCED OR REVERSED: a feed
        // valve on a pump / booster / supply-fan leg is exempt from the
        // Hardy–Cross "close a feed the balance runs against" path. When the
        // solved flow runs against the leg's pump direction the leg stays open,
        // every edge of it is sized on |flow| oriented in the pump's direction
        // (the mover duty is that |flow|, never 0), and the valve is reported
        // (checkValveAgainstPumpOut). The pump direction comes from the
        // drawing (or hops), never metres, so calibration never turns it.
        final moverValveIds = <String>{
          for (final leg in cvPlan?.moverLegs ?? const <_MoverLeg>[])
            ...leg.valveIds,
        };
        Set<String> orientMoverLegs(_CheckValvePlan? plan) {
          final againstKeys = <String>{};
          for (final leg in plan?.moverLegs ?? const <_MoverLeg>[]) {
            var against = false;
            for (var i = 0; i < leg.edgeIds.length; i++) {
              final id = leg.edgeIds[i];
              final q = allFlows[id]?.cubicMetersPerSecond ?? 0.0;
              if (q.abs() <= 1e-15) continue;
              final from = edgeFlowFrom[id];
              if (from != null && from != leg.fromNodeIds[i]) against = true;
              edgeFlowFrom[id] = leg.fromNodeIds[i];
            }
            if (!against) continue;
            againstKeys.add(leg.key);
            if (leg.valveIds.isEmpty) {
              // r8 — a VALVELESS mover leg: named on its pump(s).
              moverAgainstBalanceOut?.addAll(leg.pumpIds);
            } else {
              checkValveAgainstPumpOut?.addAll(leg.valveIds);
            }
          }
          return againstKeys;
        }

        // Round 12 (mech-props-2 gravity-loop) — on the TREE path a looped
        // component's CLOSING edges (left out of the deterministic spanning
        // tree) used to go silently UNSIZED, the choice of which depending on
        // edge order. Each closing edge now carries the LARGER load of the
        // sized edges it touches (a conservative size, never a phantom
        // under-size) and — on a gravity loop — is flagged `loopUnbalanced` so
        // Review surfaces the provisional split. A check-valve closing edge
        // instead carries its valve's own through-flow (the other edge at the
        // inline valve), unflagged.
        final closingEdgeIds = <String>{};
        Map<String, double> withClosing(Map<String, double> m) {
          final closing = [
            for (final e in componentEdges)
              if (!m.containsKey(e.id)) e,
          ];
          if (closing.isEmpty) return m;
          final out = {...m};
          for (final e in closing) {
            closingEdgeIds.add(e.id);
            // Round 27 — a deferred RETURN-SIDE pipe (not a valve leg) that
            // closes the tree carries no draw-off, whichever way it was drawn.
            if (deferred.contains(e.id) &&
                returnValveFlowFrom.isNotEmpty &&
                net.nodeById(e.fromId)?.component != NodeComponent.checkValve &&
                net.nodeById(e.toId)?.component != NodeComponent.checkValve) {
              out[e.id] = 0;
              continue;
            }
            final cvNode = deferred.contains(e.id)
                ? (net.nodeById(e.fromId)?.component == NodeComponent.checkValve
                    ? e.fromId
                    : e.toId)
                : null;
            var best = 0.0;
            for (final o in componentEdges) {
              if (o.id == e.id || !m.containsKey(o.id)) continue;
              final touches = cvNode != null
                  ? (o.fromId == cvNode || o.toId == cvNode)
                  : (o.fromId == e.fromId ||
                      o.fromId == e.toId ||
                      o.toId == e.fromId ||
                      o.toId == e.toId);
              if (touches && m[o.id]! > best) best = m[o.id]!;
            }
            out[e.id] = best;
          }
          return out;
        }

        void flagGravityClosing() {
          if (regime != FlowRegime.gravity) return;
          loopUnbalancedEdges.addAll(closingEdgeIds);
        }

        // Round 13 — duty/standby parallel legs: every standby leg carries the
        // SAME flow (and fixture units) as the duty leg's check valve, oriented
        // in its valve's pass direction (the tree / balance only ran through
        // one leg).
        void mirrorStandbyLegs(List<_StandbyLeg> legs) {
          for (final leg in legs) {
            var q = 0.0;
            double? units;
            for (final id in leg.dutyEdgeIds) {
              final f = allFlows[id]?.cubicMetersPerSecond ?? 0.0;
              if (f > q) q = f;
              final u = fixtureUnitsOut?[id];
              if (u != null && (units == null || u > units)) units = u;
            }
            if (q <= 0) continue;
            for (var i = 0; i < leg.edgeIds.length; i++) {
              allFlows[leg.edgeIds[i]] = FlowRate(q);
              edgeFlowFrom[leg.edgeIds[i]] = leg.fromNodeIds[i];
              if (units != null) fixtureUnitsOut?[leg.edgeIds[i]] = units;
              closingEdgeIds.remove(leg.edgeIds[i]);
              parallelLegEdgeIdsOut?.add(leg.edgeIds[i]);
            }
          }
        }

        if (isLooped &&
            !cutBreaksLoops &&
            (regime == FlowRegime.pressurized || regime == FlowRegime.air)) {
          final demandFlow = <String, double>{};
          var nodeUbapForBridges = const <String, double>{};
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
              final ubap = (nodeFixtureUnits[n] ??
                      (bearsDefaultDemand(n) ? fuPerLeaf : 0.0)) *
                  (dualSupplyNodes.contains(n) ? dualFactor : 1.0);
              if (ubap > 0) {
                nodeUbap[n] = ubap;
                totalUbap += ubap;
              }
            }
            if (profile.demandCurveExceeded(totalUbap, system: serviceFlush)) {
              for (final e in componentEdges) {
                demandExtrapolatedEdges.add(e.id);
              }
            }
            nodeUbapForBridges = nodeUbap;
            if (totalUbap > 0) {
              final totalFlow = profile
                  .probableFlowForFixtureUnits(totalUbap, system: serviceFlush)
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
                  : (bearsDefaultDemand(n) ? demand.cubicMetersPerSecond : 0.0);
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
                    mounting: mounting,
                  ).meters;
                  if (l > 0) return l;
                }
                final px = runPixelLength(e, net); // 0 for a riser
                return px > 1.0 ? px : 1.0;
              }(),
          };
          // Round 27 r3 — a FEED check valve is a transparent pipe of the
          // loop set, but a check valve SHUTS under reverse pressure: when the
          // balanced split would run against one (a valve on a ring segment
          // whose far side is better fed the other way round), it is closed —
          // zero flow, oriented in its permitted direction — and the ring is
          // re-balanced without it, as long as every draw-off point stays fed.
          // Round 27 r6 — a duty/standby set whose header is ALSO reached by
          // a valve-free pipe (a plain-pipe recirculation return) stays a
          // Round-13 set on the balance path too: the standby legs leave the
          // loop set and mirror the duty leg afterwards.
          final hcStandby = cvPlan?.standbyLegs ?? const <_StandbyLeg>[];
          final hcStandbyEdges = {
            for (final leg in hcStandby) ...leg.edgeIds,
          };
          final baseLoopEdges = hcStandbyEdges.isEmpty
              ? returnFreeLoopEdges
              : [
                  for (final e in returnFreeLoopEdges)
                    if (!hcStandbyEdges.contains(e.id)) e,
                ];
          final closedFeed = <String, String>{};
          var loopEdges = baseLoopEdges;
          LoopBalanceResult balance(List<NetEdge> es) => balanceFlows(
                edges: [
                  for (final e in es) (id: e.id, from: e.fromId, to: e.toId),
                ],
                root: root,
                demand: demandFlow,
                resistance: (id) => lengthById[id]!,
                exponent: regime == FlowRegime.air ? 2.0 : 1.852,
              );
          var balanced = balance(loopEdges);
          for (var guard = 0; guard < 64; guard++) {
            final reversed = [
              for (final c in cvPlan?.feedValves ?? const <_Cv>[])
                if (!moverValveIds.contains(c.id) &&
                    !closedFeed.containsKey(c.inE.id) &&
                    ((c.inE.fromId == c.upNode ? 1.0 : -1.0) *
                            (balanced.edgeFlow[c.inE.id] ?? 0.0)) <
                        -1e-12)
                  c,
            ];
            if (reversed.isEmpty) break;
            final next = {
              ...closedFeed,
              for (final c in reversed) ...{
                c.inE.id: c.upNode,
                c.outE.id: c.id
              },
            };
            final candidate = [
              for (final e in baseLoopEdges)
                if (!next.containsKey(e.id)) e,
            ];
            final reach = <String>{root};
            final st = [root];
            final cAdj = <String, List<String>>{};
            for (final e in candidate) {
              (cAdj[e.fromId] ??= []).add(e.toId);
              (cAdj[e.toId] ??= []).add(e.fromId);
            }
            while (st.isNotEmpty) {
              for (final m in cAdj[st.removeLast()] ?? const <String>[]) {
                if (reach.add(m)) st.add(m);
              }
            }
            if (!demandFlow.keys.every(reach.contains)) break;
            closedFeed
              ..clear()
              ..addAll(next);
            loopEdges = candidate;
            balanced = balance(loopEdges);
          }
          for (final entry in balanced.edgeFlow.entries) {
            // mech-props-6 — a demand-free loop pocket (a bare duct ring drawn
            // before its diffusers) balances to EXACTLY zero flow; leave it
            // unsized, as the tree path leaves a no-demand edge (the duct
            // sizers require a positive airflow).
            if (entry.value.abs() <= 1e-12) continue;
            allFlows[entry.key] = FlowRate(entry.value.abs());
          }
          // mech-props-1 — a BRIDGE of a looped water component (a dead-end
          // branch hanging off the ring, or the feed into it) is a TREE edge:
          // every fixture beyond it is served only through it, so it carries the
          // diversified flow of ITS OWN far-side units, curve(far UBAP), exactly
          // like the tree path. The ring-share split above gives it
          // total × far/total, which (the curve being concave through the
          // origin) is never more than curve(far) — and on a ring with many
          // branches it under-sized every branch (8 UBAP sized for 0.245 L/s
          // instead of 0.400 L/s). Ring (2-edge-connected) edges keep the share.
          if (useUbap && nodeUbapForBridges.isNotEmpty) {
            final far = _bridgeFarSideSums(
              edges: [
                for (final e in loopEdges)
                  (id: e.id, from: e.fromId, to: e.toId),
              ],
              root: root,
              weight: nodeUbapForBridges,
            );
            for (final entry in far.entries) {
              if (entry.value <= 0) continue;
              allFlows[entry.key] = profile.probableFlowForFixtureUnits(
                entry.value,
                system: serviceFlush,
              );
            }
          }
          // M17 — record a best-effort (unsettled) split instead of presenting it
          // as balanced. Continuity still holds, so the sizes are usable; the
          // loop head-loss balance is what was not achieved.
          if (!balanced.converged) {
            for (final e in loopEdges) {
              loopUnbalancedEdges.add(e.id);
            }
          }
          // Orient each ring edge from the balanced flow SIGN (positive = from→to,
          // per LoopBalanceResult); a near-zero edge stays undirected (null).
          for (final e in loopEdges) {
            final q = balanced.edgeFlow[e.id] ?? 0.0;
            if (q > 1e-12) {
              edgeFlowFrom[e.id] = e.fromId;
            } else if (q < -1e-12) {
              edgeFlowFrom[e.id] = e.toId;
            }
          }
          zeroReturnValves();
          // Round 27 r4 — a feed valve the balance left at exactly zero flow
          // (closed against reverse pressure, or nothing to feed) is a CLOSED
          // valve: treated exactly like a classified RETURN for output — both
          // legs sized at zero in its permitted direction, the pipes it
          // isolates sized at zero ([sizeZeroPockets]), and never the
          // check-valve-feeds-ring advisory (it carries no draw-off, so the
          // "second feed that carries draw-off" message would contradict the
          // solve).
          final closedValves = <_Cv>[];
          for (final c in cvPlan?.feedValves ?? const <_Cv>[]) {
            if (hcStandbyEdges.contains(c.inE.id)) continue; // mirrored below
            if (!closedFeed.containsKey(c.inE.id) &&
                (balanced.edgeFlow[c.inE.id] ?? 0.0).abs() > 1e-12) {
              continue;
            }
            closedFeed[c.inE.id] = c.upNode;
            closedFeed[c.outE.id] = c.id;
            closedValves.add(c);
          }
          for (final en in closedFeed.entries) {
            allFlows[en.key] = const FlowRate(0);
            edgeFlowFrom[en.key] = en.value;
            if (useUbap) fixtureUnitsOut?[en.key] = 0;
          }
          mirrorStandbyLegs(hcStandby);
          checkValveFeedsRingOut
              ?.removeAll([for (final c in closedValves) c.id]);
          sizeZeroPockets([...?cvPlan?.returnValves, ...closedValves]);
          return orientMoverLegs(cvPlan);
        }

        if (isSanitary(service)) {
          // Accumulate DRAINAGE FIXTURE UNITS and size each edge from the code
          // capacity table (branch vs stack), not from Manning flow.
          final terminalUnits = terminalMap(
              component, root, drainageUnitsForService, kDefaultLeafDfu);
          final edgeParents = <String, String>{};
          var edgeUnits = withClosing(accumulateFixtureUnits(
            net: net,
            service: service,
            rootId: root,
            terminalUnits: terminalUnits,
            edgeParent: edgeParents,
            extraRootIds: extraRoots,
          ));
          flagGravityClosing();
          // Round 12 (mech-props-2 vent-stack-reverse-taper) — a VENT STACK is
          // sized over its whole developed length on the TOTAL DFU of the
          // drainage stack it serves (IPC 916.1 / UPC 703.2 — uniform size,
          // `// VERIFY` notAnSniClause). The tie-seeded accumulation toward the
          // VTR gives each vertical segment only the floors BELOW it, so the
          // stack base — where it relieves the soil-stack base — sized on one
          // floor (DN50 under a 96-DFU stack). Every vent RISER of one connected
          // vertical stack now carries the stack's largest riser load; branch
          // (run) vents keep their own accumulated load.
          if (service == ServiceType.vent) {
            edgeUnits =
                _uniformVentStacks(net, edgeUnits, edgeParent: edgeParents);
          }
          // water-drainage-7 — which edges carry a water closet: accumulate a
          // count of WC fixtures down the SAME tree (> 0 ⇒ the edge drains one).
          final wcTerminals = <String, double>{
            for (final n in component)
              if (n != root &&
                  (_isWaterClosetNode(net.nodeById(n)) ||
                      waterClosetNodeIds.contains(n)))
                n: 1.0,
          };
          final edgeWcCount = wcTerminals.isEmpty
              ? const <String, double>{}
              : withClosing(accumulateFixtureUnits(
                  net: net,
                  service: service,
                  rootId: root,
                  terminalUnits: wcTerminals,
                  extraRootIds: extraRoots,
                ));
          // Round 9 (plumbing-rules-floor-drain-dn40-stack) — which edges carry
          // a DN50-trap terminal (floor drain / shower / urinal): every edge
          // downstream is floored at the trap size, counted down the same tree.
          final trapTerminals = <String, double>{
            for (final n in component)
              if (n != root && _isDn50TrapNode(net.nodeById(n))) n: 1.0,
          };
          final edgeTrapCount = trapTerminals.isEmpty
              ? const <String, double>{}
              : withClosing(accumulateFixtureUnits(
                  net: net,
                  service: service,
                  rootId: root,
                  terminalUnits: trapTerminals,
                  extraRootIds: extraRoots,
                ));
          fixtureUnitsOut?.addAll(edgeUnits);
          for (final entry in edgeUnits.entries) {
            final edge = net.edges.firstWhere((e) => e.id == entry.key);
            sanitary[entry.key] = _sizeSanitaryEdge(
              edge,
              entry.value,
              ctx,
              waterClosetCount: (edgeWcCount[entry.key] ?? 0).round(),
              carriesDn50Trap: (edgeTrapCount[entry.key] ?? 0) > 0,
            );
            // Drainage flows DOWNHILL toward the collection root, so it comes FROM
            // the away-from-root (demand) endpoint. A vent carries no flow → skip.
            if (edge.service == ServiceType.drainage) {
              final parent = edgeParents[entry.key];
              if (parent != null) {
                final child = parent == edge.fromId ? edge.toId : edge.fromId;
                edgeFlowFrom[entry.key] = child;
                drainageThroughDfu[child] = entry.value;
                drainageParentNode[child] = parent;
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
          final flows = withClosing(accumulateFlows(
            net: net,
            service: service,
            rootId: root,
            terminalDemand: terminalDemand,
            edgeParent: edgeParents,
            extraRootIds: extraRoots,
          ).map((k, v) => MapEntry(k, v.cubicMetersPerSecond)))
              .map((k, v) => MapEntry(k, FlowRate(v)));
          flagGravityClosing();
          for (final entry in flows.entries) {
            // water-drainage-2 — the capacity table is for VERTICAL downpipes
            // running ≈ 1/3 full; a sloped HORIZONTAL collector carries far less
            // than a stack of the same DN, so a run is sized as a gravity drain
            // (Manning, part-full at the design slope / fill — the same sizer
            // the gravity regime uses). Risers keep the downpipe table.
            final edge = net.edgeById(entry.key)!;
            if (edge.kind != EdgeKind.riser) {
              final g = drain.sizeForFlow(
                flow: entry.value,
                slope: ctx.drainageSlope,
                fillRatio: ctx.drainageFillRatio,
                manningN: ctx.drainageManningN,
              );
              stormSizing[entry.key] = EdgeSizing(
                edgeId: entry.key,
                service: service,
                flow: entry.value,
                diameter: g.diameter,
                velocity: g.fullBoreVelocity,
                // Saturated at the largest standard drain with the flow still
                // above its usable part-full capacity ⇒ the table limit, flagged.
                overCapacity: g.usableCapacity.cubicMetersPerSecond <
                    entry.value.cubicMetersPerSecond,
                // Audit water-drainage-2 residual — the collector is a Manning
                // gravity run, so it carries the sizer's own self-cleansing
                // verdict (full-bore v ≥ 0.6 m/s at the design slope), exactly
                // as the gravity regime does for drainage (M5). A flat collector
                // that silts up is flagged instead of silently passing.
                selfCleansingOk: g.selfCleansing,
              );
            } else {
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
            }
            // Storm runoff drains TOWARD the outlet root, so it comes FROM the
            // away-from-root (roof-drain) endpoint.
            final parent = edgeParents[entry.key];
            if (parent != null) {
              final edge = net.edges.firstWhere((e) => e.id == entry.key);
              edgeFlowFrom[entry.key] =
                  parent == edge.fromId ? edge.toId : edge.fromId;
            }
          }
          // Round 12 — a downpipe never necks down below the collector that
          // discharges into it (the N17 clamp, parameterised for storm).
          // VERIFY: this is a NECKING (no-reducer-in-flow-direction) rule, NOT a
          // capacity rule — a vertical downpipe hydraulically needs less bore
          // than a part-full Manning-sized horizontal collector, so the raise is
          // conservative (flagged `stackRaisedForBranch`, general practice,
          // notAnSniClause) and may print a larger downpipe than the table.
          _clampDrainageStacksToBranches(
            net: net,
            sanitary: stormSizing,
            edgeParents: edgeParents,
            ctx: ctx,
            service: ServiceType.rainwater,
            // Round 19 (property-storm-duct-raised-downpipe-false-overcapacity)
            // — the downpipe table's over-capacity flag means "DN200 is the table
            // top, not a size that carries this flow". Once the clamp raises the
            // downpipe to the bore of the collector that feeds it, and that
            // collector (Manning part-full at the design slope — a horizontal run
            // needs MORE bore than a vertical downpipe for the same flow) carries
            // at least the downpipe's whole flow WITHOUT itself saturating, the
            // raised bore is proven to carry the flow, so the flag is cleared.
            // A saturated collector (e.g. a 1 % slope), or a collector carrying
            // only part of the downpipe's flow, keeps it.
            // VERIFY notAnSniClause — general practice (part-full horizontal
            // capacity as a conservative bound on a vertical downpipe).
            raise: (edge, base, raised, governing) => EdgeSizing(
              edgeId: base.edgeId,
              service: base.service,
              flow: base.flow,
              diameter: raised,
              velocity: velocityFromFlow(base.flow, raised),
              overCapacity: base.overCapacity &&
                  !(governing != null &&
                      !governing.overCapacity &&
                      governing.flow.cubicMetersPerSecond >=
                          base.flow.cubicMetersPerSecond * (1 - 1e-9) &&
                      raised.meters >= governing.diameter.meters - 1e-9),
              stackRaisedForBranch: true,
            ),
          );
        } else if (useUbap) {
          // Per-fixture UBAP when a node carries a fixture type; else the flat
          // default for that water service.
          final terminalUnits = {
            for (final entry
                in terminalMap(component, root, nodeFixtureUnits, fuPerLeaf)
                    .entries)
              entry.key: entry.value *
                  (dualSupplyNodes.contains(entry.key) ? dualFactor : 1.0),
          };
          final edgeParents = <String, String>{};
          final edgeUnits = withClosing(accumulateFixtureUnits(
            net: net,
            service: service,
            rootId: root,
            terminalUnits: terminalUnits,
            edgeParent: edgeParents,
            deferredEdgeIds: deferred,
          ));
          fixtureUnitsOut?.addAll(edgeUnits);
          for (final entry in edgeUnits.entries) {
            allFlows[entry.key] = profile.probableFlowForFixtureUnits(
              entry.value,
              system: serviceFlush,
            );
            if (profile.demandCurveExceeded(entry.value,
                system: serviceFlush)) {
              demandExtrapolatedEdges.add(entry.key);
            }
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
            withClosing(accumulateFlows(
              net: net,
              service: service,
              rootId: root,
              terminalDemand: terminalDemand,
              edgeParent: edgeParents,
              deferredEdgeIds: deferred,
            ).map((k, v) => MapEntry(k, v.cubicMetersPerSecond)))
                .map((k, v) => MapEntry(k, FlowRate(v))),
          );
          // Supply/air flows AWAY from the source root → comes FROM the root-side
          // (parent) endpoint.
          edgeFlowFrom.addAll(edgeParents);
          // Round 16 — the unit's intake carries what the unit delivers (the
          // sum over its other ducts), flowing FROM the open leaf INTO it.
          if (airIntakeEdges.isNotEmpty) {
            var delivered = 0.0;
            for (final l in adjacency[root]!) {
              if (airIntakeEdges.containsKey(l.edgeId)) continue;
              delivered += allFlows[l.edgeId]?.cubicMetersPerSecond ?? 0.0;
            }
            // (A chain edge's map value is its OUTER node, so the flow runs
            // leaf -> damper -> unit.)
            for (final en in airIntakeEdges.entries) {
              allFlows[en.key] = FlowRate(delivered);
              edgeFlowFrom[en.key] = en.value;
              closingEdgeIds.remove(en.key);
            }
          }
        }

        // Round 26 r4 — the deferred return valve edges carry zero draw-off in
        // the tree path too; record their PHYSICAL return direction (the tree
        // reaches them from the heater side, against the valve).
        if (cutBreaksLoops) zeroReturnValves();

        mirrorStandbyLegs(standbyLegs);

        // Round 14 (mech-props-3 parallel-sources-by-id) — PARALLEL SOURCES:
        // several equal-rank degree-1 plants on one supply component (two
        // ground-tank compartments, two AHUs at opposite ends of one duct). The
        // tree can root at only one, so every OTHER source's bridge (its chain
        // of demand-free degree-2 nodes up to the first junction / terminal)
        // used to carry ZERO and print at the minimum size — which leg that was
        // depended on the node ids. Each peer source must carry the whole set
        // flow while the other is isolated, exactly like a standby leg, so its
        // bridge mirrors the root's outgoing flow (and fixture units).
        if (regime != FlowRegime.gravity &&
            roleOf(root) == NodeRole.plant &&
            degree(root) == 1) {
          final rootNode = net.nodeById(root);
          final rootRank = _supplyPlantRank(rootNode?.component, 1);
          final rootEdge = adjacency[root]!.single.edgeId;
          final q = allFlows[rootEdge]?.cubicMetersPerSecond ?? 0.0;
          final units = fixtureUnitsOut?[rootEdge];
          // Round 15 (regression-parallel-source-mirror-treats-fcus-as-peers) —
          // a terminal air unit (rank 4) is never a source peer (nor a source
          // whose peers get mirrored), and a demand-bearing plant is a delivery
          // point, not an isolated standby source.
          final peers = [
            if (rootRank < 4)
              for (final n in component)
                if (n != root &&
                    roleOf(n) == NodeRole.plant &&
                    degree(n) == 1 &&
                    !explicitDemandKeys.contains(n) &&
                    _supplyPlantRank(net.nodeById(n)?.component, 1) == rootRank)
                  n,
          ]..sort();
          for (final s in q > 0 ? peers : const <String>[]) {
            final bridge = <(String, String)>[]; // (edgeId, flow-from node)
            var cur = s;
            String? prevEdge;
            var reachedRoot = false;
            while (true) {
              final links = [
                for (final l in adjacency[cur]!)
                  if (l.edgeId != prevEdge) l,
              ];
              if (links.length != 1) break;
              final l = links.single;
              bridge.add((l.edgeId, cur));
              prevEdge = l.edgeId;
              cur = l.other;
              if (cur == root) {
                reachedRoot = true;
                break;
              }
              if (degree(cur) != 2 ||
                  explicitDemandKeys.contains(cur) ||
                  bearsDefaultDemand(cur)) {
                break;
              }
            }
            if (reachedRoot) continue;
            for (final (id, from) in bridge) {
              if ((allFlows[id]?.cubicMetersPerSecond ?? 0.0) >= q) continue;
              allFlows[id] = FlowRate(q);
              edgeFlowFrom[id] = from;
              if (units != null) fixtureUnitsOut?[id] = units;
              parallelLegEdgeIdsOut?.add(id);
            }
          }
        }

        // Round 27 r4 — the tree path's zero-flow check valves (every RETURN,
        // and a feed valve nothing downstream draws through) isolate the pipes
        // behind them: size those at zero flow too (see [sizeZeroPockets]); a
        // zero-flow feed valve is a closed valve, never the feeds-ring advisory.
        if (cvPlan != null) {
          bool zeroFlow(String id) =>
              (allFlows[id]?.cubicMetersPerSecond ?? 0.0).abs() <= 1e-15;
          final closedValves = [
            for (final c in cvPlan.feedValves)
              if (zeroFlow(c.inE.id) && zeroFlow(c.outE.id)) c,
          ];
          for (final c in closedValves) {
            for (final (e, from) in [(c.inE, c.upNode), (c.outE, c.id)]) {
              if (allFlows.containsKey(e.id)) continue;
              allFlows[e.id] = const FlowRate(0);
              edgeFlowFrom[e.id] = from;
              if (useUbap) fixtureUnitsOut?[e.id] = 0;
            }
          }
          checkValveFeedsRingOut
              ?.removeAll([for (final c in closedValves) c.id]);
          sizeZeroPockets([...cvPlan.returnValves, ...closedValves]);
          orientMoverLegs(cvPlan);
        }
        return const <String>{};
      }

      if (cvPlans.isEmpty) {
        runComponent(null);
        continue;
      }
      // Round 27 r7 — the ENVELOPE: solve every plausible discharge and size
      // each edge of the component on the largest |flow| any of them gives
      // (its direction, fixture units from that scenario; first on ties).
      // Round 27 r8 — plus, for every mover leg whose balanced split ran
      // against its pump, scenario (a): the same readings with that leg
      // CLOSED (the r4 closed-return treatment; skipped when it starves a
      // draw-off point). Side outputs are reported only from scenarios that
      // win at least one edge of the element they name (see the doc above).
      final keys = [for (final e in componentEdges) e.id];
      final ringBefore = {...?checkValveFeedsRingOut};
      final ambBefore = {...?checkValveAmbiguousOut};
      final againstBefore = {...?checkValveAgainstPumpOut};
      final moverAgainstBefore = {...?moverAgainstBalanceOut};
      final unbalancedBefore = {...loopUnbalancedEdges};
      final parallelBefore = {...?parallelLegEdgeIdsOut};
      void restore() {
        for (final k in keys) {
          allFlows.remove(k);
          edgeFlowFrom.remove(k);
          fixtureUnitsOut?.remove(k);
        }
        checkValveFeedsRingOut
          ?..clear()
          ..addAll(ringBefore);
        checkValveAmbiguousOut
          ?..clear()
          ..addAll(ambBefore);
        checkValveAgainstPumpOut
          ?..clear()
          ..addAll(againstBefore);
        moverAgainstBalanceOut
          ?..clear()
          ..addAll(moverAgainstBefore);
        loopUnbalancedEdges
          ..clear()
          ..addAll(unbalancedBefore);
        parallelLegEdgeIdsOut
          ?..clear()
          ..addAll(parallelBefore);
      }

      final results = <({
        Map<String, FlowRate> flows,
        Map<String, String> from,
        Map<String, double> units,
        Set<String> ring,
        Map<String, CheckValveAmbiguity> amb,
        Set<String> against,
        Set<String> moverAgainst,
        Set<String> unbalanced,
        Set<String> parallel,
      })>[];
      Set<String> run(_CheckValvePlan plan) {
        restore();
        final againstKeys = runComponent(plan);
        results.add((
          flows: {
            for (final k in keys)
              if (allFlows[k] != null) k: allFlows[k]!
          },
          from: {
            for (final k in keys)
              if (edgeFlowFrom[k] != null) k: edgeFlowFrom[k]!,
          },
          units: {
            for (final k in keys)
              if (fixtureUnitsOut?[k] != null) k: fixtureUnitsOut![k]!,
          },
          ring: {...?checkValveFeedsRingOut}.difference(ringBefore),
          amb: {
            for (final MapEntry(key: id, value: l)
                in (checkValveAmbiguousOut ?? const {}).entries)
              if (ambBefore[id] != l) id: l,
          },
          against: {...?checkValveAgainstPumpOut}.difference(againstBefore),
          moverAgainst:
              {...?moverAgainstBalanceOut}.difference(moverAgainstBefore),
          unbalanced: loopUnbalancedEdges.difference(unbalancedBefore),
          parallel: {...?parallelLegEdgeIdsOut}.difference(parallelBefore),
        ));
        return againstKeys;
      }

      final againstLegs = <String>{};
      for (final plan in cvPlans) {
        againstLegs.addAll(run(plan));
      }
      // Scenario (a): every leg that ran against its pump closed together;
      // when that starves a draw-off point, each leg closed on its own.
      //
      // Round 28 (regression-envelope-scenario-a-not-iterated) — scenario
      // (a) is ITERATED to a fixed point: closing the legs that ran against
      // their pump can leave a leg that ran WITH its pump in the first solve
      // as the only open return path, and that leg then carries draw-off
      // backwards. Its key joins the closed set and the closed reading is
      // re-solved while the set grows (each pass adds at least one mover
      // leg, so it stops within the number of mover legs). Without this a
      // hotel of 24+ circulator returns sized its supply main on the
      // re-opened leg's share — one DN small (2.75 L/s DN50 against the
      // open network's curve(192 UBAP) = 4.60 L/s DN65).
      //
      // Round 28 (residuals-2) — a hot-water root chain the classifier names
      // a plausible valveless RECIRCULATION RETURN (beside a pump on the
      // heater discharge) joins scenario (a) the same way: closed with a
      // pseudo return valve at its root end, enveloped with the open
      // (balanced) reading; skipped when closing it starves a draw-off point.
      var closedSet = {...againstLegs, ...returnChainKeys};
      final legCount = cvPlans.fold<int>(
          0, (m, p) => p.moverLegs.length > m ? p.moverLegs.length : m);
      for (var pass = 0; closedSet.isNotEmpty && pass <= legCount; pass++) {
        var closedPlans = classify(closedSet);
        var joint = true;
        if (closedPlans.isEmpty && closedSet.length > 1) {
          joint = false;
          closedPlans = [
            for (final k in [...closedSet]..sort()) ...classify({k}),
          ];
        }
        final grown = {...closedSet};
        for (final plan in closedPlans) {
          grown.addAll(run(plan));
        }
        // (The per-leg fallback reads each leg on its own: its against-legs
        // name no joint closure, so it is not iterated.)
        if (!joint || grown.length == closedSet.length) break;
        closedSet = grown;
      }
      // One reading: its outputs stand as written.
      if (results.length == 1) continue;

      restore();
      final winner = <String, int>{};
      for (final k in keys) {
        var best = -1;
        for (var i = 0; i < results.length; i++) {
          final q = results[i].flows[k];
          if (q == null) continue;
          if (best < 0 ||
              q.cubicMetersPerSecond >
                  results[best].flows[k]!.cubicMetersPerSecond + 1e-15) {
            best = i;
          }
        }
        if (best < 0) continue;
        winner[k] = best;
        allFlows[k] = results[best].flows[k]!;
        final from = results[best].from[k];
        if (from != null) edgeFlowFrom[k] = from;
        final fu = results[best].units[k];
        if (fu != null) fixtureUnitsOut?[k] = fu;
      }
      // The elements a side output names: a valve's two pipes; a leg (the
      // chain of degree-2 nodes through a mover / mover-leg valve).
      final cAdj = <String, List<NetEdge>>{};
      for (final e in componentEdges) {
        (cAdj[e.fromId] ??= []).add(e);
        (cAdj[e.toId] ??= []).add(e);
      }
      List<String> pipesOf(String node) =>
          [for (final e in cAdj[node] ?? const <NetEdge>[]) e.id];
      List<String> legOf(String node) {
        final out = <String>{};
        final seen = <String>{node};
        for (final first in cAdj[node] ?? const <NetEdge>[]) {
          var e = first;
          var n = node;
          while (true) {
            out.add(e.id);
            final m = e.fromId == n ? e.toId : e.fromId;
            if (m == root || !seen.add(m)) break;
            final es = cAdj[m] ?? const <NetEdge>[];
            if (es.length != 2) break;
            e = es.firstWhere((x) => x.id != e.id);
            n = m;
          }
        }
        return [...out];
      }

      bool wins(int i, Iterable<String> edgeIds) =>
          edgeIds.any((id) => winner[id] == i);
      for (var i = 0; i < results.length; i++) {
        final r = results[i];
        checkValveFeedsRingOut?.addAll([
          for (final v in r.ring)
            if (wins(i, pipesOf(v))) v,
        ]);
        checkValveAgainstPumpOut?.addAll([
          for (final v in r.against)
            if (wins(i, legOf(v))) v,
        ]);
        moverAgainstBalanceOut?.addAll([
          for (final p in r.moverAgainst)
            if (wins(i, legOf(p))) p,
        ]);
        loopUnbalancedEdges.addAll([
          for (final e in r.unbalanced)
            if (winner[e] == i) e,
        ]);
        parallelLegEdgeIdsOut?.addAll([
          for (final e in r.parallel)
            if (winner[e] == i) e,
        ]);
      }
      // An ambiguity label from the first scenario winning a pipe of its
      // valve (a valve no scenario sizes keeps the first reading's label, so
      // an ambiguous valve is always named).
      if (checkValveAmbiguousOut != null) {
        final ids = <String>{for (final r in results) ...r.amb.keys};
        for (final id in [...ids]..sort()) {
          CheckValveAmbiguity? label;
          for (var i = 0; i < results.length && label == null; i++) {
            if (wins(i, pipesOf(id))) label = results[i].amb[id];
          }
          label ??= results.firstWhere((r) => r.amb.containsKey(id)).amb[id];
          checkValveAmbiguousOut[id] = label!;
        }
      }
    }
  }

  // Sprinkler remote-area cap (see the doc above): no sprinkler pipe carries
  // more than the one-design-area demand.
  if (sprinklerDemandCap != null) {
    final capM3s = sprinklerDemandCap.cubicMetersPerSecond;
    for (final e in net.edges) {
      if (e.service != ServiceType.fireSprinkler) continue;
      final q = allFlows[e.id];
      if (q != null && q.cubicMetersPerSecond > capM3s) {
        allFlows[e.id] = sprinklerDemandCap;
      }
    }
  }
  // Hydrant standpipe design flow (see the doc above).
  if (hydrantDesignFlow != null && hydrantDesignFlow.cubicMetersPerSecond > 0) {
    final perBox = (leafDemand[ServiceType.fireHydrant] ?? const FlowRate(0))
        .cubicMetersPerSecond;
    final hydrantEdges = [
      for (final e in net.edges)
        if (e.service == ServiceType.fireHydrant) e,
    ];
    final hydrantAdj = <String, List<NetEdge>>{};
    for (final e in hydrantEdges) {
      (hydrantAdj[e.fromId] ??= []).add(e);
      (hydrantAdj[e.toId] ??= []).add(e);
    }
    for (final e in hydrantEdges) {
      final q = allFlows[e.id];
      if (q == null) continue;
      final trunk = e.kind == EdgeKind.riser ||
          q.cubicMetersPerSecond > perBox * (1 + 1e-9) + 1e-12;
      if (!trunk) continue;
      // Round 22 (regression-standpipe-every-riser-carries-total-flow) — the
      // multi-riser total (500 gpm + 250 gpm per additional riser) is the
      // COMMON supply's flow; a pipe serving only some of the stacks carries
      // the standpipe flow of the stacks DOWNSTREAM of it (one stack ⇒ the
      // 500 gpm most-remote rating, SNI 03-1745 / NFPA 14). Never above the
      // caller's design flow.
      var flow = hydrantDesignFlow;
      final from = edgeFlowFrom[e.id];
      if (from == e.fromId || from == e.toId) {
        final down = from == e.fromId ? e.toId : e.fromId;
        final seen = <String>{down};
        final reached = <String>{e.id};
        final downstream = <NetEdge>[e];
        final stack = [down];
        while (stack.isNotEmpty) {
          final cur = stack.removeLast();
          for (final x in hydrantAdj[cur] ?? const <NetEdge>[]) {
            if (!reached.add(x.id)) continue;
            downstream.add(x);
            final o = x.fromId == cur ? x.toId : x.fromId;
            if (seen.add(o)) stack.add(o);
          }
        }
        final stacks = math.max(1, parallelStandpipeCount(net, downstream));
        final served = standpipeFlow(stacks);
        if (served.cubicMetersPerSecond < flow.cubicMetersPerSecond) {
          flow = served;
        }
      }
      allFlows[e.id] = flow;
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
            ctx: ctx,
            codeMinimum: entry.value.diameter,
            // Round 17 (gravity-3-1) — the auto pick is the DFU / WC-count /
            // trap / stack≥branch floor, so a smaller hand pick is flagged.
            minimumCompliant: entry.value.diameter);
  }
  for (final entry in stormSizing.entries) {
    final override = sizeOverrides[entry.key];
    result[entry.key] = override == null
        ? entry.value
        // A horizontal collector was Manning-sized (water-drainage-2), so its
        // override stays on that basis; a downpipe keeps continuity.
        : applySizeOverride(entry.value, override,
            ctx: ctx,
            manningRun: net.edgeById(entry.key)?.kind != EdgeKind.riser,
            // Round 17 (gravity-3-1) — the auto pick is the smallest downpipe
            // whose tabulated capacity / the smallest collector whose usable
            // part-full Manning capacity carries the flow (or the N17
            // stack ≥ collector clamp), so any smaller pick cannot carry it.
            minimumCompliant: entry.value.diameter);
  }
  // Round 25 (drainage-4-1) — the N17 clamp ran on the AUTO sizes; a hand-
  // OVERSIZED branch / stack / collector must not leave the pipe below it
  // smaller in the direction of flow (IPC 704.2: no reduction in size in the
  // direction of flow). Walk the post-override map downstream of every
  // override: an auto edge is raised (flagged `stackRaisedForBranch`), an
  // overridden edge smaller than an overridden pipe above it is flagged
  // `belowCodeMinimum` (→ the gravity-below-code-minimum warning).
  if (sizeOverrides.isNotEmpty) {
    _clampGravityDownstreamOfOverrides(
      net: net,
      result: result,
      edgeFlowFrom: edgeFlowFrom,
      sizeOverrides: sizeOverrides,
      ctx: ctx,
    );
  }
  // M17 — a ring/grid whose Hardy–Cross balance never settled: every edge of
  // that component carries a PROVISIONAL split, so mark them all (after the
  // overrides, which preserve the flag either way).
  for (final id in loopUnbalancedEdges) {
    final sized = result[id];
    if (sized != null) result[id] = sized.withLoopUnbalanced(true);
  }
  for (final id in demandExtrapolatedEdges) {
    final sized = result[id];
    if (sized != null) result[id] = sized.withDemandCurveExtrapolated(true);
  }
  edgeFlowFrom.addAll(fillEdgeFlowFrom);
  // Attach the read-only flow orientation last (after overrides), so the arrow
  // record survives an override without touching any computed size/flow.
  //
  // Round 15 (root-metamorphic-return-exhaust-flow-reversed) — every air
  // component is accumulated root-OUTWARD (the AHU / fan / louvre is its
  // source of LOAD), which is the physical flow direction only for SUPPLY
  // air. Return and exhaust air travel the other way: from the grilles TOWARD
  // the fan. Their recorded endpoint is flipped to the far end so canvas,
  // plan PDF/DXF and the riser draw extract air INTO its grilles' duct and
  // out through the fan. (`duct_static` walks from the fan and flips it back.)
  for (final id in edgeFlowFrom.keys) {
    final sized = result[id];
    if (sized == null) continue;
    var from = edgeFlowFrom[id];
    if (sized.service.isExtractAir && from != null) {
      final edge = net.edgeById(id);
      if (edge != null) from = from == edge.fromId ? edge.toId : edge.fromId;
    }
    result[id] = sized.withFlowFrom(from);
  }
  return result;
}

/// Build an [EdgeSizing] for a drainage/vent edge from its accumulated [dfu]
/// using the code capacity tables. Drainage edges report a reference full-bore
/// Manning velocity (for self-cleansing); vents have no flow velocity.
///
/// A DRAINAGE (not vent) edge carrying [waterClosetCount] > 0 water closets
/// is floored at [drain.kMinWcDrainMm] whatever its DFU (water-drainage-7),
/// and at [drain.kWcRowDrainMm] once the count exceeds the DN75 branch/stack
/// limit (Round 9, [drain.minDrainMmForWcCount]); one carrying a DN50-trap
/// terminal ([carriesDn50Trap]) is floored at [drain.kMinTrapDrainMm]. An edge
/// whose DFU exceeds the top row of its table is flagged
/// [EdgeSizing.overCapacity] (water-drainage-4) — the printed size is then the
/// table limit, not a size that carries the load.
///
/// A VENT edge is sized from the vent table AND floored at half the drain
/// diameter its load requires (the same DFU + WC/trap floors, Round 9 —
/// [drain.ventDiameterForDfu] `servedDrainMm`).
EdgeSizing _sizeSanitaryEdge(
  NetEdge edge,
  double dfu,
  SizingContext ctx, {
  int waterClosetCount = 0,
  bool carriesDn50Trap = false,
}) {
  final isStack = edge.kind == EdgeKind.riser;
  final isVent = edge.service == ServiceType.vent;
  // The drain this load needs: the DFU table, floored by the WC count and the
  // DN50-trap rule. Drain edges take it directly; vents take half of it.
  var drainMm = drain.drainDiameterForDfu(dfu, isStack: isStack).inMillimeters;
  final wcFloor =
      drain.minDrainMmForWcCount(waterClosetCount, isStack: isStack);
  if (wcFloor > drainMm) drainMm = wcFloor;
  if (carriesDn50Trap && drainMm < drain.kMinTrapDrainMm) {
    drainMm = drain.kMinTrapDrainMm;
  }
  final d = isVent
      ? drain.ventDiameterForDfu(dfu, servedDrainMm: drainMm)
      : Diameter.mm(drainMm);
  final overloaded = isVent
      ? drain.ventDfuExceedsTable(dfu)
      : drain.drainDfuExceedsTable(dfu, isStack: isStack);
  // The table pick (or the WC floor above it) IS the code minimum for this
  // load, so an auto-sized sanitary run is never flagged as not-self-cleansing
  // (G1) — there is no smaller compliant pipe to move to.
  return _sanitaryEdgeSizing(edge, d, ctx,
      codeMinimum: d, overCapacity: overloaded);
}

/// True when [node] is a terminal whose trap is DN50 minimum — a floor drain
/// component, or a shower / urinal fixture (Round 9).
bool _isDn50TrapNode(NetNode? node) {
  if (node == null) return false;
  if (node.component == NodeComponent.floorDrain) return true;
  final f = node.fixture;
  return f != null && drain.isDn50TrapFixture(f);
}

/// True when [node] carries a water-closet fixture type (water-drainage-7).
bool _isWaterClosetNode(NetNode? node) {
  final f = node?.fixture;
  return f != null && drain.isWaterCloset(f);
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
  bool overCapacity = false,
}) {
  final isVent = edge.service == ServiceType.vent;
  // Round 33 — at the fall the run is LAID at (≥ its own self-cleansing
  // minimum), the same figure the plan prints.
  final v = isVent
      ? const Velocity(0)
      : manningVelocity(
          manningN: ctx.drainageManningN,
          hydraulicRadius: Length(diameter.meters / 4.0),
          slope: laidGravitySlope(
              edge, ctx.drainageSlope, diameter.inMillimeters),
        );
  return EdgeSizing(
    edgeId: edge.id,
    service: edge.service,
    flow: const FlowRate(0),
    diameter: diameter,
    velocity: v,
    overCapacity: overCapacity,
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
/// component) pass. Applies to [ServiceType.drainage] (branch vs stack DFU
/// tables) and — Round 12 (mech-props-2 rain-downpipe-shrinks) — to
/// [ServiceType.rainwater], whose horizontal collectors are Manning part-full
/// sized (water-drainage-2) while its downpipes use the more generous
/// downpipe table, so a downpipe could neck DOWN below the collector feeding
/// it (DN100 → DN65 → DN100 in the direction of flow). Vents use one DFU
/// table (no stack/branch split) and are not touched. [raise] rebuilds the
/// riser's sizing at the raised diameter (service-specific).
void _clampDrainageStacksToBranches({
  required Network net,
  required Map<String, EdgeSizing> sanitary,
  required Map<String, String> edgeParents,
  required SizingContext ctx,
  ServiceType service = ServiceType.drainage,
  EdgeSizing Function(NetEdge edge, EdgeSizing base, Diameter raised,
          EdgeSizing? governing)?
      raise,
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
  // Round 19 — the BRANCH (non-riser) edge whose bore forced each raise (the
  // governing collector, followed through raised riser segments above), so a
  // [raise] callback can judge the raised size against the run that set it.
  final governingOf = <String, String?>{};
  double effectiveMm(String edgeId) {
    final cached = memo[edgeId];
    if (cached != null) return cached;
    final edge = net.edgeById(edgeId)!;
    var maxMm = sanitary[edgeId]!.diameter.inMillimeters;
    String? governing;
    for (final childId in childEdgesAt[awayNodeOf(edge)] ?? const <String>[]) {
      final child = net.edgeById(childId);
      if (child == null ||
          child.service != service ||
          !sanitary.containsKey(childId)) {
        continue;
      }
      final isRiser = child.kind == EdgeKind.riser;
      final childMm = isRiser
          ? effectiveMm(childId)
          : sanitary[childId]!.diameter.inMillimeters;
      if (childMm > maxMm) {
        maxMm = childMm;
        governing = isRiser ? governingOf[childId] : childId;
      }
    }
    memo[edgeId] = maxMm;
    governingOf[edgeId] = governing;
    return maxMm;
  }

  for (final edgeId in edgeParents.keys) {
    final edge = net.edgeById(edgeId);
    if (edge == null ||
        edge.kind != EdgeKind.riser ||
        edge.service != service ||
        !sanitary.containsKey(edgeId)) {
      continue;
    }
    final base = sanitary[edgeId]!.diameter.inMillimeters;
    final effective = effectiveMm(edgeId);
    if (effective > base && raise != null) {
      final gov = governingOf[edgeId];
      sanitary[edgeId] = raise(edge, sanitary[edgeId]!, Diameter.mm(effective),
          gov == null ? null : sanitary[gov]);
    } else if (effective > base) {
      sanitary[edgeId] = _sanitaryEdgeSizing(
        edge,
        Diameter.mm(effective),
        ctx,
        stackRaisedForBranch: true,
        // A DFU-table overload stays flagged through the raise (wd-4).
        overCapacity: sanitary[edgeId]!.overCapacity,
        // The N17 raise is code-MANDATED, so the raised size IS this segment's
        // code minimum (G1): necking back down to its own DFU-table pick is
        // exactly the violation the clamp exists to prevent.
        codeMinimum: Diameter.mm(effective),
      );
    }
  }
}

/// Round 25 (drainage-4-1) — see the call site. Only sizes propagated from a
/// hand OVERRIDE are enforced here (the auto sizes already passed the N17
/// clamp), so a network with no gravity override is byte-identical. Topology:
/// each gravity edge's flow comes FROM its away-from-outfall node
/// ([edgeFlowFrom]); the edges upstream of edge e are those whose flow
/// arrives at e's from-node.
void _clampGravityDownstreamOfOverrides({
  required Network net,
  required Map<String, EdgeSizing> result,
  required Map<String, String> edgeFlowFrom,
  required Map<String, Diameter> sizeOverrides,
  required SizingContext ctx,
}) {
  bool isGravity(ServiceType s) =>
      s == ServiceType.drainage || s == ServiceType.rainwater;
  // node → gravity edges whose flow ARRIVES at it (their root-side endpoint).
  final arriving = <String, List<NetEdge>>{};
  for (final e in net.edges) {
    if (!isGravity(e.service) || !result.containsKey(e.id)) continue;
    final from = edgeFlowFrom[e.id];
    if (from == null) continue;
    final to = from == e.fromId ? e.toId : e.fromId;
    (arriving[to] ??= []).add(e);
  }
  // The largest OVERRIDDEN bore upstream of an edge (its own excluded),
  // memoised; the in-progress guard breaks a gravity loop's closing edge.
  final memo = <String, double>{};
  final busy = <String>{};
  double overrideAbove(NetEdge e) {
    final cached = memo[e.id];
    if (cached != null) return cached;
    if (!busy.add(e.id)) return 0;
    var m = 0.0;
    final from = edgeFlowFrom[e.id];
    for (final up in arriving[from] ?? const <NetEdge>[]) {
      if (up.id == e.id || up.service != e.service) continue;
      if (sizeOverrides.containsKey(up.id)) {
        m = math.max(m, result[up.id]!.diameter.meters);
      }
      m = math.max(m, overrideAbove(up));
    }
    busy.remove(e.id);
    return memo[e.id] = m;
  }

  for (final e in net.edges) {
    if (!isGravity(e.service)) continue;
    final sized = result[e.id];
    if (sized == null || edgeFlowFrom[e.id] == null) continue;
    final need = overrideAbove(e);
    if (need <= sized.diameter.meters + _kDiameterEpsM) continue;
    if (sizeOverrides.containsKey(e.id)) {
      // A hand pick smaller than a hand pick above it: a code violation the
      // engineer's own picks create — flagged, never silently resized.
      result[e.id] = sized.withGravityFlags(belowMinimum: true);
    } else {
      final raised = Diameter(need);
      result[e.id] = applySizeOverride(sized, raised,
              ctx: ctx,
              codeMinimum: raised,
              manningRun: e.service == ServiceType.rainwater &&
                  e.kind != EdgeKind.riser)
          .withGravityFlags(raised: true);
    }
  }
}

/// True when the undirected [edges] (endpoint pairs) contain no cycle
/// (union-find; a parallel pair or a self-loop is a cycle). Pure.
/// One STANDBY leg of a duty/standby parallel set (Round 13): its edges in
/// flow order (pass direction of its check valve), the node each edge's flow
/// comes FROM, and the duty leg's check-valve edges whose flow it mirrors.
class _StandbyLeg {
  final List<String> edgeIds;
  final List<String> fromNodeIds;
  final List<String> dutyEdgeIds;
  const _StandbyLeg(this.edgeIds, this.fromNodeIds, this.dutyEdgeIds);
}

/// Round 27 (residuals-6) — the demand-curve branch of the [service]
/// component containing [rootId]: the flush-VALVE branch only for a cold-water
/// system that holds one of [flushValveNodeIds] (hot water never serves a
/// flush valve). The SAME per-system rule [autoSizeNetwork] applies, so a
/// consumer re-diversifying a source's summed UBAP reads the sizer's curve.
FlushSystem flushSystemForRoot(
  Network net,
  ServiceType service,
  String rootId,
  Set<String> flushValveNodeIds,
) {
  if (service != ServiceType.coldWater || flushValveNodeIds.isEmpty) {
    return FlushSystem.flushTank;
  }
  final adj = <String, List<String>>{};
  for (final e in net.edges) {
    if (e.service != service) continue;
    (adj[e.fromId] ??= []).add(e.toId);
    (adj[e.toId] ??= []).add(e.fromId);
  }
  final seen = <String>{rootId};
  final stack = [rootId];
  while (stack.isNotEmpty) {
    final n = stack.removeLast();
    if (flushValveNodeIds.contains(n)) return FlushSystem.flushValve;
    for (final m in adj[n] ?? const <String>[]) {
      if (seen.add(m)) stack.add(m);
    }
  }
  return FlushSystem.flushTank;
}

/// How a looped pressurized component's check valves are treated (Round 13).
class _CheckValvePlan {
  /// The edges the spanning tree traverses last (empty => no cut =>
  /// Hardy–Cross).
  final Set<String> deferredEdgeIds;

  /// Standby legs to size on the duty flow afterwards.
  final List<_StandbyLeg> standbyLegs;

  /// Round 26 r4 — the RETURN check valves: each valve edge -> the endpoint
  /// its (zero draw-off) flow physically comes FROM. These edges are ALWAYS
  /// out of the Hardy–Cross loop set (a return valve carries no draw-off, the
  /// Round-12 principle), whether or not the rest of the component still
  /// loops. Round 27 r3: only the valves classified RETURN (their permitted
  /// direction points toward the root); every other valve is a feed pipe.
  final Map<String, String> returnValveFlowFrom;

  /// Round 27 r3 — the FEED / discharge valves (never zeroed): transparent
  /// pipes of the loop set. Hardy–Cross closes one only when the balanced
  /// flow would run against it (a check valve shuts under reverse pressure).
  final List<_Cv> feedValves;

  /// Round 27 r3 — feed valves whose outlet the source also reaches with
  /// that valve (and every return valve) closed: the drawing a recirculation
  /// return with its arrow drawn backwards produces (a judge-only advisory on
  /// hot water; `checkValveFeedsRingOut`).
  final Set<String> feedsRingValveIds;

  /// Round 27 r4 — the RETURN valves themselves (oriented), so the sizer can
  /// size the zero-flow pipes behind them ([returnValveFlowFrom] holds only
  /// the two valve edges).
  final List<_Cv> returnValves;

  /// Round 27 r5 — every AMBIGUOUSLY drawn cycle valve -> how it was
  /// assumed (`checkValveAmbiguousOut`).
  final Map<String, CheckValveAmbiguity> ambiguousValves;

  /// Round 27 r7 — every MOVER leg carrying a feed check valve, in its
  /// pump's direction: never closed by the balance, never reported against
  /// its pump.
  final List<_MoverLeg> moverLegs;
  const _CheckValvePlan(
    this.deferredEdgeIds,
    this.standbyLegs, [
    this.returnValveFlowFrom = const {},
    this.feedValves = const [],
    this.feedsRingValveIds = const {},
    this.returnValves = const [],
    this.ambiguousValves = const {},
    this.moverLegs = const [],
  ]);

  _CheckValvePlan withLabels(Map<String, CheckValveAmbiguity> labels) =>
      _CheckValvePlan(deferredEdgeIds, standbyLegs, returnValveFlowFrom,
          feedValves, feedsRingValveIds, returnValves, labels, moverLegs);
}

/// Round 27 r7 — a MOVER leg (a pump / booster set / supply fan's chain of
/// degree-2 nodes between two junctions, or between the source and its first
/// junction) carrying feed check valve(s) [valveIds]: its edges in the
/// pump's flow order and the node each edge's flow comes FROM.
///
/// Round 27 r8 — a VALVELESS mover leg (a coherently drawn pump on a chain
/// with no check valve, on a cycle) is a [_MoverLeg] too: [valveIds] empty,
/// [pumpIds] its movers (the advisory `moverAgainstBalanceOut` is keyed on
/// them).
class _MoverLeg {
  final List<String> valveIds;
  final List<String> edgeIds;
  final List<String> fromNodeIds;
  final List<String> pumpIds;
  const _MoverLeg(this.valveIds, this.edgeIds, this.fromNodeIds,
      [this.pumpIds = const []]);

  /// The leg's identity (its sorted edge ids) — how the sizer names a leg
  /// back to the classifier (`closedMoverLegs`).
  String get key => ([...edgeIds]..sort()).join('\u0000');
}

/// Round 27 r5 (binding orchestrator decision) — how the sizer read a cycle
/// check valve drawn with NO direction (both pipes drawn into the valve node,
/// or both out of it). Its intent cannot be recovered from topology or
/// distances, so it is read CONSERVATIVELY and named for the engineer to
/// redraw (`autoSizeNetwork(checkValveAmbiguousOut:)`).
enum CheckValveAmbiguity {
  /// A CLOSED return: zero draw-off, the pipes it isolates sized at zero —
  /// every main upstream of it carries the full peak, never under-sized.
  closedReturn,

  /// A plain pipe (Hardy–Cross): closing it would cut a draw-off point off
  /// the source.
  plainPipe,

  /// A member of a parallel duty/standby (or pump + bypass) set onto one
  /// header: each leg sized on the full set flow.
  standbySet,

  /// Round 27 r6 — on a SUPPLY LEG (a pump / booster / supply fan's leg, or
  /// the source's own discharge leg): a FEED in the direction leading away
  /// from the source — never zero-forced (a pump exists to pass flow).
  supplyLeg,

  /// Round 27 r6 — a DRAWN valve on a supply leg whose arrow points back
  /// toward the source (it would starve its own pump / source): a
  /// self-contradictory drawing, read as a FEED away from the source. Round
  /// 27 r7: any drawn valve whose arrow contradicts its mover leg's
  /// direction.
  drawnAgainstSupplyLeg,

  /// Round 27 r7 — one of SEVERAL undecided root chains (no drawn valve,
  /// no mover, no structural cue): the pipework is sized on the ENVELOPE of
  /// every plausible discharge (each chain in turn the discharge, the other
  /// undecided root valves closed) — conservative both ways.
  envelope,

  /// Round 27 r7 — a valve on a MOVER leg whose balanced split runs against
  /// the pump's drawn direction: the leg is kept open and sized on |flow| in
  /// the pump's direction (`checkValveAgainstPumpOut`; never on this map
  /// from the engine — the app labels it).
  balanceAgainstPump,
}

/// A cycle check valve with its ORIENTED legs: [inE] arrives from [upNode],
/// [outE] leaves toward [downNode] (Round 27 r3: the drawn orientation when
/// unambiguous, else the Round-15 topological one).
typedef _Cv = ({
  String id,
  NetEdge inE,
  NetEdge outE,
  String upNode,
  String downNode,
});

/// Classify the CYCLE check valves of a looped pressurized component. A check
/// valve off every cycle (a branch valve) is a tree edge anyway and is
/// ignored. Pure + deterministic (valves by id).
///
/// Round 27 r3 (binding design decision, after hop / shortest-path
/// heuristics failed review three times) — topology alone CANNOT tell a
/// mis-drawn return valve from a genuine second feed: they are the same
/// graph. So:
///  1. the DRAWN direction is authoritative whenever it is unambiguous (one
///     pipe drawn INTO the valve node and one OUT of it: in -> out is the
///     permitted direction);
///  2. each valve is classified with ONLY ITSELF removed (every other check
///     valve a plain pipe): the shortest distance from the root to its
///     in- and out-node (Round 27 r7: never calibrated metres or plan pixels,
///     so calibration and plan coordinates never move a reading; Round 27
///     r8: in the BEND-FREE hop metric between its effective neighbours —
///     the first non-bend node past any elbows — so a bare elbow never
///     moves it either). A
///     permitted direction pointing TOWARD the root (out-node strictly
///     nearer) is a RETURN — zero draw-off, the Round-26 r4 cut; otherwise
///     (ties included) it is a FEED / DISCHARGE and is never zeroed: a
///     transparent pipe of the loop set, except a parallel duty/standby set
///     onto one header (legs merging at the same junction, every leg
///     carrying a pump, or — r6 — the same two leg ends), which keeps the
///     Round-13 standby-leg rule;
///  3. Round 27 r5 (binding orchestrator decision) — an AMBIGUOUSLY drawn
///     valve (both pipes into, or both out of, the valve node) has no
///     recoverable intent, so it is read CONSERVATIVELY and structurally,
///     never by distance: (1) a valve whose two leg ends equal another cycle
///     valve's is in a PARALLEL set onto one header (duty/standby, pump +
///     bypass) and keeps the standby-leg rule; (2) otherwise a CLOSED RETURN
///     (zero draw-off — every main upstream carries the full peak); (3)
///     unless closing it with the returns cuts a draw-off point off the
///     source: then a PLAIN PIPE (Hardy–Cross). Every one is reported
///     ([_CheckValvePlan.ambiguousValves]) for a judge-only advisory;
///  4. mixed sets: exactly the RETURN valves are zeroed, the rest are pipes.
///
/// Round 27 r7 (binding orchestrator decision; replaces r6's discharge-chain
/// choice by plan pixels) — ORIENTATION PRECEDENCE, applied before rules
/// 2/3: (1) a DRAWN valve direction; (2) a MOVER (pump / booster set /
/// supply fan) on the valve's degree-2 leg drawn COHERENTLY (one pipe in,
/// one out) orients the leg and every valve on it — never overridden by any
/// distance or chain choice; a coherent circulator drawn TOWARD the root on
/// a root chain is a recirculation return (an ambiguous valve on it a
/// closed return), every other mover leg a FEED that is never zero-forced
/// (an incoherently drawn pump: away from the root — the root side of a
/// root chain, else the end nearer the root in bend-free hops; a drawn
/// valve pointing back at it is [CheckValveAmbiguity.drawnAgainstSupplyLeg])
/// and is exempt from the balance closing it (the sizer keeps it open in
/// the pump's direction, [_CheckValvePlan.moverLegs]); (3) STRUCTURAL root
/// chain cues: a drawn valve pointing toward the root makes its chain a
/// return, one pointing away a discharge (its ambiguous valves feeds); (4)
/// NO distances — when two or more root chains remain plausible discharges
/// with at least one UNDECIDED (only ambiguous valves: several such chains,
/// or one beside a drawn-valve-only discharge, which is what a backwards
/// return looks like), one plan per scenario is returned — each undecided
/// chain in turn the discharge, the other undecided root valves closed (and,
/// beside a drawn-valve-only discharge, all closed); a scenario whose
/// closures starve a draw-off point is skipped; two or more survivors are
/// the ENVELOPE ([CheckValveAmbiguity.envelope], the sizer takes each edge's
/// largest |flow|); more than four scenarios, or one / none surviving, fall
/// back to the surviving reading / the r5 rule. A lone undecided chain
/// beside only valveless / mover chains keeps the r5 rule; the only
/// non-return chain out of the root is its discharge.
///
/// Round 27 r8 (binding orchestrator decision) — VALVELESS mover legs (a
/// coherently drawn mover on a valve-free cycle chain) are inputs too: a
/// structural root-chain cue in (3) (drawn toward the root => a return
/// chain, away => a discharge chain) and [_CheckValvePlan.moverLegs] entries
/// the sizer orients. [closedMoverLegs] (leg keys, [_MoverLeg.key]) asks for
/// scenario (a) of the balance-against-pump envelope: those legs CLOSED —
/// a valved leg's valves fixed returns, a valveless leg a pseudo return
/// valve at its first pump — with the r4 closed-return treatment; an empty
/// list is returned when that starves a draw-off point.
///
/// A set of DRAWN returns that would cut a draw-off point off the source is
/// a self-contradictory drawing (no water could reach it — every
/// duty/standby leg drawn header -> valve -> pump): those valves fall back
/// to the Round-15 all-cut topological orientation.
///
/// Round 27 r4 — a valve that ends at zero flow (a RETURN, or a feed the
/// sizer's Hardy–Cross balance closes) is output identically: the pipes it
/// isolates are sized at zero flow by the sizer (`sizeZeroPockets`).
List<_CheckValvePlan> _classifyLoopCheckValves({
  required List<NetEdge> componentEdges,
  required String root,
  required bool Function(String nodeId) isCheckValve,
  bool Function(String nodeId)? isMover,
  bool Function(String nodeId)? isDemand,
  Set<String> closedMoverLegs = const {},
  bool returnChainEnvelope = false,
  Set<String>? returnChainKeysOut,
}) {
  const none = [_CheckValvePlan(<String>{}, <_StandbyLeg>[])];
  final adj = <String, List<NetEdge>>{};
  for (final e in componentEdges) {
    (adj[e.fromId] ??= []).add(e);
    (adj[e.toId] ??= []).add(e);
  }
  String other(NetEdge e, String n) => e.fromId == n ? e.toId : e.fromId;

  bool connectedWithout(String a, String b, String blockedNode) {
    final seen = <String>{a};
    final stack = [a];
    while (stack.isNotEmpty) {
      final n = stack.removeLast();
      if (n == b) return true;
      for (final e in adj[n] ?? const <NetEdge>[]) {
        final m = other(e, n);
        if (m == blockedNode || !seen.add(m)) continue;
        stack.add(m);
      }
    }
    return false;
  }

  // Cycle check valves (degree 2, on a cycle).
  final cvIds = [
    for (final n in adj.keys)
      if (isCheckValve(n)) n,
  ]..sort();
  final cycleValves = <String>[];
  for (final id in cvIds) {
    final es = adj[id]!;
    if (es.length != 2) continue;
    final a = other(es[0], id), b = other(es[1], id);
    if (!connectedWithout(a, b, id)) continue; // not on a cycle
    cycleValves.add(id);
  }
  // (Round 27 r8 — a component with no cycle valve still has its VALVELESS
  // mover legs read below; the early return waits for them.)

  // Hop distance from the root with EVERY cycle check valve's edges cut.
  final cut = <String>{
    for (final id in cycleValves)
      for (final e in adj[id]!) e.id,
  };
  final dist = <String, int>{root: 0};
  final queue = [root];
  for (var i = 0; i < queue.length; i++) {
    final n = queue[i];
    for (final e in adj[n] ?? const <NetEdge>[]) {
      if (cut.contains(e.id)) continue;
      final m = other(e, n);
      if (dist.containsKey(m)) continue;
      dist[m] = dist[n]! + 1;
      queue.add(m);
    }
  }

  // The unreached part of the component (all cycle valves cut) in REGIONS: a
  // valve whose one side is reached and whose other side is not enters the
  // region of its unreached side (duty/standby grouping).
  final region = <String, int>{};
  var regionCount = 0;
  for (final start in adj.keys) {
    if (dist.containsKey(start) || region.containsKey(start)) continue;
    final rid = regionCount++;
    region[start] = rid;
    final st = [start];
    while (st.isNotEmpty) {
      final n = st.removeLast();
      for (final e in adj[n] ?? const <NetEdge>[]) {
        if (cut.contains(e.id)) continue;
        final m = other(e, n);
        if (dist.containsKey(m) || region.containsKey(m)) continue;
        region[m] = rid;
        st.add(m);
      }
    }
  }

  // Hop distance from [start] with the edges [cutE] cut and the nodes
  // [blocked] removed.
  Map<String, int> hopsFrom(String start,
      {Set<String> cutE = const {}, Set<String> blocked = const {}}) {
    final d = <String, int>{start: 0};
    final q = [start];
    for (var i = 0; i < q.length; i++) {
      final n = q[i];
      for (final e in adj[n] ?? const <NetEdge>[]) {
        if (cutE.contains(e.id)) continue;
        final m = other(e, n);
        if (blocked.contains(m) || d.containsKey(m)) continue;
        d[m] = d[n]! + 1;
        q.add(m);
      }
    }
    return d;
  }

  // (The self-contradictory-returns fallback only.) True when a valve
  // between the reached nodes [a] and [b] shortens or ties NO root ->
  // draw-off path, read on the hop distances [d0] from the root and [hops]
  // from each side.
  bool strictlyOffDrawOffPaths(String a, String b, Map<String, int> d0,
      Map<String, int> Function(String start) hops) {
    if (isDemand == null) return false;
    final da = hops(a), db = hops(b);
    var any = false;
    for (final MapEntry(key: x, value: dx) in d0.entries) {
      if (x == root || !isDemand(x)) continue;
      any = true;
      final viaAB = db[x] == null ? null : d0[a]! + 2 + db[x]!;
      final viaBA = da[x] == null ? null : d0[b]! + 2 + da[x]!;
      final via = [viaAB, viaBA]
          .whereType<int>()
          .fold<int?>(null, (m, v) => m == null || v < m ? v : m);
      if (via != null && via <= dx) return false;
    }
    return any;
  }

  // Round 27 r5 — the BEND-FREE metric of the return walk: a bare bend (a
  // degree-2 node that is no source, valve, mover or draw-off point) weighs
  // nothing, every other node half a hop on each pipe it touches, so a pipe
  // a -> b weighs exactly as a -> bend -> b (two half-weights per edge,
  // doubled to stay integral).
  bool bend(String n) =>
      n != root &&
      (adj[n]?.length ?? 0) == 2 &&
      !isCheckValve(n) &&
      !(isDemand?.call(n) ?? false) &&
      !(isMover?.call(n) ?? false);
  int bendWeight(NetEdge e) =>
      (bend(e.fromId) ? 0 : 1) + (bend(e.toId) ? 0 : 1);

  // Shortest distance from [start] with only [blocked] removed (Dijkstra in
  // HOPS — Round 27 r7: classification reads no metres and no plan pixels,
  // so calibration and plan coordinates never move it).
  //
  // Round 28 (regression-classifier-quadratic-dijkstra) — a priority queue
  // keyed on (distance, node id) replaces the full-map scan (O(V^2) per
  // call, over a second per sizing on a 30-riser x 10-storey hotel with
  // return valves): nodes settle in EXACTLY the old (distance, id) order, so
  // the map (values and insertion order) is unchanged. Results are memoised
  // per classification call (every caller only reads them).
  final distMemo = <String, Map<String, double>>{};
  Map<String, double> distFrom(String start, Set<String> blocked,
      {bool bendFree = false}) {
    final memoKey =
        '$start\u0001$bendFree\u0001${([...blocked]..sort()).join('\u0000')}';
    final hit = distMemo[memoKey];
    if (hit != null) return hit;
    final d = <String, double>{start: 0};
    final done = <String>{};
    final queue = SplayTreeSet<(double, String)>((x, y) {
      final c = x.$1.compareTo(y.$1);
      return c != 0 ? c : x.$2.compareTo(y.$2);
    })
      ..add((0.0, start));
    while (queue.isNotEmpty) {
      final top = queue.first;
      queue.remove(top);
      final best = top.$2;
      if (!done.add(best)) continue;
      for (final e in adj[best] ?? const <NetEdge>[]) {
        final m = other(e, best);
        if (blocked.contains(m) || done.contains(m)) continue;
        final nd = d[best]! + (bendFree ? bendWeight(e) : 1.0);
        final old = d[m];
        if (old == null || nd < old) {
          if (old != null) queue.remove((old, m));
          d[m] = nd;
          queue.add((nd, m));
        }
      }
    }
    return distMemo[memoKey] = d;
  }

  // The nodes reached from the root with [blocked] removed — reachability
  // only, a plain memoised BFS (Round 28; `disconnectsDemand` runs in the
  // r5 starve loops once per valve pair).
  final reachMemo = <String, Set<String>>{};
  Set<String> reachableWithout(Set<String> blocked) {
    final memoKey = ([...blocked]..sort()).join('\u0000');
    final hit = reachMemo[memoKey];
    if (hit != null) return hit;
    final seen = <String>{root};
    final q = [root];
    for (var i = 0; i < q.length; i++) {
      for (final e in adj[q[i]] ?? const <NetEdge>[]) {
        final m = other(e, q[i]);
        if (blocked.contains(m) || !seen.add(m)) continue;
        q.add(m);
      }
    }
    return reachMemo[memoKey] = seen;
  }

  // Rule 2 — shortest distance from the root with only [blocked] removed.
  Map<String, double> distWithout(Set<String> blocked) =>
      distFrom(root, blocked);

  _Cv oriented(String id, int inlet) {
    final es = adj[id]!;
    final inE = es[inlet], outE = es[1 - inlet];
    return (
      id: id,
      inE: inE,
      outE: outE,
      upNode: other(inE, id),
      downNode: other(outE, id),
    );
  }

  // The Round-15 topological orientation with EVERY cycle valve cut (null =
  // undecidable) — the fallback for a self-contradictory set of drawn
  // returns (duty/standby legs drawn header -> valve -> pump: the pump side
  // is the one the root reaches with the valves cut).
  int? topologicalInlet(String id) {
    final es = adj[id]!;
    final a = other(es[0], id), b = other(es[1], id);
    final ra = dist.containsKey(a), rb = dist.containsKey(b);
    if (ra != rb) return ra ? 0 : 1;
    if (ra &&
        dist[a] != dist[b] &&
        strictlyOffDrawOffPaths(a, b, dist, (n) => hopsFrom(n, cutE: cut))) {
      return dist[a]! > dist[b]! ? 0 : 1;
    }
    if (isMover != null && isMover(a) != isMover(b)) return isMover(a) ? 0 : 1;
    return null;
  }

  // The first node beyond [from] over [via] that is not a bare bend (Round
  // 27 r8): a valve's effective neighbour, the same with or without elbows
  // drawn next to it.
  String pastBends(String from, NetEdge via) {
    var node = other(via, from);
    var edge = via;
    final seen = <String>{from};
    while (bend(node) && seen.add(node)) {
      edge = adj[node]!.firstWhere((e) => e.id != edge.id);
      node = other(edge, node);
    }
    return node;
  }

  // Rule 2 — the permitted direction points TOWARD the root. Round 27 r8:
  // read in the BEND-FREE metric ([bendWeight]) between the valve's
  // effective neighbours ([pastBends]), so adding elbows to a drawn leg
  // never flips FEED / RETURN (plain hops did: four bends on the second
  // feed of a dual-feed ring read it a return).
  bool isReturnValve(_Cv c) {
    final d = distFrom(root, {c.id}, bendFree: true);
    final du = d[pastBends(c.id, c.inE)], dd = d[pastBends(c.id, c.outE)];
    if (du == null || dd == null) return false;
    return dd < du - 1e-9;
  }

  // A draw-off point cut off the source by [blocked] closed valves.
  bool disconnectsDemand(Set<String> blocked) {
    if (blocked.isEmpty) return false;
    final d = reachableWithout(blocked);
    for (final n in adj.keys) {
      if (blocked.contains(n) || n == root) continue;
      final demand = isDemand == null ? true : isDemand(n);
      if (demand && !d.contains(n)) return true;
    }
    return false;
  }

  // The leg end of a valve: walk from [from] over [via] through plain
  // degree-2 nodes to the first junction / root / other valve.
  String legEnd(String from, NetEdge via) {
    var node = other(via, from);
    var edge = via;
    final seen = <String>{from};
    while (seen.add(node)) {
      final es = adj[node]!;
      if (node == root || es.length != 2 || isCheckValve(node)) break;
      edge = es.firstWhere((e) => e.id != edge.id);
      node = other(edge, node);
    }
    return node;
  }

  bool legHasMover(_Cv c) {
    if (isMover == null) return false;
    for (final via in [c.inE, c.outE]) {
      var node = other(via, c.id);
      var edge = via;
      final seen = <String>{c.id};
      while (seen.add(node)) {
        if (isMover(node)) return true;
        final es = adj[node]!;
        if (node == root || es.length != 2 || isCheckValve(node)) break;
        edge = es.firstWhere((e) => e.id != edge.id);
        node = other(edge, node);
      }
    }
    return false;
  }

  // Rule 1 — the drawn inlet (one pipe drawn INTO the valve node, one OUT of
  // it); every other cycle valve is AMBIGUOUSLY drawn (rule 3).
  final drawnInlet = <String, int>{};
  final ambiguous = <String>[];
  for (final id in cycleValves) {
    final es = adj[id]!;
    final ins = [
      for (var i = 0; i < 2; i++)
        if (es[i].toId == id) i
    ];
    if (ins.length == 1) {
      drawnInlet[id] = ins.first;
    } else {
      ambiguous.add(id);
    }
  }

  // ── Round 27 r7 (binding orchestrator decision) — ORIENTATION PRECEDENCE ──
  // Highest first: (1) a DRAWN valve direction; (2) an adjacent MOVER on the
  // same degree-2 leg drawn COHERENTLY (one pipe in, one out) — it orients
  // the leg and every valve on it, never overridden by any distance or chain
  // choice; (3) STRUCTURAL root-chain cues only (a chain carrying a mover or
  // a drawn valve pointing away from the root is a discharge, one carrying a
  // drawn valve toward the root a return); (4) NO DISTANCES of any kind —
  // when several root chains stay undecided, the ENVELOPE of every
  // plausible discharge is sized instead. Classification never reads metres
  // or plan pixels (rule-2 distances are hops), so it is invariant to
  // calibration and to where anything is drawn on the plan.

  // The chain from [from] over [via] through degree-2 nodes (inline devices
  // included) to the first junction / the root: its nodes in order (the
  // last one the chain end) and the edge reaching each.
  ({List<String> nodes, List<NetEdge> edges}) walk(String from, NetEdge via) {
    final nodes = <String>[];
    final edges = <NetEdge>[];
    var node = other(via, from);
    var edge = via;
    final seen = <String>{from};
    while (true) {
      nodes.add(node);
      edges.add(edge);
      if (!seen.add(node)) break;
      final es = adj[node]!;
      if (node == root || es.length != 2) break;
      edge = es.firstWhere((e) => e.id != edge.id);
      node = other(edge, node);
    }
    return (nodes: nodes, edges: edges);
  }

  // The edge of valve [v] that joins it to its neighbour [n] (index 0/1).
  int sideToward(String v, String n) {
    final es = adj[v]!;
    return other(es[0], v) == n ? 0 : 1;
  }

  // Valves with a FIXED orientation as a feed (inlet index), as a return
  // (inlet index), and the label each reports.
  final fixedInlet = <String, int>{};
  final fixedReturn = <String, int>{};
  final labelOverride = <String, CheckValveAmbiguity>{};
  final moverLegsByKey = <String, _MoverLeg>{};

  // (2) MOVER legs — a pump / booster set / supply fan on the valve's leg
  // (either side, through degree-2 nodes and inline devices). The leg's
  // direction: the mover's COHERENT drawn direction; else (the mover's own
  // pipes drawn incoherently — an "ambiguous pump") away from the root: on a
  // root chain the root side, between two junctions the end nearer the root
  // by HOPS with the leg removed (never metres) — a drawn valve pointing
  // back at its own pump would starve it and is named; else the drawn
  // valve; else the mover side. A mover leg is a FEED (never zero-forced, never
  // closed by the balance) except a coherent circulator drawn TOWARD the
  // root on a root chain — a recirculation return.
  for (final id in cycleValves) {
    if (isMover == null) break;
    final es = adj[id]!;
    final sides = [walk(id, es[0]), walk(id, es[1])];
    // (The chain END is a junction / the root, never on the leg.)
    bool moverOn(int s) => sides[s]
        .nodes
        .sublist(0, sides[s].nodes.length - 1)
        .any((n) => n != root && isMover(n));
    final m0 = moverOn(0), m1 = moverOn(1);
    if (!m0 && !m1) continue;
    // The movers' own drawn direction as an inlet for this valve; null when
    // undrawn / contradictory.
    int? pumpInlet() {
      int? inlet;
      for (var s = 0; s < 2; s++) {
        final ns = sides[s].nodes;
        for (var i = 0; i < ns.length - 1; i++) {
          final n = ns[i];
          if (n == root || !isMover(n)) continue;
          final ea = sides[s].edges[i]; // valve side -> mover
          final eb = sides[s].edges[i + 1]; // mover -> far side
          int? cand;
          if (ea.toId == n && eb.fromId == n) cand = 1 - s; // valve -> pump
          if (ea.fromId == n && eb.toId == n) cand = s; // pump -> valve
          if (cand == null || (inlet != null && inlet != cand)) return null;
          inlet = cand;
        }
      }
      return inlet;
    }

    int? rootSide;
    final r0 = sides[0].nodes.last == root, r1 = sides[1].nodes.last == root;
    if (r0 != r1) rootSide = r0 ? 0 : 1;
    final pump = pumpInlet();
    final drawn = drawnInlet[id];
    int? inlet;
    var ret = false;
    if (pump != null) {
      inlet = pump;
      ret = rootSide != null && inlet != rootSide;
    } else if (rootSide != null) {
      inlet = rootSide;
    } else {
      final interior = {
        id,
        for (final s in sides) ...s.nodes.sublist(0, s.nodes.length - 1),
      };
      // (Bend-free hops: a bare bend never turns a pump leg.)
      final h = distFrom(root, interior, bendFree: true);
      final hx = h[sides[0].nodes.last], hy = h[sides[1].nodes.last];
      if (hx != null && hy != null && (hx - hy).abs() > 1e-9) {
        inlet = hx < hy ? 0 : 1;
      } else if (drawn != null) {
        inlet = drawn;
      } else if (m0 != m1) {
        inlet = m0 ? 0 : 1;
      }
    }
    if (inlet == null) continue;
    if (ret) {
      fixedReturn[id] = inlet;
    } else {
      fixedInlet[id] = inlet;
    }
    if (drawn != null && drawn != inlet) {
      labelOverride[id] = CheckValveAmbiguity.drawnAgainstSupplyLeg;
    } else if (drawn == null) {
      labelOverride[id] = ret
          ? CheckValveAmbiguity.closedReturn
          : CheckValveAmbiguity.supplyLeg;
    }
    if (ret) continue;
    // The leg in flow order: upstream (toward the valve), then downstream.
    final up = sides[inlet], dn = sides[1 - inlet];
    final legEdges = <String>[];
    final legFrom = <String>[];
    for (var i = up.edges.length - 1; i >= 0; i--) {
      legEdges.add(up.edges[i].id);
      legFrom.add(up.nodes[i]);
    }
    for (var i = 0; i < dn.edges.length; i++) {
      legEdges.add(dn.edges[i].id);
      legFrom.add(i == 0 ? id : dn.nodes[i - 1]);
    }
    final key = ([...legEdges]..sort()).join('\u0000');
    final prev = moverLegsByKey[key];
    moverLegsByKey[key] = _MoverLeg(
      [...?prev?.valveIds, id]..sort(),
      prev?.edgeIds ?? legEdges,
      prev?.fromNodeIds ?? legFrom,
    );
  }
  // Round 27 r8 (scenario (a) of the balance-against-pump envelope) — a
  // valved mover leg the sizer CLOSES: every valve on it a fixed return in
  // the pump's direction (the r4 closed-return treatment), the leg off the
  // open mover legs.
  for (final key in [...moverLegsByKey.keys]) {
    if (!closedMoverLegs.contains(key)) continue;
    for (final v in moverLegsByKey[key]!.valveIds) {
      final inlet = fixedInlet.remove(v);
      if (inlet != null) fixedReturn[v] = inlet;
    }
    moverLegsByKey.remove(key);
  }
  final moverLegs = moverLegsByKey.values.toList()
    ..sort((a, b) => a.valveIds.first.compareTo(b.valveIds.first));

  // ── Round 27 r8 — VALVELESS MOVER LEGS ARE CLASSIFIER INPUTS ──
  // A pump / booster set / supply fan drawn COHERENTLY (one pipe in, one
  // out; several movers on one chain all agreeing) on a degree-2 chain with
  // NO check valve, on a cycle: a leg with a direction. (An incoherently
  // drawn valveless mover carries no readable direction and is left as a
  // plain pipe.) It orients its root chain (precedence 3: drawn toward the
  // root => a RETURN chain, away => a discharge chain), and the sizer keeps
  // it in the pump's direction / sizes it on the balance-against-pump
  // envelope like a valved mover leg.
  bool connectedAvoiding(String a, String b, Set<String> blocked) {
    final seen = <String>{a};
    final stack = [a];
    while (stack.isNotEmpty) {
      final n = stack.removeLast();
      if (n == b) return true;
      for (final e in adj[n] ?? const <NetEdge>[]) {
        final m = other(e, n);
        if (blocked.contains(m) || !seen.add(m)) continue;
        stack.add(m);
      }
    }
    return false;
  }

  final valvelessByKey = <String, _MoverLeg>{};
  if (isMover != null) {
    for (final p in [...adj.keys]..sort()) {
      if (p == root || !isMover(p) || adj[p]!.length != 2) continue;
      final es = adj[p]!;
      final s0 = walk(p, es[0]), s1 = walk(p, es[1]);
      // The chain end0 .. p .. end1 in drawing order.
      final ns = <String>[...s0.nodes.reversed, p, ...s1.nodes];
      final eds = <NetEdge>[...s0.edges.reversed, ...s1.edges];
      final interior = ns.sublist(1, ns.length - 1);
      if (interior.any(isCheckValve)) continue; // a valved leg (above)
      final end0 = ns.first, end1 = ns.last;
      if (end0 == end1 || interior.toSet().length != interior.length) {
        continue; // a chain closing on itself: no leg ends
      }
      if (!connectedAvoiding(end0, end1, interior.toSet())) continue;
      int? dir; // +1: end0 -> end1, -1: end1 -> end0
      var coherent = true;
      for (var i = 1; i < ns.length - 1; i++) {
        final n = ns[i];
        if (!isMover(n)) continue;
        final ea = eds[i - 1], eb = eds[i];
        final d = (ea.toId == n && eb.fromId == n)
            ? 1
            : (ea.fromId == n && eb.toId == n)
                ? -1
                : 0;
        if (d == 0 || (dir != null && dir != d)) {
          coherent = false;
          break;
        }
        dir = d;
      }
      if (!coherent || dir == null) continue;
      final legEdges = <String>[];
      final legFrom = <String>[];
      if (dir == 1) {
        for (var i = 0; i < eds.length; i++) {
          legEdges.add(eds[i].id);
          legFrom.add(ns[i]);
        }
      } else {
        for (var i = eds.length - 1; i >= 0; i--) {
          legEdges.add(eds[i].id);
          legFrom.add(ns[i + 1]);
        }
      }
      final leg = _MoverLeg(
          const [],
          legEdges,
          legFrom,
          [
            for (final n in interior)
              if (isMover(n)) n,
          ]..sort());
      valvelessByKey.putIfAbsent(leg.key, () => leg);
    }
  }
  if (cycleValves.isEmpty && valvelessByKey.isEmpty) return none;
  // Where a valveless leg's flow ARRIVES (the end its pump points at).
  String legDestination(_MoverLeg l) {
    final last =
        adj[l.fromNodeIds.last]!.firstWhere((e) => e.id == l.edgeIds.last);
    return other(last, l.fromNodeIds.last);
  }

  // Round 28 (residuals-3) — a pump-free, valveless ROOT chain whose far
  // junction is reached from every other side ONLY through coherent
  // valveless movers pointing INTO it (per-riser circulators R -> Pr -> RJ,
  // then a plain RJ -> K -> H back to the heater) is a RETURN chain too: no
  // water can leave the heater that way without running backwards through a
  // circulator. It is never a candidate discharge, so an ambiguous heater
  // discharge valve beside it is the lone discharge (a feed) instead of a
  // closed return that fed the whole building backwards up the returns.
  final valvelessLegByEdge = <String, _MoverLeg>{
    for (final l in valvelessByKey.values)
      for (final id in l.edgeIds) id: l,
  };
  final returnFedChainKeys = <String>{};
  final returnFedPumps = <String>{};
  for (final e in adj[root] ?? const <NetEdge>[]) {
    final ch = walk(root, e);
    final end = ch.nodes.last;
    if (end == root) continue;
    final interior = ch.nodes.sublist(0, ch.nodes.length - 1);
    if (interior.any((n) => isCheckValve(n) || (isMover?.call(n) ?? false))) {
      continue;
    }
    final last = ch.edges.last;
    final others = [
      for (final x in adj[end] ?? const <NetEdge>[])
        if (x.id != last.id) x,
    ];
    if (others.isEmpty) continue;
    final feeders = <_MoverLeg>{};
    var allMovers = true;
    for (final x in others) {
      final l = valvelessLegByEdge[x.id];
      if (l == null || legDestination(l) != end) {
        allMovers = false;
        break;
      }
      feeders.add(l);
    }
    if (!allMovers) continue;
    returnFedChainKeys.add(([for (final x in ch.edges) x.id]..sort()).join('\u0000'));
    for (final l in feeders) {
      returnFedPumps.addAll(l.pumpIds);
    }
  }

  // Pumps of valveless root chains drawn TOWARD the root: recirculation
  // returns (never a path a second feed can be judged against).
  final valvelessReturnPumps = <String>{
    for (final l in valvelessByKey.values)
      if (legDestination(l) == root) ...l.pumpIds,
    ...returnFedPumps,
  };
  // Scenario (a) — a valveless leg the sizer CLOSES: a pseudo return valve
  // at its first pump (the pump's two pipes, in its drawn direction), so the
  // r4 closed-return treatment (zero draw-off, the return walk from both
  // sides, the zero pockets) applies to it unchanged.
  final pseudoReturns = <_Cv>[];
  final closedValvelessKeys = <String>{};
  for (final l in valvelessByKey.values.toList()
    ..sort((a, b) => a.pumpIds.first.compareTo(b.pumpIds.first))) {
    if (!closedMoverLegs.contains(l.key)) continue;
    closedValvelessKeys.add(l.key);
    final p = l.pumpIds.first;
    final i = l.fromNodeIds.indexOf(p) - 1;
    final inE = adj[p]!.firstWhere((e) => e.id == l.edgeIds[i]);
    final outE = adj[p]!.firstWhere((e) => e.id == l.edgeIds[i + 1]);
    pseudoReturns.add((
      id: p,
      inE: inE,
      outE: outE,
      upNode: l.fromNodeIds[i],
      downNode: other(outE, p),
    ));
  }

  // Round 28 (residuals-2) — a hot-water RECIRCULATION RETURN drawn without
  // its check valve: when a root chain carries a coherent mover pointing
  // AWAY from the root (the circulator / pump set on the heater discharge),
  // every other valve-free, mover-free root chain is a plausible return.
  // Hardy–Cross on the plain ring fed draw-off from the heater up that
  // return, against the circulation the pump sets, and sized the supply
  // main on a share of the peak (curve(8) = 0.400 L/s at DN15 = 2.26 m/s).
  // Such chains are reported ([returnChainKeysOut]) for the sizer's
  // scenario (a): closed with a pseudo return valve at their root end (the
  // r4 closed-return treatment), enveloped with the open reading.
  final closedChainKeys = <String>{};
  if (returnChainEnvelope) {
    final discharges = <String>{
      for (final l in [...moverLegs, ...valvelessByKey.values])
        if (l.fromNodeIds.isNotEmpty && l.fromNodeIds.first == root)
          l.edgeIds.first,
    };
    if (discharges.isNotEmpty) {
      for (final e in adj[root] ?? const <NetEdge>[]) {
        if (discharges.contains(e.id)) continue;
        final ch = walk(root, e);
        if (ch.nodes.last == root || ch.edges.length < 2) continue;
        final interior = ch.nodes.sublist(0, ch.nodes.length - 1);
        if (interior.any((n) =>
            isCheckValve(n) ||
            (isMover?.call(n) ?? false) ||
            (isDemand?.call(n) ?? false))) {
          continue;
        }
        final key = ([for (final x in ch.edges) x.id]..sort()).join('\u0000');
        if (returnFedChainKeys.contains(key)) continue;
        returnChainKeysOut?.add(key);
        if (!closedMoverLegs.contains(key)) continue;
        closedChainKeys.add(key);
        final n1 = ch.nodes[0];
        pseudoReturns.add((
          id: n1,
          inE: ch.edges[1],
          outE: ch.edges[0],
          upNode: ch.nodes[1],
          downNode: root,
        ));
      }
    }
  }
  final pseudoIds = {for (final c in pseudoReturns) c.id};
  final openMoverLegs = <_MoverLeg>[
    ...moverLegs,
    for (final l
        in valvelessByKey.values.toList()
          ..sort((a, b) => a.pumpIds.first.compareTo(b.pumpIds.first)))
      if (!closedValvelessKeys.contains(l.key)) l,
  ];
  final closingLegs = closedMoverLegs.isNotEmpty;

  // Round 28 (residuals-1) — a VALVELESS PARALLEL SET: two or more open,
  // coherently drawn valveless mover legs between the SAME two leg ends in
  // the SAME direction (a duty/standby pump set drawn without its check
  // valves, GT -> P1 -> HDR and GT -> P2 -> HDR) is the Round-13 parallel
  // discharge set — exactly as with the valves drawn: the tree runs through
  // the first leg (by pump id), every other leg's pump pipes are deferred
  // and its whole leg mirrors the duty leg's flow (a standby pump is a
  // full-duty machine). Hardy–Cross used to split the set 50/50, halving
  // each pump's duty and sizing both legs on half the flow (DN15 at
  // 0.6278 L/s = 3.55 m/s). Discharge sets only (a set drawn toward the
  // root is a recirculation return, sized by the return rules).
  final valvelessStandby = <_StandbyLeg>[];
  final valvelessStandbyDeferred = <String>{};
  {
    (String, String) pumpPipes(_MoverLeg l) {
      final p = l.pumpIds.first;
      final i = l.fromNodeIds.indexOf(p);
      return (l.edgeIds[i - 1], l.edgeIds[i]);
    }

    final sets = <String, List<_MoverLeg>>{};
    for (final l in valvelessByKey.values) {
      if (closedValvelessKeys.contains(l.key)) continue;
      final dest = legDestination(l);
      if (dest == root) continue;
      (sets['${l.fromNodeIds.first}\u0000$dest'] ??= []).add(l);
    }
    for (final key in [...sets.keys]..sort()) {
      final group = sets[key]!
        ..sort((a, b) => a.pumpIds.first.compareTo(b.pumpIds.first));
      if (group.length < 2) continue;
      final (dIn, dOut) = pumpPipes(group.first);
      for (final l in group.skip(1)) {
        final (sIn, sOut) = pumpPipes(l);
        valvelessStandbyDeferred
          ..add(sIn)
          ..add(sOut);
        valvelessStandby
            .add(_StandbyLeg(l.edgeIds, l.fromNodeIds, [dIn, dOut]));
      }
    }
  }

  // Rule 3(1) — an ambiguous valve in a PARALLEL set onto one header: its
  // two leg ends (through bare degree-2 nodes and inline pumps) are exactly
  // those of another cycle valve (a duty/standby pair, a pump + bypass
  // pair). Structural — never a distance. The set's direction comes from a
  // DRAWN partner, else from its mover leg (r7 precedence 2), else from the
  // only leg end the root reaches with every cycle valve cut; undecided =>
  // not a standby set.
  final parallelInlet = <String, int>{};
  for (final id in ambiguous) {
    final es = adj[id]!;
    final x0 = legEnd(id, es[0]), x1 = legEnd(id, es[1]);
    if (x0 == x1) continue;
    final partners = <String>[];
    for (final w in cycleValves) {
      if (w == id) continue;
      final ws = adj[w]!;
      final y0 = legEnd(w, ws[0]), y1 = legEnd(w, ws[1]);
      if ((y0 == x0 && y1 == x1) || (y0 == x1 && y1 == x0)) partners.add(w);
    }
    if (partners.isEmpty) continue;
    int? inlet;
    var contradictory = false;
    for (final w in partners) {
      final wi = drawnInlet[w];
      if (wi == null) continue;
      final cand = legEnd(w, adj[w]![wi]) == x0 ? 0 : 1;
      if (inlet != null && inlet != cand) contradictory = true;
      inlet = cand;
    }
    if (contradictory) continue;
    inlet ??= fixedInlet[id];
    if (inlet == null) {
      final r0 = dist.containsKey(x0), r1 = dist.containsKey(x1);
      if (r0 != r1) inlet = r0 ? 0 : 1;
    }
    if (inlet != null) parallelInlet[id] = inlet;
  }

  // (3) ROOT chains: structural cues only. A chain whose valves were fixed
  // as mover feeds is a discharge; a mover return or a drawn valve pointing
  // TOWARD the root makes it a return chain (its ambiguous valves follow the
  // r5 rule); a drawn valve pointing AWAY from the root makes it a
  // discharge (its ambiguous valves are feeds away from the root). Every
  // other chain carrying an ambiguous valve is UNDECIDED.
  final undecided = <Map<String, int>>[]; // valve id -> its root-side edge
  var candidates = 0; // non-return root chains
  // Non-return chains whose discharge reading rests ONLY on a drawn valve
  // pointing away from the root (no mover): exactly what a recirculation
  // return drawn BACKWARDS looks like (the r3 feeds-ring case), so beside an
  // undecided chain it does not settle which chain is the discharge.
  var drawnOnly = 0;
  for (final e in adj[root] ?? const <NetEdge>[]) {
    final ch = walk(root, e);
    if (ch.nodes.last == root) continue; // a junction-free ring
    final valves = <String, int>{
      for (var i = 0; i < ch.nodes.length - 1; i++)
        if (cycleValves.contains(ch.nodes[i]))
          ch.nodes[i]: sideToward(ch.nodes[i], i == 0 ? root : ch.nodes[i - 1]),
    };
    if (valves.keys.any(fixedReturn.containsKey)) continue;
    if (valves.isEmpty) {
      final chainKey =
          ([for (final x in ch.edges) x.id]..sort()).join('\u0000');
      // Round 28 — fed only through circulators, or a recirculation return
      // closed for scenario (a): a return chain.
      if (returnFedChainKeys.contains(chainKey) ||
          closedChainKeys.contains(chainKey)) {
        continue;
      }
    }
    if (valves.isEmpty) {
      // r8 — a valveless chain carrying a coherent mover: drawn toward the
      // root it is a RETURN chain (never a candidate discharge), as is a
      // closed one; drawn away, a mover discharge.
      final vl = valvelessByKey[
          ([for (final x in ch.edges) x.id]..sort()).join('\u0000')];
      if (vl != null &&
          (closedValvelessKeys.contains(vl.key) ||
              legDestination(vl) == root)) {
        continue;
      }
    }
    var toward = false, away = false, mover = false;
    for (final MapEntry(key: v, value: rs) in valves.entries) {
      if (fixedInlet.containsKey(v)) {
        away = true;
        mover = true;
        continue;
      }
      final d = drawnInlet[v];
      if (d == null) continue;
      if (d == rs) {
        away = true;
      } else {
        toward = true;
      }
    }
    if (toward) continue;
    candidates++;
    if (away && !mover) drawnOnly++;
    final amb = <String, int>{
      for (final MapEntry(key: v, value: rs) in valves.entries)
        if (!drawnInlet.containsKey(v) &&
            !fixedInlet.containsKey(v) &&
            !parallelInlet.containsKey(v))
          v: rs,
    };
    if (amb.isEmpty) continue;
    if (away) {
      for (final MapEntry(key: v, value: rs) in amb.entries) {
        fixedInlet[v] = rs;
        labelOverride[v] = CheckValveAmbiguity.supplyLeg;
      }
    } else {
      undecided.add(amb);
    }
  }
  // (4) The ENVELOPE — when two or more root chains are plausible
  // discharges and at least one of them is undecided (several undecided
  // chains, or an undecided chain beside a drawn-valve-only discharge):
  // each undecided chain in turn the discharge (its valves feeds away from
  // the root), every other undecided root valve a closed return (oriented
  // toward the root — a cosmetic, drawing-free orientation); plus, beside a
  // drawn-valve-only discharge, every undecided valve closed. A single
  // non-return chain is THE discharge (structural: the only way out). An
  // undecided chain beside only valveless / mover chains keeps the r5 rule
  // (a closed return unless that starves a draw-off point). More than four
  // scenarios => the r5 rule.
  final scenarios = <({Map<String, int> feeds, Map<String, int> closed})>[];
  if (undecided.length == 1 && candidates == 1) {
    for (final MapEntry(key: v, value: rs) in undecided.single.entries) {
      fixedInlet[v] = rs;
      labelOverride[v] = CheckValveAmbiguity.supplyLeg;
    }
  } else if (undecided.isNotEmpty && undecided.length + drawnOnly >= 2) {
    for (var u = 0; u < undecided.length; u++) {
      scenarios.add((
        feeds: undecided[u],
        closed: {
          for (var w = 0; w < undecided.length; w++)
            if (w != u)
              for (final MapEntry(key: v, value: rs) in undecided[w].entries)
                v: 1 - rs,
        },
      ));
    }
    if (drawnOnly > 0) {
      scenarios.add((
        feeds: const <String, int>{},
        closed: {
          for (final m in undecided)
            for (final MapEntry(key: v, value: rs) in m.entries) v: 1 - rs,
        },
      ));
    }
    if (scenarios.length > 4) scenarios.clear();
  }
  final envelopeValves = <String>{
    if (scenarios.isNotEmpty)
      for (final m in undecided) ...m.keys,
  };

  // Rule 3(2) — an ambiguous valve read as a CLOSED RETURN is oriented with
  // its farther side (only itself removed) as the inlet; this orientation is
  // cosmetic (it carries no flow, and the return walk starts from both
  // sides), so a tie falls back to hops, then node ids.
  _Cv closedReturn(String id) {
    final es = adj[id]!;
    final a = other(es[0], id), b = other(es[1], id);
    final d = distWithout({id});
    final da = d[a], db = d[b];
    if (da != null && db != null && (da - db).abs() > 1e-9) {
      return oriented(id, da > db ? 0 : 1);
    }
    final h = hopsFrom(root, blocked: {id});
    final ha = h[a], hb = h[b];
    if (ha != null && hb != null && ha != hb) {
      return oriented(id, ha > hb ? 0 : 1);
    }
    return oriented(id, a.compareTo(b) > 0 ? 0 : 1);
  }

  // The plan for one choice of the ambiguous valves treated as standby-set
  // members ([parallelAmb]) under one envelope scenario ([sFeeds] /
  // [sClosed]: undecided root valves read as feeds / closed returns, each
  // with its inlet); also returns the valves that actually formed a
  // Round-13 parallel set. Null when the scenario's closures cut a draw-off
  // point off the source (the scenario is skipped).
  (_CheckValvePlan?, Set<String>) build(Set<String> parallelAmb,
      [Map<String, int> sFeeds = const {},
      Map<String, int> sClosed = const {}]) {
    Map<String, CheckValveAmbiguity> labels({
      Set<String> closed = const {},
      Set<String> standby = const {},
    }) =>
        {
          for (final id in ambiguous)
            id: standby.contains(id)
                ? CheckValveAmbiguity.standbySet
                : envelopeValves.contains(id)
                    ? CheckValveAmbiguity.envelope
                    : closed.contains(id)
                        ? CheckValveAmbiguity.closedReturn
                        : labelOverride[id] ??
                            (sFeeds.containsKey(id)
                                ? CheckValveAmbiguity.supplyLeg
                                : CheckValveAmbiguity.plainPipe),
          for (final MapEntry(key: id, value: l) in labelOverride.entries)
            if (l == CheckValveAmbiguity.drawnAgainstSupplyLeg) id: l,
        };
    final undecidable = _CheckValvePlan(<String>{}, <_StandbyLeg>[], const {},
        const [], const {}, const [], labels(), openMoverLegs);

    final cvs = <_Cv>[
      for (final id in cycleValves)
        if (parallelAmb.contains(id))
          oriented(id, parallelInlet[id]!)
        else if (fixedInlet[id] != null)
          // r7 — a mover-leg / root-cue feed: its fixed orientation.
          oriented(id, fixedInlet[id]!)
        else if (fixedReturn[id] != null)
          // r7 — a coherent circulator drawn toward the root: a return.
          oriented(id, fixedReturn[id]!)
        else if (sFeeds[id] != null)
          oriented(id, sFeeds[id]!)
        else if (sClosed.containsKey(id))
          oriented(id, sClosed[id]!)
        else if (drawnInlet[id] != null)
          oriented(id, drawnInlet[id]!),
    ];
    // Rule 2 on the drawn valves (a standby-set member and a fixed / scenario
    // feed are discharges, never returns; a fixed return always a return).
    bool fixedFeed(String id) =>
        parallelAmb.contains(id) ||
        fixedInlet.containsKey(id) ||
        sFeeds.containsKey(id);
    bool fixedRet(String id) =>
        fixedReturn.containsKey(id) || sClosed.containsKey(id);
    Set<String> rule2() => {
          for (final c in cvs)
            if (fixedRet(c.id) || (!fixedFeed(c.id) && isReturnValve(c))) c.id,
          ...pseudoIds,
        };
    // r8 — scenario (a): closing the leg(s) the balance ran against must
    // leave every draw-off point fed, else the scenario is skipped.
    if (closingLegs &&
        disconnectsDemand(
            {...fixedReturn.keys, ...sClosed.keys, ...pseudoIds})) {
      return (null, parallelAmb);
    }
    var returnIds = rule2();

    // A set of DRAWN returns that cuts a draw-off point off the source is
    // self-contradictory: re-read with every cycle valve cut.
    if (disconnectsDemand(returnIds)) {
      if (sClosed.isNotEmpty &&
          disconnectsDemand({...fixedReturn.keys, ...sClosed.keys})) {
        return (null, parallelAmb);
      }
      for (var i = 0; i < cvs.length; i++) {
        final c = cvs[i];
        if (!returnIds.contains(c.id) || fixedRet(c.id)) continue;
        final inlet = topologicalInlet(c.id);
        if (inlet == null) continue;
        cvs[i] = oriented(c.id, inlet);
      }
      returnIds = rule2();
      if (disconnectsDemand(returnIds)) {
        if (sClosed.isNotEmpty) return (null, parallelAmb);
        return (undecidable, parallelAmb);
      }
    }

    // Rule 3(2)/(3) — every other ambiguous valve is a CLOSED RETURN unless
    // closing it (with the drawn returns) cuts a draw-off point off the
    // source; then it is a plain PIPE. When the closed returns cut one off
    // only TOGETHER (a dual-feed ring entered through two ambiguous valves),
    // the valves whose reopening alone restores every draw-off point are all
    // reopened as pipes — symmetric, never by id order.
    var closed = <String>{
      for (final id in ambiguous)
        if (!fixedFeed(id) &&
            !fixedRet(id) &&
            !disconnectsDemand({...returnIds, id}))
          id,
    };
    while (closed.isNotEmpty && disconnectsDemand({...returnIds, ...closed})) {
      final reopen = {
        for (final v in closed)
          if (!disconnectsDemand({...returnIds, ...closed}..remove(v))) v,
      };
      closed = reopen.isEmpty ? <String>{} : closed.difference(reopen);
    }
    for (final id in closed) {
      cvs.add(closedReturn(id));
    }
    cvs.sort((x, y) => x.id.compareTo(y.id));
    returnIds = {...returnIds, ...closed};
    // An ambiguous scenario-closed return is walked from both its sides too
    // (its orientation is cosmetic).
    closed = {...closed, ...sClosed.keys, ...pseudoIds};

    final rets = [
      for (final c in cvs)
        if (returnIds.contains(c.id)) c,
      ...pseudoReturns,
    ];
    final feeds = [
      for (final c in cvs)
        if (!returnIds.contains(c.id)) c,
    ];
    // A feed valve passes water only its permitted way: [e] may be traversed
    // FROM [from] (the supply-path walks below honour it).
    final feedInE = {for (final c in feeds) c.inE.id: c.upNode};
    final feedOutE = {for (final c in feeds) c.outE.id: c.id};
    bool passable(NetEdge e, String from) =>
        (feedInE[e.id] ?? from) == from && (feedOutE[e.id] ?? from) == from;

    // The RETURN plan over [rets] with hop distance [d] from the root and the
    // valve edges [cutE] cut (see the call site).
    _CheckValvePlan returnPlan(
        Map<String, int> d, Set<String> cutE, List<_Cv> rets) {
      // Round 26 (hot-water-2-common-return-cv-hardy-cross) — N riser
      // returns joined on a common header, then ONE check valve back to the
      // heater: cutting the valve alone leaves the supply-riser /
      // return-riser ring intact, and Hardy–Cross used to push draw-off up
      // the returns, through the valve against its direction (supply main
      // ~40 % under-sized). The RETURN side is grown from each valve's
      // upstream node over edges on NO shortest root -> demand path (hop
      // distance with the valves cut) through draw-off-free, off-supply
      // nodes: a return pipe never lies on the way to a draw-off. Those edges
      // are deferred with the valves, so the returns size as zero-draw-off
      // branches — but only when what remains (the supply) is acyclic; a
      // genuine ring with draw-off on both legs keeps the Hardy–Cross split.
      final cutEdges = {...cutE};
      final supplyEdges = <String>{};
      if (isDemand != null) {
        final visited = <String>{};
        final stack = [
          for (final n in d.keys)
            if (isDemand(n)) n,
        ];
        while (stack.isNotEmpty) {
          final n = stack.removeLast();
          if (!visited.add(n)) continue;
          final dn = d[n]!;
          for (final e in adj[n] ?? const <NetEdge>[]) {
            if (cutE.contains(e.id)) continue;
            final m = other(e, n);
            if (d[m] != null && d[m]! + bendWeight(e) == dn && passable(e, m)) {
              supplyEdges.add(e.id);
              stack.add(m);
            }
          }
        }
        final candidates = <String>{
          for (final e in componentEdges)
            if (!cutE.contains(e.id) && !supplyEdges.contains(e.id)) e.id,
        };
        // Round 26 r2 — the return side is grown ONLY from each valve's
        // upstream node, through nodes that bear no draw-off and lie on no
        // supply path; it stops (edge included) where it meets the supply. A
        // ring segment BETWEEN two demand-fed ring nodes is off every
        // shortest path too, but it is reached from no such return node, so
        // a stub-fed ring main with a drawn return (valve upstream ON the
        // ring) keeps the Hardy–Cross split.
        final supplyNodes = <String>{
          for (final e in componentEdges)
            if (supplyEdges.contains(e.id)) ...[e.fromId, e.toId],
        };
        //
        // Round 26 r3 — the conservative variant: a return pipe ends where it
        // meets the supply at a BARE node (the riser top beyond the last
        // branch). When the walk lands on a DRAW-OFF node FROM A TEE (a node
        // joining more than the two pipes of a chain) the "return" is a ring
        // segment instead — a return teed from a bare ring tee X (b - X - c
        // with draw-off at b and c, the junction the Run tool's tee-in
        // creates). Such a walk extends nothing and the ring keeps the
        // Hardy–Cross split.
        //
        // Round 27 (residuals-4) — a return CHAIN (the walked node has
        // exactly two pipes: the hotel return riser) that ends on the inline
        // top fixture, or on a bare node beyond it, is a return all the same:
        // it lands on that draw-off point and stops there. r4 rejected it and
        // left the supply-riser / return-riser ring in Hardy–Cross, which
        // pushed draw-off up the returns and sized the far riser bases one DN
        // small.
        //
        // Round 27 r3 — a FEED check valve is a supply device: the walk never
        // enters it, and neither its inlet nor its outlet node is a return
        // node (a ring segment beyond a second feed is fed, not a return; the
        // walk used to grow straight through the feed valve and zero it).
        final feedTouch = <String>{
          for (final c in feeds) ...[c.id, c.upNode, c.downNode],
        };
        bool returnNode(String n) =>
            n != root &&
            !supplyNodes.contains(n) &&
            !isDemand(n) &&
            !feedTouch.contains(n);
        final returnSide = <String>{};
        var meetsDrawOff = false;
        // The supply's shortest-path DAG (parent -> downstream child).
        final children = <String, List<String>>{};
        for (final e in componentEdges) {
          if (!supplyEdges.contains(e.id)) continue;
          final da = d[e.fromId], db = d[e.toId];
          if (da == null || db == null) continue;
          final w = bendWeight(e);
          if (db == da + w) (children[e.fromId] ??= []).add(e.toId);
          if (da == db + w) (children[e.toId] ??= []).add(e.fromId);
        }
        // Round 27 r5 — an AMBIGUOUS closed return has no drawn inlet: the
        // walk starts from BOTH its sides, so its (cosmetic) orientation can
        // never decide the ring-vs-return split. Each start is walked on its
        // own (its own landings), so the outcome never depends on walk order.
        final starts = <String>{
          for (final c in rets) ...[
            if (returnNode(c.upNode)) c.upNode,
            if (closed.contains(c.id) && returnNode(c.downNode)) c.downNode,
          ],
        }.toList()
          ..sort();
        for (final s0 in starts) {
          final seenReturn = <String>{};
          final landings = <String>{};
          final walk = [s0];
          while (walk.isNotEmpty && !meetsDrawOff) {
            final n = walk.removeLast();
            if (!seenReturn.add(n)) continue;
            for (final e in adj[n] ?? const <NetEdge>[]) {
              if (!candidates.contains(e.id)) continue;
              final m = other(e, n);
              if (feeds.any((c) => c.id == m)) continue;
              if (m != root && isDemand(m)) {
                if ((adj[n]?.length ?? 0) != 2) {
                  meetsDrawOff = true;
                  break;
                }
                returnSide.add(e.id); // a return chain landing on the fixture
                landings.add(m);
                continue;
              }
              returnSide.add(e.id);
              if (returnNode(m)) {
                walk.add(m);
              } else if (m != root) {
                landings.add(m);
              }
            }
          }
          if (meetsDrawOff) break;
          // Round 27 r5 — a return closes back from the FAR ends of the
          // supply (riser tops, the top fixture): it never lands on two
          // points of ONE supply path. A walk landing on a node AND on
          // another node downstream of it on the supply (shortest-path DAG)
          // has found a ring segment / bypass beside the supply, not a
          // return — the walk extends nothing (the ring keeps its
          // Hardy–Cross split). Without this, whether such a segment read as
          // a "return" hung on a hop count (one bare bend flipped it).
          for (final l in landings) {
            final below = <String>{};
            final st = [...?children[l]];
            while (st.isNotEmpty) {
              final x = st.removeLast();
              if (!below.add(x)) continue;
              st.addAll(children[x] ?? const <String>[]);
            }
            if (landings.any((o) => o != l && below.contains(o))) {
              meetsDrawOff = true;
              break;
            }
          }
          if (meetsDrawOff) break;
        }
        if (meetsDrawOff) returnSide.clear();
        final remaining = [
          for (final e in componentEdges)
            if (!cutE.contains(e.id) && !returnSide.contains(e.id))
              (e.fromId, e.toId),
        ];
        final keepsLoop = !_isForest([
          for (final e in componentEdges)
            if (!cutE.contains(e.id)) (e.fromId, e.toId),
        ]);
        // Round 27 r3 — and the tree that remains must reach every feed
        // valve from its inlet side (never route draw-off back through one).
        bool feedsForward() {
          final seen = <String>{root};
          final st = [root];
          while (st.isNotEmpty) {
            final n = st.removeLast();
            for (final e in adj[n] ?? const <NetEdge>[]) {
              if (cutE.contains(e.id) || returnSide.contains(e.id)) continue;
              final m = other(e, n);
              if (seen.contains(m)) continue;
              if (!passable(e, n)) return false;
              seen.add(m);
              st.add(m);
            }
          }
          return true;
        }

        if (keepsLoop &&
            returnSide.isNotEmpty &&
            _isForest(remaining) &&
            feedsForward()) {
          cutEdges.addAll(returnSide);
        }
      }
      return _CheckValvePlan(cutEdges, const [], {
        for (final c in rets) ...{c.inE.id: c.upNode, c.outE.id: c.id},
      });
    }

    // Round 13 — a PARALLEL duty/standby set: feed valves entering one
    // unreached region (all cycle valves cut) whose legs merge at the SAME
    // junction, or whose every leg carries a pump / booster set.
    bool isParallelDischarge(_Cv c) =>
        dist[c.upNode] != null && dist[c.downNode] == null;
    final byRegion = <int, List<_Cv>>{};
    for (final c in feeds) {
      if (!isParallelDischarge(c)) continue;
      (byRegion[region[c.downNode]!] ??= []).add(c);
    }
    // Round 27 r6 — and STRUCTURALLY: feed valves whose oriented legs run
    // between the SAME two leg ends (the same split and the same header) are
    // one parallel set even when the header is also reached by a valve-free
    // pipe (a plain-pipe recirculation return), which defeats the
    // unreached-region test above.
    final byLegEnds = <String, List<_Cv>>{};
    for (final c in feeds) {
      final x = legEnd(c.id, c.inE), y = legEnd(c.id, c.outE);
      if (x == y) continue;
      (byLegEnds['$x\u0000$y'] ??= []).add(c);
    }
    final structural = <List<_Cv>>[
      for (final group in byLegEnds.values)
        if (group.length >= 2) group,
    ];
    final inStructural = {
      for (final g in structural)
        for (final c in g) c.id,
    };
    final parallelGroups = <List<_Cv>>[
      for (final g in structural) g..sort((x, y) => x.id.compareTo(y.id)),
      for (final group in byRegion.values)
        if (group.every((c) => !inStructural.contains(c.id)) &&
            group.length >= 2 &&
            ({for (final c in group) legEnd(c.id, c.outE)}.length == 1 ||
                group.every(legHasMover)))
          group..sort((x, y) => x.id.compareTo(y.id)),
    ]..sort((x, y) => x.first.id.compareTo(y.first.id));
    final inParallel = {
      for (final g in parallelGroups)
        for (final c in g) c.id,
    };

    // Duty/standby: the tree runs through the FIRST valve's leg of each set;
    // every other valve's edges are deferred and its whole leg (the chain of
    // degree-2 nodes through it, up to the split / merge junction or the
    // root) mirrors the duty valve's flow.
    final standbyDeferred = <String>{...valvelessStandbyDeferred};
    final legs = <_StandbyLeg>[...valvelessStandby];
    for (final group in parallelGroups) {
      final duty = group.first;
      for (final c in group.skip(1)) {
        standbyDeferred
          ..add(c.inE.id)
          ..add(c.outE.id);
        final seen = <String>{c.id};
        // Walk upstream from the valve (against the flow): (edge, upstream
        // node).
        final up = <(NetEdge, String)>[];
        var node = c.upNode;
        var edge = c.inE;
        while (true) {
          up.add((edge, node));
          if (node == root || !seen.add(node)) break;
          final es = adj[node]!;
          if (es.length != 2) break;
          final next = es.firstWhere((e) => e.id != edge.id);
          edge = next;
          node = other(next, node);
        }
        // ... and downstream (with the flow).
        final down = <(NetEdge, String)>[];
        var dn = c.id;
        var de = c.outE;
        while (true) {
          down.add((de, dn));
          final far = other(de, dn);
          if (far == root || !seen.add(far)) break;
          final es = adj[far]!;
          if (es.length != 2) break;
          final next = es.firstWhere((e) => e.id != de.id);
          dn = far;
          de = next;
        }
        final ordered = [...up.reversed, ...down];
        legs.add(_StandbyLeg(
          [for (final (e, _) in ordered) e.id],
          [for (final (_, from) in ordered) from],
          [duty.inE.id, duty.outE.id],
        ));
      }
    }

    // Honesty (judge-only) — a DRAWN feed valve whose outlet the source
    // still reaches with it AND every return valve closed: a second feed
    // into a component that already has a feed path, which is exactly what
    // a recirculation return drawn with its arrow backwards looks like.
    // Round 27 r5 — never an ambiguous valve (it has its own advisory), and
    // when several valves qualify the one(s) on the source's OWN supply leg
    // (the shortest root -> draw-off route runs through it: a heater /
    // pump discharge valve) are not named — the backwards return is.
    final feedsRing = <String>{};
    for (final c in feeds) {
      // r6 — nor a mover-leg / root-cue feed: it sits on the source's / a
      // pump's own discharge, never a backwards return.
      // r7 — an envelope scenario's feed valve competes for "the source's
      // own supply leg" (so the heater's real discharge is never named
      // beside it) but, being ambiguous, is never named itself.
      if (inParallel.contains(c.id) ||
          !(drawnInlet.containsKey(c.id) || sFeeds.containsKey(c.id)) ||
          fixedInlet.containsKey(c.id)) {
        continue;
      }
      // r8 — a valveless circulator drawn toward the root is a return
      // chain: never the path a second feed is judged against.
      final d = distWithout({c.id, ...returnIds, ...valvelessReturnPumps});
      if (d.containsKey(c.downNode)) feedsRing.add(c.id);
    }
    // (Judge-only, so it may read hop counts: a return riser's bare nodes
    // count here, which is what tells the heater's discharge from a
    // backwards return beside it.)
    if (feedsRing.length >= 2 && isDemand != null) {
      final d0 =
          hopsFrom(root, blocked: {...returnIds, ...valvelessReturnPumps});
      final score = <String, double>{};
      for (final c in feeds) {
        if (!feedsRing.contains(c.id)) continue;
        final dv = d0[c.id];
        if (dv == null) continue;
        final dd = hopsFrom(c.downNode,
            blocked: {c.id, ...returnIds, ...valvelessReturnPumps});
        int? near;
        for (final MapEntry(key: x, value: v) in dd.entries) {
          if (x == root || !isDemand(x)) continue;
          if (near == null || v < near) near = v;
        }
        if (near == null) continue;
        score[c.id] = (dv + 1 + near).toDouble();
      }
      if (score.length == feedsRing.length) {
        final best = score.values.reduce(math.min);
        final onSupply = {
          for (final MapEntry(key: id, value: v) in score.entries)
            if (v <= best + 1e-9) id,
        };
        if (onSupply.length < feedsRing.length) {
          feedsRing.removeAll(onSupply);
        }
      }
    }
    feedsRing.removeAll(sFeeds.keys);

    var deferred = <String>{...standbyDeferred};
    var returnFlowFrom = const <String, String>{};
    if (rets.isNotEmpty) {
      final cut1 = <String>{
        for (final c in rets) ...[c.inE.id, c.outE.id],
      };
      // Distance with the returns cut and every feed valve one-way, in the
      // BEND-FREE metric ([bendWeight]; Round 27 r5): a bare bend inserted
      // anywhere never changes which pipes lie on a shortest supply path.
      // (Round 28 — a (distance, id) priority queue: the same settle order
      // as the old full-map scan, without its O(V^2).)
      final dist1 = <String, int>{root: 0};
      final done1 = <String>{};
      final queue1 = SplayTreeSet<(int, String)>((x, y) {
        final c = x.$1.compareTo(y.$1);
        return c != 0 ? c : x.$2.compareTo(y.$2);
      })
        ..add((0, root));
      while (queue1.isNotEmpty) {
        final top = queue1.first;
        queue1.remove(top);
        final best = top.$2;
        if (!done1.add(best)) continue;
        for (final e in adj[best] ?? const <NetEdge>[]) {
          if (cut1.contains(e.id) || !passable(e, best)) continue;
          final m = other(e, best);
          if (done1.contains(m)) continue;
          final nd = dist1[best]! + bendWeight(e);
          final old = dist1[m];
          if (old == null || nd < old) {
            if (old != null) queue1.remove((old, m));
            dist1[m] = nd;
            queue1.add((nd, m));
          }
        }
      }
      final rp = returnPlan(dist1, cut1, rets);
      deferred = {...deferred, ...rp.deferredEdgeIds};
      returnFlowFrom = rp.returnValveFlowFrom;
    }
    return (
      _CheckValvePlan(deferred, legs, returnFlowFrom, feeds, feedsRing, rets,
          labels(closed: closed, standby: inParallel), openMoverLegs),
      inParallel,
    );
  }

  // An ambiguous valve is a standby-set member only if it actually forms a
  // Round-13 parallel set; otherwise it is re-read under rule 3(2)/(3).
  _CheckValvePlan? solve(
      [Map<String, int> sFeeds = const {},
      Map<String, int> sClosed = const {}]) {
    var parallelAmb = {...parallelInlet.keys};
    while (true) {
      final (plan, grouped) = build(parallelAmb, sFeeds, sClosed);
      if (plan == null) return null;
      final ungrouped = parallelAmb.difference(grouped);
      if (ungrouped.isEmpty) return plan;
      parallelAmb = parallelAmb.difference(ungrouped);
    }
  }

  if (scenarios.isEmpty) {
    final p = solve();
    return p == null ? const [] : [p];
  }
  final surviving = <(_CheckValvePlan, Map<String, int>)>[];
  for (final sc in scenarios) {
    final plan = solve(sc.feeds, sc.closed);
    if (plan != null) surviving.add((plan, sc.feeds));
  }
  if (surviving.length >= 2) return [for (final (p, _) in surviving) p];
  // One plausible reading (or none): no envelope — the surviving scenario as
  // read, else the r5 rule.
  envelopeValves.clear();
  if (surviving.isEmpty) {
    final p = solve();
    return p == null ? const [] : [p];
  }
  final (_, feeds) = surviving.single;
  final plan = surviving.single.$1;
  return [
    plan.withLabels({
      for (final MapEntry(key: id, value: l) in plan.ambiguousValves.entries)
        id: l != CheckValveAmbiguity.envelope
            ? l
            : feeds.containsKey(id)
                ? CheckValveAmbiguity.supplyLeg
                : CheckValveAmbiguity.closedReturn,
    }),
  ];
}

bool _isForest(List<(String, String)> edges) {
  final parent = <String, String>{};
  String find(String x) {
    var r = x;
    while (parent[r] != null && parent[r] != r) {
      r = parent[r]!;
    }
    parent[x] = r;
    return r;
  }

  for (final (a, b) in edges) {
    parent.putIfAbsent(a, () => a);
    parent.putIfAbsent(b, () => b);
    final ra = find(a), rb = find(b);
    if (ra == rb) return false;
    parent[ra] = rb;
  }
  return true;
}

/// Round 12 (mech-props-2 vent-stack-reverse-taper) — every VENT riser edge
/// in [units] raised to the largest load of the connected vertical stack it
/// belongs to (riser edges sharing an endpoint, transitively). A vent stack
/// is sized over its whole developed length on the total DFU of the soil
/// stack it serves (IPC 916.1 / UPC 703.2, `// VERIFY` notAnSniClause) — a
/// uniform size, never reverse-tapered. Run (branch-vent) edges unchanged.
Map<String, double> _uniformVentStacks(
  Network net,
  Map<String, double> units, {
  Map<String, String>? edgeParent,
}) {
  final risers = [
    for (final id in units.keys)
      if (net.edgeById(id) case final e?
          when e.kind == EdgeKind.riser && e.service == ServiceType.vent)
        e,
  ];
  if (risers.isEmpty) return units;
  // Round 25 (drainage-4-2 / -4-3) — a vent RUN is part of the stack when it
  // joins two vent-STACK riser groups (a horizontal OFFSET: riser, run,
  // riser) or a vent-stack riser end to a drainage-STACK node (the base
  // connection to the soil-stack foot). Either way it is the stack's developed
  // length and carries the stack size (IPC 916.1 / UPC 703.2 uniform,
  // `// VERIFY` notAnSniClause). A fixture's INDIVIDUAL vent riser (its group
  // touches a drainage node off the soil stack — the fixture trap) is a
  // branch vent: it never joins a stack, and keeps its own load.
  final parent = <String, String>{};
  String find(String x) {
    var r = x;
    while (parent[r] != null && parent[r] != r) {
      r = parent[r]!;
    }
    parent[x] = r;
    return r;
  }

  void union(NetEdge e) {
    parent.putIfAbsent(e.fromId, () => e.fromId);
    parent.putIfAbsent(e.toId, () => e.toId);
    final ra = find(e.fromId), rb = find(e.toId);
    if (ra != rb) parent[ra] = rb;
  }

  for (final e in risers) {
    union(e);
  }
  final drainNodes = <String>{};
  final drainStackNodes = <String>{};
  for (final e in net.edges) {
    if (e.service != ServiceType.drainage) continue;
    drainNodes.addAll([e.fromId, e.toId]);
    if (e.kind == EdgeKind.riser) drainStackNodes.addAll([e.fromId, e.toId]);
  }
  // Riser groups touching a drainage node OFF the soil stack = fixture vents.
  final branchGroups = <String>{
    for (final n in parent.keys)
      if (drainNodes.contains(n) && !drainStackNodes.contains(n)) find(n),
  };
  bool stackEnd(String n) =>
      parent.containsKey(n) && !branchGroups.contains(find(n));
  // The lowest storey of each vent-stack riser group: only its BASE joins the
  // soil-stack foot (a floor tie / relief vent higher up keeps its own load).
  final groupBottom = <String, int>{};
  final groupTop = <String, int>{};
  for (final n in parent.keys) {
    final f = net.nodeById(n)?.floorIndex;
    if (f == null) continue;
    final g = find(n);
    if (f < (groupBottom[g] ?? f + 1)) groupBottom[g] = f;
    if (f > (groupTop[g] ?? f - 1)) groupTop[g] = f;
  }
  // Round 26 (regression-vent-header-unions-separate-stacks) — a run between
  // two riser groups is a stack OFFSET only when it joins one group's TOP to
  // a DIFFERENT group's BOTTOM on the same storey (riser, run, riser). A roof
  // vent HEADER tying the tops of two independent stacks into one VTR (both
  // ends at their group's top) is NOT an offset: each stack keeps its own
  // load and the header its own accumulated load (UPC 703.2 / IPC 916 size a
  // vent stack on its own drain DFU and only the header on the combined
  // load). Group membership is fixed here, before any run is unioned.
  final riserGroupOf = <String, String>{
    for (final n in parent.keys) n: find(n),
  };
  // Vent-graph degree and run count per node.
  final ventDegree = <String, int>{};
  final ventRunCount = <String, int>{};
  final ventAdj = <String, List<NetEdge>>{};
  for (final e in net.edges) {
    if (e.service != ServiceType.vent) continue;
    for (final n in [e.fromId, e.toId]) {
      ventDegree[n] = (ventDegree[n] ?? 0) + 1;
      (ventAdj[n] ??= []).add(e);
      if (e.kind != EdgeKind.riser) {
        ventRunCount[n] = (ventRunCount[n] ?? 0) + 1;
      }
    }
  }
  // Round 27 (residuals-2) — a riser group that is TIED to no drainage node
  // is a bare VTR STUB (a riser from a header junction up to the roof). Its
  // bottom node joined by TWO or more runs is a HEADER junction, not the foot
  // of an offset stack: both header halves used to pass as stack offsets and
  // merge the two stacks (and the stub) into one uniform stack. A group is
  // TIED when one of its nodes is a drainage node OR a vent run (chain,
  // through bare bends) joins one of its nodes to a drainage node — an
  // ordinary upper vent stack whose ties run to the soil stack is a stack,
  // never a stub (r2: a floor tie drawn from the offset's upper foot W2 left
  // the lower stack reverse-tapered). Tie chains are added below, once the
  // chains are built (before any [offsetLink] call).
  final groupTouchesDrain = <String>{
    for (final n in parent.keys)
      if (drainNodes.contains(n)) riserGroupOf[n]!,
  };
  bool offsetLink(String lower, String upper) {
    if (!stackEnd(lower) || !stackEnd(upper)) return false;
    final gl = riserGroupOf[lower]!, gu = riserGroupOf[upper]!;
    if (gl == gu) return false;
    final fl = net.nodeById(lower)?.floorIndex;
    final fu = net.nodeById(upper)?.floorIndex;
    if (fl == null || fu == null || fl != fu) return false;
    if (!groupTouchesDrain.contains(gu) && (ventRunCount[upper] ?? 0) >= 2) {
      return false;
    }
    return fl == groupTop[gl] && fu == groupBottom[gu];
  }

  // Round 27 (residuals-3) — a run drawn through BARE bend nodes (degree 2,
  // two runs, no riser / tie / drainage / fitting / load) is ONE logical run:
  // a stack offset drawn V2 -> K -> W2 used to join no two riser groups and
  // leave the lower stack reverse-tapered. Each chain is classified on its
  // two END nodes; every chain edge takes the classification.
  bool bareBend(String n) {
    if (parent.containsKey(n) || drainNodes.contains(n)) return false;
    if (ventDegree[n] != 2 || ventRunCount[n] != 2) return false;
    final node = net.nodeById(n);
    return node != null && node.component == null && node.role == NodeRole.main;
  }

  final chains = <({
    String u,
    String v,
    NetEdge eu,
    NetEdge ev,
    List<NetEdge> edges,
  })>[];
  {
    final seenRun = <String>{};
    final runIds = [
      for (final id in units.keys)
        if (net.edgeById(id) case final e?
            when e.kind != EdgeKind.riser && e.service == ServiceType.vent)
          id,
    ]..sort();
    for (final id in runIds) {
      if (seenRun.contains(id)) continue;
      final e0 = net.edgeById(id)!;
      // Extend from each end through bare bends.
      (String, NetEdge, List<NetEdge>) extend(String from, NetEdge via) {
        var node = via.fromId == from ? via.toId : via.fromId;
        var edge = via;
        final path = <NetEdge>[];
        final seen = <String>{from};
        while (bareBend(node) && seen.add(node)) {
          final next = ventAdj[node]!.firstWhere((x) => x.id != edge.id);
          if (!units.containsKey(next.id)) break;
          path.add(next);
          edge = next;
          node = next.fromId == node ? next.toId : next.fromId;
        }
        return (node, edge, path);
      }

      final (v, ev, pv) = extend(e0.fromId, e0);
      final (u, eu, pu) = extend(e0.toId, e0);
      final edges = [...pu.reversed, e0, ...pv];
      for (final x in edges) {
        seenRun.add(x.id);
      }
      chains.add((u: u, v: v, eu: eu, ev: ev, edges: edges));
    }
  }
  for (final c in chains) {
    for (final (a, b) in [(c.u, c.v), (c.v, c.u)]) {
      if (riserGroupOf[a] case final g? when drainNodes.contains(b)) {
        groupTouchesDrain.add(g);
      }
    }
  }

  bool baseEnd(String n) =>
      stackEnd(n) && net.nodeById(n)?.floorIndex == groupBottom[find(n)];
  bool baseLink(String ventEnd, String other) =>
      baseEnd(ventEnd) &&
      !parent.containsKey(other) &&
      drainStackNodes.contains(other);
  final stackRuns = [
    for (final c in chains)
      if (offsetLink(c.u, c.v) ||
          offsetLink(c.v, c.u) ||
          baseLink(c.u, c.v) ||
          baseLink(c.v, c.u))
        ...c.edges,
  ];
  // Any other vent run joining two DIFFERENT stack groups is a HEADER (e.g.
  // one stack's top tied into another stack below a shared VTR). Round 26 r2
  // — a header keeps its own accumulated load and never lifts the stack that
  // RECEIVES it; so does every riser of that stack ABOVE the header's
  // junction (the shared stub up to the VTR carries both stacks). Those
  // risers are split out of
  // the uniform group, so the stack below the junction keeps the size of its
  // OWN soil stack whichever way the header is drawn (UPC 703.2 / IPC 916
  // size a vent stack on its own drain DFU, only the shared section on the
  // combined load). A junction at a group's BOTTOM storey splits nothing.
  final headers = [
    for (final c in chains)
      if (stackEnd(c.u) &&
          stackEnd(c.v) &&
          riserGroupOf[c.u] != riserGroupOf[c.v] &&
          !offsetLink(c.u, c.v) &&
          !offsetLink(c.v, c.u))
        c,
  ];
  // A header endpoint RECEIVES the header when the vent air enters its stack
  // there (see [receives] below — the solved tree, r3); otherwise the header
  // DRAINS that stack and carries that stack's whole vent load,
  // the figure its own VTR would carry, so it bounds that stack's uniform
  // size. Per receiving group: the lowest junction storey above its bottom,
  // and the header load entering there.
  int? floorOf(String n) => net.nodeById(n)?.floorIndex;
  bool continuesAbove(String g, int f) => risers.any((r) {
        if (riserGroupOf[r.fromId] != g) return false;
        final fa = floorOf(r.fromId), fb = floorOf(r.toId);
        return fa != null && fb != null && math.min(fa, fb) >= f;
      });
  // Round 26 r3 — a riser continuing above the junction is not enough: a
  // stack RECEIVES the header only when the vent air actually enters it
  // there, i.e. the junction is the ROOT-SIDE end of the header in the solved
  // vent tree ([edgeParent] — rooted at the highest vent node, the VTR the
  // air leaves by). When the header is rooted at its OTHER end the stack's
  // air leaves through the header: it is DRAINED, whatever is drawn above
  // the junction — a dead STUB above a mid-storey header (tied off at the top
  // floor, no VTR) vents nothing, and with VTRs on both stacks the one the
  // tree does not root at is drained just the same. A drained stack is
  // bounded by the header load (its whole vent load); the receiving one
  // keeps its own load below the junction. A loop-CLOSING header (no tree
  // parent) keeps the riser-only rule.
  bool receives(NetEdge header, String j) {
    final p = edgeParent?[header.id];
    if (p != null) return p == j;
    final f = floorOf(j);
    return f != null && continuesAbove(riserGroupOf[j]!, f);
  }

  final junctionFloor = <String, int>{};
  final headerLoadAt = <String, double>{};
  final drainedBound = <String, double>{}; // riser group -> header load
  for (final c in headers) {
    // Round 26 r4 — a loop-CLOSING header (left out of the solved tree: two
    // headers between the same two stacks, a relief / yoke header below a
    // roof header) carries only the conservative 'larger adjacent load' the
    // closing rule hands it — no vent air is ACCOUNTED through it. Adding
    // that to [headerLoadAt] subtracted the larger stack's own load from
    // its shared risers (a 40-DFU stack sized DN50 on 20 DFU instead of
    // DN65); bounding a stack by it would oversize the small one. It is
    // neither a receiving nor a draining header.
    if (edgeParent != null &&
        c.edges.any((x) => !edgeParent.containsKey(x.id))) {
      continue;
    }
    for (final (j, ej) in [(c.u, c.eu), (c.v, c.ev)]) {
      final g = riserGroupOf[j]!;
      final f = floorOf(j);
      if (f == null) continue;
      if (!receives(ej, j)) {
        drainedBound[g] = math.max(drainedBound[g] ?? 0, units[ej.id]!);
        continue;
      }
      if (f <= (groupBottom[g] ?? f)) continue;
      if (f < (junctionFloor[g] ?? f + 1)) junctionFloor[g] = f;
      headerLoadAt[g] = (headerLoadAt[g] ?? 0) + units[ej.id]!;
    }
  }
  // Round 27 (residuals-1) — a vent run (chain) leaving a stack's TOP to a
  // BARE node outside every riser group (a mid-header junction off which the
  // VTR rises or runs) through which the stack's air LEAVES in the solved
  // tree drains that stack exactly like a header: it carries the stack's
  // whole vent load (less any header entering at that top) and bounds the
  // stack's uniform size. The stack used to keep its below-tie partial load
  // (a 32-DFU stack sized DN50 on 22 DFU).
  bool vtrLeaf(String n) {
    final node = net.nodeById(n);
    return ventDegree[n] == 1 &&
        !drainNodes.contains(n) &&
        node != null &&
        node.component == null &&
        node.role == NodeRole.main;
  }

  if (edgeParent != null) {
    for (final c in chains) {
      for (final (j, ej, o) in [(c.u, c.eu, c.v), (c.v, c.ev, c.u)]) {
        if (!stackEnd(j) || parent.containsKey(o) || drainNodes.contains(o)) {
          continue;
        }
        if (vtrLeaf(o)) continue; // a run VTR: see [vtrRunLink] below
        final g = riserGroupOf[j]!;
        if (floorOf(j) != groupTop[g]) continue;
        final p = edgeParent[ej.id];
        if (p == null || p == j) continue; // the air does not leave here
        final load = units[ej.id]! -
            (junctionFloor[g] == floorOf(j) ? (headerLoadAt[g] ?? 0) : 0.0);
        drainedBound[g] = math.max(drainedBound[g] ?? 0, load);
      }
    }
  }
  bool aboveJunction(NetEdge e) {
    final g = riserGroupOf[e.fromId];
    final jf = g == null ? null : junctionFloor[g];
    if (jf == null) return false;
    final fa = floorOf(e.fromId), fb = floorOf(e.toId);
    if (fa == null || fb == null) return false;
    return math.min(fa, fb) >= jf;
  }

  final shared = [
    for (final e in risers)
      if (aboveJunction(e)) e,
  ];
  for (final e in stackRuns) {
    union(e);
  }
  final members = [
    for (final e in risers)
      if (!aboveJunction(e)) e,
    ...stackRuns,
  ];
  if (members.length + shared.length < 2) return units;
  final stackMax = <String, double>{};
  for (final e in members) {
    final k = find(e.fromId);
    final v = units[e.id]!;
    if (v > (stackMax[k] ?? 0)) stackMax[k] = v;
  }
  for (final MapEntry(key: g, value: v) in drainedBound.entries) {
    final k = find(g);
    if (stackMax.containsKey(k) && v > stackMax[k]!) stackMax[k] = v;
  }
  // The stack's own total still governs below the junction: a shared riser's
  // load less the header load entering at the junction (never below zero).
  for (final e in shared) {
    final k = find(e.fromId);
    final own = math.max(
        0.0, units[e.id]! - (headerLoadAt[riserGroupOf[e.fromId]] ?? 0));
    if (own > (stackMax[k] ?? 0)) stackMax[k] = own;
  }
  // Round 26 r4 — a VTR drawn as a short RUN on the top storey (stack top ->
  // a bare vent leaf on the same storey, joined by nothing else) is the
  // stack's roof termination, part of its developed length exactly like a
  // VTR riser. The top floor's tie enters ABOVE the last riser, so only
  // this run carried the stack's whole load: the risers sized one DN small
  // (24 vs 32 DFU, DN50 vs DN65) and an un-rooted second VTR printed DN32
  // over a DN40 stack. It counts like a shared riser — its own load less the
  // header load entering the stack — and is never below the stack it ends.
  bool vtrRunLink(String top, String leaf) {
    if (!stackEnd(top) || parent.containsKey(leaf)) return false;
    if (ventDegree[leaf] != 1 || drainNodes.contains(leaf)) return false;
    final ft = floorOf(top), fl = floorOf(leaf);
    if (ft == null || ft != fl || ft != groupTop[riserGroupOf[top]]) {
      return false;
    }
    final node = net.nodeById(leaf);
    return node != null && node.component == null && node.role == NodeRole.main;
  }

  final vtrRuns = <(NetEdge, String)>[
    for (final id in units.keys)
      if (net.edgeById(id) case final e?
          when e.kind != EdgeKind.riser && e.service == ServiceType.vent)
        if (vtrRunLink(e.fromId, e.toId))
          (e, e.fromId)
        else if (vtrRunLink(e.toId, e.fromId))
          (e, e.toId),
  ];
  // Round 30 (mech-sim-4-vent-stack-without-vtr-stub-undersized) — a stack
  // whose TOP node is the vent tree's ROOT (no VTR stub drawn: the bare
  // top-storey junction is the roof penetration) carries, through its
  // zero-length virtual VTR, every load ENTERING that node — the top riser
  // plus the top floor's tie — less a header received there. Without it the
  // stack sized on the floors below the top tie only (72 vs 90 DFU).
  if (edgeParent != null) {
    for (final t in riserGroupOf.keys) {
      if (!stackEnd(t)) continue;
      final g = riserGroupOf[t]!;
      if (floorOf(t) != groupTop[g]) continue;
      final incident = ventAdj[t] ?? const <NetEdge>[];
      // Only a tie / branch junction at the top (a run enters there): a bare
      // VTR stub top's single riser is already the stack's own member.
      if (!incident.any((e) => e.kind != EdgeKind.riser)) continue;
      // The tree root: every incident tree edge hangs FROM it.
      var isRoot = true;
      var sum = 0.0;
      for (final e in incident) {
        final p = edgeParent[e.id];
        final u = units[e.id];
        if (p == null || u == null) continue;
        if (p != t) {
          isRoot = false;
          break;
        }
        sum += u;
      }
      if (!isRoot) continue;
      final k = find(t);
      if (!stackMax.containsKey(k)) continue;
      final jf = junctionFloor[g];
      final ft = floorOf(t);
      final own = math.max(
          0.0,
          sum -
              (jf != null && ft != null && jf <= ft
                  ? (headerLoadAt[g] ?? 0)
                  : 0.0));
      if (own > stackMax[k]!) stackMax[k] = own;
    }
  }
  for (final (e, top) in vtrRuns) {
    final k = find(top);
    if (!stackMax.containsKey(k)) continue;
    final own =
        math.max(0.0, units[e.id]! - (headerLoadAt[riserGroupOf[top]] ?? 0));
    if (own > stackMax[k]!) stackMax[k] = own;
  }
  return {
    ...units,
    for (final e in members) e.id: stackMax[find(e.fromId)]!,
    for (final (e, top) in vtrRuns)
      if (stackMax[find(top)] case final m?) e.id: math.max(units[e.id]!, m),
    // A shared riser above a header junction keeps its own (combined) load,
    // never less than the stack it sits on.
    for (final e in shared)
      e.id: math.max(units[e.id]!, stackMax[find(e.fromId)] ?? 0),
  };
}

/// For every BRIDGE of a connected edge list (an edge whose removal splits the
/// graph — a tree edge hanging off or into a ring), the summed [weight] of the
/// nodes on its FAR side from [root]. Ring (2-edge-connected) edges are absent.
///
/// Tarjan's bridge test on a DFS from [root] (parallel edges are told apart by
/// id, so a doubled pipe is correctly NOT a bridge): a tree edge parent→child
/// is a bridge iff low[child] > tin[parent], and its far side is then exactly
/// the DFS subtree of the child. Iterative, so a long run cannot overflow the
/// stack. Pure.
Map<String, double> _bridgeFarSideSums({
  required List<({String id, String from, String to})> edges,
  required String root,
  required Map<String, double> weight,
}) {
  final adjacency = <String, List<({String edgeId, String other})>>{};
  for (final e in edges) {
    (adjacency[e.from] ??= []).add((edgeId: e.id, other: e.to));
    (adjacency[e.to] ??= []).add((edgeId: e.id, other: e.from));
  }
  final tin = <String, int>{};
  final low = <String, int>{};
  final sub = <String, double>{};
  final out = <String, double>{};
  var timer = 0;
  // Frame: node, the edge id it was entered by, next adjacency index.
  final stack = <({String node, String? viaEdge, int next})>[];
  final parentOf = <String, String>{};
  tin[root] = low[root] = timer++;
  sub[root] = weight[root] ?? 0.0;
  stack.add((node: root, viaEdge: null, next: 0));
  while (stack.isNotEmpty) {
    final top = stack.removeLast();
    final links = adjacency[top.node] ?? const [];
    if (top.next < links.length) {
      stack.add((node: top.node, viaEdge: top.viaEdge, next: top.next + 1));
      final link = links[top.next];
      if (link.edgeId == top.viaEdge) continue;
      final seen = tin[link.other];
      if (seen != null) {
        low[top.node] = math.min(low[top.node]!, seen);
      } else {
        tin[link.other] = low[link.other] = timer++;
        sub[link.other] = weight[link.other] ?? 0.0;
        parentOf[link.other] = top.node;
        stack.add((node: link.other, viaEdge: link.edgeId, next: 0));
      }
      continue;
    }
    // Finished top.node: fold into its parent.
    final p = parentOf[top.node];
    if (p == null) continue;
    low[p] = math.min(low[p]!, low[top.node]!);
    sub[p] = sub[p]! + sub[top.node]!;
    if (low[top.node]! > tin[p]!) out[top.viaEdge!] = sub[top.node]!;
  }
  return out;
}

final _airOpenBoundaryCache = Expando<
    (List<NetNode>, List<NetEdge>, int, int, Set<String>)>(
  'airOpenBoundaryLeaves',
);

/// Round 32 (regression-air-open-boundary-exempts-undrawn-terminal-off-non-
/// root-fcu) — the bare air leaves the SIZER treats as an air unit's open
/// boundary (its outdoor-air INTAKE, or an extract unit's DISCHARGE): the
/// load-free intake leaves of every air component, exactly as
/// [autoSizeNetwork] decides them (only off the component's ROOT unit — a
/// terminal FCU never roots while a source exists, Round 15, so a bare leaf
/// off a non-root FCU is a default terminal, not an intake). The connectivity
/// judge consults THIS set, so the loose-end check and the sizer can never
/// disagree. Pure.
///
/// Memoised per [Network], re-keyed (like `Network.nodeById`'s index) on the
/// node / edge LIST instances and their lengths: the lists are plain mutable
/// `List`s, so a network whose lists were swapped or grown after the first
/// call recomputes instead of serving a stale intake set.
Set<String> airOpenBoundaryLeaves(Network net) {
  final cached = _airOpenBoundaryCache[net];
  if (cached != null &&
      identical(cached.$1, net.nodes) &&
      identical(cached.$2, net.edges) &&
      cached.$3 == net.nodes.length &&
      cached.$4 == net.edges.length) {
    return cached.$5;
  }
  final airEdges = [
    for (final e in net.edges)
      if (e.service.regime == FlowRegime.air) e,
  ];
  final out = <String>{};
  if (airEdges.isNotEmpty) {
    autoSizeNetwork(
      Network(nodes: net.nodes, edges: airEdges),
      const SizingContext(),
      // The intake decision depends on the topology + explicit loads only;
      // a nominal per-terminal default keeps the solve non-degenerate.
      leafDemand: const {
        ServiceType.duct: FlowRate(0.05),
        ServiceType.returnAir: FlowRate(0.05),
        ServiceType.exhaust: FlowRate(0.05),
      },
      nodeFlowDemand: {
        for (final n in net.nodes)
          if (n.airflow != null) n.id: n.airflow!,
      },
      airIntakeLeavesOut: out,
    );
  }
  final frozen = Set<String>.unmodifiable(out);
  _airOpenBoundaryCache[net] =
      (net.nodes, net.edges, net.nodes.length, net.edges.length, frozen);
  return frozen;
}
