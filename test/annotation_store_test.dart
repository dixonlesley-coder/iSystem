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
