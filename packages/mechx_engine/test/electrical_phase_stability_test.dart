import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/sizing.dart' show roundTo;
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// PHASE-ASSIGNMENT STABILITY. `balancePhases` gained a prior-assignment seed
/// plus a re-assignment threshold so a re-solve does not silently re-label the
/// lines an installed board is already wired to. Every expectation below is
/// hand-derived by walking the greedy + local search by hand (the amp
/// arithmetic is in the comments), and the defaults are pinned as
/// byte-identical to the un-stabilised algorithm.
void main() {
  const p = PuilProfile();

  // On a 3φ 400 V board a single-phase way runs at the phase voltage
  //   Vph = round(400/√3) = round(230.94) = 231 V,
  // so a cosφ = 1.0 load of (231 · A) watts draws exactly A amperes:
  //   Ib = 231·A / (231 · 1.0) = A  (the engine rounds Ib to 0.1 A).
  ElectricalCircuit load(String id, double amps) => ElectricalCircuit(
        id: id,
        name: id,
        loadKind: LoadKind.socket,
        loadW: 231 * amps,
        cosPhi: 1,
        length: const Length(20),
      );

  PhaseAssignment phaseOf(ElectricalPanelResult r, String circuitId) =>
      r.circuits.firstWhere((c) => c.circuitId == circuitId).phase;

  double currentOf(ElectricalPanelResult r, String circuitId) =>
      r.circuits
          .firstWhere((c) => c.circuitId == circuitId)
          .designCurrent
          .amperes;

  Map<String, PhaseAssignment> assignmentOf(ElectricalPanelResult r) => {
        for (final c in r.circuits) c.circuitId: c.phase,
      };

  Map<String, Map<String, PhaseAssignment>> assignmentsOf(
          ElectricalSystemResult r) =>
      {for (final e in r.panels.entries) e.key: assignmentOf(e.value)};

  // ── (a) no prior ⇒ byte-identical ─────────────────────────────────────────
  group('(a) no prior assignment reproduces the un-stabilised balance', () {
    // MDP (3φ) feeds SP-1 and SP-2 and carries two single-phase ways of its
    // own; both sub-boards carry single-phase ways only.
    const project = ElectricalProject(
      id: 'prj',
      name: 'Phase stability',
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          tag: 'MDP',
          circuits: [
            ElectricalCircuit(
              id: 'f1',
              name: 'f1',
              loadKind: LoadKind.feeder,
              feedsPanelId: 'SP1',
              cosPhi: 1,
              length: Length(30),
            ),
            ElectricalCircuit(
              id: 'f2',
              name: 'f2',
              loadKind: LoadKind.feeder,
              feedsPanelId: 'SP2',
              cosPhi: 1,
              length: Length(30),
            ),
            // m1 = 10.0 A, m2 = 8.0 A (231·A watts at cosφ 1.0).
            ElectricalCircuit(
              id: 'm1',
              name: 'm1',
              loadKind: LoadKind.socket,
              loadW: 2310,
              cosPhi: 1,
              length: Length(20),
            ),
            ElectricalCircuit(
              id: 'm2',
              name: 'm2',
              loadKind: LoadKind.socket,
              loadW: 1848,
              cosPhi: 1,
              length: Length(20),
            ),
          ],
        ),
        ElectricalPanel(
          id: 'SP1',
          name: 'SP-1',
          tag: 'SP-1',
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'f1',
          circuits: [
            // 10.0 / 9.0 / 8.0 / 7.0 A
            ElectricalCircuit(
              id: 'a1',
              name: 'a1',
              loadKind: LoadKind.socket,
              loadW: 2310,
              cosPhi: 1,
              length: Length(20),
            ),
            ElectricalCircuit(
              id: 'a2',
              name: 'a2',
              loadKind: LoadKind.socket,
              loadW: 2079,
              cosPhi: 1,
              length: Length(20),
            ),
            ElectricalCircuit(
              id: 'a3',
              name: 'a3',
              loadKind: LoadKind.socket,
              loadW: 1848,
              cosPhi: 1,
              length: Length(20),
            ),
            ElectricalCircuit(
              id: 'a4',
              name: 'a4',
              loadKind: LoadKind.socket,
              loadW: 1617,
              cosPhi: 1,
              length: Length(20),
            ),
          ],
        ),
        ElectricalPanel(
          id: 'SP2',
          name: 'SP-2',
          tag: 'SP-2',
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'f2',
          circuits: [
            // 12.0 / 11.0 / 10.0 A
            ElectricalCircuit(
              id: 'b1',
              name: 'b1',
              loadKind: LoadKind.socket,
              loadW: 2772,
              cosPhi: 1,
              length: Length(20),
            ),
            ElectricalCircuit(
              id: 'b2',
              name: 'b2',
              loadKind: LoadKind.socket,
              loadW: 2541,
              cosPhi: 1,
              length: Length(20),
            ),
            ElectricalCircuit(
              id: 'b3',
              name: 'b3',
              loadKind: LoadKind.socket,
              loadW: 2310,
              cosPhi: 1,
              length: Length(20),
            ),
          ],
        ),
      ],
    );

    final plain = computeSystem(p, project);
    final withEmptyPrior = computeSystem(
      p,
      project,
      priorAssignments: const {},
      phaseReassignThresholdA: 0,
    );

    test('per-circuit phase + phase balance are identical', () {
      expect(assignmentsOf(withEmptyPrior), assignmentsOf(plain));
      for (final id in plain.order) {
        final a = plain.panels[id]!.phaseBalance;
        final b = withEmptyPrior.panels[id]!.phaseBalance;
        expect(b.l1, a.l1, reason: '$id L1');
        expect(b.l2, a.l2, reason: '$id L2');
        expect(b.l3, a.l3, reason: '$id L3');
        expect(b.imbalancePercent, a.imbalancePercent, reason: '$id imbalance');
      }
    });

    test('the from-scratch greedy result is the documented one', () {
      // SP-1 singles descending: 10.0, 9.0, 8.0, 7.0 onto the least-loaded line
      //   10.0 -> L1 (0,0,0)      => (10, 0, 0)
      //    9.0 -> L2               => (10, 9, 0)
      //    8.0 -> L3               => (10, 9, 8)
      //    7.0 -> L3 (8 is lowest) => (10, 9, 15)
      // Local search: every relocate/swap leaves the 15 - 9 = 6 A spread the
      // same or wider (e.g. swapping 10↔9 gives (9,10,15), still 6), so the
      // greedy result stands.
      final sp1 = plain.panels['SP1']!;
      expect(phaseOf(sp1, 'a1'), PhaseAssignment.l1);
      expect(phaseOf(sp1, 'a2'), PhaseAssignment.l2);
      expect(phaseOf(sp1, 'a3'), PhaseAssignment.l3);
      expect(phaseOf(sp1, 'a4'), PhaseAssignment.l3);
      expect(sp1.phaseBalance.l1, closeTo(10.0, 1e-9));
      expect(sp1.phaseBalance.l2, closeTo(9.0, 1e-9));
      expect(sp1.phaseBalance.l3, closeTo(15.0, 1e-9));
      // imbalance = (15 - 9) / ((10+9+15)/3) · 100 = 6 / 11.3333 · 100 = 52.94
      expect(sp1.phaseBalance.imbalancePercent, closeTo(52.9, 1e-9));

      // SP-2: 12.0 -> L1, 11.0 -> L2, 10.0 -> L3; every swap only permutes the
      // three lines, so the 12 - 10 = 2 A spread never shrinks.
      final sp2 = plain.panels['SP2']!;
      expect(phaseOf(sp2, 'b1'), PhaseAssignment.l1);
      expect(phaseOf(sp2, 'b2'), PhaseAssignment.l2);
      expect(phaseOf(sp2, 'b3'), PhaseAssignment.l3);
      // imbalance = (12 - 10) / ((12+11+10)/3) · 100 = 2 / 11 · 100 = 18.18
      expect(sp2.phaseBalance.imbalancePercent, closeTo(18.2, 1e-9));

      // MDP: both feeders are three-phase, so they load L1/L2/L3 equally with
      // F = Ib(f1) + Ib(f2) before any single-phase way is placed. m1 (10.0 A)
      // then goes to L1 and m2 (8.0 A) to L2 (both lines still at F).
      final mdp = plain.panels['MDP']!;
      expect(phaseOf(mdp, 'f1'), PhaseAssignment.threePhase);
      expect(phaseOf(mdp, 'f2'), PhaseAssignment.threePhase);
      expect(phaseOf(mdp, 'm1'), PhaseAssignment.l1);
      expect(phaseOf(mdp, 'm2'), PhaseAssignment.l2);
      final f = currentOf(mdp, 'f1') + currentOf(mdp, 'f2');
      expect(mdp.phaseBalance.l1, closeTo(roundTo(f + 10.0, 1), 1e-9));
      expect(mdp.phaseBalance.l2, closeTo(roundTo(f + 8.0, 1), 1e-9));
      expect(mdp.phaseBalance.l3, closeTo(roundTo(f, 1), 1e-9));
    });

    test('re-solving with the first solve own assignment changes nothing', () {
      // The first solve ended at a local optimum (no relocate or swap improved
      // the spread), so seeding it back reproduces it whatever the threshold —
      // the 3φ feeder entries in the prior map are ignored outright.
      final prior = assignmentsOf(plain);
      expect(prior['MDP']!['f1'], PhaseAssignment.threePhase);

      final resolved = computeSystem(
        p,
        project,
        priorAssignments: prior,
        phaseReassignThresholdA: 5,
      );
      expect(assignmentsOf(resolved), prior);
      for (final id in plain.order) {
        expect(resolved.panels[id]!.phaseBalance.l1, plain.panels[id]!.phaseBalance.l1);
        expect(resolved.panels[id]!.phaseBalance.l2, plain.panels[id]!.phaseBalance.l2);
        expect(resolved.panels[id]!.phaseBalance.l3, plain.panels[id]!.phaseBalance.l3);
      }
    });
  });

  // ── (b) a sub-threshold gain never re-labels the board ────────────────────
  group('(b) sub-threshold no-hop', () {
    // One 3φ board, six single-phase ways (A, at cosφ 1.0 / 231 V):
    //   k1 10.0   k2 9.8   k3 9.0   k4 7.0   k5 6.8   k6 5.4     (sum 48.0)
    final panel = ElectricalPanel(
      id: 'LP',
      name: 'LP',
      tag: 'LP',
      circuits: [
        load('k1', 10.0),
        load('k2', 9.8),
        load('k3', 9.0),
        load('k4', 7.0),
        load('k5', 6.8),
        load('k6', 5.4),
      ],
    );

    // The board as WIRED (a previous solve): L1 {k1, k5} = 16.8,
    // L2 {k3, k4} = 16.0, L3 {k2, k6} = 15.2 — spread 16.8 - 15.2 = 1.6 A.
    const prior = <String, PhaseAssignment>{
      'k1': PhaseAssignment.l1,
      'k2': PhaseAssignment.l3,
      'k3': PhaseAssignment.l2,
      'k4': PhaseAssignment.l2,
      'k5': PhaseAssignment.l1,
      'k6': PhaseAssignment.l3,
    };

    test('a 0.4 A gain does not clear a 1.0 A threshold', () {
      // From the wired state every RELOCATE is far worse (the smallest way is
      // 5.4 A, so moving any of them opens a gap of at least 11.6 A against the
      // 1.6 A spread). Exactly two SWAPS improve it, both by 0.4 A:
      //   k1(L1,10.0) <-> k2(L3,9.8): L1 16.6, L3 15.4 -> spread 1.2 (-0.4)
      //   k5(L1, 6.8) <-> k6(L3,5.4): L1 15.4, L3 16.6 -> spread 1.2 (-0.4)
      // A swap moving a way off its prior line must beat 1.0 A, and 0.4 < 1.0,
      // so both are rejected and the wired assignment survives verbatim.
      final r = computePanel(
        p,
        panel,
        opts: const ComputePanelOptions(
          priorAssignment: prior,
          phaseReassignThresholdA: 1.0,
        ),
      );
      expect(assignmentOf(r), prior);
      expect(r.phaseBalance.l1, closeTo(16.8, 1e-9));
      expect(r.phaseBalance.l2, closeTo(16.0, 1e-9));
      expect(r.phaseBalance.l3, closeTo(15.2, 1e-9));
      // imbalance = (16.8 - 15.2) / (48/3) · 100 = 1.6 / 16 · 100 = 10.0 %
      expect(r.phaseBalance.imbalancePercent, closeTo(10.0, 1e-9));
    });

    test('computeSystem threads the per-panel prior slice', () {
      final project = ElectricalProject(id: 'prj', panels: [panel]);
      final r = computeSystem(
        p,
        project,
        priorAssignments: const {'LP': prior},
        phaseReassignThresholdA: 1.0,
      );
      expect(assignmentOf(r.panels['LP']!), prior);
      // A prior for another panel id must not reach this one.
      final unrelated = computeSystem(
        p,
        project,
        priorAssignments: const {'OTHER': prior},
        phaseReassignThresholdA: 1.0,
      );
      expect(assignmentOf(unrelated.panels['LP']!),
          isNot(equals(assignmentOf(r.panels['LP']!))));
    });

    test('the same 0.4 A gain IS taken at threshold 0', () {
      // Same seed, no threshold: the first improving swap the loop meets is
      // a = k1 (L1), b = k2 (L3) -> k1 to L3, k2 to L1, spread 1.6 -> 1.2.
      // Nothing improves on the resulting 16.6 / 16.0 / 15.4 split, so it ends
      // there — proof that the THRESHOLD, not the seed, blocked the hop above.
      final r = computePanel(
        p,
        panel,
        opts: const ComputePanelOptions(priorAssignment: prior),
      );
      expect(phaseOf(r, 'k1'), PhaseAssignment.l3);
      expect(phaseOf(r, 'k2'), PhaseAssignment.l1);
      expect(phaseOf(r, 'k3'), PhaseAssignment.l2);
      expect(phaseOf(r, 'k4'), PhaseAssignment.l2);
      expect(phaseOf(r, 'k5'), PhaseAssignment.l1);
      expect(phaseOf(r, 'k6'), PhaseAssignment.l3);
      expect(r.phaseBalance.l1, closeTo(16.6, 1e-9)); // k2 9.8 + k5 6.8
      expect(r.phaseBalance.l2, closeTo(16.0, 1e-9)); // k3 9.0 + k4 7.0
      expect(r.phaseBalance.l3, closeTo(15.4, 1e-9)); // k1 10.0 + k6 5.4
      // imbalance = 1.2 / 16 · 100 = 7.5 %
      expect(r.phaseBalance.imbalancePercent, closeTo(7.5, 1e-9));
    });

    test('with no prior the greedy lands somewhere else entirely', () {
      // Descending greedy onto the least-loaded line:
      //   k1 10.0 -> L1  (10.0,  0.0,  0.0)
      //   k2  9.8 -> L2  (10.0,  9.8,  0.0)
      //   k3  9.0 -> L3  (10.0,  9.8,  9.0)
      //   k4  7.0 -> L3  (10.0,  9.8, 16.0)
      //   k5  6.8 -> L2  (10.0, 16.6, 16.0)
      //   k6  5.4 -> L1  (15.4, 16.6, 16.0)   spread 1.2
      // No relocate/swap improves on that, so it is the answer — a different
      // labelling of the SAME board (only k1 keeps its wired line).
      final r = computePanel(p, panel);
      expect(phaseOf(r, 'k1'), PhaseAssignment.l1);
      expect(phaseOf(r, 'k2'), PhaseAssignment.l2);
      expect(phaseOf(r, 'k3'), PhaseAssignment.l3);
      expect(phaseOf(r, 'k4'), PhaseAssignment.l3);
      expect(phaseOf(r, 'k5'), PhaseAssignment.l2);
      expect(phaseOf(r, 'k6'), PhaseAssignment.l1);
      expect(r.phaseBalance.l1, closeTo(15.4, 1e-9));
      expect(r.phaseBalance.l2, closeTo(16.6, 1e-9));
      expect(r.phaseBalance.l3, closeTo(16.0, 1e-9));
      expect(r.phaseBalance.imbalancePercent, closeTo(7.5, 1e-9));
      expect(assignmentOf(r), isNot(equals(prior)));
    });
  });

  // ── (c) a big change still rebalances ─────────────────────────────────────
  group('(c) a large new load still rebalances', () {
    // The wired board: k1 10.0 A on L1, k2 8.0 A on L2, k3 6.0 A on L3
    // (that is also what the greedy produces from scratch — spread 4.0 A).
    const prior = <String, PhaseAssignment>{
      'k1': PhaseAssignment.l1,
      'k2': PhaseAssignment.l2,
      'k3': PhaseAssignment.l3,
    };
    final wired = [load('k1', 10.0), load('k2', 8.0), load('k3', 6.0)];

    test('the unchanged board holds its wired lines', () {
      final r = computePanel(
        p,
        ElectricalPanel(id: 'LP', name: 'LP', circuits: wired),
        opts: const ComputePanelOptions(
          priorAssignment: prior,
          phaseReassignThresholdA: 1.0,
        ),
      );
      expect(assignmentOf(r), prior);
      expect(r.phaseBalance.l1, closeTo(10.0, 1e-9));
      expect(r.phaseBalance.l2, closeTo(8.0, 1e-9));
      expect(r.phaseBalance.l3, closeTo(6.0, 1e-9));
    });

    test('adding a 12.0 A way moves three circuits despite the threshold', () {
      // Seed (10, 8, 6); the NEW way g (12.0 A) has no prior, so the greedy
      // drops it on the least-loaded line L3 -> (10, 8, 18), spread 10.0 A.
      // Relocate pass (descending g, k1, k2, k3):
      //   g  L3->L1 (22, 8, 6) spread 16.0 / L3->L2 (10,20,6) 14.0  -> reject
      //   k1 L1->L2 ( 0,18,18) 18.0 / L1->L3 (0,8,28) 28.0          -> reject
      //   k2 L2->L1 (18, 0,18) 18.0 / L2->L3 (10,0,26) 26.0         -> reject
      //   k3 L3->L1 (16, 8,12) 8.0: gain 10.0-8.0 = 2.0 > 1.0       -> ACCEPT
      //      then L3->L2 (16,14,6) 10.0                             -> reject
      // Swap pass on (16, 8, 12):
      //   g<->k1 (18,8,10) 10.0, g<->k2 (16,12,8) 8.0                -> reject
      //   k1<->k2: L1 16-10+8 = 14, L2 8-8+10 = 10 -> (14,10,12) spread 4.0,
      //      gain 8.0-4.0 = 4.0 > 1.0                                -> ACCEPT
      // Nothing improves on (14, 10, 12) in the next pass, so:
      //   L1 {k2 8.0, k3 6.0} = 14.0   L2 {k1 10.0} = 10.0   L3 {g 12.0} = 12.0
      final r = computePanel(
        p,
        ElectricalPanel(
          id: 'LP',
          name: 'LP',
          circuits: [...wired, load('g', 12.0)],
        ),
        opts: const ComputePanelOptions(
          priorAssignment: prior,
          phaseReassignThresholdA: 1.0,
        ),
      );
      expect(phaseOf(r, 'k1'), PhaseAssignment.l2);
      expect(phaseOf(r, 'k2'), PhaseAssignment.l1);
      expect(phaseOf(r, 'k3'), PhaseAssignment.l1);
      expect(phaseOf(r, 'g'), PhaseAssignment.l3);
      expect(r.phaseBalance.l1, closeTo(14.0, 1e-9));
      expect(r.phaseBalance.l2, closeTo(10.0, 1e-9));
      expect(r.phaseBalance.l3, closeTo(12.0, 1e-9));
      // imbalance = (14 - 10) / ((14+10+12)/3) · 100 = 4 / 12 · 100 = 33.3 %
      expect(r.phaseBalance.imbalancePercent, closeTo(33.3, 1e-9));
    });
  });
}
