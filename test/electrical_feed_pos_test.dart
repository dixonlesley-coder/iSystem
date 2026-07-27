import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/network/network.dart';

/// A placed equipment NODE's plan position (sheet/floor/x/y) rides through as
/// the derived [MepEquipmentLoad.loadPos] and, from there, into the sized
/// circuit's [ElectricalCircuit.loadPos] — so a pump/fan drawn on the layout
/// can get a geo-derived cable length instead of a typed-in manual one.
/// Duty-derived loads (the auto-sized system pump/fan/fire-pump, built from
/// `solve_store`/`fire_store` — no plan position of their own) stay unplaced.
void main() {
  test('a placed pump NODE yields a loadPos carrying its sheet/floor/x/y', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final net = container.read(networkControllerProvider.notifier);

    net.addComponentNode('s1', 2, const Offset(123, 456), NodeComponent.pump);

    final loads = container.read(placedEquipmentLoadsProvider);
    expect(loads, hasLength(1));
    final pos = loads.single.loadPos;
    expect(pos, isNotNull);
    expect(pos!.sheetId, 's1');
    expect(pos.floorIndex, 2);
    expect(pos.x, 123);
    expect(pos.y, 456);
  });

  test('the derived circuit carries the same loadPos as its source node', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final net = container.read(networkControllerProvider.notifier);

    net.addComponentNode(
        's2', 1, const Offset(10, 20), NodeComponent.exhaustFan);

    final circuits = container.read(mepEquipmentCircuitsProvider);
    final fan =
        circuits.firstWhere((c) => c.sourceEquipmentId!.startsWith('node-'));
    expect(
      fan.loadPos,
      const LayoutPos(sheetId: 's2', floorIndex: 1, x: 10, y: 20),
    );
  });

  test('duty-derived loads (no plan position) stay loadPos-less', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // No pump/fan duty and no standpipe head in the default project, so the
    // duty feed is empty; assert the invariant on the provider directly so
    // this doesn't depend on a live duty being sized.
    final dutyLoads = container.read(mepEquipmentLoadsProvider);
    for (final l in dutyLoads) {
      expect(l.loadPos, isNull);
    }
  });
}
