import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/topology.dart';
import 'package:test/test.dart';

void main() {
  group('sanitizeFeederTopology', () {
    test('dangling feeder way dropped', () {
      // Feeder circuit targeting a non-existent panel should be removed.
      final circuits = [
        const ElectricalCircuit(
          id: 'c1',
          name: 'Feeder to MDP',
          feedsPanelId: 'non-existent-panel',
        ),
      ];
      final panel = ElectricalPanel(
        id: 'lp1',
        name: 'Load Panel 1',
        circuits: circuits,
      );

      final result = sanitizeFeederTopology([panel]);

      expect(result, isNotNull);
      expect(result.length, 1);
      expect(result[0].id, 'lp1');
      // The dangling feeder should be removed.
      expect(result[0].circuits.length, 0);
    });

    test('empty string target dropped', () {
      // Feeder circuit with empty-string target should be removed.
      final circuits = [
        const ElectricalCircuit(
          id: 'c1',
          name: 'Bad Feeder',
          feedsPanelId: '',
        ),
      ];
      final panel = ElectricalPanel(
        id: 'lp1',
        name: 'Load Panel 1',
        circuits: circuits,
      );

      final result = sanitizeFeederTopology([panel]);

      expect(result[0].circuits.length, 0);
    });

    test('orphaned back-pointer cleared', () {
      // Panel with fedByCircuitId pointing to a non-existent circuit should
      // have the back-pointer cleared and sourceType reset to utility.
      const panel = ElectricalPanel(
        id: 'lp1',
        name: 'Load Panel 1',
        sourceType: PanelSource.feeder,
        fedByCircuitId: 'non-existent-circuit',
      );

      final result = sanitizeFeederTopology([panel]);

      expect(result[0].sourceType, PanelSource.utility);
      expect(result[0].fedByCircuitId, isNull);
    });

    test('mismatched back-pointer repaired to real feeder', () {
      // Panel is targeted by a feeder, but the back-pointer is wrong or null.
      // Should be repaired to point to the correct feeder.
      final mutableCircuits = <ElectricalCircuit>[];
      mutableCircuits.add(
        const ElectricalCircuit(
          id: 'c1',
          name: 'Feeder to LP1',
          feedsPanelId: 'lp1',
        ),
      );
      final mdp = ElectricalPanel(
        id: 'mdp',
        name: 'Main Panel',
        circuits: mutableCircuits,
      );

      // LP1 has a mismatched fedByCircuitId (points to a non-existent circuit).
      const lp1 = ElectricalPanel(
        id: 'lp1',
        name: 'Load Panel 1',
        sourceType: PanelSource.feeder,
        fedByCircuitId: 'wrong-circuit-id',
      );

      final result = sanitizeFeederTopology([mdp, lp1]);

      // Find LP1 in the result.
      final resultLp1 = result.firstWhere((p) => p.id == 'lp1');
      expect(resultLp1.sourceType, PanelSource.feeder);
      expect(resultLp1.fedByCircuitId, 'c1');
    });

    test('healthy 3-panel tree returns identical list', () {
      // A well-formed feeder tree should return the same list instance.
      final mutableCircuitsMdp = <ElectricalCircuit>[];
      mutableCircuitsMdp.add(
        const ElectricalCircuit(
          id: 'c-mdp-lp1',
          name: 'Feeder to LP1',
          feedsPanelId: 'lp1',
        ),
      );
      mutableCircuitsMdp.add(
        const ElectricalCircuit(
          id: 'c-mdp-lp2',
          name: 'Feeder to LP2',
          feedsPanelId: 'lp2',
        ),
      );
      final mdp = ElectricalPanel(
        id: 'mdp',
        name: 'Main Panel',
        circuits: mutableCircuitsMdp,
      );

      const lp1 = ElectricalPanel(
        id: 'lp1',
        name: 'Load Panel 1',
        sourceType: PanelSource.feeder,
        fedByCircuitId: 'c-mdp-lp1',
      );

      const lp2 = ElectricalPanel(
        id: 'lp2',
        name: 'Load Panel 2',
        sourceType: PanelSource.feeder,
        fedByCircuitId: 'c-mdp-lp2',
      );

      final input = [mdp, lp1, lp2];
      final result = sanitizeFeederTopology(input);

      // Should return the same list instance (no changes needed).
      expect(identical(result, input), true);
    });

    test('idempotent: sanitize(sanitize(x)) == sanitize(x)', () {
      // Applying sanitizeFeederTopology twice should give the same result
      // (structural equality).
      final circuits = [
        const ElectricalCircuit(
          id: 'c1',
          name: 'Feeder to LP1',
          feedsPanelId: 'lp1',
        ),
      ];
      final mdp = ElectricalPanel(
        id: 'mdp',
        name: 'Main Panel',
        circuits: circuits,
      );

      const lp1 = ElectricalPanel(
        id: 'lp1',
        name: 'Load Panel 1',
        sourceType: PanelSource.utility, // Wrong sourceType initially.
        fedByCircuitId: null,
      );

      final input = [mdp, lp1];
      final result1 = sanitizeFeederTopology(input);
      final result2 = sanitizeFeederTopology(result1);

      // Both results should be structurally identical.
      expect(result2.length, result1.length);
      for (int i = 0; i < result1.length; i++) {
        expect(result2[i].id, result1[i].id);
        expect(result2[i].sourceType, result1[i].sourceType);
        expect(result2[i].fedByCircuitId, result1[i].fedByCircuitId);
        expect(result2[i].circuits.length, result1[i].circuits.length);
        for (int j = 0; j < result1[i].circuits.length; j++) {
          expect(result2[i].circuits[j].id, result1[i].circuits[j].id);
          expect(
            result2[i].circuits[j].feedsPanelId,
            result1[i].circuits[j].feedsPanelId,
          );
        }
      }

      // Second application should return the same list instance (already clean).
      expect(identical(result1, result2), true);
    });

    test('multiple feeders targeting one panel leaves panel unchanged', () {
      // If a panel is targeted by more than one feeder, do not auto-repair
      // the back-pointer (ambiguous case). The panel's existing back-pointer
      // is honored as-is (if valid) or cleared if it points to a wrong circuit.
      final circuits1 = [
        const ElectricalCircuit(
          id: 'c1',
          name: 'Feeder to LP1',
          feedsPanelId: 'lp1',
        ),
      ];
      final mdp = ElectricalPanel(
        id: 'mdp',
        name: 'Main Panel',
        circuits: circuits1,
      );

      final circuits2 = [
        const ElectricalCircuit(
          id: 'c2',
          name: 'Another Feeder to LP1',
          feedsPanelId: 'lp1',
        ),
      ];
      final lp2 = ElectricalPanel(
        id: 'lp2',
        name: 'Load Panel 2',
        circuits: circuits2,
      );

      const lp1 = ElectricalPanel(
        id: 'lp1',
        name: 'Load Panel 1',
        sourceType: PanelSource.feeder,
        fedByCircuitId: 'c1', // Pointing to one of the two feeders.
      );

      final input = [mdp, lp2, lp1];
      final result = sanitizeFeederTopology(input);

      final resultLp1 = result.firstWhere((p) => p.id == 'lp1');
      // Should keep the existing valid back-pointer (one of the two feeders).
      expect(resultLp1.sourceType, PanelSource.feeder);
      expect(resultLp1.fedByCircuitId, 'c1');
    });

    test('null target feeder is kept (non-feeder circuit)', () {
      // A circuit with feedsPanelId == null is not a feeder, so it should
      // be kept even if it has no target.
      final circuits = [
        const ElectricalCircuit(
          id: 'c1',
          name: 'Regular Circuit',
          feedsPanelId: null,
        ),
      ];
      final panel = ElectricalPanel(
        id: 'lp1',
        name: 'Load Panel 1',
        circuits: circuits,
      );

      final result = sanitizeFeederTopology([panel]);

      expect(result[0].circuits.length, 1);
      expect(result[0].circuits[0].id, 'c1');
    });

    test('empty panel list', () {
      final result = sanitizeFeederTopology([]);
      expect(result, isEmpty);
    });

    test('panel with no circuits', () {
      const panel = ElectricalPanel(
        id: 'lp1',
        name: 'Load Panel 1',
      );

      final result = sanitizeFeederTopology([panel]);

      expect(result.length, 1);
      expect(result[0].id, 'lp1');
      expect(result[0].circuits, isEmpty);
    });

    test('removes feeder and clears back-pointer in one pass', () {
      // A feeder targeting a non-existent panel is removed, and that panel's
      // back-pointer (if it was pointing to that feeder) should be cleared.
      final circuits = [
        const ElectricalCircuit(
          id: 'c1',
          name: 'Feeder to non-existent',
          feedsPanelId: 'non-existent',
        ),
      ];
      final mdp = ElectricalPanel(
        id: 'mdp',
        name: 'Main Panel',
        circuits: circuits,
      );

      const lp1 = ElectricalPanel(
        id: 'lp1',
        name: 'Load Panel 1',
        sourceType: PanelSource.feeder,
        fedByCircuitId: 'c1',
      );

      final result = sanitizeFeederTopology([mdp, lp1]);

      // MDP's feeder should be removed.
      final resultMdp = result.firstWhere((p) => p.id == 'mdp');
      expect(resultMdp.circuits, isEmpty);

      // LP1's back-pointer should be cleared (the feeder it pointed to is gone).
      final resultLp1 = result.firstWhere((p) => p.id == 'lp1');
      expect(resultLp1.sourceType, PanelSource.utility);
      expect(resultLp1.fedByCircuitId, isNull);
    });

    test('preserves unchanged panels as same instances', () {
      // When a panel is unchanged, it should be the same instance in the result.
      final unchangedCircuits = [
        const ElectricalCircuit(
          id: 'c1',
          name: 'Regular Circuit',
        ),
      ];
      final unchangedPanel = ElectricalPanel(
        id: 'lp1',
        name: 'Unchanged Panel',
        circuits: unchangedCircuits,
      );

      final changedCircuits = [
        const ElectricalCircuit(
          id: 'c2',
          name: 'Bad Feeder',
          feedsPanelId: '', // Will be removed.
        ),
      ];
      final changedPanel = ElectricalPanel(
        id: 'lp2',
        name: 'Panel to Change',
        circuits: changedCircuits,
      );

      final input = [unchangedPanel, changedPanel];
      final result = sanitizeFeederTopology(input);

      // The list was changed, so it's a new instance.
      expect(identical(result, input), false);

      // But unchangedPanel should still be the same instance.
      final resultUnchanged = result.firstWhere((p) => p.id == 'lp1');
      expect(identical(resultUnchanged, unchangedPanel), true);
    });

    test('complex multi-level hierarchy', () {
      // MDP -> LP1 -> SP1 (3-level feeder tree)
      final mdpCircuits = [
        const ElectricalCircuit(
          id: 'c-mdp-lp1',
          name: 'MDP -> LP1',
          feedsPanelId: 'lp1',
        ),
      ];
      final mdp = ElectricalPanel(
        id: 'mdp',
        name: 'Main Panel',
        circuits: mdpCircuits,
      );

      final lp1Circuits = [
        const ElectricalCircuit(
          id: 'c-lp1-sp1',
          name: 'LP1 -> SP1',
          feedsPanelId: 'sp1',
        ),
      ];
      final lp1 = ElectricalPanel(
        id: 'lp1',
        name: 'Load Panel 1',
        sourceType: PanelSource.feeder,
        fedByCircuitId: 'c-mdp-lp1',
        circuits: lp1Circuits,
      );

      const sp1 = ElectricalPanel(
        id: 'sp1',
        name: 'Sub Panel 1',
        sourceType: PanelSource.feeder,
        fedByCircuitId: 'c-lp1-sp1',
      );

      final input = [mdp, lp1, sp1];
      final result = sanitizeFeederTopology(input);

      // All back-pointers should be correct and valid.
      final resultLp1 = result.firstWhere((p) => p.id == 'lp1');
      expect(resultLp1.fedByCircuitId, 'c-mdp-lp1');
      expect(resultLp1.sourceType, PanelSource.feeder);

      final resultSp1 = result.firstWhere((p) => p.id == 'sp1');
      expect(resultSp1.fedByCircuitId, 'c-lp1-sp1');
      expect(resultSp1.sourceType, PanelSource.feeder);

      // Well-formed, should return same list.
      expect(identical(result, input), true);
    });

    test('feeder circuit with non-existent target is removed', () {
      // Multiple circuits, one valid and one invalid.
      final circuits = [
        const ElectricalCircuit(
          id: 'c1',
          name: 'Valid feeder',
          feedsPanelId: 'lp1',
        ),
        const ElectricalCircuit(
          id: 'c2',
          name: 'Invalid feeder',
          feedsPanelId: 'non-existent',
        ),
        const ElectricalCircuit(
          id: 'c3',
          name: 'Regular circuit',
          feedsPanelId: null,
        ),
      ];
      final mdp = ElectricalPanel(
        id: 'mdp',
        name: 'Main Panel',
        circuits: circuits,
      );

      const lp1 = ElectricalPanel(
        id: 'lp1',
        name: 'Load Panel 1',
      );

      final result = sanitizeFeederTopology([mdp, lp1]);

      final resultMdp = result.firstWhere((p) => p.id == 'mdp');
      // Should have 2 circuits: valid feeder (c1) and regular (c3).
      expect(resultMdp.circuits.length, 2);
      expect(
        resultMdp.circuits.map((c) => c.id).toList(),
        containsAll(['c1', 'c3']),
      );
      expect(
        resultMdp.circuits.map((c) => c.id).toList(),
        isNot(contains('c2')),
      );
    });
  });
}
