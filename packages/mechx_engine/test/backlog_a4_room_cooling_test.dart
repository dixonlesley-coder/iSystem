// Backlog A-4 (2026-11-13) — too few / too small AC units in a room.
import 'package:mechx_engine/sizing/cooling_load.dart';
import 'package:test/test.dart';

void main() {
  test('shophouse room 44 400 BTU/h, two units: 2 x 2.5 PK = 48 000 ⇒ OK', () {
    final c = roomCoolingCheck(loadBtuPerHr: 44400, unitCount: 2)!;
    // 44 400 / 2 = 22 200 ⇒ 2.5 PK (24 000); 2 x 24 000 = 48 000 >= 44 400.
    expect(c.perUnit.pk, 2.5);
    expect(c.installedBtuPerHr, 48000);
    expect(c.undersized, isFalse);
  });

  test('one cassette: 44 400 > 27 000 (3 PK top rung) ⇒ undersized, 2 needed',
      () {
    final c = roomCoolingCheck(loadBtuPerHr: 44400, unitCount: 1)!;
    expect(c.perUnit.exceedsRange, isTrue);
    expect(c.installedBtuPerHr, 27000);
    expect(c.undersized, isTrue);
    // ceil(44 400 / 27 000) = 2.
    expect(c.unitsNeeded, 2);
  });

  test('exactly the top rung is not undersized; no unit ⇒ no check', () {
    expect(roomCoolingCheck(loadBtuPerHr: 27000, unitCount: 1)!.undersized,
        isFalse);
    expect(roomCoolingCheck(loadBtuPerHr: 54000, unitCount: 2)!.unitsNeeded, 2);
    // A room with no AC node is un-designed, not undersized.
    expect(roomCoolingCheck(loadBtuPerHr: 44400, unitCount: 0), isNull);
  });
}
