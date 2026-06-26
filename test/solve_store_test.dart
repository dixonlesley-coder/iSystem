import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart';

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
}
