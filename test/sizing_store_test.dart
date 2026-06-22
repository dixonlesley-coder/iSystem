import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx_engine/network/network.dart';

void main() {
  test('sizingProvider auto-sizes a drawn run', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(networkControllerProvider.notifier);
    n.setService(ServiceType.coldWater);
    n.setTool(DrawTool.drawRun);
    n.placeRunPoint('s1', 0, const Offset(0, 0));
    n.placeRunPoint('s1', 0, const Offset(1000, 0));

    final sizing = c.read(sizingProvider);
    expect(sizing, isNotEmpty);
    final s = sizing.values.first;
    expect(s.service, ServiceType.coldWater);
    expect(s.diameter.inMillimeters, greaterThan(0));
    expect(s.velocity.metersPerSecond, lessThanOrEqualTo(2.0));
  });

  test('empty network → empty sizing', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(sizingProvider), isEmpty);
  });

  test('showSizing toggles', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(showSizingProvider), isFalse);
    c.read(showSizingProvider.notifier).toggle();
    expect(c.read(showSizingProvider), isTrue);
  });
}
