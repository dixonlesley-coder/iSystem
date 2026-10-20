/// Round 36 (2026-10-18) — engine seed suite.
///
///  1. mech-props-5-duplex-mixed-valve-split — a duty/standby pump set with a
///     check valve drawn on only SOME legs is the same Round-13 parallel set
///     as with the valves on every leg or on none: every leg on the full set
///     flow, the standby legs mirrored (was a Hardy–Cross 50/50 split).
///  2. regression-genset-1ph-essential-board-per-phase (+ the duplicates
///     elec-props-4-genset-phase-1ph-essential-board / printed-parity-3-1) —
///     a 1φ essential board on a 3φ supply contributes √3·400·I to the
///     alternator's per-phase rating, never 230·I.
///  3. elec-props-4-genset-dip-skips-motors-full-backup — a full-backup set
///     screens every motor even when a board is designated essential.
///  4. elec-props-4-stale-motorkw-after-rekind — an HVAC way sizes its
///     starter / genset dip / PF kW on loadW, never a stray motorKw.
///  5. elec-props-4-tt-rcd-ladder-saturates — an exhausted TT feeder RCD
///     ladder never claims discrimination and raises tt-rcd-not-selective.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/power_factor.dart';
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

NetNode _n(String id, double x, double y,
        {int floor = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b,
        {EdgeKind k = EdgeKind.run, ServiceType s = ServiceType.coldWater}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

const _sni = SniProfile();
double _curve(double ubap) =>
    _sni.probableFlowForFixtureUnits(ubap).inLitersPerSecond;

/// Cold water: GT -> P_i -> [C_i ->] HDR for i = 1..[pumps] (a check valve
/// only on the legs in [valved]), HDR -> 4-floor riser with a 4-UBAP fixture
/// per floor.
Network _pumpSet(Set<int> valved, {int pumps = 2}) {
  final nodes = <NetNode>[
    _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('HDR', 100, 0),
  ];
  final edges = <NetEdge>[];
  for (var i = 1; i <= pumps; i++) {
    nodes.add(
        _n('P$i', 50, 20.0 * i, role: NodeRole.plant, c: NodeComponent.pump));
    edges.add(_e('h$i', 'GT', 'P$i'));
    if (valved.contains(i)) {
      nodes.add(_n('C$i', 75, 20.0 * i, c: NodeComponent.checkValve));
      edges
        ..add(_e('p$i', 'P$i', 'C$i'))
        ..add(_e('c$i', 'C$i', 'HDR'));
    } else {
      edges.add(_e('p$i', 'P$i', 'HDR'));
    }
  }
  for (var f = 0; f < 4; f++) {
    nodes
      ..add(_n('S$f', 150, 0, floor: f))
      ..add(_n('fx$f', 190, 0, floor: f, role: NodeRole.fixture));
    edges.add(_e('b$f', 'S$f', 'fx$f'));
    edges.add(f == 0
        ? _e('m', 'HDR', 'S0')
        : _e('s$f', 'S${f - 1}', 'S$f', k: EdgeKind.riser));
  }
  return Network(nodes: nodes, edges: edges);
}

/// A 3φ 400 V MDP carrying [mdpLoads] plus a 2P feeder on L1 to a 1φ 230 V
/// ESSENTIAL board EP with one [epW] W heater (cos φ 1).
ElectricalProject _essential1ph({
  required List<ElectricalCircuit> mdpLoads,
  required double epW,
  required GeneratorSource gen,
}) =>
    ElectricalProject(
      sources: ElectricalSources(generator: gen),
      panels: [
        ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
          ...mdpLoads,
          const ElectricalCircuit(
            id: 'f-ep',
            name: 'EP',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'ep',
            phases: 1,
            phaseOverride: PhaseLine.l1,
            length: Length(10),
          ),
        ]),
        ElectricalPanel(
          id: 'ep',
          name: 'EP',
          system: ElectricalSystem.singlePhase,
          voltage: const Voltage(230),
          essential: true,
          circuits: [
            ElectricalCircuit(
              id: 'ep-h',
              name: 'Heater',
              loadKind: LoadKind.heating,
              loadW: epW,
              cosPhi: 1.0,
              phases: 1,
              length: const Length(10),
            ),
          ],
        ),
      ],
    );

ElectricalCircuit _heater3(String id, double w) => ElectricalCircuit(
      id: id,
      name: 'Heater $id',
      loadKind: LoadKind.heating,
      loadW: w,
      cosPhi: 1.0,
      phases: 3,
      length: const Length(10),
    );

double _perPhase(double va) => va / (math.sqrt(3) * 400);

// The system list aggregates every panel's circuit warnings.
List<ElectricalWarning> _allWarnings(ElectricalSystemResult sys) =>
    sys.warnings;

void main() {
  group('1 — a mixed-valve duty/standby pump set', () {
    test(
        'valves on every subset of the legs (2 and 3 pumps), calibrated or '
        'not: every leg carries the full set flow curve(16) = 0.6533 L/s at '
        'DN25 (DN20: 4Q/(pi D^2) = 2.08 m/s > 2.0); the standby legs are the '
        'mirrored legs (was 0.339/0.314 L/s DN15 with the valve on P1 only)',
        () {
      expect(_curve(16), closeTo(0.6533, 1e-4));
      expect(4 * 0.6533e-3 / (math.pi * 0.02 * 0.02), greaterThan(2.0));
      for (final pumps in [2, 3]) {
        final subsets = <Set<int>>[
          for (var mask = 0; mask < (1 << pumps); mask++)
            {
              for (var i = 1; i <= pumps; i++)
                if (mask & (1 << (i - 1)) != 0) i,
            },
        ];
        for (final valved in subsets) {
          for (final cal in [false, true]) {
            final why = 'pumps=$pumps valved=$valved cal=$cal';
            final par = <String>{};
            final s = autoSizeNetwork(
              _pumpSet(valved, pumps: pumps),
              const SizingContext(),
              leafDemand: {ServiceType.coldWater: const FlowRate(0)},
              leafFixtureUnits: {ServiceType.coldWater: 4},
              building: cal
                  ? BuildingLevels([
                      for (var i = 0; i < 4; i++)
                        const Floor('L', Length(3.0))
                    ])
                  : null,
              calibrationBySheet:
                  cal ? const {'s1': ScaleCalibration(0.05)} : const {},
              parallelLegEdgeIdsOut: par,
            );
            for (var i = 1; i <= pumps; i++) {
              for (final id in ['h$i', 'p$i', if (valved.contains(i)) 'c$i']) {
                expect(s[id]!.flow.inLitersPerSecond, closeTo(_curve(16), 1e-9),
                    reason: '$why $id');
                expect(s[id]!.diameter.inMillimeters.round(), 25,
                    reason: '$why $id');
              }
              expect(s['p$i']!.flowFromId, 'P$i', reason: why);
            }
            expect(s['m']!.flow.inLitersPerSecond, closeTo(_curve(16), 1e-9),
                reason: why);
            expect(
                par,
                {
                  for (var i = 2; i <= pumps; i++) ...[
                    'h$i',
                    'p$i',
                    if (valved.contains(i)) 'c$i',
                  ],
                },
                reason: why);
          }
        }
      }
    });
  });

  group('2 — a 1φ essential board on a 3φ genset', () {
    // 3φ MDP with 3 x 10 kW 3φ heaters + a feeder on L1 to a 1φ 230 V
    // essential EP carrying 7 kW (cos φ 1), backupFraction 0.1:
    //   EP I = 7000 / 230 = 30.43 A (carried at 0.1 A: 30.4 A), ALL on L1
    //   of the 3φ alternator, rated S / (√3·400) per phase, so the need is
    //   √3·400·30.4 = 21 062 VA (not 230·30.4 = 6 992 VA) => the 25 kVA rung
    //   (36.1 A per phase). The fraction term: MDP L1 = 43.3 + 30.4 = 73.7 A
    //   => 0.1 x √3·400·73.7 = 5.1 kVA (never governs).
    ElectricalProject probe({ApparentPower? kva}) => _essential1ph(
          mdpLoads: [
            for (var i = 0; i < 3; i++) _heater3('h$i', 10000),
          ],
          epW: 7000,
          gen: GeneratorSource(kva: kva, backupFraction: 0.1),
        );

    test('need = √3·400·I(EP) ≈ 21.06 kVA => the 25 kVA set', () {
      final p = probe();
      final sys = computeSystem(_p, p);
      final iEp = sys.panels['ep']!.diversifiedDemandCurrent.amperes;
      expect(iEp, closeTo(7000 / 230, 0.06));
      final need = gensetBackupDemandVa(p, sys).voltAmperes;
      expect(need, closeTo(math.sqrt(3) * 400 * iEp, 1));
      expect(need, greaterThan(21000));
      final g = sizeGenerator(gensetBackupDemandVa(p, sys),
          backupPower: gensetBackupDemandW(p, sys));
      expect(g.ratingKva.inKilovoltAmperes, 25);
      expect(_perPhase(g.ratingKva.voltAmperes), greaterThanOrEqualTo(iEp));
      // Every printed surface reads the same basis — the power one-line's
      // generator node prints the corrected rung.
      final study = computeAdvancedStudy(_p, p, sys);
      final genNode = study.powerOneLine!.nodeOfKind(PowerNodeKind.generator)!;
      expect(genNode.sub, startsWith('25 kVA'));
    });

    test('a forced 10 kVA nameplate (14.4 A per phase) raises '
        'genset-phase-overload', () {
      final p = probe(kva: const ApparentPower(10000));
      final w = gensetBackupWarnings(p, computeSystem(_p, p));
      expect(w.map((x) => x.code), contains('genset-phase-overload'));
    });

    test('9.2 kW EP at backupFraction 0.3 beside a 30 kW 3φ heater: need '
        '√3·400·40.0 = 27.7 kVA => the 33 kVA ladder rung (was 20 kVA)', () {
      // EP I = 9200 / 230 = 40.0 A; MDP L1 = 43.3 + 40.0 = 83.3 A =>
      // 0.3 x √3·400·83.3 = 17.3 kVA (the old answer) < 27.7 kVA.
      final p = _essential1ph(
          mdpLoads: [_heater3('h0', 30000)],
          epW: 9200,
          gen: const GeneratorSource(backupFraction: 0.3));
      final sys = computeSystem(_p, p);
      final need = gensetBackupDemandVa(p, sys).voltAmperes;
      expect(need, closeTo(math.sqrt(3) * 400 * 40.0, 1));
      final g = sizeGenerator(gensetBackupDemandVa(p, sys),
          backupPower: gensetBackupDemandW(p, sys));
      // The genset ladder's first rung >= 27.7 kVA is 33 kVA (33 000 /
      // (√3·400) = 47.6 A per phase >= 40.0 A); the old 20 kVA set was 28.9 A per phase.
      expect(g.ratingKva.inKilovoltAmperes, 33);
      expect(_perPhase(g.ratingKva.voltAmperes), greaterThanOrEqualTo(40.0));
    });

    test('a balanced 3φ essential board is unchanged (per-phase <= demand)',
        () {
      // A 3φ essential sub-board with a 10 kW 3φ heater: 14.43 A per line
      // (carried 14.4 A) => √3·400·14.4 = 9 977 VA < the 10 000 VA demand,
      // so the need stays the balanced 10 000 VA.
      final p = ElectricalProject(
        sources: const ElectricalSources(
            generator: GeneratorSource(backupFraction: 0.1)),
        panels: [
          ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
            _heater3('h0', 30000),
            const ElectricalCircuit(
                id: 'f',
                name: 'EP3',
                loadKind: LoadKind.feeder,
                feedsPanelId: 'ep3',
                length: Length(10)),
          ]),
          ElectricalPanel(
              id: 'ep3',
              name: 'EP3',
              essential: true,
              circuits: [_heater3('x', 10000)]),
        ],
      );
      final sys = computeSystem(_p, p);
      expect(gensetBackupDemandVa(p, sys).voltAmperes,
          closeTo(essentialDemandVa(p, sys), 1e-6));
      expect(essentialDemandVa(p, sys), closeTo(10000, 1));
    });
  });

  group('3 — the genset dip screen on a full-backup set', () {
    // MDP: 110 kW DOL chiller + 60 kW general + a feeder to FP (5.5 kW DOL
    // jockey). Full backup (backupFraction 1.0) ⇒ the whole bus transfers,
    // the set starts the chiller: 110 / 0.8 x 6 = 825 kVA starting.
    ElectricalProject chiller({required bool fpEssential, double frac = 1.0}) =>
        ElectricalProject(
          sources: ElectricalSources(
              generator: GeneratorSource(backupFraction: frac)),
          panels: [
            const ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
              ElectricalCircuit(
                  id: 'ch',
                  name: 'Chiller',
                  loadKind: LoadKind.motor,
                  motorKw: 110,
                  phases: 3,
                  starterType: StarterType.dol,
                  length: Length(20)),
              ElectricalCircuit(
                  id: 'g',
                  name: 'General',
                  loadW: 60000,
                  phases: 3,
                  length: Length(20)),
              ElectricalCircuit(
                  id: 'f',
                  name: 'FP',
                  loadKind: LoadKind.feeder,
                  feedsPanelId: 'fp',
                  length: Length(20)),
            ]),
            ElectricalPanel(
                id: 'fp',
                name: 'FP',
                essential: fpEssential,
                circuits: const [
                  ElectricalCircuit(
                      id: 'j',
                      name: 'Jockey',
                      loadKind: LoadKind.pump,
                      motorKw: 5.5,
                      phases: 3,
                      starterType: StarterType.dol,
                      lifeSafety: true,
                      cableType: 'FRC',
                      length: Length(20)),
                ]),
          ],
        );

    test('marking the fire-pump board essential keeps the chiller screened', () {
      for (final ess in [false, true]) {
        final p = chiller(fpEssential: ess);
        expect(gensetStartMotors(p).map((m) => m.name),
            containsAll(['Chiller', 'Jockey']),
            reason: 'essential=$ess');
        final study = computeAdvancedStudy(_p, p, computeSystem(_p, p));
        final sub =
            study.powerOneLine!.nodeOfKind(PowerNodeKind.generator)!.sub!;
        expect(sub, contains('start dip'), reason: 'essential=$ess: $sub');
      }
    });

    test('a fractional set with FP essential still screens only the jockey '
        '(Round 11 behaviour)', () {
      final p = chiller(fpEssential: true, frac: 0.3);
      expect(gensetStartMotors(p).map((m) => m.name), ['Jockey']);
    });
  });

  group('4 — a stray motorKw on a re-kinded HVAC way', () {
    // An HVAC way carrying a hidden motorKw 30 (left by re-kinding a motor)
    // and loadW 5 000: compute sizes it on 5 kW, so the starter, the genset
    // dip and the PF kW must too.
    ElectricalProject rekinded({String? sourceEquipmentId}) =>
        ElectricalProject(
          sources: const ElectricalSources(generator: GeneratorSource()),
          panels: [
            ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
              ElectricalCircuit(
                  id: 'c',
                  name: 'Chiller',
                  loadKind: LoadKind.hvac,
                  loadW: 5000,
                  motorKw: 30,
                  phases: 3,
                  starterType: StarterType.dol,
                  sourceEquipmentId: sourceEquipmentId,
                  length: const Length(20)),
            ]),
          ],
        );

    test('starter, dip motor and PF kW all read 5 kW', () {
      final p = rekinded();
      final sys = computeSystem(_p, p);
      final study = computeAdvancedStudy(_p, p, sys);
      expect(study.controlAssemblies['c']!.motor!.kw, closeTo(5, 1e-9));
      expect(gensetStartMotors(p).single.shaftPower.inKiloWatts,
          closeTo(5, 1e-9));
      expect(powerFactorCorrection(sys, p).totalKw, closeTo(5, 1e-9));
    });

    test('an MEP-derived HVAC way keeps its machine motorKw for the dip', () {
      final p = rekinded(sourceEquipmentId: 'ahu-1');
      expect(gensetStartMotors(p).single.shaftPower.inKiloWatts,
          closeTo(30, 1e-9));
    });
  });

  group('5 — an exhausted TT feeder RCD ladder', () {
    // A TT chain P0 -> P1 -> ... -> P(n-1), each board a 2 kW socket + the
    // feeder to the next. Levels below f_k = n - 2 - k:
    //   f(n-2) 300 mA, then 1000, 3000, 10 000, 10 000 (clamped).
    ElectricalProject chain(int n) => ElectricalProject(
          earthingSystem: EarthingSystem.tt,
          panels: [
            for (var k = 0; k < n; k++)
              ElectricalPanel(id: 'P$k', name: 'P$k', circuits: [
                ElectricalCircuit(
                    id: 's$k',
                    name: 'Socket $k',
                    loadKind: LoadKind.socket,
                    loadW: 2000,
                    phases: 1,
                    length: const Length(20)),
                if (k < n - 1)
                  ElectricalCircuit(
                      id: 'f$k',
                      name: 'Feeder $k',
                      loadKind: LoadKind.feeder,
                      feedsPanelId: 'P${k + 1}',
                      length: const Length(20)),
              ]),
          ],
        );

    RcdSpec rcdOf(ElectricalSystemResult sys, String panel, String id) =>
        sys.panels[panel]!.circuits.firstWhere((c) => c.circuitId == id).rcd;

    test('ladder selectivity: 3 x IΔn holds through level 3 only', () {
      expect(ttFeederRcdSelective(0), isTrue);
      expect(ttFeederRcdSelective(1), isTrue); // 1000 >= 3 x 300
      expect(ttFeederRcdSelective(2), isTrue); // 3000 >= 3 x 1000
      expect(ttFeederRcdSelective(3), isTrue); // 10000 >= 3 x 3000
      expect(ttFeederRcdSelective(4), isFalse); // 10000 < 3 x 10000
    });

    test('6-board chain: f0 and f1 both 10 000 mA; f0 is named and never '
        'claims the 3 x ratio', () {
      final sys = computeSystem(_p, chain(6));
      expect(rcdOf(sys, 'P1', 'f1').ratingMa, 10000);
      final f0 = rcdOf(sys, 'P0', 'f0');
      expect(f0.ratingMa, 10000);
      expect(f0.reason, contains('NOT achievable'));
      expect(f0.reason, isNot(contains('≥ 3 × the 10000 mA time-delayed')));
      final w = _allWarnings(sys)
          .where((x) => x.code == 'tt-rcd-not-selective')
          .toList();
      expect(w.map((x) => x.circuitId), ['f0']);
      expect(w.single.panelId, 'P0');
    });

    test('a 5-board chain is selective and warning-free', () {
      final sys = computeSystem(_p, chain(5));
      expect(rcdOf(sys, 'P0', 'f0').ratingMa, 10000);
      expect(rcdOf(sys, 'P1', 'f1').ratingMa, 3000);
      expect(
          _allWarnings(sys).where((x) => x.code == 'tt-rcd-not-selective'),
          isEmpty);
    });
  });
}
