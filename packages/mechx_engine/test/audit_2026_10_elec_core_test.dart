import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/load_list.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sizing.dart';
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

  group('elec-core-3 — parallel runs are derated as a group', () {
    // 560 kW general load, 3φ 400 V, cosφ 0.85, PVC in conduit (B1), 30 °C,
    // panel grouping 1 ⇒ df = 1.0:
    //   Ib = 560 000 / (√3·400·0.85) = 560 000 / 588.897 = 950.93 A
    //   In = first rung ≥ 950.93 = 1000 A
    //   Iz required = max(1000, 1.25 · 950.93 = 1188.66) = 1188.66 A
    // Parallel runs of ONE circuit in common containment are a group
    // (IEC 60364-5-52 §523.5): n runs derate by groupingFactor(n).
    //   n=1: largest KHA 500 (300 mm²) < 1188.66                         ✗
    //   n=2: 0.8  ⇒ per run ≥ 1188.66/2/0.8  = 742.9 A > 500             ✗
    //   n=3: 0.7  ⇒ per run ≥ 1188.66/3/0.7  = 566.0 A > 500             ✗
    //        (the defect rated 3×240 at 3·435·1.0 = 1305 A — really
    //         3·435·0.7 = 913.5 A, below even In = 1000 A)
    //   n=4: 0.65 ⇒ per run ≥ 1188.66/4/0.65 = 457.2 A ⇒ 300 mm² (KHA 500)
    //        Iz = 4 · 500 · 0.65 = 1300 A ≥ 1188.66 ✓
    test('560 kW: 4×300 mm² at 0.65 (Iz 1300 A), never 3×240 at 1.0', () {
      final cable = sizeCable(
        profile,
        designCurrent: const Current(950.93),
        breakerRating: const Current(1000),
        deratingFactor: 1.0,
        minSectionMm2: 4,
        threePhase: true,
      );
      expect(cable.runsPerPhase, 4);
      expect(cable.csaMm2, 300);
      expect(cable.deratingFactor, 0.65);
      expect(cable.deratedIz.amperes, closeTo(1300, 0.05));
      expect(cable.deratedIz.amperes, greaterThanOrEqualTo(1188.66));
      expect(cable.ampacityReached, isTrue);
    });

    test('a grouped circuit swaps its g-factor for the g·n one', () {
      // g = 2 ⇒ df = groupingFactor(2) = 0.8 already applied. Ib 400 A,
      // In 400 A ⇒ Iz ≥ max(400, 500) = 500 A.
      //   n=1: per run ≥ 500/0.8 = 625 A > 500 ✗
      //   n=2: df_run = 0.8 · gf(4)/gf(2) = 0.8 · 0.65/0.8 = 0.65
      //        per run ≥ 500/2/0.65 = 384.6 A: 185 mm² (KHA 370) ✗,
      //        240 mm² (KHA 435) ✓ ⇒ Iz = 2 · 435 · 0.65 = 565.5 A
      //        (ungrouped-parallel would have taken 2×185 at 0.8 = 592 A).
      final cable = sizeCable(
        profile,
        designCurrent: const Current(400),
        breakerRating: const Current(400),
        deratingFactor: 0.8,
        minSectionMm2: 4,
        threePhase: true,
        groupingCount: 2,
      );
      expect(cable.runsPerPhase, 2);
      expect(cable.csaMm2, 240);
      expect(cable.deratingFactor, 0.65);
      expect(cable.deratedIz.amperes, closeTo(565.5, 0.05));
    });

    test('a single run is unchanged (byte-identical)', () {
      // Ib 100 A, In 100 A ⇒ Iz ≥ 125 A ⇒ 35 mm² (KHA 130), df 1.0.
      final cable = sizeCable(
        profile,
        designCurrent: const Current(100),
        breakerRating: const Current(100),
        deratingFactor: 1.0,
        minSectionMm2: 4,
        threePhase: true,
        groupingCount: 3,
      );
      expect(cable.runsPerPhase, isNull);
      expect(cable.csaMm2, 35);
      expect(cable.deratedIz.amperes, 130);
    });

    test('computePanel threads it: the 560 kW way gets 4×300 mm²', () {
      final r = computePanel(
        profile,
        const ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          ambientTempC: 30,
          circuits: [
            ElectricalCircuit(
              id: 'big',
              name: 'Big load',
              loadKind: LoadKind.general,
              loadW: 560000,
              cosPhi: 0.85,
              phases: 3,
              length: Length(5),
            ),
          ],
        ),
      );
      final c = r.circuits.single;
      expect(c.designCurrent.amperes, closeTo(950.9, 0.05));
      expect(c.breaker.ratingA.amperes, 1000);
      expect(c.cable.runsPerPhase, 4);
      expect(c.cable.csaMm2, 300);
      expect(c.cable.deratedIz.amperes, greaterThanOrEqualTo(1188.6));
    });
  });

  group('elec-core-5/6 — one ampacity basis across insulations + methods', () {
    test('XLPE (90 °C) is never below PVC (70 °C), every method + section', () {
      // On ONE installation basis a 90 °C conductor always carries at least
      // what a 70 °C one does (higher permitted conductor temperature, same
      // heat path).
      for (final m in CableInstallMethod.values) {
        for (final s in profile.standardSectionsMm2) {
          final pvc = profile.ampacity(s, method: m).amperes;
          final xlpe = profile
              .ampacity(s, insulation: ConductorInsulation.xlpe, method: m)
              .amperes;
          expect(xlpe, greaterThanOrEqualTo(pvc), reason: '$m $s mm2');
        }
      }
    });

    test('buried: IEC B.52.4/B.52.5 D1, 3-loaded, both insulations', () {
      // 16 mm²: PVC 64 A, XLPE 75 A; 300 mm²: PVC 316 A, XLPE 365 A.
      // (The defect read PVC 89 / 465 A — a direct-in-ground catalogue basis
      // — above XLPE.)
      const m = CableInstallMethod.buried;
      expect(profile.ampacity(16, method: m).amperes, 64);
      expect(profile.ampacity(300, method: m).amperes, 316);
      expect(
          profile
              .ampacity(300, insulation: ConductorInsulation.xlpe, method: m)
              .amperes,
          365);
    });

    test('a buried FRC (XLPE) run never takes MORE copper than NYY (PVC)', () {
      // Ib 186.8 A, In 200 A ⇒ Iz ≥ max(200, 1.25·186.8 = 233.5) = 233.5 A,
      // buried, df 1.0:
      //   PVC D1: 95 → 169 ✗, 120 → 192 ✗, 150 → 217 ✗, 185 → 243 ✓ ⇒ 185 mm²
      //   XLPE D1: 95 → 197 ✗, 120 → 223 ✗, 150 → 251 ✓ ⇒ 150 mm²
      // (The defect: NYY 95 mm² at 245 A vs FRC 150 mm² — the 90 °C cable two
      // sizes LARGER.)
      CableResultLike size(ConductorInsulation ins) {
        final c = sizeCable(
          profile,
          designCurrent: const Current(186.8),
          breakerRating: const Current(200),
          deratingFactor: 1.0,
          minSectionMm2: 4,
          insulation: ins,
          method: CableInstallMethod.buried,
          threePhase: true,
        );
        return (csa: c.csaMm2, iz: c.deratedIz.amperes);
      }

      final pvc = size(ConductorInsulation.pvc);
      final xlpe = size(ConductorInsulation.xlpe);
      expect(pvc.csa, 185);
      expect(pvc.iz, 243);
      expect(xlpe.csa, 150);
      expect(xlpe.iz, 251);
      expect(xlpe.csa, lessThanOrEqualTo(pvc.csa));
    });

    test('XLPE C/E are the 3-loaded columns (3φ is not overrated)', () {
      // IEC 60364-5-52: B.52.5 column C 3-loaded 300 mm² = 576 A (2-loaded
      // 693); B.52.12 method E 3-loaded 16 mm² = 100 A, 300 mm² = 621 A
      // (2-loaded 115 / 741).
      const x = ConductorInsulation.xlpe;
      expect(profile.ampacity(300, insulation: x, method: CableInstallMethod.wall)
          .amperes, 576);
      expect(profile.ampacity(16, insulation: x, method: CableInstallMethod.tray)
          .amperes, 100);
      expect(profile.ampacity(300, insulation: x, method: CableInstallMethod.tray)
          .amperes, 621);
      // Like with like: every XLPE column now sits on the 3-loaded basis, so
      // the open-air methods rank E ≥ C ≥ B1 at every section (free air
      // dissipates best, a conduit worst).
      for (final s in profile.standardSectionsMm2) {
        final b1 = profile.ampacity(s, insulation: x).amperes;
        final c = profile
            .ampacity(s, insulation: x, method: CableInstallMethod.wall)
            .amperes;
        final e = profile
            .ampacity(s, insulation: x, method: CableInstallMethod.tray)
            .amperes;
        expect(c, greaterThanOrEqualTo(b1), reason: 'C vs B1 at $s');
        expect(e, greaterThanOrEqualTo(c), reason: 'E vs C at $s');
      }
    });
  });
}

typedef CableResultLike = ({double csa, double iz});
