// Round 70 (elec-convergence-22-genset-start-dip-failure-never-a-warning) —
// the genset motor-start dip screen SIZES an unforced set and JUDGES a
// forced one: no surface buys a set the engine says cannot start its largest
// motor, and a ' · start dip NN% over' one-line label never stands without a
// `genset-start-dip-exceeded` warning.
//
// First principles (voltage-divider model, Xd'' = 0.15 pu):
//   z = S_start x 0.15, dip = 100 z / (S_gen + z) <= 25 %
//   ⇒ S_gen >= z (100 - 25) / 25 = 3 z.
// The probe's 75 kW DOL life-safety fire pump starts at S_start ≈ 630 kVA
// (FLC = 75/0.88 kW / (sqrt3 x 400 x 0.88) = 139.8 A, x 6.5 DOL, x sqrt3 x
// 400), so z ≈ 94.5 kVA and the minimum set ≈ 283 kVA: the 150 kVA set the
// essential load alone selects dips 94.5 / 244.5 = 38.6 %.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart' show StarterType;
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart' show WarningSeverity;
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

ElectricalProject _icu({ApparentPower? forced, double pumpKw = 75}) =>
    ElectricalProject(
      id: 'icu',
      name: 'ICU wing',
      earthingSystem: EarthingSystem.tnCs,
      supplyCapacityVa: const ApparentPower(555e3),
      sources: ElectricalSources(generator: GeneratorSource(kva: forced)),
      panels: [
        ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            voltage: const Voltage(400),
            circuits: [
              for (var i = 0; i < 4; i++)
                ElectricalCircuit(
                    id: 'p$i',
                    name: 'Power $i',
                    loadKind: LoadKind.heating,
                    loadW: 50000,
                    phases: 3,
                    length: const Length(20)),
              const ElectricalCircuit(
                  id: 'fE',
                  name: 'EMDP feeder',
                  loadKind: LoadKind.feeder,
                  cableType: 'FRC',
                  length: Length(20),
                  feedsPanelId: 'EMDP'),
            ]),
        ElectricalPanel(
            id: 'EMDP',
            name: 'EMDP',
            voltage: const Voltage(400),
            essential: true,
            circuits: [
              ElectricalCircuit(
                  id: 'fp',
                  name: 'Fire pump',
                  loadKind: LoadKind.pump,
                  motorKw: pumpKw,
                  phases: 3,
                  cosPhi: 0.88,
                  cableType: 'FRC',
                  lifeSafety: true,
                  starterType: StarterType.dol,
                  length: const Length(60)),
              const ElectricalCircuit(
                  id: 'jp',
                  name: 'Jockey',
                  loadKind: LoadKind.pump,
                  motorKw: 3,
                  phases: 3,
                  starterType: StarterType.dol,
                  length: Length(20)),
              const ElectricalCircuit(
                  id: 'fI',
                  name: 'ICU feeder',
                  loadKind: LoadKind.feeder,
                  length: Length(20),
                  feedsPanelId: 'ICU'),
            ]),
        ElectricalPanel(
            id: 'ICU',
            name: 'ICU',
            voltage: const Voltage(400),
            essential: true,
            circuits: [
              for (var i = 0; i < 6; i++)
                ElectricalCircuit(
                    id: 's$i',
                    name: 'Socket $i',
                    loadKind: LoadKind.socket,
                    loadW: 2500,
                    length: const Length(20)),
              const ElectricalCircuit(
                  id: 'lt',
                  name: 'Lighting',
                  loadKind: LoadKind.lighting,
                  loadW: 1500,
                  length: Length(20)),
            ]),
      ],
    );

AdvancedStudy _study(ElectricalProject p) =>
    computeAdvancedStudy(_profile, p, computeSystem(_profile, p));

PowerNode _genNode(AdvancedStudy st) =>
    st.powerOneLine!.nodeOfKind(PowerNodeKind.generator)!;

List<String> _dipWarnings(AdvancedStudy st) => [
      for (final w in st.warnings)
        if (w.code == 'genset-start-dip-exceeded') w.message,
    ];

void main() {
  test('an unforced set is sized to start the 75 kW fire pump (>= 3 z)', () {
    final p = _icu();
    final sys = computeSystem(_profile, p);
    final st = computeAdvancedStudy(_profile, p, sys);
    final start = st.powerOneLine!.gensetStart!;
    // z = 0.15 x S_start; the floor is 3 z.
    final z = start.startingKva.inKilovoltAmperes * 0.15;
    expect(start.startingKva.inKilovoltAmperes, closeTo(629.8, 2.0));
    expect(gensetStartFloorFor(p, sys).inKilovoltAmperes, closeTo(3 * z, 0.1));
    // The plant is the first ladder rung >= 3 z (300 kVA), never the
    // load-only 150 kVA rung.
    final plant = gensetPlantVa(p, sys)! / 1000;
    expect(plant, 300);
    expect(start.acceptable, isTrue);
    expect(start.estimatedDipPct, lessThanOrEqualTo(25));
    expect(_genNode(st).sub, isNot(contains('start dip')));
    expect(_dipWarnings(st), isEmpty);
    // The BOM buys the same 300 kVA set + its ATS.
    expect(st.bom.lines.any((l) => l.description.startsWith('Genset 300 kVA')),
        isTrue);
  });

  test('a forced 150 kVA nameplate is judged: ERROR on a life-safety motor',
      () {
    final st = _study(_icu(forced: const ApparentPower(150e3)));
    final start = st.powerOneLine!.gensetStart!;
    final z = start.startingKva.inKilovoltAmperes * 0.15;
    // dip = 100 z / (150 + z) ≈ 38.6 %.
    expect(start.estimatedDipPct, closeTo(100 * z / (150 + z), 0.01));
    expect(start.estimatedDipPct, closeTo(38.6, 0.2));
    expect(_genNode(st).sub, contains('start dip'));
    final w = st.warnings
        .where((w) => w.code == 'genset-start-dip-exceeded')
        .toList();
    expect(w, hasLength(1));
    expect(w.single.severity, WarningSeverity.error);
    expect(w.single.message, contains('Fire pump'));
    // The forced nameplate is still bought verbatim (judged, never resized).
    expect(st.bom.lines.any((l) => l.description.startsWith('Genset 150 kVA')),
        isTrue);
  });

  test('seeded: a start-dip label always carries the warning (and only then)',
      () {
    final rnd = math.Random(7070);
    var flagged = 0;
    for (var t = 0; t < 60; t++) {
      final kw = [5.5, 11.0, 22.0, 37.0, 55.0, 75.0, 110.0][rnd.nextInt(7)];
      final forced = rnd.nextBool()
          ? ApparentPower(
              1000.0 * [20, 50, 100, 150, 250, 400][rnd.nextInt(6)])
          : null;
      final st = _study(_icu(forced: forced, pumpKw: kw));
      final labelled = _genNode(st).sub?.contains('start dip') ?? false;
      expect(_dipWarnings(st).isNotEmpty, labelled,
          reason: 'trial $t kw=$kw forced=$forced');
      if (forced == null) expect(labelled, isFalse);
      if (labelled) flagged++;
    }
    expect(flagged, greaterThan(0)); // non-vacuous
  });
}
