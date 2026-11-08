import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/floor_remap.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/reference_line_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/cooling_load.dart';
import 'package:mechx_engine/units.dart';

/// Floor-placed work that is NOT a network node — rooms, tanks, measurements,
/// reference lines, electrical placements — must follow every floor-stack /
/// sheet re-mapping (and be pruned with a removed floor / sheet) in the SAME
/// structural undo step as the drawn nodes.
const _floors = [
  Floor('G', Length(3.0)),
  Floor('L1', Length(3.0)),
  Floor('L2', Length(3.0)),
  Floor('L3', Length(3.0)),
];

/// Sheets s1 (positional floor 0) + s2 (floor 1), s1 calibrated 0.01 m/px; an
/// office room r0 with a cassette AC inside it, a measurement, a tank and a
/// reference line on s1 floor 0; a room r1 on s2 floor 1; an electrical panel
/// placed on s1 floor 0 feeding a load placed on s1 floor 0. The history is
/// reset so the timeline starts empty.
ProviderContainer _setup() {
  final c = ProviderContainer();
  c.read(projectControllerProvider.notifier).setFloors(_floors);
  c.read(sheetsControllerProvider.notifier).loadSheets(const [
    Sheet(id: 's1', name: 'A', sizePx: Size(2000, 2000)),
    Sheet(id: 's2', name: 'B', sizePx: Size(2000, 2000)),
  ]);
  c
      .read(projectControllerProvider.notifier)
      .setCalibration('s1', const ScaleCalibration(0.01));
  c.read(roomAreasProvider.notifier).set(const [
    RoomArea(
        id: 'r0', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 100),
    RoomArea(
        id: 'r1', sheetId: 's2', floorIndex: 1, ax: 0, ay: 0, bx: 50, by: 50),
  ]);
  c.read(measurementsProvider.notifier).set(const [
    Measurement(
        id: 'm0', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 100, by: 0),
  ]);
  c.read(tankAreasProvider.notifier).set(const [
    TankArea(
        id: 't0', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 10, by: 10),
  ]);
  c.read(referenceLinesProvider.notifier).set(const [
    ReferenceLine(id: 'rl0', sheetId: 's1', x1: 0, y1: 0, x2: 10, y2: 0),
  ]);
  c.read(networkControllerProvider.notifier).loadNetwork(const Network(nodes: [
        NetNode(
          id: 'ac1',
          sheetId: 's1',
          x: 100,
          y: 50,
          floorIndex: 0,
          role: NodeRole.plant,
          component: NodeComponent.acCassette,
        ),
      ]));
  c.read(electricalProjectProvider.notifier).setProject(const ElectricalProject(
        panels: [
          ElectricalPanel(
            id: 'LP',
            name: 'LP',
            layoutPos: LayoutPos(sheetId: 's1', floorIndex: 0, x: 5, y: 5),
            circuits: [
              ElectricalCircuit(
                id: 'c1',
                name: 'Load',
                loadW: 500,
                loadPos: LayoutPos(sheetId: 's1', floorIndex: 0, x: 9, y: 9),
              ),
            ],
          ),
        ],
      ));
  c.read(historyProvider.notifier).reset();
  return c;
}

RoomArea _room(ProviderContainer c, String id) =>
    c.read(roomAreasProvider).firstWhere((r) => r.id == id);
NetNode _node(ProviderContainer c, String id) =>
    c.read(networkControllerProvider).network.nodes.firstWhere((n) => n.id == id);
ElectricalPanel _lp(ProviderContainer c) =>
    c.read(electricalProjectProvider).panels.firstWhere((p) => p.id == 'LP');
// The placed load way (the MEP auto-feed may add a feeder way beside it).
ElectricalCircuit _c1(ProviderContainer c) =>
    _lp(c).circuits.firstWhere((x) => x.id == 'c1');

void main() {
  group('shiftFloorIndex (the one shared floor rule)', () {
    test('insertion shifts at/above the slot up; removal deletes on, drops above',
        () {
      // 2 basements inserted at 0 into a 4→6 stack: floor 1 → 3.
      expect(
          shiftFloorIndex(1,
              levelCount: 6, insertedIndex: 0, insertedCount: 2),
          3);
      // Floor 2 removed from 4 → 3: floor 2 has no home, floor 3 → 2, 1 stays.
      expect(shiftFloorIndex(2, levelCount: 3, removedIndex: 2), isNull);
      expect(shiftFloorIndex(3, levelCount: 3, removedIndex: 2), 2);
      expect(shiftFloorIndex(1, levelCount: 3, removedIndex: 2), 1);
      // Wholesale shrink to 2 floors clamps floor 3 onto the new top (1).
      expect(shiftFloorIndex(3, levelCount: 2), 1);
      // Sheet re-map by +2 on a 4-floor stack, clamped at the top.
      expect(shiftSheetFloorIndex(0, 2, levelCount: 4), 2);
      expect(shiftSheetFloorIndex(3, 2, levelCount: 4), 3);
    });
  });

  test(
      'setSheetFloor carries rooms/tanks/measurements/electrical placements '
      'with the nodes; the AC keeps its room load; one undo restores all', () {
    final c = _setup();
    addTearDown(c.dispose);
    // Room r0: 2 m x 1 m = 2 m2 at 0.01 m/px; 2 m2 x 3 m x 600 BTU/h.m2 =
    // 1200 BTU/h -> one unit -> 0.5 PK nominal 5000 BTU/h -> input W via COP.
    final roomWatts = acInputPowerW(coolingBtuPerHr: 5000.0);
    expect(c.read(placedEquipmentLoadsProvider).single.mechanicalPower.watts,
        closeTo(roomWatts, 1e-6));

    c.read(sheetsControllerProvider.notifier).setSheetFloor('s1', 2);

    expect(_node(c, 'ac1').floorIndex, 2);
    expect(_room(c, 'r0').floorIndex, 2);
    expect(_room(c, 'r1').floorIndex, 1, reason: 'another sheet is untouched');
    expect(c.read(measurementsProvider).single.floorIndex, 2);
    expect(c.read(tankAreasProvider).single.floorIndex, 2);
    expect(_lp(c).layoutPos!.floorIndex, 2);
    expect(_c1(c).loadPos!.floorIndex, 2);
    final ac = _node(c, 'ac1');
    expect(_room(c, 'r0').containsNode(ac.sheetId, ac.floorIndex, ac.x, ac.y),
        isTrue);
    // The AC circuit still tracks the room PK — not the 1.8 kW default.
    expect(c.read(placedEquipmentLoadsProvider).single.mechanicalPower.watts,
        closeTo(roomWatts, 1e-6));

    // ONE Ctrl+Z restores the mapping, the node AND every placed record.
    c.read(historyProvider.notifier).undo();
    expect(c.read(historyProvider.notifier).canUndo, isFalse);
    expect(_node(c, 'ac1').floorIndex, 0);
    expect(_room(c, 'r0').floorIndex, 0);
    expect(c.read(measurementsProvider).single.floorIndex, 0);
    expect(c.read(tankAreasProvider).single.floorIndex, 0);
    expect(_lp(c).layoutPos!.floorIndex, 0);
    expect(_c1(c).loadPos!.floorIndex, 0);

    c.read(historyProvider.notifier).redo();
    expect(_room(c, 'r0').floorIndex, 2);
    expect(_lp(c).layoutPos!.floorIndex, 2);
  });

  test(
      'removeFloor deletes annotations on it, un-places electrical there, and '
      'drops the work above; one undo restores', () {
    final c = _setup();
    addTearDown(c.dispose);
    c.read(projectControllerProvider.notifier).removeFloor(0);
    // Floor 0 is gone: r0 / m0 / t0 deleted (like the AC node), r1 1 -> 0.
    expect(c.read(roomAreasProvider).map((r) => r.id), ['r1']);
    expect(_room(c, 'r1').floorIndex, 0);
    expect(c.read(measurementsProvider), isEmpty);
    expect(c.read(tankAreasProvider), isEmpty);
    expect(_lp(c).layoutPos, isNull);
    expect(_c1(c).loadPos, isNull);

    c.read(historyProvider.notifier).undo();
    expect(c.read(roomAreasProvider), hasLength(2));
    expect(_room(c, 'r1').floorIndex, 1);
    expect(c.read(measurementsProvider), hasLength(1));
    expect(_lp(c).layoutPos!.floorIndex, 0);
  });

  test('addBasement shifts annotations + placements up with the nodes', () {
    final c = _setup();
    addTearDown(c.dispose);
    c.read(projectControllerProvider.notifier).addBasement(2, 3.0);
    expect(_node(c, 'ac1').floorIndex, 2);
    expect(_room(c, 'r0').floorIndex, 2);
    expect(_room(c, 'r1').floorIndex, 3);
    expect(c.read(measurementsProvider).single.floorIndex, 2);
    expect(_lp(c).layoutPos!.floorIndex, 2);
    c.read(historyProvider.notifier).undo();
    expect(_room(c, 'r1').floorIndex, 1);
    expect(_lp(c).layoutPos!.floorIndex, 0);
  });

  test(
      'removeSheet prunes the sheet\'s calibration, annotations and reference '
      'lines (one undo restores); a same-id re-import inherits nothing', () {
    final c = _setup();
    addTearDown(c.dispose);
    final sheets = c.read(sheetsControllerProvider.notifier);
    sheets.removeSheet('s1');
    expect(c.read(projectControllerProvider).calibrationFor('s1'), isNull);
    expect(c.read(roomAreasProvider).map((r) => r.id), ['r1']);
    expect(c.read(measurementsProvider), isEmpty);
    expect(c.read(tankAreasProvider), isEmpty);
    expect(c.read(referenceLinesProvider), isEmpty);
    expect(_lp(c).layoutPos, isNull);

    // A revised plan imported under the same filename-derived id gets NO old
    // scale and no old annotations.
    sheets.addSheets(const [Sheet(id: 's1', name: 'A rev B')]);
    expect(c.read(sheetsControllerProvider).sheets.last.id, 's1');
    expect(c.read(projectControllerProvider).calibrationFor('s1'), isNull);

    // Undo the removal: everything comes back (the timeline holds only it).
    c.read(historyProvider.notifier).undo();
    expect(c.read(projectControllerProvider).calibrationFor('s1')!.metersPerPixel,
        0.01);
    expect(c.read(roomAreasProvider), hasLength(2));
    expect(c.read(referenceLinesProvider), hasLength(1));
    expect(_lp(c).layoutPos!.sheetId, 's1');
  });

  test('addSheets never hands out an id that still carries a calibration', () {
    final c = _setup();
    addTearDown(c.dispose);
    // A leftover calibration for a sheet that is not live (an older file).
    c
        .read(projectControllerProvider.notifier)
        .setCalibration('denah#0', const ScaleCalibration(0.02));
    c
        .read(sheetsControllerProvider.notifier)
        .addSheets(const [Sheet(id: 'denah#0', name: 'denah')]);
    final added = c.read(sheetsControllerProvider).sheets.last;
    expect(added.id, isNot('denah#0'));
    expect(c.read(projectControllerProvider).calibrationFor(added.id), isNull);
  });

  test(
      'Replace-all prunes gone sheets\' work, flags a surviving same-id '
      'calibration STALE, and is one undo step', () {
    final c = _setup();
    addTearDown(c.dispose);
    // Replace with a same-named s1 (revised plan) only — s2 goes.
    c
        .read(sheetsControllerProvider.notifier)
        .replaceAllSheets(const [Sheet(id: 's1', name: 'A rev B')]);
    final project = c.read(projectControllerProvider);
    expect(project.calibrationFor('s1')!.metersPerPixel, 0.01);
    expect(project.isCalibrationStale('s1'), isTrue);
    expect(c.read(roomAreasProvider).map((r) => r.id), ['r0']);

    c.read(historyProvider.notifier).undo();
    expect(c.read(sheetsControllerProvider).sheets.map((s) => s.id),
        ['s1', 's2']);
    expect(c.read(projectControllerProvider).isCalibrationStale('s1'), isFalse);
    expect(c.read(roomAreasProvider), hasLength(2));
  });

  test('Replace-all into an empty project records nothing (plain load)', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c
        .read(sheetsControllerProvider.notifier)
        .replaceAllSheets(const [Sheet(id: 'p#0', name: 'p')]);
    expect(c.read(sheetsControllerProvider).sheets.single.id, 'p#0');
    expect(c.read(historyProvider.notifier).canUndo, isFalse);
  });
}
