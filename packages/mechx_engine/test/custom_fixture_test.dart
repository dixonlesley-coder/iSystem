import 'package:mechx_engine/standards/custom_fixture.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  group('CustomFixture', () {
    test('JSON round-trip preserves every field (SI metres for height)', () {
      const f = CustomFixture(
        id: 'cf1',
        name: 'Bidet spray',
        supplyUnits: 1.5,
        drainageUnits: 0.5,
        defaultMountingHeight: Length(0.4),
        isFlushValve: true,
      );
      final back = CustomFixture.fromJson(f.toJson())!;
      expect(back.id, 'cf1');
      expect(back.name, 'Bidet spray');
      expect(back.supplyUnits, 1.5);
      expect(back.drainageUnits, 0.5);
      expect(back.defaultMountingHeight!.meters, 0.4);
      expect(back.isFlushValve, isTrue);
    });

    test('round-trip with no mounting height keeps it null', () {
      const f = CustomFixture(id: 'cf2', name: 'Mop sink', supplyUnits: 2);
      final json = f.toJson();
      expect(json.containsKey('mountingHeight_m'), isFalse);
      final back = CustomFixture.fromJson(json)!;
      expect(back.defaultMountingHeight, isNull);
      expect(back.drainageUnits, 0); // defaults to 0
      expect(back.isFlushValve, isFalse);
    });

    test('tolerant decode drops entries missing id or name', () {
      expect(CustomFixture.fromJson(null), isNull);
      expect(CustomFixture.fromJson('not a map'), isNull);
      expect(CustomFixture.fromJson({'name': 'no id'}), isNull);
      expect(CustomFixture.fromJson({'id': 'x'}), isNull); // no name
      expect(CustomFixture.fromJson({'id': '', 'name': 'empty id'}), isNull);
    });

    test('tolerant decode coerces missing numeric loads to 0', () {
      final f = CustomFixture.fromJson({'id': 'cf3', 'name': 'Plain'})!;
      expect(f.supplyUnits, 0);
      expect(f.drainageUnits, 0);
    });

    test('copyWith clears the mounting height with its flag', () {
      const f = CustomFixture(
        id: 'cf4',
        name: 'Sink',
        defaultMountingHeight: Length(0.8),
      );
      final cleared = f.copyWith(clearDefaultMountingHeight: true);
      expect(cleared.defaultMountingHeight, isNull);
      expect(cleared.name, 'Sink'); // other fields survive
    });
  });
}
