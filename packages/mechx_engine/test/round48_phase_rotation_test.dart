// Round 48 — sub-board R/S/T rotation is searched on the PARENT's solved
// balance, its own single-phase ways included
// (elec-convergence-2-parent-rotation-ignores-own-singles).
import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

ElectricalCircuit _way(String id, double kw) => ElectricalCircuit(
      id: id,
      name: id,
      loadKind: LoadKind.general,
      loadW: kw * 1000,
      cosPhi: 1,
      phases: 1,
      length: const Length(10),
    );

/// MDP (3φ 400 V) feeding DB-i with single-phase [kids][i] kW ways, plus the
/// MDP's own single-phase [own] kW ways. [reverse] reverses every circuit
/// list and the panel list (the order-invariance check).
ElectricalProject _tree(List<List<double>> kids, List<double> own,
    {bool reverse = false}) {
  List<T> o<T>(List<T> l) => reverse ? l.reversed.toList() : l;
  return ElectricalProject(
      id: 'p',
      name: 'P',
      panels: o([
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          system: ElectricalSystem.threePhase,
          voltage: const Voltage(400),
          circuits: o([
            for (var i = 0; i < kids.length; i++)
              ElectricalCircuit(
                  id: 'f$i',
                  name: 'to DB-$i',
                  loadKind: LoadKind.feeder,
                  feedsPanelId: 'DB$i',
                  length: const Length(20)),
            for (var j = 0; j < own.length; j++) _way('o$j', own[j]),
          ]),
        ),
        for (var i = 0; i < kids.length; i++)
          ElectricalPanel(
            id: 'DB$i',
            name: 'DB-$i',
            system: ElectricalSystem.threePhase,
            voltage: const Voltage(400),
            sourceType: PanelSource.feeder,
            fedByCircuitId: 'f$i',
            circuits: o([
              for (var j = 0; j < kids[i].length; j++)
                _way('d${i}w$j', kids[i][j]),
            ]),
          ),
      ]));
}

double _worst(PhaseBalanceResult b) => math.max(b.l1, math.max(b.l2, b.l3));

PhaseAssignment _rot(PhaseAssignment a, int r) =>
    a == PhaseAssignment.threePhase
        ? a
        : PhaseAssignment.values[(a.index + r) % 3];

/// The minimum root worst phase over every cyclic relabelling of the fed
/// boards' engine assignment: each relabelling is frozen as a prior (a huge
/// stability threshold keeps the labelled sub-boards where they are; the
/// MDP itself carries no prior, so its own singles balance freely).
double _bruteForceWorst(ElectricalProject pr, ElectricalSystemResult sys) {
  final kids = [
    for (final p in pr.panels)
      if (p.id != 'MDP') p.id,
  ]..sort();
  var best = double.infinity;
  final n = math.pow(3, kids.length).toInt();
  for (var code = 0; code < n; code++) {
    var c = code;
    final prior = <String, Map<String, PhaseAssignment>>{};
    for (final k in kids) {
      final r = c % 3;
      c ~/= 3;
      prior[k] = {
        for (final cr in sys.panels[k]!.circuits)
          cr.circuitId: _rot(cr.phase, r),
      };
    }
    final s = computeSystem(_p, pr,
        priorAssignments: prior, phaseReassignThresholdA: 1e9);
    best = math.min(best, _worst(s.panels['MDP']!.phaseBalance));
  }
  return best;
}

void main() {
  test('repro: DB-0 [6,1], DB-1 [3], DB-2 [4,2] kW + own 7 kW => 40 A', () {
    // 1 kW at 230 V cos phi 1 = 4.348 A. The relabelling
    //   L1 = DB-1 4.3 + own 30.4 = 34.8 A (DB-0's 1 kW on L1)
    //   L2 = DB-1 13.0 + DB-2 17.4 = 30.4 A
    //   L3 = DB-0 26.1 + DB-2 8.7 = 34.8 A
    // gives a worst phase of 34.8 A (the 40 A rung), ≤ 13.3 % imbalance —
    // the engine used to keep 26.0 / 51.9 / 21.7 A (63 A, 'inherent').
    final pr = _tree([
      [6, 1],
      [3],
      [4, 2],
    ], [
      7
    ]);
    final sys = computeSystem(_p, pr);
    final mdp = sys.panels['MDP']!;
    expect(_worst(mdp.phaseBalance), lessThanOrEqualTo(34.8));
    expect(mdp.incomer.breaker.ratingA.amperes, 40);
    expect(mdp.phaseBalance.imbalancePercent, lessThanOrEqualTo(13.4));
    expect(
        sys.warnings.where(
            (w) => w.panelId == 'MDP' && w.code.startsWith('phase-imbalance')),
        isEmpty);
  });

  test('probe 2 (no own ways): the engine APPLIES the relabelling', () {
    // DB-0 [6,5], DB-1 [6], DB-2 [8] kW: lines (A) DB-0 26.1 + 21.7 on two
    // lines, DB-1 26.1, DB-2 34.8. Best relabelling: DB-2 alone on L1
    // (34.8), DB-0's 26.1 on L2, its 21.7 + DB-1's 26.1 on L3 = 47.8 A (the
    // 50 A rung); the engine used to keep 56.2 A (63 A) and only recommend
    // 'Rotate R/S/T at DB-0, DB-1'.
    final pr = _tree([
      [6, 5],
      [6],
      [8],
    ], const []);
    final sys = computeSystem(_p, pr);
    final mdp = sys.panels['MDP']!;
    expect(_worst(mdp.phaseBalance), lessThanOrEqualTo(47.9));
    expect(mdp.incomer.breaker.ratingA.amperes, 50);
    expect(_worst(mdp.phaseBalance),
        lessThanOrEqualTo(_bruteForceWorst(pr, sys) + 0.05));
  });

  test(
      'seeded property: the root worst phase is the minimum over every '
      'cyclic relabelling of the fed boards, invariant to list order', () {
    final rnd = math.Random(4848);
    for (var t = 0; t < 120; t++) {
      final nk = 2 + rnd.nextInt(2);
      final kids = [
        for (var i = 0; i < nk; i++)
          [
            for (var j = 0; j < 1 + rnd.nextInt(2); j++)
              (1 + rnd.nextInt(8)).toDouble(),
          ],
      ];
      final own = [
        for (var j = 0; j < rnd.nextInt(3); j++)
          (1 + rnd.nextInt(8)).toDouble(),
      ];
      final pr = _tree(kids, own);
      final sys = computeSystem(_p, pr);
      final w = _worst(sys.panels['MDP']!.phaseBalance);
      final ref = _bruteForceWorst(pr, sys);
      expect(w, lessThanOrEqualTo(ref + 0.05),
          reason: 'trial $t kids=$kids own=$own: $w A vs best $ref A');
      final rev = computeSystem(_p, _tree(kids, own, reverse: true));
      expect(_worst(rev.panels['MDP']!.phaseBalance), closeTo(w, 0.05),
          reason: 'trial $t order-reversed');
      // 'inherent' is printed only when no relabelling beats the actual.
      final inherent = sys.warnings.any(
          (x) => x.panelId == 'MDP' && x.code == 'phase-imbalance-inherent');
      if (inherent) {
        expect(w, lessThanOrEqualTo(ref + 0.05), reason: 'trial $t');
      }
    }
  });
}
