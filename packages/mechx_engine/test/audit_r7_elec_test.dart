// Round-7 property audit — electrical fixes, each pinned by the finding's
// counterexample and, where it fits, a seeded property:
//   elec-props-1  faultStudy uses the PARENT's material for the feeder's N/PE
//                 (agrees with Fold-1 on every mixed-material tree);
//   elec-props-2  a feeder converts at the fed board's REAL power factor;
//   elec-props-3  the phase balancer adopts the exact optimum (≤ 10 singles);
//   elec-props-4  feeder-below-fed-demand compares like with like (diversity);
//   elec-props-5  a breaker override below Ib is flagged.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

ElectricalCircuit _way(String id, double w,
        {double cos = 1.0,
        int phases = 1,
        LoadKind kind = LoadKind.heating,
        Current? breakerOverrideA,
        double lengthM = 10}) =>
    ElectricalCircuit(
      id: id,
      name: id,
      loadKind: kind,
      loadW: w,
      cosPhi: cos,
      phases: phases,
      length: Length(lengthM),
      breakerOverrideA: breakerOverrideA,
    );

ElectricalCircuit _feeder(String id, String child,
        {double lengthM = 10, double? cableMm2}) =>
    ElectricalCircuit(
      id: id,
      name: id,
      loadKind: LoadKind.feeder,
      cosPhi: 0.85,
      length: Length(lengthM),
      feedsPanelId: child,
      cableOverrideMm2: cableMm2,
    );

/// The exact minimum worst phase over every assignment of [ways] (A).
double _bruteMinWorst(List<double> ways) {
  var best = double.infinity;
  final l = [0.0, 0.0, 0.0];
  void walk(int i) {
    if (i == ways.length) {
      best = math.min(best, math.max(l[0], math.max(l[1], l[2])));
      return;
    }
    for (var p = 0; p < 3; p++) {
      l[p] += ways[i];
      walk(i + 1);
      l[p] -= ways[i];
    }
  }

  walk(0);
  return best;
}

void main() {
  group('elec-props-1 — feeder N/PE in the PARENT material', () {
    ElectricalProject project(ConductorMaterial child) => ElectricalProject(
          id: 'pr',
          name: 'B',
          earthingSystem: EarthingSystem.tnS,
          panels: [
            ElectricalPanel(
              id: 'MDP',
              name: 'MDP',
              circuits: [_feeder('f', 'SDB', lengthM: 4, cableMm2: 16)],
            ),
            ElectricalPanel(
              id: 'SDB',
              name: 'SDB',
              system: ElectricalSystem.singlePhase,
              voltage: const Voltage(220),
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'f',
              material: child,
              circuits: [_way('s', 9000, kind: LoadKind.socket)],
            ),
          ],
        );

    test('marking the SUB-board aluminium leaves its bus fault unchanged', () {
      final cu = project(ConductorMaterial.copper);
      final al = project(ConductorMaterial.aluminum);
      final fsCu = faultStudy(computeSystem(_p, cu), cu, _p);
      final fsAl = faultStudy(computeSystem(_p, al), al, _p);
      // The feeder (phase, neutral AND PE) is the Cu MDP's cable either way,
      // so the L-N loop impedance — and the bus fault — are the same.
      expect(fsAl.panels['SDB']!.prospectiveFaultkA,
          fsCu.panels['SDB']!.prospectiveFaultkA);
      // ...and the device is specified on the TRUE fault (11.08 kA ⇒ 15 kA).
      expect(fsAl.circuits['s']!.breakerKa, fsCu.circuits['s']!.breakerKa);
      expect(fsAl.circuits['s']!.breakerKa,
          greaterThanOrEqualTo(fsAl.panels['SDB']!.prospectiveFaultkA));
    });

    test('property: Fold-1 and faultStudy agree on random mixed-material trees',
        () {
      for (var seed = 0; seed < 150; seed++) {
        final rnd = math.Random(seed);
        ConductorMaterial m() => rnd.nextBool()
            ? ConductorMaterial.copper
            : ConductorMaterial.aluminum;
        final n = 2 + rnd.nextInt(4);
        final panels = <ElectricalPanel>[];
        for (var i = 0; i < n; i++) {
          final children = [
            for (var j = i + 1; j < n; j++)
              if (j == i + 1 || rnd.nextInt(4) == 0) j,
          ].where((j) => j == i + 1).toList(); // a chain (one parent each)
          final onePhase = i > 0 && rnd.nextInt(3) == 0 && children.isEmpty;
          panels.add(ElectricalPanel(
            id: 'P$i',
            name: 'P$i',
            system: onePhase
                ? ElectricalSystem.singlePhase
                : ElectricalSystem.threePhase,
            voltage: Voltage(onePhase ? 220 : 400),
            material: m(),
            sourceType: i == 0 ? PanelSource.utility : PanelSource.feeder,
            fedByCircuitId: i == 0 ? null : 'f${i - 1}',
            circuits: [
              _way('w$i', 2000.0 + rnd.nextInt(8000)),
              for (final j in children)
                _feeder('f$i', 'P$j', lengthM: 2.0 + rnd.nextInt(60)),
            ],
          ));
        }
        final proj = ElectricalProject(
            id: 'x',
            name: 'x',
            earthingSystem: EarthingSystem.tnS,
            panels: panels);
        final sys =
            computeSystem(_p, proj, originFaultLevel: const Current(16000));
        final fs = faultStudy(sys, proj, _p);
        for (final pr in panels.skip(1)) {
          final w = sys.panels[pr.id]!.busbar.withstand;
          expect(w, isNotNull);
          expect(
              fs.panels[pr.id]!.prospectiveFaultkA, closeTo(w!.faultKa, 0.011),
              reason: 'seed $seed ${pr.id}');
        }
      }
    });
  });

  group('elec-props-2 — a feeder converts at the fed board REAL pf', () {
    // SDP: three 20 kW three-phase 'general' ways at cos 0.65 (diversity 1).
    final project = ElectricalProject(
      id: 'pr',
      name: 'B',
      earthingSystem: EarthingSystem.tnS,
      panels: [
        ElectricalPanel(
            id: 'MDP', name: 'MDP', circuits: [_feeder('f', 'SDP')]),
        ElectricalPanel(
          id: 'SDP',
          name: 'SDP',
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'f',
          circuits: [
            for (var i = 0; i < 3; i++)
              _way('g$i', 20000, cos: 0.65, phases: 3, kind: LoadKind.general),
          ],
        ),
      ],
    );
    final sys = computeSystem(_p, project);

    test('feeder Ib = the board line current, and the cable carries it', () {
      // Board: 60 000 / (√3·400·0.65) = 133.24 A on every line.
      final expected = 60000 / (math.sqrt(3) * 400 * 0.65);
      expect(expected, closeTo(133.24, 0.01));
      expect(sys.panels['SDP']!.demandCurrent.amperes, 133.2);
      final f = sys.panels['MDP']!.circuits.single;
      // Was 60 000/(√3·400·0.85) = 101.9 A at the feeder's own default.
      expect(f.designCurrent.amperes, 133.2);
      // Ib ≤ In ≤ Iz — the conductor carries what it really feeds.
      expect(f.breaker.ratingA.amperes, greaterThanOrEqualTo(133.2));
      expect(f.cable.deratedIz.amperes,
          greaterThanOrEqualTo(f.breaker.ratingA.amperes));
    });

    test('property: a balanced 3φ fed board — feeder Ib = demand × diversity',
        () {
      for (var seed = 0; seed < 60; seed++) {
        final rnd = math.Random(seed);
        final div = 0.5 + rnd.nextInt(6) / 10; // 0.5 … 1.0
        final ways = [
          for (var i = 0; i < 1 + rnd.nextInt(4); i++)
            _way('g$i', 3000.0 + rnd.nextInt(30000),
                cos: 0.6 + rnd.nextInt(41) / 100,
                phases: 3,
                kind: LoadKind.general),
        ];
        final proj = ElectricalProject(
          id: 'p',
          name: 'p',
          earthingSystem: EarthingSystem.tnS,
          panels: [
            ElectricalPanel(
                id: 'MDP', name: 'MDP', circuits: [_feeder('f', 'SDP')]),
            ElectricalPanel(
              id: 'SDP',
              name: 'SDP',
              diversityFactor: div,
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'f',
              circuits: ways,
            ),
          ],
        );
        final s = computeSystem(_p, proj);
        // Σ P / (√3·V·pf) with pf = ΣP / Σ(P/cos) ⇒ Σ (P/cos) / (√3·V) — the
        // arithmetic sum of the ways' own line currents, × the diversity.
        final lineA = ways.fold(
            0.0, (a, w) => a + w.loadW / (math.sqrt(3) * 400 * w.cosPhi));
        final f = s.panels['MDP']!.circuits.single;
        expect(f.designCurrent.amperes, closeTo(lineA * div, 0.051),
            reason: 'seed $seed');
        expect(f.cable.deratedIz.amperes,
            greaterThanOrEqualTo(f.designCurrent.amperes),
            reason: 'seed $seed');
        // And no feeder-below-fed-demand on a balanced board (elec-props-4).
        expect(s.panels['MDP']!.warnings.map((w) => w.code),
            isNot(contains('feeder-below-fed-demand')),
            reason: 'seed $seed');
      }
    });
  });

  group('elec-props-3 — the balancer reaches the exact optimum', () {
    ElectricalPanelResult board(List<double> ib) {
      final proj = ElectricalProject(
        id: 'p',
        name: 'p',
        earthingSystem: EarthingSystem.tnS,
        panels: [
          ElectricalPanel(id: 'DB', name: 'DB', circuits: [
            // loadW = I × 231 × 0.85 ⇒ Ib = I (231 V phase voltage).
            for (var i = 0; i < ib.length; i++)
              _way('x$i', ib[i] * 231 * 0.85,
                  cos: 0.85, kind: LoadKind.general),
          ]),
        ],
      );
      return computeSystem(_p, proj).panels['DB']!;
    }

    test('nine ways: worst phase 49.5 A ⇒ a 50 A incomer (was 63 A)', () {
      const ib = [7.7, 6.2, 13.4, 23.1, 16.7, 24.4, 21.5, 23.7, 9.7];
      final r = board(ib);
      // {24.4, 23.7} = 48.1, {23.1, 16.7, 9.7} = 49.5,
      // {21.5, 13.4, 7.7, 6.2} = 48.8 ⇒ worst 49.5 A is the exact optimum.
      expect(_bruteMinWorst(ib), closeTo(49.5, 1e-9));
      expect(r.demandCurrent.amperes, 49.5);
      expect(r.incomer.breaker.ratingA.amperes, 50);
    });

    test('six ways: the engine never asks to redistribute its own phases', () {
      final r = board(const [6.6, 9.9, 24.9, 15.5, 7.0, 20.6]);
      expect(r.warnings.map((w) => w.code), isNot(contains('phase-imbalance')));
      expect(
          r.demandCurrent.amperes,
          closeTo(
              _bruteMinWorst(const [6.6, 9.9, 24.9, 15.5, 7.0, 20.6]), 1e-9));
    });

    test('property: random unpinned boards hit the exact min worst phase', () {
      for (var seed = 0; seed < 300; seed++) {
        final rnd = math.Random(seed);
        final ib = [
          for (var i = 0; i < 2 + rnd.nextInt(8); i++)
            (10 + rnd.nextInt(240)) / 10.0,
        ];
        final r = board(ib);
        expect(r.demandCurrent.amperes, closeTo(_bruteMinWorst(ib), 0.051),
            reason: 'seed $seed $ib');
        expect(
            r.warnings.map((w) => w.code), isNot(contains('phase-imbalance')),
            reason: 'seed $seed $ib');
      }
    });

    test('a PIN-forced imbalance is still reported as reducible', () {
      // Three equal 10 A ways all pinned to L1: 30 / 0 / 0 A — unpinning is a
      // real action, so the warning (with its unpin wording) still fires.
      final proj = ElectricalProject(
        id: 'p',
        name: 'p',
        earthingSystem: EarthingSystem.tnS,
        panels: [
          ElectricalPanel(id: 'DB', name: 'DB', circuits: [
            for (var i = 0; i < 3; i++)
              ElectricalCircuit(
                id: 'x$i',
                name: 'x$i',
                loadKind: LoadKind.general,
                loadW: 10 * 231 * 0.85,
                cosPhi: 0.85,
                length: const Length(10),
                phaseOverride: PhaseLine.l1,
              ),
          ]),
        ],
      );
      final r = computeSystem(_p, proj).panels['DB']!;
      final w = r.warnings.where((w) => w.code == 'phase-imbalance').single;
      expect(w.message, contains('Unpin the 3 ways pinned'));
    });
  });

  test(
      'elec-props-4 — a balanced board with diversity 0.6 raises no '
      'feeder-below-fed-demand', () {
    final proj = ElectricalProject(
      id: 'p',
      name: 'p',
      earthingSystem: EarthingSystem.tnS,
      panels: [
        ElectricalPanel(
            id: 'MDP', name: 'MDP', circuits: [_feeder('f', 'SDP')]),
        ElectricalPanel(
          id: 'SDP',
          name: 'SDP',
          diversityFactor: 0.6,
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'f',
          circuits: [
            for (var i = 0; i < 3; i++) _way('h$i', 20000, phases: 3),
          ],
        ),
      ],
    );
    final sys = computeSystem(_p, proj);
    // SDP worst phase = 3 × 28.868 A (each way 20 000/(√3·400)) = 86.60 →
    // 86.6 A UNdiversified (Round 43: the exact way currents are summed and
    // rounded once — never 3 × 28.9 = 86.7); the feeder carries the
    // diversified 36 kW ⇒ 36 000/(√3·400) = 51.96 → 52.0 A ⇒ 63 A, judged
    // against 86.60 × 0.6 = 51.96 A (was against the raw 86.6 A ⇒ a false
    // warning).
    expect(sys.panels['SDP']!.demandCurrent.amperes, 86.6);
    final f = sys.panels['MDP']!.circuits.single;
    expect(f.designCurrent.amperes, 52.0);
    expect(sys.panels['MDP']!.warnings.map((w) => w.code),
        isNot(contains('feeder-below-fed-demand')));
  });

  group('elec-props-5 — a breaker override below Ib is flagged', () {
    ElectricalPanelResult run(Current? override) => computeSystem(
          _p,
          ElectricalProject(
            id: 'p',
            name: 'p',
            earthingSystem: EarthingSystem.tnS,
            panels: [
              ElectricalPanel(id: 'DB', name: 'DB', circuits: [
                _way('h', 4000, breakerOverrideA: override),
              ]),
            ],
          ),
        ).panels['DB']!;

    test('4 kW heater (Ib 17.3 A) pinned to 10 A ⇒ warning, override kept', () {
      // Ib = 4000 / (231 × 1.0) = 17.32 A.
      final r = run(const Current(10));
      final c = r.circuits.single;
      expect(c.designCurrent.amperes, 17.3);
      expect(c.breaker.ratingA.amperes, 10);
      final w = r.warnings
          .where((w) => w.code == 'breaker-below-design-current')
          .single;
      expect(w.severity, WarningSeverity.warning);
      expect(w.circuitId, 'h');
      expect(w.message, contains('10 A'));
      expect(w.message, contains('17.3 A'));
    });

    test('an override at or above Ib, or none, raises nothing', () {
      for (final o in [null, const Current(20), const Current(32)]) {
        expect(run(o).warnings.map((w) => w.code),
            isNot(contains('breaker-below-design-current')));
      }
    });
  });
}
