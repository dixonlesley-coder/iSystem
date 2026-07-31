import 'package:mechx_engine/electrical/connectivity.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
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
    // second root of a DECLARED dual-transformer service.
    test('a dual-transformer service (2 roots) is NOT flagged', () {
      // Two roots, no feeder between them, but a second transformer is modelled:
      // MDP = the primary root, EMDP = the second LV main the TX rule allows.
      final dualTx = ElectricalProject(
        panels: [_panel('MDP'), _panel('EMDP')],
        dualTransformer: true,
      );
      expect(electricalConnectivityDefects(dualTx), isEmpty);
    });

    // H2 — the dual-transformer allowance is ONE extra main, not "any number of
    // roots": two LV mains are expected, a THIRD floating board is still a
    // forgotten feeder. MDP (primary) + SP1 (the TX allowance) are clean; SP2 is
    // the defect.
    test('a THIRD root under dualTransformer IS still flagged', () {
      final project = ElectricalProject(
        panels: [_panel('MDP'), _panel('SP1'), _panel('SP2')],
        dualTransformer: true,
      );
      final ids =
          electricalConnectivityDefects(project).map((d) => d.panelId).toList();
      expect(ids, ['SP2']);
    });

    // H2 — an `essential` board is a genset-backed emergency main, so it is a
    // legitimate root ONLY when a generator is actually declared. With the
    // genset present the essential EMDP is clean...
    test('an essential root with a declared genset is NOT flagged', () {
      final project = ElectricalProject(
        panels: [
          _panel('MDP'),
          const ElectricalPanel(id: 'EMDP', name: 'EMDP', essential: true),
        ],
        sources: const ElectricalSources(generator: GeneratorSource()),
      );
      expect(electricalConnectivityDefects(project), isEmpty);
    });

    // ...but the genset legitimises the ESSENTIAL board only. A second, ordinary
    // floating board in the same project has no supply of its own ⇒ still a
    // defect (before H2 the mere presence of `sources` silenced the whole
    // project).
    test('a NON-essential extra root alongside a genset IS flagged', () {
      final project = ElectricalProject(
        panels: [
          _panel('MDP'),
          const ElectricalPanel(id: 'EMDP', name: 'EMDP', essential: true),
          _panel('SP'),
        ],
        sources: const ElectricalSources(generator: GeneratorSource()),
      );
      final ids =
          electricalConnectivityDefects(project).map((d) => d.panelId).toList();
      expect(ids, ['SP']);
    });

    // H2 — an essential board with NO generator declared is not source-fed by
    // anything: the `essential` flag alone is a colour/priority designation, not
    // a supply. It must be fed by a feeder like any other board.
    test('an essential root with NO declared genset IS flagged', () {
      final project = ElectricalProject(panels: [
        _panel('MDP'),
        const ElectricalPanel(id: 'EMDP', name: 'EMDP', essential: true),
      ]);
      final ids =
          electricalConnectivityDefects(project).map((d) => d.panelId).toList();
      expect(ids, ['EMDP']);
    });

    // H2 — the today-silent case: declaring a rooftop PV array (or a battery)
    // used to switch the check off PROJECT-WIDE. Neither feeds a floating board
    // — both attach to the LV bus of an existing one — so the floating SP is
    // reported exactly as in the single-supply case.
    test('a declared SOLAR array does NOT legitimise a floating sub-board', () {
      final project = ElectricalProject(
        panels: [_panel('MDP'), _panel('SP')],
        sources: const ElectricalSources(solar: SolarSource(panels: 12)),
      );
      final ids =
          electricalConnectivityDefects(project).map((d) => d.panelId).toList();
      expect(ids, ['SP']);
    });

    test('a declared BATTERY does NOT legitimise a floating sub-board', () {
      final project = ElectricalProject(
        panels: [_panel('MDP'), _panel('SP')],
        sources: const ElectricalSources(
          battery: BatterySource(autonomyHours: 4),
        ),
      );
      final ids =
          electricalConnectivityDefects(project).map((d) => d.panelId).toList();
      expect(ids, ['SP']);
    });
  });
}
