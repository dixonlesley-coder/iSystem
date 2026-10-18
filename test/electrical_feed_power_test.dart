import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/electrical/load_list.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

/// 3-phase FLA at the MEP panel voltage: I = P / (√3·V·cosφ).
double _fla3(double inputW) =>
    inputW / (math.sqrt(3) * mepPanelVoltage.volts * defaultMotorCosPhi);

void main() {
  group('wiring-2 — the fire-pump way is sized on the NFPA 20 motor', () {
    test('8 × 4 m: circuit carries the 75 kW selected motor, not shaft kW', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(projectControllerProvider.notifier).setFloors([
        for (var i = 0; i < 8; i++) Floor('L$i', const Length(4)),
      ]);
      // Round 15 — the fire pump exists only once a fire service is drawn.
      drawFireHydrantRun(c);

      final st = c.read(standpipeDesignProvider);
      final rating = c.read(firePumpRatingProvider);
      // The rated-point shaft power is below the overload-governed motor.
      expect(rating.selectedMotor.watts,
          greaterThan(st.pumpShaftPower.watts));
      // The NFPA motor is the smallest standard frame covering the OVERLOAD
      // shaft power (independently re-selected from the engine ladder).
      expect(rating.selectedMotor.watts,
          selectMotor(rating.overload.shaftPower).watts);
      expect(rating.selectedMotor.inKiloWatts, 75);

      // ONE fire-pump kW: the shared duty's motor IS the rating's motor.
      final duty = c.read(firePumpDutyProvider)!;
      expect(duty.selectedMotor.watts, rating.selectedMotor.watts);

      final load = c
          .read(mepEquipmentLoadsProvider)
          .singleWhere((l) => l.source == MepLoadSource.firePump);
      expect(load.mechanicalPower.watts, rating.selectedMotor.watts);

      final circuit = c
          .read(mepEquipmentCircuitsProvider)
          .singleWhere((cc) => cc.sourceEquipmentId == 'fire-pump');
      // Input = 75 kW / 0.9 = 83.33 kW; FLA = 83333/(√3·400·0.85) ≈ 141.5 A.
      final input = 75000 / defaultMotorEfficiency;
      expect(circuit.loadW, closeTo(input, 1e-6));
      expect(circuit.flaOverrideA, closeTo(_fla3(input), 1e-6));
      expect(circuit.flaOverrideA, closeTo(141.5, 0.1));
      expect(circuit.lifeSafety, isTrue);
    });
  });

  group('wiring-3 — an entered electrical load is NOT divided by η again', () {
    ProviderContainer pumpNode({double? electricalLoadW}) {
      final c = ProviderContainer();
      c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
            NetNode(
              id: 'p1',
              sheetId: 's1',
              x: 10,
              y: 10,
              floorIndex: 0,
              role: NodeRole.plant,
              component: NodeComponent.pump,
              electricalLoadW: electricalLoadW,
            ),
          ]));
      return c;
    }

    test('electricalLoadW 1500 W ⇒ the circuit draws exactly 1500 W', () {
      final c = pumpNode(electricalLoadW: 1500);
      addTearDown(c.dispose);
      final circuit = c.read(placedEquipmentCircuitsProvider).single;
      expect(circuit.loadW, closeTo(1500, 1e-9));
      // FLA = 1500 / (√3·400·0.85) ≈ 2.547 A (no ÷0.9 inflation to 2.83 A).
      expect(circuit.flaOverrideA, closeTo(_fla3(1500), 1e-9));
      expect(circuit.flaOverrideA, closeTo(2.547, 0.001));
      // The displayed kW stays the entered one.
      expect(circuit.motorKw, closeTo(1.5, 1e-9));
    });

    test('the component-default SHAFT rating still derives input as kW / η',
        () {
      final c = pumpNode();
      addTearDown(c.dispose);
      final shaftW = NodeComponent.pump.defaultMotorKw * 1000;
      final circuit = c.read(placedEquipmentCircuitsProvider).single;
      expect(circuit.loadW, closeTo(shaftW / defaultMotorEfficiency, 1e-9));
    });
  });
}
