import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/storm_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

import 'app_state.dart';
import 'network_store.dart';

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
  const profile = SniProfile();

  // Real per-fixture UBAP where the user has assigned a fixture type; nodes
  // without a type fall back to the flat default in autoSizeNetwork.
  final nodeFixtureUnits = <String, double>{
    for (final n in net.nodes)
      if (n.fixture != null)
        n.id: profile.fixtureUnitLoad(n.fixture!, occupancy: occupancy),
  };
  // Per-diffuser airflow where assigned (drives the duct air path).
  final nodeFlowDemand = <String, FlowRate>{
    for (final n in net.nodes)
      if (n.airflow != null) n.id: n.airflow!,
  };
  // Per-fixture drainage units (drives sanitary drainage/vent sizing).
  final nodeDrainageUnits = <String, double>{
    for (final n in net.nodes)
      if (n.fixture != null) n.id: drainageFixtureUnit(n.fixture!),
  };
  // If any assigned WC uses a flush valve, size the supply on the valve curve.
  final anyFlushValve = net.nodes.any(
      (n) => n.fixture == PlumbingFixture.waterClosetFlushValve);

  // Rainwater leaves drain a default roof area at the design storm intensity.
  final leafDemand = <ServiceType, FlowRate>{
    ...kDefaultLeafDemand,
    ServiceType.rainwater: rainwaterDesignFlow(
      intensityMmPerHr: ref.watch(rainfallIntensityProvider),
      roofAreaM2: kDefaultRoofAreaPerOutlet,
    ),
  };

  return autoSizeNetwork(
    net,
    SizingContext(ductShape: ducts.shape, ductMethod: ducts.method),
    leafDemand: leafDemand,
    leafFixtureUnits: kDefaultLeafFixtureUnits,
    nodeFixtureUnits: nodeFixtureUnits,
    nodeDrainageUnits: nodeDrainageUnits,
    nodeFlowDemand: nodeFlowDemand,
    flushSystem:
        anyFlushValve ? FlushSystem.flushValve : FlushSystem.flushTank,
  );
});

/// Whether to overlay the computed sizes on the canvas.
final showSizingProvider =
    NotifierProvider<ShowSizingController, bool>(ShowSizingController.new);

class ShowSizingController extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
}
