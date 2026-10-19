import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/drainage_advisory.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/storm_sizing.dart';
import 'package:mechx_engine/standards/custom_fixture.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

import 'app_state.dart';
import 'fire_store.dart';
import 'fixture_library_store.dart';
import 'network_store.dart';
import 'project_store.dart';

/// Roof catchment assumed per rainwater outlet until a per-outlet area is
/// assigned. // VERIFY — refine with a real roof plan.
const double kDefaultRoofAreaPerOutlet = 100.0;

/// Default per-terminal demand by service, used to auto-size the drawn network
/// until per-fixture loads are assigned. (Pragmatic placeholders.)
///
/// Water-supply services are sized from accumulated fixture UNITS through the
/// SNI Hunter curve instead (see [kDefaultLeafFixtureUnits]); the flow figures
/// here only apply to the non-water services.
const Map<ServiceType, FlowRate> kDefaultLeafDemand = {
  ServiceType.duct: FlowRate(0.05), // 50 L/s per supply diffuser
  ServiceType.returnAir: FlowRate(0.05), // per return grille
  ServiceType.exhaust: FlowRate(0.03), // per exhaust grille
  ServiceType.coldWater: FlowRate(0.0002), // fallback only (UBAP path used)
  ServiceType.hotWater: FlowRate(0.0002),
  ServiceType.drainage: FlowRate(0.0008), // 0.8 L/s per fixture
  ServiceType.vent: FlowRate(0.0004),
  ServiceType.rainwater: FlowRate(0.001),
  // (No fireSprinkler entry: sizingProvider always supplies the hazard's own
  // remote-head flow from sprinklerRemoteAreaProvider instead.)
  ServiceType.fireHydrant: FlowRate(0.005),
};

/// Default fixture-unit (UBAP) load per water-supply terminal. Each drawn
/// terminal is treated as a representative fixture (~2 UBAP, between a lavatory
/// and a flush-tank WC) until per-fixture types are assigned. Accumulated down
/// the tree and converted via the Hunter curve, this yields a DIVERSIFIED design
/// flow rather than a sum of peak fixture flows.
const Map<ServiceType, double> kDefaultLeafFixtureUnits = {
  ServiceType.coldWater: 2.0,
  ServiceType.hotWater: 2.0,
};

/// Live sizing of the drawn network — recomputed whenever the network changes.
/// Each edge is routed to the correct §7 path and sized for its accumulated
/// (per-branch) demand: water supply via accumulated fixture units → Hunter
/// curve; other services via accumulated flows.
/// The ONE [SizingContext] the network sizer runs with (Round 21 follow-up):
/// every judge that re-checks a sized edge (e.g. the fire velocity cap in
/// `waterVelocityChecksProvider`) reads its limits from HERE, so a judge can
/// never apply a different cap than the sizer used.
final sizingContextProvider = Provider<SizingContext>((ref) {
  final ducts = ref.watch(ductSettingsProvider);
  return SizingContext(
    ductShape: ducts.shape,
    ductMethod: ducts.method,
    // M13 — the laid drainage slope is a real design input
    // (drainageSlopeProvider): it sets the Manning full-bore velocity behind
    // every gravity size AND the self-cleansing verdict. Default 0.01 ⇒
    // byte-identical.
    drainageSlope: ref.watch(drainageSlopeProvider),
  );
});

final sizingProvider = Provider<Map<String, EdgeSizing>>(
    (ref) => ref.watch(sizingDetailProvider).sizing);

/// Round 9 (report-parity-run-schedule-fu-blank) — the accumulated fixture
/// units (UBAP for water supply, DFU for drainage/vent) per TREE edge, recorded
/// by the SAME [autoSizeNetwork] call that sized it (`fixtureUnitsOut`), so the
/// calc report's run schedule prints the basis that drove each size.
final edgeFixtureUnitsProvider = Provider<Map<String, double>>(
    (ref) => ref.watch(sizingDetailProvider).fixtureUnits);

/// Round 14 (regression-dutystandby-tank-root-doubles-pump-duty) — the edges
/// the sizer gave a MIRRORED set flow (duty/standby standby legs, parallel
/// peer-source bridges; `autoSizeNetwork(parallelLegEdgeIdsOut:)`). They carry
/// the full set flow so each machine can run alone, but are not extra delivery:
/// [sourceDeliveredFlow] skips them so a duty/standby set drawn straight from
/// its ground tank is never sized on curve(2 × UBAP).
final parallelLegEdgeIdsProvider = Provider<Set<String>>(
    (ref) => ref.watch(sizingDetailProvider).parallelLegs);

/// Round 27 r3 — hot-water cycle check valves the sizer read as a FEED (the
/// drawn arrow does not point toward the heater) into a component the heater
/// already feeds another way: the drawing a recirculation return with its
/// arrow drawn backwards produces (`autoSizeNetwork(checkValveFeedsRingOut:)`).
/// Judge-only — the valve is sized as drawn; Review names it.
final checkValveFeedsRingProvider = Provider<Set<String>>(
    (ref) => ref.watch(sizingDetailProvider).checkValveFeedsRing);

/// The one live sizing solve + its fixture-unit record (see [sizingProvider]).
final sizingDetailProvider = Provider<
    ({
      Map<String, EdgeSizing> sizing,
      Map<String, double> fixtureUnits,
      FlushSystem flushSystem,
      Set<String> flushValveNodeIds,
      Set<String> parallelLegs,
      Set<String> checkValveFeedsRing,
    })>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  if (net.edges.isEmpty) {
    return (
      sizing: const {},
      fixtureUnits: const {},
      flushSystem: FlushSystem.flushTank,
      flushValveNodeIds: const <String>{},
      parallelLegs: const <String>{},
      checkValveFeedsRing: const <String>{},
    );
  }
  final occupancy = ref.watch(occupancyProvider);
  final project = ref.watch(projectControllerProvider);
  const profile = SniProfile();

  // User-defined custom fixtures, keyed by id. A node's `customFixtureId` (when
  // present and FOUND here) resolves to its UBAP/DFU loads directly, overriding
  // the built-in `fixture`. An unknown id falls back to the no-fixture default.
  final library = ref.watch(fixtureLibraryProvider);
  final libraryById = <String, CustomFixture>{
    for (final f in library) f.id: f,
  };
  CustomFixture? customFor(NetNode n) {
    final id = n.customFixtureId;
    return id == null ? null : libraryById[id];
  }

  // Real per-fixture UBAP where the user has assigned a fixture type; nodes
  // without a type fall back to the flat default in autoSizeNetwork. A resolved
  // custom fixture's supplyUnits wins over the built-in table.
  final nodeFixtureUnits = <String, double>{
    for (final n in net.nodes)
      if (customFor(n) != null)
        n.id: customFor(n)!.supplyUnits
      else if (n.fixture != null)
        n.id: profile.fixtureUnitLoad(n.fixture!, occupancy: occupancy),
  };
  final intensity = ref.watch(rainfallIntensityProvider);
  final runoffC = ref.watch(runoffCoefficientProvider);
  // Per-diffuser airflow where assigned (drives the duct air path), plus the
  // per-outlet rainwater design flow for any rainwater node carrying a roof-area
  // override (it wins over the flat default leaf demand for that outlet).
  final nodeFlowDemand = <String, FlowRate>{
    for (final n in net.nodes)
      if (n.airflow != null) n.id: n.airflow!,
    // A roof-area outlet (storm) — guarded so a duct diffuser's airflow on the
    // same node id is never silently overwritten (the two are different services
    // and never co-occur in practice, but the map key is the node id).
    for (final n in net.nodes)
      if (n.roofAreaM2 != null && n.airflow == null)
        n.id: rainwaterDesignFlow(
            intensityMmPerHr: intensity,
            roofAreaM2: n.roofAreaM2!,
            runoffCoefficient: runoffC),
  };
  // Per-fixture drainage units (drives sanitary drainage/vent sizing). A
  // resolved custom fixture's drainageUnits wins over the built-in table.
  final nodeDrainageUnits = <String, double>{
    for (final n in net.nodes)
      if (customFor(n) != null)
        n.id: customFor(n)!.drainageUnits
      else if (n.fixture != null)
        n.id: drainageFixtureUnit(n.fixture!),
  };
  // Flush-valve WCs (built-in OR a custom flush-valve fixture). Round 27
  // (residuals-6) — the engine picks the valve curve per cold-water SYSTEM
  // (only a component holding one of these nodes; hot water never), so a
  // valve WC on a public toilet core no longer re-curves the apartments'
  // flush-tank system. [flushSystem] is the whole-project summary only.
  final flushValveNodeIds = <String>{
    for (final n in net.nodes)
      if (n.fixture == PlumbingFixture.waterClosetFlushValve ||
          (customFor(n)?.isFlushValve ?? false))
        n.id,
  };
  final flushSystem = flushValveNodeIds.isNotEmpty
      ? FlushSystem.flushValve
      : FlushSystem.flushTank;

  // Rainwater leaves drain a default roof area at the design storm intensity
  // (per-outlet roof areas, when set, override this via nodeFlowDemand above).
  // Sprinkler heads take the hazard's OWN per-head design flow (the remote
  // head's discharge, K-floor uplifted — `remoteAreaHydraulics`) instead of a
  // flat 0.5 L/s that understated every hazard 1.3-3x, and the accumulated
  // sprinkler flow is capped at the one-design-area demand (only the remote
  // area operates at once — the cross-main is not sized for every drawn head).
  final sprinklerRemote = ref.watch(sprinklerRemoteAreaProvider);
  final leafDemand = <ServiceType, FlowRate>{
    ...kDefaultLeafDemand,
    ServiceType.rainwater: rainwaterDesignFlow(
      intensityMmPerHr: intensity,
      roofAreaM2: kDefaultRoofAreaPerOutlet,
      runoffCoefficient: runoffC,
    ),
    ServiceType.fireSprinkler: sprinklerRemote.remoteHeadFlow,
  };

  // Manual per-segment nominal-size overrides (right-click "Set size"): the
  // edge keeps its accumulated flow but is sized to the chosen diameter.
  final sizeOverrides = <String, Diameter>{
    for (final e in net.edges)
      if (e.sizeOverride != null) e.id: e.sizeOverride!,
  };

  final fixtureUnits = <String, double>{};
  final parallelLegs = <String>{};
  final checkValveFeedsRing = <String>{};
  final sizing = autoSizeNetwork(
    net,
    // The one sizing context (duct settings + the laid drainage slope).
    ref.watch(sizingContextProvider),
    leafDemand: leafDemand,
    leafFixtureUnits: kDefaultLeafFixtureUnits,
    nodeFixtureUnits: nodeFixtureUnits,
    nodeDrainageUnits: nodeDrainageUnits,
    nodeFlowDemand: nodeFlowDemand,
    sizeOverrides: sizeOverrides,
    sprinklerDemandCap: sprinklerRemote.remoteAreaDemand,
    // mech-building-5 — the hydrant riser/trunk carries the standpipe design
    // flow the fire pump is sized on (one system, one flow), not Σ boxes.
    hydrantDesignFlow: ref.watch(standpipeDesignProvider).requiredFlow,
    flushSystem: flushSystem,
    flushValveNodeIds: flushValveNodeIds,
    // Geometry lets looped (ring) mains balance their flow split against REAL
    // edge lengths — runs via calibration, risers via the §10 elevation delta.
    building: project.building,
    calibrationBySheet: project.calibrations,
    // Audit 2026-10 water-drainage-8 — the project's mounting heights (F8)
    // set the riser lengths of the ring-split basis, as on the drawings.
    mounting: project.mounting,
    // Audit water-drainage-7 residual — a custom fixture flagged as a water
    // closet gets the same DN75 drain floor as a built-in WC type.
    waterClosetNodeIds: {
      for (final n in net.nodes)
        if (customFor(n)?.isWaterCloset ?? false) n.id,
    },
    fixtureUnitsOut: fixtureUnits,
    parallelLegEdgeIdsOut: parallelLegs,
    checkValveFeedsRingOut: checkValveFeedsRing,
  );
  return (
    sizing: sizing,
    fixtureUnits: fixtureUnits,
    flushSystem: flushSystem,
    flushValveNodeIds: flushValveNodeIds,
    parallelLegs: parallelLegs,
    checkValveFeedsRing: checkValveFeedsRing,
  );
});

/// Round 11 — the demand-curve branch (flush tank / flush valve) the live
/// water-supply sizing used, so a consumer re-diversifying a summed UBAP load
/// (the pump at a tee'd discharge) reads the SAME curve the sizer did.
final supplyFlushSystemProvider = Provider<FlushSystem>(
    (ref) => ref.watch(sizingDetailProvider).flushSystem);

/// Round 27 (residuals-6) — the flush-valve fixture nodes the sizer chose the
/// demand curve from, per system: pair with `flushSystemForRoot` to read the
/// curve of ONE supply system (the pump duties re-diversify on it).
final supplyFlushValveNodeIdsProvider = Provider<Set<String>>(
    (ref) => ref.watch(sizingDetailProvider).flushValveNodeIds);

/// Advisory checks over the drawn DRAINAGE branches — a read-only judge layer
/// (`drainage_advisory.dart`) that NEVER resizes. For each horizontal drainage
/// run it flags a laid SLOPE below the per-DN self-cleansing minimum (judged
/// against the run's SIZED diameter), and for each fixture it walks the TRAP
/// ARM — summing every drawn segment to the first vented point (vent / stack /
/// root), so a branch split by the auto-elbow / tee-in tools is judged as one
/// developed length — against the per-DN trap-arm limit (Round 9). Risers
/// (vertical stacks) and vents are skipped. All thresholds are `// VERIFY`.
///
/// Empty when there's no drainage network, so a project without drainage is
/// byte-identical (no issues surfaced).
final drainageAdvisoryProvider = Provider<List<DrainageAdvisory>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final project = ref.watch(projectControllerProvider);
  final sizing = ref.watch(sizingProvider);
  // M13 — the laid design slope the SIZER used (drainageSlopeProvider), so the
  // advisory judges the project's real gradient instead of a const that could
  // never trip its own threshold. // VERIFY the min-slope threshold itself.
  final slope = ref.watch(drainageSlopeProvider); // m/m // VERIFY
  double lengthOf(NetEdge e) => edgeLength(
        e,
        net,
        calibrationBySheet: project.calibrations,
        building: project.building,
        mounting: project.mounting,
      ).meters;
  final out = <DrainageAdvisory>[];
  for (final e in net.edges) {
    if (e.service != ServiceType.drainage) continue;
    if (e.kind == EdgeKind.riser) continue; // slope is a horizontal-branch rule
    out.addAll(drainageAdvisories(
      edgeId: e.id,
      slope: slope,
      diameterMm: sizing[e.id]?.diameter.inMillimeters,
    ));
  }
  for (final arm in trapArmRuns(net: net, sizing: sizing, lengthOf: lengthOf)) {
    final d = sizing[arm.firstEdgeId]?.diameter.inMillimeters;
    if (d == null || arm.developedLengthM <= 0) continue;
    out.addAll(drainageAdvisories(
      edgeId: arm.firstEdgeId,
      // Slope already judged per edge above — pass 0 so only the trap arm runs.
      slope: 0,
      developedLengthM: arm.developedLengthM,
      diameterMm: d,
    ));
  }
  return out;
});

/// Whether to overlay the computed sizes on the canvas.
final showSizingProvider =
    NotifierProvider<ShowSizingController, bool>(ShowSizingController.new);

class ShowSizingController extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;

  /// Turn the overlay ON (idempotent). F2 — the first auto-size nudge says
  /// "sizes shown on the plan"; this is what makes that true. Deliberately not
  /// a set(bool): nothing should be able to force the labels OFF behind the
  /// engineer's back, and the inspector toggle still owns the off direction.
  void show() {
    if (!state) state = true;
  }
}
