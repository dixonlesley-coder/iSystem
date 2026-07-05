import 'package:mechx_engine/electrical/connectivity.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:test/test.dart';

/// A minimal panel with the given [id] and circuits.
ElectricalPanel _panel(String id, {List<ElectricalCircuit> circuits = const []}) =>
    ElectricalPanel(id: id, name: id, circuits: circuits);

/// A feeder circuit on the parent that feeds [childId].
ElectricalCircuit _feeder(String id, String childId) =>
    ElectricalCircuit(id: id, name: id, feedsPanelId: childId);

void main() {
  group('electricalConnectivityDefects', () {
    // A single root panel (the MDP) is fed by the incomer/source ⇒ never a
    // defect.
    test('a single panel is never a defect', () {
      final project = ElectricalProject(panels: [_panel('MDP')]);
      expect(electricalConnectivityDefects(project), isEmpty);
    });

    // A sub-panel with a feeder pointing to it (feedsPanelId == SP) is
    // connected ⇒ NOT flagged.
    test('a properly-fed sub-panel is NOT flagged', () {
      final project = ElectricalProject(panels: [
        _panel('MDP', circuits: [_feeder('c1', 'SP')]),
        _panel('SP'),
      ]);
      expect(electricalConnectivityDefects(project), isEmpty);
    });

    // A sub-panel with NO feeder anywhere (the MDP is the root, SP is floating)
    // IS flagged unfedPanel.
    test('an unfed sub-panel IS flagged unfedPanel', () {
      final project = ElectricalProject(panels: [
        _panel('MDP'),
        _panel('SP'),
      ]);
      final defects = electricalConnectivityDefects(project);
      expect(defects, hasLength(1));
      expect(defects.single.panelId, 'SP');
      expect(defects.single.kind,
          ElectricalConnectivityDefectKind.unfedPanel);
    });

    // Two floating sub-panels alongside a fed one: the first unfed panel (MDP)
    // is THE root; the two others are unfed defects, sorted by id.
    test('multiple floating panels are flagged, root excluded, sorted', () {
      final project = ElectricalProject(panels: [
        _panel('MDP', circuits: [_feeder('c1', 'SP1')]),
        _panel('SP1'),
        _panel('SP3'),
        _panel('SP2'),
      ]);
      final ids = electricalConnectivityDefects(project)
          .map((d) => d.panelId)
          .toList();
      expect(ids, ['SP2', 'SP3']);
    });

    // M1: a legitimate dual-source design has MORE than one root (a normal MDP +
    // an emergency MDP, each fed by the source spine, neither by a feeder).
    // compute.dart supports multiple roots, so the check must NOT flag the
    // second root when the project models a second supply (dualTransformer /
    // sources) or the board is `essential` (genset-backed).
    test('a dual-source design (multiple roots) is NOT flagged', () {
      // Two roots, no feeder between them, but a second transformer is modelled.
      final dualTx = ElectricalProject(
        panels: [_panel('MDP'), _panel('EMDP')],
        dualTransformer: true,
      );
      expect(electricalConnectivityDefects(dualTx), isEmpty);

      // An essential (genset-backed) second root is a legitimate source-fed
      // board, even without the project-level multi-source flags.
      final essentialRoot = ElectricalProject(panels: [
        _panel('MDP'),
        const ElectricalPanel(id: 'EMDP', name: 'EMDP', essential: true),
      ]);
      expect(electricalConnectivityDefects(essentialRoot), isEmpty);
    });
  });
}
