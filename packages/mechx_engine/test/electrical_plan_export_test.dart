import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/report/electrical_plan_export.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// H1 — the plan-accurate electrical LAYOUT export. The pure
/// [buildElectricalPlanData] builder is exercised against a small placed
/// project; the PDF/DXF renderers are smoke-checked for a well-formed file. The
/// key contract is HONESTY: only items placed on the exported sheet+floor are
/// drawn, and everything else is LISTED (never given a fabricated position).
void main() {
  const building = BuildingLevels([
    Floor('Ground', Length(4.0)),
    Floor('Level 1', Length(3.5)),
  ]);
  // 1 px = 2 cm on both sheets.
  const calib = {
    's0': ScaleCalibration(0.02),
    's1': ScaleCalibration(0.02),
  };

  // MDP (ground) feeds a sub-panel LP-1 on the SAME floor and a general load
  // placed on the ground plan; a second sub-panel LP-2 sits on floor 1 (its
  // feeder is off-sheet for the ground export).
  ElectricalProject project() => const ElectricalProject(
        id: 'p',
        name: 'Contoh',
        panels: [
          ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            tag: 'MDP',
            layoutPos: LayoutPos(sheetId: 's0', floorIndex: 0, x: 100, y: 100),
            circuits: [
              ElectricalCircuit(
                  id: 'f-lp1',
                  name: 'Feeder LP-1',
                  loadKind: LoadKind.feeder,
                  feedsPanelId: 'LP1'),
              ElectricalCircuit(
                  id: 'f-lp2',
                  name: 'Feeder LP-2',
                  loadKind: LoadKind.feeder,
                  feedsPanelId: 'LP2'),
              ElectricalCircuit(
                  id: 'gen',
                  name: 'General power',
                  loadKind: LoadKind.general,
                  loadW: 3000,
                  loadPos:
                      LayoutPos(sheetId: 's0', floorIndex: 0, x: 400, y: 100)),
              ElectricalCircuit(
                  id: 'unpl',
                  name: 'Unplaced socket',
                  loadKind: LoadKind.socket,
                  loadW: 1000),
            ],
          ),
          ElectricalPanel(
            id: 'LP1',
            name: 'LP-1',
            tag: 'LP-1',
            sourceType: PanelSource.feeder,
            fedByCircuitId: 'f-lp1',
            layoutPos: LayoutPos(sheetId: 's0', floorIndex: 0, x: 100, y: 400),
            circuits: [
              ElectricalCircuit(
                  id: 'lt1',
                  name: 'Lighting',
                  loadKind: LoadKind.lighting,
                  isLighting: true,
                  loadW: 800),
            ],
          ),
          ElectricalPanel(
            id: 'LP2',
            name: 'LP-2',
            tag: 'LP-2',
            sourceType: PanelSource.feeder,
            fedByCircuitId: 'f-lp2',
            layoutPos: LayoutPos(sheetId: 's1', floorIndex: 1, x: 100, y: 100),
            circuits: [],
          ),
        ],
      );

  group('buildElectricalPlanData', () {
    test('draws the panels + placed load on the exported sheet+floor', () {
      final data = buildElectricalPlanData(
        project: project(),
        sheetId: 's0',
        floorIndex: 0,
        calibrations: calib,
        building: building,
      );
      final tags = data.nodes.map((n) => n.tag).toSet();
      // MDP + LP-1 panels and the placed general load are drawn.
      expect(tags, containsAll(<String>{'MDP', 'LP-1', 'General power'}));
      // LP-2 (floor 1) is NOT on this plan.
      expect(tags, isNot(contains('LP-2')));

      final panels = data.nodes
          .where((n) => n.kind == ElectricalPlanNodeKind.panel)
          .map((n) => n.tag)
          .toSet();
      expect(panels, {'MDP', 'LP-1'});
      final loads = data.nodes
          .where((n) => n.kind == ElectricalPlanNodeKind.load)
          .map((n) => n.tag)
          .toSet();
      expect(loads, {'General power'});
    });

    test('routes both on-sheet feeder + on-sheet load drop, with a length', () {
      final data = buildElectricalPlanData(
        project: project(),
        sheetId: 's0',
        floorIndex: 0,
        calibrations: calib,
        building: building,
      );
      // MDP->LP-1 feeder (same floor) + MDP->general-load drop = 2 routes.
      // The MDP->LP-2 feeder is off-sheet ⇒ NOT drawn.
      expect(data.routes.length, 2);
      // MDP(100,100)->load(400,100) = 300 px × 0.02 = 6 m.
      final drop = data.routes.firstWhere((r) => r.x2 == 400 && r.y2 == 100);
      expect(drop.label, '6 m');
    });

    test('lists unplaced items in the corner note, never a fake position', () {
      final data = buildElectricalPlanData(
        project: project(),
        sheetId: 's0',
        floorIndex: 0,
        calibrations: calib,
        building: building,
      );
      // The unplaced loads (no loadPos: MDP's socket + LP-1's lighting) are
      // COUNTED, not given a fabricated position.
      expect(data.unplaced.any((u) => u.contains('2 beban belum ditempatkan')),
          isTrue);
      // A node was never invented for the unplaced socket.
      expect(data.nodes.any((n) => n.tag == 'Unplaced socket'), isFalse);
    });

    test('a panel with NO placement is listed, not drawn', () {
      const noPos = ElectricalProject(id: 'p', name: 'x', panels: [
        ElectricalPanel(id: 'MDP', name: 'MDP', tag: 'MDP', circuits: []),
      ]);
      final data = buildElectricalPlanData(
        project: noPos,
        sheetId: 's0',
        floorIndex: 0,
        calibrations: calib,
        building: building,
      );
      expect(data.nodes, isEmpty);
      expect(data.unplaced.any((u) => u.contains('MDP')), isTrue);
    });

    test('panel/load rating sub-labels come from the solved result', () {
      const puil = PuilProfile();
      final result = computeSystem(puil, project());
      final data = buildElectricalPlanData(
        project: project(),
        result: result,
        sheetId: 's0',
        floorIndex: 0,
        calibrations: calib,
        building: building,
      );
      final mdp = data.nodes.firstWhere((n) => n.tag == 'MDP');
      // The incomer rating appears (e.g. "NN A 3ph") — a real solved figure.
      expect(mdp.sub, isNotNull);
      expect(mdp.sub, contains('A'));
    });
  });

  group('renderers', () {
    test('PDF is a well-formed single-page document', () {
      final data = buildElectricalPlanData(
        project: project(),
        sheetId: 's0',
        floorIndex: 0,
        calibrations: calib,
        building: building,
      );
      final bytes = electricalPlanToPdf(
        data: data,
        projectName: 'Contoh',
        sheetName: 'Ground',
        dateString: '2026-07-06',
        metersPerPixel: 0.02,
      );
      final head = String.fromCharCodes(bytes.take(8));
      expect(head, startsWith('%PDF-1.4'));
      final tail = String.fromCharCodes(bytes.skip(bytes.length - 6));
      expect(tail.trim(), endsWith('%%EOF'));
    });

    test('DXF carries the E-* class layers + the unplaced note', () {
      final data = buildElectricalPlanData(
        project: project(),
        sheetId: 's0',
        floorIndex: 0,
        calibrations: calib,
        building: building,
      );
      final dxf = electricalPlanToDxf(
        data: data,
        projectName: 'Contoh',
        sheetName: 'Ground',
      );
      expect(dxf, contains('E-FEEDER'));
      expect(dxf, contains('E-TEXT'));
      expect(dxf, contains('BELUM DITEMPATKAN'));
      expect(dxf, endsWith('EOF\n'));
    });
  });
}
