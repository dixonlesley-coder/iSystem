// Round 70 (elec-convergence-22-genset-start-dip-failure-never-a-warning) —
// the genset motor-start dip screen SIZES an unforced set and JUDGES a
// forced one: no surface buys a set the engine says cannot start its largest
// motor, and a ' · start dip NN% over' one-line label never stands without a
// `genset-start-dip-exceeded` warning.
//
// First principles (voltage-divider model on the TRANSIENT reactance X'd =
// 0.15 pu — backlog B-5 named it; the fault level uses X''d 0.12):
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
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart'
    show ElectricalWarning, WarningSeverity;
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

ElectricalProject _icu(
        {ApparentPower? forced,
        double pumpKw = 75,
        String pumpName = 'Fire pump',
        List<ElectricalCircuit> extraIcu = const []}) =>
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
                  name: pumpName,
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
              ...extraIcu,
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
    // The start floor is the first ladder rung >= 3 z (300 kVA), never the
    // load-only 150 kVA rung.
    final startSet = sizeGenerator(gensetBackupDemandVa(p, sys),
        backupPower: gensetBackupDemandW(p, sys),
        minKvaForStart: gensetStartFloorFor(p, sys));
    expect(startSet.ratingKva.inKilovoltAmperes, 300);
    expect(startSet.governing, GensetSizingReason.motorStart);
    // Backlog B-3 (2026-11-13): on 300 kVA the alternator fault is 300 000 /
    // (√3 × 400 × 0.12) = 3608 A and the fire pump's 160 A MCCB (10 × In ⇒
    // Zs_max 0.95 × 230 / 1600 = 0.137 Ω) sees a 0.143 Ω loop ⇒ it would
    // not disconnect on the genset. 400 kVA (4811 A) brings it to 0.132 Ω,
    // so the recommendation is 400 kVA, governed by disconnection.
    expect(sys.gensetAdsFloorKva, 400);
    final plant = gensetPlantVa(p, sys)! / 1000;
    expect(plant, 400);
    expect(st.gensetAdsFailedCircuitIds, isEmpty);
    expect(st.powerOneLine!.gensetSizing!.governing,
        GensetSizingReason.disconnection);
    expect(start.acceptable, isTrue);
    expect(start.estimatedDipPct, lessThanOrEqualTo(25));
    expect(_genNode(st).sub, isNot(contains('start dip')));
    expect(_dipWarnings(st), isEmpty);
    // The BOM buys the same 400 kVA set + its ATS.
    expect(st.bom.lines.any((l) => l.description.startsWith('Genset 400 kVA')),
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
          ? ApparentPower(1000.0 * [20, 50, 100, 150, 250, 400][rnd.nextInt(6)])
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

  // Round 71 (regression-1) — the severity is graded on EACH motor's own
  // life-safety flag and own dip, never by matching the limiting motor's
  // NAME. A 90 kW DOL non-life-safety pump on the ICU board starts at
  // ~755 kVA (z = 113.3, dip 113.3 / 263.3 = 43.0 % on 150 kVA) and is the
  // limiting motor.
  ElectricalCircuit chiller(String name) => ElectricalCircuit(
      id: 'cp',
      name: name,
      loadKind: LoadKind.pump,
      motorKw: 90,
      phases: 3,
      cosPhi: 0.88,
      starterType: StarterType.dol,
      length: const Length(20));
  ElectricalWarning dipOf(AdvancedStudy st) =>
      st.warnings.singleWhere((w) => w.code == 'genset-start-dip-exceeded');

  test('(B) a failing life-safety motor that is NOT limiting is an ERROR', () {
    final st = _study(_icu(
        forced: const ApparentPower(150e3),
        extraIcu: [chiller('Chiller pump')]));
    final start = st.powerOneLine!.gensetStart!;
    expect(start.limitingMotorName, 'Chiller pump');
    expect(start.estimatedDipPct, closeTo(43.0, 0.3));
    // The 75 kW fire pump's own dip ~38.6 % > 25 %: it must start on mains
    // failure, so the screen blocks sign-off.
    expect(start.failingLifeSafetyMotors.map((m) => m.circuitId), ['fp']);
    final w = dipOf(st);
    expect(w.severity, WarningSeverity.error);
    expect(w.message, contains('Chiller pump'));
    expect(w.message, contains('Fire pump'));
  });

  test('(A) a name shared with a passing life-safety motor is a WARNING', () {
    // The 5.5 kW life-safety pump dips ~5 % (passes); the limiting 90 kW
    // non-life-safety pump carries the SAME name.
    final st = _study(_icu(
        forced: const ApparentPower(150e3),
        pumpKw: 5.5,
        pumpName: 'Pump A',
        extraIcu: [chiller('Pump A')]));
    final start = st.powerOneLine!.gensetStart!;
    expect(start.limitingMotorName, 'Pump A');
    expect(start.acceptable, isFalse);
    expect(start.failingLifeSafetyMotors, isEmpty);
    expect(dipOf(st).severity, WarningSeverity.warning);
  });

  test('seeded: ERROR iff some life-safety motor fails on its own dip', () {
    final rnd = math.Random(7171);
    var errors = 0, warnings = 0;
    for (var t = 0; t < 60; t++) {
      final kw = [5.5, 11.0, 22.0, 37.0, 55.0, 75.0][rnd.nextInt(6)];
      final other = [0.0, 22.0, 55.0, 90.0, 110.0][rnd.nextInt(5)];
      final forced =
          ApparentPower(1000.0 * [50, 100, 150, 250][rnd.nextInt(4)]);
      final name = rnd.nextBool() ? 'Pump A' : 'Fire pump';
      final st =
          _study(_icu(forced: forced, pumpKw: kw, pumpName: name, extraIcu: [
        if (other > 0)
          ElectricalCircuit(
              id: 'cp',
              name: rnd.nextBool() ? name : 'Chiller pump',
              loadKind: LoadKind.pump,
              motorKw: other,
              phases: 3,
              cosPhi: 0.88,
              starterType: StarterType.dol,
              length: const Length(20)),
      ]));
      final start = st.powerOneLine!.gensetStart!;
      if (start.acceptable) continue;
      // Each motor's own dip, from the screen's own model:
      // dip = 100 z / (S_gen + z), z = 0.15 S_start.
      final lsFail = start.failingLifeSafetyMotors.isNotEmpty;
      for (final m in start.failingLifeSafetyMotors) {
        expect(m.lifeSafety, isTrue);
        final z = m.startKva!.inKilovoltAmperes * 0.15;
        expect(100 * z / (forced.inKilovoltAmperes + z), greaterThan(25));
      }
      final w = dipOf(st);
      expect(
          w.severity, lsFail ? WarningSeverity.error : WarningSeverity.warning,
          reason: 'trial $t kw $kw other $other $forced');
      lsFail ? errors++ : warnings++;
    }
    expect(errors, greaterThan(0));
    expect(warnings, greaterThan(0));
  });
}

