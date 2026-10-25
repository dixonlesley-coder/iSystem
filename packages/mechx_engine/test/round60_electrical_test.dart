// Round 60 (2026-10-18) — the sectioned service is ONE service everywhere.
//
//   regression-transformer-units-undeclared-lv-vs-dual-mv — `transformerUnits
//     >= 2` is a sectioned (MV) service exactly like `dualTransformer`: the
//     study never takes the direct-LV exit, the fault estimate, the ADS
//     verdicts, the spine / schedule / BOM follow; an LV PLN daya is ONE
//     connection (never split by the section count).
//   elec-convergence-12-printed-transformer-not-the-study-transformer — the
//     transformer printed on the BOM, the TX-01 row, the power one-line and
//     the spine IS the study's pick (seeded property over dual / N-section
//     services with unequal roots).
//   elec-convergence-12-undeclared-sectioned-single-root-transformer-
//     undersized — one service-entrance board on an undeclared sectioned
//     service sits on ONE unit, which carries the whole demand.
//
// First principles: a transformer unit carries at most 80 % of nameplate
// (transformerLoadingFactor), so a section of S kVA needs a unit >= S / 0.8
// on the IEC ladder; its LV fault is Isc = kVA x 1000 / (sqrt3 x 400 x 0.04)
// (4 % impedance). Two 3φ 50 kW roots at cos phi ~0.9: each section carries
// its own root (the larger one), never half the total.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_bom.dart';
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/supply_design.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

double _iscA(double kva) => kva * 1000 / (math.sqrt(3) * 400 * 0.04);

ElectricalPanel _root(String id, List<double> loadsW, {double length = 30}) =>
    ElectricalPanel(
      id: id,
      name: id,
      voltage: const Voltage(400),
      circuits: [
        for (var k = 0; k < loadsW.length; k++)
          ElectricalCircuit(
              id: '$id-$k',
              name: 'Load $id-$k',
              loadKind: LoadKind.general,
              loadW: loadsW[k],
              phases: 3,
              length: Length(length)),
      ],
    );

ElectricalProject _service(List<ElectricalPanel> roots,
        {bool dual = false, int? units, ApparentPower? capacity}) =>
    ElectricalProject(
      id: 'p',
      name: 'Sectioned',
      earthingSystem: EarthingSystem.tnS,
      dualTransformer: dual,
      transformerUnits: units,
      supplyCapacityVa: capacity,
      panels: roots,
    );

List<String> _labels(SldSheet s) =>
    [for (final p in s.prims) if (p is SldLabel) p.text];

({SupplyDesign supply, Current? fault, ElectricalSystemResult sys}) _study(
    ElectricalProject pr) {
  final sys0 = computeSystem(_profile, pr);
  final supply = studySupplyDesign(pr, sys0);
  final fault = estimatedServiceFaultLevelA(pr,
      demand: sys0.supply.demandVa, supply: supply);
  final sys = computeSystem(_profile, pr, originFaultLevel: fault);
  return (supply: supply, fault: fault, sys: sys);
}

void main() {
  group('regression-transformer-units-undeclared-lv-vs-dual-mv', () {
    // Two 3φ 50 kW roots plus a long 80 m way: 118 kVA total, LV-sized.
    final roots = [
      _root('LVMDP-1', [50000]),
      _root('LVMDP-2', [50000], length: 80),
    ];

    test('transformerUnits = 2 is studied exactly like dualTransformer', () {
      final dual = _study(_service(roots, dual: true));
      final two = _study(_service(roots, units: 2));
      expect(dual.supply.isMv, isTrue);
      expect(two.supply.isMv, isTrue,
          reason: 'a sectioned service never takes the direct-LV exit');
      expect(two.supply.transformerKva, dual.supply.transformerKva);
      expect(two.supply.units, dual.supply.units);
      // Each unit >= the larger root / 0.8; the fault is ONE unit's.
      final largest = <double>[
        for (final r in dual.sys.panels.values) r.demandVaOrEstimate()
      ].reduce(math.max);
      expect(dual.supply.transformerKva! * 1000,
          greaterThanOrEqualTo(largest / 0.8 - 1e-6));
      expect(two.fault!.amperes,
          closeTo(_iscA(dual.supply.transformerKva!), 0.1));
      expect(two.fault!.amperes, dual.fault!.amperes);
      // Every ADS verdict follows the same source impedance.
      final fd = faultStudy(dual.sys, _service(roots, dual: true), _profile,
          originFaultLevel: dual.fault!);
      final ft = faultStudy(two.sys, _service(roots, units: 2), _profile,
          originFaultLevel: two.fault!);
      for (final id in fd.circuits.keys) {
        expect(ft.circuits[id]!.adsOk, fd.circuits[id]!.adsOk, reason: id);
        expect(ft.circuits[id]!.zsOhm, fd.circuits[id]!.zsOhm, reason: id);
      }
      expect(isDeclaredMvService(_service(roots, units: 2)), isTrue);
    });

    test('an N-section service prints and buys its study transformers', () {
      final pr = _service([
        for (final b in ['A', 'B', 'C'])
          _root('MDP-$b', [for (var k = 0; k < 6; k++) 40000]),
      ], units: 3);
      final s = _study(pr);
      expect(s.supply.isMv, isTrue);
      final kva = s.supply.transformerKva!;
      expect(s.supply.units, 3);
      final tx = serviceTransformer(pr, s.sys)!;
      expect(tx.kva, kva);
      expect(tx.units, 3);
      final spine = _labels(buildElectricalSourceSpine(project: pr, result: s.sys));
      expect(spine.join('\n'), contains('TRANSFORMER 3 x ${kva.toInt()} kVA'));
      final rows = buildEquipmentScheduleRows(EquipmentScheduleData(
          projectName: 'P',
          date: '2026-10-18',
          electrical: s.sys,
          electricalProject: pr));
      final row = rows.firstWhere((r) => r.tag == 'TX-01');
      expect(row.duty, '${kva.toInt()} kVA');
      expect(row.qty, 3);
      final bom = advancedBomLines(project: pr, sys: s.sys)
          .where((l) => (l.priceKey ?? '').contains('transformer'))
          .single;
      expect(bom.qty, 3);
      expect(bom.description, 'Transformer ${kva.toInt()} kVA');
    });

    test('an LV PLN daya is ONE connection, never split by the sections', () {
      final pr = _service([_root('MDP', [30000, 30000, 30000])],
          units: 3, capacity: const ApparentPower(105000));
      expect(serviceEntranceCapacityVa(pr), 105000);
      // A declared MV connection (above the LV ceiling) still splits.
      final mv = _service([_root('MDP', [30000])],
          units: 3, capacity: const ApparentPower(3750e3));
      expect(serviceEntranceCapacityVa(mv), 1250e3);
    });
  });

  group('elec-convergence-12-undeclared-sectioned-single-root', () {
    test('one root on transformerUnits = 3 / dual: the unit carries the whole '
        'demand and its fault is that unit\'s', () {
      for (final pr in [
        _service([_root('LVMDP', [for (var k = 0; k < 6; k++) 80000])],
            units: 3),
        _service([_root('LVMDP', [for (var k = 0; k < 6; k++) 80000])],
            dual: true),
      ]) {
        final s = _study(pr);
        final sys = s.sys;
        final basis = math.max(
            sys.supply.demandVa.voltAmperes,
            studySupplyInputs(pr, sys).perPhaseBasisVa);
        final kva = s.supply.transformerKva!;
        // 6 x 80 kW 3φ ~ 560 kVA => a unit >= 560 / 0.8 = 700 => 800 kVA
        // (never 3 x 250 kVA sized on demand / 3).
        expect(kva * 1000, greaterThanOrEqualTo(basis / 0.8 - 1e-6));
        expect(kva, 800);
        expect(s.fault!.amperes, closeTo(_iscA(kva), 0.1));
        // The incomer sits under the one unit's FLC rung: no judge fires.
        final adv = computeAdvancedStudy(_profile, pr, sys);
        expect(
            adv.warnings
                .where((w) => w.code == 'root-incomer-exceeds-transformer-flc'),
            isEmpty);
      }
    });
  });

  group('elec-convergence-12-printed-transformer-not-the-study-transformer',
      () {
    test('seeded property: printed kVA x units == the study kVA x units', () {
      final rnd = math.Random(6012);
      var mvTrials = 0;
      for (var t = 0; t < 120; t++) {
        final nRoots = 1 + rnd.nextInt(3);
        final roots = [
          for (var r = 0; r < nRoots; r++)
            _root('R$r', [
              for (var k = 0; k < 1 + rnd.nextInt(5); k++)
                5000.0 + rnd.nextInt(60) * 5000.0,
            ]),
        ];
        final mode = rnd.nextInt(3);
        final pr = _service(roots,
            dual: mode == 0, units: mode == 0 ? null : 2 + rnd.nextInt(2));
        final sys = computeSystem(_profile, pr);
        final study = studySupplyDesign(pr, sys);
        final printed = serviceTransformer(pr, sys);
        expect(study.isMv, isTrue, reason: 'trial $t');
        mvTrials++;
        expect(printed, isNotNull, reason: 'trial $t');
        expect(printed!.kva, study.transformerKva, reason: 'trial $t');
        expect(printed.units, study.units, reason: 'trial $t');
        expect(powerOneLineUtilitySub(pr, sys),
            'MV via TX ${printed.units > 1 ? '${printed.units} x ' : ''}'
            '${printed.kva.toStringAsFixed(0)} kVA',
            reason: 'trial $t');
        final bom = advancedBomLines(project: pr, sys: sys)
            .where((l) => (l.priceKey ?? '').contains('transformer'))
            .single;
        expect(bom.qty, study.units.toDouble(), reason: 'trial $t');
      }
      expect(mvTrials, 120);
    });
  });
}
