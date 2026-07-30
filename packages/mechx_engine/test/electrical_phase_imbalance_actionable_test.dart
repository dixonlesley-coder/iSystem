// The phase-imbalance warning is only raised when the imbalance can ACTUALLY be
// reduced by a different phase assignment. `balancePhases` already spreads every
// unpinned single-phase way as evenly as it can, so "redistribute single-phase
// circuits" is only a real instruction when something (a phase PIN, a sticky
// prior assignment) is holding the board off a better assignment. An imbalance
// inherent to the board's own loads — two single-phase ways can never load three
// lines evenly — must NOT be reported as a fixable defect.
//
// Expected minimum spreads are hand-enumerated from the load lists below.

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  const p = PuilProfile();

  ElectricalCircuit lighting(String id, double w, {PhaseLine? pin}) =>
      ElectricalCircuit(
        id: id,
        name: 'Lighting $id',
        loadKind: LoadKind.lighting,
        isLighting: true,
        loadW: w,
        cosPhi: 1,
        length: const Length(10),
        phaseOverride: pin,
      );

  ElectricalPanel board(List<ElectricalCircuit> circuits) => ElectricalPanel(
        id: 'MDP',
        name: 'MDP',
        system: ElectricalSystem.threePhase,
        voltage: const Voltage(400),
        ambientTempC: 30,
        circuits: circuits,
      );

  group('minimumPhaseSpreadA (the achievable floor)', () {
    test('no single-phase ways ⇒ nothing to spread', () {
      expect(minimumPhaseSpreadA(const []), 0);
      // Zero/negative currents are not ways.
      expect(minimumPhaseSpreadA(const [0, 0]), 0);
    });

    test('one way ⇒ its own current is the floor (two lines stay empty)', () {
      expect(minimumPhaseSpreadA(const [12.0]), closeTo(12.0, 1e-9));
    });

    test('two equal ways ⇒ 0/x/x is the best possible, floor = x', () {
      // 5.8+5.8 → either 11.6/0/0 (spread 11.6) or 5.8/5.8/0 (spread 5.8).
      expect(minimumPhaseSpreadA(const [5.8, 5.8]), closeTo(5.8, 1e-9));
    });

    test('three equal ways ⇒ a perfectly even board is reachable', () {
      expect(minimumPhaseSpreadA(const [10.0, 10.0, 10.0]), 0);
    });

    test('an indivisible set floors above zero: 3+3+2+2+2 ⇒ spread 2', () {
      // Total 12, so 4/4/4 would be even — but a 4 needs {2,2}, leaving {3,3,2}
      // to split into 5/3. Every partition is (5,4,3) → 2, (5,5,2) → 3,
      // (6,4,2) → 4 or worse, so 2 is the floor.
      expect(minimumPhaseSpreadA(const [3.0, 3.0, 2.0, 2.0, 2.0]),
          closeTo(2.0, 1e-9));
    });

    test('above the exact-search cap the balancer itself is the reference', () {
      // 12 equal ways ⇒ 4 per line either way; the heuristic fallback finds it.
      final twelve = List<double>.filled(12, 6.0);
      expect(minimumPhaseSpreadA(twelve, exactSearchMax: 10), 0);
    });
  });

  group('the reported board (2 three-phase ways + 2 equal 1φ ways)', () {
    // Reproduces the screenshot that prompted this change: R 27.9 / S 27.9 /
    // T 22.1 A, imbalance 22.3 %. The two three-phase ways load all three lines
    // equally (they cannot change the spread, only the average), and the two
    // lighting ways are EQUAL — so 5.8 A on two lines and nothing on the third
    // is the floor. There is no redistribution to make.
    final r = computePanel(
      p,
      board([
        const ElectricalCircuit(
          id: 'sp2',
          name: 'Sub-panel 2',
          loadKind: LoadKind.general,
          loadW: 4000,
          cosPhi: 0.85,
          phases: 3,
          length: Length(10),
        ),
        const ElectricalCircuit(
          id: 'sp3',
          name: 'Sub-panel 3',
          loadKind: LoadKind.general,
          loadW: 9000,
          cosPhi: 0.85,
          phases: 3,
          length: Length(10),
        ),
        lighting('l1', 1340),
        lighting('l2', 1340),
      ]),
    );

    test('the reported line currents + imbalance are reproduced', () {
      // 3φ: 4000/(√3·400·0.85) = 6.79 → 6.8 A; 9000/… = 15.29 → 15.3 A.
      // 1φ: 1340/231 = 5.80 A. R = S = 6.8+15.3+5.8 = 27.9; T = 22.1.
      expect(r.phaseBalance.l1, closeTo(27.9, 0.05));
      expect(r.phaseBalance.l2, closeTo(27.9, 0.05));
      expect(r.phaseBalance.l3, closeTo(22.1, 0.05));
      // avg 25.97 ⇒ (27.9−22.1)/25.97·100 = 22.3 %.
      expect(r.imbalancePercent, closeTo(22.3, 0.15));
    });

    test('over the 15 % limit, yet NOT reported — nothing can be moved', () {
      expect(r.imbalancePercent, greaterThan(kPhaseImbalanceWarnPercent));
      expect(r.phaseBalance.imbalanceReducible, isFalse);
      expect(r.warnings.map((w) => w.code), isNot(contains('phase-imbalance')));
    });
  });

  group('inherent imbalance is NOT warned about', () {
    // The user-reported board: two 3-phase sub-panel feeders (which load all
    // three lines equally and so cannot change the spread) plus two EQUAL
    // single-phase lighting ways. 5.8 A on two lines, 0 on the third is the
    // best any assignment reaches — the board is unbalanceable by construction.
    final r = computePanel(
      p,
      board([
        lighting('l1', 1340),
        lighting('l2', 1340),
      ]),
    );

    test('the imbalance is real and printed', () {
      expect(r.imbalancePercent, greaterThan(15));
      expect(r.phaseBalance.l3, 0);
    });

    test('no phase-imbalance warning, and the result says why', () {
      expect(r.phaseBalance.imbalanceReducible, isFalse);
      expect(r.warnings.map((w) => w.code), isNot(contains('phase-imbalance')));
    });
  });

  group('pin-forced imbalance IS warned about', () {
    // Three equal single-phase ways all pinned to L1: the balancer is forbidden
    // from moving them, but unpinning would give a perfectly even 10/10/10 —
    // an action the engineer can take, so the warning is honest here.
    final r = computePanel(
      p,
      board([
        lighting('a', 2310, pin: PhaseLine.l1),
        lighting('b', 2310, pin: PhaseLine.l1),
        lighting('c', 2310, pin: PhaseLine.l1),
      ]),
    );

    test('all three ways land on L1', () {
      expect(r.phaseBalance.l1, closeTo(30.0, 0.2));
      expect(r.phaseBalance.l2, 0);
      expect(r.phaseBalance.l3, 0);
    });

    test('warned, flagged reducible, and told what to unpin', () {
      expect(r.phaseBalance.imbalanceReducible, isTrue);
      final w = r.warnings.firstWhere((w) => w.code == 'phase-imbalance');
      expect(w.severity, WarningSeverity.warning);
      expect(w.message, contains('3 ways pinned'));
      // A perfectly even board is achievable once they are freed.
      expect(w.message, contains('0.0% is achievable'));
    });

    test('freeing the pins removes the warning entirely', () {
      final free = computePanel(
        p,
        board([lighting('a', 2310), lighting('b', 2310), lighting('c', 2310)]),
      );
      expect(free.imbalancePercent, 0);
      expect(free.phaseBalance.imbalanceReducible, isFalse);
      expect(
          free.warnings.map((w) => w.code), isNot(contains('phase-imbalance')));
    });
  });

  group('the feeder-below-fed-demand cause text follows the same honesty', () {
    // A sub-board carrying one dominant single-phase way: its worst phase far
    // exceeds the balanced current the parent's feeder is sized from, so the
    // feeder check fires — but no re-assignment can even out one big load, so
    // that message must not offer "rebalance" either.
    const project = ElectricalProject(
      id: 'prj',
      name: 'Dominant 1ph load',
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          circuits: [
            ElectricalCircuit(
              id: 'f1',
              name: 'Feeder PP',
              loadKind: LoadKind.feeder,
              feedsPanelId: 'PP',
              length: Length(10),
            ),
          ],
        ),
        ElectricalPanel(
          id: 'PP',
          name: 'PP',
          sourceType: PanelSource.feeder,
          circuits: [
            ElectricalCircuit(
              id: 'big',
              name: 'Big 1ph',
              loadKind: LoadKind.general,
              loadW: 6000,
              phases: 1,
              length: Length(10),
            ),
            ElectricalCircuit(
              id: 's1',
              name: 'Small A',
              loadKind: LoadKind.general,
              loadW: 200,
              phases: 1,
              length: Length(10),
            ),
          ],
        ),
      ],
    );

    test('an inherent imbalance is named as such, not offered as a fix', () {
      final r = computeSystem(p, project);
      expect(r.panels['PP']!.phaseBalance.imbalanceReducible, isFalse);
      expect(r.panels['PP']!.warnings.map((w) => w.code),
          isNot(contains('phase-imbalance')));
      final w = r.panels['MDP']!.warnings
          .firstWhere((w) => w.code == 'feeder-below-fed-demand');
      expect(w.message, contains('inherent'));
      expect(w.message, isNot(contains('rebalance')));
      expect(w.message, contains('raise the feeder rating'));
    });
  });

  group('a partially reducible board still warns', () {
    // Two ways pinned onto L1 (14 A + 14 A) beside a free 14 A way: achieved
    // 28/14/0, but releasing the pins reaches 14/14/14. Reducible ⇒ warned.
    final r = computePanel(
      p,
      board([
        lighting('a', 3234, pin: PhaseLine.l1),
        lighting('b', 3234, pin: PhaseLine.l1),
        lighting('c', 3234),
      ]),
    );

    test('warned with the singular pin wording when one way is pinned', () {
      final one = computePanel(
        p,
        board([
          lighting('a', 3234, pin: PhaseLine.l1),
          lighting('b', 3234, pin: PhaseLine.l1),
        ]),
      );
      // Both ways pinned to the same line ⇒ 28/0/0, but 14/14/0 is reachable.
      expect(one.phaseBalance.imbalanceReducible, isTrue);
      expect(one.warnings.firstWhere((w) => w.code == 'phase-imbalance').message,
          contains('2 ways pinned'));
    });

    test('three ways, two pinned ⇒ reducible', () {
      expect(r.phaseBalance.imbalanceReducible, isTrue);
      expect(r.warnings.map((w) => w.code), contains('phase-imbalance'));
    });
  });
}
