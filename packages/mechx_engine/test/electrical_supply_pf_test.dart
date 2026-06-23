import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/power_factor.dart';
import 'package:mechx_engine/electrical/supply_design.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// A8b — supply / transformer determination + PLN daya + power-factor
/// correction. Expected values are hand-derived from the formulas + the local
/// `// VERIFY` ladders, so they anchor the port (tests-are-the-spec).
void main() {
  const profile = PuilProfile();

  group('determineSupply — LV vs MV (transformer ladder + FLC)', () {
    test('demand <= 200 kVA -> direct LV, no transformer', () {
      // 150 kVA <= the 200 kVA Indonesian LV ceiling -> direct PLN LV.
      final s = determineSupply(ApparentPower.kilovoltAmperes(150));
      expect(s.lvOrMv, SupplyLevel.lv);
      expect(s.isMv, isFalse);
      expect(s.units, 0);
      expect(s.transformerKva, isNull);
      expect(s.mvVoltage, isNull);
      expect(s.primaryFlc, isNull);
      expect(s.secondaryFlc, isNull);
      expect(s.demandKva, closeTo(150, 1e-9));
      expect(s.lvVoltage.volts, 400);
      expect(s.verifyItems, isNotEmpty);
    });

    test('demand at the 200 kVA ceiling is still LV (<=)', () {
      final s = determineSupply(ApparentPower.kilovoltAmperes(200));
      expect(s.lvOrMv, SupplyLevel.lv);
    });

    test('demand > 200 kVA -> MV + a transformer off the ladder, FLC checked',
        () {
      // 300 kVA > 200 -> MV. requiredKva = 300 / 0.8 = 375.
      // Ladder [...,315,400,...] -> smallest >= 375 is 400 kVA.
      // primaryFlc  = 400000 / (sqrt(3) * 20000) = 11.547 -> 11.5 A (1 dp).
      // secondaryFlc= 400000 / (sqrt(3) *   400) = 577.35 -> 577 A (0 dp).
      final s = determineSupply(ApparentPower.kilovoltAmperes(300));
      expect(s.lvOrMv, SupplyLevel.mv);
      expect(s.isMv, isTrue);
      expect(s.units, 1);
      expect(s.transformerKva, 400);
      expect(s.impedancePct, 4);
      expect(s.mvVoltage!.volts, 20000);

      final primary = 400 * 1000 / (math.sqrt(3) * 20000); // 11.547
      final secondary = 400 * 1000 / (math.sqrt(3) * 400); // 577.35
      expect(s.primaryFlc!.amperes, closeTo((primary * 10).round() / 10, 1e-9));
      expect(s.primaryFlc!.amperes, closeTo(11.5, 1e-9));
      expect(s.secondaryFlc!.amperes, closeTo(secondary.roundToDouble(), 1e-9));
      expect(s.secondaryFlc!.amperes, closeTo(577, 1e-9));
    });

    test('dualTransformer forces MV with 2 half-demand units even below 200 kVA',
        () {
      // 120 kVA, dual: perUnitRequired = 120/2/0.8 = 75 -> ladder >= 75 is 100.
      final s = determineSupply(
        ApparentPower.kilovoltAmperes(120),
        dualTransformer: true,
      );
      expect(s.lvOrMv, SupplyLevel.mv);
      expect(s.units, 2);
      expect(s.transformerKva, 100);
    });
  });

  group('recommendedDayaVa — next PLN connected-power step', () {
    test('3-phase demand picks the next 3-phase daya step', () {
      // 50 kVA = 50000 VA. 3φ ladder [...,41500,53000,...] -> 53000.
      final daya = recommendedDayaVa(
        ApparentPower.kilovoltAmperes(50),
        ElectricalSystem.threePhase,
      );
      expect(daya, 53000);
      expect(formatDaya(daya), '53,000 VA (53 kVA)');
    });

    test('exact-match demand returns that step (>=)', () {
      final daya = recommendedDayaVa(
        const ApparentPower(53000),
        ElectricalSystem.threePhase,
      );
      expect(daya, 53000);
    });

    test('1-phase demand picks the next 1-phase daya step', () {
      // 4000 VA. 1φ ladder [...,3500,4400,...] -> 4400.
      final daya = recommendedDayaVa(
        const ApparentPower(4000),
        ElectricalSystem.singlePhase,
      );
      expect(daya, 4400);
    });

    test('demand beyond the LV catalogue clamps to the largest step', () {
      final daya = recommendedDayaVa(
        ApparentPower.kilovoltAmperes(500),
        ElectricalSystem.threePhase,
      );
      expect(daya, 233000); // largest 3φ daya step
    });
  });

  group('powerFactorCorrection — capacitor bank sizing', () {
    test('low-PF project -> a sized capacitor bank (hand-checked kVAR)', () {
      // One 100 kW welding load at cosφ 0.7, demandFactor 1, ambient 30 °C.
      //   kW   = 100
      //   tanφ1 (pf 0.70) = sqrt(1-0.49)/0.7 = 1.020204
      //   kvar = 100 * 1.020204 = 102.0204
      //   kVA  = hypot(100, 102.0204) = 142.857 (= 100/0.7)
      //   existingPf = 100/142.857 = 0.70  (< 0.85 penalty -> needed)
      //   tanφ2 (pf 0.95) = sqrt(1-0.9025)/0.95 = 0.328684
      //   requiredKvar = 100*(1.020204 - 0.328684) = 69.152
      //   ambient 30 -> derate 1.0 ; bank ladder [...,50,75,...] -> 75
      //   stepKvar = 25 (75 in (50,150]) ; steps = round(75/25) = 3
      const panel = ElectricalPanel(
        id: 'MDP',
        name: 'MDP',
        system: ElectricalSystem.threePhase,
        voltage: Voltage(400),
        ambientTempC: 30,
        circuits: [
          ElectricalCircuit(
            id: 'w1',
            name: 'Welder',
            loadKind: LoadKind.welding,
            loadW: 100000,
            cosPhi: 0.7,
            length: Length(10),
          ),
        ],
      );
      const project = ElectricalProject(
        id: 'P',
        name: 'PF low',
        panels: [panel],
        earthingSystem: EarthingSystem.tnCs,
      );
      final sys = computeSystem(profile, project);

      final r = powerFactorCorrection(sys, project);
      expect(r.totalKw, closeTo(100.0, 1e-6));
      expect(r.totalKvar, closeTo(102.0, 0.1));
      expect(r.existingPf, closeTo(0.70, 1e-3));
      expect(r.needed, isTrue);
      expect(r.requiredKvar, closeTo(69.2, 0.2)); // 69.152 -> 1 dp
      expect(r.bankKvar, 75);
      expect(r.stepKvar, 25);
      expect(r.steps, 3);
      expect(r.detuned, isFalse);
    });

    test('harmonicRich low-PF project -> a DETUNED bank', () {
      const project = ElectricalProject(
        id: 'P2',
        name: 'PF harmonic',
        panels: [
          ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            ambientTempC: 30,
            circuits: [
              ElectricalCircuit(
                id: 'w1',
                name: 'Welder',
                loadKind: LoadKind.welding,
                loadW: 100000,
                cosPhi: 0.7,
                length: Length(10),
              ),
            ],
          ),
        ],
      );
      final sys = computeSystem(profile, project);
      final r = powerFactorCorrection(sys, project, harmonicRich: true);
      expect(r.bankKvar, greaterThan(0));
      expect(r.detuned, isTrue);
    });

    test('good-PF project -> no bank', () {
      // One 10 kW resistive heater at cosφ 1.0 -> kvar 0, PF 1.0 >= 0.95.
      const project = ElectricalProject(
        id: 'P3',
        name: 'PF good',
        panels: [
          ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            ambientTempC: 30,
            circuits: [
              ElectricalCircuit(
                id: 'h1',
                name: 'Heater',
                loadKind: LoadKind.heating,
                loadW: 10000,
                cosPhi: 1.0,
                length: Length(10),
              ),
            ],
          ),
        ],
      );
      final sys = computeSystem(profile, project);
      final r = powerFactorCorrection(sys, project);
      // A unity-PF load reports 0.999 — PF is clamped to <1 to keep tanφ finite
      // (mirrors PanelMaker). The point is it is at/above the 0.95 target, so no
      // bank is sized.
      expect(r.existingPf, closeTo(0.999, 1e-3));
      expect(r.existingPf, greaterThanOrEqualTo(0.95));
      expect(r.needed, isFalse);
      expect(r.requiredKvar, 0);
      expect(r.bankKvar, 0);
      expect(r.steps, 0);
      expect(r.detuned, isFalse);
    });
  });
}
