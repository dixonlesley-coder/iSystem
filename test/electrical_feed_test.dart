import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/load_list.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/units.dart';

/// The MEP→electrical auto-feed seam: a pump/fan the mechanical engine sized
/// becomes a sized electrical circuit in the project (the unified payoff).
void main() {
  test('syncMepEquipment folds a sized MEP load into the electrical project '
      'and the panel sizes off the derived FLA', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // A 7.5 kW pump whose motor input is 8.333 kW → derived FLA via A5.
    final loads = [
      MepEquipmentLoad(
        id: 'booster',
        name: 'Booster pump',
        source: MepLoadSource.supplyPump,
        mechanicalPower: Power.kiloWatts(7.5),
        electricalInputPower: Power.kiloWatts(8.333),
      ),
    ];
    final circuits =
        buildEquipmentCircuits(loads, panelVoltage: const Voltage(400));
    expect(circuits, hasLength(1));
    expect(circuits.single.sourceEquipmentId, 'booster');
    expect(circuits.single.loadKind, LoadKind.pump);
    final fla = circuits.single.flaOverrideA;
    expect(fla, isNotNull);

    container.read(electricalProjectProvider.notifier).syncMepEquipment(circuits);
    final result = container.read(electricalResultProvider);
    final mep = result.panels['mep-equipment'];
    expect(mep, isNotNull);
    expect(mep!.circuits, hasLength(1));
    // The panel sizes the circuit off MechX's derived FLA (not re-derived):
    // designCurrent == the override, rounded to 1 dp by the engine.
    expect(
      mep.circuits.single.designCurrent.amperes,
      closeTo(fla!.amperes, 0.05),
    );

    // Re-syncing with no equipment removes the panel (idempotent upsert).
    container.read(electricalProjectProvider.notifier).syncMepEquipment(const []);
    expect(container.read(electricalResultProvider).panels['mep-equipment'],
        isNull);
  });

  test('mepEquipmentCircuitsProvider derives a circuit from a live pump duty',
      () {
    final container = ProviderContainer(overrides: [
      pumpDutyProvider.overrideWith((ref) => const PumpDuty(
            flow: FlowRate(0.005),
            head: Head(30),
            hydraulicPower: Power(1500),
            shaftPower: Power(2100),
            motorInputPower: Power(2500),
            selectedMotor: Power(3000),
          )),
      ductFanProvider.overrideWith((ref) => null),
    ]);
    addTearDown(container.dispose);

    final circuits = container.read(mepEquipmentCircuitsProvider);
    final pump =
        circuits.firstWhere((c) => c.sourceEquipmentId == 'supply-pump');
    expect(pump.loadKind, LoadKind.pump);
    expect(pump.motorKw, closeTo(3.0, 1e-9)); // selectedMotor = 3 kW
    expect(pump.flaOverrideA, isNotNull);
    // 2.5 kW input / (√3·400·0.85) ≈ 4.25 A
    expect(pump.flaOverrideA!.amperes, closeTo(4.25, 0.1));
  });

  test('a pump NODE placed on the plan is inter-related as an electrical load',
      () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final net = container.read(networkControllerProvider.notifier);

    // Drop a pump (default 1.5 kW) and an exhaust fan with an explicit 900 W.
    net.addComponentNode('s1', 0, const Offset(10, 10), NodeComponent.pump);
    net.addComponentNode('s1', 0, const Offset(20, 20), NodeComponent.exhaustFan);
    final fanId = container
        .read(networkControllerProvider)
        .network
        .nodes
        .firstWhere((n) => n.component == NodeComponent.exhaustFan)
        .id;
    net.setNodeElectricalLoad(fanId, 900);
    // A non-electrical component (gate valve) must NOT surface as a load.
    net.addComponentNode('s1', 0, const Offset(30, 30), NodeComponent.gateValve);

    final loads = container.read(placedEquipmentLoadsProvider);
    expect(loads, hasLength(2));
    final pump =
        loads.firstWhere((l) => l.source == MepLoadSource.supplyPump);
    expect(pump.mechanicalPower.inKiloWatts, closeTo(1.5, 1e-9)); // default
    final fan =
        loads.firstWhere((l) => l.source == MepLoadSource.exhaustFan);
    expect(fan.mechanicalPower.watts, closeTo(900, 1e-9)); // explicit override

    // They become circuits on the MEP equipment feed, keyed by node id.
    final circuits = container.read(mepEquipmentCircuitsProvider);
    expect(circuits.where((c) => c.sourceEquipmentId!.startsWith('node-')),
        hasLength(2));
  });
}
