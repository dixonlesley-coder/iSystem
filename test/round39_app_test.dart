// Round 39 (2026-10-18) — electrical store regressions.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/units.dart';

ElectricalCircuit _w(
  String id,
  LoadKind k, {
  double loadW = 0,
  double? motorKw,
  int? phases,
}) => ElectricalCircuit(
  id: id,
  name: id,
  loadKind: k,
  loadW: loadW,
  motorKw: motorKw,
  phases: phases,
  cosPhi: 0.85,
  length: const Length(10),
);

ElectricalProject _project(List<ElectricalCircuit> ways) => ElectricalProject(
  id: 'p',
  name: 'P',
  panels: [ElectricalPanel(id: 'mdp', name: 'MDP', circuits: ways)],
);

ElectricalPanel _mdp(ProviderContainer c) =>
    c.read(electricalProjectProvider).panels.firstWhere((p) => p.id == 'mdp');

double _demand(ProviderContainer c) =>
    c.read(electricalResultProvider).panels['mdp']!.demandW;

void main() {
  group('regression-detargeted-feeder-copy-keeps-overrides', () {
    test('a duplicated feeder becomes a plain Spare with no overrides', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);
      ctrl.setProject(
        ElectricalProject(
          id: 'p',
          name: 'P',
          panels: [
            ElectricalPanel(
              id: 'mdp',
              name: 'MDP',
              circuits: [
                const ElectricalCircuit(
                  id: 'f',
                  name: 'to SDP',
                  loadKind: LoadKind.feeder,
                  feedsPanelId: 'sdp',
                  length: Length(20),
                  breakerOverrideA: Current(250),
                  cableOverrideMm2: 120,
                ),
                _w('l', LoadKind.lighting, loadW: 1000, phases: 1),
              ],
            ),
            const ElectricalPanel(
              id: 'sdp',
              name: 'SDP',
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'f',
              circuits: [],
            ),
          ],
        ),
      );
      ctrl.duplicateCircuit('mdp', 'f');
      final spare = _mdp(
        c,
      ).circuits.firstWhere((w) => w.loadKind == LoadKind.spare);
      expect(spare.name, 'Spare');
      expect(spare.feedsPanelId, isNull);
      expect(spare.breakerOverrideA, isNull);
      expect(spare.cableOverrideMm2, isNull);
      final sys = c.read(electricalResultProvider);
      final r = sys.panels['mdp']!.circuits.firstWhere(
        (x) => x.circuitId == spare.id,
      );
      // Sized like a palette spare (no load) — never the copied 250 A.
      expect(r.breaker.ratingA.amperes, lessThan(250));
      expect(
        sys.warnings.where(
          (w) =>
              w.code == 'outgoing-exceeds-incomer' &&
              w.circuitId == spare.id &&
              w.severity == WarningSeverity.warning,
        ),
        isEmpty,
      );
    });
  });

  group('elec-ui-journeys-2-merge-drop-loses-load', () {
    // pump 7.5 kW shaft, lighting 1000 W, capacitor 20 kvar:
    //   demand = 7500 / 0.88 + 1000 = 9522.7 W (the capacitor draws none).
    final ways = [
      _w('pump', LoadKind.pump, motorKw: 7.5, phases: 3),
      _w('light', LoadKind.lighting, loadW: 1000, phases: 1),
      _w('cap', LoadKind.capacitor, loadW: 20000, phases: 3),
    ];
    const before = 7500 / kAssumedMotorEfficiency + 1000;

    ProviderContainer seeded() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(electricalProjectProvider.notifier).setProject(_project(ways));
      return c;
    }

    test('premise', () {
      expect(_demand(seeded()), closeTo(before, 0.5));
    });

    test('pump onto lighting keeps the board demand (input W carried)', () {
      final c = seeded();
      c
          .read(electricalProjectProvider.notifier)
          .mergeCircuit('mdp', 'pump', 'light');
      // The 1ph lighting target cannot take a 3ph machine -> refused; the
      // demand is unchanged either way.
      expect(_demand(c), closeTo(before, 0.5));
    });

    test('a 1ph motor onto lighting adds its electrical input W', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c
          .read(electricalProjectProvider.notifier)
          .setProject(
            _project([
              _w('m', LoadKind.motor, motorKw: 1.1, phases: 1),
              _w('light', LoadKind.lighting, loadW: 1000, phases: 1),
            ]),
          );
      final b = _demand(c);
      c
          .read(electricalProjectProvider.notifier)
          .mergeCircuit('mdp', 'm', 'light');
      final merged = _mdp(c).circuits.single;
      expect(merged.id, 'light');
      expect(merged.motorKw, isNull);
      expect(
        merged.loadW,
        closeTo(1000 + 1100 / kAssumedMotorEfficiency, 1e-9),
      );
      expect(_demand(c), closeTo(b, 0.5));
    });

    test('lighting onto pump / capacitor is refused (demand unchanged)', () {
      final c = seeded();
      final ctrl = c.read(electricalProjectProvider.notifier);
      ctrl.mergeCircuit('mdp', 'light', 'pump');
      ctrl.mergeCircuit('mdp', 'light', 'cap');
      ctrl.mergeCircuit('mdp', 'cap', 'light');
      expect(_mdp(c).circuits, hasLength(3));
      expect(_demand(c), closeTo(before, 0.5));
    });

    test('mergedLoadWay carries life-safety', () {
      final m = ElectricalProjectController.mergedLoadWay(
        _w('a', LoadKind.general, loadW: 100).copyWith(lifeSafety: true),
        _w('b', LoadKind.general, loadW: 200),
      );
      expect(m!.lifeSafety, isTrue);
      expect(m.loadW, 300);
    });
  });
}
