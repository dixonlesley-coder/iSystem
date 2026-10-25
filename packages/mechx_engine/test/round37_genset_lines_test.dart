// Round 37 (2026-10-18) — regression-genset-1ph-boards-on-different-lines-
// summed.
//
// A 3φ alternator is rated PER PHASE. Three 1φ 230 V essential boards fed
// from three different lines load three different alternator phases, so the
// per-phase need is the heaviest LINE, never the sum of the boards.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

ElectricalCircuit _heater3(String id, double w) => ElectricalCircuit(
      id: id,
      name: 'Heater $id',
      loadKind: LoadKind.heating,
      loadW: w,
      cosPhi: 1.0,
      phases: 3,
      length: const Length(10),
    );

/// MDP (3φ) with 3 x 10 kW 3φ heaters + one 1φ feeder per [lines] entry to a
/// 1φ 230 V essential board with a 7 kW heater (cos φ 1).
ElectricalProject _probe(List<PhaseLine> lines, {ApparentPower? kva}) =>
    ElectricalProject(
      sources: ElectricalSources(
          generator: GeneratorSource(kva: kva, backupFraction: 0.1)),
      panels: [
        ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
          for (var i = 0; i < 3; i++) _heater3('h$i', 10000),
          for (var i = 0; i < lines.length; i++)
            ElectricalCircuit(
              id: 'f$i',
              name: 'EP$i',
              loadKind: LoadKind.feeder,
              feedsPanelId: 'ep$i',
              phases: 1,
              phaseOverride: lines[i],
              length: const Length(10),
            ),
        ]),
        for (var i = 0; i < lines.length; i++)
          ElectricalPanel(
            id: 'ep$i',
            name: 'EP$i',
            system: ElectricalSystem.singlePhase,
            voltage: const Voltage(230),
            essential: true,
            circuits: [
              ElectricalCircuit(
                id: 'ep$i-h',
                name: 'Heater',
                loadKind: LoadKind.heating,
                loadW: 7000,
                cosPhi: 1.0,
                length: const Length(10),
              ),
            ],
          ),
      ],
    );

void main() {
  // EP I = 7000 / 230 = 30.43 A (carried at 0.1 A: 30.4 A).
  final perPhaseNeed = math.sqrt(3) * 400 * 30.4; // 21 062 VA

  test('one board on L1 (the Round-36 case) still needs √3·400·30.4 = 21 062 VA',
      () {
    final p = _probe([PhaseLine.l1]);
    final sys = computeSystem(_p, p);
    expect(gensetPhaseDemandVa(p, sys), closeTo(perPhaseNeed, 1));
  });

  test('three equal boards on L1 / L2 / L3 need the SAME per-phase VA as one '
      '(each alternator line carries 30.4 A) => 33 kVA, no phase overload', () {
    final p = _probe([PhaseLine.l1, PhaseLine.l2, PhaseLine.l3]);
    final sys = computeSystem(_p, p);
    expect(gensetPhaseDemandVa(p, sys), closeTo(perPhaseNeed, 1));
    // kW basis: 3 x 7 kW = 21 kW / 0.8 = 26.25 kVA governs (> 21.06 kVA),
    // the first ladder rung >= 26.25 kVA is 33 kVA = 47.6 A per phase.
    final g = sizeGenerator(gensetBackupDemandVa(p, sys),
        backupPower: gensetBackupDemandW(p, sys));
    expect(g.ratingKva.inKilovoltAmperes, 33);
    final w = gensetBackupWarnings(
        _probe([PhaseLine.l1, PhaseLine.l2, PhaseLine.l3],
            kva: const ApparentPower(33000)),
        sys);
    expect(w.map((x) => x.code), isNot(contains('genset-phase-overload')));
  });

  test('two boards on the SAME line add on that line: √3·400·60.8 = 42 124 VA',
      () {
    final p = _probe([PhaseLine.l2, PhaseLine.l2]);
    final sys = computeSystem(_p, p);
    expect(gensetPhaseDemandVa(p, sys),
        closeTo(math.sqrt(3) * 400 * 60.8, 1));
  });

  test('seeded property: the per-phase need is the heaviest line, ≤ the '
      'per-board sum and ≥ the largest single board', () {
    final rng = math.Random(3737);
    for (var trial = 0; trial < 40; trial++) {
      final n = 1 + rng.nextInt(5);
      final lines = [
        for (var i = 0; i < n; i++) PhaseLine.values[rng.nextInt(3)]
      ];
      final p = _probe(lines);
      final sys = computeSystem(_p, p);
      final count = {for (final l in PhaseLine.values) l: 0};
      for (final l in lines) {
        count[l] = count[l]! + 1;
      }
      final heaviest = count.values.reduce(math.max);
      expect(gensetPhaseDemandVa(p, sys),
          closeTo(math.sqrt(3) * 400 * 30.4 * heaviest, 1 + heaviest),
          reason: '$lines');
    }
  });
}
