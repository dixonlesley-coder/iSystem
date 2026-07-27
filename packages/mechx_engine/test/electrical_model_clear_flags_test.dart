import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// Round-trip + clear-flag contract for `ElectricalCircuit`. Covers the six
/// clear flags added alongside the existing clearMotorKw/clearPhases/
/// clearCableType/clearStarterType/clearLoadPos idiom, plus the tolerant
/// `feedsPanelId: ''` legacy-sentinel decode.
void main() {
  group('ElectricalCircuit.copyWith clear flags', () {
    test('clearFeedsPanelId nulls feedsPanelId; copyWith() alone preserves',
        () {
      const c = ElectricalCircuit(id: 'c', name: 'X', feedsPanelId: 'p2');
      expect(c.copyWith().feedsPanelId, 'p2');
      expect(c.copyWith(clearFeedsPanelId: true).feedsPanelId, isNull);
    });

    test(
        'clearBreakerOverrideA nulls breakerOverrideA; copyWith() alone preserves',
        () {
      const c = ElectricalCircuit(
        id: 'c',
        name: 'X',
        breakerOverrideA: Current(20),
      );
      expect(c.copyWith().breakerOverrideA!.amperes, 20);
      expect(c.copyWith(clearBreakerOverrideA: true).breakerOverrideA, isNull);
    });

    test(
        'clearCableOverrideMm2 nulls cableOverrideMm2; copyWith() alone preserves',
        () {
      const c = ElectricalCircuit(
        id: 'c',
        name: 'X',
        cableOverrideMm2: 4,
      );
      expect(c.copyWith().cableOverrideMm2, 4);
      expect(c.copyWith(clearCableOverrideMm2: true).cableOverrideMm2, isNull);
    });

    test(
        'clearGroupingCountOverride nulls groupingCountOverride; copyWith() alone preserves',
        () {
      const c = ElectricalCircuit(
        id: 'c',
        name: 'X',
        groupingCountOverride: 3,
      );
      expect(c.copyWith().groupingCountOverride, 3);
      expect(
        c.copyWith(clearGroupingCountOverride: true).groupingCountOverride,
        isNull,
      );
    });

    test(
        'clearPhaseOverride nulls phaseOverride; copyWith() alone preserves',
        () {
      const c = ElectricalCircuit(
        id: 'c',
        name: 'X',
        phaseOverride: PhaseLine.l2,
      );
      expect(c.copyWith().phaseOverride, PhaseLine.l2);
      expect(c.copyWith(clearPhaseOverride: true).phaseOverride, isNull);
    });

    test('clearLaying nulls laying; copyWith() alone preserves', () {
      const c = ElectricalCircuit(id: 'c', name: 'X', laying: 'ground');
      expect(c.copyWith().laying, 'ground');
      expect(c.copyWith(clearLaying: true).laying, isNull);
    });
  });

  group('ElectricalCircuit.fromJson tolerant feedsPanelId decode', () {
    test("an empty-string 'feedsPanelId' decodes to null (legacy sentinel)",
        () {
      final c = ElectricalCircuit.fromJson({
        'id': 'c',
        'name': 'Socket',
        'feedsPanelId': '',
      });
      expect(c.feedsPanelId, isNull);
      // Not a feeder kind ⇒ the empty-sentinel decode must not turn it into one.
      expect(c.isFeeder, isFalse);
    });

    test('a real feedsPanelId still decodes and marks isFeeder true', () {
      final c = ElectricalCircuit.fromJson({
        'id': 'c',
        'name': 'Feeder to LP-2',
        'feedsPanelId': 'panel-lp2',
      });
      expect(c.feedsPanelId, 'panel-lp2');
      expect(c.isFeeder, isTrue);
    });

    test('an absent feedsPanelId decodes as null', () {
      final c = ElectricalCircuit.fromJson({'id': 'c', 'name': 'X'});
      expect(c.feedsPanelId, isNull);
      expect(c.isFeeder, isFalse);
    });
  });

  test(
      'toJson/fromJson round-trips a normal feeder circuit unchanged '
      '(byte-identical for a real feedsPanelId)', () {
    const c = ElectricalCircuit(
      id: 'c1',
      name: 'Feeder to LP-2',
      loadKind: LoadKind.feeder,
      feedsPanelId: 'panel-lp2',
      breakerOverrideA: Current(63),
      cableOverrideMm2: 16,
      groupingCountOverride: 2,
      phaseOverride: PhaseLine.l1,
      laying: 'air',
    );
    final json = c.toJson();
    final back = ElectricalCircuit.fromJson(json);
    expect(back.feedsPanelId, 'panel-lp2');
    expect(back.isFeeder, isTrue);
    expect(back.breakerOverrideA!.amperes, 63);
    expect(back.cableOverrideMm2, 16);
    expect(back.groupingCountOverride, 2);
    expect(back.phaseOverride, PhaseLine.l1);
    expect(back.laying, 'air');
    // Round-tripping again is idempotent (the JSON shape itself is unchanged).
    expect(back.toJson(), json);
  });
}
