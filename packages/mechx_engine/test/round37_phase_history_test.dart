// Round 37 (2026-10-18) — edit-fuzz-3-1 / edit-fuzz-3-2.
//
// The session-only phase memory (the previous solve's assignment, fed back as
// `priorAssignment` with a 1.0 A stickiness threshold) is NEVER saved in the
// .mechx file. So nothing that sizes or judges the board may depend on it:
//
//   * edit-fuzz-3-1 — the WORST phase (the incomer + busbar sizing current)
//     of a seeded solve equals the unseeded solve's, whatever the prior;
//   * edit-fuzz-3-2 — the phase-imbalance verdict (warning vs inherent info,
//     `imbalanceReducible`) is the same seeded or not.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  const p = PuilProfile();

  // 231 V phase voltage on a 400 V board: a cos phi 1 way of 231·A W draws A.
  ElectricalCircuit load(String id, double amps, {PhaseLine? pin}) =>
      ElectricalCircuit(
        id: id,
        name: id,
        loadKind: LoadKind.socket,
        loadW: 231 * amps,
        cosPhi: 1,
        phaseOverride: pin,
        length: const Length(20),
      );

  double worst(ElectricalPanelResult r) => math.max(
      r.phaseBalance.l1, math.max(r.phaseBalance.l2, r.phaseBalance.l3));

  String? imbalanceCode(ElectricalPanelResult r) => r.warnings
      .map((w) => w.code)
      .where((c) => c.startsWith('phase-imbalance'))
      .firstOrNull;

  test('the reported live/reopen divergence: a 0.9 A heavier sticky worst '
      'phase is never kept', () {
    // Four single-phase ways (A): 12.6, 11.1, 9.6, 9.6 → total 42.9. Seed the
    // memory with a deliberately heavy labelling: L1 {12.6, 9.6} 22.2,
    // L2 {11.1, 9.6} 20.7, L3 {} 0. The optimum worst phase is 12.6 + 0 …
    // i.e. {12.6} / {11.1} / {9.6, 9.6} = 19.2 A worst. Whatever the
    // stickiness, the issued worst phase is the fresh optimum 19.2 A.
    final panel = ElectricalPanel(id: 'LP', name: 'LP', circuits: [
      load('a', 12.6),
      load('b', 11.1),
      load('c', 9.6),
      load('d', 9.6),
    ]);
    final seeded = computePanel(p, panel,
        opts: const ComputePanelOptions(priorAssignment: {
          'a': PhaseAssignment.l1,
          'b': PhaseAssignment.l2,
          'c': PhaseAssignment.l1,
          'd': PhaseAssignment.l2,
        }, phaseReassignThresholdA: 1.0));
    final fresh = computePanel(p, panel);
    expect(worst(fresh), closeTo(19.2, 1e-9));
    expect(worst(seeded), closeTo(worst(fresh), 1e-9));
    expect(seeded.incomer.breaker.ratingA.amperes, fresh.incomer.breaker.ratingA.amperes);
  });

  test('seeded property: random boards / priors / pins — worst phase, incomer '
      'and the imbalance verdict never depend on the session memory', () {
    final rng = math.Random(37);
    for (var trial = 0; trial < 300; trial++) {
      final n = 2 + rng.nextInt(10); // 2..11 singles (exact + local search)
      final circuits = <ElectricalCircuit>[];
      final prior = <String, PhaseAssignment>{};
      for (var i = 0; i < n; i++) {
        final amps = (1 + rng.nextInt(250)) / 10.0; // 0.1 .. 25.0 A
        final pin = rng.nextDouble() < 0.1
            ? PhaseLine.values[rng.nextInt(3)]
            : null;
        circuits.add(load('w$i', amps, pin: pin));
        if (rng.nextBool()) {
          prior['w$i'] = [
            PhaseAssignment.l1,
            PhaseAssignment.l2,
            PhaseAssignment.l3
          ][rng.nextInt(3)];
        }
      }
      if (rng.nextBool()) {
        circuits.add(ElectricalCircuit(
          id: 'm3',
          name: 'm3',
          loadKind: LoadKind.socket,
          loadW: 400.0 * 1.732 * (1 + rng.nextInt(20)),
          cosPhi: 1,
          phases: 3,
          length: const Length(20),
        ));
      }
      final panel = ElectricalPanel(id: 'LP', name: 'LP', circuits: circuits);
      final fresh = computePanel(p, panel);
      final seeded = computePanel(p, panel,
          opts: ComputePanelOptions(
              priorAssignment: prior, phaseReassignThresholdA: 1.0));
      final reason = 'trial $trial: $prior';
      expect(worst(seeded), closeTo(worst(fresh), 1e-9), reason: reason);
      expect(seeded.incomer.breaker.ratingA.amperes, fresh.incomer.breaker.ratingA.amperes, reason: reason);
      expect(seeded.phaseBalance.imbalanceReducible,
          fresh.phaseBalance.imbalanceReducible,
          reason: reason);
      expect(imbalanceCode(seeded), imbalanceCode(fresh), reason: reason);
    }
  });
}
