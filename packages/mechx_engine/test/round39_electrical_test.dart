// Round 39 (2026-10-18) — electrical regressions + report / drawing parity.
//
// Each group pins one confirmed finding with a first-principles derivation;
// where a counterexample generalises, it is a seeded property.
import 'dart:convert';
import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_bom.dart';
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/catalog.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/containment.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/power_factor.dart';
import 'package:mechx_engine/electrical/results.dart';
import 'package:mechx_engine/electrical/supply_design.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/electrical_plan_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

ElectricalCircuitResult _way(ElectricalSystemResult s, String panel, String c) =>
    s.panels[panel]!.circuits.firstWhere((r) => r.circuitId == c);

List<String> _labels(SldSheet s) =>
    [for (final p in s.prims) if (p is SldLabel) p.text];

void main() {
  // ── 1. the incomer carries the largest final way's running current ───────
  group('regression-outgoing-exceeds-incomer', () {
    // One HVAC way 10 kW at cos phi 0.85, df 0.9 (the palette default):
    //   run current = 10000 / (sqrt(3) * 400 * 0.85) = 16.98 A -> 20 A way;
    //   diversified worst line = 0.9 * 16.98 = 15.3 A -> was a 16 A incomer.
    // One machine does not diversify against itself: the incomer floors at
    // the 17.0 A running current -> 20 A, and nothing warns.
    const project = ElectricalProject(id: 'p', name: 'P', panels: [
      ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
        ElectricalCircuit(
          id: 'ac',
          name: 'AC',
          loadKind: LoadKind.hvac,
          loadW: 10000,
          cosPhi: 0.85,
          phases: 3,
          demandFactor: 0.9,
          length: const Length(10),
        ),
      ]),
    ]);
    final sys = computeSystem(_p, project);
    final run = 10000 / (math.sqrt(3) * 400 * 0.85);

    test('way 20 A on 17.0 A; incomer 20 A (not 16 A)', () {
      expect(_way(sys, 'MDP', 'ac').runCurrentA.amperes,
          closeTo(run, 0.05));
      expect(_way(sys, 'MDP', 'ac').breaker.ratingA.amperes, 20);
      expect(sys.panels['MDP']!.incomer.breaker.ratingA.amperes, 20);
    });

    test('no warning-severity outgoing-exceeds-incomer', () {
      expect(
          sys.warnings.where((w) =>
              w.code == 'outgoing-exceeds-incomer' &&
              w.severity == WarningSeverity.warning),
          isEmpty);
    });

    test('an override-caused inversion stays a WARNING', () {
      const o = ElectricalProject(id: 'p', name: 'P', panels: [
        ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
          ElectricalCircuit(
            id: 'ac',
            name: 'AC',
            loadKind: LoadKind.hvac,
            loadW: 10000,
            cosPhi: 0.85,
            phases: 3,
            length: const Length(10),
            breakerOverrideA: const Current(63),
          ),
        ]),
      ]);
      final s = computeSystem(_p, o);
      expect(
          s.warnings.where((w) =>
              w.code == 'outgoing-exceeds-incomer' &&
              w.severity == WarningSeverity.warning),
          hasLength(1));
    });

    test('seeded property: override-free boards never warn, incomer >= every '
        'final way running current', () {
      final rng = math.Random(39);
      const kinds = [
        LoadKind.hvac,
        LoadKind.heating,
        LoadKind.general,
        LoadKind.lighting,
        LoadKind.socket,
      ];
      for (var t = 0; t < 300; t++) {
        final n = 1 + rng.nextInt(4);
        final circuits = [
          for (var i = 0; i < n; i++)
            ElectricalCircuit(
              id: 'c$i',
              name: 'c$i',
              loadKind: kinds[rng.nextInt(kinds.length)],
              loadW: 500 + rng.nextDouble() * 30000,
              cosPhi: 0.8 + rng.nextDouble() * 0.2,
              demandFactor: 0.3 + rng.nextDouble() * 0.7,
              phases: rng.nextBool() ? 3 : 1,
              length: Length(5 + rng.nextDouble() * 40),
            ),
        ];
        final s = computeSystem(
            _p,
            ElectricalProject(id: 'p', name: 'P', panels: [
              ElectricalPanel(id: 'B', name: 'B', circuits: circuits),
            ]));
        final b = s.panels['B']!;
        for (final c in b.circuits) {
          expect(b.incomer.breaker.ratingA.amperes + 0.05,
              greaterThanOrEqualTo(c.runCurrentA.amperes),
              reason: 'trial $t way ${c.circuitId}');
        }
        expect(
            s.warnings.where((w) =>
                w.code == 'outgoing-exceeds-incomer' &&
                w.severity == WarningSeverity.warning),
            isEmpty,
            reason: 'trial $t');
      }
    });
  });

  // ── 2. a permuting prior never relabels a fed board (r2: adopts judged) ──
  group('regression-history-free-feeder-lines-contradict-labelled-subboard',
      () {
    ElectricalCircuit heater(String id, double a) => ElectricalCircuit(
          id: id,
          name: id,
          loadKind: LoadKind.heating,
          // 1ph at 231 V, cos 1: W = I * 231.
          loadW: a * 231,
          cosPhi: 1.0,
          phases: 1,
          length: const Length(5),
        );
    final project = ElectricalProject(id: 'p', name: 'P', panels: [
      ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
        const ElectricalCircuit(
          id: 'f',
          name: 'to DB',
          loadKind: LoadKind.feeder,
          feedsPanelId: 'DB',
          length: Length(10),
        ),
        heater('d', 10),
      ]),
      ElectricalPanel(
          id: 'DB',
          name: 'DB',
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'f',
          circuits: [heater('a', 30), heater('b', 20), heater('c', 20)]),
    ]);
    // The live store's stickiness prior: a on L2, b on L1, c on L3 — a pure
    // relabelling of the engine's own assignment (a relabel never saves 1 A).
    final sys = computeSystem(_p, project,
        priorAssignments: const {
          'DB': {
            'a': PhaseAssignment.l2,
            'b': PhaseAssignment.l1,
            'c': PhaseAssignment.l3,
          },
        },
        phaseReassignThresholdA: 1.0);

    test('(r2) a parent of ONE fed board: the DB keeps its sticky labels', () {
      // Stickiness is refused only under a parent feeding >= 2 boards.
      final a = _way(sys, 'DB', 'a');
      expect(a.phase, PhaseAssignment.l2);
    });

    test('the MDP feeder row prints the DB schedule\'s labelled R/S/T', () {
      final db = sys.panels['DB']!.phaseBalance;
      final row = _way(sys, 'MDP', 'f').lineCurrentsA!;
      expect(row[0], closeTo(db.l1, 1e-6));
      expect(row[1], closeTo(db.l2, 1e-6));
      expect(row[2], closeTo(db.l3, 1e-6));
    });

    test('the wired worst MDP line fits under the printed incomer', () {
      // DB labels a (30 A) on S -> the MDP balancer must put d (10 A) on
      // R or T, so the MDP worst line is 30 A (never 30 + 10 = 40 A on S).
      final m = sys.panels['MDP']!;
      final worst = [m.phaseBalance.l1, m.phaseBalance.l2, m.phaseBalance.l3]
          .reduce(math.max);
      expect(worst, closeTo(30, 0.2));
      expect(m.incomer.breaker.ratingA.amperes, greaterThanOrEqualTo(worst));
    });
  });

  // ── 2b. (r2) two fed boards: the parent never depends on the labels ─────
  group('regression-history-free-feeder-lines (two fed boards, r3)', () {
    ElectricalCircuit heater(String id, double a) => ElectricalCircuit(
          id: id,
          name: id,
          loadKind: LoadKind.heating,
          loadW: a * 231,
          cosPhi: 1.0,
          phases: 1,
          length: const Length(5),
        );
    ElectricalPanel board(String id, String feeder) => ElectricalPanel(
            id: id,
            name: id,
            sourceType: PanelSource.feeder,
            fedByCircuitId: feeder,
            circuits: [
              heater('${id}30', 30),
              heater('${id}20', 20),
              heater('${id}10', 10),
            ]);
    // MDP feeds A and B, each 30 / 20 / 10 A 1ph heaters. The engine puts
    // the 30 A way of each board on the same line, so the MDP worst line is
    // 30 + 30 = 60 A -> a 63 A incomer. A session prior that ROTATES B's
    // labels by one line (a pure relabelling) used to hand the MDP
    // 30+10 / 20+30 / 10+20 = 40 / 50 / 30 A -> a 50 A incomer live and a
    // 63 A one after reopen on the same document.
    final project = ElectricalProject(id: 'p', name: 'P', panels: [
      const ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
        ElectricalCircuit(
            id: 'fA',
            name: 'to A',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'A',
            length: Length(10)),
        ElectricalCircuit(
            id: 'fB',
            name: 'to B',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'B',
            length: Length(10)),
      ]),
      board('A', 'fA'),
      board('B', 'fB'),
    ]);
    PhaseLine rot(PhaseAssignment a) => switch (a) {
          PhaseAssignment.l1 => PhaseLine.l2,
          PhaseAssignment.l2 => PhaseLine.l3,
          _ => PhaseLine.l1,
        };
    final reopened = computeSystem(_p, project);
    final engineB = {
      for (final c in reopened.panels['B']!.circuits) c.circuitId: c.phase,
    };
    // Round 39 r3 — the document now CARRIES B's rotated labels (the
    // persisted `assignedPhase` the live store wrote), so the rotation is
    // part of the document, never session memory.
    final rotated = project.withPanels([
      for (final p in project.panels)
        p.id != 'B'
            ? p
            : p.copyWith(circuits: [
                for (final c in p.circuits)
                  c.copyWith(assignedPhase: rot(engineB[c.id]!)),
              ]),
    ]);
    final doc = computeSystem(_p, rotated, phaseReassignThresholdA: 1.0);
    double worst(PhaseBalanceResult b) => [b.l1, b.l2, b.l3].reduce(math.max);

    test('no persisted assignment: MDP worst line 60 A, 63 A incomer', () {
      final m = reopened.panels['MDP']!;
      expect(worst(m.phaseBalance), closeTo(60, 0.2));
      expect(m.incomer.breaker.ratingA.amperes, 63);
    });

    test('(r3) the persisted labels: B prints them, the MDP sums them', () {
      // B keeps its rotated labels (same worst line, a relabel never saves
      // 1 A): 30 on L2, 20 on L3, 10 on L1. A (engine LPT): 30 L1, 20 L2,
      // 10 L3. MDP: L1 30 + 10 = 40, L2 20 + 30 = 50, L3 10 + 20 = 30 A.
      final b = doc.panels['B']!;
      for (final c in b.circuits) {
        expect(c.phase.name, rot(engineB[c.circuitId]!).name,
            reason: c.circuitId);
      }
      final row = _way(doc, 'MDP', 'fB').lineCurrentsA!;
      expect(row[0], closeTo(b.phaseBalance.l1, 1e-6));
      expect(row[1], closeTo(b.phaseBalance.l2, 1e-6));
      expect(row[2], closeTo(b.phaseBalance.l3, 1e-6));
      final m = doc.panels['MDP']!;
      expect(m.phaseBalance.l1, closeTo(40, 0.2));
      expect(m.phaseBalance.l2, closeTo(50, 0.2));
      expect(m.phaseBalance.l3, closeTo(30, 0.2));
      expect(m.incomer.breaker.ratingA.amperes,
          greaterThanOrEqualTo(worst(m.phaseBalance)));
    });

    test('(r3) the document alone decides: JSON round-trip == live', () {
      final back = ElectricalProject.fromJson(
          jsonDecode(jsonEncode(rotated.toJson())) as Map<String, dynamic>);
      final again = computeSystem(_p, back, phaseReassignThresholdA: 1.0);
      for (final id in ['MDP', 'A', 'B']) {
        final x = doc.panels[id]!, y = again.panels[id]!;
        expect(y.phaseBalance.l1, x.phaseBalance.l1, reason: id);
        expect(y.phaseBalance.l2, x.phaseBalance.l2, reason: id);
        expect(y.phaseBalance.l3, x.phaseBalance.l3, reason: id);
        expect(y.incomer.breaker.ratingA.amperes,
            x.incomer.breaker.ratingA.amperes, reason: id);
      }
      // ...and the persisted field IS the prior (== an explicit prior map).
      final viaParam = computeSystem(_p, project,
          priorAssignments: {
            'B': {
              for (final e in engineB.entries)
                e.key: PhaseAssignment.values.byName(rot(e.value).name),
            },
          },
          phaseReassignThresholdA: 1.0);
      expect(viaParam.panels['MDP']!.phaseBalance.l2,
          doc.panels['MDP']!.phaseBalance.l2);
    });

    test('a NON-permuting sticky result keeps its labels', () {
      // One board, 30 / 20 / 10 / 5 A. Unseeded LPT: 30 R, 20 S, 10 + 5 T
      // = 30 / 20 / 15 A. The prior holds the 5 A way on S: 30 / 25 / 10 A —
      // the SAME worst line (30 A, so Round 37 keeps it) but NOT a
      // permutation of 30 / 20 / 15, and a 100 A threshold forbids the move
      // -> the sticky labels stand (stickiness is only refused for a pure
      // relabelling).
      final one = ElectricalProject(id: 'q', name: 'Q', panels: [
        ElectricalPanel(id: 'X', name: 'X', circuits: [
          heater('x30', 30),
          heater('x20', 20),
          heater('x10', 10),
          heater('x5', 5),
        ]),
      ]);
      final sticky = computeSystem(_p, one,
          priorAssignments: const {
            'X': {
              'x30': PhaseAssignment.l1,
              'x20': PhaseAssignment.l2,
              'x10': PhaseAssignment.l3,
              'x5': PhaseAssignment.l2,
            },
          },
          phaseReassignThresholdA: 100.0);
      final x = sticky.panels['X']!;
      expect(x.circuits.firstWhere((c) => c.circuitId == 'x5').phase,
          PhaseAssignment.l2);
      expect(x.phaseBalance.l2, closeTo(25, 0.2));
    });
  });

  // ── 3. the LV verdict and the daya recommendation share one basis ────────
  group('regression-lv-supply-verdict-without-any-lv-daya', () {
    test('150 kW 3ph + 30 kW 1ph: worst phase 240 kVA > 197 kVA => MV', () {
      // Worst phase: 150000 / (sqrt3*400) + 30000 / 231 = 216.5 + 129.9 =
      // 346.4 A -> sqrt3*400*346.4 = 240 kVA > the 197 kVA LV ceiling.
      const project = ElectricalProject(id: 'p', name: 'P', panels: [
        ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
          ElectricalCircuit(
              id: 'h3',
              name: 'h3',
              loadKind: LoadKind.heating,
              loadW: 150000,
              cosPhi: 1,
              phases: 3,
              length: const Length(5)),
          ElectricalCircuit(
              id: 'h1',
              name: 'h1',
              loadKind: LoadKind.heating,
              loadW: 30000,
              cosPhi: 1,
              phases: 1,
              length: const Length(5)),
        ]),
      ]);
      final sys = computeSystem(_p, project);
      final adv = computeAdvancedStudy(_p, project, sys);
      expect(adv.recommendedDayaVa, isNull);
      expect(adv.supply.lvOrMv, SupplyLevel.mv);
    });

    test('seeded property: lv <=> recommendedDaya != null', () {
      final rng = math.Random(3939);
      for (var t = 0; t < 200; t++) {
        final circuits = [
          for (var i = 0; i < 1 + rng.nextInt(4); i++)
            ElectricalCircuit(
              id: 'c$i',
              name: 'c$i',
              loadKind: LoadKind.heating,
              loadW: 1000 + rng.nextDouble() * 120000,
              cosPhi: 1,
              phases: rng.nextBool() ? 3 : 1,
              length: const Length(5),
            ),
        ];
        final project = ElectricalProject(id: 'p', name: 'P', panels: [
          ElectricalPanel(id: 'MDP', name: 'MDP', circuits: circuits),
        ]);
        final sys = computeSystem(_p, project);
        final adv = computeAdvancedStudy(_p, project, sys);
        expect(adv.supply.lvOrMv == SupplyLevel.lv,
            adv.recommendedDayaVa != null,
            reason: 'trial $t: ${adv.supply.note}');
      }
    });

    test('seeded property (r2): a 1ph ROOT board — lv <=> daya != null', () {
      // The single-phase branch of the per-phase basis: a 1ph root loads ONE
      // phase of whatever service it gets, judged at sqrt3*400*I. Loads span
      // the 1ph ladder, the 3ph LV steps and past the 197 kVA LV ceiling
      // (up to 4 x 40 kW = 160 kW 1ph at 231 V = 693 A -> sqrt3*400*693 =
      // 480 kVA per-phase basis => MV).
      final rng = math.Random(39392);
      var sawLv = 0, sawMv = 0;
      for (var t = 0; t < 200; t++) {
        final circuits = [
          for (var i = 0; i < 1 + rng.nextInt(4); i++)
            ElectricalCircuit(
              id: 'c$i',
              name: 'c$i',
              loadKind: LoadKind.heating,
              loadW: 200 + rng.nextDouble() * 40000,
              cosPhi: 1,
              phases: 1,
              length: const Length(5),
            ),
        ];
        final project = ElectricalProject(id: 'p', name: 'P', panels: [
          ElectricalPanel(
              id: 'MDB',
              name: 'MDB',
              system: ElectricalSystem.singlePhase,
              circuits: circuits),
        ]);
        final sys = computeSystem(_p, project);
        expect(sys.supply.system, ElectricalSystem.singlePhase,
            reason: 'trial $t exercises the 1ph branch');
        final adv = computeAdvancedStudy(_p, project, sys);
        final lv = adv.supply.lvOrMv == SupplyLevel.lv;
        lv ? sawLv++ : sawMv++;
        expect(lv, adv.recommendedDayaVa != null,
            reason: 'trial $t: ${adv.supply.note}');
      }
      expect(sawLv, greaterThan(0));
      expect(sawMv, greaterThan(0));
    });
  });

  // ── 4. no MCCB below its 16 A frame ──────────────────────────────────────
  group('regression-fault-aware-class-mints-nonexistent-small-mccb', () {
    test('a 6 A way on a 36 kA bus becomes an MCCB 16 A, never MCCB 6 A', () {
      // transformerKva 1000 -> 1e6 / (sqrt3*400*0.04) = 36 084 A origin.
      const project = ElectricalProject(
        id: 'p',
        name: 'P',
        transformerKva: const ApparentPower(1000000),
        panels: [
          ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
            ElectricalCircuit(
                id: 'l',
                name: 'Lights',
                loadKind: LoadKind.lighting,
                loadW: 300,
                cosPhi: 0.9,
                phases: 1,
                length: const Length(10)),
          ]),
        ],
      );
      final sys = computeSystem(_p, project,
          originFaultLevel: estimatedServiceFaultLevelA(project));
      final w = _way(sys, 'MDP', 'l').breaker;
      expect(w.deviceClass, BreakerClass.mccb);
      expect(w.ratingA.amperes, kMccbMinFrameA);
      final inc = sys.panels['MDP']!.incomer.breaker;
      // r2 — unconditional: the incomer on the same 36 kA bus is raised to
      // the MCCB class too, and never below the 16 A frame.
      expect(inc.deviceClass, BreakerClass.mccb);
      expect(inc.ratingA.amperes, greaterThanOrEqualTo(kMccbMinFrameA));

      // r2 — no issued surface (board schedule, BOM description / price
      // key) may name an MCCB below the 16 A frame.
      final small = RegExp(r'MCCB[ :]*(\d+(?:\.\d+)?) ?A');
      var seen = 0;
      void noSmallMccb(String text, String where) {
        for (final m in small.allMatches(text)) {
          seen++;
          expect(double.parse(m.group(1)!),
              greaterThanOrEqualTo(kMccbMinFrameA),
              reason: '$where: "$text"');
        }
      }

      for (final t in _labels(buildElectricalPanelDetail(
          project: project, result: sys, panelId: 'MDP'))) {
        noSmallMccb(t, 'schedule');
      }
      final adv = computeAdvancedStudy(_p, project, sys);
      final ka = faultSpecifiedKa(adv.fault);
      final bom = buildBom(sys,
          requiredIcuKaByPanelId: ka.bus,
          incomerKaByPanelId: ka.incomers,
          breakerKaByCircuitId: ka.breakers);
      expect(bom.lines, isNotEmpty);
      for (final l in bom.lines) {
        noSmallMccb(l.description, 'BOM description');
        noSmallMccb((l.priceKey ?? '').toUpperCase(), 'BOM price key');
      }
      expect(seen, greaterThan(0), reason: 'the scan saw the MCCB labels');
    });

    test('Iz below 16 A keeps the MCB and flags back-up protection', () {
      const b = BreakerResult(
          ratingA: Current(10),
          deviceClass: BreakerClass.mcb,
          curve: BreakerCurve.c);
      final kept = faultAwareBreakerClass(b, const Current(36000),
          maxRatingA: const Current(13));
      expect(kept.deviceClass, BreakerClass.mcb);
      expect(mcbNeedsBackupProtection(kept, const Current(36000)), isTrue);
      final raised = faultAwareBreakerClass(b, const Current(36000),
          maxRatingA: const Current(24));
      expect(raised.deviceClass, BreakerClass.mccb);
      expect(raised.ratingA.amperes, 16);
      // Below the MCB ladder top nothing changes (byte-identical).
      expect(identical(faultAwareBreakerClass(b, const Current(10000)), b),
          isTrue);
    });
  });

  // ── 4b. (r3) an incomer is never bought as another class / fewer poles ─
  group('regression-bom-incomer-substituted-by-smaller-class', () {
    // The scheduled incomer 'MCCB 16A 4P' (Round-39 fault-aware class on a
    // 36 kA bus) used to be priced as the catalogue 'MCB 16A C 1P' — a class
    // AND pole departure merely flagged deviceSubstituted. An incomer's class
    // and pole count are hard requirements (like the Round-33 exact rating):
    // with no compatible part it stays UNMATCHED on its own price key.
    const project = ElectricalProject(
      id: 'p',
      name: 'P',
      transformerKva: const ApparentPower(1000000),
      panels: [
        ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
          ElectricalCircuit(
              id: 'l',
              name: 'Lights',
              loadKind: LoadKind.lighting,
              loadW: 300,
              cosPhi: 0.9,
              phases: 1,
              length: const Length(10)),
        ]),
      ],
    );
    final sys = computeSystem(_p, project,
        originFaultLevel: estimatedServiceFaultLevelA(project));
    final inc = sys.panels['MDP']!.incomer;
    Part breaker(String sku, String cls, int poles,
            {double rating = 16, double? ka, String? curve}) =>
        Part(
          sku: sku,
          manufacturer: 'Test',
          category: PartCategory.breaker,
          series: 'T',
          model: '$cls ${rating}A ${poles}P',
          attributes: {
            'ratingA': rating,
            'poles': poles,
            'deviceClass': cls,
            if (curve != null) 'curve': curve,
            if (ka != null) 'breakingKa': ka,
          },
        );
    BomLine incomerLine(List<Part> parts) =>
        buildBom(sys, parts: parts, incomerKaByPanelId: const {'MDP': 50})
            .lines
            .singleWhere((l) => l.description.contains('incomer'));

    test('premise: the schedule specifies MCCB 16A 4P', () {
      expect(inc.breaker.deviceClass, BreakerClass.mccb);
      expect(inc.breaker.ratingA.amperes, 16);
      expect(inc.poles, 4);
    });

    test('only an MCB 16A C 1P in the catalogue => unmatched, own key', () {
      final l = incomerLine([breaker('MCB1', 'MCB', 1, ka: 50, curve: 'C')]);
      expect(l.sku, isNull);
      expect(l.deviceSubstituted, isFalse);
      expect(l.priceKey, '${kElecPriceKeyPrefix}breaker:MCCB:16A:4P:50kA');
      expect(l.description, isNot(contains('catalogue part')));
    });

    test('an MCCB with FEWER poles (3P) never serves a 4P incomer', () {
      final l = incomerLine([breaker('MCCB3', 'MCCB', 3, ka: 50)]);
      expect(l.sku, isNull);
      expect(l.priceKey, '${kElecPriceKeyPrefix}breaker:MCCB:16A:4P:50kA');
    });

    test('a compatible MCCB 16A 4P is bought (over an MCB of the rating)',
        () {
      final l = incomerLine([
        breaker('MCB1', 'MCB', 1, ka: 50, curve: 'C'),
        breaker('MCCB4', 'MCCB', 4, ka: 50),
      ]);
      expect(l.sku, 'MCCB4');
      expect(l.deviceSubstituted, isFalse);
    });

    test('an incompatible part short of the kA does not flag the line short',
        () {
      // Only an MCB (disqualified) is short of 50 kA: the MCCB is simply
      // absent from the catalogue, so the line is unmatched, not kA-short.
      final l = incomerLine([breaker('MCB1', 'MCB', 1, ka: 10, curve: 'C')]);
      expect(l.sku, isNull);
      expect(l.breakingCapacityShort, isFalse);
    });
  });

  // ── 5. a spare way pulls no cable on the schedule ────────────────────────
  group('elec-props-5-spare-way-cable-on-schedule-not-in-bom', () {
    const project = ElectricalProject(id: 'p', name: 'P', panels: [
      ElectricalPanel(id: 'SDP', name: 'SDP', circuits: [
        ElectricalCircuit(
            id: 'l',
            name: 'Light',
            loadKind: LoadKind.lighting,
            loadW: 2000,
            phases: 1,
            length: const Length(10)),
        ElectricalCircuit(
            id: 's',
            name: 'Spare MCB',
            loadKind: LoadKind.spare,
            loadW: 0,
            length: const Length(10)),
      ]),
    ]);
    final sys = computeSystem(_p, project);

    test('the spare row prints no cable / conduit / length token', () {
      final labels = _labels(buildElectricalPanelDetail(
          project: project, result: sys, panelId: 'SDP'));
      expect(labels, isNot(contains(contains('10.0 m · ')))); // sanity
      final cableTokens =
          labels.where((t) => t.contains('mm2 ·') || t == '-').toList();
      // Only the lighting way prints a cable; the spare row prints '-'.
      expect(cableTokens.where((t) => t.contains('mm2')), hasLength(1));
      expect(labels.where((t) => t.endsWith(' m') && t.contains('mm2')),
          hasLength(1));
    });

    test('the containment study gives the spare no conduit', () {
      final c = containmentFor(sys.panels['SDP']!);
      expect(c.conduits.map((x) => x.circuitId), ['l']);
    });

    test('schedule cable metres == BOM cable metres', () {
      final bom = buildBom(sys);
      final cableQty = bom.lines
          .where((l) => l.category.name == 'cable')
          .fold<double>(0, (s, l) => s + l.qty);
      expect(cableQty, closeTo(10, 1e-9));
    });
  });

  // ── 6. the off-sheet feeder length is one figure on both layouts ─────────
  group('elec-reports-parity-1', () {
    const building = BuildingLevels([
      Floor('GF', Length(4.0)),
      Floor('L1', Length(4.0)),
    ]);
    const calib = {
      's0': ScaleCalibration(0.02),
      's1': ScaleCalibration(0.05),
    };
    const mdpPos = LayoutPos(sheetId: 's0', floorIndex: 0, x: 100, y: 100);
    const lpPos = LayoutPos(sheetId: 's1', floorIndex: 1, x: 600, y: 100);
    const project = ElectricalProject(id: 'p', name: 'P', panels: [
      ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          tag: 'MDP',
          layoutPos: mdpPos,
          circuits: const [
            ElectricalCircuit(
                id: 'f',
                name: 'to LP',
                loadKind: LoadKind.feeder,
                feedsPanelId: 'LP',
                length: Length(10)),
          ]),
      const ElectricalPanel(
          id: 'LP',
          name: 'LP',
          tag: 'LP',
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'f',
          layoutPos: lpPos,
          circuits: []),
    ]);

    test('ke and dari print the feeding sheet\'s 500 x 0.02 + 4 = 14.0 m', () {
      final ke = buildElectricalPlanData(
              project: project,
              sheetId: 's0',
              floorIndex: 0,
              calibrations: calib,
              building: building)
          .risers
          .single
          .text;
      final dari = buildElectricalPlanData(
              project: project,
              sheetId: 's1',
              floorIndex: 1,
              calibrations: calib,
              building: building)
          .risers
          .single
          .text;
      expect(ke, endsWith('- 14.0 m'));
      expect(dari, endsWith('- 14.0 m'));
    });
  });

  // ── 7. unmatched RCDs key on their rated current ─────────────────────────
  group('elec-reports-parity-2', () {
    test('unmatched RCDs of different breaker ratings stay two lines', () {
      const project = ElectricalProject(
        id: 'p',
        name: 'P',
        earthingSystem: EarthingSystem.tt,
        panels: [
          const ElectricalPanel(id: 'B', name: 'B', circuits: [
            ElectricalCircuit(
                id: 'a',
                name: 'Socket A',
                loadKind: LoadKind.socket,
                loadW: 1500,
                phases: 1,
                length: Length(10)),
            ElectricalCircuit(
                id: 'b',
                name: 'Water heater',
                loadKind: LoadKind.general,
                // 9000 / 231 = 39 A -> a 40 A breaker -> a 40 A RCD frame,
                // vs Socket A's 10 A breaker -> a 16 A frame.
                loadW: 9000,
                phases: 1,
                length: Length(10)),
          ]),
        ],
      );
      final sys = computeSystem(_p, project);
      final ra = _way(sys, 'B', 'a');
      final rb = _way(sys, 'B', 'b');
      expect(ra.rcd.required && rb.rcd.required, isTrue);
      expect(ra.breaker.ratingA.amperes, isNot(rb.breaker.ratingA.amperes));
      final bom = buildBom(sys, parts: const []);
      final rcdKeys = {
        for (final l in bom.lines)
          if (l.category.name == 'rcd') l.priceKey
      };
      expect(rcdKeys, hasLength(2));
      expect(rcdFrameRatingA(10), 16);
      expect(rcdFrameRatingA(126), isNull);
    });
  });

  // ── 8. one installed-capacitor-bank definition ───────────────────────────
  group('elec-reports-parity-3', () {
    ElectricalCircuit cap(String id, double kvar) => ElectricalCircuit(
        id: id,
        name: id,
        loadKind: LoadKind.capacitor,
        loadW: kvar * 1000,
        phases: 3,
        length: const Length(5));
    ElectricalCircuit load() => const ElectricalCircuit(
        id: 'm',
        name: 'Motor',
        loadKind: LoadKind.heating,
        loadW: 80000,
        cosPhi: 0.75,
        phases: 3,
        length: Length(5));
    for (final (name, ways, declared) in [
      ('ways only', [cap('c', 50)], null),
      ('declared only', <ElectricalCircuit>[], 100.0),
      ('both present', [cap('c', 50)], 100.0),
    ]) {
      test('$name: schedule == BOM == PF installed', () {
        final project = ElectricalProject(
          id: 'p',
          name: 'P',
          capacitorBankKvar: declared,
          panels: [
            ElectricalPanel(
                id: 'LVMDP', name: 'LVMDP', circuits: [load(), ...ways]),
          ],
        );
        final sys = computeSystem(_p, project);
        final installed = installedCapacitorBanks(project)
            .fold<double>(0, (s, b) => s + b.kvar);
        final rows = buildEquipmentScheduleRows(EquipmentScheduleData(
            projectName: 'P',
            date: 'd',
            electrical: sys,
            electricalProject: project));
        final schedKvar = rows
            .where((r) => r.category == EquipmentCategory.capacitorBank)
            .fold<double>(
                0, (s, r) => s + double.parse(r.duty.split(' ').first));
        final bomKvar = advancedBomLines(project: project, sys: sys)
            .where((l) => l.description.startsWith('Capacitor bank '))
            .fold<double>(
                0, (s, l) => s + double.parse(l.description.split(' ')[2]));
        final pf = powerFactorCorrection(sys, project);
        expect(schedKvar, closeTo(installed, 1e-9));
        expect(bomKvar, closeTo(installed, 1e-9));
        expect(pf.installedKvar, closeTo(installed, 1e-6));
        expect(installed, ways.isEmpty ? 100 : 50);
      });
    }
  });

  // ── 9-11. the calc report states the schedule's make-up, kA, verdict ─────
  group('elec-reports-parity-4/5/6', () {
    test('Vdrop printed in its verdict direction: 3.05 % vs 3.0 % -> 3.1', () {
      expect(vdropPctForVerdict(3.05, limit: 3.0, over: true), '3.1');
      expect(vdropPctForVerdict(3.01, limit: 3.0, over: true), '3.1');
      expect(vdropPctForVerdict(3.04, limit: 3.0, over: false), '3.0');
      // Property: an OVER figure always prints above its limit.
      final rng = math.Random(9);
      for (var i = 0; i < 500; i++) {
        final lim = [3.0, 4.0, 5.0][rng.nextInt(3)];
        final v = lim + 1e-6 + rng.nextDouble() * 0.2;
        expect(double.parse(vdropPctForVerdict(v, limit: lim, over: true)),
            greaterThan(lim));
      }
    });

    test('cable cell = schedule make-up; kA printed when supplied', () {
      const project = ElectricalProject(id: 'p', name: 'P', panels: [
        ElectricalPanel(id: 'B', name: 'B', circuits: [
          ElectricalCircuit(
              id: 'h',
              name: 'Heater',
              loadKind: LoadKind.heating,
              loadW: 20000,
              cosPhi: 1,
              phases: 3,
              length: const Length(10)),
        ]),
      ]);
      final sys = computeSystem(_p, project);
      final r = _way(sys, 'B', 'h');
      final md = buildElectricalCalcReport(ElectricalCalcReportData(
        projectName: 'P',
        date: 'd',
        standardsName: 'PUIL',
        standardsRevision: '2011',
        project: project,
        result: sys,
        incomerKaByPanelId: const {'B': 10},
        breakerKaByCircuitId: const {'h': 6},
      ));
      final label = cableRunLabel(project.panels.first.circuits.first,
          r.cable.csaMm2, r.threePhase,
          cores: r.grounding.cores,
          runs: r.cable.runsPerPhase,
          peCsaMm2: r.grounding.peCsaMm2,
          neutralCsaMm2: r.grounding.neutralCsaMm2);
      expect(md, contains('| $label |'));
      expect(md, contains(' 6 kA'));
      expect(md, contains(' 10 kA'));
    });
  });

  // ── 12-13. a stale A5 FLA re-derives from the way's own load ─────────────
  group('elec-ui-journeys-2 (FLA)', () {
    test('parked (source-less) way retyped to 15 kW sizes at 25.5 A / 32 A',
        () {
      const project = ElectricalProject(id: 'p', name: 'P', panels: [
        ElectricalPanel(id: 'B', name: 'B', circuits: [
          ElectricalCircuit(
            id: 'w',
            name: 'Pump P-01 (source removed)',
            loadKind: LoadKind.pump,
            loadW: 15000,
            motorKw: 3,
            cosPhi: 0.85,
            phases: 3,
            length: const Length(10),
            flaOverrideA: const Current(6.0),
          ),
        ]),
      ]);
      final r = _way(computeSystem(_p, project), 'B', 'w');
      // 15000 / (sqrt3 * 400 * 0.85) = 25.47 A -> 32 A.
      expect(r.runCurrentA.amperes, closeTo(25.5, 0.05));
      expect(r.breaker.ratingA.amperes, 32);
    });

    test('MEP way on a 1ph 220 V board: 3529.4 / (220 * 0.85) = 18.9 A', () {
      const project = ElectricalProject(id: 'p', name: 'P', panels: [
        ElectricalPanel(
            id: 'B',
            name: 'B',
            system: ElectricalSystem.singlePhase,
            voltage: const Voltage(220),
            circuits: [
              ElectricalCircuit(
                id: 'w',
                name: 'Pump',
                loadKind: LoadKind.pump,
                loadW: 3529.4,
                motorKw: 3,
                cosPhi: 0.85,
                phases: 3,
                length: const Length(10),
                sourceEquipmentId: 'n1',
                flaOverrideA: const Current(6.0),
              ),
            ]),
      ]);
      final r = _way(computeSystem(_p, project), 'B', 'w');
      expect(r.runCurrentA.amperes, closeTo(18.9, 0.05));
      expect(r.breaker.ratingA.amperes, 20);
    });

    test('an untouched MEP way on its 3ph 400 V board keeps the mint', () {
      const project = ElectricalProject(id: 'p', name: 'P', panels: [
        ElectricalPanel(id: 'B', name: 'B', circuits: [
          ElectricalCircuit(
            id: 'w',
            name: 'Pump',
            loadKind: LoadKind.pump,
            loadW: 3529.4,
            motorKw: 3,
            cosPhi: 0.85,
            phases: 3,
            length: const Length(10),
            sourceEquipmentId: 'n1',
            flaOverrideA: const Current(6.0),
          ),
        ]),
      ]);
      expect(_way(computeSystem(_p, project), 'B', 'w').runCurrentA.amperes,
          closeTo(6.0, 1e-9));
    });
  });

  // ── 14. a generator / solar primary supply is LV, with its own fault ─────
  group('elec-ui-journeys-2-generator-supply-drawn-as-mv', () {
    const project = ElectricalProject(
      id: 'p',
      name: 'P',
      supplyKind: SupplyKind.generator,
      supplyCapacityVa: const ApparentPower(250000),
      panels: [
        ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
          ElectricalCircuit(
              id: 'h',
              name: 'h',
              loadKind: LoadKind.heating,
              loadW: 100000,
              cosPhi: 1,
              phases: 3,
              length: const Length(5)),
        ]),
      ],
    );

    test('no declared MV service, no transformer', () {
      expect(isDeclaredMvService(project), isFalse);
      expect(declaredServiceTransformer(project), isNull);
      final sys = computeSystem(_p, project);
      final labels = _labels(buildElectricalSourceSpine(
          project: project, result: sys));
      expect(labels.any((t) => t.contains('TRANSFORMER')), isFalse);
      expect(labels.any((t) => t.contains('TEGANGAN MENENGAH')), isFalse);
    });

    test('fault = 250e3 / (sqrt3 * 400 * 0.12) = 3007 A, not 16 kA', () {
      final f = estimatedServiceFaultLevelA(project)!.amperes;
      expect(f, closeTo(250000 / (math.sqrt(3) * 400 * 0.12), 0.1));
      const solar = ElectricalProject(
          id: 's',
          name: 'S',
          supplyKind: SupplyKind.solar,
          supplyCapacityVa: const ApparentPower(100000),
          panels: const []);
      expect(estimatedServiceFaultLevelA(solar)!.amperes,
          closeTo(1.5 * 100000 / (math.sqrt(3) * 400), 0.1));
    });

    test('(r2) the Design Basis names the alternator / inverter basis', () {
      expect(serviceFaultEstimateBasis(project),
          FaultLevelBasis.generatorEstimate);
      final sys = computeSystem(_p, project);
      final md = buildElectricalCalcReport(ElectricalCalcReportData(
        projectName: 'P',
        date: 'd',
        standardsName: 'PUIL',
        standardsRevision: '2011',
        project: project,
        result: sys,
        originFaultLevelA: estimatedServiceFaultLevelA(project)!.amperes,
        faultLevelBasis: serviceFaultEstimateBasis(project),
      ));
      expect(md, contains("generator's alternator"));
      expect(md, contains("Xd'' 0.12 p.u."));
      expect(md, isNot(contains('declared service size')));

      const solar = ElectricalProject(
          id: 's',
          name: 'S',
          supplyKind: SupplyKind.solar,
          supplyCapacityVa: ApparentPower(100000),
          panels: []);
      expect(serviceFaultEstimateBasis(solar),
          FaultLevelBasis.inverterEstimate);
      // A declared customer transformer wins (the engine's step 1).
      const genTx = ElectricalProject(
          id: 'g',
          name: 'G',
          supplyKind: SupplyKind.generator,
          transformerKva: ApparentPower(630000),
          panels: []);
      expect(serviceFaultEstimateBasis(genTx), FaultLevelBasis.serviceEstimate);
      // PLN keeps the legacy split.
      const pln = ElectricalProject(
          id: 'n',
          name: 'N',
          supplyCapacityVa: ApparentPower(33000),
          panels: []);
      expect(serviceFaultEstimateBasis(pln), FaultLevelBasis.serviceEstimate);
      const bare = ElectricalProject(id: 'b', name: 'B', panels: []);
      expect(serviceFaultEstimateBasis(bare),
          FaultLevelBasis.supplyStudyEstimate);
    });
  });
}
