/// Round 26 electrical seed suite:
///   * fractional-genset-screens-no-motor — a genset backing a fraction of the
///     load with NO essential designation screens every motor (it used to
///     screen none and print no dip verdict);
///   * diversity-library-overrides-userset-and-standby-df — the occupancy
///     library replaces minted defaults only, never a user-set factor or a
///     standby machine's deliberate 0;
///   * ics-unchecked-on-incomers-and-final-mccbs — the IEC 60947-2 Ics test
///     runs on every specified device (incomer, final way, feeder), once.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/diversity_library.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const p = PuilProfile();

const _chiller = ElectricalCircuit(
  id: 'chiller',
  name: 'Chiller',
  loadKind: LoadKind.motor,
  motorKw: 110,
  cosPhi: 0.85,
  length: Length(30),
);

const _lighting = ElectricalCircuit(
  id: 'lt',
  name: 'Lighting',
  loadKind: LoadKind.lighting,
  loadW: 20000,
  cosPhi: 0.9,
  phases: 3,
  length: Length(20),
);

ElectricalProject _gensetProject(double backup) => ElectricalProject(
      id: 'pr',
      name: 'B',
      sources: ElectricalSources(
          generator: GeneratorSource(backupFraction: backup)),
      panels: const [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          system: ElectricalSystem.threePhase,
          voltage: Voltage(400),
          circuits: [_chiller, _lighting],
        ),
      ],
    );

void main() {
  group('a fractional genset with no essential board screens every motor', () {
    test('50 % backup, no essential designation: the chiller is screened', () {
      expect(gensetBackedPanelIds(_gensetProject(0.5)), isEmpty);
      expect(gensetStartMotors(_gensetProject(0.5)).map((m) => m.name),
          ['Chiller']);
    });

    test('the advanced study prints a start-dip verdict on the partial set',
        () {
      final pr = _gensetProject(0.5);
      final sys = computeSystem(p, pr);
      final adv = computeAdvancedStudy(p, pr, sys);
      final sub = adv.powerOneLine!.nodes.firstWhere((n) => n.id == 'gen').sub;
      // The 110 kW DOL start = 110 / 0.8 x 6 = 825 kVA on a set sized for half
      // the load: far beyond the 25 % dip limit, so a verdict MUST print.
      expect(sub, contains('start dip'));
    });

    test('property: with no essential board the screened set never depends '
        'on the backup fraction (seeded)', () {
      final full = gensetStartMotors(_gensetProject(1.0))
          .map((m) => m.name)
          .toList();
      final rnd = math.Random(2026);
      for (var i = 0; i < 40; i++) {
        final f = 0.01 + rnd.nextDouble() * 0.99;
        expect(gensetStartMotors(_gensetProject(f)).map((m) => m.name),
            full,
            reason: 'backup $f');
      }
    });
  });

  group('the diversity library replaces minted defaults only', () {
    const lib = PuilDiversityLibrary();
    const duty = ElectricalCircuit(
      id: 'duty',
      name: 'Duty pump',
      loadKind: LoadKind.pump,
      motorKw: 30,
      cosPhi: 0.85,
      length: Length(20),
    );
    const standby = ElectricalCircuit(
      id: 'sb',
      name: 'Standby pump',
      loadKind: LoadKind.pump,
      motorKw: 30,
      cosPhi: 0.85,
      demandFactor: 0,
      demandFactorUserSet: true,
      length: Length(20),
    );
    const typedLighting = ElectricalCircuit(
      id: 'lt',
      name: 'Lighting',
      loadKind: LoadKind.lighting,
      loadW: 2000,
      cosPhi: 0.9,
      demandFactor: 1.0,
      demandFactorUserSet: true,
      phases: 3,
      length: Length(20),
    );
    const mintedZero = ElectricalCircuit(
      id: 'z',
      name: 'Standby fan',
      loadKind: LoadKind.motor,
      motorKw: 5.5,
      cosPhi: 0.85,
      demandFactor: 0,
      length: Length(20),
    );

    test('user-set and zero factors survive; the duty pump takes the library',
        () {
      double eff(ElectricalCircuit c) => effectiveDemandFactor(c,
          library: lib, diversityLibraryId: 'office');
      expect(eff(standby), 0);
      expect(eff(mintedZero), 0);
      expect(eff(typedLighting), 1.0);
      expect(eff(duty),
          lib.demandFactorFor('office', LoadKind.pump, fallback: 1.0));
    });

    test('panel demand: only the minted duty pump is re-diversified', () {
      ElectricalProject pr(String? libId) => ElectricalProject(
            id: 'pr',
            name: 'B',
            panels: [
              ElectricalPanel(
                id: 'MDP',
                name: 'MDP',
                system: ElectricalSystem.threePhase,
                voltage: const Voltage(400),
                diversityLibraryId: libId,
                circuits: const [duty, standby, typedLighting],
              ),
            ],
          );
      final plain = computeSystem(p, pr(null)).panels['MDP']!;
      final withLib =
          computeSystem(p, pr('office'), diversityLibrary: lib).panels['MDP']!;
      // Without the library: duty 30 / 0.88 = 34 091 W + standby 0 + 2000 W.
      const dutyW = 30000 / kAssumedMotorEfficiency;
      expect(plain.demandW, closeTo(dutyW + 2000, 1));
      // With it: only the duty pump moves, by its library factor.
      final k = lib.demandFactorFor('office', LoadKind.pump, fallback: 1.0);
      expect(withLib.demandW, closeTo(dutyW * k + 2000, 1));
    });
  });

  group('Ics is judged on every specified MCCB, once', () {
    ElectricalProject board() => const ElectricalProject(
          id: 'pr',
          name: 'B',
          panels: [
            ElectricalPanel(
              id: 'MDP',
              name: 'MDP',
              system: ElectricalSystem.threePhase,
              voltage: Voltage(400),
              circuits: [_chiller, _lighting],
            ),
          ],
        );

    test('a 1600 kVA service (57.74 kA) flags the MCCB incomer and the MCCB '
        'chiller way', () {
      // Transformer-limited LV fault: S / (√3 · 400 · 0.04)
      //   = 1 600 000 / 27.713 = 57 735 A. A 70 kA MCCB has Ics = 0.75 x 70
      //   = 52.5 kA < 57.74 kA (and no MCCB rung covers both) ⇒ shortfall.
      final isc = 1600000 / (math.sqrt(3) * 400 * 0.04);
      expect(isc, closeTo(57735, 1));
      final pr = board();
      final sys = computeSystem(p, pr);
      final mdp = sys.panels['MDP']!;
      expect(mdp.incomer.breaker.deviceClass, BreakerClass.mccb);
      final chiller =
          mdp.circuits.firstWhere((c) => c.circuitId == 'chiller');
      expect(chiller.breaker.deviceClass, BreakerClass.mccb);
      final fs = faultStudy(sys, pr, p, originFaultLevel: Current(isc));
      final ics = fs.warnings
          .where((w) => w.code == 'service-capacity-inadequate')
          .toList();
      expect(ics.where((w) => w.panelId == 'MDP' && w.circuitId == null),
          hasLength(1),
          reason: 'incomer');
      expect(ics.where((w) => w.circuitId == 'chiller'), hasLength(1));
      expect(ics.first.message, contains('52.5 kA'));
    });

    test('property: a device is flagged exactly when its Icu holds but its '
        'Ics does not (seeded)', () {
      final pr = board();
      final sys = computeSystem(p, pr);
      final mdp = sys.panels['MDP']!;
      final rnd = math.Random(60947);
      for (var trial = 0; trial < 40; trial++) {
        final faultKa = 5 + rnd.nextDouble() * 70;
        final fs = faultStudy(sys, pr, p,
            originFaultLevel: Current(faultKa * 1000));
        bool expected(double ratingA, BreakerClass cls) {
          final icu = specifiedBreakerKa(ratingA, cls, faultKa);
          final frac = serviceCapacityFraction[cls] ?? 1;
          return icu + 1e-9 >= faultKa && icu * frac + 1e-9 < faultKa;
        }

        final flagged = <String?>[
          for (final w in fs.warnings)
            if (w.code == 'service-capacity-inadequate') w.circuitId,
        ];
        // Never twice for one device.
        expect(flagged.toSet().length, flagged.length, reason: 'trial $trial');
        expect(flagged.contains(null),
            expected(mdp.incomer.breaker.ratingA.amperes,
                mdp.incomer.breaker.deviceClass),
            reason: 'incomer @ $faultKa kA');
        for (final c in mdp.circuits) {
          expect(flagged.contains(c.circuitId),
              expected(c.breaker.ratingA.amperes, c.breaker.deviceClass),
              reason: '${c.circuitId} @ $faultKa kA');
        }
      }
    });
  });
}
