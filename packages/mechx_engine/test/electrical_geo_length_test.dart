import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// Geo-derived electrical cable length. Expected values are hand-computed from
/// the `ScaleCalibration` / `BuildingLevels` primitives (§10: planar = pixels ×
/// scale; vertical = a floor-elevation delta, never pixels), mirroring the
/// mechanical `edgeLength` contract in `network_test.dart`.
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

  group('LayoutPos value type', () {
    test('copyWith replaces only what is passed; round-trips', () {
      const p = LayoutPos(sheetId: 's1', floorIndex: 1, x: 10, y: 20);
      final moved = p.copyWith(x: 99);
      expect(moved.sheetId, 's1');
      expect(moved.floorIndex, 1);
      expect(moved.x, 99);
      expect(moved.y, 20);

      final json = p.toJson();
      expect(json, {'sheetId': 's1', 'floorIndex': 1, 'x': 10.0, 'y': 20.0});
      final back = LayoutPos.fromJson(json);
      expect(back, p);
      expect(back.hashCode, p.hashCode);
    });

    test('fromJson is tolerant of missing fields (degenerate but safe)', () {
      final back = LayoutPos.fromJson(const {});
      expect(back.sheetId, '');
      expect(back.floorIndex, 0);
      expect(back.x, 0);
      expect(back.y, 0);
    });
  });

  group('electricalCableLength — §10 sources of truth', () {
    test('same floor: planar = pixel distance × calibration', () {
      // (300,400) from (0,0) ⇒ 500 px; 500 × 0.01 = 5.0 m; no vertical leg.
      const from = LayoutPos(sheetId: 's1', floorIndex: 0, x: 0, y: 0);
      const to = LayoutPos(sheetId: 's1', floorIndex: 0, x: 300, y: 400);
      final len = electricalCableLength(from, to,
          calibrationBySheet: calib, building: building);
      expect(len.meters, closeTo(5.0, 1e-9));
    });

    test('cross floor: planar + true floor-elevation delta (not pixels)', () {
      // Planar: (300,0) from (0,0) ⇒ 300 px × 0.01 = 3.0 m.
      // Vertical: floor 0 → floor 2 surface delta = 7.5 − 0.0 = 7.5 m
      //   (riserLength(0,2) = heights of floors 0 and 1 = 4.0 + 3.5).
      // Total = 3.0 + 7.5 = 10.5 m.
      const from = LayoutPos(sheetId: 's1', floorIndex: 0, x: 0, y: 0);
      const to = LayoutPos(sheetId: 's1', floorIndex: 2, x: 300, y: 0);
      final len = electricalCableLength(from, to,
          calibrationBySheet: calib, building: building);
      // Sanity: the riser leg matches the building primitive directly.
      expect(building.riserLength(0, 2).meters, closeTo(7.5, 1e-9));
      expect(len.meters, closeTo(10.5, 1e-9));
    });

    test('vertical leg is symmetric (abs delta) — load below the panel', () {
      // floor 2 → floor 0: same 7.5 m vertical; planar 0 (coincident pixels).
      const from = LayoutPos(sheetId: 's1', floorIndex: 2, x: 50, y: 50);
      const to = LayoutPos(sheetId: 's1', floorIndex: 0, x: 50, y: 50);
      final len = electricalCableLength(from, to,
          calibrationBySheet: calib, building: building);
      expect(len.meters, closeTo(7.5, 1e-9));
    });

    test('uncalibrated from-sheet ⇒ Length(0) (mirrors edgeLength)', () {
      const from = LayoutPos(sheetId: 'nope', floorIndex: 0, x: 0, y: 0);
      const to = LayoutPos(sheetId: 'nope', floorIndex: 1, x: 300, y: 0);
      final len = electricalCableLength(from, to,
          calibrationBySheet: calib, building: building);
      expect(len.meters, 0);
    });
  });

  group('resolveCircuitLength — geo when placed, else manual', () {
    test('placed circuit ⇒ geo length wins over manual length', () {
      // Panel on floor 0 at (0,0); load on floor 0 at (300,400) ⇒ 5.0 m geo,
      // overriding the (deliberately different) manual length of 99 m.
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
      final len = resolveCircuitLength(c, panel,
          calibrationBySheet: calib, building: building);
      expect(len.meters, closeTo(5.0, 1e-9));
    });

    test('unplaced circuit (no loadPos) ⇒ manual length', () {
      const panel = ElectricalPanel(
        id: 'P1',
        name: 'P1',
        layoutPos: LayoutPos(sheetId: 's1', floorIndex: 0, x: 0, y: 0),
      );
      const c = ElectricalCircuit(id: 'c1', name: 'Load', length: Length(42));
      final len = resolveCircuitLength(c, panel,
          calibrationBySheet: calib, building: building);
      expect(len.meters, 42);
    });

    test('panel not placed ⇒ manual length even with a loadPos', () {
      const panel = ElectricalPanel(id: 'P1', name: 'P1');
      const c = ElectricalCircuit(
        id: 'c1',
        name: 'Load',
        length: Length(7),
        loadPos: LayoutPos(sheetId: 's1', floorIndex: 0, x: 300, y: 0),
      );
      final len = resolveCircuitLength(c, panel,
          calibrationBySheet: calib, building: building);
      expect(len.meters, 7);
    });

    test('uncalibrated sheet ⇒ falls back to manual length (never 0)', () {
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
      final len = resolveCircuitLength(c, panel,
          calibrationBySheet: calib, building: building);
      expect(len.meters, 13);
    });

    test('feeder ⇒ panel→sub-panel geo length via panelById', () {
      // MDP on floor 0 at (0,0); sub-panel SP on floor 1 at (300,0).
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
        length: Length(50), // manual fallback, deliberately different
      );
      const mdp = ElectricalPanel(
        id: 'MDP',
        name: 'MDP',
        layoutPos: LayoutPos(sheetId: 's1', floorIndex: 0, x: 0, y: 0),
        circuits: [feeder],
      );
      expect(building.riserLength(0, 1).meters, closeTo(4.0, 1e-9));
      final len = resolveCircuitLength(feeder, mdp,
          calibrationBySheet: calib,
          building: building,
          panelById: {'MDP': mdp, 'SP': sub});
      expect(len.meters, closeTo(7.0, 1e-9));
    });

    test('feeder with un-placed sub-panel ⇒ manual length', () {
      const sub = ElectricalPanel(id: 'SP', name: 'SP'); // no layoutPos
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
      final len = resolveCircuitLength(feeder, mdp,
          calibrationBySheet: calib,
          building: building,
          panelById: {'MDP': mdp, 'SP': sub});
      expect(len.meters, 50);
    });
  });

  group('model round-trip carries layoutPos / loadPos (tolerant)', () {
    test('circuit copyWith carries loadPos; clearLoadPos nulls it', () {
      const c = ElectricalCircuit(id: 'c1', name: 'L');
      expect(c.loadPos, isNull);
      const pos = LayoutPos(sheetId: 's1', floorIndex: 2, x: 5, y: 6);
      final placed = c.copyWith(loadPos: pos);
      expect(placed.loadPos, pos);
      // No-arg copy preserves it.
      expect(placed.copyWith().loadPos, pos);
      // Clear flag removes it.
      expect(placed.copyWith(clearLoadPos: true).loadPos, isNull);
    });

    test('panel copyWith carries layoutPos; clearLayoutPos nulls it; '
        'clearPosition leaves it (distinct space from x/y)', () {
      const p = ElectricalPanel(id: 'P1', name: 'P1', x: 1, y: 2);
      expect(p.layoutPos, isNull);
      const pos = LayoutPos(sheetId: 's1', floorIndex: 0, x: 7, y: 8);
      final placed = p.copyWith(layoutPos: pos);
      expect(placed.layoutPos, pos);
      // The schematic-canvas clear must NOT touch the geo placement.
      final clearedCanvas = placed.copyWith(clearPosition: true);
      expect(clearedCanvas.x, isNull);
      expect(clearedCanvas.y, isNull);
      expect(clearedCanvas.layoutPos, pos);
      // And clearing the geo placement leaves the schematic x/y.
      final clearedGeo = placed.copyWith(clearLayoutPos: true);
      expect(clearedGeo.layoutPos, isNull);
      expect(clearedGeo.x, 1);
      expect(clearedGeo.y, 2);
    });

    test('circuit toJson omits loadPos when null; round-trips when set', () {
      const bare = ElectricalCircuit(id: 'c1', name: 'L');
      expect(bare.toJson().containsKey('loadPos'), isFalse);

      const c = ElectricalCircuit(
        id: 'c1',
        name: 'L',
        loadPos: LayoutPos(sheetId: 's1', floorIndex: 1, x: 3, y: 4),
      );
      final back = ElectricalCircuit.fromJson(c.toJson());
      expect(back.loadPos,
          const LayoutPos(sheetId: 's1', floorIndex: 1, x: 3, y: 4));
    });

    test('panel toJson omits layoutPos when null; round-trips when set', () {
      const bare = ElectricalPanel(id: 'P1', name: 'P1');
      expect(bare.toJson().containsKey('layoutPos'), isFalse);

      const p = ElectricalPanel(
        id: 'P1',
        name: 'P1',
        layoutPos: LayoutPos(sheetId: 's1', floorIndex: 2, x: 9, y: 10),
        circuits: [
          ElectricalCircuit(
            id: 'c1',
            name: 'L',
            loadPos: LayoutPos(sheetId: 's1', floorIndex: 2, x: 11, y: 12),
          ),
        ],
      );
      final back = ElectricalPanel.fromJson(p.toJson());
      expect(back.layoutPos,
          const LayoutPos(sheetId: 's1', floorIndex: 2, x: 9, y: 10));
      expect(back.circuits.single.loadPos,
          const LayoutPos(sheetId: 's1', floorIndex: 2, x: 11, y: 12));
    });

    test('old file (no layoutPos/loadPos keys) ⇒ null, never throws', () {
      // Mimic a pre-geo `.mechx` panel: the keys are simply absent.
      final back = ElectricalPanel.fromJson({
        'id': 'P1',
        'name': 'P1',
        'circuits': [
          {'id': 'c1', 'name': 'L'},
        ],
      });
      expect(back.layoutPos, isNull);
      expect(back.circuits.single.loadPos, isNull);
    });
  });

  group('computeSystem geo threading (additive — default unchanged)', () {
    // One MDP, 3φ 400 V, single resistive way. Manual length 99 m; placing it
    // 5.0 m away by geometry must shorten the run the engine sizes against.
    ElectricalProject project({
      LayoutPos? panelPos,
      LayoutPos? loadPos,
    }) =>
        ElectricalProject(
          id: 'prj',
          panels: [
            ElectricalPanel(
              id: 'MDP',
              name: 'MDP',
              layoutPos: panelPos,
              circuits: [
                ElectricalCircuit(
                  id: 'c1',
                  name: 'Big load',
                  loadKind: LoadKind.general,
                  loadW: 8000,
                  cosPhi: 0.85,
                  length: const Length(99),
                  loadPos: loadPos,
                ),
              ],
            ),
          ],
        );

    const p = PuilProfile();

    test('omitting geo inputs ⇒ identical to the manual-length result', () {
      final manual = computeSystem(p, project());
      final withEmptyGeo = computeSystem(p, project(),
          calibrationBySheet: const {}, building: building);
      final a = manual.panels['MDP']!.circuits.single;
      final b = withEmptyGeo.panels['MDP']!.circuits.single;
      // No layoutPos anywhere ⇒ manual length both ways ⇒ same drop & section.
      expect(b.voltageDrop.dropPercent, a.voltageDrop.dropPercent);
      expect(b.cable.csaMm2, a.cable.csaMm2);
    });

    test('placed circuit ⇒ shorter geo run ⇒ smaller voltage drop than manual',
        () {
      // Manual 99 m vs geo 5.0 m for the same current ⇒ drop scales with length.
      final manual = computeSystem(p, project());
      final placed = computeSystem(
        p,
        project(
          panelPos: const LayoutPos(sheetId: 's1', floorIndex: 0, x: 0, y: 0),
          loadPos:
              const LayoutPos(sheetId: 's1', floorIndex: 0, x: 300, y: 400),
        ),
        calibrationBySheet: calib,
        building: building,
      );
      final mDrop = manual.panels['MDP']!.circuits.single.voltageDrop.dropPercent;
      final gDrop = placed.panels['MDP']!.circuits.single.voltageDrop.dropPercent;
      expect(gDrop, lessThan(mDrop));
      // 5 m vs 99 m: the geo drop should be far smaller (roughly 5/99) — assert
      // it is well under a tenth of the manual drop as an order-of-magnitude
      // guard (cable section may differ between the two, so not an exact ratio).
      expect(gDrop, lessThan(mDrop * 0.2));
    });
  });
}
