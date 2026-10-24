// Round 40 (2026-10-18) — electrical regressions + drawing honesty.
//
// Each group pins one confirmed finding with a first-principles derivation;
// where a counterexample generalises, it is a seeded property.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

ElectricalCircuitResult _way(
        ElectricalSystemResult s, String panel, String c) =>
    s.panels[panel]!.circuits.firstWhere((r) => r.circuitId == c);

ElectricalProject _fedMachine({
  required LoadKind kind,
  required double loadW,
  required double cosPhi,
  required double df,
  double? supplyVa,
}) =>
    ElectricalProject(
      id: 'p',
      name: 'P',
      supplyCapacityVa: supplyVa == null ? null : ApparentPower(supplyVa),
      panels: [
        const ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
          ElectricalCircuit(
            id: 'f',
            name: 'Feeder to SB',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'SB',
            phases: 3,
            length: Length(10),
          ),
        ]),
        ElectricalPanel(
          id: 'SB',
          name: 'SB',
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'f',
          circuits: [
            ElectricalCircuit(
              id: 'm',
              name: 'Machine',
              loadKind: kind,
              loadW: loadW,
              cosPhi: cosPhi,
              phases: 3,
              demandFactor: df,
              length: const Length(10),
            ),
          ],
        ),
      ],
    );

void main() {
  // ── 1. the largest-machine floor follows the machine up the tree ─────────
  group('regression-largest-machine-floor-not-propagated-upstream', () {
    // Welder 15 kW, cos phi 0.7, 3ph, df 0.5:
    //   run = 15000 / (sqrt(3) * 400 * 0.7) = 30.93 A  -> SB incomer 32 A;
    //   diversified = 0.5 * 30.93 = 15.5 A.
    // The feeder and the MDP incomer carry the machine whenever it runs, so
    // both are >= 32 A; the recommended daya passes >= sqrt(3)*400*30.9 VA.
    final run = 15000 / (math.sqrt(3) * 400 * 0.7);
    final project =
        _fedMachine(kind: LoadKind.welding, loadW: 15000, cosPhi: 0.7, df: 0.5);
    final sys = computeSystem(_p, project);

    test('SB incomer, feeder and MDP incomer all >= 32 A', () {
      expect(_way(sys, 'SB', 'm').runCurrentA.amperes, closeTo(run, 0.05));
      expect(sys.panels['SB']!.incomer.breaker.ratingA.amperes, 32);
      final f = _way(sys, 'MDP', 'f');
      expect(f.breaker.ratingA.amperes, greaterThanOrEqualTo(32));
      // The conductor protects the device: Iz >= In.
      expect(f.cable.deratedIz.amperes,
          greaterThanOrEqualTo(f.breaker.ratingA.amperes - 1e-9));
      expect(sys.panels['MDP']!.incomer.breaker.ratingA.amperes,
          greaterThanOrEqualTo(32));
      expect(sys.panels['MDP']!.largestDownstreamRunA, closeTo(run, 0.05));
    });

    test('recommended daya >= sqrt(3) * 400 * 30.9 VA', () {
      final adv = computeAdvancedStudy(_p, project, sys);
      expect(adv.recommendedDayaVa, isNotNull);
      expect(adv.recommendedDayaVa!,
          greaterThanOrEqualTo(math.sqrt(3) * 400 * 30.9 - 1e-6));
    });

    test('a declared daya below the machine raises the service judge', () {
      // 13 200 VA -> 13200 / (sqrt(3)*400) = 19.05 A < 30.9 A.
      final s = computeSystem(
          _p,
          _fedMachine(
              kind: LoadKind.welding,
              loadW: 15000,
              cosPhi: 0.7,
              df: 0.5,
              supplyVa: 13200));
      expect(s.warnings.where((w) => w.code == 'service-capacity-below-demand'),
          hasLength(1));
    });

    test('HVAC 10 kW df 0.9 behind a feeder: MDP incomer >= 20 A', () {
      // run = 10000 / (sqrt(3)*400*0.85) = 16.98 A -> 20 A rung.
      final s = computeSystem(
          _p,
          _fedMachine(
              kind: LoadKind.hvac, loadW: 10000, cosPhi: 0.85, df: 0.9));
      expect(s.panels['SB']!.incomer.breaker.ratingA.amperes, 20);
      expect(_way(s, 'MDP', 'f').breaker.ratingA.amperes,
          greaterThanOrEqualTo(20));
      expect(s.panels['MDP']!.incomer.breaker.ratingA.amperes,
          greaterThanOrEqualTo(20));
    });

    test(
        'seeded property: every feeder and incomer up the chain >= the '
        'largest final way running current below it', () {
      final rng = math.Random(40);
      const kinds = [
        LoadKind.hvac,
        LoadKind.heating,
        LoadKind.general,
        LoadKind.welding,
        LoadKind.socket,
      ];
      for (var t = 0; t < 150; t++) {
        final n = 1 + rng.nextInt(3);
        final ways = [
          for (var i = 0; i < n; i++)
            ElectricalCircuit(
              id: 'c$i',
              name: 'c$i',
              loadKind: kinds[rng.nextInt(kinds.length)],
              loadW: 500 + rng.nextDouble() * 25000,
              cosPhi: 0.7 + rng.nextDouble() * 0.3,
              demandFactor: 0.3 + rng.nextDouble() * 0.7,
              phases: rng.nextBool() ? 3 : 1,
              length: Length(5 + rng.nextDouble() * 30),
            ),
        ];
        final s = computeSystem(
            _p,
            ElectricalProject(id: 'p', name: 'P', panels: [
              const ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
                ElectricalCircuit(
                  id: 'f',
                  name: 'to SB',
                  loadKind: LoadKind.feeder,
                  feedsPanelId: 'SB',
                  phases: 3,
                  length: Length(10),
                ),
              ]),
              ElectricalPanel(
                  id: 'SB',
                  name: 'SB',
                  sourceType: PanelSource.feeder,
                  fedByCircuitId: 'f',
                  circuits: ways),
            ]));
        final maxRun = s.panels['SB']!.circuits
            .map((c) => c.runCurrentA.amperes)
            .fold(0.0, math.max);
        expect(_way(s, 'MDP', 'f').breaker.ratingA.amperes + 0.05,
            greaterThanOrEqualTo(maxRun),
            reason: 'trial $t feeder');
        expect(s.panels['MDP']!.incomer.breaker.ratingA.amperes + 0.05,
            greaterThanOrEqualTo(maxRun),
            reason: 'trial $t MDP incomer');
      }
    });
  });

  // ── 8. the supply 'connected' load is undiversified ──────────────────────
  group('electrical-sim-5-supply-connected-is-diversified', () {
    // One 1800 W socket way at df 0.5 + one 1200 W lighting way at df 1:
    //   connected (undiversified) = 1800 + 1200 = 3000 W;
    //   demand = 0.5 * 1800 + 1200 = 2100 W.
    const project = ElectricalProject(id: 'p', name: 'P', panels: [
      ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
        ElectricalCircuit(
            id: 's',
            name: 'S',
            loadKind: LoadKind.socket,
            loadW: 1800,
            demandFactor: 0.5,
            length: Length(10)),
        ElectricalCircuit(
            id: 'l',
            name: 'L',
            loadKind: LoadKind.lighting,
            loadW: 1200,
            demandFactor: 1.0,
            length: Length(10)),
      ]),
    ]);
    final sys = computeSystem(_p, project);
    test('connected 3000 W > demand 2100 W; equals the board connected', () {
      expect(sys.supply.connectedW, closeTo(3000, 1e-6));
      expect(sys.supply.demandW, closeTo(2100, 1));
      expect(sys.supply.connectedW, greaterThan(sys.supply.demandW));
      final boardConnected = sys.panels['MDP']!.circuits
          .fold(0.0, (a, c) => a + c.connectedWOrLoad);
      expect(sys.supply.connectedW, closeTo(boardConnected, 1e-6));
    });
  });

  // ── 6. dual transformer: the most loaded SECTION governs ─────────────────
  group('electrical-sim-5-dual-tx-section-overload-missed', () {
    // 2 x 1600 kVA declared; LVMDP2 carries 6 x 250 kW heating (pf 1) =
    // 1500 kVA, LVMDP1 1 x 200 kW. Equal split: 1700 / 2 = 850 <= 1280
    // (1600 x 0.8) -> wrongly passed. The section on LVMDP2 carries
    // 1500 kVA > 1280 -> overloaded (1500 / 1600 = 94 % of nameplate,
    // 1500 / 1280 = 117 % of the 0.8-factor rating), and a
    // single 1600 kVA unit's LV FLC is 1600e3 / (sqrt(3) * 400) = 2309 A.
    ElectricalCircuit heater(String id, double w) => ElectricalCircuit(
        id: id,
        name: id,
        loadKind: LoadKind.heating,
        loadW: w,
        cosPhi: 1.0,
        phases: 3,
        length: const Length(10));
    final project = ElectricalProject(
      id: 'p',
      name: 'P',
      dualTransformer: true,
      transformerKva: const ApparentPower(1600000),
      panels: [
        ElectricalPanel(
            id: 'LVMDP1', name: 'LVMDP1', circuits: [heater('a', 200000)]),
        ElectricalPanel(id: 'LVMDP2', name: 'LVMDP2', circuits: [
          for (var i = 0; i < 6; i++) heater('h$i', 250000),
        ]),
      ],
    );
    final sys = computeSystem(_p, project);
    final adv = computeAdvancedStudy(_p, project, sys);

    test('the section on LVMDP2 is flagged overloaded', () {
      expect(adv.supply.declaredBelowDemand, isTrue);
      final w = adv.warnings
          .where((w) => w.code == 'section-transformer-overloaded')
          .toList();
      expect(w, hasLength(1));
      expect(w.single.panelId, 'LVMDP2');
    });

    // Round 41 — re-derived: the LVMDP2 incomer (1500 kVA / (sqrt(3) x 400)
    // = 2165 A -> the 2500 A ACB rung) is the FIRST rung at or above one
    // unit's FLC (2309 A -> 2500 A), i.e. the incomer a 1600 kVA unit's
    // full load needs anyway — no FLC warning. The overload stays covered
    // by `section-transformer-overloaded` above.
    test('LVMDP2 incomer on the FLC own rung (2500 A) is not flagged', () {
      final flc = 1600e3 / (math.sqrt(3) * 400);
      expect(flc, closeTo(2309.4, 0.1));
      final inA = sys.panels['LVMDP2']!.incomer.breaker.ratingA.amperes;
      expect(inA, greaterThan(flc));
      expect(inA, incomerRungForFlcA(_p, flc));
      expect(inA, 2500);
      expect(
          adv.warnings.where((w) =>
              w.code == 'root-incomer-exceeds-transformer-flc' &&
              w.panelId == 'LVMDP2'),
          isEmpty);
      expect(
          adv.warnings.where((w) =>
              w.code == 'root-incomer-exceeds-transformer-flc' &&
              w.panelId == 'LVMDP1'),
          isEmpty);
    });

    test('balanced sections: no section warning (equal split unchanged)', () {
      final balanced = ElectricalProject(
        id: 'p',
        name: 'P',
        dualTransformer: true,
        transformerKva: const ApparentPower(1600000),
        panels: [
          ElectricalPanel(id: 'A', name: 'A', circuits: [heater('a', 400000)]),
          ElectricalPanel(id: 'B', name: 'B', circuits: [heater('b', 400000)]),
        ],
      );
      final s = computeSystem(_p, balanced);
      final a = computeAdvancedStudy(_p, balanced, s);
      expect(a.supply.declaredBelowDemand, isFalse);
      expect(
          a.warnings.where((w) => w.code == 'section-transformer-overloaded'),
          isEmpty);
    });
  });

  // ── 7. the selectivity floor never breaks ADS ────────────────────────────
  group('electrical-sim-5-selectivity-floor-breaks-ads', () {
    // SB: 3 x 6200 W 1ph heaters (one per line) -> worst line
    //   6200 / 231 = 26.8 A -> SB incomer 32 A; feeder load-sized 32 A.
    // Floor = 1.6 x 32 = 51.2 A, capped at the 10 mm2 cable's Iz 50 A -> 50 A.
    // TN 5 s ADS, curve C (10 x In): Zs_max = 0.95 x 230 / (10 x In):
    //   32 A -> 0.683 ohm, 40 A -> 0.547 ohm, 50 A -> 0.437 ohm.
    // At 110 m of 10 mm2 the loop is Zs ~= 0.619 ohm: the load-sized 32 A
    // passes, 40 A and 50 A fail -> the floor must stop at 32 A.
    ElectricalProject fixture(double len, double csa) =>
        ElectricalProject(id: 'p', name: 'P', panels: [
          ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
            ElectricalCircuit(
                id: 'f',
                name: 'to SB',
                loadKind: LoadKind.feeder,
                feedsPanelId: 'SB',
                phases: 3,
                length: Length(len),
                cableOverrideMm2: csa),
          ]),
          ElectricalPanel(
              id: 'SB',
              name: 'SB',
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'f',
              circuits: [
                for (var i = 0; i < 3; i++)
                  ElectricalCircuit(
                      id: 'h$i',
                      name: 'h$i',
                      loadKind: LoadKind.heating,
                      loadW: 6200,
                      cosPhi: 1,
                      phases: 1,
                      length: const Length(5)),
              ]),
        ]);

    test('110 m of 10 mm2: feeder stays 32 A and ADS passes', () {
      final project = fixture(110, 10);
      final s = computeSystem(_p, project);
      final adv = computeAdvancedStudy(_p, project, s);
      expect(_way(s, 'MDP', 'f').breaker.ratingA.amperes, 32);
      final fc = adv.fault.circuits['f']!;
      expect(fc.zsOhm!, closeTo(0.619, 0.01));
      expect(fc.adsOk, isTrue);
      // The floor target was not reached: the residual partial selectivity
      // stays reported (not suppressed as an engine floor).
      expect(s.feederFloorsApplied, isNot(contains('f')));
      expect(
          adv.fault.warnings.where(
              (w) => w.code == 'ads-disconnection' && w.circuitId == 'f'),
          isEmpty);
    });

    test('90 m: the floor stops at the highest rung ADS allows (40 A)', () {
      // Zs ~= 0.507: 40 A (0.547) passes, 50 A (0.437) fails.
      final project = fixture(90, 10);
      final s = computeSystem(_p, project);
      expect(_way(s, 'MDP', 'f').breaker.ratingA.amperes, 40);
      expect(computeAdvancedStudy(_p, project, s).fault.circuits['f']!.adsOk,
          isTrue);
    });

    test(
        'seeded property: a feeder fails ADS only at its load-sized rung (the floor never worsens ADS)',
        () {
      final rng = math.Random(4007);
      const csas = [6.0, 10.0, 16.0, 25.0];
      for (var t = 0; t < 40; t++) {
        final len = 30 + rng.nextDouble() * 200;
        final csa = csas[rng.nextInt(csas.length)];
        final project = fixture(len, csa);
        final s = computeSystem(_p, project);
        final fc = computeAdvancedStudy(_p, project, s).fault.circuits['f']!;
        if (fc.adsOk == false) {
          expect(_way(s, 'MDP', 'f').breaker.ratingA.amperes, 32,
              reason: 'trial $t len $len csa $csa');
        }
      }
    });
  });

  // ── 5. a transient load never permanently relabels the board ─────────────
  group('elec-props-6-phase-labels-not-restored-after-mep-add-remove', () {
    // Heaters at cos phi 1, 1ph at 231 V (I = W / 231) + a 6 kW 3ph motor
    // (equal on every line, so it never decides a label).
    ElectricalCircuit one(String id, LoadKind k, double w) => ElectricalCircuit(
        id: id,
        name: id,
        loadKind: k,
        loadW: w,
        cosPhi: 1.0,
        phases: 1,
        demandFactor: 1.0,
        length: const Length(10));
    const motor = ElectricalCircuit(
        id: 'p3',
        name: 'motor 3ph',
        loadKind: LoadKind.motor,
        motorKw: 6,
        phases: 3,
        length: Length(10));
    ElectricalProject board(List<ElectricalCircuit> extra) =>
        ElectricalProject(id: 'p', name: 'P', panels: [
          ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
            one('m0', LoadKind.heating, 4200),
            one('m1', LoadKind.heating, 2400),
            one('m2', LoadKind.heating, 2200),
            one('m3', LoadKind.heating, 4100),
            motor,
            ...extra,
          ]),
        ]);
    Map<String, PhaseAssignment> labels(ElectricalSystemResult s) => {
          for (final c in s.panels['MDP']!.circuits) c.circuitId: c.phase,
        };
    double worst(ElectricalSystemResult s) {
      final b = s.panels['MDP']!.phaseBalance;
      return math.max(b.l1, math.max(b.l2, b.l3));
    }

    test('add then remove a 3.4 kW way: the four ways keep their labels', () {
      // Currents (W / 231): 18.2 / 10.4 / 9.5 / 17.7 A, the added way
      // 14.7 A. Adding it needs at most ONE existing way to change line to
      // reach the best worst phase; the old rule adopted the fresh solve's
      // labels wholesale (two existing ways relabelled), and removing the
      // way again then kept those labels for good.
      final s0 =
          computeSystem(_p, board(const []), phaseReassignThresholdA: 1.0);
      final l0 = labels(s0);
      final s1 = computeSystem(_p, board([one('x', LoadKind.heating, 3400)]),
          priorAssignments: {'MDP': l0}, phaseReassignThresholdA: 1.0);
      final l1 = labels(s1)..remove('x');
      final moved = [
        for (final k in ['m0', 'm1', 'm2', 'm3'])
          if (l1[k] != l0[k]) k
      ];
      expect(moved.length, lessThanOrEqualTo(1));
      final s2 = computeSystem(_p, board(const []),
          priorAssignments: {'MDP': l1}, phaseReassignThresholdA: 1.0);
      for (final id in ['m0', 'm1', 'm2', 'm3']) {
        expect(labels(s2)[id], l0[id], reason: id);
      }
      expect(worst(s2), lessThanOrEqualTo(worst(s0) + 1e-9));
    });

    test(
        'seeded property: a prior never raises the worst phase above the '
        'fresh solve, and a fresh-optimal prior is kept verbatim', () {
      final rng = math.Random(4005);
      const lines = [
        PhaseAssignment.l1,
        PhaseAssignment.l2,
        PhaseAssignment.l3
      ];
      for (var t = 0; t < 120; t++) {
        final n = 2 + rng.nextInt(6);
        final ways = [
          for (var i = 0; i < n; i++)
            one('w$i', LoadKind.heating, 500 + rng.nextDouble() * 4000),
        ];
        final project = ElectricalProject(id: 'p', name: 'P', panels: [
          ElectricalPanel(id: 'MDP', name: 'MDP', circuits: ways),
        ]);
        final fresh = computeSystem(_p, project);
        final prior = {
          for (final w in ways) w.id: lines[rng.nextInt(3)],
        };
        final s = computeSystem(_p, project,
            priorAssignments: {'MDP': prior}, phaseReassignThresholdA: 1.0);
        double worst(ElectricalSystemResult r) {
          final b = r.panels['MDP']!.phaseBalance;
          return math.max(b.l1, math.max(b.l2, b.l3));
        }

        expect(worst(s), lessThanOrEqualTo(worst(fresh) + 0.05),
            reason: 'trial $t');
        // Re-solving with its own labels as the prior is a fixed point.
        final again = computeSystem(_p, project,
            priorAssignments: {'MDP': labels(s)}, phaseReassignThresholdA: 1.0);
        expect(labels(again), labels(s), reason: 'trial $t fixed point');
      }
    });
  });
}
