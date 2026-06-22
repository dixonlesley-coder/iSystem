import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/units.dart';

void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  test('default project: name, 3 floors, computed elevations', () {
    final c = makeContainer();
    final s = c.read(projectControllerProvider);
    expect(s.name, 'Untitled project');
    expect(s.floors.length, 3);
    expect(s.building.totalHeight.meters, closeTo(11.0, 1e-9));
    expect(s.building.elevationOf(1).meters, closeTo(4.0, 1e-9));
    expect(s.building.elevationOf(2).meters, closeTo(7.5, 1e-9));
  });

  test('setName updates the project name', () {
    final c = makeContainer();
    c.read(projectControllerProvider.notifier).setName('Tower A');
    expect(c.read(projectControllerProvider).name, 'Tower A');
  });

  test('addFloor / removeFloor adjust the level count', () {
    final c = makeContainer();
    final n = c.read(projectControllerProvider.notifier);
    n.addFloor();
    expect(c.read(projectControllerProvider).floors.length, 4);
    expect(c.read(projectControllerProvider).floors.last.name, 'Level 3');
    n.removeFloor(0);
    expect(c.read(projectControllerProvider).floors.length, 3);
  });

  test('cannot remove the last remaining floor', () {
    final c = makeContainer();
    final n = c.read(projectControllerProvider.notifier);
    n.removeFloor(0);
    n.removeFloor(0);
    n.removeFloor(0); // would empty it — blocked
    expect(c.read(projectControllerProvider).floors.length, 1);
  });

  test('nudgeFloorHeight steps and clamps to a sane range', () {
    final c = makeContainer();
    final n = c.read(projectControllerProvider.notifier);
    n.nudgeFloorHeight(0, 0.1);
    expect(c.read(projectControllerProvider).floors[0].height.meters,
        closeTo(4.1, 1e-9));
    n.nudgeFloorHeight(0, -100); // clamps to the 0.5 m minimum
    expect(c.read(projectControllerProvider).floors[0].height.meters,
        closeTo(0.5, 1e-9));
  });

  test('calibration is stored and looked up per sheet', () {
    final c = makeContainer();
    c
        .read(projectControllerProvider.notifier)
        .setCalibration('s1', const ScaleCalibration(0.02));
    final s = c.read(projectControllerProvider);
    expect(s.calibrationFor('s1')?.metersPerPixel, 0.02);
    expect(s.calibrationFor('s2'), isNull);
  });

  test('floor + calibration edits are undoable / redoable', () {
    final c = makeContainer();
    final n = c.read(projectControllerProvider.notifier);
    final before = c.read(projectControllerProvider).floors.length;

    n.addFloor();
    expect(c.read(projectControllerProvider).floors.length, before + 1);
    expect(n.canUndo, isTrue);

    n.setFloorHeight(0, const Length(2.0));
    expect(c.read(projectControllerProvider).floors[0].height.meters, 2.0);

    n.undo(); // revert height
    expect(c.read(projectControllerProvider).floors[0].height.meters, 4.0);
    n.undo(); // revert addFloor
    expect(c.read(projectControllerProvider).floors.length, before);

    n.redo(); // re-add the floor
    expect(c.read(projectControllerProvider).floors.length, before + 1);
  });

  test('load() clears undo history (opened doc is a fresh baseline)', () {
    final c = makeContainer();
    final n = c.read(projectControllerProvider.notifier);
    n.addFloor();
    expect(n.canUndo, isTrue);
    n.load(
      name: 'Opened',
      floors: const [Floor('G', Length(3))],
      calibrations: const {},
    );
    expect(n.canUndo, isFalse);
    expect(c.read(projectControllerProvider).name, 'Opened');
  });
}
