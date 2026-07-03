import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
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

  test('applyCalibrationToAllSheets copies one sheet\'s calibration to all others',
      () {
    final c = makeContainer();
    final n = c.read(projectControllerProvider.notifier);
    n.setCalibration('s1', const ScaleCalibration(0.02));

    n.applyCalibrationToAllSheets('s1', toSheetIds: {'s1', 's2', 's3'});

    final s = c.read(projectControllerProvider);
    expect(s.calibrationFor('s1')?.metersPerPixel, 0.02);
    expect(s.calibrationFor('s2')?.metersPerPixel, 0.02);
    expect(s.calibrationFor('s3')?.metersPerPixel, 0.02);
  });

  test('applyCalibrationToAllSheets is a no-op when source is uncalibrated', () {
    final c = makeContainer();
    final n = c.read(projectControllerProvider.notifier);
    n.applyCalibrationToAllSheets('s1', toSheetIds: {'s1', 's2'});
    expect(c.read(projectControllerProvider).calibrations, isEmpty);
    expect(n.canUndo, isFalse); // nothing recorded
  });

  test('applyCalibrationToAllSheets is undoable (one step) / redoable', () {
    final c = makeContainer();
    final n = c.read(projectControllerProvider.notifier);
    n.setCalibration('s1', const ScaleCalibration(0.02)); // 1st undoable edit

    n.applyCalibrationToAllSheets('s1', toSheetIds: {'s1', 's2', 's3'});
    expect(c.read(projectControllerProvider).calibrationFor('s2')?.metersPerPixel,
        0.02);

    // It records on the global timeline as a project action.
    final hist = c.read(historyProvider.notifier);
    expect(hist.canUndo, isTrue);

    hist.undo(); // reverts the bulk-apply, leaving only s1 calibrated
    final reverted = c.read(projectControllerProvider);
    expect(reverted.calibrationFor('s1')?.metersPerPixel, 0.02);
    expect(reverted.calibrationFor('s2'), isNull);
    expect(reverted.calibrationFor('s3'), isNull);

    hist.redo(); // re-applies to all
    final redone = c.read(projectControllerProvider);
    expect(redone.calibrationFor('s2')?.metersPerPixel, 0.02);
    expect(redone.calibrationFor('s3')?.metersPerPixel, 0.02);
  });

  // ── B6: editing the floor stack under a drawn network stays safe ───────────

  test('setFloors that shrinks clamps drawn nodes above the new top (no crash)',
      () {
    final c = makeContainer();
    final net = c.read(networkControllerProvider.notifier);
    // 3-floor default; draw one node on each floor 0..2.
    net.loadNetwork(const Network(nodes: [
      NetNode(id: 'n0', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
      NetNode(id: 'n1', sheetId: 's1', x: 0, y: 0, floorIndex: 1),
      NetNode(id: 'n2', sheetId: 's1', x: 0, y: 0, floorIndex: 2),
    ]));
    // Reduce to a single floor (a template with fewer floors, say).
    c
        .read(projectControllerProvider.notifier)
        .setFloors(const [Floor('Only', Length(3.0))]);

    final floors = {
      for (final n in c.read(networkControllerProvider).network.nodes)
        n.id: n.floorIndex
    };
    expect(floors['n0'], 0);
    expect(floors['n1'], 0); // clamped down onto the single surviving floor
    expect(floors['n2'], 0);
    // No node can reference a floor the solve would index out of range.
    final building = c.read(projectControllerProvider).building;
    for (final fi in floors.values) {
      expect(() => building.elevationOf(fi), returnsNormally);
    }
  });

  test(
      'removeFloor(middle) shifts higher nodes to KEEP their physical floor '
      '(no silent re-elevation)', () {
    final c = makeContainer();
    final proj = c.read(projectControllerProvider.notifier);
    final net = c.read(networkControllerProvider.notifier);
    // A 5-floor building (setFloors on the still-empty network is a no-op remap).
    proj.setFloors(const [
      Floor('F0', Length(4.0)),
      Floor('F1', Length(3.0)),
      Floor('F2', Length(3.0)),
      Floor('F3', Length(3.0)),
      Floor('F4', Length(3.0)),
    ]);
    // Draw a node on F2 (index 2, elevation 4+3 = 7.0).
    net.loadNetwork(const Network(nodes: [
      NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 2),
    ]));
    expect(c.read(projectControllerProvider).building.elevationOf(2).meters,
        closeTo(7.0, 1e-9));

    // Remove F1 (index 1). F2 moves to index 1; the node must move WITH it —
    // NOT stay at index 2 (which is now F3, a different physical floor).
    proj.removeFloor(1);
    final a = c.read(networkControllerProvider).network.nodes.single;
    expect(a.floorIndex, 1);
    final building = c.read(projectControllerProvider).building;
    expect(building.levelCount, 4);
    expect(building.floors[a.floorIndex].name, 'F2'); // still on its own slab
  });

  test('setFloors that only grows leaves drawn nodes untouched (byte-identical)',
      () {
    final c = makeContainer();
    final net = c.read(networkControllerProvider.notifier);
    net.loadNetwork(const Network(nodes: [
      NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 2),
    ]));
    expect(net.canUndo, isFalse); // loadNetwork clears the network history

    c.read(projectControllerProvider.notifier).setFloors(const [
      Floor('F0', Length(4)),
      Floor('F1', Length(3)),
      Floor('F2', Length(3)),
      Floor('F3', Length(3)),
      Floor('F4', Length(3)),
      Floor('F5', Length(3)),
    ]);
    // The node keeps its floor and the network recorded NO undo step.
    expect(c.read(networkControllerProvider).network.nodes.single.floorIndex, 2);
    expect(net.canUndo, isFalse);
  });

  test('a shrinking setFloors remaps nodes as one network undo step', () {
    final c = makeContainer();
    final net = c.read(networkControllerProvider.notifier);
    net.loadNetwork(const Network(nodes: [
      NetNode(id: 'top', sheetId: 's1', x: 0, y: 0, floorIndex: 2),
    ]));
    final hist = c.read(historyProvider.notifier);

    c
        .read(projectControllerProvider.notifier)
        .setFloors(const [Floor('Only', Length(3.0))]);
    expect(
        c.read(networkControllerProvider).network.nodes.single.floorIndex, 0);

    // The floor swap recorded a project step; the node remap a network step.
    // Undo the network step first: the node returns to floor 2.
    hist.undo();
    expect(
        c.read(networkControllerProvider).network.nodes.single.floorIndex, 2);
    // Undo again: the floor stack is restored.
    hist.undo();
    expect(c.read(projectControllerProvider).floors.length, 3);
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
