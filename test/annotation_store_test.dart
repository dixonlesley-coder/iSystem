import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';

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
}
