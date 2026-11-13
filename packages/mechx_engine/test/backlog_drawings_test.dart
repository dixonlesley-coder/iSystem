// Drawing backlog (2026-11-13) — C-1..C-5 focused tests (pure layer).
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/riser_tags.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

BuildingLevels _levels(List<String> names, {int ground = 0}) =>
    BuildingLevels([for (final n in names) Floor(n, const Length(3.5))],
        groundIndex: ground);

void main() {
  group('C-1 level code follows the floor name', () {
    test('floorNameLevelCode recognises the drawing conventions', () {
      expect(floorNameLevelCode('Lantai 30'), 'L30');
      expect(floorNameLevelCode('lantai1'), 'L1');
      expect(floorNameLevelCode('  LANTAI   7 '), 'L7');
      expect(floorNameLevelCode('Basement 2'), 'B2');
      expect(floorNameLevelCode('B1'), 'B1');
      expect(floorNameLevelCode('b 3'), 'B3');
      expect(floorNameLevelCode('Ground'), 'GF');
      expect(floorNameLevelCode('GF'), 'GF');
      expect(floorNameLevelCode('Dasar'), 'GF');
      expect(floorNameLevelCode('Atap'), 'RF');
      expect(floorNameLevelCode('Roof'), 'RF');
      expect(floorNameLevelCode('Mezzanine'), isNull);
      expect(floorNameLevelCode('L1'), isNull);
    });

    test('a "Lantai N" stack prints LN on floor N (not the index one below)',
        () {
      final b = _levels([for (var i = 1; i <= 30; i++) 'Lantai $i']);
      expect(floorLocatorToken(0, b), 'L1');
      expect(floorLocatorToken(29, b), 'L30');
    });

    test('basements + ground + roof by name; unknown names keep the index rule',
        () {
      final b = _levels(['Basement 1', 'Dasar', 'Mezz', 'Atap'], ground: 1);
      expect(floorLocatorToken(0, b), 'B1');
      expect(floorLocatorToken(1, b), 'GF');
      expect(floorLocatorToken(2, b), 'L1'); // index rule (rel +1)
      expect(floorLocatorToken(3, b), 'RF');
    });

    test('ambiguous names fall back to the index rule for every floor', () {
      // 'Lantai 2' would collide with the index fallback 'L2' of 'Mezz'.
      final b = _levels(['Lantai 1', 'Mezz', 'Mezz B', 'Lantai 2']);
      expect([for (var i = 0; i < 4; i++) floorLocatorToken(i, b)],
          ['GF', 'L1', 'L2', 'L3']);
    });

    test('no building keeps the legacy F<n>', () {
      expect(floorLocatorToken(4, null), 'F5');
    });

    test('elementTags (plan / BOM / report) carry the name-derived code', () {
      final b = _levels(['Lantai 1', 'Lantai 2']);
      const net = Network(nodes: [
        NetNode(id: 'a', sheetId: 's', x: 0, y: 0, floorIndex: 1),
        NetNode(id: 'b', sheetId: 's', x: 10, y: 0, floorIndex: 1),
      ], edges: [
        NetEdge(id: 'e', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
      ]);
      expect(elementTags(net, building: b)['e'], 'CW-L2');
    });
  });
}
