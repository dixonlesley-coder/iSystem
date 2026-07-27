import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/load_list.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// `resolveCircuitLengthDetailed` (length-source honesty) + the
/// `MepEquipmentLoad.loadPos` passthrough (A5's MEP-equipment→circuit geo
/// position carrier). Same hand-computed `LayoutPos`/`BuildingLevels` fixture
/// as `electrical_geo_length_test.dart` so the geo numbers are already proven
/// there — this file's job is only the `source` discriminant + the new
/// `loadPos` plumbing.
void main() {
  // Three floors: 4.0 + 3.5 + 3.5 m. Floor-surface elevations (elevationOf):
  //   floor 0 = 0.0; floor 1 = 4.0; floor 2 = 7.5 m.
  const building = BuildingLevels([
    Floor('Ground', Length(4.0)),
    Floor('Level 1', Length(3.5)),
    Floor('Level 2', Length(3.5)),
  ]);
  // 1 px = 1 cm on sheet s1.
  const calib = {'s1': ScaleCalibration(0.01)};

  group('resolveCircuitLengthDetailed — source discriminant', () {
    test('placed + calibrated ⇒ source geo, same length as resolveCircuitLength',
        () {
      // Panel on floor 0 at (0,0); load on floor 0 at (300,400) ⇒ 500 px ×
      // 0.01 = 5.0 m geo, overriding the manual 99 m fallback.
      const panel = ElectricalPanel(
        id: 'P1',
        name: 'P1',
        layoutPos: LayoutPos(sheetId: 's1', floorIndex: 0, x: 0, y: 0),
      );
      const c = ElectricalCircuit(
        id: 'c1',
        name: 'Load',
        length: Length(99),
        loadPos: LayoutPos(sheetId: 's1', floorIndex: 0, x: 300, y: 400),
      );

      final detailed = resolveCircuitLengthDetailed(c, panel,
          calibrationBySheet: calib, building: building);
      final plain = resolveCircuitLength(c, panel,
          calibrationBySheet: calib, building: building);

      expect(detailed.source, CircuitLengthSource.geo);
      expect(detailed.length.meters, closeTo(5.0, 1e-9));
      expect(detailed.length.meters, closeTo(plain.meters, 1e-9));
    });

    test('(a) unplaced circuit (panel not placed) ⇒ source manual', () {
      const panel = ElectricalPanel(id: 'P1', name: 'P1'); // no layoutPos
      const c = ElectricalCircuit(
        id: 'c1',
        name: 'Load',
        length: Length(7),
        loadPos: LayoutPos(sheetId: 's1', floorIndex: 0, x: 300, y: 0),
      );
      final detailed = resolveCircuitLengthDetailed(c, panel,
          calibrationBySheet: calib, building: building);
      expect(detailed.source, CircuitLengthSource.manual);
      expect(detailed.length.meters, 7);
      expect(
          detailed.length.meters,
          resolveCircuitLength(c, panel,
                  calibrationBySheet: calib, building: building)
              .meters);
    });

    test('(b) placed panel + unplaced load ⇒ source manual', () {
      const panel = ElectricalPanel(
        id: 'P1',
        name: 'P1',
        layoutPos: LayoutPos(sheetId: 's1', floorIndex: 0, x: 0, y: 0),
      );
      const c = ElectricalCircuit(id: 'c1', name: 'Load', length: Length(42));
      final detailed = resolveCircuitLengthDetailed(c, panel,
          calibrationBySheet: calib, building: building);
      expect(detailed.source, CircuitLengthSource.manual);
      expect(detailed.length.meters, 42);
      expect(
          detailed.length.meters,
          resolveCircuitLength(c, panel,
                  calibrationBySheet: calib, building: building)
              .meters);
    });

    test('(c) uncalibrated sheet ⇒ source manual (never a silent zero)', () {
      const panel = ElectricalPanel(
        id: 'P1',
        name: 'P1',
        layoutPos: LayoutPos(sheetId: 'nope', floorIndex: 0, x: 0, y: 0),
      );
      const c = ElectricalCircuit(
        id: 'c1',
        name: 'Load',
        length: Length(13),
        loadPos: LayoutPos(sheetId: 'nope', floorIndex: 1, x: 300, y: 0),
      );
      final detailed = resolveCircuitLengthDetailed(c, panel,
          calibrationBySheet: calib, building: building);
      expect(detailed.source, CircuitLengthSource.manual);
      expect(detailed.length.meters, 13);
      expect(
          detailed.length.meters,
          resolveCircuitLength(c, panel,
                  calibrationBySheet: calib, building: building)
              .meters);
    });

    test('feeder to a placed sub-panel ⇒ source geo', () {
      // MDP on floor 0 at (0,0); sub-panel SP on floor 1 at (300,0):
      //   planar 300 px × 0.01 = 3.0 m; vertical floor 0→1 = 4.0 m ⇒ 7.0 m.
      const sub = ElectricalPanel(
        id: 'SP',
        name: 'SP',
        layoutPos: LayoutPos(sheetId: 's1', floorIndex: 1, x: 300, y: 0),
      );
      const feeder = ElectricalCircuit(
        id: 'f1',
        name: 'Feeder to SP',
        loadKind: LoadKind.feeder,
        feedsPanelId: 'SP',
        length: Length(50),
      );
      const mdp = ElectricalPanel(
        id: 'MDP',
        name: 'MDP',
        layoutPos: LayoutPos(sheetId: 's1', floorIndex: 0, x: 0, y: 0),
        circuits: [feeder],
      );
      final detailed = resolveCircuitLengthDetailed(feeder, mdp,
          calibrationBySheet: calib,
          building: building,
          panelById: {'MDP': mdp, 'SP': sub});
      expect(detailed.source, CircuitLengthSource.geo);
      expect(detailed.length.meters, closeTo(7.0, 1e-9));
    });
  });

  group('MepEquipmentLoad.loadPos — passthrough to the produced circuit', () {
    test('set loadPos flows through equipmentToCircuit', () {
      const pos = LayoutPos(sheetId: 's1', floorIndex: 1, x: 12, y: 34);
      const e = MepEquipmentLoad(
        id: 'P-1',
        name: 'Booster pump',
        source: MepLoadSource.boosterPump,
        mechanicalPower: Power(7500),
        loadPos: pos,
      );
      final c = equipmentToCircuit(e, panelVoltage: const Voltage(400));
      expect(c.loadPos, pos);
    });

    test('null loadPos stays null (default byte-identical)', () {
      const e = MepEquipmentLoad(
        id: 'P-2',
        name: 'Sump pump',
        source: MepLoadSource.sumpPump,
        mechanicalPower: Power(1500),
      );
      expect(e.loadPos, isNull);
      final c = equipmentToCircuit(e, panelVoltage: const Voltage(400));
      expect(c.loadPos, isNull);
    });

    test('buildEquipmentCircuits carries loadPos per-load (mixed placed/unplaced)',
        () {
      const posA = LayoutPos(sheetId: 's1', floorIndex: 0, x: 1, y: 2);
      const loads = [
        MepEquipmentLoad(
          id: 'a',
          name: 'Pump A',
          source: MepLoadSource.supplyPump,
          mechanicalPower: Power(3000),
          loadPos: posA,
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
      expect(circuits[0].loadPos, posA);
      expect(circuits[1].loadPos, isNull);
    });

    test('fromPumpDuty passes loadPos through to the descriptor', () {
      final duty = sizePump(
        flow: FlowRate.litersPerSecond(5),
        head: const Head(30),
      );
      const pos = LayoutPos(sheetId: 's1', floorIndex: 2, x: 5, y: 6);
      final e = MepEquipmentLoad.fromPumpDuty(
        duty,
        id: 'P-9',
        name: 'Sized pump',
        loadPos: pos,
      );
      expect(e.loadPos, pos);
      final c = equipmentToCircuit(e, panelVoltage: const Voltage(400));
      expect(c.loadPos, pos);
    });

    test('fromPumpDuty omitting loadPos ⇒ null (default byte-identical)', () {
      final duty = sizePump(
        flow: FlowRate.litersPerSecond(5),
        head: const Head(30),
      );
      final e = MepEquipmentLoad.fromPumpDuty(
        duty,
        id: 'P-9',
        name: 'Sized pump',
      );
      expect(e.loadPos, isNull);
    });

    test('geo length resolves for an equipment-derived circuit once placed',
        () {
      // The produced circuit's loadPos + a placed panel resolve a real geo
      // length via resolveCircuitLengthDetailed, proving the carrier actually
      // closes the loop end-to-end (equipment → circuit → geo resolution).
      const panel = ElectricalPanel(
        id: 'MP',
        name: 'Mech panel',
        layoutPos: LayoutPos(sheetId: 's1', floorIndex: 0, x: 0, y: 0),
      );
      const e = MepEquipmentLoad(
        id: 'P-1',
        name: 'Booster pump',
        source: MepLoadSource.boosterPump,
        mechanicalPower: Power(7500),
        loadPos: LayoutPos(sheetId: 's1', floorIndex: 0, x: 300, y: 400),
      );
      final c = equipmentToCircuit(e,
          panelVoltage: const Voltage(400), lengthM: 999);
      final detailed = resolveCircuitLengthDetailed(c, panel,
          calibrationBySheet: calib, building: building);
      expect(detailed.source, CircuitLengthSource.geo);
      expect(detailed.length.meters, closeTo(5.0, 1e-9));
    });
  });
}
