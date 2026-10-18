import 'dart:math' as math;

import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/catalog.dart' show PartCategory;
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/containment.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/electrode.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/power_factor.dart';
import 'package:mechx_engine/electrical/quotation.dart';
import 'package:mechx_engine/electrical/sources.dart';
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
            // Round-7 elec-props-2: the feeder now converts SP's 10 kW at SP's
            // REAL pf (two cos 1 heaters ⇒ 1.0): Ib = 10 000/220 = 45.5 A,
            // which alone sizes 10 mm². The fault arithmetic below is derived
            // on a 16 mm² feeder, so it is pinned with a manual cable minimum.
            cableOverrideMm2: 16,
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

    test('bus fault = U0/|Zsrc + Zphase + Zneutral| ≈ 13.70 kA', () {
      // Feeder 16 mm², 2 m. Round 17: the MAXIMUM fault takes conductor R at
      // 20 °C (IEC 60909-0) — the 70 °C table × (234.5 + 20)/(234.5 + 70) =
      // 254.5/304.5 = 0.835796: Rc = 1.38·2/1000·0.835796 = 0.00230690,
      // Xc = 0.08·2/1000 = 0.00016 — once for the phase leg, once for the
      // neutral return.
      //   loop R = 0.00204124 + 2·0.00230690 = 0.00665504
      //   loop X = 0.01428869 + 2·0.00016 = 0.01460869
      //   |Z| = √(0.00665504² + 0.01460869²) = 0.0160532 Ω
      //   I_LN = 220/0.0160532 = 13 704 A → 13.70 kA.
      // (The old code fed 220 V into the 3-phase formula:
      //  220/(√3·|0.00480+j0.01445|) = 8.34 kA — ~40 % low; the 70 °C R then
      //  still printed 13.37 kA — 2.4 % low.)
      const kc = 254.5 / 304.5;
      const rc = 1.38 * 2 / 1000 * kc, xc = 0.08 * 2 / 1000;
      final iLn = 220 /
          math.sqrt(math.pow(rSrc + 2 * rc, 2) + math.pow(xSrc + 2 * xc, 2));
      expect(iLn / 1000, closeTo(13.70, 0.01));
      expect(fs.panels['SP']!.prospectiveFaultkA, closeTo(iLn / 1000, 0.01));
      // It must not exceed the 3-phase fault at the same point:
      //   400/(√3·|0.00434814+j0.01444869|) = 400/(√3·0.0150888) = 15.31 kA.
      final i3 = 400 /
          (math.sqrt(3) *
              math.sqrt(math.pow(rSrc + rc, 2) + math.pow(xSrc + xc, 2)));
      expect(i3 / 1000, closeTo(15.31, 0.01));
      expect(fs.panels['SP']!.prospectiveFaultkA, lessThan(i3 / 1000));
    });

    test('the MCB is specified at 15 kA (the 10 kA rung no longer passes)', () {
      // MCB ladder [6, 10, 15, 25]: first rung ≥ 13.70 kA is 15 kA.
      expect(fs.panels['SP']!.incomerKa, 15);
      expect(fs.panels['SP']!.incomerAdequate, isTrue);
      expect(fs.circuits['s1']!.breakerKa, 15);
    });

    test('Fold-1 busbar withstand sees the same L-N fault', () {
      final sysW =
          computeSystem(p, project, originFaultLevel: const Current(16000));
      final w = sysW.panels['SP']!.busbar.withstand;
      expect(w, isNotNull);
      // Same derivation as above ⇒ 13.70 kA (was 8.34 kA on the 220 V basis).
      expect(w!.faultKa, closeTo(13.70, 0.01));
    });

    test('a 1-phase ROOT board refers its source Z to the 400 V line basis',
        () {
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
      // Fixture check (re-derived Round 11 — conduit PVC reads IEC B.52.4 B1):
      // every 57.9 A run needs Iz ≥ 1.25 × 57.89 = 72.36 A ⇒ 16 mm² (68 A) is
      // too small ⇒ 25 mm² (89 A), with a 16 mm² PE (16 < 25 ≤ 35).
      expect(feeder.cable.csaMm2, 25);
      expect(feeder.grounding.peCsaMm2, 16);
      expect(s1.cable.csaMm2, 25);
      expect(m1.cable.csaMm2, 25);
      expect(m1.grounding.peCsaMm2, 16);

      // Sub-board motor (the seed fixture's s1) — the loop carries the FEEDER's
      // phase AND its PE, every conductor hot (×1.28):
      //   feeder 25 mm² phase 50 m = (0.0435·1.28, 0.004) = (0.05568, 0.004)
      //   feeder 16 mm² PE    50 m = (0.069·1.28,  0.004) = (0.08832, 0.004)
      //   final  25 mm² phase 10 m = (0.0087·1.28, 0.0008) = (0.011136, 0.0008)
      //   final  16 mm² PE    10 m = (0.0138·1.28, 0.0008) = (0.017664, 0.0008)
      //   R = 0.00204124 + 0.05568 + 0.08832 + 0.011136 + 0.017664 = 0.17484124
      //   X = 0.01428869 + 2·0.004 + 2·0.0008 = 0.02388869
      //   Zs = 0.176466 Ω ≤ Zs_max(5 s, a 63 A final > 32 A) = 0.95·230/(10·63)
      //      = 0.34683 Ω ⇒ ADS passes (Round 11: the 5 s D-curve multiple).
      final rS = rSrc + (0.0435 + 0.069 + 0.0087 + 0.0138) * 1.28;
      final xS = xSrc + 2 * 0.004 + 2 * 0.0008;
      expect(math.sqrt(rS * rS + xS * xS), closeTo(0.176466, 1e-5));
      expect(fs.circuits['s1']!.zsOhm, 0.176); // floor(176.466) / 1000
      expect(fs.circuits['s1']!.adsOk, isTrue);

      // ROOT-board motor — no upstream feeder, so no feeder legs:
      //   R = 0.00204124 + 0.011136 + 0.017664 = 0.03084124,
      //   X = 0.01428869 + 0.0016 = 0.01588869; Zs = 0.034693 Ω → 0.034
      //   (Round 20: a PASS stores Zs rounded DOWN, floor(34.693) / 1000).
      final rR = rSrc + (0.0087 + 0.0138) * 1.28;
      final xR = xSrc + 2 * 0.0008;
      expect(math.sqrt(rR * rR + xR * xR), closeTo(0.034693, 1e-5));
      expect(fs.circuits['m1']!.zsOhm, 0.034);
      expect(fs.circuits['m1']!.adsOk, isTrue);
    });

    test('prospective-fault decay stays COLD (unchanged by the hot Zs legs)',
        () {
      // Re-derived Round 11 — the load-sized feeder is 25 mm² (R 0.87 Ω/km);
      // Round 17 — the maximum fault takes R at 20 °C: 0.0435·0.835796 =
      // 0.0363571 Ω:
      // Isc_SP = 400/(√3·|(0.00204124+0.0363571) + j(0.01428869+0.004)|)
      //        = 400/(√3·0.0425328) = 5429.6 A → 5.43 kA (the cold basis —
      //        the ×1.28 hot factor never enters the prospective fault).
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
      expect(fs.panels['SP']!.prospectiveFaultkA, closeTo(5.43, 0.01));
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
      final fs =
          faultStudy(sys, project, p, originFaultLevel: const Current(60000));
      expect(fs.circuits['f1']!.breakerKa, 70);
      expect(fs.selectivity.single.icsAdequate, isFalse);
      expect(fs.warnings.map((w) => w.code),
          contains('service-capacity-inadequate'));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // elec-advanced-3 — cable labour is per RUN, not per metre.
  // ─────────────────────────────────────────────────────────────────────────
  group('elec-advanced-3: cable labour per run', () {
    const project = ElectricalProject(
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
                id: 'c1',
                name: 'Heater',
                loadKind: LoadKind.heating,
                loadW: 3000,
                cosPhi: 1,
                length: Length(50)),
          ],
        ),
      ],
    );
    final bom = buildBom(computeSystem(p, project));

    test('one 50 m run books 0.2 h (one run), not 50 × 0.2 = 10 h', () {
      final cable =
          bom.lines.where((l) => l.category == PartCategory.cable).toList();
      expect(cable, hasLength(1));
      expect(cable.single.qty, 50); // metres — what is bought
      expect(cable.single.runs, 1);
      // assemblyHoursPerUnit[cable] = 0.2 h per run × 1 run = 0.2 h.
      expect(labourHoursForBom(Bom(cable)), closeTo(0.2, 1e-9));
    });

    test('non-cable lines keep hours × qty; the total adds 0.2 h of cable', () {
      // Σ over every non-cable line of hours(category)·qty, + 0.2 h of cable.
      final nonCable = bom.lines
          .where((l) => l.category != PartCategory.cable)
          .fold<double>(
              0, (s, l) => s + assemblyHoursForCategory(l.category) * l.qty);
      expect(labourHoursForBom(bom), closeTo(nonCable + 0.2, 1e-9));
      // The probe's old total was 17.6 h, 10 h of it cable ⇒ now 7.8 h.
      expect(labourHoursForBom(bom), closeTo(7.8, 1e-9));
    });

    test('consolidated cable lines sum their runs', () {
      const two = ElectricalProject(
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
                  id: 'c1',
                  name: 'Heater A',
                  loadKind: LoadKind.heating,
                  loadW: 3000,
                  cosPhi: 1,
                  length: Length(50)),
              ElectricalCircuit(
                  id: 'c2',
                  name: 'Heater B',
                  loadKind: LoadKind.heating,
                  loadW: 3000,
                  cosPhi: 1,
                  length: Length(30)),
            ],
          ),
        ],
      );
      final cable = buildBom(computeSystem(p, two))
          .lines
          .where((l) => l.category == PartCategory.cable)
          .toList();
      // Same cable on both ways ⇒ one merged line: 50 + 30 = 80 m, 2 runs,
      // 2 × 0.2 = 0.4 h.
      expect(cable, hasLength(1));
      expect(cable.single.qty, 80);
      expect(cable.single.runs, 2);
      expect(labourHoursForBom(Bom(cable)), closeTo(0.4, 1e-9));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // elec-advanced-7 — parallel-run feeders are taken off at N × the length.
  // ─────────────────────────────────────────────────────────────────────────
  group('elec-advanced-7: parallel-run cable take-off + tray fill', () {
    const project = ElectricalProject(
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
                cosPhi: 1,
                length: Length(40),
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
                name: 'Load',
                loadKind: LoadKind.heating,
                loadW: 400000,
                cosPhi: 1,
                length: Length(10)),
          ],
        ),
      ],
    );
    final sys = computeSystem(p, project);
    final mdp = sys.panels['MDP']!;
    final feeder = mdp.circuits.single;

    test('fixture: the 400 kW feeder sizes as 3 parallel runs of 240 mm²', () {
      expect(feeder.cable.runsPerPhase, 3);
      // Ib = 400 kW / (√3·400·1) = 577.4 A → the load-sized device is the
      // 630 A rung, so Iz_req = max(630, 1.25 × 577.4 = 721.7) = 721.7 A.
      // Parallel runs laid together are group-derated (elec-core-3).
      // Re-derived Round 11 — conduit PVC reads IEC B.52.4 B1 (240 mm² = 346 A,
      // 300 mm² = 394 A): two runs top out at 2 × 394 × 0.8 = 630 A < 721.7;
      // three runs at gf(3) = 0.7 need a table Iz ≥ 721.7 / 3 / 0.7 = 343.7 A
      // → 240 mm² (346 A) ⇒ 3 × 346 × 0.7 = 726.6 A ≥ 721.7.
      expect(feeder.cable.csaMm2, 240);
      expect(feeder.grounding.cableSpec, startsWith('3× '));
    });

    test('BOM: 3 runs × 40 m = 120 m of the SINGLE cable; lugs on every run',
        () {
      final lines = buildPanelBom(mdp);
      final cable = lines.where((l) => l.category == PartCategory.cable).single;
      // 40 m run × 3 parallel runs = 120 m to buy (was 40 m).
      expect(cable.qty, 120);
      expect(cable.runs, 3);
      // The description names the single cable, so 120 m reads unambiguously.
      expect(cable.description, isNot(contains('3×')));
      expect(cable.description, contains('4×240'));
      // Skun: 5 conductors (3L+N+PE) × 2 ends × 3 runs = 30 lugs — Round 19
      // split by section: the PE of a 240 mm² phase is 120 mm² (S/2), so
      // 4 × 2 × 3 = 24 lugs at 240 mm² and 1 × 2 × 3 = 6 at 120 mm².
      final lugs = lines.where((l) => l.description.contains('skun')).toList();
      expect(feeder.grounding.peCsaMm2, 120);
      expect(lugs.singleWhere((l) => l.description.contains('240 mm²')).qty,
          24);
      expect(lugs.singleWhere((l) => l.description.contains('120 mm²')).qty,
          6);
      expect(lugs.fold<double>(0, (a, l) => a + l.qty), 30);
    });

    test('tray fill counts one cable per parallel run', () {
      final tray = sizeCableTray(mdp);
      expect(tray.cableCount, 3);
      // Width = 3·OD × packing factor (one OD per run).
      final od =
          cableOuterDiameterMm(feeder.cable.csaMm2, feeder.grounding.cores);
      final required = 3 * od * trayPackingFactor;
      expect(tray.fillPct, closeTo(required / tray.widthMm * 100, 0.06));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // elec-advanced-9 — the capacitor bank cancels the motor's INPUT kvar.
  // ─────────────────────────────────────────────────────────────────────────
  group('elec-advanced-9: PF correction on motor input power', () {
    test('22 kW cos 0.8 motor ⇒ 25 kW input, 10.53 kvar ⇒ the 25 kVAR rung',
        () {
      const project = ElectricalProject(
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
                  id: 'm1',
                  name: 'Motor',
                  loadKind: LoadKind.motor,
                  motorKw: 22,
                  cosPhi: 0.8,
                  length: Length(10)),
            ],
          ),
        ],
      );
      final pf = powerFactorCorrection(computeSystem(p, project), project);
      // Input = 22/0.88 = 25.0 kW (the same basis compute.dart's Ib uses).
      expect(kAssumedMotorEfficiency, 0.88);
      expect(pf.totalKw, closeTo(25.0, 0.05));
      // kvar = 25·tan(acos 0.8) = 25·0.75 = 18.75.
      // (reported to 1 dp: 18.7499… → 18.7)
      expect(pf.totalKvar, closeTo(18.75, 0.06));
      // required = 25·(0.75 − tan(acos 0.95)) = 25·(0.75 − 0.328684)
      //          = 25·0.421316 = 10.533 kvar (30 °C ⇒ no ambient oversize).
      expect(pf.requiredKvar, closeTo(10.5, 0.05));
      // Ladder [10, 25, …]: 10.53 > 10 ⇒ 25 kVAR (the shaft basis picked 10).
      expect(pf.bankKvar, 25);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // elec-advanced-5 — the electrode rod count is the true minimum.
  // ─────────────────────────────────────────────────────────────────────────
  group('elec-advanced-5: minimum rod count with each count\'s own η', () {
    test('100 Ω·m ⇒ 11 rods at 4.993 Ω (BS 7430, Round 17)', () {
      // R1 = 100/(2π·3)·(ln(24/0.016) − 1) = 5.30516·6.31322 = 33.4927 Ω.
      // α = 1/6.31322 = 0.158398 (s = L). n = 10: 33.4927·1.60350/10 = 5.371
      // > 5; n = 11: λ 4.03975 ⇒ 33.4927·1.63989/11 = 4.9931 ≤ 5.
      final d = designElectrode(soilResistivityOhmM: 100);
      expect(d.rodCount, 11);
      expect(d.achieved.ohms, closeTo(4.993, 0.001));
      expect(d.meetsTarget, isTrue);
    });

    test('25 Ω·m ⇒ 2 rods (the fixed-η estimate over-counted to 3)', () {
      // R1 = 25/(2π·3)·6.31322 = 1.32629·6.31322 = 8.3732 Ω.
      // Fixed η: ceil(8.3732/(5·0.8)) = ceil(2.093) = 3.
      // True minimum: n = 1: 8.37 > 5; n = 2: 8.3732·(1 + 0.158398)/2 = 4.8497.
      final d = designElectrode(soilResistivityOhmM: 25);
      expect(d.singleRod.ohms, closeTo(8.373, 0.001));
      expect(d.rodCount, 2);
      expect(d.achieved.ohms, closeTo(4.850, 0.001));
      expect(d.meetsTarget, isTrue);
    });

    test('500 Ω·m ⇒ 75 rods meet it (BS 7430 coupling, Round 17)', () {
      // R1 = 5·33.4927 = 167.463 Ω. λ(75) = (2/75)(75·H74 − 74)
      //   = (2/75)(75·4.888029 − 74) = 7.80029 ⇒ 1 + 7.80029·0.158398 = 2.23555
      //   ⇒ 167.463·2.23555/75 = 4.9917…≈4.992 Ω ≤ 5 (n = 74 just misses).
      final d = designElectrode(soilResistivityOhmM: 500);
      expect(d.rodCount, 75);
      expect(d.achieved.ohms, closeTo(4.992, 0.002));
      expect(d.meetsTarget, isTrue);
    });

    test('beyond the search cap ⇒ the cap, flagged unmet', () {
      // 2000 Ω·m: R1 = 669.85 Ω; even n = 100 gives 669.85·(1 + λ(100)·α)/100
      // ≈ 15.6 Ω > 5 ⇒ the cap.
      final d = designElectrode(soilResistivityOhmM: 2000);
      expect(d.rodCount, maxElectrodeRods);
      expect(d.meetsTarget, isFalse);
      expect(d.note, contains('above 5 ohm target'));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // elec-advanced-6 — PV modules are split evenly, never padded.
  // ─────────────────────────────────────────────────────────────────────────
  group('elec-advanced-6: physical PV string layout', () {
    // maxByMppt = floor(850/41.7) = 20; maxByVoltage = floor(1000/56.925) = 17;
    // minByMppt = ceil(200/41.7) = 5; max string length = min(20, 17) = 17.
    test('18 × 550 Wp ⇒ 2 strings of 9 (375 V, inside 200–850 V)', () {
      // strings = ceil(18/17) = 2; stringSize = ceil(18/2) = 9.
      final s = sizeSolar(panelWp: 550, panels: 18);
      expect(s.strings, 2);
      expect(s.stringSize, 9);
      expect(s.strings * s.stringSize, 18);
      expect(s.note, contains('2 string(s) of 9;'));
      expect(s.note, isNot(contains('MPPT window')));
    });

    test('19 modules ⇒ 2 strings of 9-10 (an honest uneven split)', () {
      final s = sizeSolar(panelWp: 550, panels: 19);
      expect(s.strings, 2);
      expect(s.stringSize, 10);
      expect(s.note, contains('2 string(s) of 9-10;'));
    });

    test('3 modules ⇒ 1 string of 3, flagged below the MPPT window', () {
      // 3 × 41.7 = 125.1 V → 125 V < 200 V MPPT minimum.
      final s = sizeSolar(panelWp: 550, panels: 3);
      expect(s.strings, 1);
      expect(s.stringSize, 3);
      expect(s.note, contains('1 string(s) of 3;'));
      expect(s.note, contains('~125 V Vmp, below the 200 V MPPT minimum'));
    });
  });
}
