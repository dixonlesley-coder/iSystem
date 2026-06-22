import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/network/network.dart';

void main() {
  test('solve + pump + zones + bom derive from a cold-water network', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(networkControllerProvider.notifier);
    n.setService(ServiceType.coldWater);
    n.setTool(DrawTool.drawRun);
    n.placeRunPoint('s1', 0, const Offset(0, 0));
    n.placeRunPoint('s1', 0, const Offset(1000, 0));

    final solution = c.read(solveProvider);
    expect(solution, isNotNull);
    expect(solution!.requiredPumpHead.meters, greaterThan(0));
    expect(c.read(pumpDutyProvider), isNotNull);
    expect(c.read(zonesProvider), isNotEmpty);
    expect(c.read(bomProvider), isNotEmpty);
  });

  test('no cold-water network → null solve and pump', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(solveProvider), isNull);
    expect(c.read(pumpDutyProvider), isNull);
  });

  test('heatmap toggle', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(showHeatmapProvider), isFalse);
    c.read(showHeatmapProvider.notifier).toggle();
    expect(c.read(showHeatmapProvider), isTrue);
  });
}
