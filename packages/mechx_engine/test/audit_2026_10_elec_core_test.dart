import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/load_list.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
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

  group('elec-core-4 — motor demand counts the ELECTRICAL INPUT', () {
    // MDP (3φ 400 V) → feeder f1 → PP (3φ 400 V), PP carries one 22 kW pump.
    const project = ElectricalProject(
      id: 'p4',
      name: 'Motor demand',
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'Main',
          circuits: [
            ElectricalCircuit(
              id: 'f1',
              name: 'Feeder PP',
              loadKind: LoadKind.feeder,
              cosPhi: 0.85,
              length: Length(20),
              feedsPanelId: 'PP',
            ),
          ],
        ),
        ElectricalPanel(
          id: 'PP',
          name: 'Pump panel',
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'f1',
          circuits: [
            ElectricalCircuit(
              id: 'pump',
              name: 'Pump',
              loadKind: LoadKind.pump,
              motorKw: 22,
              cosPhi: 0.85,
              length: Length(15),
            ),
          ],
        ),
      ],
    );
    final sys = computeSystem(profile, project);

    test('child demand = 22 000 / 0.88 = 25 000 W (not the 22 000 W shaft)',
        () {
      // Shaft 22 kW / assumed motor efficiency 0.88 = 25 000 W input.
      expect(sys.panels['PP']!.demandW, 25000);
      expect(sys.supply.demandW, 25000);
    });

    test('motor Ib and the feeder Ib agree at 42.5 A', () {
      // Both convert 25 000 W at √3·400·0.85 = 588.897:
      //   25 000 / 588.897 = 42.45 A → 42.5 A
      // (the defect put the feeder on 22 000/588.897 = 37.36 → 37.4 A, 12 %
      // below the current its own fed motor way draws).
      final motor = sys.panels['PP']!.circuits.single;
      final feeder = sys.panels['MDP']!.circuits.single;
      expect(motor.designCurrent.amperes, 42.5);
      expect(feeder.designCurrent.amperes, 42.5);
    });

    test('an A5 way counts its loadW (electrical input), not motorKw', () {
      // 7.5 kW shaft, η 0.9 ⇒ A5 loadW = 7500/0.9 = 8333.33 W, flaOverrideA set.
      const e = MepEquipmentLoad(
        id: 'P',
        name: 'Booster',
        source: MepLoadSource.boosterPump,
        mechanicalPower: Power(7500),
        cosPhi: 0.85,
        motorEfficiency: 0.9,
      );
      final c = equipmentToCircuit(e, panelVoltage: const Voltage(400));
      expect(c.flaOverrideA, isNotNull);
      expect(circuitConnectedW(c), closeTo(8333.33, 0.01));
    });
  });

  group('elec-core-2 — Zs/ADS + fault decay use the SOLVED (geo) run', () {
    const building = BuildingLevels([Floor('Ground', Length(4.0))]);
    // 1 px = 1 cm on sheet s1.
    const calib = {'s1': ScaleCalibration(0.01)};
    const origin = LayoutPos(sheetId: 's1', floorIndex: 0, x: 0, y: 0);
    // 5000 px × 0.01 = 50 m planar from the board.
    const far = LayoutPos(sheetId: 's1', floorIndex: 0, x: 5000, y: 0);

    // A 5.5 kW 3φ motor: Ib = 5500/0.88/(√3·400·0.85) = 6250/588.897
    // = 10.61 A → 16 A curve D; the 2.5 mm² final minimum carries it.
    ElectricalProject motorProject(
            {required double manualM, LayoutPos? loadPos}) =>
        ElectricalProject(
          id: 'ads',
          name: 'ADS',
          panels: [
            ElectricalPanel(
              id: 'MDP',
              name: 'Main',
              layoutPos: loadPos == null ? null : origin,
              circuits: [
                ElectricalCircuit(
                  id: 'm',
                  name: 'Motor',
                  loadKind: LoadKind.motor,
                  motorKw: 5.5,
                  cosPhi: 0.85,
                  length: Length(manualM),
                  loadPos: loadPos,
                ),
              ],
            ),
          ],
        );

    test('a placed 50 m motor run (manual left at 10 m) FAILS ADS', () {
      final project = motorProject(manualM: 10, loadPos: far);
      final sys = computeSystem(profile, project,
          calibrationBySheet: calib, building: building);
      final cr = sys.panels['MDP']!.circuits.single;
      // Sizing already used the geo run.
      final runM = cr.lengthM;
      expect(runM, greaterThanOrEqualTo(50));
      expect(cr.breaker.ratingA.amperes, 16);
      expect(cr.cable.csaMm2, 2.5);

      final f = faultStudy(sys, project, profile).circuits['m']!;
      // Zs,max = 0.95 · U0 / (20 · In)  (curve D trips at 20 × In)
      //        = 0.95 · 230 / (20 · 16) = 218.5 / 320 = 0.683 Ω.
      expect(f.zsMaxOhm, closeTo(0.683, 0.001));
      // The conductor loop ALONE on 50 m: phase + PE, both 2.5 mm²
      // (8.87 Ω/km), at the 1.28 fault-temperature factor:
      //   R = 2 · 8.87 · 0.050 · 1.28 = 1.135 Ω  > 0.683 Ω ⇒ must fail.
      // (The defect computed it on 10 m: 2·8.87·0.010·1.28 = 0.227 Ω ⇒ pass.)
      expect(f.zsOhm!, greaterThan(1.135));
      expect(f.adsOk, isFalse);

      // And it is EXACTLY the verdict of the same run typed as manual.
      final manualProject = motorProject(manualM: runM);
      final manualSys = computeSystem(profile, manualProject);
      final fm = faultStudy(manualSys, manualProject, profile).circuits['m']!;
      expect(f.zsOhm, fm.zsOhm);
      expect(fm.adsOk, isFalse);
    });

    // Feeder decay: MDP → 50 mm-class feeder → SUB, SUB placed 80 m away
    // while the feeder's manual length stays 10 m.
    ElectricalProject feederProject({
      required double manualM,
      bool placed = false,
      ConductorMaterial subMaterial = ConductorMaterial.copper,
    }) =>
        ElectricalProject(
          id: 'fd',
          name: 'Feeder decay',
          panels: [
            ElectricalPanel(
              id: 'MDP',
              name: 'Main',
              layoutPos: placed ? origin : null,
              circuits: [
                ElectricalCircuit(
                  id: 'f',
                  name: 'Feeder SUB',
                  loadKind: LoadKind.feeder,
                  cosPhi: 0.85,
                  length: Length(manualM),
                  feedsPanelId: 'SUB',
                ),
              ],
            ),
            ElectricalPanel(
              id: 'SUB',
              name: 'Sub',
              material: subMaterial,
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'f',
              layoutPos: placed
                  ? const LayoutPos(
                      sheetId: 's1', floorIndex: 0, x: 8000, y: 0)
                  : null,
              circuits: const [
                ElectricalCircuit(
                  id: 'h',
                  name: 'Heater',
                  loadKind: LoadKind.heating,
                  loadW: 20000,
                  cosPhi: 1.0,
                  phases: 3,
                  length: Length(10),
                ),
              ],
            ),
          ],
        );

    test('the sub-board fault decays over the SOLVED feeder run', () {
      final placed = feederProject(manualM: 10, placed: true);
      final sys = computeSystem(profile, placed,
          calibrationBySheet: calib, building: building);
      final runM = sys.panels['MDP']!.circuits.single.lengthM;
      expect(runM, greaterThanOrEqualTo(80));
      final fsPlaced = faultStudy(sys, placed, profile);

      final manual = feederProject(manualM: runM);
      final manualSys = computeSystem(profile, manual);
      final fsManual = faultStudy(manualSys, manual, profile);
      // Same feeder run ⇒ same downstream prospective fault (the defect decayed
      // it over 10 m and overstated the SUB fault level).
      expect(fsPlaced.panels['SUB']!.prospectiveFaultkA,
          fsManual.panels['SUB']!.prospectiveFaultkA);
      final stale = feederProject(manualM: 10);
      final fsStale =
          faultStudy(computeSystem(profile, stale), stale, profile);
      expect(fsPlaced.panels['SUB']!.prospectiveFaultkA,
          lessThan(fsStale.panels['SUB']!.prospectiveFaultkA));
    });

    test('the feeder impedance uses the PARENT material that sized it', () {
      // The MDP (copper) sizes the feeder; an aluminium SUB must not re-rate
      // that copper feeder as aluminium (×1.61 resistance). The SUB fault level
      // therefore equals the all-copper case.
      final cu = feederProject(manualM: 40);
      final al = feederProject(
          manualM: 40, subMaterial: ConductorMaterial.aluminum);
      final cuSys = computeSystem(profile, cu);
      final alSys = computeSystem(profile, al);
      // Same feeder cable (sized by the copper parent) in both.
      expect(alSys.panels['MDP']!.circuits.single.cable.csaMm2,
          cuSys.panels['MDP']!.circuits.single.cable.csaMm2);
      expect(faultStudy(alSys, al, profile).panels['SUB']!.prospectiveFaultkA,
          faultStudy(cuSys, cu, profile).panels['SUB']!.prospectiveFaultkA);
    });
  });
}
