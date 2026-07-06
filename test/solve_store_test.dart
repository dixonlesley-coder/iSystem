import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/air_velocity.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

void main() {
  void drawColdRun(ProviderContainer c) {
    final n = c.read(networkControllerProvider.notifier);
    n.setService(ServiceType.coldWater);
    n.setTool(DrawTool.drawRun);
    n.placeRunPoint('s1', 0, const Offset(0, 0));
    n.placeRunPoint('s1', 0, const Offset(1000, 0));
  }

  test('pipeCutPlanProvider plans stock pipes for a calibrated network', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c
        .read(projectControllerProvider.notifier)
        .setCalibration('s1', const ScaleCalibration(0.02));
    drawColdRun(c); // 1000 px x 0.02 = a 20 m cold-water main

    final plan = c.read(pipeCutPlanProvider);
    expect(plan, isNotEmpty);
    final g = plan.first;
    expect(g.service, ServiceType.coldWater);
    expect(g.stockLengthM, 4.0); // PVC/PPR
    expect(g.plan.requiredM, closeTo(20.0, 1e-6));
    // 20 m / 4 m = exactly 5 stock bars, no waste.
    expect(g.plan.totalBars, 5);
    expect(g.plan.wasteM, closeTo(0.0, 1e-6));
  });

  test('consumablesProvider estimates PVC cement from a drainage network', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c
        .read(projectControllerProvider.notifier)
        .setCalibration('s1', const ScaleCalibration(0.02));
    final n = c.read(networkControllerProvider.notifier);
    // A long PVC drainage run (solvent weld) with a fixture so it sizes; the
    // 20 m run is 5 stock lengths ⇒ inline couplings ⇒ solvent joints.
    n.setService(ServiceType.drainage);
    n.setTool(DrawTool.drawRun);
    n.placeRunPoint('s1', 0, const Offset(0, 0));
    n.placeRunPoint('s1', 0, const Offset(1000, 0));
    n.setTool(DrawTool.select);
    final endNode = c
        .read(networkControllerProvider)
        .network
        .nodes
        .reduce((a, b) => a.x > b.x ? a : b);
    n.setNodeFixture(endNode.id, PlumbingFixture.waterClosetFlushTank);

    final est = c.read(consumablesProvider);
    expect(est.solventJoints, greaterThan(0));
    expect(est.pvcCementCans, greaterThanOrEqualTo(1));
  });

  test('upfeed: solve + pump + zones + bom derive from a cold-water network',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(feedStrategyProvider.notifier).set(FeedStrategy.upfeed);
    drawColdRun(c);

    final solution = c.read(solveProvider);
    expect(solution, isNotNull);
    expect(solution!.requiredPumpHead.meters, greaterThan(0));
    expect(c.read(pumpDutyProvider), isNotNull);
    expect(c.read(residualByNodeProvider), isNotEmpty);
    expect(c.read(zonesProvider), isNotEmpty);
    expect(c.read(bomProvider), isNotEmpty);
  });

  test('downfeed: gravity solve fills the residual field; no pump', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // downfeed is the default strategy.
    drawColdRun(c);

    expect(c.read(solveProvider), isNull); // upfeed solve inactive
    final down = c.read(downfeedProvider);
    expect(down, isNotNull);
    expect(c.read(residualByNodeProvider), isNotEmpty);
    expect(c.read(pumpDutyProvider), isNull); // gravity-fed, no booster pump
  });

  test('no cold-water network → null solve and pump', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(feedStrategyProvider.notifier).set(FeedStrategy.upfeed);
    expect(c.read(solveProvider), isNull);
    expect(c.read(pumpDutyProvider), isNull);
    expect(c.read(residualByNodeProvider), isEmpty);
  });

  test('heatmap toggle', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(showHeatmapProvider), isFalse);
    c.read(showHeatmapProvider.notifier).toggle();
    expect(c.read(showHeatmapProvider), isTrue);
  });

  test('targetResidualProvider is the SNI design target (2.25 bar)', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // 2.25 bar = 225 kPa — the absolute pass anchor the heatmap + probe read.
    expect(c.read(targetResidualProvider).inKiloPascals, closeTo(225, 1e-6));
  });

  test(
      'waterVelocityChecksProvider judges a sized water run against the SNI '
      'max supply velocity (I3)', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c
        .read(projectControllerProvider.notifier)
        .setCalibration('s1', const ScaleCalibration(0.02));
    final n = c.read(networkControllerProvider.notifier);
    // A cold-water run terminating at a WC so the edge carries demand → flow →
    // a sized diameter with a real velocity.
    n.setService(ServiceType.coldWater);
    n.setTool(DrawTool.drawRun);
    n.placeRunPoint('s1', 0, const Offset(0, 0));
    n.placeRunPoint('s1', 0, const Offset(1000, 0));
    n.setTool(DrawTool.select);
    final endNode = c
        .read(networkControllerProvider)
        .network
        .nodes
        .reduce((a, b) => a.x > b.x ? a : b);
    n.setNodeFixture(endNode.id, PlumbingFixture.waterClosetFlushTank);

    final runEdge = c
        .read(networkControllerProvider)
        .network
        .edges
        .firstWhere((e) => e.kind == EdgeKind.run);

    // Auto-sized: within the SNI supply band (the sizer sizes TO ≤ 2.0 m/s).
    final auto = c.read(waterVelocityChecksProvider)[runEdge.id];
    expect(auto, isNotNull, reason: 'a sized water run must be judged');
    expect(auto!.actual.metersPerSecond, greaterThan(0));
    expect(auto.max, const SniProfile().maxSupplyVelocity.value);
    expect(auto.verdict, VelocityBandVerdict.ok);
    expect(auto.isWarning, isFalse);

    // Force a diameter small enough that the SAME flow drives the velocity well
    // over the SNI cap — derived from the engine's own numbers so it is
    // deterministic regardless of the exact fixture flow.
    final sized = c.read(sizingProvider)[runEdge.id]!;
    final v0 = sized.velocity.metersPerSecond;
    final d0 = sized.diameter.meters;
    // v ∝ 1/d²; pick d so v ≈ 6 m/s → comfortably 'too high'.
    final dSmall = d0 * math.sqrt(v0 / 6.0);
    n.setEdgeSizeOverride(runEdge.id, Diameter(dSmall));

    final over = c.read(waterVelocityChecksProvider)[runEdge.id]!;
    expect(over.verdict, VelocityBandVerdict.tooHigh);
    expect(over.isWarning, isTrue);
  });
}
