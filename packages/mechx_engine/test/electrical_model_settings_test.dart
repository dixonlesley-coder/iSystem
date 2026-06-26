import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// Round-trip contract for the additive Fold-1 project settings (origin fault
/// level + busbar clearing time). They must survive toJson→fromJson and a legacy
/// file lacking the keys must decode them as null (= the app defaults).
void main() {
  test('ElectricalProject round-trips the Fold-1 fault settings', () {
    const p = ElectricalProject(
      id: 'p1',
      name: 'X',
      originFaultLevelA: Current(25000),
      busbarClearingTimeS: 0.2,
    );
    final back = ElectricalProject.fromJson(p.toJson());
    expect(back.originFaultLevelA!.amperes, 25000);
    expect(back.busbarClearingTimeS, 0.2);
  });

  test('a project without the keys decodes both as null (legacy/default)', () {
    final back = ElectricalProject.fromJson({'id': 'p', 'name': 'Y'});
    expect(back.originFaultLevelA, isNull);
    expect(back.busbarClearingTimeS, isNull);
  });

  test('unset fields are omitted from JSON (small file, byte-identical)', () {
    const p = ElectricalProject(id: 'p', name: 'Y');
    final json = p.toJson();
    expect(json.containsKey('originFaultLevelA'), isFalse);
    expect(json.containsKey('busbarClearingTimeS'), isFalse);
  });

  group('ElectricalCircuit.points (chained outlets)', () {
    test('round-trips and is omitted when 1 (default)', () {
      const c = ElectricalCircuit(id: 'c', name: 'Sockets', points: 3);
      final back = ElectricalCircuit.fromJson(c.toJson());
      expect(back.points, 3);
      // The default (1) is omitted so an unchained circuit stays byte-identical.
      const single = ElectricalCircuit(id: 'c', name: 'X');
      expect(single.toJson().containsKey('points'), isFalse);
      expect(ElectricalCircuit.fromJson({'id': 'c', 'name': 'X'}).points, 1);
    });

    test('copyWith carries / overrides points', () {
      const c = ElectricalCircuit(id: 'c', name: 'X', points: 2);
      expect(c.copyWith().points, 2);
      expect(c.copyWith(points: 5).points, 5);
    });
  });
}
