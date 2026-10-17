import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_list.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// 2026-10 audit, group D-elec-core. Every expected value is hand-derived from
/// first principles in the comments beside it.
void main() {
  const profile = PuilProfile();

  group('elec-core-1 — single-phase A5 equipment on a 400 V board', () {
    // A 1φ FCU: shaft 1800 W, η 0.9, cosφ 0.85.
    //   P_in = 1800 / 0.9                    = 2000 W
    // The MEP board is 400 V LINE; a 1φ load is connected line-to-neutral, so
    // it sees V_ph = round(400/√3) = round(230.94) = 231 V.
    //   I    = 2000 / (231 · 0.85) = 2000 / 196.35 = 10.186 A
    // (The defect divided by 400 V: 2000/(400·0.85) = 5.882 A — √3 low.)
    const fcu = MepEquipmentLoad(
      id: 'FCU-1',
      name: 'FCU',
      source: MepLoadSource.supplyFan,
      mechanicalPower: Power(1800),
      phases: 1,
      cosPhi: 0.85,
      motorEfficiency: 0.9,
    );

    test('terminal voltage is the phase voltage (231 V), FLA 10.19 A', () {
      expect(
          equipmentTerminalVoltage(fcu, panelVoltage: const Voltage(400)).volts,
          231);
      final c = equipmentToCircuit(fcu, panelVoltage: const Voltage(400));
      expect(c.flaOverrideA!.amperes, closeTo(10.186, 0.005));
    });

    test('explicit board system wins over the >300 V heuristic', () {
      // A single-phase 230 V board: the 1φ load sees the board voltage verbatim.
      //   I = 2000 / (230 · 0.85) = 2000 / 195.5 = 10.230 A
      final c = equipmentToCircuit(fcu,
          panelVoltage: const Voltage(230),
          panelSystem: ElectricalSystem.singlePhase);
      expect(c.flaOverrideA!.amperes, closeTo(10.230, 0.005));
      // A three-phase item is untouched by the phase rule: still the line V.
      //   I = 2000 / (√3 · 400 · 0.85) = 2000 / 588.897 = 3.396 A
      const fcu3 = MepEquipmentLoad(
        id: 'FCU-3',
        name: 'FCU 3ph',
        source: MepLoadSource.supplyFan,
        mechanicalPower: Power(1800),
        phases: 3,
        cosPhi: 0.85,
        motorEfficiency: 0.9,
      );
      final c3 = equipmentToCircuit(fcu3, panelVoltage: const Voltage(400));
      expect(c3.flaOverrideA!.amperes, closeTo(3.396, 0.005));
    });

    test('computePanel sizes the way on 10.2 A → the 16 A rung (not 6 A)', () {
      // Ib = 10.186 → 10.2 A (1 dp). MCB ladder 6, 10, 16 …: 10 < 10.2 ⇒ 16 A.
      final c = equipmentToCircuit(fcu, panelVoltage: const Voltage(400));
      final r = computePanel(
        profile,
        ElectricalPanel(
          id: 'MEP',
          name: 'MEP',
          system: ElectricalSystem.threePhase,
          voltage: const Voltage(400),
          circuits: [c],
        ),
      );
      final cr = r.circuits.single;
      expect(cr.threePhase, isFalse);
      expect(cr.designCurrent.amperes, closeTo(10.2, 0.05));
      expect(cr.breaker.ratingA.amperes, 16);
    });
  });
}
