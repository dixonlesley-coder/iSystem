import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/cooling_load.dart';

/// A container with sheet s1 calibrated at 0.01 m/px, optionally a 2 m² office
/// room, and one cassette-AC node placed inside (or far outside) it.
ProviderContainer _setup({double? overrideW, bool inRoom = true}) {
  final c = ProviderContainer();
  c
      .read(projectControllerProvider.notifier)
      .setCalibration('s1', const ScaleCalibration(0.01));
  if (inRoom) {
    c.read(roomAreasProvider.notifier).set(const [
      RoomArea(
          id: 'r0', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 100),
    ]);
  }
  c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
        NetNode(
          id: 'ac1',
          sheetId: 's1',
          x: inRoom ? 100 : 9000,
          y: 50,
          floorIndex: 0,
          role: NodeRole.plant,
          component: NodeComponent.acCassette,
          electricalLoadW: overrideW,
        ),
      ]));
  return c;
}

void main() {
  test('a placed AC load tracks the room cooling PK (not the component default)',
      () {
    final c = _setup();
    addTearDown(c.dispose);
    final loads = c.read(placedEquipmentLoadsProvider);
    expect(loads, hasLength(1));
    // Room: 2 m² × 3 m × 600 BTU/h·m² = 1200 BTU/h; 1 unit → 0.5 PK = 5000 BTU/h
    // nominal → input W = 5000/3.412141633/3 ≈ 488 W.
    final expected = acInputPowerW(coolingBtuPerHr: 5000.0);
    expect(loads.single.mechanicalPower.watts, closeTo(expected, 1e-6));
    // ... clearly below the cassette default of 1.8 kW.
    expect(loads.single.mechanicalPower.watts, lessThan(1800));
    // Wall/cassette AC are single-phase.
    expect(loads.single.phases, 1);
  });

  test('an explicit electricalLoadW override wins over the cooling-derived load',
      () {
    final c = _setup(overrideW: 1234);
    addTearDown(c.dispose);
    expect(c.read(placedEquipmentLoadsProvider).single.mechanicalPower.watts,
        1234);
  });

  test('an AC outside any room falls back to the component default (1.8 kW)', () {
    final c = _setup(inRoom: false);
    addTearDown(c.dispose);
    expect(c.read(placedEquipmentLoadsProvider).single.mechanicalPower.watts,
        closeTo(1800, 1e-6));
  });
}
