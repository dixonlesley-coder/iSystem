/// ROUND 14 (2026-10-18) — electrical sizing rules, each pinned by a
/// hand-derived case and (where the rule is a property) a SEEDED property:
///
///   1. A capacitor way's phase decision reads its kvar rating (an Auto-phase
///      bank on a 3φ board is three-phase, never a 216 A single-pole way).
///   2. The FEEDER to a capacitor board floors at the SAME switching current
///      the fed board's incomer floors at (one phase model, not two).
///   3. The service cable + main earthing follow a root incomer the capacitor
///      floor lifted above its demand (as Round 12 did for headroom).
///   4. The supply kVA uses the real per-circuit cos φ, not a flat 0.85.
///   5. The metering CT covers the current the board is SIZED for.
///   6. A declared genset alone draws no capacitor bank on the spine.
///   7. A placed AC / FCU is minted as an HVAC final (curve C), not a pump.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/load_list.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/sizing.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const p = PuilProfile();

ElectricalCircuitResult _way(ElectricalSystemResult r, String panel, String id) =>
    r.panels[panel]!.circuits.firstWhere((c) => c.circuitId == id);

ElectricalPanel _p3(String id, List<ElectricalCircuit> circuits,
        {String? fedBy}) =>
    ElectricalPanel(
      id: id,
      name: id,
      system: ElectricalSystem.threePhase,
      voltage: const Voltage(400),
      sourceType: fedBy == null ? PanelSource.utility : PanelSource.feeder,
      fedByCircuitId: fedBy,
      circuits: circuits,
    );

ElectricalCircuit _bank(String id, double kvar, {int? phases}) =>
    ElectricalCircuit(
      id: id,
      name: 'Bank $id',
      loadKind: LoadKind.capacitor,
      loadW: kvar,
      cosPhi: 1.0,
      phases: phases,
      length: const Length(5),
    );

ElectricalProject _capProject(List<ElectricalCircuit> banks,
        {List<ElectricalCircuit> mdpLoads = const []}) =>
    ElectricalProject(
      id: 'cap',
      name: 'CAP',
      earthingSystem: EarthingSystem.tnCs,
      panels: [
        _p3('MDP', [
          ...mdpLoads,
          const ElectricalCircuit(
            id: 'f-cap',
            name: 'Feeder CAP',
            loadKind: LoadKind.feeder,
            length: Length(10),
            feedsPanelId: 'CAP',
          ),
        ]),
        _p3('CAP', banks, fedBy: 'f-cap'),
      ],
    );

void main() {
  // ── 1. Auto-phase capacitor way ────────────────────────────────────────────
  group('1 — an Auto-phase capacitor way sizes on its kvar rating', () {
    test('50 kvar, phases null, on a 3φ board ⇒ 3φ 72.2 A, never 1φ 216 A',
        () {
      final sys = computeSystem(
          p,
          ElectricalProject(id: 'x', name: 'x', panels: [
            _p3('LVMDP', [_bank('c', 50000)]),
          ]));
      final c = _way(sys, 'LVMDP', 'c');
      // 50 000 var > singlePhaseMaxW (5 500) ⇒ three-phase:
      // Ib = Q / (√3 · 400) = 72.17 A (was 50 000 / 231 = 216.5 A, 1φ).
      expect(singlePhaseMaxW, lessThan(50000));
      expect(c.threePhase, isTrue);
      expect(c.designCurrent.amperes,
          closeTo(50000 / (math.sqrt(3) * 400), 0.06));
      // Switching current 1.43 × 72.17 = 103.2 A ⇒ the 125 A rung (not 315 A).
      expect(c.breaker.ratingA.amperes, 125);
    });

    test('property: the way and the floor agree on the phase (seeded)', () {
      final rnd = math.Random(14014);
      for (var t = 0; t < 40; t++) {
        final kvar = 1000 + rnd.nextInt(80000).toDouble();
        final sys = computeSystem(p, _capProject([_bank('b', kvar)]));
        final b = _way(sys, 'CAP', 'b');
        final three = kvar > singlePhaseMaxW;
        expect(b.threePhase, three, reason: 'trial $t $kvar var');
        final rated = three ? kvar / (math.sqrt(3) * 400) : kvar / 231;
        // The CAP incomer floor = the switching current of THAT phase model.
        expect(sys.panels['CAP']!.capacitorCurrentA,
            closeTo(kCapacitorSwitchingFactor * rated, 0.11),
            reason: 'trial $t $kvar var');
      }
    });
  });

  // ── 2. one capacitor phase model for the incomer AND its feeder ───────────
  group('2 — the feeder floors at the fed board\'s own switching current', () {
    test('two 1φ 10 kvar banks: CAP incomer and MDP feeder both ≥ 123.8 A', () {
      final sys = computeSystem(p,
          _capProject([_bank('b1', 10000, phases: 1), _bank('b2', 10000, phases: 1)]));
      final cap = sys.panels['CAP']!;
      // Each bank: 10 000 / 231 = 43.29 A × 1.43 = 61.9 A on ITS line. The
      // board's own balance assignment places both (0 balance current each)
      // on the same line ⇒ 2 × 61.9 = 123.8 A on it.
      final line = [
        for (final c in cap.circuits) c.phase,
      ];
      const perBank = kCapacitorSwitchingFactor * 10000 / 231;
      final sameLine = line[0] == line[1];
      final expected = sameLine ? 2 * perBank : perBank;
      expect(cap.capacitorCurrentA, closeTo(expected, 0.11));
      // The feeder floors at the SAME figure (was 61.9 A ⇒ an 80 A feeder on
      // 25 mm² supplying a 125 A incomer).
      final feeder = _way(sys, 'MDP', 'f-cap');
      expect(feeder.breaker.ratingA.amperes,
          greaterThanOrEqualTo(cap.capacitorCurrentA - 0.1));
      expect(feeder.breaker.ratingA.amperes,
          greaterThanOrEqualTo(cap.incomer.breaker.ratingA.amperes));
    });

    test('property: feeder ≥ fed incomer floor for random bank sets (seeded)',
        () {
      final rnd = math.Random(20261018);
      for (var t = 0; t < 40; t++) {
        final n = 1 + rnd.nextInt(4);
        final banks = [
          for (var i = 0; i < n; i++)
            _bank('b$i', 2000 + rnd.nextInt(30000).toDouble(),
                phases: const [null, 1, 3][rnd.nextInt(3)]),
        ];
        final sys = computeSystem(p, _capProject(banks));
        final cap = sys.panels['CAP']!;
        final feeder = _way(sys, 'MDP', 'f-cap');
        expect(feeder.breaker.ratingA.amperes,
            greaterThanOrEqualTo(cap.capacitorCurrentA - 0.1),
            reason: 'trial $t');
      }
    });
  });

  // ── 3. earthing follows a capacitor-floored root incomer ──────────────────
  group('3 — main earthing sized for the capacitor-lifted incomer', () {
    const motor = ElectricalCircuit(
      id: 'm',
      name: 'Motor 30 kW',
      loadKind: LoadKind.motor,
      motorKw: 30,
      cosPhi: 0.85,
      phases: 3,
      length: Length(20),
    );

    test('30 kW motor + 100 kvar bank downstream: 250 A incomer ⇒ its PE', () {
      final sys = computeSystem(
          p, _capProject([_bank('b', 100000, phases: 3)], mdpLoads: [motor]));
      final mdp = sys.panels['MDP']!;
      // Bank switching 1.43 × 144.3 = 206.4 A ⇒ the 250 A incomer.
      expect(mdp.incomer.breaker.ratingA.amperes, 250);
      // The service cable is sized for the 250 A device (In ≤ Iz), and the
      // main earthing / bonding derive from ITS PE — not from the 63 A
      // demand-selected device (16 / 10 mm²).
      final cable = sizeCable(p,
          designCurrent: const Current(250),
          breakerRating: const Current(250),
          deratingFactor: 1,
          minSectionMm2: 4);
      final earthing = computeEarthing(p,
          system: EarthingSystem.tnCs,
          supplyPeMm2: p.peConductorSizeMm2(cable.csaMm2));
      expect(sys.earthing.mainEarthingConductorMm2,
          earthing.mainEarthingConductorMm2);
      expect(sys.earthing.mainBondingConductorMm2,
          earthing.mainBondingConductorMm2);
      // ... strictly larger than the no-capacitor (63 A) service.
      final plain = computeSystem(
          p,
          ElectricalProject(
              id: 'n', name: 'n', earthingSystem: EarthingSystem.tnCs,
              panels: [_p3('MDP', [motor])]));
      expect(plain.panels['MDP']!.incomer.breaker.ratingA.amperes, 63);
      expect(sys.earthing.mainEarthingConductorMm2,
          greaterThan(plain.earthing.mainEarthingConductorMm2));
    });
  });

  // ── 4. supply kVA at the real power factor ────────────────────────────────
  group('4 — supply kVA uses the real per-circuit cos φ', () {
    test('60 kW chiller at cos φ 0.72 + 16 kW lighting at 0.9', () {
      final sys = computeSystem(
          p,
          ElectricalProject(id: 'pf', name: 'pf', panels: [
            _p3('LVMDP', const [
              ElectricalCircuit(
                id: 'ch',
                name: 'Chiller',
                loadKind: LoadKind.hvac,
                loadW: 60000,
                cosPhi: 0.72,
                phases: 3,
                length: Length(20),
              ),
              ElectricalCircuit(
                id: 'lt',
                name: 'Lighting',
                loadKind: LoadKind.lighting,
                loadW: 16000,
                cosPhi: 0.9,
                phases: 3,
                length: Length(20),
              ),
            ]),
          ]));
      // VA = 60 000 / 0.72 + 16 000 / 0.9 = 83 333 + 17 778 = 101 111 VA
      // (was 76 000 / 0.85 = 89 412 VA — an undersized genset basis).
      final w = circuitConnectedW(const ElectricalCircuit(
              id: 'ch',
              name: 'c',
              loadKind: LoadKind.hvac,
              loadW: 60000,
              length: Length(1))) +
          16000;
      expect(sys.supply.demandW, closeTo(w, 1));
      expect(sys.supply.demandVa.voltAmperes,
          closeTo(60000 / 0.72 + 16000 / 0.9, 1));
      expect(sys.supply.demandVa.voltAmperes,
          greaterThan(76000 / assumedBuildingPf));
    });

    test('property: VA ≥ W and = Σ W/cos φ for random single-board loads', () {
      final rnd = math.Random(77);
      for (var t = 0; t < 40; t++) {
        final n = 1 + rnd.nextInt(5);
        final ways = [
          for (var i = 0; i < n; i++)
            ElectricalCircuit(
              id: 'w$i',
              name: 'w$i',
              loadKind: LoadKind.heating,
              loadW: 1000 + rnd.nextInt(20000).toDouble(),
              cosPhi: 0.6 + rnd.nextDouble() * 0.4,
              phases: 3,
              length: const Length(10),
            ),
        ];
        final sys = computeSystem(p,
            ElectricalProject(id: 'r', name: 'r', panels: [_p3('R', ways)]));
        final va = ways.fold(0.0, (s, c) => s + c.loadW / c.cosPhi);
        expect(sys.supply.demandVa.voltAmperes, closeTo(va, 1),
            reason: 'trial $t');
        expect(sys.supply.demandVa.voltAmperes,
            greaterThanOrEqualTo(sys.supply.demandW - 1),
            reason: 'trial $t');
      }
    });
  });

  // ── 5. metering CT on the sized current ────────────────────────────────────
  group('5 — the CT primary covers the incomer/busbar sizing current', () {
    test('197 kVA daya + 60 kW chiller: CT >= 284.3 A (not the demand)', () {
      final project = ElectricalProject(
        id: 'ct',
        name: 'ct',
        supplyCapacityVa: const ApparentPower(197000),
        panels: [
          _p3('LVMDP', const [
            ElectricalCircuit(
              id: 'ch',
              name: 'Chiller',
              loadKind: LoadKind.hvac,
              loadW: 60000,
              cosPhi: 0.72,
              phases: 3,
              length: Length(20),
            ),
          ]),
        ],
      );
      final sys = computeSystem(p, project);
      final r = sys.panels['LVMDP']!;
      // Service current 197 000 / (√3 · 400) = 284.3 A floors the bus.
      final service = 197000 / (math.sqrt(3) * 400);
      expect(r.busbar.totalCurrentA.amperes, closeTo(service, 0.06));
      expect(r.demandCurrent.amperes, lessThan(service));
      expect(r.meteringCurrent.amperes, closeTo(service, 0.06));
      final adv = computeAdvancedStudy(p, project, sys);
      expect(adv.metering['LVMDP']!.ctPrimaryA,
          greaterThanOrEqualTo(service - 0.06));
      // The schedule's CT label agrees: the next primary >= 284.3 is 300 A.
      final labels = buildElectricalSld(project: project, result: sys)
          .prims
          .whereType<SldLabel>()
          .map((l) => l.text)
          .where((t) => t.startsWith('CT '))
          .toList();
      expect(labels, contains(startsWith('CT 300/5A')));
    });
  });

  // ── 6. no fabricated capacitor bank ───────────────────────────────────────
  group('6 — a genset alone draws no capacitor bank', () {
    ElectricalProject proj({double? kvar}) => ElectricalProject(
          id: 'g',
          name: 'g',
          capacitorBankKvar: kvar,
          sources: const ElectricalSources(generator: GeneratorSource()),
          panels: [
            _p3('LVMDP', const [
              ElectricalCircuit(
                id: 'l',
                name: 'Load',
                loadKind: LoadKind.general,
                loadW: 20000,
                length: Length(10),
              ),
            ]),
          ],
        );

    String labels(SldSheet s) =>
        s.prims.whereType<SldLabel>().map((t) => t.text).join('\n');

    test('spine / overview / riser: bank only when kvar > 0', () {
      for (final kvar in [null, 0.0, 25000.0]) {
        final project = proj(kvar: kvar);
        final sys = computeSystem(p, project);
        final sheets = [
          buildElectricalSourceSpine(project: project, result: sys),
          buildElectricalSourceSpine(
              project: project, result: sys, horizontal: true),
          buildElectricalOverview(
              project: project, result: sys, sourceChain: true),
          buildElectricalRiser(project: project, result: sys, sourceChain: true),
        ];
        for (final s in sheets) {
          final t = labels(s);
          expect(t, contains('GENSET'), reason: 'kvar $kvar');
          final drawn = t.contains('CAPACITOR BANK') || t.contains('CAP ');
          expect(drawn, (kvar ?? 0) > 0, reason: 'kvar $kvar');
          expect(t, isNot(contains('PF correction')), reason: 'kvar $kvar');
        }
      }
    });
  });

  // ── 7. AC / FCU minted as HVAC ────────────────────────────────────────────
  group('7 — an AC / FCU unit is an HVAC final', () {
    test('hvacUnit mints LoadKind.hvac (curve C); pumps stay pump (curve D)',
        () {
      const ac = MepEquipmentLoad(
        id: 'ac1',
        name: 'Split AC',
        source: MepLoadSource.hvacUnit,
        mechanicalPower: Power(1500),
        phases: 1,
      );
      final c = equipmentToCircuit(ac,
          panelVoltage: const Voltage(400),
          panelSystem: ElectricalSystem.threePhase);
      expect(c.loadKind, LoadKind.hvac);
      expect(loadDefaults[c.loadKind]!.curve, BreakerCurve.c);
      expect(MepLoadSource.supplyPump.circuitLoadKind, LoadKind.pump);
      expect(MepLoadSource.supplyFan.circuitLoadKind, LoadKind.motor);
      final sys = computeSystem(
          p,
          ElectricalProject(id: 'a', name: 'a', panels: [
            _p3('MEP', [c]),
          ]));
      expect(_way(sys, 'MEP', 'mep-ac1').breaker.curve, BreakerCurve.c);
    });
  });
}
