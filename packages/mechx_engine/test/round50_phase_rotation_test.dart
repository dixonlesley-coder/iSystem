// Round 50 (elec-convergence-3-engine-own-rotation-counted-as-persisted-labels)
// — the sub-tree R/S/T rotation judges "labelled" on the DOCUMENT's persisted
// assignment, never on the relabels the same pass already wrote for a nested
// sub-tree. On a fresh document (no `assignedPhase`) the phase-stability
// threshold must therefore bite nowhere: threshold 1.0 A == threshold 0.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();
final _u0 = 400 / math.sqrt(3);

ElectricalCircuit _way(String id, double kw) => ElectricalCircuit(
      id: id,
      name: id,
      loadKind: LoadKind.general,
      loadW: kw * 1000,
      cosPhi: 1,
      phases: 1,
      length: const Length(10),
    );

ElectricalCircuit _feeder(String id, String to) => ElectricalCircuit(
      id: id,
      name: 'to $to',
      loadKind: LoadKind.feeder,
      feedsPanelId: to,
      length: const Length(20),
    );

ElectricalPanel _board(String id, List<ElectricalCircuit> cs,
        {String? fedBy, bool onePhase = false}) =>
    ElectricalPanel(
      id: id,
      name: id,
      system:
          onePhase ? ElectricalSystem.singlePhase : ElectricalSystem.threePhase,
      voltage: Voltage(onePhase ? _u0 : 400),
      sourceType: fedBy == null ? PanelSource.utility : PanelSource.feeder,
      fedByCircuitId: fedBy,
      circuits: cs,
    );

List<double> _lines(PhaseBalanceResult b) => [b.l1, b.l2, b.l3];

double _worst(PhaseBalanceResult b) => _lines(b).reduce(math.max);

ElectricalProject _fixture() => ElectricalProject(id: 'p', name: 'P', panels: [
      _board('MDP',
          [_feeder('m0', 'S0'), _feeder('m1', 'S1'), _feeder('m2', 'S2')]),
      _board('S0',
          [_feeder('s00', 'D00'), _feeder('s01', 'D01'), _way('s0w', 1.5)],
          fedBy: 'm0'),
      _board('D00', [_way('a', .3), _way('b', 1.5), _way('c', 1.2)],
          fedBy: 's00', onePhase: true),
      _board('D01', [_way('d', 1.2), _way('e', .5)],
          fedBy: 's01', onePhase: true),
      _board('S1',
          [_feeder('s10', 'D10'), _feeder('s11', 'D11'), _feeder('s12', 'D12')],
          fedBy: 'm1'),
      _board('D10', [_way('f', 1.5), _way('g', 2.0)], fedBy: 's10'),
      _board('D11', [_way('h', 1.2)], fedBy: 's11'),
      _board('D12', [_way('i', .5), _way('j', .9)],
          fedBy: 's12', onePhase: true),
      _board('S2', [_feeder('s20', 'D20'), _feeder('s21', 'D21')],
          fedBy: 'm2'),
      _board('D20', [_way('k', 1.2), _way('l', .5)], fedBy: 's20'),
      _board('D21', [_way('m', 1.5), _way('n', .3)], fedBy: 's21'),
    ]);

/// [project] with every single-phase way's solved line in [solved]
/// persisted as `assignedPhase` (what the store stamps).
ElectricalProject _stamped(
        ElectricalProject project, ElectricalSystemResult solved) =>
    ElectricalProject(id: project.id, name: project.name, panels: [
      for (final p in project.panels)
        p.copyWith(circuits: [
          for (final c in p.circuits) _stampOne(c, solved.panels[p.id]!),
        ]),
    ]);

ElectricalCircuit _stampOne(ElectricalCircuit c, ElectricalPanelResult r) {
  final hit = r.circuits.where((x) => x.circuitId == c.id);
  if (hit.isEmpty || hit.first.phase == PhaseAssignment.threePhase) return c;
  return c.copyWith(assignedPhase: PhaseLine.values[hit.first.phase.index]);
}

void main() {
  test(
      'fresh document: the stability threshold never refuses the engine\'s '
      'own sub-tree relabel (25 A MDP incomer, not 32 A)', () {
    // At U0 = 230.9 V, cos phi 1, every diversity 1 (kW -> A on U0):
    //   S0 = D00 3.0 kW (13.0 A) + D01 1.7 kW (7.4 A) + own 1.5 kW (6.5 A)
    //   S1 = {8.7, 6.5, 11.3} A, S2 = {6.5, 2.2, 6.5} A (in some order).
    // The cyclic relabelling S0 -> 13.0/7.4/6.5, S2 -> 2.2/6.5/6.5 keeps
    // every board's own worst line and gives the MDP
    //   13.0 + 8.7 + 2.2 = 23.9, 7.4 + 6.5 + 6.5 = 20.4,
    //   6.5 + 11.3 + 6.5 = 24.3 A — worst 24.3 A <= 25 A, the 25 A rung.
    // The un-relabelled MDP (21.7 / 21.7 / 25.2 A) needs the 32 A rung; the
    // 0.9 A gain is under the 1.0 A threshold, which must NOT bite because
    // the document carries no labels (the nested S0 / S2 rotations are the
    // engine's own in-pass choice).
    final pr = _fixture();
    final s0 = computeSystem(_p, pr);
    final s1 = computeSystem(_p, pr, phaseReassignThresholdA: 1.0);
    final m0 = s0.panels['MDP']!;
    final m1 = s1.panels['MDP']!;
    expect(_worst(m0.phaseBalance), lessThanOrEqualTo(25.0));
    expect(m0.incomer.breaker.ratingA.amperes, 25);
    expect(m1.incomer.breaker.ratingA.amperes, 25);
    final sorted = [..._lines(m1.phaseBalance)]..sort();
    expect(sorted[0], closeTo(20.4, 0.06));
    expect(sorted[1], closeTo(23.9, 0.06));
    expect(sorted[2], closeTo(24.3, 0.06));
    // Every board's balance is identical at threshold 0 and 1.0.
    for (final id in s0.panels.keys) {
      final a = _lines(s1.panels[id]!.phaseBalance);
      final b = _lines(s0.panels[id]!.phaseBalance);
      for (var i = 0; i < 3; i++) {
        expect(a[i], closeTo(b[i], 1e-9), reason: '$id line $i');
      }
    }
  });

  test('a LABELLED document keeps its persisted lines under the threshold',
      () {
    // Stamp the identity solve (nothing relabelled — threshold 1e9 freezes
    // the unseeded greedy) as the document's `assignedPhase`, then re-solve
    // at 1.0 A: the S0 / S2 relabel gains only 0.9 A < 1.0 A, so the
    // labelled sub-trees keep every persisted line.
    final pr = _fixture();
    final frozen = computeSystem(_p, pr, phaseReassignThresholdA: 1e9);
    final labelled = _stamped(pr, frozen);
    final again = computeSystem(_p, labelled, phaseReassignThresholdA: 1.0);
    for (final p in labelled.panels) {
      final res = again.panels[p.id]!;
      for (final c in p.circuits) {
        if (c.assignedPhase == null) continue;
        final r = res.circuits.firstWhere((x) => x.circuitId == c.id);
        expect(r.phase.index, c.assignedPhase!.index,
            reason: '${p.id}/${c.id}');
      }
    }
    // Re-solving the stamped document at its own threshold is a fixed point.
    for (final id in frozen.panels.keys) {
      final a = _lines(again.panels[id]!.phaseBalance);
      final b = _lines(frozen.panels[id]!.phaseBalance);
      for (var i = 0; i < 3; i++) {
        expect(a[i], closeTo(b[i], 1e-9), reason: '$id line $i');
      }
    }
  });
}
