/// Round 29 electrical seed suite (2026-10-18):
///   * electrical-sim-3-1ph-motor-control-gear-3ph-flc — a single-phase
///     motor's starter, contactor and overload size on the 1φ FLC at U0.
///   * electrical-sim-3-declared-capacity-above-tr-ceiling — a declared PLN
///     connection above the LV (TR) ceiling is a TM (MV) service on ONE
///     snapped transformer for the study, fault estimate and drawings.
///   * electrical-sim-3-motor-fault-contribution-claimed-not-applied — the
///     motor-infeed provenance line prints only when an infeed was folded in.
///   * electrical-sim-3-main-earthing-off-ladder-single-conductor — a TN main
///     earthing conductor above the ladder top is n parallel ladder sections.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/motor_flc.dart';
import 'package:mechx_engine/electrical/control/starter.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/supply_design.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const p = PuilProfile();

ElectricalProject _motorBoard(
        {required int phases,
        required double kw,
        ElectricalSystem system = ElectricalSystem.threePhase,
        double volts = 400}) =>
    ElectricalProject(id: 'pr', name: 'B', panels: [
      ElectricalPanel(
        id: 'EP-1',
        name: 'EP-1',
        system: system,
        voltage: Voltage(volts),
        circuits: [
          ElectricalCircuit(
            id: 'jp',
            name: 'Jockey pump',
            loadKind: LoadKind.pump,
            motorKw: kw,
            cosPhi: 0.85,
            phases: phases,
            starterType: StarterType.dol,
            length: const Length(15),
          ),
        ],
      ),
    ]);

ControlDevice _role(ControlAssembly a, String role) =>
    a.devices.firstWhere((d) => d.role == role);

void main() {
  group('a 1φ motor\'s control gear sizes on the 1φ FLC', () {
    test('2.2 kW 1φ DOL on a 3φ 400 V board: FLC = 2200 / (231 x 0.68) = '
        '14.0 A (was the 3φ table 5.0 A)', () {
      final pr = _motorBoard(phases: 1, kw: 2.2);
      final sys = computeSystem(p, pr);
      final a = computeAdvancedStudy(p, pr, sys).controlAssemblies['jp']!;
      // U0 = round(400 / √3) = 231 V; η·cosφ(2.2 kW) = 0.68 (1φ table).
      const flc = 2200 / (231 * 0.68); // 14.006 A
      expect(a.motor!.flcA.amperes, closeTo(14.0, 1e-9));
      expect(a.motor!.flcA.amperes, closeTo(flc, 0.05));
      // The overload is set AT the FLC; the AC-3 contactor covers it.
      expect(_role(a, 'overload').targetRatingA!.amperes,
          greaterThanOrEqualTo(14.0 - 1e-9));
      final main = a.devices.firstWhere(
          (d) => d.category == DeviceCategory.contactor);
      expect(main.targetRatingA!.amperes, greaterThanOrEqualTo(14.0 - 1e-9));
      // The gear is never below the way's own running current.
      final ib = sys.panels['EP-1']!.circuits.single.designCurrent.amperes;
      expect(_role(a, 'overload').targetRatingA!.amperes,
          greaterThan(ib * 0.9));
    });

    test('the same 1φ motor on a 1φ 230 V board reads the same 1φ FLC', () {
      final pr = _motorBoard(
          phases: 1,
          kw: 2.2,
          system: ElectricalSystem.singlePhase,
          volts: 230);
      final a = computeAdvancedStudy(p, pr, computeSystem(p, pr))
          .controlAssemblies['jp']!;
      expect(a.motor!.flcA.amperes,
          closeTo((motorFlc1ph(2.2, const Voltage(230)).amperes * 10)
                  .roundToDouble() /
              10,
              1e-9));
    });

    test('property: a 3φ motor keeps the IEC 400 V table (byte-identical)',
        () {
      for (final kw in [0.75, 2.2, 5.5, 11.0, 30.0]) {
        final pr = _motorBoard(phases: 3, kw: kw);
        final a = computeAdvancedStudy(p, pr, computeSystem(p, pr))
            .controlAssemblies['jp']!;
        expect(a.motor!.flcA.amperes,
            closeTo((motorFlc(kw).amperes * 10).roundToDouble() / 10, 1e-9),
            reason: '$kw kW');
      }
    });

    test('property: a 1φ FLC is always above the 3φ FLC of the same rating '
        '(seeded over the 1φ range)', () {
      for (var kw = 0.18; kw <= 3.7; kw += 0.13) {
        final one = applyStarterTemplate(
            circuitId: 'x',
            starterType: StarterType.dol,
            motorKw: kw,
            voltage: const Voltage(231),
            singlePhase: true);
        final three = applyStarterTemplate(
            circuitId: 'x', starterType: StarterType.dol, motorKw: kw);
        expect(one.motor!.flcA.amperes,
            greaterThan(three.motor!.flcA.amperes),
            reason: '$kw kW');
      }
    });
  });

  group('a declared capacity above the LV ceiling is ONE MV service', () {
    ElectricalProject big(double? capVa) => ElectricalProject(
          id: 'pr',
          name: 'B',
          supplyCapacityVa: capVa == null ? null : ApparentPower(capVa),
          panels: const [
            ElectricalPanel(
              id: 'MDP',
              name: 'MDP',
              system: ElectricalSystem.threePhase,
              voltage: Voltage(400),
              circuits: [
                ElectricalCircuit(
                  id: 'l',
                  name: 'Lighting',
                  loadKind: LoadKind.lighting,
                  loadW: 240000,
                  cosPhi: 0.9,
                  phases: 3,
                  length: Length(10),
                ),
              ],
            ),
          ],
        );

    test('555 kVA daya: the study, fault, power one-line and drawings all '
        'describe a 630 kVA transformer', () {
      final pr = big(555000);
      expect(isDeclaredMvService(pr), isTrue);
      expect(declaredServiceTransformerKva(pr)!.inKilovoltAmperes, 630);
      final sys = computeSystem(p, pr);
      final adv = computeAdvancedStudy(p, pr, sys);
      // The study reports the DECLARED unit (was a demand-derived 400 kVA).
      expect(adv.supply.isMv, isTrue);
      expect(adv.supply.declared, isTrue);
      expect(adv.supply.transformerKva, 630);
      // Fault: 630e3 / (√3 · 400 · 0.04) = 22 733.0 A (was the raw 555 kVA's
      // 20 027 A, and the study's 400 kVA unit gives only 14 434 A).
      final isc = 630000 / (math.sqrt(3) * 400 * 0.04);
      expect(
          estimatedServiceFaultLevelA(pr, demand: sys.supply.demandVa)!
              .amperes,
          closeTo(isc, 0.05));
      expect(powerOneLineUtilitySub(pr, sys.supply.demandVa),
          'MV via TX 630 kVA');
      final labels = [
        for (final prim in buildElectricalOverview(
                project: pr, result: sys, sourceChain: true)
            .prims)
          if (prim is SldLabel) prim.text,
      ];
      expect(labels, contains('TRANSFORMER 630 kVA'));
    });

    test('property: a capacity at / below the LV ceiling stays an LV service '
        '(no transformer anywhere); above it, the snapped unit is the '
        'smallest ladder rating covering the daya (seeded)', () {
      final rnd = math.Random(29);
      for (var i = 0; i < 60; i++) {
        final cap = 1000 + rnd.nextDouble() * 2400000;
        final pr = big(cap);
        final tx = declaredServiceTransformerKva(pr);
        if (cap <= plnLvServiceCeilingVa) {
          expect(tx, isNull, reason: '$cap');
          expect(isDeclaredMvService(pr), isFalse, reason: '$cap');
        } else {
          final kva = tx!.inKilovoltAmperes;
          expect(kva, greaterThanOrEqualTo(cap / 1000 - 1e-9), reason: '$cap');
          final lower = transformerKvaLadder.where((k) => k < kva);
          for (final k in lower) {
            expect(k, lessThan(cap / 1000), reason: '$cap');
          }
          final sys = computeSystem(p, pr);
          expect(computeAdvancedStudy(p, pr, sys).supply.transformerKva, kva,
              reason: '$cap');
        }
      }
    });
  });

  group('motor-infeed provenance only when applied', () {
    test('a motor-heavy board: the advanced study passes no infeed, so its '
        'verify items never claim one', () {
      final pr = _motorBoard(phases: 3, kw: 30);
      final adv = computeAdvancedStudy(p, pr, computeSystem(p, pr));
      expect(adv.verifyItems, isNot(contains(faultStudyMotorVerifyItem)));
    });
  });

  group('TN main earthing conductor: orderable ladder make-up', () {
    test('4 runs x PE 150 mm2: 4 x 150 mm2 (total 600), never 1 x 600', () {
      final r = tnMainEarthingConductor(p, 150, runsPerPhase: 4);
      expect(r.perConductorMm2, 150);
      expect(r.count, 4);
      expect(r.totalMm2, 600);
      final e = computeEarthing(p,
          system: EarthingSystem.tnCs, supplyPeMm2: 150, runsPerPhase: 4);
      expect(e.mainEarthingMakeup, '4 x 150');
      expect(e.mainEarthingConductorMm2, 600);
    });

    test('a total on the ladder stays ONE conductor (2 x 70 = 140 -> 150)',
        () {
      final e = computeEarthing(p,
          system: EarthingSystem.tnS, supplyPeMm2: 70, runsPerPhase: 2);
      expect(e.mainEarthingConductorCount, 1);
      expect(e.mainEarthingMakeup, '150');
    });

    test('property: every conductor is a ladder rung, the total CSA covers '
        'the service PE sum and equals tnMainEarthingConductorMm2', () {
      final ladder = p.standardSectionsMm2;
      for (final pe in ladder) {
        for (var runs = 1; runs <= 8; runs++) {
          final r = tnMainEarthingConductor(p, pe, runsPerPhase: runs);
          expect(ladder, contains(r.perConductorMm2), reason: '$pe x $runs');
          expect(r.totalMm2,
              greaterThanOrEqualTo(math.max(16, pe * runs) - 1e-9),
              reason: '$pe x $runs');
          expect(r.totalMm2, r.perConductorMm2 * r.count);
          expect(tnMainEarthingConductorMm2(p, pe, runsPerPhase: runs),
              r.totalMm2);
        }
      }
    });
  });
}
