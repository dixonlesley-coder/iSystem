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
}
