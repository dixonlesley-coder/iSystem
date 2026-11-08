// Round 80 (2026-10-18) — genset convergence.
//
// (1) regression-genset-1ph-siblings-under-1ph-board-lpt-spread — 1φ boards
//     fed from ONE 1φ board share that board's single alternator line. 3φ
//     root M (3 kW heater, 4.3 A/line) beside 1φ root R (230 V) feeding two
//     essential 1φ boards E1 / E2, each 3 x 3 kW sockets at cos 0.9:
//     I = 9000 / (230 x 0.9) = 43.48 A each, so R's line carries 86.96 A and
//     the per-phase need is sqrt3 x 400 x 86.96 = 60.25 kVA — never the
//     sqrt3 x 400 x 43.48 = 30.1 kVA of E1 and E2 on separate lines. A forced
//     40 kVA set is 40000 / 692.8 = 57.7 A per phase < 86.96 A ⇒
//     `genset-phase-overload`.
//
// (2) elec-convergence-31-primary-genset-plant-sized-as-partial-standby — an
//     on-site genset PRIMARY supply (supplyKind generator) is the only
//     source: it is sized on the whole demand (fraction 1.0) whatever the
//     essential marks / a typed fraction say, its fault follows that plant
//     (S / (sqrt3 x 400 x 0.12)), its dip screen covers every motor, and a
//     standby mode raises the info `primary-genset-typed-standby`.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart' show StarterType;
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();
final _s3 = math.sqrt(3) * 400;

ElectricalCircuit _socket(String id, double w) => ElectricalCircuit(
    id: id,
    name: id,
    loadKind: LoadKind.socket,
    loadW: w,
    cosPhi: 0.9,
    phases: 1,
    length: const Length(10));

ElectricalCircuit _feeder(String id, String to) => ElectricalCircuit(
    id: id,
    name: 'F $to',
    loadKind: LoadKind.feeder,
    feedsPanelId: to,
    length: const Length(10));

ElectricalPanel _onePh(String id, List<ElectricalCircuit> c,
        {bool essential = false}) =>
    ElectricalPanel(
        id: id,
        name: 'Board $id',
        system: ElectricalSystem.singlePhase,
        voltage: const Voltage(230),
        essential: essential,
        circuits: c);

ElectricalProject _siblings(int k, {ApparentPower? forced, double w = 3000}) =>
    ElectricalProject(
      id: 'p',
      name: 'p',
      sources: ElectricalSources(
          generator: GeneratorSource(kva: forced, backupFraction: 0.1)),
      panels: [
        const ElectricalPanel(id: 'M', name: 'Main M', circuits: [
          ElectricalCircuit(
              id: 'M-a',
              name: 'Heater',
              loadKind: LoadKind.heating,
              loadW: 3000,
              cosPhi: 1,
              phases: 3,
              length: Length(10)),
        ]),
        _onePh('R', [for (var i = 0; i < k; i++) _feeder('R-f$i', 'E$i')]),
        for (var i = 0; i < k; i++)
          _onePh('E$i', [for (var j = 0; j < 3; j++) _socket('E$i-$j', w)],
              essential: true),
      ],
    );

void main() {
  group('(1) 1ph siblings under one 1ph board share its line', () {
    test('two 43.5 A boards under R => sqrt3 x 400 x 87.0 A', () {
      final pr = _siblings(2);
      final sys = computeSystem(_profile, pr);
      final e = sys.panels['E0']!.diversifiedDemandCurrent.amperes;
      expect(e, closeTo(9000 / (230 * 0.9), 0.1));
      expect(gensetPhaseDemandVa(pr, sys), closeTo(_s3 * 2 * e, 40));
    });

    test('a forced 40 kVA set (57.7 A/phase) raises genset-phase-overload',
        () {
      final pr = _siblings(2, forced: const ApparentPower(40000));
      final sys = computeSystem(_profile, pr);
      final st = computeAdvancedStudy(_profile, pr, sys);
      expect(st.warnings.where((w) => w.code == 'genset-phase-overload'),
          isNotEmpty);
    });

    test('a 1ph board under a 3ph root resolves to its feeding way line', () {
      // 3ph MDP -> 1ph SDB (on one labelled line) -> E0, E1 essential: both
      // on SDB's line, so the heaviest line is MDP's own on that line +
      // E0 + E1.
      final pr = ElectricalProject(
        id: 'p',
        name: 'p',
        sources: const ElectricalSources(
            generator: GeneratorSource(backupFraction: 0.1)),
        panels: [
          ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
            _feeder('m-f', 'SDB'),
          ]),
          _onePh('SDB', [_feeder('s0', 'E0'), _feeder('s1', 'E1')]),
          _onePh('E0', [_socket('a0', 3000), _socket('a1', 3000)],
              essential: true),
          _onePh('E1', [_socket('b0', 3000), _socket('b1', 3000)],
              essential: true),
        ],
      );
      final sys = computeSystem(_profile, pr);
      final i = sys.panels['E0']!.diversifiedDemandCurrent.amperes +
          sys.panels['E1']!.diversifiedDemandCurrent.amperes;
      expect(gensetPhaseDemandVa(pr, sys), closeTo(_s3 * i, 40));
    });

    test('seeded property: k siblings under a 1ph root never split', () {
      final rnd = math.Random(80);
      for (var t = 0; t < 40; t++) {
        final k = 2 + rnd.nextInt(3);
        final w = 500.0 + rnd.nextInt(2500);
        final pr = _siblings(k, w: w);
        final sys = computeSystem(_profile, pr);
        var sum = 0.0;
        for (var i = 0; i < k; i++) {
          sum += sys.panels['E$i']!.diversifiedDemandCurrent.amperes;
        }
        expect(gensetPhaseDemandVa(pr, sys),
            greaterThanOrEqualTo(_s3 * sum - 40),
            reason: 'trial $t: k=$k w=$w');
      }
    });
  });

  group('(2) a primary genset plant carries the whole building', () {
    ElectricalProject build({double? fraction, bool essential = true}) =>
        ElectricalProject(
          id: 'p',
          name: 'p',
          supplyKind: SupplyKind.generator,
          earthingSystem: EarthingSystem.tnS,
          sources: ElectricalSources(
              generator: GeneratorSource(backupFraction: fraction)),
          panels: [
            ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
              _feeder('f1', 'PLANT'),
              _feeder('f2', 'FIRE'),
            ]),
            ElectricalPanel(id: 'PLANT', name: 'PLANT', circuits: [
              for (var i = 0; i < 4; i++)
                ElectricalCircuit(
                    id: 'c$i',
                    name: 'Crusher $i',
                    loadKind: LoadKind.motor,
                    motorKw: 45,
                    phases: 3,
                    cosPhi: 0.85,
                    starterType: StarterType.starDelta,
                    length: const Length(30)),
            ]),
            ElectricalPanel(
                id: 'FIRE',
                name: 'FIRE',
                essential: essential,
                circuits: const [
                  ElectricalCircuit(
                      id: 'l',
                      name: 'Light',
                      loadKind: LoadKind.lighting,
                      loadW: 2000,
                      phases: 1,
                      length: Length(10)),
                ]),
          ],
        );

    test('essential mark / typed 0.6 never shrink the plant below the '
        'no-essential figure', () {
      final ref = build(essential: false);
      final refSys = computeSystem(_profile, ref);
      final refPlant = gensetPlantVa(ref, refSys)!;
      // The plant covers the whole solved demand.
      expect(refPlant, greaterThanOrEqualTo(refSys.supply.demandVa.voltAmperes));
      for (final pr in [build(), build(fraction: 0.6)]) {
        final sys = computeSystem(_profile, pr);
        expect(effectiveGeneratorBackupFraction(pr), 1.0);
        expect(gensetPlantVa(pr, sys), refPlant);
        expect(onSitePrimaryPlantVa(pr, sys), refPlant);
        // The service fault is the plant's alternator fault S/(sqrt3 400 Xd'').
        expect(serviceFaultEstimateFor(pr, sys)!.amperes,
            closeTo(refPlant / (_s3 * 0.12), 1));
        // Every 45 kW motor is screened for the start dip.
        expect(
            gensetStartMotors(pr, sys: sys).where((m) => m.circuitId != null)
                .length,
            4);
      }
    });

    test('a standby-mode primary set raises primary-genset-typed-standby; '
        'a prime one does not; a PLN service never', () {
      final pr = build();
      final sys = computeSystem(_profile, pr);
      expect(
          gensetBackupWarnings(pr, sys)
              .where((w) => w.code == 'primary-genset-typed-standby'),
          isNotEmpty);
      final prime = ElectricalProject(
          id: 'p',
          name: 'p',
          supplyKind: SupplyKind.generator,
          sources: const ElectricalSources(
              generator: GeneratorSource(mode: GeneratorMode.prime)),
          panels: pr.panels);
      expect(
          gensetBackupWarnings(prime, computeSystem(_profile, prime))
              .where((w) => w.code == 'primary-genset-typed-standby'),
          isEmpty);
      final pln = ElectricalProject(
          id: 'p', name: 'p', sources: pr.sources, panels: pr.panels);
      expect(
          gensetBackupWarnings(pln, computeSystem(_profile, pln))
              .where((w) => w.code == 'primary-genset-typed-standby'),
          isEmpty);
      // A PLN standby set with an essential board keeps the essential-only
      // basis (byte-identical Round-65 reading).
      expect(effectiveGeneratorBackupFraction(pln), 0.0);
    });
  });
}
