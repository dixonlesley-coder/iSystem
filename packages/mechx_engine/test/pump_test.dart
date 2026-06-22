import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// Pump-duty sizing tests.
///
/// All expected values are hand-computed in SI and verified before being
/// recorded here as the correctness anchor.
///
/// Primary duty point (duty-A):
///   flow  Q = 0.02 m³/s,  head H = 30 m,
///   η_pump = 0.70,         η_motor = 0.90
///
///   P_hydraulic = ρ·g·Q·H = 1000 × 9.81 × 0.02 × 30 = 5 886.000 W
///   P_shaft     = P_hyd / η_pump  = 5 886 / 0.70     = 8 408.571 428… W
///   P_input     = P_shaft / η_mot = 8 408.5714 / 0.90 = 9 342.857 142… W
///   shaft kW    = 8.408 571…  → smallest standard ≥ 8.4086 kW is 11 kW
///
/// Small duty point (duty-B):
///   flow  Q = 0.002 m³/s,  head H = 10 m,
///   η_pump = 0.65,          η_motor = 0.88
///
///   P_hydraulic = 1000 × 9.81 × 0.002 × 10 = 196.200 W
///   P_shaft     = 196.2 / 0.65             = 301.846 153… W
///   P_input     = 301.8461 / 0.88          = 342.893 356… W
///   shaft kW    = 0.301 846…  → smallest standard ≥ 0.3018 kW is 0.37 kW
void main() {
  // ── Primary duty point (duty-A) ──────────────────────────────────────────

  group('sizePump — duty-A (Q=0.02 m³/s, H=30 m, η_p=0.70, η_m=0.90)', () {
    late PumpDuty duty;

    setUpAll(() {
      duty = sizePump(
        flow: const FlowRate(0.02),
        head: const Head(30),
        pumpEfficiency: 0.70,
        motorEfficiency: 0.90,
      );
    });

    test('hydraulicPower = 5 886.000 W', () {
      expect(duty.hydraulicPower.watts, closeTo(5886.0, 1e-6));
    });

    test('shaftPower = 8 408.571 W', () {
      expect(duty.shaftPower.watts, closeTo(8408.5714286, 1e-4));
    });

    test('motorInputPower = 9 342.857 W', () {
      expect(duty.motorInputPower.watts, closeTo(9342.8571429, 1e-4));
    });

    test('selectedMotor = 11 kW', () {
      expect(duty.selectedMotor.inKiloWatts, closeTo(11.0, 1e-9));
    });

    test('selectedMotor > shaftPower (motor covers the demand)', () {
      expect(
        duty.selectedMotor.watts,
        greaterThanOrEqualTo(duty.shaftPower.watts),
      );
    });

    test('flow is preserved on result', () {
      expect(duty.flow.cubicMetersPerSecond, closeTo(0.02, 1e-12));
    });

    test('head is preserved on result', () {
      expect(duty.head.meters, closeTo(30.0, 1e-12));
    });
  });

  // ── Small duty point (duty-B) ────────────────────────────────────────────

  group('sizePump — duty-B (Q=0.002 m³/s, H=10 m, η_p=0.65, η_m=0.88)', () {
    late PumpDuty duty;

    setUpAll(() {
      duty = sizePump(
        flow: const FlowRate(0.002),
        head: const Head(10),
        pumpEfficiency: 0.65,
        motorEfficiency: 0.88,
      );
    });

    test('hydraulicPower = 196.200 W', () {
      expect(duty.hydraulicPower.watts, closeTo(196.2, 1e-6));
    });

    test('shaftPower = 301.846 W', () {
      // 196.2 / 0.65 = 301.846 153…
      expect(duty.shaftPower.watts, closeTo(301.8461538, 1e-4));
    });

    test('motorInputPower = 343.007 W', () {
      // 301.8461538 / 0.88 = 343.006 993…
      expect(duty.motorInputPower.watts, closeTo(343.0069930, 1e-4));
    });

    test('selectedMotor = 0.37 kW (smallest in the table)', () {
      expect(duty.selectedMotor.inKiloWatts, closeTo(0.37, 1e-9));
    });

    test('selectedMotor > shaftPower (motor covers the demand)', () {
      expect(
        duty.selectedMotor.watts,
        greaterThanOrEqualTo(duty.shaftPower.watts),
      );
    });
  });

  // ── selectMotor unit-tests ────────────────────────────────────────────────

  group('selectMotor', () {
    test('exactly 11 kW shaft → selects 11 kW motor', () {
      final m = selectMotor(Power.kiloWatts(11.0));
      expect(m.inKiloWatts, closeTo(11.0, 1e-9));
    });

    test('11.001 kW shaft → selects 15 kW motor (next step up)', () {
      final m = selectMotor(Power.kiloWatts(11.001));
      expect(m.inKiloWatts, closeTo(15.0, 1e-9));
    });

    test('0.0 kW shaft → selects 0.37 kW motor (smallest standard)', () {
      final m = selectMotor(const Power(0.0));
      expect(m.inKiloWatts, closeTo(0.37, 1e-9));
    });

    test('75.001 kW shaft → returns 75 kW (largest, oversized condition)', () {
      final m = selectMotor(Power.kiloWatts(75.001));
      expect(m.inKiloWatts, closeTo(75.0, 1e-9));
    });

    test('exactly 75 kW shaft → selects 75 kW motor', () {
      final m = selectMotor(Power.kiloWatts(75.0));
      expect(m.inKiloWatts, closeTo(75.0, 1e-9));
    });
  });

  // ── standardMotorKw list sanity checks ───────────────────────────────────

  group('standardMotorKw', () {
    test('has 19 entries', () {
      expect(standardMotorKw.length, 19);
    });

    test('is strictly ascending', () {
      for (var i = 0; i < standardMotorKw.length - 1; i++) {
        expect(
          standardMotorKw[i],
          lessThan(standardMotorKw[i + 1]),
          reason: 'entry $i (${standardMotorKw[i]}) should be < '
              'entry ${i + 1} (${standardMotorKw[i + 1]})',
        );
      }
    });

    test('first entry is 0.37 kW and last is 75 kW', () {
      expect(standardMotorKw.first, closeTo(0.37, 1e-9));
      expect(standardMotorKw.last, closeTo(75.0, 1e-9));
    });
  });
}
