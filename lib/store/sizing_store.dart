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
  ServiceType.fireSprinkler: FlowRate(0.0005),
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
final sizingProvider = Provider<Map<String, EdgeSizing>>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  if (net.edges.isEmpty) return const {};
  final occupancy = ref.watch(occupancyProvider);
  final ducts = ref.watch(ductSettingsProvider);
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
  // If any assigned WC uses a flush valve (built-in OR a custom flush-valve
  // fixture), size the supply on the valve curve.
  final anyFlushValve = net.nodes.any((n) =>
      n.fixture == PlumbingFixture.waterClosetFlushValve ||
      (customFor(n)?.isFlushValve ?? false));

  // Rainwater leaves drain a default roof area at the design storm intensity
  // (per-outlet roof areas, when set, override this via nodeFlowDemand above).
  final leafDemand = <ServiceType, FlowRate>{
    ...kDefaultLeafDemand,
    ServiceType.rainwater: rainwaterDesignFlow(
      intensityMmPerHr: intensity,
      roofAreaM2: kDefaultRoofAreaPerOutlet,
      runoffCoefficient: runoffC,
    ),
  };

  // Manual per-segment nominal-size overrides (right-click "Set size"): the
  // edge keeps its accumulated flow but is sized to the chosen diameter.
  final sizeOverrides = <String, Diameter>{
    for (final e in net.edges)
      if (e.sizeOverride != null) e.id: e.sizeOverride!,
  };

  return autoSizeNetwork(
    net,
    SizingContext(ductShape: ducts.shape, ductMethod: ducts.method),
    leafDemand: leafDemand,
    leafFixtureUnits: kDefaultLeafFixtureUnits,
    nodeFixtureUnits: nodeFixtureUnits,
    nodeDrainageUnits: nodeDrainageUnits,
    nodeFlowDemand: nodeFlowDemand,
    sizeOverrides: sizeOverrides,
    flushSystem:
        anyFlushValve ? FlushSystem.flushValve : FlushSystem.flushTank,
    // Geometry lets looped (ring) mains balance their flow split against REAL
    // edge lengths — runs via calibration, risers via the §10 elevation delta.
    building: project.building,
    calibrationBySheet: project.calibrations,
  );
});

/// Advisory checks over the drawn DRAINAGE branches — a read-only judge layer
/// (`drainage_advisory.dart`) that NEVER resizes. For each horizontal drainage
/// run it flags a too-flat laid SLOPE (below the self-cleansing minimum) and an
/// over-long developed length (trap-arm / self-siphonage risk), using the §10
/// geometry length. Risers (vertical stacks) and vents are skipped — the slope
/// rule is a horizontal-branch concern. All thresholds are `// VERIFY`.
///
/// Empty when there's no drainage network, so a project without drainage is
/// byte-identical (no issues surfaced).
final drainageAdvisoryProvider = Provider<List<DrainageAdvisory>>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final project = ref.watch(projectControllerProvider);
  // The laid design slope is the same default the sizer uses (SizingContext).
  final slope = const SizingContext().drainageSlope; // m/m // VERIFY
  final out = <DrainageAdvisory>[];
  for (final e in net.edges) {
    if (e.service != ServiceType.drainage) continue;
    if (e.kind == EdgeKind.riser) continue; // slope is a horizontal-branch rule
    final lenM = edgeLength(
      e,
      net,
      calibrationBySheet: project.calibrations,
      building: project.building,
    ).meters;
    out.addAll(drainageAdvisories(
      edgeId: e.id,
      slope: slope,
      developedLengthM: lenM > 0 ? lenM : null,
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
}
