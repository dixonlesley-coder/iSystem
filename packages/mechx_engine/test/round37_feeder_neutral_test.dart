// Round 37 (2026-10-18) — electrical-sim-4-feeder-neutral-ignores-fed-board-
// triplen-oversize.
//
// FOLD 2 oversizes a board's neutral BAR when its single-phase non-linear
// load sums triplen current in the neutral. The FEEDER supplying that board
// shares the same neutral current, so its cable must carry it too (four
// loaded conductors, IEC 60364-5-52 Annex E: Iz × 0.86 ≥ factor × I), and the
// parent board's own neutral bar sees that share.
//
// Derivation: 12 × 3 kW UPS ways (cos φ 0.9, 1φ at 231 V) on a 3φ TN-S
// sub-board, four per line ⇒ 4 × 3000 / (231 × 0.9) = 4 × 14.4 A (each 14.43 A, carried at 0.1 A) = 57.6 A per line. Every
// way is single-phase non-linear ⇒ triplen share 1.0 ⇒ FOLD-2 factor 1.73 ⇒
// neutral current 1.73 × 57.6 = 99.6 A ⇒ the feeder needs a derated Iz of at
// least 99.6 / 0.86 = 115.9 A.
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

ElectricalProject _project({bool ups = true}) => ElectricalProject(panels: [
      const ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
        ElectricalCircuit(
            id: 'f',
            name: 'Feeder UPS',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'ups',
            cableType: 'NYY',
            length: Length(30)),
      ]),
      ElectricalPanel(id: 'ups', name: 'UPS', circuits: [
        for (var i = 0; i < 12; i++)
          ElectricalCircuit(
            id: 'u$i',
            name: 'UPS $i',
            loadKind: ups ? LoadKind.ups : LoadKind.general,
            loadW: 3000,
            cosPhi: 0.9,
            phases: 1,
            length: const Length(10),
          ),
      ]),
    ]);

void main() {
  test('the fed board: 57.7 A per line, FOLD-2 factor 1.73', () {
    final sys = computeSystem(_p, _project());
    final ups = sys.panels['ups']!;
    // 4 ways per line × 3000 / (231 × 0.9) = 4 × 14.430 = 57.72 → 57.7 A.
    // Round 43: the line sums the EXACT way currents (was 4 × 14.4 = 57.6).
    expect(ups.phaseBalance.l1, closeTo(57.7, 0.05));
    expect(ups.phaseBalance.l2, closeTo(57.7, 0.05));
    expect(ups.phaseBalance.l3, closeTo(57.7, 0.05));
    expect(ups.neutralPeBars.neutralOversizeFactor, closeTo(1.73, 1e-9));
  });

  test('the feeder cable carries the 99.6 A neutral at 0.86 (Iz >= 115.9 A), '
      'with a full-size neutral, and says so', () {
    final sys = computeSystem(_p, _project());
    final f = sys.panels['mdp']!.circuits.single;
    const neutralA = 1.73 * 57.6;
    expect(neutralA, closeTo(99.6, 0.05));
    expect(f.cable.deratedIz.amperes * kFourLoadedConductorFactor,
        greaterThanOrEqualTo(neutralA - 0.1));
    expect(f.grounding.neutralCsaMm2, f.cable.csaMm2);
    expect(
        sys.warnings.where((w) =>
            w.code == 'harmonics-neutral-oversize' && w.circuitId == 'f'),
        hasLength(1));
  });

  test('the parent MDP neutral bar sees the triplen share (factor > 1)', () {
    final sys = computeSystem(_p, _project());
    expect(sys.panels['mdp']!.neutralPeBars.neutralOversizeFactor,
        greaterThan(1));
  });

  test('a LINEAR sub-board of the same loads is byte-identical: no neutral '
      'upsizing, MDP factor 1.0', () {
    final sys = computeSystem(_p, _project(ups: false));
    expect(sys.panels['ups']!.neutralPeBars.neutralOversizeFactor, 1.0);
    expect(sys.panels['mdp']!.neutralPeBars.neutralOversizeFactor, 1.0);
    final f = sys.panels['mdp']!.circuits.single;
    // Sized on the 57.6 A phase current alone.
    expect(f.cable.deratedIz.amperes * kFourLoadedConductorFactor,
        lessThan(99.6));
    // Round 38 — no NEUTRAL finding on the feeder (the selectivity floor's
    // separate 'outgoing-exceeds-incomer' judge is not a neutral matter).
    expect(
        sys.warnings.where((w) =>
            w.circuitId == 'f' &&
            (w.code == 'harmonics-neutral-oversize' ||
                w.code == 'feeder-neutral-overloaded')),
        isEmpty);
  });
}
