// Round 37 (2026-10-18) — electrical-sim-4-dual-tx-single-root-floor-vs-
// fault-basis.
//
// A single service-entrance board on a DUAL-transformer service sits on ONE
// section (bus coupler normally open) — the basis the fault estimate already
// uses — so its incomer is floored at ONE section's share of the declared
// daya, never the whole connection.
//
// Derivation (1 MVA declared, dual):
//   per section 1 000 000 / 2 = 500 kVA ⇒ 500 000 / (√3·400) = 721.7 A
//   ⇒ the first rung ≥ 721.7 A is 800 A (the total 1 MVA gave 1443.4 A ⇒
//   1600 A, specified with devices from the one-section 18 kA fault);
//   one-section fault 500 000 / (√3·400·0.04) = 18 042 A.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

ElectricalProject _hotel({required bool dual}) => ElectricalProject(
      supplyCapacityVa: const ApparentPower(1000000),
      dualTransformer: dual,
      panels: [
        ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
          for (var i = 0; i < 10; i++)
            ElectricalCircuit(
              id: 'h$i',
              name: 'h$i',
              loadKind: LoadKind.heating,
              loadW: 30000,
              cosPhi: 1,
              phases: 3,
              length: const Length(20),
            ),
        ]),
      ],
    );

void main() {
  test('the derivation', () {
    expect(500000 / (math.sqrt(3) * 400), closeTo(721.7, 0.05));
    expect(500000 / (math.sqrt(3) * 400 * 0.04), closeTo(18042, 1));
  });

  test('1 MVA dual, one root: 800 A incomer on the one-section 18 kA basis',
      () {
    final p = _hotel(dual: true);
    expect(serviceEntranceCapacityVa(p), 500000);
    final mdp = computeSystem(_p, p).panels['mdp']!;
    expect(mdp.incomer.breaker.ratingA.amperes, 800);
    expect(estimatedServiceFaultLevelA(p)!.amperes, closeTo(18042, 1));
  });

  test('a single-transformer 1 MVA service keeps the whole daya (1600 A)', () {
    final p = _hotel(dual: false);
    expect(serviceEntranceCapacityVa(p), 1000000);
    expect(computeSystem(_p, p).panels['mdp']!.incomer.breaker.ratingA.amperes,
        1600);
  });

  test('the Design Basis says so (EN)', () {
    final p = _hotel(dual: true);
    final md = buildElectricalCalcReport(ElectricalCalcReportData(
      projectName: 'Hotel',
      date: '2026-10-18',
      standardsName: 'PUIL 2011',
      standardsRevision: '2011',
      project: p,
      result: computeSystem(_p, p),
    ));
    expect(md, contains('Service-entrance rating:'));
    expect(md, contains('500 kVA per section'));
    expect(md, contains('1000 kVA declared in total'));
  });

  // Round 37 r2 — the judge and the supply study read the SAME one-section
  // basis. 1 MVA dual, one MDP carrying 2 x 300 kW 3φ heaters (cos φ 1):
  //   600 000 / (√3·400) = 866.0 A > one section's 721.7 A ⇒ the judge fires,
  //   worded on the section (never 'declared 500 kVA');
  //   the supply study: 500 kVA x 0.8 = 400 kVA < the 600 kVA the ONE section
  //   carries ⇒ flagged too (never 'for the 600 kVA demand' with no overload).
  ElectricalProject heavy({required bool dual}) => ElectricalProject(
        supplyCapacityVa: const ApparentPower(1000000),
        dualTransformer: dual,
        panels: [
          ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
            for (var i = 0; i < 2; i++)
              ElectricalCircuit(
                id: 'h$i',
                name: 'h$i',
                loadKind: LoadKind.heating,
                loadW: 300000,
                cosPhi: 1,
                phases: 3,
                length: const Length(20),
              ),
          ]),
        ],
      );

  test('the r2 derivation', () {
    expect(600000 / (math.sqrt(3) * 400), closeTo(866.0, 0.05));
    expect(500 * 0.8, lessThan(600));
  });

  test('1 MVA dual, 600 kVA single root: the warning names the one section '
      'and the supply note agrees', () {
    final p = heavy(dual: true);
    final sys = computeSystem(_p, p);
    final w = sys.panels['mdp']!.warnings
        .where((w) => w.code == 'service-capacity-below-demand')
        .toList();
    expect(w, hasLength(1));
    expect(w.single.message,
        contains('one 500 kVA section of the declared 1000 kVA connection'));
    expect(w.single.message, contains('~721.7 A'));
    expect(w.single.message, isNot(contains('declared connection capacity')));

    final study = computeAdvancedStudy(_p, p, sys);
    expect(study.supply.declaredBelowDemand, isTrue);
    expect(study.supply.note, contains('One section feeds the single'));
    expect(study.supply.note,
        contains('below the 600 kVA the one section feeding the single'));

    // And the report prints both, consistently.
    final md = buildElectricalCalcReport(ElectricalCalcReportData(
      projectName: 'Hotel',
      date: '2026-10-18',
      standardsName: 'PUIL 2011',
      standardsRevision: '2011',
      project: p,
      result: sys,
    ));
    expect(md, contains('one 500 kVA section of the declared 1000 kVA'));
  });

  test('a single-transformer 1 MVA service: no warning, no flag', () {
    final p = heavy(dual: false);
    final sys = computeSystem(_p, p);
    expect(
        sys.panels['mdp']!.warnings
            .any((w) => w.code == 'service-capacity-below-demand'),
        isFalse);
    final study = computeAdvancedStudy(_p, p, sys);
    expect(study.supply.note, isNot(contains('One section feeds')));
  });

  test('two roots on a dual service: each section carries half (unchanged)',
      () {
    final base = heavy(dual: true);
    final p = ElectricalProject(
      supplyCapacityVa: base.supplyCapacityVa,
      dualTransformer: true,
      panels: [
        ElectricalPanel(
            id: 'a', name: 'A', circuits: [base.panels.first.circuits[0]]),
        const ElectricalPanel(id: 'b', name: 'B', circuits: [
          ElectricalCircuit(
            id: 'x',
            name: 'x',
            loadKind: LoadKind.heating,
            loadW: 300000,
            cosPhi: 1,
            phases: 3,
            length: Length(20),
          ),
        ]),
      ],
    );
    final sys = computeSystem(_p, p);
    final study = computeAdvancedStudy(_p, p, sys);
    // 600 / 2 = 300 kVA per section <= 400 ⇒ not flagged.
    expect(study.supply.declaredBelowDemand, isFalse);
    expect(study.supply.note, isNot(contains('One section feeds')));
  });
}
