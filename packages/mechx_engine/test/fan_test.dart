/// Tests for the §8 fan-duty sizing module. Air power P = Q·Δp; expected
/// values hand-computed and checked with `closeTo`.
library;

import 'package:mechx_engine/sizing/fan.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  group('sizeFan — Q = 2 m³/s, Δp = 300 Pa, η_fan 0.65, η_motor 0.90', () {
    late FanDuty duty;
    setUp(() {
      duty = sizeFan(
        airflow: const FlowRate(2.0),
        totalStaticPressure: const Pressure(300),
      );
    });

    test('air power = Q·Δp = 600 W', () {
      expect(duty.airPower.watts, closeTo(600.0, 1e-9));
    });

    test('shaft power = air / 0.65 ≈ 923.08 W', () {
      expect(duty.shaftPower.watts, closeTo(600.0 / 0.65, 1e-6));
    });

    test('motor input = shaft / 0.90', () {
      expect(duty.motorInputPower.watts,
          closeTo((600.0 / 0.65) / 0.90, 1e-6));
    });

    test('selected motor is the smallest standard ≥ shaft (1.1 kW)', () {
      // shaft ≈ 0.923 kW → next standard frame is 1.1 kW.
      expect(duty.selectedMotor.inKiloWatts, closeTo(1.1, 1e-9));
    });

    test('shaft > air power (efficiency < 1); flow/pressure echoed', () {
      expect(duty.shaftPower.watts, greaterThan(duty.airPower.watts));
      expect(duty.airflow.cubicMetersPerSecond, 2.0);
      expect(duty.totalStaticPressure.pascals, 300.0);
    });
  });

  test('higher static → larger air power and motor', () {
    final low = sizeFan(
        airflow: const FlowRate(1.0), totalStaticPressure: const Pressure(100));
    final high = sizeFan(
        airflow: const FlowRate(1.0), totalStaticPressure: const Pressure(500));
    expect(high.airPower.watts, greaterThan(low.airPower.watts));
    expect(high.selectedMotor.inKiloWatts,
        greaterThanOrEqualTo(low.selectedMotor.inKiloWatts));
  });
}
