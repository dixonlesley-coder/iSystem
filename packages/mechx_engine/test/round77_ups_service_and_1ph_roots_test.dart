// Round 77 (2026-10-18) — two service-judge convergence fixes.
//
// (1) elec-convergence-28-ups-root-service-judges-on-output — a UPS-backed
// service-entrance board is supplied THROUGH its UPS, so the service carries
// the UPS INPUT = output x kUpsInputFactor (1.10 recharge / 0.94 efficiency
// = 1.170213). The supply demand and the recommended daya already used it;
// the daya judge (`service-capacity-below-demand`) and the dual-service
// section load read the OUTPUT board.
//
//   Probe A: one 3ph UPS root, 6 x 6000 W heaters, cos phi 1.
//     Output 36 000 W -> 36 000 / (sqrt3 x 400) = 51.96 A.
//     UPS input 36 000 x 1.170213 = 42 127.7 VA -> 42 127.7 / 692.82 = 60.81 A.
//     Declared 41 500 VA -> limiter 41 500 / 692.82 = 59.90 A.
//     60.8 A > 59.9 A => the limiter trips: the warning MUST be raised.
//
//   Probe B: dual 2 x 1600 kVA declared; UPS root 25 x 50 kW + a 100 kW
//     normal root, cos phi 1. The UPS section carries
//     1 250 kVA x 1.170213 = 1 462.8 kVA = 91.4 % of 1600 kVA, above the
//     80 % / 1280 kVA loading target => `section-transformer-overloaded`.
//
// (2) elec-convergence-28-several-1ph-roots-summed-on-one-line — several
// single-phase service-entrance boards on one 3-phase service sit on
// DIFFERENT lines. Spreading them largest-first onto the lightest line
// (LPT) gives the heaviest line current I_max; the per-phase basis is
// sqrt3 x 400 x I_max (a 3-phase root loads every line with its own
// worst-phase current). One 1ph root keeps the Round-66 sqrt3 x 400 x I.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/sizing.dart' show roundTo;
import 'package:mechx_engine/electrical/supply_design.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();
final _sqrt3x400 = math.sqrt(3) * 400;

ElectricalCircuit _heater(String id, double w) => ElectricalCircuit(
    id: id,
    name: id,
    loadKind: LoadKind.heating,
    loadW: w,
    cosPhi: 1,
    phases: 3,
    length: const Length(10));

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

/// The LPT reference: the heaviest line current when the 1ph
/// roots' currents are placed largest first on the lightest of three lines,
/// above a common 3-phase base current on every line. NOTE: this is the
/// same largest-first / lightest-line loop as `allocateServiceLinesVa`, NOT
/// an independent oracle — the meaningful content of the property is its
/// three bound assertions (<= the old one-line sum, >= the balanced spread,
/// >= base + the largest 1ph root) over engine-derived currents.
double _lptMaxLineA(List<double> singles, double base) {
  final xs = [...singles]..sort((a, b) => b.compareTo(a));
  final lines = [base, base, base];
  for (final x in xs) {
    var k = 0;
    for (var i = 1; i < 3; i++) {
      if (lines[i] < lines[k] - 1e-9) k = i;
    }
    lines[k] += x;
  }
  return lines.reduce(math.max);
}

/// A root's per-line current on the service basis (the judge's 0.1 A
/// rounding, floored at its largest single machine).
double _rootA(ElectricalSystemResult sys, String id) => math.max(
    roundTo(sys.panels[id]!.diversifiedDemandCurrent.amperes, 1),
    sys.panels[id]!.largestDownstreamRunA);

void main() {
  group('UPS root judged on its UPS input', () {
    test('probe A: the daya judge reads 60.8 A, not the 52.0 A output', () {
      final pr = ElectricalProject(
          id: 'a',
          name: 'UPS service',
          supplyCapacityVa: const ApparentPower(41500),
          panels: [
            ElectricalPanel(
                id: 'U',
                name: 'UPS-MDP',
                upsBacked: true,
                circuits: [for (var i = 0; i < 6; i++) _heater('h$i', 6000)]),
          ]);
      final sys = computeSystem(_profile, pr);
      final r = sys.panels['U']!;
      expect(r.diversifiedDemandCurrent.amperes,
          closeTo(36000 / _sqrt3x400, 0.06));
      final inputA = 36000 * kUpsInputFactor / _sqrt3x400;
      expect(inputA, closeTo(60.81, 0.01));
      expect(41500 / _sqrt3x400, closeTo(59.90, 0.01));
      final w = r.warnings
          .where((w) => w.code == 'service-capacity-below-demand')
          .toList();
      expect(w, hasLength(1));
      expect(w.single.message, contains('60.8 A'));
      expect(w.single.message, contains('UPS input'));
      // Declaring the engine's own recommendation clears the judge.
      final st = computeAdvancedStudy(_profile, pr, sys);
      final daya = st.recommendedDayaVa!;
      expect(daya, greaterThanOrEqualTo(36000 * kUpsInputFactor));
      final pr2 = ElectricalProject(
          id: 'a',
          name: 'UPS service',
          supplyCapacityVa: ApparentPower(daya),
          panels: pr.panels);
      final sys2 = computeSystem(_profile, pr2);
      expect(
          sys2.panels['U']!.warnings
              .map((w) => w.code)
              .contains('service-capacity-below-demand'),
          isFalse);
    });

    test('a UPS root at Voltage(0) (hand-edited file) solves, never throws',
        () {
      final pr = ElectricalProject(
          id: 'z',
          name: 'Corrupt voltage',
          supplyCapacityVa: const ApparentPower(41500),
          panels: [
            ElectricalPanel(
                id: 'U',
                name: 'UPS-MDP',
                upsBacked: true,
                voltage: const Voltage(0),
                circuits: [for (var i = 0; i < 6; i++) _heater('h$i', 6000)]),
          ]);
      late ElectricalSystemResult sys;
      expect(() => sys = computeSystem(_profile, pr), returnsNormally);
      expect(sys.panels['U'], isNotNull);
      expect(() => computeAdvancedStudy(_profile, pr, sys), returnsNormally);
    });

    test('no UPS: the output board current is judged (unchanged)', () {
      final pr = ElectricalProject(
          id: 'a',
          name: 'plain',
          supplyCapacityVa: const ApparentPower(41500),
          panels: [
            ElectricalPanel(
                id: 'U',
                name: 'MDP',
                circuits: [for (var i = 0; i < 6; i++) _heater('h$i', 6000)]),
          ]);
      final sys = computeSystem(_profile, pr);
      // 51.96 A < 59.90 A => no warning.
      expect(
          sys.panels['U']!.warnings
              .map((w) => w.code)
              .contains('service-capacity-below-demand'),
          isFalse);
    });

    test('probe B: a dual-service UPS section is loaded at its UPS input', () {
      ElectricalProject build(int upsWays) => ElectricalProject(
              id: 'b',
              name: 'Data centre',
              dualTransformer: true,
              transformerKva: const ApparentPower(1600e3),
              panels: [
                ElectricalPanel(
                    id: 'U',
                    name: 'UPS-MDP',
                    upsBacked: true,
                    circuits: [
                      for (var i = 0; i < upsWays; i++) _heater('u$i', 50000)
                    ]),
                ElectricalPanel(
                    id: 'N', name: 'MDP-N', circuits: [_heater('n0', 100000)]),
              ]);
      final pr = build(25);
      final sys = computeSystem(_profile, pr);
      const section = 1250e3 * kUpsInputFactor;
      expect(section / 1000, closeTo(1462.8, 0.1));
      expect(section / 1600e3, greaterThan(0.8));
      expect(rootServiceDemandVa(pr, sys, 'U'), closeTo(section, 1));
      final st = computeAdvancedStudy(_profile, pr, sys);
      expect(st.warnings.map((w) => w.code),
          contains('section-transformer-overloaded'));
      expect(st.supply.note, contains('1462.8 kVA'));
      expect(st.supply.note, contains('91 %'));
    });
  });

  group('several 1ph roots are spread over the three lines', () {
    // Ten 1ph shop boards (2-4 socket ways each, 1500-4200 W, cos phi 0.9).
    final shopWays = <List<double>>[
      [1500, 1500],
      [2700, 1800, 1500],
      [4200, 3000, 1500, 1200],
      [2400, 2400],
      [4200, 3000, 1800],
      [4200, 4200, 2400, 1800],
      [3300, 3300],
      [4200, 3600, 2400],
      [4200, 4200, 4200, 3000],
      [3600, 2400, 3000],
    ];
    ElectricalProject shops() =>
        ElectricalProject(id: 'r', name: 'Ruko row', panels: [
          for (var k = 0; k < shopWays.length; k++) _shop('S$k', shopWays[k])
        ]);

    test('the ten-shop row stays an LV service on its real heaviest line', () {
      final pr = shops();
      final sys = computeSystem(_profile, pr);
      final currents = [
        for (var k = 0; k < shopWays.length; k++) _rootA(sys, 'S$k')
      ];
      final sum = currents.fold(0.0, (a, b) => a + b);
      final iMax = _lptMaxLineA(currents, 0);
      // LPT is never worse than the largest item + the mean share.
      expect(iMax, lessThanOrEqualTo(sum / 3 + currents.reduce(math.max)));
      final studied = studySupplyInputs(pr, sys);
      expect(studied.perPhaseBasisVa, closeTo(_sqrt3x400 * iMax, 1e-6));
      // The old one-line sum (sqrt3 x 400 x every root) was ~3x this.
      expect(studied.perPhaseBasisVa, lessThan(_sqrt3x400 * sum / 2));
      final st = computeAdvancedStudy(_profile, pr, sys);
      expect(st.supply.lvOrMv, SupplyLevel.lv);
      expect(st.supply.transformerKva, isNull);
      expect(st.recommendedDayaVa, isNotNull);
      // The 3ph PLN daya covers the heaviest line it is judged on.
      expect(st.recommendedDayaVa! + 1e-6,
          greaterThanOrEqualTo(_sqrt3x400 * iMax));
      expect(st.recommendedDayaThreePhase, isTrue);
    });

    test('one 1ph root beside a 3ph root keeps the Round-66 sum', () {
      final pr = ElectricalProject(id: 'm', name: 'mixed', panels: [
        ElectricalPanel(
            id: 'A',
            name: 'MDP-A',
            circuits: [for (var i = 0; i < 3; i++) _heater('a$i', 60000)]),
        _shop('B', [4200, 4200, 3000]),
      ]);
      final sys = computeSystem(_profile, pr);
      final studied = studySupplyInputs(pr, sys);
      expect(studied.perPhaseBasisVa,
          rootServiceBasisVa(pr, sys, 'A') + rootServiceBasisVa(pr, sys, 'B'));
    });

    test('seeded property: the basis is the LPT allocation over the lines', () {
      final rng = math.Random(77);
      for (var trial = 0; trial < 60; trial++) {
        final nSingle = 1 + rng.nextInt(9);
        final nThree = rng.nextInt(3);
        final panels = <ElectricalPanel>[
          for (var k = 0; k < nSingle; k++)
            _shop('S$k', [
              for (var i = 0; i < 1 + rng.nextInt(4); i++)
                (5 + rng.nextInt(40)) * 100.0
            ]),
          for (var k = 0; k < nThree; k++)
            ElectricalPanel(id: 'T$k', name: 'MDP-T$k', circuits: [
              for (var i = 0; i < 1 + rng.nextInt(3); i++)
                _heater('t$k$i', (5 + rng.nextInt(40)) * 1000.0)
            ]),
        ];
        final pr = ElectricalProject(id: 'q', name: 'q', panels: panels);
        final sys = computeSystem(_profile, pr);
        final singles = [for (var k = 0; k < nSingle; k++) _rootA(sys, 'S$k')];
        final threeVa = [
          for (var k = 0; k < nThree; k++) rootServiceBasisVa(pr, sys, 'T$k')
        ];
        final base = threeVa.fold(0.0, (a, b) => a + b) / _sqrt3x400;
        final basis = studySupplyInputs(pr, sys).perPhaseBasisVa;
        final expected = nSingle <= 1
            ? threeVa.fold(0.0, (a, b) => a + b) +
                singles.fold(0.0, (a, b) => a + _sqrt3x400 * b)
            : _sqrt3x400 * _lptMaxLineA(singles, base);
        expect(basis, closeTo(expected, 1e-3), reason: 'trial $trial');
        // Never below a balanced spread of the whole load, never above the
        // old one-line sum.
        final allOnOne = threeVa.fold(0.0, (a, b) => a + b) +
            singles.fold(0.0, (a, b) => a + _sqrt3x400 * b);
        expect(basis, lessThanOrEqualTo(allOnOne + 1e-3));
        final balanced = threeVa.fold(0.0, (a, b) => a + b) +
            singles.fold(0.0, (a, b) => a + _sqrt3x400 * b) / 3;
        expect(basis + 1e-3, greaterThanOrEqualTo(balanced));
        // The heaviest single 1ph root always sits whole on one line.
        expect(
            basis + 1e-3,
            greaterThanOrEqualTo(
                _sqrt3x400 * (base + singles.reduce(math.max))));
      }
    });

    test('allocateServiceLinesVa: two equal 1ph roots take two lines', () {
      expect(allocateServiceLinesVa({'a': 300, 'b': 300}, {'a', 'b'}), 300);
      expect(allocateServiceLinesVa({'a': 300}, {'a'}), 300);
      expect(
          allocateServiceLinesVa(
              {'a': 300, 'b': 300, 'c': 300, 'd': 300}, {'a', 'b', 'c', 'd'}),
          600);
      expect(allocateServiceLinesVa({'t': 900, 'a': 300, 'b': 300}, {'a', 'b'}),
          closeTo(1200, 1e-9));
    });
  });
}
