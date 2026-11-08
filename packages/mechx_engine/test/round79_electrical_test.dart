// Round 79 (2026-10-18) — electrical convergence on MIXED-system services.
//
// `sys.supply.system` is the GOVERNING root's (largest incomer). Since
// Round 78 the daya ladder and the alternator SIZING read the boards
// (any 3ph root => a 3ph service / alternator); Round 79 brings the fault,
// the genset per-line basis, the multi-root daya judge and the printed
// service onto the same reading.
//
// (1) regression-genset-fault-1ph-u0-on-3ph-alternator-ads-pass — a
//     standby set sized as a 3ph alternator is faulted on
//     S / (sqrt3 x 400 x Xd'') = S / (692.8 x 0.12), never the ~3x larger
//     S / (230 x 0.12) of a single-phase machine. Board M (3ph): 5 kW +
//     a 30 kW 3ph heater 'far' at 116 m; board S (1ph, governs): 8 x 3 kW
//     sockets at cos 0.9. On the real 3ph alternator fault 'far' fails ADS.
//
// (2) elec-convergence-30-multi-root-declared-daya-never-judged — 3ph root
//     M 6 x 10 kW (86.6 A) + 1ph S, T at 3 x 3 kW / cos 0.9 (43.5 A each),
//     declared 33 kVA. The study's per-line allocation puts S and T on
//     different lines: heaviest line = 86.6 + 43.5 = 130.1 A, above the
//     33 000 / (sqrt3 x 400) = 47.6 A limiter => `service-capacity-below-
//     demand`. 105 kVA (151.6 A) passes.
//
// (3) elec-convergence-30-genset-sums-1ph-roots-onto-one-alternator-line —
//     3ph M (3 kW => 4.3 A) + three 1ph shops at 43.5 A: LPT puts one shop
//     on each line => 4.3 + 43.5 = 47.8 A => sqrt3 x 400 x 47.8 = 33.1 kVA
//     (== the study's per-line basis), never 3.0 + 3 x 30.1 = 93.4 kVA.
//
// (4) elec-convergence-30-supply-printed-1ph-230v-on-a-3ph-service — the
//     printed supply follows [serviceSystemOf]: 'Three-phase, 400 V' and
//     'Main LV bus 400 V' whenever a 3ph root exists.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();
final _s3 = math.sqrt(3) * 400;

ElectricalCircuit _heater(String id, double w, {double len = 10}) =>
    ElectricalCircuit(
        id: id,
        name: id,
        loadKind: LoadKind.heating,
        loadW: w,
        cosPhi: 1,
        phases: 3,
        length: Length(len));

ElectricalPanel _main(String id, List<ElectricalCircuit> c) =>
    ElectricalPanel(id: id, name: 'Main $id', circuits: c);

ElectricalPanel _shop(String id, List<double> ways) => ElectricalPanel(
      id: id,
      name: 'Shop $id',
      system: ElectricalSystem.singlePhase,
      voltage: const Voltage(230),
      circuits: [
        for (var i = 0; i < ways.length; i++)
          ElectricalCircuit(
              id: '$id-$i',
              name: 'Socket $i',
              loadKind: LoadKind.socket,
              loadW: ways[i],
              cosPhi: 0.9,
              phases: 1,
              length: const Length(10)),
      ],
    );

void main() {
  group('(1) the on-site source is faulted on its alternator basis', () {
    ElectricalProject build(double farM) => ElectricalProject(
          id: 'p',
          name: 'p',
          sources: const ElectricalSources(generator: GeneratorSource()),
          panels: [
            _main('M',
                [_heater('M-a', 5000), _heater('far', 30000, len: farM)]),
            _shop('S', [for (var i = 0; i < 8; i++) 3000]),
          ],
        );

    test('a 1ph-governed service with a 3ph root: S/(sqrt3 400 Xd)', () {
      final pr = build(116);
      final sys = computeSystem(_profile, pr);
      expect(sys.supply.system, ElectricalSystem.singlePhase);
      expect(alternatorBasis(pr, sys).threePhase, isTrue);
      expect(onSiteSinglePhaseU0(pr, sys), isNull);
      final b = gensetFaultBasis(pr, sys)!;
      expect(b.iscA, closeTo(b.va / _s3 / kAlternatorXdPu, 1e-6));
      // Never the single-phase S/(U0 Xd): 692.8 / 230 = 3.01x larger.
      expect(b.va / 230 / kAlternatorXdPu / b.iscA, closeTo(_s3 / 230, 1e-9));
    });

    test('a way that passes on the 1ph figure fails ADS on the 3ph '
        'alternator (ERROR)', () {
      var hit = 0;
      for (final len in [108.0, 116.0, 120.0, 132.0, 140.0]) {
        final pr = build(len);
        final sys = computeSystem(_profile, pr);
        final b = gensetFaultBasis(pr, sys)!;
        final g =
            faultStudy(sys, pr, _profile, originFaultLevel: Current(b.iscA));
        final st = computeAdvancedStudy(_profile, pr, sys);
        final raised = st.warnings.any((w) =>
            w.code == 'ads-disconnection-on-genset' &&
            w.circuitId == 'far' &&
            w.severity == WarningSeverity.error);
        // The judge agrees with the alternator-basis study, both ways.
        expect(raised, g.circuits['far']!.adsOk == false, reason: '$len m');
        if (raised) hit++;
      }
      expect(hit, greaterThan(0));
      final pr = build(116);
      final sys = computeSystem(_profile, pr);
      final st = computeAdvancedStudy(_profile, pr, sys);
      expect(st.gensetAdsFailedCircuitIds, contains('far'));
    });

    test('an all-1ph service keeps the 1ph U0 basis (byte-identical)', () {
      final pr = ElectricalProject(
        id: 'p',
        name: 'p',
        sources: const ElectricalSources(generator: GeneratorSource()),
        panels: [
          _shop('S', [3000, 3000])
        ],
      );
      final sys = computeSystem(_profile, pr);
      expect(onSiteSinglePhaseU0(pr, sys), 230);
      final b = gensetFaultBasis(pr, sys)!;
      expect(b.iscA, closeTo(b.va / 230 / kAlternatorXdPu, 1e-6));
    });
  });

  group('(2) the declared daya is judged with several roots', () {
    ElectricalProject build(double va) => ElectricalProject(
          id: 'p',
          name: 'p',
          supplyCapacityVa: ApparentPower(va),
          panels: [
            _main('M', [for (var i = 0; i < 6; i++) _heater('M-$i', 10000)]),
            _shop('S', [3000, 3000, 3000]),
            _shop('T', [3000, 3000, 3000]),
          ],
        );
    bool warns(ElectricalProject pr) => computeSystem(_profile, pr)
        .warnings
        .any((w) => w.code == 'service-capacity-below-demand');

    test('33 / 66 kVA below the 130.1 A heaviest line warn', () {
      expect(33000 / _s3, closeTo(47.6, 0.05));
      expect(66000 / _s3, closeTo(95.3, 0.05));
      for (final va in [33000.0, 66000.0]) {
        final pr = build(va);
        final sys = computeSystem(_profile, pr);
        final w = sys.warnings
            .where((w) => w.code == 'service-capacity-below-demand')
            .toList();
        expect(w, hasLength(1), reason: '$va');
        // Heaviest line = M's 86.6 A + one shop's 43.5 A.
        expect(w.single.message, contains('130.1 A'));
        expect(w.single.panelId, 'M');
        // Fans into the board's own list too (compliance + locate).
        expect(sys.panels['M']!.warnings.contains(w.single), isTrue);
      }
    });

    test('105 kVA (151.6 A per phase) passes; the heaviest line is the '
        'study per-line basis', () {
      expect(warns(build(105000)), isFalse);
      final pr = build(33000);
      final sys = computeSystem(_profile, pr);
      final basis = studySupplyInputs(pr, sys).perPhaseBasisVa;
      expect(basis / _s3, closeTo(130.1, 0.1));
    });

    test('single-root service unchanged (the Round-35 judge only)', () {
      final pr = ElectricalProject(
          id: 'p',
          name: 'p',
          supplyCapacityVa: const ApparentPower(33000),
          panels: [
            _main('M', [for (var i = 0; i < 6; i++) _heater('M-$i', 10000)])
          ]);
      final w = computeSystem(_profile, pr)
          .warnings
          .where((w) => w.code == 'service-capacity-below-demand');
      expect(w, hasLength(1));
      expect(w.single.message, contains('worst-loaded'));
    });

    test('seeded property: warns iff the heaviest allocated line exceeds the '
        'limiter', () {
      final rnd = math.Random(79);
      var fired = 0, quiet = 0;
      for (var t = 0; t < 40; t++) {
        final nShops = 2 + rnd.nextInt(3);
        final nHeaters = 1 + rnd.nextInt(4);
        final pr0 = ElectricalProject(id: 'p', name: 'p', panels: [
          _main('M', [
            for (var i = 0; i < nHeaters; i++)
              _heater('M-$i', 2000.0 + rnd.nextInt(10) * 1000)
          ]),
          for (var s = 0; s < nShops; s++)
            _shop('S$s', [
              for (var i = 0, n = 1 + rnd.nextInt(3); i < n; i++)
                1000.0 + rnd.nextInt(3) * 1000
            ]),
        ]);
        final sys0 = computeSystem(_profile, pr0);
        final lineA = studySupplyInputs(pr0, sys0).perPhaseBasisVa / _s3;
        for (final va in [23000.0, 33000.0, 41500.0, 53000.0, 66000.0]) {
          final pr = ElectricalProject(
              id: 'p',
              name: 'p',
              supplyCapacityVa: ApparentPower(va),
              panels: pr0.panels);
          final limit = va / _s3;
          if ((lineA - limit).abs() < 0.2) continue; // rounding band
          final w = warns(pr);
          expect(w, lineA > limit,
              reason: 'trial $t va $va line $lineA limit $limit');
          w ? fired++ : quiet++;
        }
      }
      expect(fired, greaterThan(0));
      expect(quiet, greaterThan(0));
    });
  });

  group('(3) the genset spreads 1ph roots over the alternator lines', () {
    ElectricalProject build({ApparentPower? forced}) => ElectricalProject(
          id: 'p',
          name: 'p',
          sources: ElectricalSources(generator: GeneratorSource(kva: forced)),
          panels: [
            _main('M', [_heater('M-a', 3000)]),
            _shop('S', [3000, 3000, 3000]),
            _shop('T', [3000, 3000, 3000]),
            _shop('U', [3000, 3000, 3000]),
          ],
        );

    test('per-line basis == the supply study basis (33.1 kVA)', () {
      final pr = build();
      final sys = computeSystem(_profile, pr);
      final studied = studySupplyInputs(pr, sys).perPhaseBasisVa;
      expect(studied, closeTo((4.3 + 43.5) * _s3, 40));
      expect(gensetPhaseDemandVa(pr, sys), closeTo(studied, 40));
      expect(gensetBackupDemandVa(pr, sys).voltAmperes, lessThan(40000));
    });

    test('a forced 40 kVA set raises no genset-phase-overload', () {
      final pr = build(forced: const ApparentPower(40000));
      final sys = computeSystem(_profile, pr);
      final st = computeAdvancedStudy(_profile, pr, sys);
      expect(st.warnings.where((w) => w.code == 'genset-phase-overload'),
          isEmpty);
    });

    test('one 1ph root keeps the conservative per-board term (Round 66)', () {
      final pr = ElectricalProject(
          id: 'p',
          name: 'p',
          sources: const ElectricalSources(generator: GeneratorSource()),
          panels: [
            _main('M', [_heater('M-a', 20000)]),
            _shop('S', [3000, 3000, 3000]),
          ]);
      final sys = computeSystem(_profile, pr);
      expect(gensetPhaseDemandVa(pr, sys),
          closeTo(studySupplyInputs(pr, sys).perPhaseBasisVa, 1));
    });
  });

  group('(4) the printed service is the 3ph service', () {
    final pr = ElectricalProject(
        id: 'p',
        name: 'p',
        sources: const ElectricalSources(generator: GeneratorSource()),
        panels: [
          _main('M', [_heater('M-a', 3000)]),
          _shop('S', [3000, 3000, 3000]),
          _shop('T', [3000, 3000, 3000]),
          _shop('U', [3000, 3000, 3000]),
        ]);

    test('serviceSystemOf + report + one-line bus', () {
      final sys = computeSystem(_profile, pr);
      expect(sys.supply.system, ElectricalSystem.singlePhase);
      final svc = serviceSystemOf(pr, sys);
      expect(svc.system, ElectricalSystem.threePhase);
      expect(svc.voltage.volts, 400);
      final st = computeAdvancedStudy(_profile, pr, sys);
      final md = buildElectricalCalcReport(ElectricalCalcReportData(
          projectName: 'p',
          date: 'd',
          standardsName: 'PUIL',
          standardsRevision: '2011',
          project: pr,
          result: sys,
          powerOneLine: st.powerOneLine));
      expect(md, contains('**3-phase, 400 V**'));
      expect(md, contains('- System: 3-phase, 400 V'));
      expect(st.powerOneLine!.nodes.any((n) => n.sub?.contains('400 V') ?? false),
          isTrue);
      expect(st.powerOneLine!.nodes.any((n) => n.sub?.startsWith('230 V') ?? false),
          isFalse);
    });

    test('all-1ph and all-3ph services keep sys.supply', () {
      final one = ElectricalProject(id: 'p', name: 'p', panels: [
        _shop('S', [3000, 3000])
      ]);
      final s1 = computeSystem(_profile, one);
      expect(serviceSystemOf(one, s1).system, ElectricalSystem.singlePhase);
      expect(serviceSystemOf(one, s1).voltage.volts, 230);
      final three = ElectricalProject(id: 'p', name: 'p', panels: [
        _main('M', [_heater('a', 3000)])
      ]);
      final s3 = computeSystem(_profile, three);
      expect(serviceSystemOf(three, s3).system, ElectricalSystem.threePhase);
      expect(serviceSystemOf(three, s3).voltage, s3.supply.voltage);
    });
  });
}
