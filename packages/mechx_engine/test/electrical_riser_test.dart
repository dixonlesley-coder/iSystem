import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/geo_length.dart' show LayoutPos;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  const profile = PuilProfile();

  // A 3-floor building (each 4 m floor-to-floor).
  const building = BuildingLevels([
    Floor('Ground', Length(4)),
    Floor('First', Length(4)),
    Floor('Second', Length(4)),
  ]);

  // LVMDP (floor 0) feeds LP-G (floor 0) + LP-1 (floor 1) + an EMERGENCY board
  // (floor 2) carrying a life-safety way; plus one UNPLACED sub-board.
  const project = ElectricalProject(
    id: 'r1',
    name: 'Riser tower',
    panels: [
      ElectricalPanel(
        id: 'LVMDP',
        name: 'LVMDP',
        layoutPos: LayoutPos(sheetId: 's', floorIndex: 0, x: 100, y: 100),
        circuits: [
          ElectricalCircuit(
              id: 'fg', name: 'Feeder LP-G', loadKind: LoadKind.feeder,
              feedsPanelId: 'LPG', length: Length(10)),
          ElectricalCircuit(
              id: 'f1', name: 'Feeder LP-1', loadKind: LoadKind.feeder,
              feedsPanelId: 'LP1', length: Length(20)),
          ElectricalCircuit(
              id: 'fe', name: 'Feeder EMG', loadKind: LoadKind.feeder,
              feedsPanelId: 'EMG', length: Length(25)),
          ElectricalCircuit(
              id: 'fu', name: 'Feeder UP', loadKind: LoadKind.feeder,
              feedsPanelId: 'UP', length: Length(30)),
        ],
      ),
      ElectricalPanel(
        id: 'LPG', name: 'LP-G', sourceType: PanelSource.feeder,
        layoutPos: LayoutPos(sheetId: 's', floorIndex: 0, x: 300, y: 100),
        circuits: [
          ElectricalCircuit(
              id: 'g1', name: 'Lighting', loadKind: LoadKind.lighting,
              isLighting: true, loadW: 1200, length: Length(12)),
        ],
      ),
      ElectricalPanel(
        id: 'LP1', name: 'LP-1', sourceType: PanelSource.feeder,
        layoutPos: LayoutPos(sheetId: 's', floorIndex: 1, x: 300, y: 100),
        circuits: [
          ElectricalCircuit(
              id: 'l1', name: 'Lighting', loadKind: LoadKind.lighting,
              isLighting: true, loadW: 1500, length: Length(15)),
        ],
      ),
      ElectricalPanel(
        id: 'EMG', name: 'MDP EMERGENCY', sourceType: PanelSource.feeder,
        layoutPos: LayoutPos(sheetId: 's', floorIndex: 2, x: 300, y: 100),
        circuits: [
          ElectricalCircuit(
              id: 'e1', name: 'Smoke fan', loadKind: LoadKind.motor,
              motorKw: 5.5, lifeSafety: true, length: Length(18)),
        ],
      ),
      // No layoutPos ⇒ falls to a feeder-depth tier.
      ElectricalPanel(
        id: 'UP', name: 'PP UNPLACED', sourceType: PanelSource.feeder,
        circuits: [
          ElectricalCircuit(
              id: 'u1', name: 'Sockets', loadKind: LoadKind.general,
              loadW: 2000, length: Length(20)),
        ],
      ),
    ],
  );

  final result = computeSystem(profile, project);

  test('emits one rect per panel + finite bounds', () {
    final sheet = buildElectricalRiser(
        project: project, result: result, building: building);
    expect(sheet.isEmpty, isFalse);
    expect(sheet.prims.whereType<SldRect>().length, project.panels.length);
    expect(sheet.minX.isFinite && sheet.maxX.isFinite, isTrue);
    expect(sheet.maxX, greaterThan(sheet.minX));
    expect(sheet.maxY, greaterThan(sheet.minY));
  });

  test('panels stack by true elevation: higher floor => smaller y', () {
    final sheet = buildElectricalRiser(
        project: project, result: result, building: building);
    double yOf(String name) => sheet.prims
        .whereType<SldLabel>()
        .firstWhere((l) => l.bold && l.text.contains(name))
        .y;
    // floor 0 < floor 1 < floor 2 in elevation ⇒ y descends.
    expect(yOf('LP-G'), greaterThan(yOf('LP-1')));
    expect(yOf('LP-1'), greaterThan(yOf('MDP EMERGENCY')));
  });

  test('the unplaced panel still renders (falls to a tier, no throw)', () {
    final sheet = buildElectricalRiser(
        project: project, result: result, building: building);
    final joined =
        sheet.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
    expect(joined, contains('PP UNPLACED'));
  });

  test('the gutter carries the floor names + FFL elevations', () {
    final sheet = buildElectricalRiser(
        project: project, result: result, building: building);
    final joined =
        sheet.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
    expect(joined, contains('Ground'));
    expect(joined, contains('First'));
    expect(joined, contains('Second'));
    // FFL tags: floor 1 surface = +4.00, floor 2 = +8.00.
    expect(joined, contains('FFL +0.00'));
    expect(joined, contains('FFL +4.00'));
    expect(joined, contains('FFL +8.00'));
  });

  test('essential propagation matches the overview', () {
    final riser = buildElectricalRiser(
        project: project, result: result, building: building);
    final overview = buildElectricalOverview(project: project, result: result);
    SldRole roleIn(SldSheet s, String name) => s.prims
        .whereType<SldLabel>()
        .firstWhere((l) => l.bold && l.text.contains(name))
        .role;
    for (final name in ['LVMDP', 'LP-G', 'MDP EMERGENCY', 'PP UNPLACED']) {
      expect(roleIn(riser, name), roleIn(overview, name),
          reason: 'role mismatch for $name');
    }
    // The emergency board is essential (red).
    expect(roleIn(riser, 'MDP EMERGENCY'), SldRole.essential);
  });

  test('building: null degrades to feeder-depth tiers (no throw, still rects)',
      () {
    final sheet = buildElectricalRiser(project: project, result: result);
    expect(sheet.prims.whereType<SldRect>().length, project.panels.length);
    final joined =
        sheet.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
    // Tier gutter, no FFL elevation labels.
    expect(joined, contains('Tier '));
    expect(joined.contains('FFL '), isFalse);
  });

  test('an empty building level list also degrades gracefully', () {
    const empty = BuildingLevels([]);
    final sheet = buildElectricalRiser(
        project: project, result: result, building: empty);
    expect(sheet.prims.whereType<SldRect>().length, project.panels.length);
  });

  test('an out-of-range floorIndex is clamped (no index throw)', () {
    const oob = ElectricalProject(
      id: 'oob',
      name: 'OOB',
      panels: [
        ElectricalPanel(
          id: 'P',
          name: 'P',
          // floorIndex 9 on a 3-floor building ⇒ clamp to the top floor.
          layoutPos: LayoutPos(sheetId: 's', floorIndex: 9, x: 0, y: 0),
          circuits: [
            ElectricalCircuit(
                id: 'c', name: 'L', loadKind: LoadKind.general, loadW: 500,
                length: Length(5)),
          ],
        ),
      ],
    );
    final r = computeSystem(profile, oob);
    final sheet =
        buildElectricalRiser(project: oob, result: r, building: building);
    expect(sheet.prims.whereType<SldRect>().length, 1);
  });

  test('sourceChain=true prepends a source spine above the top band', () {
    final sheet = buildElectricalRiser(
        project: project,
        result: result,
        building: building,
        sourceChain: true);
    final sourceRects =
        sheet.prims.whereType<SldRect>().where((r) => r.role == SldRole.source);
    expect(sourceRects.length, greaterThanOrEqualTo(3));
    final joined =
        sheet.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
    expect(joined, contains('PLN MV STATION'));
    expect(sheet.legend.map((e) => e.code), contains('Source'));
  });

  test('an empty project yields an empty riser (no panel rects)', () {
    const e = ElectricalProject(id: 'e', name: 'Empty');
    final er = computeSystem(profile, e);
    final sheet =
        buildElectricalRiser(project: e, result: er, building: building);
    expect(sheet.prims.whereType<SldRect>(), isEmpty);
  });
}
