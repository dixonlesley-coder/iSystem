// Round 65 (elec-convergence-17-genset-backup-fraction-unreachable-essential-
// only-set-sized-for-whole-building) — an UNTYPED genset backup fraction
// follows the essential designation.
//
// MDP: 3 x 30 kW heaters (cos phi 1, 3ph), a 15 kW chiller motor and a
// feeder to EMDP (one 10 kW, cos phi 1, 3ph way).
//  * untyped fraction, EMDP essential: backup = max(0 x the building, 10 kVA
//    essential, floored at its largest machine 10 kVA) = 10 kVA — the set
//    the essential sub-tree needs; the dip screen starts only the essential
//    sub-tree's motors and the one-line draws the essential split.
//  * untyped, nothing essential: the whole building, 100 kVA.
//  * a typed fraction (incl. an explicit legacy 1.0) is the engineer's:
//    max(f x the building demand, 10 kVA).
library;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

ElectricalProject _proj({double? fraction, bool essential = true}) =>
    ElectricalProject(
      id: 'g',
      name: 'g',
      sources: ElectricalSources(
          generator: GeneratorSource(backupFraction: fraction)),
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          system: ElectricalSystem.threePhase,
          voltage: const Voltage(400),
          circuits: [
            for (var i = 0; i < 3; i++)
              ElectricalCircuit(
                id: 'h$i',
                name: 'Heater $i',
                loadKind: LoadKind.general,
                loadW: 30000,
                cosPhi: 1,
                phases: 3,
                length: const Length(10),
              ),
            const ElectricalCircuit(
              id: 'm1',
              name: 'Chiller',
              loadKind: LoadKind.motor,
              motorKw: 15,
              phases: 3,
              length: Length(10),
            ),
            const ElectricalCircuit(
                id: 'fe',
                name: 'to EMDP',
                loadKind: LoadKind.feeder,
                feedsPanelId: 'EMDP',
                length: Length(10)),
          ],
        ),
        ElectricalPanel(
          id: 'EMDP',
          name: 'EMDP',
          system: ElectricalSystem.threePhase,
          voltage: const Voltage(400),
          essential: essential,
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'fe',
          circuits: const [
            ElectricalCircuit(
              id: 'e1',
              name: 'Essential',
              loadKind: LoadKind.general,
              loadW: 10000,
              cosPhi: 1,
              phases: 3,
              length: Length(10),
            ),
          ],
        ),
      ],
    );

void main() {
  test('untyped + essential board: the set backs the essential sub-tree', () {
    final pr = _proj();
    final sys = computeSystem(_p, pr);
    expect(effectiveGeneratorBackupFraction(pr), 0.0);
    // The EMDP board's own 10 kW at cos phi 1 = 10 kVA.
    expect(gensetBackupDemandVa(pr, sys).voltAmperes, closeTo(10000, 1));
    expect(gensetBackupDemandW(pr, sys).watts, closeTo(10000, 1));
    // The MDP chiller is not started by the set.
    final motors = gensetStartMotors(pr, sys: sys);
    expect(motors, isEmpty);
    // The one-line draws the essential split behind the ATS.
    final study = computeAdvancedStudy(_p, pr, sys);
    final labels = [
      for (final n in study.powerOneLine!.nodes) n.label,
    ].join(' | ');
    expect(labels.toLowerCase(), contains('essential'));
  });

  test('untyped + no essential board: the whole building', () {
    final pr = _proj(essential: false);
    final sys = computeSystem(_p, pr);
    expect(effectiveGeneratorBackupFraction(pr), 1.0);
    final whole = sys.supply.demandVa.voltAmperes;
    expect(gensetBackupDemandVa(pr, sys).voltAmperes,
        greaterThanOrEqualTo(whole - 1));
    expect(gensetStartMotors(pr, sys: sys).map((m) => m.name),
        contains('Chiller'));
  });

  test('a typed fraction is the engineer\'s (legacy 1.0 kept)', () {
    final one = _proj(fraction: 1.0);
    final sysOne = computeSystem(_p, one);
    expect(gensetBackupDemandVa(one, sysOne).voltAmperes,
        greaterThanOrEqualTo(sysOne.supply.demandVa.voltAmperes - 1));
    final part = _proj(fraction: 0.6);
    final sysPart = computeSystem(_p, part);
    expect(gensetBackupDemandVa(part, sysPart).voltAmperes,
        closeTo(0.6 * sysPart.supply.demandVa.voltAmperes, 1));
  });

  test('.mechx: untyped writes no fraction; typed round-trips', () {
    final untyped = _proj().toJson();
    final g = (untyped['sources'] as Map)['generator'] as Map;
    expect(g.containsKey('backupFraction'), isFalse);
    final back = ElectricalProject.fromJson(untyped);
    expect(back.sources!.generator!.backupFractionTyped, isNull);
    final typed = ElectricalProject.fromJson(_proj(fraction: 0.6).toJson());
    expect(typed.sources!.generator!.backupFractionTyped, 0.6);
    // A legacy explicit 1.0 stays typed (whole building, as saved).
    final legacy = ElectricalProject.fromJson(_proj(fraction: 1.0).toJson());
    expect(legacy.sources!.generator!.backupFractionTyped, 1.0);
    expect(effectiveGeneratorBackupFraction(legacy), 1.0);
  });
}
