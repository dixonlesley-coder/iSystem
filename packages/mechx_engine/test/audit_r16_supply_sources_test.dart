// Round 16 — supply-source regressions (2026-10-18).
//
//   genset-kw-limit            a genset is rated kW = 0.8 × kVA: the rating
//                              covers max(S, P / 0.8); fuel burns the real kW.
//   battery-critical-load-pf   the bank + inverter carry the REAL demand W.
//   installed-pfc              an installed bank enters the PF study.
//   undeclared-mv-fault        a demand needing MV gets that transformer's
//                              fault, not the flat 16 kA (one Z = 4 %).
//   declared-tx-study          a declared transformer IS the supply.
//   dual-tx-spine              the spine + schedule print the study's
//                              2 × unit pick on the transformer ladder.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/power_factor.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/electrical/supply_design.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

ElectricalProject _mdp(List<ElectricalCircuit> cs,
        {ElectricalSources? sources,
        ApparentPower? transformerKva,
        bool dual = false,
        double? capKvar}) =>
    ElectricalProject(
      id: 'p',
      name: 'P',
      sources: sources,
      transformerKva: transformerKva,
      dualTransformer: dual,
      capacitorBankKvar: capKvar,
      panels: [ElectricalPanel(id: 'MDP', name: 'MDP', circuits: cs)],
    );

List<ElectricalCircuit> _ways(int n, double w, double pf) => [
      for (var i = 0; i < n; i++)
        ElectricalCircuit(
            id: 'c$i',
            name: 'L$i',
            loadW: w,
            cosPhi: pf,
            phases: 3,
            length: const Length(10)),
    ];

String _labels(List<SldPrim> prims) =>
    prims.whereType<SldLabel>().map((l) => l.text).join('\n');

void main() {
  group('genset-kw-limit', () {
    test('90 kW at cos φ 0.95: max(94.7 kVA, 90 / 0.8 = 112.5) ⇒ 125 kVA', () {
      final r = sizeGenerator(ApparentPower.kilovoltAmperes(90 / 0.95),
          backupPower: const Power(90000));
      expect(r.ratingKva.inKilovoltAmperes, 125);
      // The kVA alone picked 100 kVA = 80 kW (12.5 % short of 90 kW).
      expect(
          sizeGenerator(ApparentPower.kilovoltAmperes(90 / 0.95))
              .ratingKva
              .inKilovoltAmperes,
          100);
      // Fuel at the REAL 90 kW: 90 × 0.25 = 22.5 l/h; 8 h ⇒ a 180 L day-tank.
      expect(r.fuelLph, closeTo(22.5, 1e-9));
      expect(r.dayTankL, 180);
      // Prime: 112.5 × 1.25 = 140.6 ⇒ 150 kVA.
      expect(
          sizeGenerator(ApparentPower.kilovoltAmperes(90 / 0.95),
                  backupPower: const Power(90000), mode: GeneratorMode.prime)
              .ratingKva
              .inKilovoltAmperes,
          150);
    });

    test('a load below cos φ 0.8 stays kVA-limited', () {
      // 60 kW at 0.7 = 85.7 kVA > 60 / 0.8 = 75 ⇒ the 100 kVA rung either way.
      final r = sizeGenerator(ApparentPower.kilovoltAmperes(60 / 0.7),
          backupPower: const Power(60000));
      expect(r.ratingKva.inKilovoltAmperes, 100);
    });

    test('the spine and G-01 agree; the backup % is kW-honest', () {
      final p = _mdp(_ways(6, 15000, 0.95),
          sources: const ElectricalSources(generator: GeneratorSource()));
      final sys = computeSystem(_profile, p);
      final kw = sys.supply.demandW / 1000;
      final kva = sys.supply.demandVa.inKilovoltAmperes;
      expect(kw / kGeneratorPf, greaterThan(kva)); // kW-limited premise
      final need = math.max(kva, kw / kGeneratorPf);
      final rung = kGeneratorKva.firstWhere((k) => k >= need);
      final spine =
          _labels(buildElectricalSourceSpine(project: p, result: sys).prims);
      expect(spine, contains('GENSET ${rung.toInt()} kVA'));
      final pct =
          (math.min(1.0, math.min(rung / kva, rung * kGeneratorPf / kw)) * 100)
              .round();
      expect(spine, contains('backs $pct% of load'));
      final rows = buildEquipmentScheduleRows(EquipmentScheduleData(
          projectName: 'P',
          date: '2026-10-18',
          electrical: sys,
          electricalProject: p));
      expect(
          rows.firstWhere((r) => r.tag == 'G-01').duty, '${rung.toInt()} kVA');
    });
  });

  group('battery-critical-load-pf', () {
    test('the bank + inverter are sized on the real demand W', () {
      final p = _mdp(_ways(6, 15000, 0.95),
          sources: const ElectricalSources(
              battery: BatterySource(autonomyHours: 1)));
      final sys = computeSystem(_profile, p);
      final adv = computeAdvancedStudy(_profile, p, sys);
      final expected = sizeBattery(Power(sys.supply.demandW), autonomyHours: 1);
      // E = P·t / (DoD·η) = P / (0.9 · 0.95) for 1 h LiFePO4.
      expect(expected.requiredKwh.inKilowattHours,
          closeTo(sys.supply.demandW / 1000 / (0.9 * 0.95), 0.06));
      // The inverter covers the real load (VA × 0.8 under-read it 16 %).
      expect(expected.inverterKw.inKiloWatts * expected.inverterUnits,
          greaterThanOrEqualTo(sys.supply.demandW / 1000));
      final kwhText = [
        for (final n in adv.powerOneLine!.nodes) '${n.label} ${n.sub ?? ''}',
      ].join('\n');
      final installed = expected.installedKwh.inKilowattHours;
      expect(
          kwhText,
          contains(installed == installed.roundToDouble()
              ? installed.toInt().toString()
              : installed.toString()));
      final spine =
          _labels(buildElectricalSourceSpine(project: p, result: sys).prims);
      expect(spine, contains('BATTERY'));
    });
  });

  group('installed-pfc', () {
    // 4 × 30 kW at cos φ 0.75: P = 120 kW, Q = 120·tan(acos 0.75) = 105.83 kvar.
    final q = 120 * math.tan(math.acos(0.75));

    test('no bank: pf 0.75 ⇒ a bank is recommended', () {
      final p = _mdp(_ways(4, 30000, 0.75));
      final r = powerFactorCorrection(computeSystem(_profile, p), p);
      expect(r.totalKvar, closeTo(q, 0.06));
      expect(r.existingPf, closeTo(0.75, 1e-3));
      expect(r.needed, isTrue);
      expect(r.bankKvar, greaterThan(0));
    });

    test('an installed 75 kvar bank (way OR project field) reads pf 0.969', () {
      // Residual Q = 105.83 − 75 = 30.83; S = √(120² + 30.83²) = 123.90;
      // pf = 120 / 123.90 = 0.9685 ≥ 0.95 ⇒ no further bank.
      final expectedPf = 120 / math.sqrt(120 * 120 + (q - 75) * (q - 75));
      expect(expectedPf, closeTo(0.9685, 5e-4));
      final viaWay = _mdp([
        ..._ways(4, 30000, 0.75),
        const ElectricalCircuit(
            id: 'cap',
            name: 'PFC',
            loadW: 75000,
            phases: 3,
            loadKind: LoadKind.capacitor,
            length: Length(5)),
      ]);
      final viaField = _mdp(_ways(4, 30000, 0.75), capKvar: 75);
      for (final p in [viaWay, viaField]) {
        final r = powerFactorCorrection(computeSystem(_profile, p), p);
        expect(r.installedKvar, closeTo(75, 1e-9));
        expect(r.uncorrectedPf, closeTo(0.75, 1e-3));
        expect(r.existingPf, closeTo(expectedPf, 1e-3));
        expect(r.needed, isFalse);
        expect(r.bankKvar, 0);
        expect(r.leading, isFalse);
      }
    });

    test('an oversized installed bank reads LEADING and sizes nothing more',
        () {
      final p = _mdp(_ways(4, 30000, 0.75), capKvar: 150);
      final r = powerFactorCorrection(computeSystem(_profile, p), p);
      expect(r.leading, isTrue);
      expect(r.needed, isFalse);
      expect(r.bankKvar, 0);
      expect(r.note, contains('LEADING'));
    });
  });

  group('undeclared-mv-fault', () {
    test("one transformer impedance: the study's 4 %", () {
      expect(transformerImpedancePct, 4);
      expect(representativeTransformerZpu, transformerImpedancePct / 100);
    });

    test('an MV-sized demand ⇒ the study unit at 4 %, not 16 kA', () {
      final p = _mdp(_ways(8, 85000, 0.85));
      final sys = computeSystem(_profile, p);
      final demand = sys.supply.demandVa;
      final supply = determineSupply(demand);
      expect(supply.isMv, isTrue);
      final unit = transformerKvaLadder
          .firstWhere((k) => k >= demand.inKilovoltAmperes / 0.8);
      expect(supply.transformerKva, unit);
      // Isc = S / (√3·400·0.04), clamped at 50 kA.
      final expected =
          math.min(unit * 1000 / (math.sqrt(3) * 400 * 0.04), 50000.0);
      expect(estimatedServiceFaultLevelA(p), isNull); // nothing declared
      expect(estimatedServiceFaultLevelA(p, demand: demand)!.amperes,
          closeTo(expected, 0.06));
      expect(expected, greaterThan(16000));
      // The fault study runs at that figure.
      final adv = computeAdvancedStudy(_profile, p, sys);
      expect(adv.fault.originFaultkA * 1000, closeTo(expected, 60));
    });

    test('an LV demand keeps no claim (the caller keeps 16 kA)', () {
      final p = _mdp(_ways(2, 20000, 0.9));
      final sys = computeSystem(_profile, p);
      expect(
          estimatedServiceFaultLevelA(p, demand: sys.supply.demandVa), isNull);
    });

    test("a dual service takes ONE section's unit (coupler N.O.)", () {
      final p = _mdp(_ways(8, 85000, 0.85), dual: true);
      final sys = computeSystem(_profile, p);
      final s = determineSupply(sys.supply.demandVa, dualTransformer: true);
      expect(s.units, 2);
      final expected = math.min(
          s.transformerKva! * 1000 / (math.sqrt(3) * 400 * 0.04), 50000.0);
      expect(
          estimatedServiceFaultLevelA(p, demand: sys.supply.demandVa)!.amperes,
          closeTo(expected, 0.06));
    });
  });

  group('declared-tx-study', () {
    test('a declared 630 kVA unit is the arrangement: MV, no LV daya', () {
      final p = _mdp(_ways(3, 45000, 0.9),
          transformerKva: ApparentPower.kilovoltAmperes(630));
      final sys = computeSystem(_profile, p);
      expect(sys.supply.demandVa.inKilovoltAmperes, lessThan(200));
      final adv = computeAdvancedStudy(_profile, p, sys);
      expect(adv.supply.isMv, isTrue);
      expect(adv.supply.transformerKva, 630);
      expect(adv.supply.units, 1);
      expect(adv.supply.declared, isTrue);
      expect(adv.supply.declaredBelowDemand, isFalse);
      expect(adv.recommendedDayaVa, isNull);
    });

    test('a declared unit loaded past 80 % is flagged', () {
      // 150 kVA demand vs 160 kVA × 0.8 = 128 kVA ⇒ below demand.
      final s = determineSupply(ApparentPower.kilovoltAmperes(150),
          declaredKva: ApparentPower.kilovoltAmperes(160));
      expect(s.declaredBelowDemand, isTrue);
      expect(s.note, contains('raise the rating'));
      // 100 kVA vs 160 × 0.8 = 128 ⇒ fine.
      expect(
          determineSupply(ApparentPower.kilovoltAmperes(100),
                  declaredKva: ApparentPower.kilovoltAmperes(160))
              .declaredBelowDemand,
          isFalse);
    });
  });

  group('dual-tx-spine', () {
    test('dual service: 2 × the study unit on spine, schedule and study', () {
      final p = _mdp(_ways(10, 45000, 0.9), dual: true);
      final sys = computeSystem(_profile, p);
      // Round 60 — ONE service-entrance board sits on ONE section (coupler
      // normally open), so each unit carries the whole demand:
      // per unit >= demand / 0.8 (500 kVA / 0.8 = 625 ⇒ 630 kVA), never the
      // demand / 2 share the lone root can never draw from the other unit.
      final perUnit = sys.supply.demandVa.inKilovoltAmperes / 0.8;
      final unit = transformerKvaLadder.firstWhere((k) => k >= perUnit);
      final adv = computeAdvancedStudy(_profile, p, sys);
      expect(adv.supply.transformerKva, unit);
      expect(adv.supply.units, 2);
      final spine =
          _labels(buildElectricalSourceSpine(project: p, result: sys).prims);
      expect(spine, contains('TRANSFORMER 2 x ${unit.toInt()} kVA'));
      final h = _labels(
          buildElectricalSourceSpine(project: p, result: sys, horizontal: true)
              .prims);
      expect(h, contains('TRAFO 2 x ${unit.toInt()} kVA'));
      final rows = buildEquipmentScheduleRows(EquipmentScheduleData(
          projectName: 'P',
          date: '2026-10-18',
          electrical: sys,
          electricalProject: p));
      final tx = rows.firstWhere((r) => r.tag == 'TX-01');
      expect(tx.duty, '${unit.toInt()} kVA');
      expect(tx.qty, 2);
    });
  });
}
