// Unit tests for the pure `equipmentDetail` helper that drives the equipment
// detail suffix (capacity / duty) drawn beside a node on the single-line.
//
// HONESTY contract under test: a suffix is returned ONLY when the datum exists
// (a tank's capacity, or a system duty provider non-null); otherwise null so
// the node keeps its plain name and no value is fabricated.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/schematic/schematic_view.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fan.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/units.dart';

NetNode _node(NodeComponent? component, {double? tankCapacityLitres}) => NetNode(
      id: 'n1',
      sheetId: 's1',
      x: 0,
      y: 0,
      floorIndex: 0,
      role: component?.role ?? NodeRole.main,
      component: component,
      tankCapacityLitres: tankCapacityLitres,
    );

// A PumpDuty whose selected motor is exactly 5.5 kW — built via the engine's
// own Power constructor (not a magic literal). The other duty fields are
// irrelevant to equipmentDetail, so derive them consistently.
PumpDuty _pump(double motorKw) => PumpDuty(
      flow: FlowRate.litersPerSecond(2),
      head: const Head(30),
      hydraulicPower: Power.kiloWatts(motorKw),
      shaftPower: Power.kiloWatts(motorKw),
      motorInputPower: Power.kiloWatts(motorKw),
      selectedMotor: Power.kiloWatts(motorKw),
    );

FanDuty _fan(double motorKw) => FanDuty(
      airflow: FlowRate.cubicMetersPerHour(1000),
      totalStaticPressure: const Pressure(250),
      airPower: Power.kiloWatts(motorKw),
      shaftPower: Power.kiloWatts(motorKw),
      motorInputPower: Power.kiloWatts(motorKw),
      selectedMotor: Power.kiloWatts(motorKw),
    );

void main() {
  group('equipmentDetail — tank capacity', () {
    test('a roof tank with a capacity shows its m³', () {
      final node = _node(NodeComponent.roofTank, tankCapacityLitres: 237000);
      expect(equipmentDetail(node), '237 m³');
    });

    test('a ground tank with a small capacity keeps one decimal', () {
      final node = _node(NodeComponent.groundTank, tankCapacityLitres: 12500);
      expect(equipmentDetail(node), '12.5 m³');
    });

    test('a tank with no capacity is omitted (null)', () {
      expect(equipmentDetail(_node(NodeComponent.roofTank)), isNull);
      expect(
        equipmentDetail(_node(NodeComponent.groundTank, tankCapacityLitres: 0)),
        isNull,
      );
    });
  });

  group('equipmentDetail — pump / fan duty', () {
    test('a pump shows duty kW only when the supply-pump duty is provided', () {
      final node = _node(NodeComponent.pump);
      expect(equipmentDetail(node, supplyPump: _pump(5.5)), '5.5 kW');
      // Honest omit: no duty available (e.g. downfeed gravity ⇒ null provider).
      expect(equipmentDetail(node), isNull);
    });

    test('a booster set tracks the same supply-pump duty', () {
      expect(
        equipmentDetail(_node(NodeComponent.boosterSet), supplyPump: _pump(7.5)),
        '7.5 kW',
      );
      expect(equipmentDetail(_node(NodeComponent.boosterSet)), isNull);
    });

    test('an AHU / fan shows the duct-fan duty only when present', () {
      expect(equipmentDetail(_node(NodeComponent.ahu), fan: _fan(1.5)), '1.5 kW');
      expect(equipmentDetail(_node(NodeComponent.supplyFan)), isNull);
    });
  });

  group('equipmentDetail — no detail for non-equipment', () {
    test('a plain valve has no detail', () {
      expect(equipmentDetail(_node(NodeComponent.gateValve)), isNull);
    });

    test('a node with no component has no detail', () {
      expect(equipmentDetail(_node(null)), isNull);
    });

    test('a pump duty is NOT attached to an unrelated tank', () {
      // Even with a supply-pump duty in scope, a tank only shows its capacity.
      final tank = _node(NodeComponent.roofTank, tankCapacityLitres: 100000);
      expect(equipmentDetail(tank, supplyPump: _pump(5.5)), '100 m³');
    });
  });
}
