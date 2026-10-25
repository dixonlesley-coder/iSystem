// Round 61 (2026-10-18) — one section count, the study transformer on the
// incomer's basis, and the most loaded SECTION when boards outnumber
// sections.
//
//   regression-dual-with-one-section-study-mv-nothing-printed-fault-doubled /
//   elec-convergence-13-dual-plus-one-section-two-services — a dual flag with
//     an explicit single section (`transformerUnits: 1`) is ONE section: the
//     study, the fault estimate, the printed transformer and the BOM read it
//     exactly like a non-dual single service (it used to study 2 units and
//     fault them as a paralleled pair: 2 x the one-unit fault).
//   regression-undeclared-study-transformer-flagged-against-headroom-incomer
//     — an undeclared study transformer is sized on the root's FUTURE
//     (headroom-uplifted) basis, the basis its incomer is sized on, so the
//     Round-41 FLC judge never condemns the engine's own pick.
//   elec-convergence-13-roots-outnumber-sections-section-overload — with
//     more service-entrance boards than sections at least one section
//     carries two boards (pigeonhole): the section load is the optimum of the
//     multiway partition, never the single largest board; a declared service
//     with paralleled units per section is judged per section too.
//
// First principles: a transformer unit carries at most 80 % of nameplate,
// so a section of S kVA needs a unit >= S / 0.8 on the IEC ladder; its LV
// fault is Isc = kVA x 1000 / (sqrt3 x 400 x 0.04).
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_bom.dart';
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/headroom.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/supply_design.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

double _iscA(double kva) => kva * 1000 / (math.sqrt(3) * 400 * 0.04);

ElectricalPanel _root(String id, List<double> loadsW,
        {HeadroomSpec? headroom}) =>
    ElectricalPanel(
      id: id,
      name: id,
      voltage: const Voltage(400),
      headroom: headroom,
      circuits: [
        for (var k = 0; k < loadsW.length; k++)
          ElectricalCircuit(
              id: '$id-$k',
              name: 'Load $id-$k',
              loadKind: LoadKind.general,
              loadW: loadsW[k],
              phases: 3,
              length: const Length(30)),
      ],
    );

ElectricalProject _service(List<ElectricalPanel> roots,
        {bool dual = false, int? units, ApparentPower? capacity}) =>
    ElectricalProject(
      id: 'p',
      name: 'Sections',
      earthingSystem: EarthingSystem.tnS,
      dualTransformer: dual,
      transformerUnits: units,
      supplyCapacityVa: capacity,
      panels: roots,
    );

({SupplyDesign supply, Current? fault, ElectricalSystemResult sys}) _study(
    ElectricalProject pr) {
  final sys0 = computeSystem(_profile, pr);
  final supply = studySupplyDesign(pr, sys0);
  final fault = estimatedServiceFaultLevelA(pr,
      demand: sys0.supply.demandVa, supply: supply);
  final sys = computeSystem(_profile, pr, originFaultLevel: fault);
  return (supply: supply, fault: fault, sys: sys);
}

/// Brute force: every assignment of [xs] to [n] sections.
double _bruteMaxSection(List<double> xs, int n) {
  var best = double.infinity;
  final bins = List<double>.filled(n, 0);
  void go(int i) {
    if (i == xs.length) {
      best = math.min(best, bins.reduce(math.max));
      return;
    }
    for (var k = 0; k < n; k++) {
      bins[k] += xs[i];
      go(i + 1);
      bins[k] -= xs[i];
    }
  }

  go(0);
  return best;
}

void main() {
  group('dual flag + one typed section is one section', () {
    for (final loads in [
      // One root: dual + 1 must equal the non-dual reading whatever it is.
      [for (var k = 0; k < 9; k++) 20000.0],
      [for (var k = 0; k < 6; k++) 15000.0],
    ]) {
      test('${loads.length} x ${loads.first / 1000} kW: dual + units 1 == '
          'non-dual', () {
        final single = _service([_root('MDP', loads)]);
        final dualOne = _service([_root('MDP', loads)], dual: true, units: 1);
        final a = _study(single);
        final b = _study(dualOne);
        expect(b.supply.isMv, a.supply.isMv);
        expect(b.supply.transformerKva, a.supply.transformerKva);
        expect(b.supply.units, a.supply.units);
        expect(b.fault?.amperes, a.fault?.amperes,
            reason: 'one unit, never a paralleled pair');
        expect(serviceTransformer(dualOne, b.sys),
            serviceTransformer(single, a.sys));
        expect(isDeclaredMvService(dualOne), isDeclaredMvService(single));
        expect(serviceSections(dualOne), 1);
        // The bought transformer agrees with the study reading.
        int txLines(ElectricalProject pr, ElectricalSystemResult sys) =>
            advancedBomLines(project: pr, sys: sys)
                .where((l) =>
                    (l.priceKey ?? '').contains('transformer:'))
                .length;
        expect(txLines(dualOne, b.sys), txLines(single, a.sys));
      });
    }

    test('two 200 kW roots: dual + units 1 faults ONE unit (was 2 x)', () {
      final roots = [
        _root('A', [100000, 100000]),
        _root('B', [100000, 100000]),
      ];
      final a = _study(_service(roots));
      final b = _study(_service(roots, dual: true, units: 1));
      expect(b.supply.transformerKva, a.supply.transformerKva);
      expect(b.supply.units, a.supply.units);
      expect(b.fault!.amperes,
          closeTo(_iscA(a.supply.transformerKva!) * a.supply.units, 0.5));
      expect(b.fault!.amperes, a.fault!.amperes);
    });

    test('determineSupply: sections 1 on a dual flag takes the single path',
        () {
      final d = determineSupply(const ApparentPower(150000),
          dualTransformer: true, sections: 1);
      expect(d.isMv, isFalse, reason: '150 kVA is within the LV ceiling');
      final d2 = determineSupply(const ApparentPower(150000),
          dualTransformer: true);
      expect(d2.isMv, isTrue, reason: 'a real dual service is MV');
      expect(d2.units, 2);
    });
  });

  group('undeclared study transformer on the future (headroom) basis', () {
    List<ElectricalPanel> roots(double spare) => [
          _root('MDP', [for (var k = 0; k < 9; k++) 45000.0],
              headroom: spare > 0
                  ? HeadroomSpec(sparePercentage: spare)
                  : null),
        ];

    for (final spare in [0.0, 25.0, 35.0, 50.0, 80.0]) {
      test('$spare % spare: no root-incomer-exceeds-transformer-flc', () {
        final pr = _service(roots(spare));
        final s = _study(pr);
        expect(s.supply.isMv, isTrue);
        final adv = computeAdvancedStudy(_profile, pr, s.sys);
        expect(
            adv.warnings.where(
                (w) => w.code == 'root-incomer-exceeds-transformer-flc'),
            isEmpty);
        // The unit covers the FUTURE demand at 80 % loading.
        final r = s.sys.panels['MDP']!;
        final future = r.demandVaOrEstimate() * (1 + spare / 100);
        expect(s.supply.transformerKva! * 1000 * 0.8,
            greaterThanOrEqualTo(future - 1e-6));
      });
    }

    test('0 % spare is byte-identical to no headroom spec', () {
      final a = _study(_service(roots(0)));
      final b = _study(_service(
          [_root('MDP', [for (var k = 0; k < 9; k++) 45000.0],
              headroom: const HeadroomSpec())]));
      expect(b.supply.transformerKva, a.supply.transformerKva);
      expect(b.supply.note, a.supply.note);
    });

    test('headroom never turns an LV service into MV', () {
      final pr = _service([
        _root('MDP', [for (var k = 0; k < 4; k++) 30000.0],
            headroom: const HeadroomSpec(sparePercentage: 100)),
      ]);
      final s = _study(pr);
      final plain = _study(_service([
        _root('MDP', [for (var k = 0; k < 4; k++) 30000.0]),
      ]));
      expect(s.supply.isMv, plain.supply.isMv);
    });
  });

  group('roots outnumber sections: the most loaded section', () {
    test('minimalMaxSectionLoad == brute force (seeded property)', () {
      final rnd = math.Random(61);
      for (var trial = 0; trial < 400; trial++) {
        final n = 2 + rnd.nextInt(3);
        final m = 1 + rnd.nextInt(8);
        final xs = [for (var i = 0; i < m; i++) 10 + rnd.nextDouble() * 500];
        expect(minimalMaxSectionLoad(xs, n),
            closeTo(_bruteMaxSection(xs, n), 1e-6),
            reason: 'trial $trial: $xs over $n');
      }
    });

    test('above the exact cap the greedy is an upper bound', () {
      final xs = [for (var i = 0; i < 20; i++) 100.0 + i];
      final total = xs.fold(0.0, (a, b) => a + b);
      final got = minimalMaxSectionLoad(xs, 3);
      expect(got, greaterThanOrEqualTo(total / 3 - 1e-9));
      expect(got, lessThanOrEqualTo(total / 3 + xs.reduce(math.max)));
    });

    test('3 equal roots on an undeclared dual: one section carries two', () {
      final roots = [
        for (final id in ['A', 'B', 'C'])
          _root(id, [for (var k = 0; k < 9; k++) 30000.0]),
      ];
      final pr = _service(roots, dual: true);
      final s = _study(pr);
      final rootVa = s.sys.panels['A']!.demandVaOrEstimate();
      // Two boards on one section: each unit >= 2 x root / 0.8.
      expect(s.supply.units, 2);
      expect(s.supply.transformerKva! * 1000 * 0.8,
          greaterThanOrEqualTo(2 * rootVa - 1e-6));
    });

    test('4 roots on transformerUnits 3: a section carries two', () {
      final roots = [
        for (final id in ['A', 'B', 'C', 'D'])
          _root(id, [for (var k = 0; k < 9; k++) 30000.0]),
      ];
      final s = _study(_service(roots, units: 3));
      final rootVa = s.sys.panels['A']!.demandVaOrEstimate();
      expect(s.supply.transformerKva! * 1000 * 0.8,
          greaterThanOrEqualTo(2 * rootVa - 1e-6));
    });

    test('declared 2 x 630 kVA with 3 roots of ~318 kVA is below demand', () {
      final roots = [
        for (final id in ['A', 'B', 'C'])
          _root(id, [for (var k = 0; k < 9; k++) 30000.0]),
      ];
      final pr = ElectricalProject(
        id: 'p',
        name: 'Declared',
        earthingSystem: EarthingSystem.tnS,
        dualTransformer: true,
        transformerKva: const ApparentPower(630000),
        panels: roots,
      );
      final s = _study(pr);
      final rootVa = s.sys.panels['A']!.demandVaOrEstimate();
      // 2 x rootVa on one 630 kVA unit vs its 504 kVA design rating.
      expect(2 * rootVa, greaterThan(630000 * 0.8));
      expect(s.supply.declared, isTrue);
      expect(s.supply.declaredBelowDemand, isTrue);
      final adv = computeAdvancedStudy(_profile, pr, s.sys);
      expect(
          adv.warnings.map((w) => w.code),
          contains('section-transformer-overloaded'));
    });

    test('declared paralleled units per section are judged per section', () {
      // A declared 6 MVA dual connection: 2 sections x 2 x 1600 kVA.
      final d = determineSupply(const ApparentPower(5000000),
          dualTransformer: true,
          declaredKva: const ApparentPower(1600000),
          declaredUnits: 4,
          largestSectionDemand: const ApparentPower(4000000));
      // Section A: 4000 kVA on 2 x 1600 kVA ⇒ 2000 kVA / unit > 1280 kVA.
      expect(d.declaredBelowDemand, isTrue);
      final ok = determineSupply(const ApparentPower(4000000),
          dualTransformer: true,
          declaredKva: const ApparentPower(1600000),
          declaredUnits: 4,
          largestSectionDemand: const ApparentPower(2500000));
      // 2500 / 2 = 1250 kVA per unit <= 1280 ⇒ fine.
      expect(ok.declaredBelowDemand, isFalse);
    });
  });
}
