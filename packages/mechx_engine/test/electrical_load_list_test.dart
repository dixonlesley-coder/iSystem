
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/load_list.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/sizing/fan.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// A5 unified-feed tests. Expected currents are hand-derived from first
/// principles: P_in = P_mech / η_m, then I = P_in / (√3·V·cosφ) for three-phase
/// or P_in / (V·cosφ) for single-phase.
void main() {
  const profile = PuilProfile();

  group('equipmentFullLoadCurrent — derivation', () {
    test('7.5 kW 3φ pump, η 0.9, cosφ 0.85, 400 V → 14.15 A', () {
      // P_in = 7500 / 0.9        = 8333.33 W
      // I    = 8333.33 / (√3 · 400 · 0.85)
      //      = 8333.33 / 588.897 = 14.151 A
      const e = MepEquipmentLoad(
        id: 'P-1',
        name: 'Booster pump',
        source: MepLoadSource.boosterPump,
        mechanicalPower: Power(7500),
        phases: 3,
        cosPhi: 0.85,
        motorEfficiency: 0.9,
      );
      final fla = equipmentFullLoadCurrent(e, voltage: const Voltage(400));
      expect(fla.amperes, closeTo(14.151, 0.01));
    });

    test('1.5 kW 1φ pump, η 0.9, cosφ 0.85, 220 V → 8.91 A', () {
      // P_in = 1500 / 0.9      = 1666.67 W
      // I    = 1666.67 / (220 · 0.85)
      //      = 1666.67 / 187   = 8.912 A
      const e = MepEquipmentLoad(
        id: 'P-2',
        name: 'Sump pump',
        source: MepLoadSource.sumpPump,
        mechanicalPower: Power(1500),
        phases: 1,
        cosPhi: 0.85,
        motorEfficiency: 0.9,
      );
      final fla = equipmentFullLoadCurrent(e, voltage: const Voltage(220));
      expect(fla.amperes, closeTo(8.912, 0.01));
    });

    test('known electricalInputPower wins over derived', () {
      // electricalInputPower given (5000 W) is used verbatim — efficiency ignored.
      // I = 5000 / (√3 · 400 · 0.85) = 5000 / 588.897 = 8.49 A
      const e = MepEquipmentLoad(
        id: 'P-3',
        name: 'Transfer pump',
        source: MepLoadSource.transferPump,
        mechanicalPower: Power(7500),
        electricalInputPower: Power(5000),
        phases: 3,
        cosPhi: 0.85,
        motorEfficiency: 0.5, // would change the result if it were used
      );
      expect(e.inputPower.watts, closeTo(5000, 1e-9));
      final fla = equipmentFullLoadCurrent(e, voltage: const Voltage(400));
      expect(fla.amperes, closeTo(8.490, 0.01));
    });
  });

  group('equipmentToCircuit — projection fields', () {
    test('3φ pump → branch pump circuit carries FLA override + link id', () {
      const e = MepEquipmentLoad(
        id: 'P-1',
        name: 'Booster pump',
        source: MepLoadSource.boosterPump,
        mechanicalPower: Power(7500),
        phases: 3,
        cosPhi: 0.85,
        motorEfficiency: 0.9,
      );
      final c = equipmentToCircuit(e, panelVoltage: const Voltage(400));

      expect(c.role, CircuitRole.branch);
      expect(c.loadKind, LoadKind.pump);
      expect(c.phases, 3);
      expect(c.cosPhi, 0.85);
      // motorKw = mechanical (rated motor) power in kW
      expect(c.motorKw, closeTo(7.5, 1e-9));
      // loadW = electrical input power = 7500 / 0.9 = 8333.33 W
      expect(c.loadW, closeTo(8333.33, 0.01));
      // re-import link
      expect(c.sourceEquipmentId, 'P-1');
      expect(c.id, 'mep-P-1');
      // FLA override = derived current (14.15 A)
      expect(c.flaOverrideA, isNotNull);
      expect(c.flaOverrideA!.amperes, closeTo(14.151, 0.01));
      // a booster pump is not life-safety
      expect(c.lifeSafety, isFalse);
    });

    test('fan → motor circuit; fire pump → life-safety', () {
      const fan = MepEquipmentLoad(
        id: 'F-1',
        name: 'Exhaust fan',
        source: MepLoadSource.exhaustFan,
        mechanicalPower: Power(2200),
      );
      final fc = equipmentToCircuit(fan, panelVoltage: const Voltage(400));
      expect(fc.loadKind, LoadKind.motor);
      expect(fc.lifeSafety, isFalse);

      const fire = MepEquipmentLoad(
        id: 'FP-1',
        name: 'Fire pump',
        source: MepLoadSource.firePump,
        mechanicalPower: Power(11000),
      );
      final firec = equipmentToCircuit(fire, panelVoltage: const Voltage(400));
      expect(firec.loadKind, LoadKind.pump);
      expect(firec.lifeSafety, isTrue);
    });
  });

  group('fromPumpDuty / fromFanDuty — duty mapping', () {
    test('fromPumpDuty pulls selectedMotor + motorInputPower', () {
      // Size a real duty so the test exercises the engine primitives, then map it.
      // 5 l/s at 30 m head, default η_pump 0.70, η_motor 0.90:
      //   P_hyd   = ρ·g·Q·H = 1000·9.81·0.005·30      = 1471.5 W
      //   P_shaft = 1471.5 / 0.70                      = 2102.1 W
      //   selectedMotor = smallest std ≥ 2102 W        = 2.2 kW
      //   P_input = 2102.1 / 0.90                       = 2335.7 W
      final duty = sizePump(
        flow: FlowRate.litersPerSecond(5),
        head: const Head(30),
      );
      expect(duty.selectedMotor.inKiloWatts, closeTo(2.2, 1e-9));

      final e = MepEquipmentLoad.fromPumpDuty(
        duty,
        id: 'P-9',
        name: 'Sized pump',
        source: MepLoadSource.supplyPump,
      );
      // mechanicalPower = selectedMotor (2.2 kW), electricalInputPower = duty's.
      expect(e.mechanicalPower.inKiloWatts, closeTo(2.2, 1e-9));
      expect(e.electricalInputPower, isNotNull);
      expect(e.electricalInputPower!.watts,
          closeTo(duty.motorInputPower.watts, 1e-9));
      expect(e.inputPower.watts, closeTo(duty.motorInputPower.watts, 1e-9));

      // FLA from the duty's own motor-input power at 400 V, cosφ 0.85:
      //   I = 2335.7 / (√3 · 400 · 0.85) = 3.966 A
      final fla = equipmentFullLoadCurrent(e, voltage: const Voltage(400));
      expect(fla.amperes, closeTo(3.966, 0.01));
    });

    test('fromFanDuty pulls selectedMotor + motorInputPower', () {
      // 2 m³/s at 500 Pa, default η_fan 0.65, η_motor 0.90:
      //   P_air   = Q·Δp = 2·500               = 1000 W
      //   P_shaft = 1000 / 0.65                = 1538.5 W
      //   selectedMotor = smallest std ≥ 1538.5 = 2.2 kW (1.5 kW is < shaft)
      //   P_input = 1538.5 / 0.90              = 1709.4 W
      final duty = sizeFan(
        airflow: const FlowRate(2),
        totalStaticPressure: const Pressure(500),
      );
      expect(duty.selectedMotor.inKiloWatts, closeTo(2.2, 1e-9));

      final e = MepEquipmentLoad.fromFanDuty(
        duty,
        id: 'F-9',
        name: 'Sized fan',
        source: MepLoadSource.supplyFan,
      );
      // mechanicalPower = selectedMotor (2.2 kW); the *input* power, which drives
      // the FLA, is the duty's own motorInputPower (1709.4 W), independent of the
      // rounded-up frame size.
      expect(e.mechanicalPower.inKiloWatts, closeTo(2.2, 1e-9));
      expect(e.electricalInputPower!.watts,
          closeTo(duty.motorInputPower.watts, 1e-9));
      // I = 1709.4 / (√3 · 400 · 0.85) = 2.902 A
      final fla = equipmentFullLoadCurrent(e, voltage: const Voltage(400));
      expect(fla.amperes, closeTo(2.902, 0.01));
    });
  });

  group('buildEquipmentCircuits — stable order', () {
    test('preserves input order and ids', () {
      const loads = [
        MepEquipmentLoad(
          id: 'a',
          name: 'Pump A',
          source: MepLoadSource.supplyPump,
          mechanicalPower: Power(3000),
        ),
        MepEquipmentLoad(
          id: 'b',
          name: 'Fan B',
          source: MepLoadSource.exhaustFan,
          mechanicalPower: Power(2200),
        ),
      ];
      final circuits =
          buildEquipmentCircuits(loads, panelVoltage: const Voltage(400));
      expect(circuits.map((c) => c.id).toList(), ['mep-a', 'mep-b']);
      expect(circuits.map((c) => c.sourceEquipmentId).toList(), ['a', 'b']);
    });
  });

  group('end-to-end — the FLA override wins in computePanel', () {
    test('panel sizes the breaker off flaOverrideA, not re-derived kW', () {
      // A 7.5 kW 3φ pump derived to 14.15 A. Feed that circuit through A4
      // computePanel; the circuit's designCurrent must equal the override
      // (14.2 A after the engine's 1-dp rounding), and the breaker the smallest
      // standard rating ≥ 14.2 A = 16 A — proving the override drove sizing.
      const e = MepEquipmentLoad(
        id: 'P-1',
        name: 'Booster pump',
        source: MepLoadSource.boosterPump,
        mechanicalPower: Power(7500),
        phases: 3,
        cosPhi: 0.85,
        motorEfficiency: 0.9,
      );
      final circuit = equipmentToCircuit(e, panelVoltage: const Voltage(400));

      final panel = ElectricalPanel(
        id: 'MP',
        name: 'Mech panel',
        system: ElectricalSystem.threePhase,
        voltage: const Voltage(400),
        circuits: [circuit],
      );
      final r = computePanel(profile, panel);
      final cr = r.circuits.single;

      // designCurrent == the override (rounded to 1 dp by the orchestrator).
      expect(cr.designCurrent.amperes, closeTo(14.2, 0.05));
      // smallest standard breaker that carries 14.15 A is 16 A.
      expect(cr.breaker.ratingA.amperes, 16);
      expect(cr.loadKind, LoadKind.pump);
      expect(cr.threePhase, isTrue);
    });
  });
}
