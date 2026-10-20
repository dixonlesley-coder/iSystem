// Round 49 — the phase-imbalance verdict and the sub-board R/S/T rotation
// share ONE objective (worst line, then spread) on EXACT line sums, and a
// mid-level board fed by imbalanced sub-boards rotates as a whole sub-tree.
//
//  * regression-rotation-vs-reducibility-objective /
//    elec-props-13-rotate-advice-raises-worst-phase — a 'Rotate R/S/T at …'
//    WARNING is raised only for a relabelling the engine's own objective
//    accepts (never one that raises the parent's worst line).
//  * elec-props-13-rounded-floor-phantom-unpin-warning — the floor compares
//    exact spreads, so a two-way board (one line always empty) is inherent.
//  * elec-props-13-three-level-tree-never-rotated — MDP -> SDB -> DB trees
//    are rotated at the SDB level, and the advice names the boards that hold
//    the single-phase ways.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

ElectricalCircuit _way(String id, double kw, {PhaseLine? pin}) =>
    ElectricalCircuit(
      id: id,
      name: id,
      loadKind: LoadKind.general,
      loadW: kw * 1000,
      cosPhi: 1,
      phases: 1,
      length: const Length(10),
      phaseOverride: pin,
    );

ElectricalCircuit _feeder(String id, String to) => ElectricalCircuit(
      id: id,
      name: 'to $to',
      loadKind: LoadKind.feeder,
      feedsPanelId: to,
      length: const Length(20),
    );

ElectricalPanel _board(String id, List<ElectricalCircuit> cs,
        {String? fedBy}) =>
    ElectricalPanel(
      id: id,
      name: id,
      system: ElectricalSystem.threePhase,
      voltage: const Voltage(400),
      sourceType: fedBy == null ? PanelSource.utility : PanelSource.feeder,
      fedByCircuitId: fedBy,
      circuits: cs,
    );

double _worst(PhaseBalanceResult b) => math.max(b.l1, math.max(b.l2, b.l3));

Iterable<ElectricalWarning> _phaseWarnings(
        ElectricalSystemResult s, String panelId) =>
    s.warnings
        .where((w) => w.panelId == panelId && w.code == 'phase-imbalance');

PhaseAssignment _rot(PhaseAssignment a, int r) =>
    a == PhaseAssignment.threePhase
        ? a
        : PhaseAssignment.values[(a.index + r) % 3];

PhaseLine _line(PhaseAssignment a) => PhaseLine.values[a.index];

/// [project] with the boards in [rotation] relabelled by their cyclic step
/// (pins re-pinned, the rest frozen through a prior) and every other board
/// frozen at its solved labels — the drawing an engineer gets by following a
/// 'Rotate R/S/T' instruction.
ElectricalSystemResult _frozen(ElectricalProject project,
    ElectricalSystemResult solved, Map<String, int> rotation) {
  final prior = <String, Map<String, PhaseAssignment>>{};
  final panels = <ElectricalPanel>[];
  for (final p in project.panels) {
    final r = rotation[p.id] ?? 0;
    final res = solved.panels[p.id]!;
    final phaseOf = {for (final c in res.circuits) c.circuitId: c.phase};
    prior[p.id] = {
      for (final e in phaseOf.entries) e.key: _rot(e.value, r),
    };
    panels.add(p.copyWith(circuits: [
      for (final c in p.circuits)
        c.phaseOverride == null
            ? c
            : c.copyWith(phaseOverride: _line(_rot(phaseOf[c.id]!, r))),
    ]));
  }
  return computeSystem(
      _p, ElectricalProject(id: project.id, name: project.name, panels: panels),
      priorAssignments: prior, phaseReassignThresholdA: 1e9);
}

void main() {
  group('the Rotate advice follows the engine objective (worst, spread)', () {
    test('DB-0 [3, 6] kW + DB-1 [5, 2] kW: no Rotate warning at the MDP', () {
      // At U0 = 230.9 V, cos phi 1: 3 kW = 13.0 A, 6 kW = 26.0 A,
      // 5 kW = 21.7 A, 2 kW = 8.7 A. The engine keeps
      //   MDP L1 26.0 / L2 34.6 / L3 8.7 A (worst 34.6 A, 112.1 %).
      // The three cyclic relabellings reaching 93.9 % all put 34.7 A on one
      // line (e.g. DB-1 rotated: 26.0 + 8.7 / 13.0 + 0 / 0 + 21.7) — a WORSE
      // worst line than the 34.6 A kept, which `rotateFedChildren` rightly
      // rejected; advising it would raise the incomer basis.
      final pr = ElectricalProject(id: 'p', name: 'P', panels: [
        _board('MDP', [_feeder('f0', 'DB0'), _feeder('f1', 'DB1')]),
        _board('DB0', [_way('a', 3), _way('b', 6)], fedBy: 'f0'),
        _board('DB1', [_way('c', 5), _way('d', 2)], fedBy: 'f1'),
      ]);
      final sys = computeSystem(_p, pr);
      final mdp = sys.panels['MDP']!;
      expect(_worst(mdp.phaseBalance), closeTo(34.6, 1e-9));
      expect(mdp.incomer.breaker.ratingA.amperes, 40);
      expect(_phaseWarnings(sys, 'MDP'), isEmpty);
      expect(mdp.phaseBalance.imbalanceReducible, isFalse);
    });

    test(
        'a relabel of the pinned board B would raise the worst line: '
        'only B\'s own Unpin warning remains', () {
      // A: 0.5 / 1 / 2 kW -> 2.2 / 8.7 / 4.3 A. B: 2 kW pinned L1, 2 kW,
      // 2 kW pinned L1 -> 17.3 / 8.7 / 0.0 A. MDP = 19.5 / 17.4 / 4.3 A
      // (worst 19.5 A, the 20 A rung). B's two rotations give the MDP
      // 2.2 + 0 / 8.7 + 17.3 / 4.3 + 8.7 = 2.2 / 26.0 / 13.0 A and
      // 2.2 + 8.7 / 8.7 + 0 / 4.3 + 17.3 = 10.9 / 8.7 / 21.6 A — worst 26.0
      // and 21.6 A (25 A rung): spread 93.9 % but never an improvement.
      final pr = ElectricalProject(id: 'p', name: 'P', panels: [
        _board('MDP', [_feeder('f0', 'A'), _feeder('f1', 'B')]),
        _board('A', [_way('a', .5), _way('b', 1), _way('c', 2)], fedBy: 'f0'),
        _board(
            'B',
            [
              _way('d', 2, pin: PhaseLine.l1),
              _way('e', 2),
              _way('f', 2, pin: PhaseLine.l1),
            ],
            fedBy: 'f1'),
      ]);
      final sys = computeSystem(_p, pr);
      final mdp = sys.panels['MDP']!;
      expect(_worst(mdp.phaseBalance), closeTo(19.5, 1e-9));
      expect(mdp.incomer.breaker.ratingA.amperes, 20);
      expect(_phaseWarnings(sys, 'MDP'), isEmpty);
      final b = _phaseWarnings(sys, 'B').toList();
      expect(b, hasLength(1));
      expect(b.single.message, contains('Unpin the 2 ways pinned'));
    });
  });

  group('exact floor (no rounding artefact)', () {
    test('0.5 kW + 1.0 kW pinned L2: inherent INFO, no stability claim', () {
      // Two ways on three lines always leave one line empty: the exact floor
      // is max - 0 = 4.33 A on an exact average (2.165 + 4.330) / 3 =
      // 2.165 A ⇒ exactly 200 %. The rounded figures (4.3 / 2.1667 =
      // 198.5 %) used to beat it by 1.5 pp > the 1 pp margin.
      for (final pin in [PhaseLine.l2, null]) {
        final sys = computeSystem(
            _p,
            ElectricalProject(id: 'p', name: 'P', panels: [
              _board('MDP', [_way('a', .5), _way('b', 1, pin: pin)]),
            ]));
        final b = sys.panels['MDP']!.phaseBalance;
        expect(b.imbalancePercent, 200.0);
        expect(_phaseWarnings(sys, 'MDP'), isEmpty);
        final info = sys.warnings
            .where((w) => w.code == 'phase-imbalance-inherent')
            .toList();
        expect(info, hasLength(1));
        expect(info.single.severity, WarningSeverity.info);
        expect(
            info.single.message, isNot(contains('labelled phases are kept')));
        expect(info.single.message, contains('200.0% is the best'));
      }
    });

    test('seeded sweep: <= 3-way boards never raise Unpin at the exact floor',
        () {
      // cos phi 1, one board voltage ⇒ current ∝ kW, so the exact floor is
      // brute-forced in kW over all 3^n assignments.
      final rnd = math.Random(4949);
      const kws = [0.5, 1.0, 1.5, 2.0, 3.0, 4.0];
      var atFloor = 0;
      for (var t = 0; t < 300; t++) {
        final n = 1 + rnd.nextInt(3);
        final ways = [
          for (var i = 0; i < n; i++)
            _way('w$i', kws[rnd.nextInt(kws.length)],
                pin: rnd.nextDouble() < 0.5
                    ? PhaseLine.values[rnd.nextInt(3)]
                    : null),
        ];
        final sys = computeSystem(
            _p,
            ElectricalProject(
                id: 'p', name: 'P', panels: [_board('MDP', ways)]));
        final res = sys.panels['MDP']!;
        final l = [0.0, 0.0, 0.0];
        for (final c in res.circuits) {
          final kw = ways.firstWhere((w) => w.id == c.circuitId).loadW;
          l[c.phase.index] += kw;
        }
        double spread(List<double> v) =>
            v.reduce(math.max) - v.reduce(math.min);
        var best = double.infinity;
        for (var code = 0; code < math.pow(3, n); code++) {
          final v = [0.0, 0.0, 0.0];
          var k = code;
          for (final w in ways) {
            v[k % 3] += w.loadW;
            k ~/= 3;
          }
          best = math.min(best, spread(v));
        }
        if ((spread(l) - best).abs() < 1e-9) {
          atFloor++;
          expect(_phaseWarnings(sys, 'MDP'), isEmpty,
              reason:
                  'trial $t: ${ways.map((w) => '${w.loadW}@${w.phaseOverride}')}');
        }
      }
      expect(atFloor, greaterThan(50));
    });
  });

  group('three-level trees rotate at the mid level', () {
    test('MDP -> S0..S2 -> D0..D2 (10 / 5 / 5 A each) reaches 20 / 20 / 20 A',
        () {
      // Each D_i: 2.31 / 1.155 / 1.155 kW at 230.9 V ⇒ 10 / 5 / 5 A.
      // Rotating S1's sub-tree one line and S2's two gives the MDP
      // 10 + 5 + 5 = 20 A on every line (the 20 A rung), 0 %.
      final pr = ElectricalProject(id: 'p', name: 'P', panels: [
        _board('MDP',
            [_feeder('f0', 'S0'), _feeder('f1', 'S1'), _feeder('f2', 'S2')]),
        for (var i = 0; i < 3; i++) ...[
          _board('S$i', [_feeder('g$i', 'D$i')], fedBy: 'f$i'),
          _board('D$i',
              [_way('x$i', 2.31), _way('y$i', 1.155), _way('z$i', 1.155)],
              fedBy: 'g$i'),
        ],
      ]);
      final sys = computeSystem(_p, pr, phaseReassignThresholdA: 1.0);
      final mdp = sys.panels['MDP']!.phaseBalance;
      expect(mdp.l1, closeTo(20.0, 1e-9));
      expect(mdp.l2, closeTo(20.0, 1e-9));
      expect(mdp.l3, closeTo(20.0, 1e-9));
      expect(sys.panels['MDP']!.incomer.breaker.ratingA.amperes, 20);
      expect(sys.warnings.where((w) => w.code == 'phase-imbalance'), isEmpty);
      // Every S_i still reads its D_i's lines exactly (a rotation, nothing
      // else): one 10 A line, two 5 A lines.
      for (var i = 0; i < 3; i++) {
        final s = sys.panels['S$i']!.phaseBalance;
        expect([s.l1, s.l2, s.l3]..sort(), [5.0, 5.0, 10.0]);
      }
    });

    test('seeded: the root worst line never exceeds the unrotated drawing', () {
      // 2- and 3-level trees, leaves with unpinned 1φ ways. The no-rotation
      // reference freezes every board at the labels a balancer gives it in
      // isolation (each leaf solved alone, rotation 0).
      final rnd = math.Random(4950);
      const kws = [0.5, 1.0, 2.0, 3.0, 5.0];
      var improved = 0;
      for (var t = 0; t < 60; t++) {
        final mids = 2 + rnd.nextInt(2);
        final threeLevel = rnd.nextBool();
        final panels = <ElectricalPanel>[];
        final rootFeeders = <ElectricalCircuit>[];
        final leaves = <String>[];
        for (var m = 0; m < mids; m++) {
          rootFeeders.add(_feeder('f$m', 'M$m'));
          List<ElectricalCircuit> leafWays(String id) => [
                for (var w = 0; w < 1 + rnd.nextInt(3); w++)
                  _way('${id}w$w', kws[rnd.nextInt(kws.length)]),
              ];
          if (threeLevel) {
            final n = 1 + rnd.nextInt(2);
            panels.add(_board(
                'M$m',
                [
                  for (var d = 0; d < n; d++) _feeder('g${m}_$d', 'D${m}_$d'),
                ],
                fedBy: 'f$m'));
            for (var d = 0; d < n; d++) {
              panels.add(
                  _board('D${m}_$d', leafWays('D${m}_$d'), fedBy: 'g${m}_$d'));
              leaves.add('D${m}_$d');
            }
          } else {
            panels.add(_board('M$m', leafWays('M$m'), fedBy: 'f$m'));
            leaves.add('M$m');
          }
        }
        final pr = ElectricalProject(
            id: 'p', name: 'P', panels: [_board('R', rootFeeders), ...panels]);
        final sys = computeSystem(_p, pr);
        // The unrotated reference: each leaf at the labels it takes alone.
        final prior = <String, Map<String, PhaseAssignment>>{};
        for (final id in leaves) {
          final alone = computeSystem(
              _p,
              ElectricalProject(id: 'a', name: 'A', panels: [
                _board(id, pr.panels.firstWhere((p) => p.id == id).circuits),
              ]));
          prior[id] = {
            for (final c in alone.panels[id]!.circuits) c.circuitId: c.phase,
          };
        }
        final ref = computeSystem(_p, pr,
            priorAssignments: prior, phaseReassignThresholdA: 1e9);
        final w = _worst(sys.panels['R']!.phaseBalance);
        final wRef = _worst(ref.panels['R']!.phaseBalance);
        expect(w, lessThanOrEqualTo(wRef + 0.05), reason: 'trial $t');
        if (w < wRef - 0.05) improved++;
      }
      expect(improved, greaterThan(0));
    });
  });

  test(
      'seeded property: a Rotate R/S/T warning names a relabelling that never '
      'raises the root worst line and cuts the imbalance by the margin', () {
    final rnd = math.Random(4848);
    const kws = [0.5, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0];
    var fired = 0;
    for (var t = 0; t < 300; t++) {
      final kids = 2 + rnd.nextInt(3);
      final prior = <String, Map<String, PhaseAssignment>>{};
      final panels = <ElectricalPanel>[];
      for (var i = 0; i < kids; i++) {
        final ways = <ElectricalCircuit>[];
        final pm = <String, PhaseAssignment>{};
        for (var w = 0; w < 1 + rnd.nextInt(3); w++) {
          final pinned = rnd.nextDouble() < 0.25;
          final id = 'd${i}w$w';
          ways.add(_way(id, kws[rnd.nextInt(kws.length)],
              pin: pinned ? PhaseLine.values[rnd.nextInt(3)] : null));
          if (!pinned && rnd.nextDouble() < 0.5) {
            pm[id] = PhaseAssignment.values[rnd.nextInt(3)];
          }
        }
        if (pm.isNotEmpty) prior['DB$i'] = pm;
        panels.add(_board('DB$i', ways, fedBy: 'f$i'));
      }
      final pr = ElectricalProject(id: 'p', name: 'P', panels: [
        _board('MDP', [for (var i = 0; i < kids; i++) _feeder('f$i', 'DB$i')]),
        ...panels,
      ]);
      final threshold = [0.0, 2.0, 5.0][rnd.nextInt(3)];
      final sys = computeSystem(_p, pr,
          priorAssignments: prior, phaseReassignThresholdA: threshold);
      final warn = _phaseWarnings(sys, 'MDP').toList();
      if (warn.isEmpty || !warn.single.message.contains('Rotate R/S/T')) {
        continue;
      }
      fired++;
      final named = [
        for (var i = 0; i < kids; i++)
          if (warn.single.message.contains('DB-$i') ||
              RegExp('\\bDB$i\\b').hasMatch(warn.single.message))
            'DB$i',
      ];
      expect(named, isNotEmpty);
      final mdp = sys.panels['MDP']!.phaseBalance;
      var ok = false;
      for (var code = 1; code < math.pow(3, named.length) && !ok; code++) {
        var c = code;
        final rot = <String, int>{};
        for (final id in named) {
          rot[id] = c % 3;
          c ~/= 3;
        }
        final f = _frozen(pr, sys, rot).panels['MDP']!.phaseBalance;
        ok = _worst(f) <= _worst(mdp) + 0.05 &&
            f.imbalancePercent <
                mdp.imbalancePercent -
                    kPhaseImbalanceReducibleMarginPercent +
                    0.15;
      }
      expect(ok, isTrue, reason: 'trial $t: ${warn.single.message}');
    }
    expect(fired, greaterThan(0));
  });
}
