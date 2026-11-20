// Fix round 6 (C7, 2026-11-20) — on a downfeed building the delivered field
// read the open ground tank and the transfer riser from the ROOF tank's
// gravity walked back down (apartment GT 394 kPa, tower 1139 kPa). An open
// storage tank is atmospheric: GT reads 0 kPa, and the transfer side reads
// the transfer pump's discharge falling with height — from the SAME walk the
// pump head is sized on (`transferPumpHead(fieldOut:)`).
//
// At the pump outlet: (H - hf_suction) x 9.81 kPa, H the sized transfer
// head, hf_suction the Hazen-Williams loss GT -> pump at its sized flow and
// bore (C150); the tank and pump sit on the Lantai 1 slab (0.0 m). E.g. the
// shophouse: H 17.242 m (lift 8.0 + the fill-pipe friction + 5.0 m inlet
// residual, backlog W-3), outlet 168.997 kPa; the apartment H 48.833 m,
// outlet 478.657 kPa; the tower H 128.830 m, outlet 1263.520 kPa. Every
// delivery (fixture) node is byte-identical to the field without the
// transfer side.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/hydraulics.dart' show headLossHazenWilliams;
import 'package:mechx_engine/network/network.dart';

import 'reference_drawing_loader.dart';

void main() {
  for (final (key, gt, tp, outletKpa) in [
    ('shophouse', 'GT_A', 'TP_A', 168.997),
    ('apartment', 'GT', 'TP', 478.657),
    ('tower', 'GT', 'TP', 1263.520),
  ]) {
    testWidgets('$key: GT 0 kPa, the transfer riser on the pump', (t) async {
      final spec = kRefDrawingSpecs.firstWhere((s) => s.key == key);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await t.runAsync(() => loadRefDrawingSpec(c, spec));
      await t.pump();
      final d = c.read(downfeedDeliveredProvider)!;
      expect(d.residualPressure[gt]!.pascals, 0);
      expect(d.noFlowStaticPressure[gt]!.pascals, 0);
      final net = c.read(sizingNetworkProvider);
      final sizing = c.read(sizingProvider);
      final project = c.read(projectControllerProvider);
      final h = c.read(supplyMoverDutiesProvider)[tp]!.head.meters;
      final suction = net.edges.firstWhere((e) =>
          e.service == ServiceType.coldWater &&
          {e.fromId, e.toId}.containsAll([gt, tp]));
      final sz = sizing[suction.id]!;
      final hf = headLossHazenWilliams(
        flow: sz.flow,
        length: edgeLength(suction, net,
            calibrationBySheet: project.calibrations,
            building: project.building,
            mounting: project.mounting),
        diameter: sz.diameter,
        hazenWilliamsC: 150,
      ).meters;
      expect(d.residualPressure[tp]!.inKiloPascals,
          closeTo((h - hf) * 9.81, 1e-6));
      expect(d.residualPressure[tp]!.inKiloPascals, closeTo(outletKpa, 5e-4));

      // Delivery nodes byte-identical without the transfer side.
      final bare = ProviderContainer(overrides: [
        transferSideFieldProvider.overrideWithValue(const {}),
      ]);
      addTearDown(bare.dispose);
      await t.runAsync(() => loadRefDrawingSpec(bare, spec));
      await t.pump();
      final b = bare.read(downfeedDeliveredProvider)!;
      for (final id in d.deliveryNodeIds) {
        expect(d.residualPressure[id]!.pascals, b.residualPressure[id]!.pascals,
            reason: id);
      }
    });
  }
}
