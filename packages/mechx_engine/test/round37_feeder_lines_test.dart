// Round 37 (2026-10-18) — electrical-sim-4-feeder-balanced-phase-hides-fed-
// board-imbalance.
//
// A 3φ feeder carries its fed board's OWN line currents into the parent's
// phase balance (and sizes on the worst one), so drawing the same loads on a
// sub-board instead of directly on the MDP never hides the worst phase from
// the parent incomer, the recommended daya, the genset or the service judge.
//
// Derivation: two 1φ 7 kW heaters (cos φ 1) at the 231 V phase voltage draw
// 7000 / 231 = 30.30 A each, one on L1 and one on L2 ⇒ lines 30.3 / 30.3 / 0.
// The balanced feeder Ib the old code used is 14 000 / (√3·400) = 20.2 A on
// every line. Incomer: first rung ≥ 30.3 A = 32 A (20.2 A gave 25 A). A
// declared 16.5 kVA = 16 500 / (√3·400) = 23.8 A < 30.3 A ⇒
// service-capacity-below-demand.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

ElectricalCircuit _heater1(String id) => ElectricalCircuit(
      id: id,
      name: 'Heater $id',
      loadKind: LoadKind.heating,
      loadW: 7000,
      cosPhi: 1.0,
      phases: 1,
      length: const Length(10),
    );

ElectricalProject _direct({ApparentPower? capacity}) => ElectricalProject(
      supplyCapacityVa: capacity,
      panels: [
        ElectricalPanel(
            id: 'mdp',
            name: 'MDP',
            circuits: [_heater1('a'), _heater1('b')]),
      ],
    );

ElectricalProject _sub({ApparentPower? capacity}) => ElectricalProject(
      supplyCapacityVa: capacity,
      panels: [
        const ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
          ElectricalCircuit(
              id: 'f',
              name: 'DB',
              loadKind: LoadKind.feeder,
              feedsPanelId: 'db',
              length: Length(10)),
        ]),
        ElectricalPanel(
            id: 'db', name: 'DB', circuits: [_heater1('a'), _heater1('b')]),
      ],
    );

List<double> _lines(ElectricalPanelResult r) =>
    [r.phaseBalance.l1, r.phaseBalance.l2, r.phaseBalance.l3]..sort();

void main() {
  test('direct drawing (reference): MDP 30.3 / 30.3 / 0, incomer 32 A', () {
    final r = computeSystem(_p, _direct()).panels['mdp']!;
    expect(_lines(r), [0, 30.3, 30.3]);
    expect(r.incomer.breaker.ratingA.amperes, 32);
  });

  test('the same heaters on a 3φ sub-board: MDP sees 30.3 / 30.3 / 0, '
      'incomer 32 A (was 20.2 x 3 and 25 A)', () {
    final sys = computeSystem(_p, _sub());
    final mdp = sys.panels['mdp']!;
    expect(_lines(mdp), [0, 30.3, 30.3]);
    expect(mdp.incomer.breaker.ratingA.amperes, 32);
    // The feeder itself carries the worst line, and is never below it.
    final f = mdp.circuits.single;
    expect(f.designCurrent.amperes, closeTo(30.3, 1e-9));
    expect(f.breaker.ratingA.amperes, greaterThanOrEqualTo(30.3));
    expect(sys.warnings.map((w) => w.code),
        isNot(contains('feeder-below-fed-demand')));
  });

  test('a declared 16.5 kVA (23.8 A) raises service-capacity-below-demand in '
      'both drawings', () {
    expect(16500 / (math.sqrt(3) * 400), closeTo(23.8, 0.05));
    for (final p in [
      _direct(capacity: const ApparentPower(16500)),
      _sub(capacity: const ApparentPower(16500)),
    ]) {
      final sys = computeSystem(_p, p);
      expect(sys.warnings.map((w) => w.code),
          contains('service-capacity-below-demand'));
    }
  });

  test('a balanced (3φ-only) sub-board is byte-identical: no line map', () {
    // 3 x 10 kW 3φ heaters ⇒ 14.4 A on every line; the feeder keeps its
    // balanced Ib and the MDP lines stay equal.
    final p = ElectricalProject(panels: [
      const ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
        ElectricalCircuit(
            id: 'f',
            name: 'DB',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'db',
            length: Length(10)),
      ]),
      ElectricalPanel(id: 'db', name: 'DB', circuits: [
        for (var i = 0; i < 3; i++)
          ElectricalCircuit(
              id: 'h$i',
              name: 'h$i',
              loadKind: LoadKind.heating,
              loadW: 10000,
              cosPhi: 1,
              phases: 3,
              length: const Length(10)),
      ]),
    ]);
    final mdp = computeSystem(_p, p).panels['mdp']!;
    expect(mdp.phaseBalance.l1, mdp.phaseBalance.l2);
    expect(mdp.phaseBalance.l2, mdp.phaseBalance.l3);
    // 30 000 / (√3·400) = 43.3 A
    expect(mdp.circuits.single.designCurrent.amperes, closeTo(43.3, 1e-9));
  });

  test('seeded property: moving a 3φ board\'s single-phase ways onto a '
      'sub-board never lowers the MDP worst phase below the direct drawing', () {
    final rng = math.Random(737);
    for (var trial = 0; trial < 60; trial++) {
      final n = 1 + rng.nextInt(6);
      final ways = [
        for (var i = 0; i < n; i++)
          ElectricalCircuit(
            id: 'w$i',
            name: 'w$i',
            loadKind: LoadKind.heating,
            loadW: 500.0 + rng.nextInt(60) * 100,
            cosPhi: 1,
            phases: 1,
            length: const Length(10),
          ),
      ];
      final direct = computeSystem(_p,
              ElectricalProject(panels: [
                ElectricalPanel(id: 'mdp', name: 'MDP', circuits: ways)
              ]))
          .panels['mdp']!;
      final sub = computeSystem(
              _p,
              ElectricalProject(panels: [
                const ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
                  ElectricalCircuit(
                      id: 'f',
                      name: 'DB',
                      loadKind: LoadKind.feeder,
                      feedsPanelId: 'db',
                      length: Length(10)),
                ]),
                ElectricalPanel(id: 'db', name: 'DB', circuits: ways),
              ]))
          .panels['mdp']!;
      double worst(ElectricalPanelResult r) => math.max(
          r.phaseBalance.l1, math.max(r.phaseBalance.l2, r.phaseBalance.l3));
      // The sub-board balances its own ways exactly as the MDP did, so the
      // MDP's worst phase is the same figure (to the 0.1 A carry).
      expect(worst(sub), closeTo(worst(direct), 0.05 + 1e-9),
          reason: '${ways.map((w) => w.loadW)}');
      expect(sub.incomer.breaker.ratingA.amperes,
          greaterThanOrEqualTo(direct.incomer.breaker.ratingA.amperes),
          reason: '${ways.map((w) => w.loadW)}');
    }
  });
}
