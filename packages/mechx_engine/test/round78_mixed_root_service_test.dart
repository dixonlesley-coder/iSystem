// Round 78 (2026-10-18) — the service and the alternator are decided on the
// BOARDS they feed, never on the governing root's system alone.
//
// `sys.supply.system` is the GOVERNING root's system (largest incomer), so a
// 3-phase root board can sit beside a larger 1-phase root (and vice versa).
//
// (1) regression-daya-3ph-supply-1ph-root-on-board-basis — 3ph root M with
//     6 x 10 kW heaters (60 000 / 692.82 = 86.6 A, a 100 A incomer, governs)
//     beside 1ph root S with 3 x 3000 W sockets at cos 0.9
//     (10 000 VA / 230 = 43.5 A). S's whole current sits on ONE line of the
//     3ph service: that line carries 86.6 + 43.5 = 130.1 A, so the daya must
//     reach 130.1 x 692.82 = 90 136 VA => the 105 kVA step. The old
//     board-basis sum counted S at 230 x 43.5 (70 003 VA => 82.5 kVA =
//     119.1 A per phase, a limiter that trips on S's line).
//
// (2) regression-daya-single-phase-step-for-a-3ph-root — 3ph root M with one
//     3 kW heater (4.3 A) beside 1ph root S with 2 x 3000 W sockets
//     (6 667 VA / 230 = 29.0 A, governs). A 3ph board cannot hang off a 1ph
//     PLN service: the daya is a 3ph step on the per-line basis
//     sqrt3 x 400 x 29.0 + sqrt3 x 400 x 4.3 = 20 092 + 2 979 = 23 071 VA,
//     just over the 23 kVA step => 33 kVA 3ph (never 11 kVA 1ph).
//
// (3) regression-genset-1ph-governed-supply-with-3ph-root-undersized — 3ph
//     root M with a 20 kW heater (28.9 A) beside 1ph root S at 43.5 A
//     (governs), full-backup genset. The alternator must be 3ph to feed M,
//     and S's line carries 28.9 + 43.5 = 72.4 A => sqrt3 x 400 x 72.4 =
//     50 162 VA. The 1ph board-basis sum gave 30 023 VA.
library;

// Backlog E-1 (2026-11-13): every board here is its own SERVICE ENTRANCE
// (own meter / section main), so each is flagged `serviceEntrance: true` —
// an unflagged un-fed board after the first is `unfed-panel` and outside
// the supply study.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/sizing.dart' show roundTo;
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/electrical/supply_design.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();
final _s3 = math.sqrt(3) * 400;

ElectricalPanel _main(String id, List<double> heatersW) => ElectricalPanel(serviceEntrance: true, 
      id: id,
      name: 'Main $id',
      circuits: [
        for (var i = 0; i < heatersW.length; i++)
          ElectricalCircuit(
              id: '$id-h$i',
              name: 'Heater $i',
              loadKind: LoadKind.heating,
              loadW: heatersW[i],
              cosPhi: 1,
              phases: 3,
              length: const Length(10)),
      ],
    );

ElectricalPanel _shop(String id, List<double> ways) => ElectricalPanel(serviceEntrance: true, 
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

double _a(ElectricalSystemResult sys, String id) => math.max(
    roundTo(sys.panels[id]!.diversifiedDemandCurrent.amperes, 1),
    sys.panels[id]!.largestDownstreamRunA);

void main() {
  test('(1) 3ph-governed service: the 1ph root rides one line (105 kVA)', () {
    final pr = ElectricalProject(id: 'p', name: 'p', panels: [
      _main('M', [for (var i = 0; i < 6; i++) 10000]),
      _shop('S', [3000, 3000, 3000]),
    ]);
    final sys = computeSystem(_profile, pr);
    expect(sys.supply.system, ElectricalSystem.threePhase);
    expect(_a(sys, 'M'), closeTo(86.6, 0.05));
    expect(_a(sys, 'S'), closeTo(43.5, 0.05));
    final lineA = _a(sys, 'M') + _a(sys, 'S'); // 130.1 A on S's line
    final st = computeAdvancedStudy(_profile, pr, sys);
    expect(st.recommendedDayaThreePhase, isTrue);
    final daya = st.recommendedDayaVa!;
    expect(daya / _s3, greaterThanOrEqualTo(lineA - 1e-6));
    expect(daya, 105000);
    // The daya basis == the study's per-line basis == the genset basis.
    final studied = studySupplyInputs(pr, sys);
    expect(studied.perPhaseBasisVa, closeTo(lineA * _s3, 1));
    final withGen = ElectricalProject(
        id: 'p',
        name: 'p',
        panels: pr.panels,
        sources: const ElectricalSources(generator: GeneratorSource()));
    final sysG = computeSystem(_profile, withGen);
    expect(gensetPhaseDemandVa(withGen, sysG),
        closeTo(studied.perPhaseBasisVa, 1));
  });

  test('(2) a 3ph root never gets a 1ph PLN daya (33 kVA 3ph)', () {
    final pr = ElectricalProject(id: 'p', name: 'p', panels: [
      _main('M', [3000]),
      _shop('S', [3000, 3000]),
    ]);
    final sys = computeSystem(_profile, pr);
    expect(sys.supply.system, ElectricalSystem.singlePhase);
    final basis = (_a(sys, 'M') + _a(sys, 'S')) * _s3;
    expect(basis, closeTo(23071, 5));
    final st = computeAdvancedStudy(_profile, pr, sys);
    expect(st.recommendedDayaThreePhase, isTrue);
    expect(st.recommendedDayaVa, 33000);
    expect(st.recommendedDayaVa!, greaterThanOrEqualTo(basis));
  });

  test('(3) 1ph-governed genset with a 3ph root: per-line 50.2 kVA', () {
    ElectricalProject build(double mainW) => ElectricalProject(
        id: 'p',
        name: 'p',
        sources: const ElectricalSources(generator: GeneratorSource()),
        panels: [
          _main('M', [mainW]),
          _shop('S', [3000, 3000, 3000]),
        ]);
    final pr = build(20000);
    final sys = computeSystem(_profile, pr);
    expect(sys.supply.system, ElectricalSystem.singlePhase);
    final lineA = _a(sys, 'M') + _a(sys, 'S'); // 28.9 + 43.5
    expect(lineA, closeTo(72.4, 0.1));
    expect(gensetBackupDemandVa(pr, sys).voltAmperes,
        greaterThanOrEqualTo(lineA * _s3 - 1));
    expect(gensetBackupDemandVa(pr, sys).voltAmperes, closeTo(50162, 5));
  });

  test('all-1ph roots keep the 1ph ladder (byte-identical)', () {
    final pr = ElectricalProject(id: 'p', name: 'p', panels: [
      _shop('S', [3000, 3000]),
    ]);
    final sys = computeSystem(_profile, pr);
    final st = computeAdvancedStudy(_profile, pr, sys);
    expect(st.recommendedDayaThreePhase, isFalse);
    // 6 667 VA => the 7 700 VA 1ph step.
    expect(st.recommendedDayaVa, recommendedDaya(
            ApparentPower(math.max(sys.supply.demandVa.voltAmperes,
                _a(sys, 'S') * 230)),
            ElectricalSystem.singlePhase)!
        .va);
  });

  test('seeded: mixed roots — 3ph daya covers every line, genset agrees', () {
    final rnd = math.Random(78);
    var nonVacuous = 0;
    for (var trial = 0; trial < 120; trial++) {
      final mains = rnd.nextInt(2) + 1;
      final shops = rnd.nextInt(3);
      final panels = <ElectricalPanel>[
        for (var m = 0; m < mains; m++)
          _main('M$m', [
            for (var i = 0; i < rnd.nextInt(4) + 1; i++)
              (rnd.nextInt(12) + 1) * 1000.0
          ]),
        for (var s = 0; s < shops; s++)
          _shop('S$s', [
            for (var i = 0; i < rnd.nextInt(3) + 1; i++)
              (rnd.nextInt(6) + 1) * 500.0
          ]),
      ];
      final pr = ElectricalProject(
          id: 'p',
          name: 'p',
          panels: panels,
          sources: const ElectricalSources(generator: GeneratorSource()));
      final sys = computeSystem(_profile, pr);
      final st = computeAdvancedStudy(_profile, pr, sys);
      final studied = studySupplyInputs(pr, sys);
      final daya = st.recommendedDayaVa;
      // Every 3ph root makes it a 3ph service.
      if (daya != null) expect(st.recommendedDayaThreePhase, isTrue);
      if (daya == null) continue;
      // The daya covers the study's own per-line basis.
      expect(daya, greaterThanOrEqualTo(studied.perPhaseBasisVa - 1e-6));
      // The heaviest line: every 3ph root's worst phase + the largest 1ph
      // root (whatever line it lands on).
      final base = [for (var m = 0; m < mains; m++) _a(sys, 'M$m')]
          .fold(0.0, (a, b) => a + b);
      final big1 = [for (var s = 0; s < shops; s++) _a(sys, 'S$s')]
          .fold(0.0, math.max);
      expect(daya / _s3, greaterThanOrEqualTo(base + big1 - 1e-6));
      // The genset is a 3ph alternator carrying that line too.
      expect(gensetPhaseDemandVa(pr, sys),
          greaterThanOrEqualTo((base + big1) * _s3 - 1));
      if (shops > 0 && sys.supply.system == ElectricalSystem.singlePhase) {
        nonVacuous++;
      }
    }
    expect(nonVacuous, greaterThan(5));
  });
}
