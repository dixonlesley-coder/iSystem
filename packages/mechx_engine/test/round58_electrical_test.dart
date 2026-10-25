// Round 58 (2026-10-18) — electrical engine pins.
//
//   elec-convergence-10-star-delta-ads-no-remedy — a star-delta way failing
//     TN ADS can be brought into compliance: the cable override and the ADS
//     growth size its MOTOR LEADS (the field run that sets Zs).
//   elec-convergence-10-ups-feeder-false-below-demand — a UPS-backed board's
//     feeder is judged on the balanced UPS INPUT it carries, and the UPS
//     decouples the pair (no selectivity target / finding).
//   elec-convergence-10-power-oneline-pln-on-genset-supply — on a genset
//     primary supply the power one-line draws the plant itself (no PLN head,
//     no ATS, no mains interlock) at the spine's kVA, and the supply study
//     recommends no PLN daya.
//   elec-convergence-10-n-section-transformer-service-unrepresentable — a
//     declared N-section service (one transformer per root board) faults
//     each root on ONE unit and judges each unit on its own root.
//
// First principles (the star-delta probe): TN-S, a 630 kVA / 4 % transformer
// (Isc = 630e3 / (sqrt3 x 400 x 0.04) = 22 733 A), a 10 m feeder, a 55 kW
// star-delta motor at 160 m. Ib = 55 / 0.88 kW at cos phi 0.85 on 400 V ~
// 106 A => a 125 A MCCB, whose magnetic release sits at 10 x In, so the
// 5 s-class ADS limit is Zs <= 0.95 x 230 / (10 x 125) = 0.1748 ohm. The
// loop is set by ONE lead phase conductor + both leads' PE over the 160 m
// (Round 43): growing the leads lowers it in proportion to 1 / csa.
library;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart' show StarterType;
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

ElectricalProject _plant(double lengthM,
        {double? cableMm2,
        StarterType starter = StarterType.starDelta,
        double kw = 55}) =>
    ElectricalProject(
      id: 'p',
      name: 'Pump house',
      earthingSystem: EarthingSystem.tnS,
      transformerKva: const ApparentPower(630e3),
      panels: [
        const ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            voltage: Voltage(400),
            circuits: [
              ElectricalCircuit(
                  id: 'f',
                  name: 'MCC feeder',
                  loadKind: LoadKind.feeder,
                  length: Length(10),
                  cableOverrideMm2: 300,
                  feedsPanelId: 'MCC'),
            ]),
        ElectricalPanel(
            id: 'MCC',
            name: 'MCC',
            voltage: const Voltage(400),
            circuits: [
              ElectricalCircuit(
                  id: 'm',
                  name: 'Transfer pump',
                  loadKind: LoadKind.pump,
                  motorKw: kw,
                  phases: 3,
                  starterType: starter,
                  cableOverrideMm2: cableMm2,
                  length: Length(lengthM)),
            ]),
      ],
    );

/// MDP -> a 3φ UPS-backed board with four 5000 W single-phase racks at
/// cos phi 0.85 (two land on one line: an inherent imbalance).
ElectricalProject _upsRoom() => ElectricalProject(
      id: 'u',
      name: 'Data room',
      earthingSystem: EarthingSystem.tnS,
      transformerKva: const ApparentPower(630e3),
      panels: [
        const ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            voltage: Voltage(400),
            circuits: [
              ElectricalCircuit(
                  id: 'fu',
                  name: 'UPS feeder',
                  loadKind: LoadKind.feeder,
                  length: Length(20),
                  feedsPanelId: 'UPS'),
            ]),
        ElectricalPanel(
            id: 'UPS',
            name: 'UPS',
            upsBacked: true,
            voltage: const Voltage(400),
            circuits: [
              for (var k = 0; k < 4; k++)
                ElectricalCircuit(
                    id: 'r$k',
                    name: 'Rack $k',
                    loadKind: LoadKind.socket,
                    loadW: 5000,
                    cosPhi: 0.85,
                    phases: 1,
                    length: const Length(10)),
            ]),
      ],
    );

/// An island resort on a 500 kVA prime genset plant: one MDP, six 3φ 40 kW
/// general ways.
ElectricalProject _island({SupplyKind kind = SupplyKind.generator}) =>
    ElectricalProject(
      id: 'i',
      name: 'Resort',
      earthingSystem: EarthingSystem.tt,
      supplyKind: kind,
      supplyCapacityVa: const ApparentPower(500e3),
      sources: const ElectricalSources(
          generator: GeneratorSource(mode: GeneratorMode.prime)),
      panels: [
        ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            voltage: const Voltage(400),
            circuits: [
              for (var k = 0; k < 6; k++)
                ElectricalCircuit(
                    id: 'g$k',
                    name: 'Villa block $k',
                    loadKind: LoadKind.general,
                    loadW: 40000,
                    phases: 3,
                    length: const Length(30)),
            ]),
      ],
    );

/// A three-building campus: one root board per building (six 3φ 110 kW
/// ways each), a declared 3750 kVA PLN connection.
ElectricalProject _campus({int? units, ApparentPower? tx}) => ElectricalProject(
      id: 'c',
      name: 'Campus',
      earthingSystem: EarthingSystem.tnS,
      supplyCapacityVa: tx == null ? const ApparentPower(3750e3) : null,
      transformerKva: tx,
      transformerUnits: units,
      panels: [
        for (final b in ['A', 'B', 'C'])
          ElectricalPanel(
              id: 'MDP-$b',
              name: 'MDP-$b',
              voltage: const Voltage(400),
              circuits: [
                for (var k = 0; k < 6; k++)
                  ElectricalCircuit(
                      id: '$b$k',
                      name: 'Load $b$k',
                      loadKind: LoadKind.general,
                      loadW: 110000,
                      phases: 3,
                      length: const Length(20)),
              ]),
      ],
    );

void main() {
  group('elec-convergence-10-star-delta-ads-no-remedy', () {
    final fault = estimatedServiceFaultLevelA(_plant(160))!;

    test('a 22 kW star-delta way at 220 m grows its motor leads and passes',
        () {
      // Ib = 22 / 0.88 kW / (sqrt3 x 400 x 0.85) ~ 42.5 A => a 50 A MCB
      // (a final > 32 A: the 5 s class, magnetic multiple k = 10), limit
      // 0.95 x 230 / (10 x 50) = 0.437 ohm. The ampacity-sized leads
      // (Ib / sqrt3 ~ 24.5 A => 16 mm2 on the 220 m Vd) fail; the growth
      // steps the LEADS (not the 2 m link) until the loop passes.
      final pr = _plant(220, kw: 22);
      final sys = computeSystem(_profile, pr, originFaultLevel: fault);
      final w = sys.panels['MCC']!.circuits.single;
      final f = faultStudy(sys, pr, _profile, originFaultLevel: fault);
      expect(w.motorLeads, isNotNull);
      expect(w.motorLeads!.csaMm2, greaterThan(16));
      // The 2 m internal link stays ampacity-sized (not grown).
      expect(w.cable.csaMm2, lessThan(w.motorLeads!.csaMm2));
      expect(w.cableRaisedForAds, isTrue);
      expect(f.circuits['m']!.adsOk, isTrue);
      expect(f.circuits['m']!.zsOhm!,
          lessThanOrEqualTo(f.circuits['m']!.zsMaxOhm!));
      expect(
          sys.warnings
              .firstWhere(
                  (x) => x.code == 'cable-raised-for-ads' && x.circuitId == 'm')
              .message,
          contains('motor leads raised'));
    });

    test('the 55 kW / 160 m way past the bounded ladder names the leads', () {
      // The 35 mm2 leads sit at the growth cap (kAdsCsaGrowthMaxMm2): the
      // error stands but now names the remedy that reaches the loop.
      final pr = _plant(160);
      final sys = computeSystem(_profile, pr, originFaultLevel: fault);
      final f = faultStudy(sys, pr, _profile, originFaultLevel: fault);
      expect(sys.panels['MCC']!.circuits.single.motorLeads!.csaMm2, 35);
      expect(f.circuits['m']!.adsOk, isFalse);
      expect(
          f.warnings
              .firstWhere(
                  (x) => x.code == 'ads-disconnection' && x.circuitId == 'm')
              .message,
          contains('motor-lead CSA'));
    });

    test('a cable override sizes the motor leads (the in-tool remedy)', () {
      // The ampacity-sized leads fail: pin them at 35 mm2.
      final pinned = _plant(160, cableMm2: 35);
      final sys35 = computeSystem(_profile, pinned, originFaultLevel: fault);
      final f35 = faultStudy(sys35, pinned, _profile, originFaultLevel: fault);
      expect(sys35.panels['MCC']!.circuits.single.motorLeads!.csaMm2, 35);
      expect(f35.circuits['m']!.adsOk, isFalse);
      expect(
          f35.warnings
              .firstWhere(
                  (x) => x.code == 'ads-disconnection' && x.circuitId == 'm')
              .message,
          contains('motor-lead CSA'));
      // Typed 120 mm2: the leads follow (no longer stuck at 35) and the loop
      // drops in proportion (lead R ~ 1 / csa): it now disconnects in time.
      final big = _plant(160, cableMm2: 120);
      final sys = computeSystem(_profile, big, originFaultLevel: fault);
      final f = faultStudy(sys, big, _profile, originFaultLevel: fault);
      final w = sys.panels['MCC']!.circuits.single;
      expect(w.motorLeads!.csaMm2, greaterThanOrEqualTo(120));
      expect(f.circuits['m']!.adsOk, isTrue);
      expect(f.circuits['m']!.zsOhm!, lessThan(f35.circuits['m']!.zsOhm!));
    });

    test('a DOL way is unchanged by the star-delta rule (no leads)', () {
      final pr = _plant(40, starter: StarterType.dol);
      final sys = computeSystem(_profile, pr, originFaultLevel: fault);
      expect(sys.panels['MCC']!.circuits.single.motorLeads, isNull);
    });
  });

  group('elec-convergence-10-ups-feeder-false-below-demand', () {
    test('the feeder is judged on the UPS input, never the output phase', () {
      final pr = _upsRoom();
      final sys = computeSystem(_profile, pr);
      final feeder = sys.panels['MDP']!.circuits.single;
      // UPS input = 20 000 W / 0.85 = 23 529 VA x kUpsInputFactor
      // (1.10 / 0.94) = 27 534 VA over sqrt3 x 400 = 39.7 A, balanced.
      const inputA = 20000 / 0.85 * kUpsInputFactor / (1.7320508 * 400);
      expect(inputA, closeTo(39.7, 0.05));
      expect(feeder.breaker.ratingA.amperes, greaterThanOrEqualTo(inputA));
      // Non-vacuous: the UPS OUTPUT worst phase (two racks on one line,
      // 2 x 5000 / (230 x 0.85) = 51.2 A at the board's U0) sits ABOVE the
      // feeder rating — the old judge compared against it. The rectifier
      // draws the balanced input, so that comparison was false.
      expect(sys.panels['UPS']!.demandCurrent.amperes,
          greaterThan(feeder.breaker.ratingA.amperes));
      final codes = [
        for (final p in sys.panels.values)
          for (final w in p.warnings) w.code,
        for (final w in sys.warnings) w.code,
      ];
      expect(codes, isNot(contains('feeder-below-fed-demand')));
      expect(codes, isNot(contains('feeder-below-fed-headroom')));
      final f = faultStudy(sys, pr, _profile,
          originFaultLevel: estimatedServiceFaultLevelA(pr)!);
      final fc = f.warnings.map((w) => w.code);
      expect(fc, isNot(contains('non-selective')));
      expect(fc, isNot(contains('selectivity-partial')));
    });
  });

  group('elec-convergence-10-power-oneline-pln-on-genset-supply', () {
    test('a genset primary supply: no PLN head, no ATS, the spine kVA', () {
      final pr = _island();
      final sys = computeSystem(_profile, pr);
      final st = computeAdvancedStudy(_profile, pr, sys);
      final ol = st.powerOneLine!;
      expect(ol.nodeOfKind(PowerNodeKind.utility), isNull);
      expect(ol.nodeOfKind(PowerNodeKind.ats), isNull);
      expect(ol.interlocks.where((i) => i.note.contains('Mains')), isEmpty);
      final head = ol.nodeOfKind(PowerNodeKind.generator)!;
      expect(head.label, 'GENSET SUPPLY');
      // The plant is the declared 500 kVA — the figure the spine head prints
      // ('GENSET SUPPLY 500 kVA'), never a second sized 250 kVA set.
      expect(head.sub, startsWith('500 kVA'));
      expect(ol.nodes.where((n) => n.kind == PowerNodeKind.generator),
          hasLength(1));
      // The plant feeds the main bus directly.
      expect(ol.edges.any((e) => e.from == head.id && e.to == 'bus'), isTrue);
      // No PLN connection in the supply study.
      expect(st.recommendedDayaVa, isNull);
      expect(st.supply.note, isNot(contains('PLN LV connection')));
      expect(st.supply.note, contains('no PLN connection'));
    });

    test('a PLN supply keeps the utility, ATS and interlocks', () {
      final pr = _island(kind: SupplyKind.pln);
      final sys = computeSystem(_profile, pr);
      final ol = computeAdvancedStudy(_profile, pr, sys).powerOneLine!;
      expect(ol.nodeOfKind(PowerNodeKind.utility)!.label, 'PLN utility');
      expect(ol.nodeOfKind(PowerNodeKind.ats), isNotNull);
      expect(ol.nodeOfKind(PowerNodeKind.generator)!.label, 'Generator');
    });
  });

  group('elec-convergence-10-n-section-transformer-service-unrepresentable',
      () {
    // One 1250 kVA unit (4 %) per root: Isc = 1.25e6 / (sqrt3 x 400 x 0.04)
    // = 45 105 A. The legacy reading parallels 2 x 2000 kVA: 4e6 / (sqrt3 x
    // 400 x 0.04) = 144 338 A.
    const oneUnitA = 1.25e6 / (1.7320508075688772 * 400 * 0.04);
    const legacyA = 4e6 / (1.7320508075688772 * 400 * 0.04);

    test('3 sections of a declared 3750 kVA: 3 x 1250 kVA, one-unit fault', () {
      final pr = _campus(units: 3);
      final sys = computeSystem(_profile, pr);
      final st = computeAdvancedStudy(_profile, pr, sys);
      expect(st.supply.transformerKva, 1250);
      expect(st.supply.units, 3);
      final fault = estimatedServiceFaultLevelA(pr,
          demand: sys.supply.demandVa, supply: st.supply)!;
      expect(fault.amperes, closeTo(oneUnitA, 0.1));
      // Each unit carries ONE building (6 x 110 kW at the default pf, well
      // inside 0.8 x 1250 = 1000 kVA): no false below-demand verdict.
      expect(st.supply.declaredBelowDemand, isFalse);
      expect(st.warnings.map((w) => w.code),
          isNot(contains('transformer-below-demand')));
    });

    test('an explicit 1250 kVA unit x 3 sections reads the same', () {
      final pr = _campus(units: 3, tx: const ApparentPower(1250e3));
      final sys = computeSystem(_profile, pr);
      final st = computeAdvancedStudy(_profile, pr, sys);
      expect(st.supply.units, 3);
      expect(st.supply.declaredBelowDemand, isFalse);
      expect(estimatedServiceFaultLevelA(pr)!.amperes, closeTo(oneUnitA, 0.1));
    });

    test('legacy (no sections) stays 2 x 2000 kVA paralleled, byte-identical',
        () {
      final pr = _campus();
      final sys = computeSystem(_profile, pr);
      final st = computeAdvancedStudy(_profile, pr, sys);
      expect(st.supply.transformerKva, 2000);
      expect(st.supply.units, 2);
      final fault = estimatedServiceFaultLevelA(pr,
          demand: sys.supply.demandVa, supply: st.supply)!;
      expect(fault.amperes, closeTo(legacyA, 0.1));
    });

    test('transformerUnits round-trips tolerantly in .mechx', () {
      final pr = _campus(units: 3);
      expect(ElectricalProject.fromJson(pr.toJson()).transformerUnits, 3);
      expect(_campus().toJson().containsKey('transformerUnits'), isFalse);
      for (final bad in [0, -2, 'x', double.nan]) {
        final j = {..._campus().toJson(), 'transformerUnits': bad};
        expect(ElectricalProject.fromJson(j).transformerUnits, isNull,
            reason: '$bad');
      }
    });
  });
}
