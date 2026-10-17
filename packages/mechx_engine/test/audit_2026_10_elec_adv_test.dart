import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// Audit 2026-10, group E (electrical advanced studies). Every expectation is
/// hand-derived from first principles in the comments; impedances read the
/// engine's own conductor table (`PuilProfile.conductorResistanceOhmPerKm`,
/// 16 mm² Cu = 1.38 Ω/km, reactance 0.08 Ω/km) so the arithmetic is auditable.
void main() {
  const p = PuilProfile();

  // Source Z behind a 16 kA origin on the 400 V LV line basis:
  //   |Z| = 400/(√3·16000) = 0.01443376 Ω; X/R = 7 ⇒ R = |Z|/√50 = 0.00204124,
  //   X = 7R = 0.01428869.
  final zSrc = 400 / (math.sqrt(3) * 16000);
  final rSrc = zSrc / math.sqrt(50);
  final xSrc = 7 * rSrc;

  // ─────────────────────────────────────────────────────────────────────────
  // elec-advanced-1 — a 1-phase sub-board's fault is LINE-to-NEUTRAL on U0.
  // ─────────────────────────────────────────────────────────────────────────
  group('elec-advanced-1: 1-phase 220 V sub-board prospective fault', () {
    const sp = ElectricalPanel(
      id: 'SP',
      name: 'Sub 1ph',
      system: ElectricalSystem.singlePhase,
      voltage: Voltage(220),
      sourceType: PanelSource.feeder,
      fedByCircuitId: 'f1',
      circuits: [
        ElectricalCircuit(
            id: 's1',
            name: 'Heater A',
            loadKind: LoadKind.heating,
            loadW: 5000,
            cosPhi: 1,
            length: Length(10)),
        ElectricalCircuit(
            id: 's2',
            name: 'Heater B',
            loadKind: LoadKind.heating,
            loadW: 5000,
            cosPhi: 1,
            length: Length(10)),
      ],
    );
    const mdp = ElectricalPanel(
      id: 'MDP',
      name: 'Main',
      system: ElectricalSystem.threePhase,
      voltage: Voltage(400),
      circuits: [
        ElectricalCircuit(
            id: 'f1',
            name: 'Feeder',
            loadKind: LoadKind.feeder,
            cosPhi: 0.85,
            length: Length(2),
            feedsPanelId: 'SP'),
      ],
    );
    const project = ElectricalProject(
      id: 'pr',
      name: 'B',
      panels: [mdp, sp],
      earthingSystem: EarthingSystem.tnS,
    );
    final sys = computeSystem(p, project);
    final fs = faultStudy(sys, project, p); // origin 16 kA

    test('the feeder sizes to 16 mm² with a full-size neutral (fixture check)',
        () {
      final f = sys.panels['MDP']!.circuits.single;
      expect(f.cable.csaMm2, 16);
      expect(f.grounding.neutralCsaMm2, 16);
    });

    test('bus fault = U0/|Zsrc + Zphase + Zneutral| ≈ 13.37 kA', () {
      // Feeder 16 mm², 2 m: Rc = 1.38·2/1000 = 0.00276, Xc = 0.08·2/1000 =
      // 0.00016 — once for the phase leg, once for the neutral return.
      //   loop R = 0.00204124 + 2·0.00276 = 0.00756124
      //   loop X = 0.01428869 + 2·0.00016 = 0.01460869
      //   |Z| = √(0.00756124² + 0.01460869²) = 0.0164495 Ω
      //   I_LN = 220/0.0164495 = 13 374 A → 13.37 kA.
      // (The old code fed 220 V into the 3-phase formula:
      //  220/(√3·|0.00480+j0.01445|) = 8.34 kA — ~40 % low.)
      const rc = 1.38 * 2 / 1000, xc = 0.08 * 2 / 1000;
      final iLn = 220 /
          math.sqrt(math.pow(rSrc + 2 * rc, 2) + math.pow(xSrc + 2 * xc, 2));
      expect(iLn / 1000, closeTo(13.37, 0.01));
      expect(fs.panels['SP']!.prospectiveFaultkA, closeTo(iLn / 1000, 0.01));
      // It must not exceed the 3-phase fault at the same point:
      //   400/(√3·|0.00480124+j0.01444869|) = 400/(√3·0.0152255) = 15.17 kA.
      final i3 = 400 /
          (math.sqrt(3) *
              math.sqrt(math.pow(rSrc + rc, 2) + math.pow(xSrc + xc, 2)));
      expect(i3 / 1000, closeTo(15.17, 0.01));
      expect(fs.panels['SP']!.prospectiveFaultkA, lessThan(i3 / 1000));
    });

    test('the MCB is specified at 15 kA (the 10 kA rung no longer passes)', () {
      // MCB ladder [6, 10, 15, 25]: first rung ≥ 13.37 kA is 15 kA.
      expect(fs.panels['SP']!.incomerKa, 15);
      expect(fs.panels['SP']!.incomerAdequate, isTrue);
      expect(fs.circuits['s1']!.breakerKa, 15);
    });

    test('Fold-1 busbar withstand sees the same L-N fault', () {
      final sysW =
          computeSystem(p, project, originFaultLevel: const Current(16000));
      final w = sysW.panels['SP']!.busbar.withstand;
      expect(w, isNotNull);
      // Same derivation as above ⇒ 13.37 kA (was 8.34 kA on the 220 V basis).
      expect(w!.faultKa, closeTo(13.37, 0.01));
    });

    test('a 1-phase ROOT board refers its source Z to the 400 V line basis', () {
      const root = ElectricalPanel(
        id: 'R',
        name: 'House',
        system: ElectricalSystem.singlePhase,
        voltage: Voltage(220),
      );
      expect(faultBasisLineVoltageV(root), 400);
      // |Z| = 400/(√3·16000) = 0.014434 Ω (220 V would give 0.007939 Ω, a Zs
      // understated by ~6.5 mΩ — optimistic ADS).
      expect(
        sourceImpedanceFromIsc(16000, faultBasisLineVoltageV(root)).magnitude,
        closeTo(0.014434, 1e-6),
      );
      expect(faultBasisLineVoltageV(mdp), 400);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // elec-advanced-2 — the earth-fault loop returns through upstream feeder PEs.
  // ─────────────────────────────────────────────────────────────────────────
  group('elec-advanced-2: Zs includes every upstream feeder PE (hot)', () {
    test('sub-board way: loop = src + hot feeder phase + hot feeder PE + own',
        () {
      const sp = ElectricalPanel(
        id: 'SP',
        name: 'Sub',
        system: ElectricalSystem.threePhase,
        voltage: Voltage(400),
        sourceType: PanelSource.feeder,
        fedByCircuitId: 'f1',
        circuits: [
          ElectricalCircuit(
              id: 's1',
              name: 'Motor',
              loadKind: LoadKind.motor,
              motorKw: 30,
              cosPhi: 0.85,
              length: Length(10)),
        ],
      );
      const mdp = ElectricalPanel(
        id: 'MDP',
        name: 'Main',
        system: ElectricalSystem.threePhase,
        voltage: Voltage(400),
        circuits: [
          ElectricalCircuit(
              id: 'f1',
              name: 'Feeder to SP',
              loadKind: LoadKind.feeder,
              cosPhi: 0.85,
              length: Length(50),
              feedsPanelId: 'SP'),
          ElectricalCircuit(
              id: 'm1',
              name: 'Root motor',
              loadKind: LoadKind.motor,
              motorKw: 30,
              cosPhi: 0.85,
              length: Length(10)),
        ],
      );
      const project = ElectricalProject(
          id: 'pr',
          name: 'B',
          panels: [mdp, sp],
          earthingSystem: EarthingSystem.tnS);
      final sys = computeSystem(p, project);
      final fs = faultStudy(sys, project, p);
      final feeder =
          sys.panels['MDP']!.circuits.firstWhere((c) => c.circuitId == 'f1');
      final s1 = sys.panels['SP']!.circuits.single;
      final m1 =
          sys.panels['MDP']!.circuits.firstWhere((c) => c.circuitId == 'm1');
      // Fixture check: 16 mm² feeder with a 16 mm² PE; both motors on 16 mm².
      expect(feeder.cable.csaMm2, 16);
      expect(feeder.grounding.peCsaMm2, 16);
      expect(s1.cable.csaMm2, 16);
      expect(m1.cable.csaMm2, 16);
      expect(m1.grounding.peCsaMm2, 16);

      // Sub-board motor (the seed fixture's s1):
      //   feeder 50 m hot phase = hot PE = (0.069·1.28, 0.004) = (0.08832, 0.004)
      //   final 10 m hot phase = hot PE = (0.0138·1.28, 0.0008) = (0.017664, 0.0008)
      //   R = 0.00204124 + 2·0.08832 + 2·0.017664 = 0.21400924
      //   X = 0.01428869 + 2·0.004 + 2·0.0008 = 0.02388869
      //   Zs = 0.215339 Ω > Zs_max = 0.95·230/(20·63) = 0.17341 ⇒ ADS FAILS.
      final rS = rSrc + 2 * 0.069 * 1.28 + 2 * 0.0138 * 1.28;
      final xS = xSrc + 2 * 0.004 + 2 * 0.0008;
      expect(math.sqrt(rS * rS + xS * xS), closeTo(0.215339, 1e-5));
      expect(fs.circuits['s1']!.zsOhm, closeTo(0.215, 0.0005));
      expect(fs.circuits['s1']!.adsOk, isFalse);

      // ROOT-board motor — no upstream feeder, so its loop is UNCHANGED:
      //   R = 0.00204124 + 2·0.017664 = 0.03736924, X = 0.01428869 + 0.0016
      //     = 0.01588869; Zs = √(0.0013965 + 0.00025245) = 0.040607 Ω → 0.041.
      final rR = rSrc + 2 * 0.0138 * 1.28;
      final xR = xSrc + 2 * 0.0008;
      expect(math.sqrt(rR * rR + xR * xR), closeTo(0.040607, 1e-5));
      expect(fs.circuits['m1']!.zsOhm, closeTo(0.041, 0.0005));
      expect(fs.circuits['m1']!.adsOk, isTrue);
    });

    test('prospective-fault decay stays COLD (unchanged by the hot Zs legs)',
        () {
      // Isc_SP = 400/(√3·|(0.00204124+0.069) + j(0.01428869+0.004)|)
      //        = 400/(√3·0.0733576) = 3148.1 A → 3.15 kA (the seed value).
      const sp = ElectricalPanel(
        id: 'SP',
        name: 'Sub',
        system: ElectricalSystem.threePhase,
        voltage: Voltage(400),
        sourceType: PanelSource.feeder,
        fedByCircuitId: 'f1',
        circuits: [
          ElectricalCircuit(
              id: 's1',
              name: 'Motor',
              loadKind: LoadKind.motor,
              motorKw: 30,
              cosPhi: 0.85,
              length: Length(10)),
        ],
      );
      const mdp = ElectricalPanel(
        id: 'MDP',
        name: 'Main',
        system: ElectricalSystem.threePhase,
        voltage: Voltage(400),
        circuits: [
          ElectricalCircuit(
              id: 'f1',
              name: 'Feeder',
              loadKind: LoadKind.feeder,
              cosPhi: 0.85,
              length: Length(50),
              feedsPanelId: 'SP'),
        ],
      );
      const project = ElectricalProject(
          id: 'pr',
          name: 'B',
          panels: [mdp, sp],
          earthingSystem: EarthingSystem.tnS);
      final fs = faultStudy(computeSystem(p, project), project, p);
      expect(fs.panels['SP']!.prospectiveFaultkA, closeTo(3.15, 0.01));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // elec-advanced-4 — the specified Icu must also satisfy Ics.
  // ─────────────────────────────────────────────────────────────────────────
  group('elec-advanced-4: specified kA covers Ics as well as Icu', () {
    test('pure helper: MCCB at 16 kA ⇒ 25 kA (Ics 18.75 ≥ 16)', () {
      // Icu-only pick: 16 kA (Ics = 0.75·16 = 12 < 16 ⇒ unfit for service).
      expect(breakerKa(125, BreakerClass.mccb, 16), 16);
      // Next rung 25: Icu 25 ≥ 16 and Ics 0.75·25 = 18.75 ≥ 16 ⇒ 25 kA.
      expect(specifiedBreakerKa(125, BreakerClass.mccb, 16), 25);
      // 12 kA: rung 16 ⇒ Ics 12 ≥ 12 ⇒ 16 kA (the boundary holds).
      expect(specifiedBreakerKa(125, BreakerClass.mccb, 12), 16);
      // MCBs are Ics = Icu ⇒ identical to the Icu-only pick.
      expect(specifiedBreakerKa(40, BreakerClass.mcb, 8), 10);
      // Large frame floor (≥ 400 A ⇒ ≥ 36 kA) is honoured: 30 kA ⇒ 36 kA
      // gives Ics 27 < 30 ⇒ 50 kA (Ics 37.5 ≥ 30).
      expect(specifiedBreakerKa(400, BreakerClass.mccb, 30), 50);
      // Above every rung's Ics ⇒ the class maximum (70 kA, Ics 52.5).
      expect(specifiedBreakerKa(125, BreakerClass.mccb, 60), 70);
    });

    ElectricalProject feederProject() => const ElectricalProject(
          id: 'pr',
          name: 'B',
          earthingSystem: EarthingSystem.tnS,
          panels: [
            ElectricalPanel(
              id: 'MDP',
              name: 'Main',
              system: ElectricalSystem.threePhase,
              voltage: Voltage(400),
              circuits: [
                ElectricalCircuit(
                    id: 'f1',
                    name: 'Feeder',
                    loadKind: LoadKind.feeder,
                    cosPhi: 0.85,
                    length: Length(20),
                    feedsPanelId: 'SP'),
              ],
            ),
            ElectricalPanel(
              id: 'SP',
              name: 'Sub',
              system: ElectricalSystem.threePhase,
              voltage: Voltage(400),
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'f1',
              circuits: [
                ElectricalCircuit(
                    id: 's1',
                    name: 'Motor',
                    loadKind: LoadKind.motor,
                    motorKw: 30,
                    cosPhi: 0.85,
                    length: Length(10)),
              ],
            ),
          ],
        );

    test('MCCB feeder on a 16 kA root bus: 25 kA, Ics adequate, no warning',
        () {
      final project = feederProject();
      final sys = computeSystem(p, project);
      final fs = faultStudy(sys, project, p);
      final f = sys.panels['MDP']!.circuits.single;
      expect(f.breaker.deviceClass, BreakerClass.mccb);
      // Bus fault 16 kA ⇒ 25 kA rung (Ics 18.75 kA ≥ 16 kA).
      expect(fs.circuits['f1']!.breakerKa, 25);
      final pair = fs.selectivity.single;
      expect(pair.icuAdequate, isTrue);
      expect(pair.icsAdequate, isTrue);
      expect(fs.warnings.map((w) => w.code),
          isNot(contains('service-capacity-inadequate')));
    });

    test('above the ladder top Ics the warning still fires', () {
      // Origin 60 kA: top MCCB rung 70 kA ⇒ Ics 52.5 kA < 60 kA.
      final project = feederProject();
      final sys = computeSystem(p, project);
      final fs = faultStudy(sys, project, p,
          originFaultLevel: const Current(60000));
      expect(fs.circuits['f1']!.breakerKa, 70);
      expect(fs.selectivity.single.icsAdequate, isFalse);
      expect(fs.warnings.map((w) => w.code),
          contains('service-capacity-inadequate'));
    });
  });
}
