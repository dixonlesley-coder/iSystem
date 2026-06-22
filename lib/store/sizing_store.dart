import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';

import 'network_store.dart';

/// Default per-terminal demand by service, used to auto-size the drawn network
/// until per-fixture loads are assigned. (Pragmatic placeholders.)
const Map<ServiceType, FlowRate> kDefaultLeafDemand = {
  ServiceType.duct: FlowRate(0.05), // 50 L/s per diffuser
  ServiceType.coldWater: FlowRate(0.0002), // 0.2 L/s per fixture
  ServiceType.hotWater: FlowRate(0.0002),
  ServiceType.drainage: FlowRate(0.0008), // 0.8 L/s per fixture
  ServiceType.vent: FlowRate(0.0004),
  ServiceType.rainwater: FlowRate(0.001),
  ServiceType.fireSprinkler: FlowRate(0.0005),
  ServiceType.fireHydrant: FlowRate(0.005),
};

/// Live sizing of the drawn network — recomputed whenever the network changes.
/// Each edge is routed to the correct §7 path and sized for its accumulated
/// (per-branch) flow.
final sizingProvider = Provider<Map<String, EdgeSizing>>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  if (net.edges.isEmpty) return const {};
  return autoSizeNetwork(
    net,
    const SizingContext(),
    leafDemand: kDefaultLeafDemand,
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
