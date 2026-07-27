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

  test('sourceChain=true prepends a source spine above the top band — the '
      'honest LV head here (nothing declares an MV service)', () {
    final sheet = buildElectricalRiser(
        project: project,
        result: result,
        building: building,
        sourceChain: true);
    final joined =
        sheet.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
    // An undeclared (LV) service draws the plain PLN head — never a
    // fabricated MV station / transformer chain.
    expect(joined, contains('PLN'));
    expect(joined, isNot(contains('MV STATION')));
    expect(joined, isNot(contains('TRANSFORMER')));
    expect(
        sheet.prims
            .whereType<SldCircle>()
            .where((c) => c.role == SldRole.source),
        isEmpty);
    expect(sheet.legend.map((e) => e.code), contains('Source'));
  });

  test('sourceChain=true with a DECLARED transformer draws the MV spine '
      'symbols above the top band', () {
    final mv = ElectricalProject(
      id: project.id,
      name: project.name,
      transformerKva: const ApparentPower(400000),
      panels: project.panels,
    );
    final mr = computeSystem(profile, mv);
    final sheet = buildElectricalRiser(
        project: mv, result: mr, building: building, sourceChain: true);
    // The spine draws single-line SYMBOLS: the two transformer winding
    // circles ⇒ at least 2 source circles (not boxes).
    final sourceCircles = sheet.prims
        .whereType<SldCircle>()
        .where((c) => c.role == SldRole.source);
    expect(sourceCircles.length, greaterThanOrEqualTo(2));
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

  test('feeder runs carry a cable + breaker annotation', () {
    final sheet = buildElectricalRiser(
        project: project, result: result, building: building);
    // LVMDP feeds LPG / LP1 / EMG / UP — four resolvable feeder labels.
    final feederLabels = sheet.prims
        .whereType<SldLabel>()
        .where((l) => l.text.contains(' mm2 ') && l.text.contains('·'))
        .toList();
    expect(feederLabels.length, project.panels.length - 1);
    for (final l in feederLabels) {
      expect(l.text, matches(RegExp(r'\dx\d')), reason: l.text); // cable cores
      expect(l.text, matches(RegExp(r'(MCB|MCCB) \d+(\.\d+)?A \dph')),
          reason: l.text);
    }
  });

  test('per-floor branch fan-out: a board shows a labelled load-way stub', () {
    final sheet = buildElectricalRiser(
        project: project, result: result, building: building);
    final joined =
        sheet.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
    // LP-G distributes a 'Lighting' way; it hangs as a stub with its rating.
    final stub = sheet.prims
        .whereType<SldLabel>()
        .where((l) =>
            l.size == 6 && l.text.startsWith('Lighting') && l.text.contains('A'))
        .toList();
    expect(stub, isNotEmpty);
    expect(joined, contains('Sockets')); // the unplaced board's load way
  });

  test('the compact node sub-line carries kW AND kVA demand', () {
    final sheet = buildElectricalRiser(
        project: project, result: result, building: building);
    final sub = sheet.prims.whereType<SldLabel>().where(
        (l) => !l.bold && l.text.contains('kW') && l.text.contains('kVA'));
    expect(sub, isNotEmpty);
    expect(sub.first.text, matches(RegExp(r'\d+A \dP · .*kW / .*kVA')));
  });

  test('no riser label contains a non-ASCII tofu glyph', () {
    final sheet = buildElectricalRiser(
        project: project, result: result, building: building);
    for (final l in sheet.prims.whereType<SldLabel>()) {
      expect(l.text.contains('Ø'), isFalse, reason: l.text);
      expect(l.text.contains('²'), isFalse, reason: l.text);
      expect(l.text.contains('³'), isFalse, reason: l.text);
    }
  });

  // H5: buildElectricalRiser's per-floor fan-out used to hard-`substring(0,
  // 14)` a circuit name with no ellipsis, producing a mid-word chop like
  // 'Power socke' / 'Lighting - Lev'. It should now cut on a word boundary and
  // append an ASCII ellipsis, and never silently drop the fact it was cut.
  test('a long circuit name in the fan-out is truncated at a word boundary '
      'with an ellipsis, never mid-word', () {
    const longName = 'Power socket ring - workshop';
    const longNameProject = ElectricalProject(
      id: 'ln',
      name: 'Long names',
      panels: [
        ElectricalPanel(
          id: 'P1',
          name: 'LP-1',
          layoutPos: LayoutPos(sheetId: 's', floorIndex: 0, x: 100, y: 100),
          circuits: [
            ElectricalCircuit(
                id: 'c1',
                name: longName,
                loadKind: LoadKind.general,
                loadW: 2000,
                length: Length(10)),
          ],
        ),
      ],
    );
    final r = computeSystem(profile, longNameProject);
    final sheet = buildElectricalRiser(
        project: longNameProject, result: r, building: building);
    final stub = sheet.prims
        .whereType<SldLabel>()
        .where((l) => l.size == 6 && l.text.contains('A'))
        .map((l) => l.text)
        .toList();
    expect(stub, isNotEmpty);
    final label = stub.first;

    // Truncated with an explicit ASCII ellipsis, and the word it was cut at
    // is never split mid-token.
    expect(label, contains('...'), reason: label);
    expect(label, isNot(contains('workshop')), reason: label);
    final namePart = label.split('...').first;
    final words = longName.split(' ');
    final wordBoundaryPrefixes = [
      for (var i = 1; i <= words.length; i++) words.sublist(0, i).join(' ')
    ];
    expect(wordBoundaryPrefixes, contains(namePart), reason: label);
    // The total budget (name + ellipsis) stays within the old 14-char width
    // so the on-canvas column layout is unaffected.
    expect(namePart.length + 3, lessThanOrEqualTo(14));
  });
}
