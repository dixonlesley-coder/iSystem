import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/network/network.dart' show NodeComponent;
import 'package:mechx_engine/sizing/room_air.dart';
import 'package:mechx_engine/standards/ventilation.dart';
import 'package:mechx_engine/units.dart';

void main() {
  test('add ignores a zero-length span and stores real ones', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final m = c.read(measurementsProvider.notifier);
    m.add(sheetId: 's1', floorIndex: 0, ax: 10, ay: 10, bx: 10, by: 10);
    expect(c.read(measurementsProvider), isEmpty);
    m.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 30, by: 40);
    final list = c.read(measurementsProvider);
    expect(list, hasLength(1));
    expect(list.first.pixelLength, closeTo(50, 1e-9)); // 3-4-5
  });

  test('removeById and clear', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final m = c.read(measurementsProvider.notifier);
    m.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 1, by: 0);
    m.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 2, by: 0);
    final id0 = c.read(measurementsProvider).first.id;
    m.removeById(id0);
    expect(c.read(measurementsProvider), hasLength(1));
    expect(c.read(measurementsProvider).any((x) => x.id == id0), isFalse);
    m.clear();
    expect(c.read(measurementsProvider), isEmpty);
  });

  test('set() loads a list and fresh ids never collide with loaded ones', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final m = c.read(measurementsProvider.notifier);
    m.set(const [
      Measurement(id: 'm5', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 1, by: 1),
    ]);
    expect(c.read(measurementsProvider), hasLength(1));
    m.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 2, by: 0);
    final ids = c.read(measurementsProvider).map((x) => x.id).toSet();
    expect(ids, hasLength(2)); // no collision with the loaded 'm5'
  });

  test('measureMode toggles', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(measureModeProvider), isFalse);
    c.read(measureModeProvider.notifier).toggle();
    expect(c.read(measureModeProvider), isTrue);
    c.read(measureModeProvider.notifier).set(false);
    expect(c.read(measureModeProvider), isFalse);
  });

  test('TankArea capacity = footprint x depth; add ignores a tiny box', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final t = c.read(tankAreasProvider.notifier);
    // A degenerate (sub-2px) box is ignored.
    t.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 1, by: 1);
    expect(c.read(tankAreasProvider), isEmpty);
    // A 200x100 px footprint at 0.01 m/px = 2.0 x 1.0 m = 2.0 m^2.
    t.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 100);
    final tank = c.read(tankAreasProvider).single;
    expect(tank.areaM2(0.01), closeTo(2.0, 1e-9));
    // Default depth 2.0 m + concrete ⇒ 4.0 m^3 = 4000 L.
    expect(tank.depthM, 2.0);
    expect(tank.material, TankMaterial.concrete);
    expect(tank.volumeM3(0.01), closeTo(4.0, 1e-9));
    expect(tank.litres(0.01), closeTo(4000, 1e-6));
    // Editing depth + material recomputes capacity.
    t.setDepth(tank.id, 3.0);
    t.setMaterial(tank.id, TankMaterial.fibreglass);
    final t2 = c.read(tankAreasProvider).single;
    expect(t2.volumeM3(0.01), closeTo(6.0, 1e-9));
    expect(t2.material, TankMaterial.fibreglass);
  });

  test('TankArea.fromJson is tolerant (drops malformed, unknown material)', () {
    expect(TankArea.fromJson('nope'), isNull);
    expect(TankArea.fromJson({'id': 't1', 'sheetId': 's1'}), isNull);
    final ok = TankArea.fromJson({
      'id': 't1',
      'sheetId': 's1',
      'floor': 1,
      'ax': 0,
      'ay': 0,
      'bx': 10,
      'by': 20,
      'material': 'not-a-material',
    });
    expect(ok, isNotNull);
    expect(ok!.material, TankMaterial.concrete); // unknown ⇒ concrete
    expect(ok.depthM, 2.0); // absent ⇒ default
    expect(TankArea.fromJson(ok.toJson())!.toJson(), ok.toJson());
  });

  test('RoomArea airflow = area x ceiling x ACH; add ignores a tiny box', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final r = c.read(roomAreasProvider.notifier);
    // A degenerate (sub-2px) box is ignored.
    r.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 1, by: 1);
    expect(c.read(roomAreasProvider), isEmpty);
    // A 200x100 px footprint at 0.01 m/px = 2.0 x 1.0 m = 2.0 m^2.
    r.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 100);
    final room = c.read(roomAreasProvider).single;
    expect(room.areaM2(0.01), closeTo(2.0, 1e-9));
    // Defaults: office (6 ACH), 3.0 m ceiling, FCU, no override.
    expect(room.roomType, RoomType.office);
    expect(room.ceilingHeightM, 3.0);
    expect(room.equipmentKind, AirEquipmentKind.fcu);
    expect(room.achOverride, isNull);
    expect(room.effectiveAch(), closeTo(6.0, 1e-9));
    // volume = 2.0 x 3.0 = 6.0 m^3; Q = 6.0 x 6 / 3600 = 0.01 m^3/s = 10 L/s.
    final s = room.sizing(0.01)!;
    expect(s.airflow.cubicMetersPerSecond, closeTo(0.01, 1e-12));
    expect(s.airflow.inLitersPerSecond, closeTo(10.0, 1e-9));
    expect(s.airflowCfm, closeTo(21.19, 0.01)); // 0.01 x 2118.88
  });

  test('RoomArea edits: room type drives ACH; explicit override; Auto resets',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final r = c.read(roomAreasProvider.notifier);
    r.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 100);
    final id = c.read(roomAreasProvider).single.id;

    // Commercial kitchen ⇒ 20 ACH ⇒ Q = 6.0 x 20 / 3600 = 0.03333 m^3/s.
    r.setRoomType(id, RoomType.commercialKitchen);
    var room = c.read(roomAreasProvider).single;
    expect(room.effectiveAch(), closeTo(20.0, 1e-9));
    expect(room.sizing(0.01)!.airflow.cubicMetersPerSecond,
        closeTo(6.0 * 20 / 3600, 1e-12));

    // Explicit override wins over the room-type default.
    r.setAch(id, 10);
    room = c.read(roomAreasProvider).single;
    expect(room.achOverride, 10);
    expect(room.effectiveAch(), closeTo(10.0, 1e-9));

    // 'Auto' (null) clears the override back to the room-type default (20).
    r.setAch(id, null);
    room = c.read(roomAreasProvider).single;
    expect(room.achOverride, isNull);
    expect(room.effectiveAch(), closeTo(20.0, 1e-9));
  });

  test('RoomArea cooling load + AC containment', () {
    const room = RoomArea(
      id: 'r0',
      sheetId: 's1',
      floorIndex: 0,
      ax: 0,
      ay: 0,
      bx: 200,
      by: 100,
    );
    // 2.0 m² (200×100 px @ 0.01) × 3 m ceiling, office density 600 BTU/h·m²:
    //   load = 2.0 × 600 × (3/3) = 1200 BTU/h → 0.133 PK → recommend 0.5 PK.
    final load = room.coolingLoad(0.01)!;
    expect(load.btuPerHr, closeTo(1200.0, 1e-9));
    expect(load.pk, closeTo(1200.0 / 9000.0, 1e-9));
    expect(load.recommended.pk, 0.5);
    expect(room.coolingLoad(null), isNull); // no scale ⇒ null

    // Containment: a node inside the footprint on the same sheet/floor.
    expect(room.containsNode('s1', 0, 100, 50), isTrue);
    expect(room.containsNode('s1', 0, 250, 50), isFalse); // outside x
    expect(room.containsNode('s2', 0, 100, 50), isFalse); // other sheet
    expect(room.containsNode('s1', 1, 100, 50), isFalse); // other floor

    expect(RoomArea.isAcComponent(NodeComponent.acCassette), isTrue);
    expect(RoomArea.isAcComponent(NodeComponent.acSplitWall), isTrue);
    expect(RoomArea.isAcComponent(NodeComponent.acDucted), isTrue);
    expect(RoomArea.isAcComponent(NodeComponent.fcu), isFalse);
    expect(RoomArea.isAcComponent(null), isFalse);
  });

  test('RoomArea.fromJson is tolerant (drops malformed, unknown enums)', () {
    expect(RoomArea.fromJson('nope'), isNull);
    expect(RoomArea.fromJson({'id': 'r1', 'sheetId': 's1'}), isNull);
    final ok = RoomArea.fromJson({
      'id': 'r1',
      'sheetId': 's1',
      'floor': 2,
      'ax': 0,
      'ay': 0,
      'bx': 10,
      'by': 20,
      'roomType': 'not-a-type',
      'equipment': 'not-a-kind',
    });
    expect(ok, isNotNull);
    expect(ok!.roomType, RoomType.office); // unknown ⇒ office
    expect(ok.equipmentKind, AirEquipmentKind.fcu); // unknown ⇒ fcu
    expect(ok.ceilingHeightM, 3.0); // absent ⇒ default
    expect(ok.achOverride, isNull); // absent ⇒ null
    expect(RoomArea.fromJson(ok.toJson())!.toJson(), ok.toJson());
  });

  test('roomMode toggles', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(roomModeProvider), isFalse);
    c.read(roomModeProvider.notifier).toggle();
    expect(c.read(roomModeProvider), isTrue);
    c.read(roomModeProvider.notifier).set(false);
    expect(c.read(roomModeProvider), isFalse);
  });

  test('Measurement.fromJson is tolerant (drops malformed)', () {
    expect(Measurement.fromJson('nope'), isNull);
    expect(Measurement.fromJson({'id': 'm1', 'sheetId': 's1'}), isNull); // no coords
    final ok = Measurement.fromJson({
      'id': 'm1',
      'sheetId': 's1',
      'floor': 2,
      'ax': 1,
      'ay': 2,
      'bx': 3,
      'by': 4,
    });
    expect(ok, isNotNull);
    expect(ok!.floorIndex, 2);
    // Round-trip.
    expect(Measurement.fromJson(ok.toJson())!.toJson(), ok.toJson());
  });

  // ── B3: annotation undo domain ─────────────────────────────────────────────

  test('measurement add records on the global timeline and undoes/redoes', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final m = c.read(measurementsProvider.notifier);
    final hist = c.read(historyProvider.notifier);

    expect(hist.canUndo, isFalse);
    m.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 30, by: 40);
    expect(c.read(measurementsProvider), hasLength(1));
    expect(hist.canUndo, isTrue);

    hist.undo();
    expect(c.read(measurementsProvider), isEmpty);
    hist.redo();
    expect(c.read(measurementsProvider), hasLength(1));
  });

  test('a degenerate (ignored) add records nothing — no phantom undo step', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final m = c.read(measurementsProvider.notifier);
    // Zero-length span is ignored by add() ⇒ it must not push an undo step.
    m.add(sheetId: 's1', floorIndex: 0, ax: 5, ay: 5, bx: 5, by: 5);
    expect(c.read(measurementsProvider), isEmpty);
    expect(c.read(historyProvider.notifier).canUndo, isFalse);
  });

  test('room delete is undoable — Ctrl+Z restores the room with its edits', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final r = c.read(roomAreasProvider.notifier);
    final hist = c.read(historyProvider.notifier);

    r.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 100);
    final id = c.read(roomAreasProvider).single.id;
    // Minutes-of-input configuration — an edit is its own undo step.
    r.setRoomType(id, RoomType.commercialKitchen);
    r.setCeiling(id, 4.0);
    final configured = c.read(roomAreasProvider).single;
    expect(configured.roomType, RoomType.commercialKitchen);
    expect(configured.ceilingHeightM, 4.0);

    // The data-loss trap: delete it.
    r.removeById(id);
    expect(c.read(roomAreasProvider), isEmpty);

    // One undo restores the deleted room, its configured properties intact.
    hist.undo();
    final restored = c.read(roomAreasProvider).single;
    expect(restored.id, id);
    expect(restored.roomType, RoomType.commercialKitchen);
    expect(restored.ceilingHeightM, 4.0);

    // The prior undo step (setCeiling) still reverts independently.
    hist.undo();
    expect(c.read(roomAreasProvider).single.ceilingHeightM, 3.0);
  });

  test('tank delete is undoable — restores the deleted tank + capacity', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final t = c.read(tankAreasProvider.notifier);
    final hist = c.read(historyProvider.notifier);

    t.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 100);
    final id = c.read(tankAreasProvider).single.id;
    t.setDepth(id, 3.0);
    expect(c.read(tankAreasProvider).single.volumeM3(0.01), closeTo(6.0, 1e-9));

    t.removeById(id);
    expect(c.read(tankAreasProvider), isEmpty);

    hist.undo();
    final restored = c.read(tankAreasProvider).single;
    expect(restored.id, id);
    expect(restored.volumeM3(0.01), closeTo(6.0, 1e-9)); // depth edit intact
  });

  test('the three lists share ONE stack; newest-first undo across them', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final t = c.read(tankAreasProvider.notifier);
    final r = c.read(roomAreasProvider.notifier);
    final hist = c.read(historyProvider.notifier);

    t.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 100);
    r.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 100);

    // Newest edit is the room add — one undo reverts IT, tank untouched.
    hist.undo();
    expect(c.read(roomAreasProvider), isEmpty);
    expect(c.read(tankAreasProvider), hasLength(1));
    // Next undo reverts the tank add.
    hist.undo();
    expect(c.read(tankAreasProvider), isEmpty);
  });

  test('annotation shares the global timeline with other domains', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final proj = c.read(projectControllerProvider.notifier);
    final tanks = c.read(tankAreasProvider.notifier);
    final hist = c.read(historyProvider.notifier);

    proj.setFloorHeight(0, const Length(2.0));
    tanks.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 100);

    // Newest edit is the tank add — undo reverts it, leaving the floor height,
    // and the FOLLOWING undo reverts the (older) project edit. This exercises
    // history_store's `_revert(UndoDomain.annotation, …)` branch end-to-end.
    hist.undo();
    expect(c.read(tankAreasProvider), isEmpty);
    expect(c.read(projectControllerProvider).floors.first.height.meters, 2.0);
    hist.undo();
    expect(c.read(projectControllerProvider).floors.first.height.meters, 4.0);
  });

  test('load path (set) never records — no phantom undo across a project load',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final hist = c.read(historyProvider.notifier);

    // Mirror applyDocument: replace each list wholesale (the load path).
    c.read(measurementsProvider.notifier).set(const [
      Measurement(
          id: 'm5', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 1, by: 1),
    ]);
    c.read(tankAreasProvider.notifier).set(const [
      TankArea(
          id: 't2', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 100),
    ]);
    c.read(roomAreasProvider.notifier).set(const [
      RoomArea(
          id: 'r3', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 100),
    ]);

    expect(c.read(measurementsProvider), hasLength(1));
    expect(c.read(tankAreasProvider), hasLength(1));
    expect(c.read(roomAreasProvider), hasLength(1));
    // The load populated state but recorded NOTHING on the timeline.
    expect(hist.canUndo, isFalse);
    expect(hist.canRedo, isFalse);
    expect(c.read(annotationHistoryProvider.notifier).canUndo, isFalse);
  });

  test('history reset clears the annotation stack (fresh baseline on load)', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final r = c.read(roomAreasProvider.notifier);
    final anno = c.read(annotationHistoryProvider.notifier);

    r.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 100);
    expect(anno.canUndo, isTrue);

    // A document open/restore resets the global timeline; that also drops the
    // annotation coordinator's shared stack.
    c.read(historyProvider.notifier).reset();
    expect(anno.canUndo, isFalse);
    expect(anno.canRedo, isFalse);
  });

  // ── E6: first-class rooms/tanks (move/resize on the annotation undo domain) ──

  test('E6: a room MOVE drag collapses to exactly ONE undo step', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final r = c.read(roomAreasProvider.notifier);
    final hist = c.read(historyProvider.notifier);

    r.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 100);
    final id = c.read(roomAreasProvider).single.id;

    // Simulate one drag: the overlay snapshots ONCE on first movement, then
    // streams many live (non-recording) setBounds calls (onPanUpdate).
    r.beginGeometryEdit();
    r.setBounds(id, 10, 10, 210, 110);
    r.setBounds(id, 20, 20, 220, 120);
    r.setBounds(id, 50, 50, 250, 150);
    var room = c.read(roomAreasProvider).single;
    expect(room.ax, 50);
    expect(room.ay, 50);
    expect(room.bx, 250);
    expect(room.by, 150);

    // ONE undo reverts the WHOLE drag back to the pre-drag footprint (not just
    // the last increment).
    hist.undo();
    room = c.read(roomAreasProvider).single;
    expect(room.ax, 0);
    expect(room.ay, 0);
    expect(room.bx, 200);
    expect(room.by, 100);

    // The next undo reverts the add — proving the drag was exactly one step.
    hist.undo();
    expect(c.read(roomAreasProvider), isEmpty);

    // Redo replays the drag as one step.
    hist.redo(); // re-add
    hist.redo(); // re-drag
    expect(c.read(roomAreasProvider).single.ax, 50);
  });

  test('E6: a tank corner RESIZE drag collapses to exactly ONE undo step', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final t = c.read(tankAreasProvider.notifier);
    final hist = c.read(historyProvider.notifier);

    t.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 100);
    final id = c.read(tankAreasProvider).single.id;

    // Drag the bottom-right corner out (bx grows) across several frames.
    t.beginGeometryEdit();
    t.setBounds(id, 0, 0, 300, 150);
    t.setBounds(id, 0, 0, 400, 200);
    expect(c.read(tankAreasProvider).single.bx, 400);
    expect(c.read(tankAreasProvider).single.by, 200);

    hist.undo();
    final back = c.read(tankAreasProvider).single;
    expect(back.bx, 200); // original corner restored in one step
    expect(back.by, 100);
  });

  test('E6: containsPoint hit-tests the footprint (sheet/floor scoped)', () {
    const room = RoomArea(
        id: 'r0', sheetId: 's1', floorIndex: 0, ax: 10, ay: 10, bx: 60, by: 40);
    expect(room.containsPoint('s1', 0, 30, 20), isTrue);
    expect(room.containsPoint('s1', 0, 5, 20), isFalse); // outside x
    expect(room.containsPoint('s2', 0, 30, 20), isFalse); // other sheet
    expect(room.containsPoint('s1', 1, 30, 20), isFalse); // other floor
    // Unnormalized corners (bx < ax) still hit-test correctly.
    const flipped = TankArea(
        id: 't0', sheetId: 's1', floorIndex: 0, ax: 60, ay: 40, bx: 10, by: 10);
    expect(flipped.containsPoint('s1', 0, 30, 20), isTrue);
  });

  test('E6: selectedAnnotation selects room/tank and clears conditionally', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final sel = c.read(selectedAnnotationProvider.notifier);
    expect(c.read(selectedAnnotationProvider), isNull); // byte-identical default

    sel.selectRoom('r0');
    expect(c.read(selectedAnnotationProvider),
        const SelectedAnnotation(AnnotationKind.room, 'r0'));
    sel.selectTank('t0');
    expect(c.read(selectedAnnotationProvider)!.kind, AnnotationKind.tank);

    // clear(id) only clears when id matches the current selection.
    sel.clear('nope');
    expect(c.read(selectedAnnotationProvider), isNotNull);
    sel.clear('t0');
    expect(c.read(selectedAnnotationProvider), isNull);

    // clear() with no id clears unconditionally.
    sel.selectRoom('r9');
    sel.clear();
    expect(c.read(selectedAnnotationProvider), isNull);
  });

  // ── E7: room/tank names ─────────────────────────────────────────────────────

  test('E7: rooms get sequential names; rename via setName; name round-trips',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final r = c.read(roomAreasProvider.notifier);

    r.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 100);
    r.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 100);
    final rooms = c.read(roomAreasProvider);
    // Distinct default names so a 20-AHU schedule never lists a wall of 'Room'.
    expect(rooms[0].name, 'Room 1');
    expect(rooms[1].name, 'Room 2');

    // Rename is its own undo step (the dead setter is now wired to the field).
    r.setName(rooms[0].id, 'Lobby AHU');
    final renamed = c.read(roomAreasProvider).first;
    expect(renamed.name, 'Lobby AHU');

    // Persistence keeps the name (already threaded through project_document via
    // RoomArea.toJson/fromJson).
    final back = RoomArea.fromJson(renamed.toJson())!;
    expect(back.name, 'Lobby AHU');
    expect(back.toJson(), renamed.toJson());

    // Undo reverts the rename back to the sequential default.
    c.read(historyProvider.notifier).undo();
    expect(c.read(roomAreasProvider).first.name, 'Room 1');
  });

  test('E7: tanks get sequential names + name round-trips', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final t = c.read(tankAreasProvider.notifier);

    t.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 100);
    t.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 100);
    final tanks = c.read(tankAreasProvider);
    expect(tanks[0].name, 'Tank 1');
    expect(tanks[1].name, 'Tank 2');

    t.setName(tanks[0].id, 'Ground reservoir');
    final back =
        TankArea.fromJson(c.read(tankAreasProvider).first.toJson())!;
    expect(back.name, 'Ground reservoir');
  });

  test('E7: an old file without a name decodes to the default (byte-identical)',
      () {
    // A pre-E7 `.mechx` (no `name` key) is tolerant → the default name applies.
    final room = RoomArea.fromJson({
      'id': 'r1',
      'sheetId': 's1',
      'floor': 0,
      'ax': 0,
      'ay': 0,
      'bx': 10,
      'by': 20,
    })!;
    expect(room.name, 'Room');
    final tank = TankArea.fromJson({
      'id': 't1',
      'sheetId': 's1',
      'floor': 0,
      'ax': 0,
      'ay': 0,
      'bx': 10,
      'by': 20,
    })!;
    expect(tank.name, 'Tank');
  });
}
