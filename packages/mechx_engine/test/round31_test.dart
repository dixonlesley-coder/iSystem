/// Round 31 seed suite (2026-10-18):
///   * regression-ejector-force-main-walk-stops-at-valve-or-header — the
///     force-main walk passes inline valves and a duplex header, so the
///     static lift is the full rise to the sewer.
///   * stress-edits-1 — the balancePhases relocate pass never double-counts
///     a way after an accepted move (line totals == assigned ways).
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/connectivity.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/ejector.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? component}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: component?.role ?? role,
        component: component);

NetEdge _e(String id, String a, String b, {EdgeKind kind = EdgeKind.run}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.drainage, kind: kind);

// B2 / B1 / L0 at 3.0 m, groundIndex 2: B2 slab -6.0, B1 slab -3.0, L0 0.0.
const _b = BuildingLevels([
  Floor('B2', Length(3)),
  Floor('B1', Length(3)),
  Floor('L0', Length(3)),
], groundIndex: 2);

({double lift, double head}) _duty(Network net, String pump) {
  final fu = <String, double>{};
  final sizing = autoSizeNetwork(net, const SizingContext(),
      leafDemand: const {},
      nodeDrainageUnits: const {'WC': 20},
      fixtureUnitsOut: fu);
  final p = ejectorDutyPoint(
      net: net,
      pumpId: pump,
      sizing: sizing,
      edgeFixtureUnits: fu,
      building: _b,
      calibrationBySheet: const {'s1': ScaleCalibration(0.05)})!;
  return (lift: p.staticLift.meters, head: p.head.meters);
}

void main() {
  group('ejector force main through valves and a duplex header', () {
    // Expected lift, first principles: the pump sits on the B2 slab
    // (-6.0 m, a plant on its own floor surface); the riser top R1 is a
    // bare L0 drainage junction, which reads under its slab = the B1
    // ceiling = 0.0 - 0.3 = -0.3 m. Lift = -0.3 - (-6.0) = 5.70 m — the
    // same whatever inline devices sit on the discharge.
    const expectedLift = 5.70;
    final common = [
      _n('WC', -50, 0, role: NodeRole.fixture),
      _n('PIT', 0, 0, component: NodeComponent.groundTank),
      _n('EJ', 20, 0, component: NodeComponent.pump),
      _n('R1', 40, 0, floor: 2),
      _n('SW', 140, 0, floor: 2),
    ];

    test('plain discharge', () {
      final net = Network(nodes: common, edges: [
        _e('in', 'WC', 'PIT'),
        _e('pe', 'PIT', 'EJ'),
        _e('rs', 'EJ', 'R1', kind: EdgeKind.riser),
        _e('sw', 'R1', 'SW'),
      ]);
      final d = _duty(net, 'EJ');
      expect(d.lift, closeTo(expectedLift, 1e-9));
      expect(d.head, greaterThan(d.lift));
    });

    test('EJ -> check valve -> riser', () {
      final net = Network(nodes: [
        ...common,
        _n('CV', 30, 0, component: NodeComponent.checkValve),
      ], edges: [
        _e('in', 'WC', 'PIT'),
        _e('pe', 'PIT', 'EJ'),
        _e('d1', 'EJ', 'CV'),
        _e('rs', 'CV', 'R1', kind: EdgeKind.riser),
        _e('sw', 'R1', 'SW'),
      ]);
      final d = _duty(net, 'EJ');
      expect(d.lift, closeTo(expectedLift, 1e-9));
      expect(d.head, greaterThan(d.lift));
    });

    test('EJ -> check valve -> gate valve -> riser', () {
      final net = Network(nodes: [
        ...common,
        _n('CV', 26, 0, component: NodeComponent.checkValve),
        _n('GV', 32, 0, component: NodeComponent.gateValve),
      ], edges: [
        _e('in', 'WC', 'PIT'),
        _e('pe', 'PIT', 'EJ'),
        _e('d1', 'EJ', 'CV'),
        _e('d2', 'CV', 'GV'),
        _e('rs', 'GV', 'R1', kind: EdgeKind.riser),
        _e('sw', 'R1', 'SW'),
      ]);
      final d = _duty(net, 'EJ');
      expect(d.lift, closeTo(expectedLift, 1e-9));
      expect(d.head, greaterThan(d.lift));
    });

    test('duplex EJ / EJ2 -> header -> riser: both pumps see the full lift',
        () {
      final net = Network(nodes: [
        ...common,
        _n('EJ2', 20, 20, component: NodeComponent.pump),
        _n('CV1', 26, 0, component: NodeComponent.checkValve),
        _n('CV2', 26, 20, component: NodeComponent.checkValve),
        _n('H', 34, 10),
      ], edges: [
        _e('in', 'WC', 'PIT'),
        _e('pe', 'PIT', 'EJ'),
        _e('pe2', 'PIT', 'EJ2'),
        _e('d1', 'EJ', 'CV1'),
        _e('d2', 'EJ2', 'CV2'),
        _e('h1', 'CV1', 'H'),
        _e('h2', 'CV2', 'H'),
        _e('rs', 'H', 'R1', kind: EdgeKind.riser),
        _e('sw', 'R1', 'SW'),
      ]);
      for (final p in ['EJ', 'EJ2']) {
        final d = _duty(net, p);
        expect(d.lift, closeTo(expectedLift, 1e-9), reason: p);
        expect(d.head, greaterThan(d.lift), reason: p);
      }
    });

    test('a junction receiving gravity drainage ends the force main', () {
      // R1 also receives a gravity branch from an L0 fixture: the force main
      // ends at R1 (the high point), so the lift is still 5.70 m and the
      // walk never runs on along the sewer.
      final net = Network(nodes: [
        ...common,
        _n('FD', 40, 40, floor: 2, role: NodeRole.fixture),
      ], edges: [
        _e('in', 'WC', 'PIT'),
        _e('pe', 'PIT', 'EJ'),
        _e('rs', 'EJ', 'R1', kind: EdgeKind.riser),
        _e('g', 'FD', 'R1'),
        _e('sw', 'R1', 'SW'),
      ]);
      final d = _duty(net, 'EJ');
      expect(d.lift, closeTo(expectedLift, 1e-9));
    });
  });

  group('air open-boundary leaves are not loose ends (hvac-5-2)', () {
    NetNode a(String id, double x, {NodeComponent? c}) => NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: 0,
        floorIndex: 0,
        role: c?.role ?? NodeRole.main,
        component: c);
    NetEdge d(String id, String f, String t,
            [ServiceType s = ServiceType.duct]) =>
        NetEdge(id: id, fromId: f, toId: t, service: s);

    test('AHU -> damper -> bare leaf (intake) and fan -> bare leaf '
        '(discharge) are exempt; a bare junction -> leaf is still loose', () {
      final net = Network(nodes: [
        a('ahu', 0, c: NodeComponent.ahu),
        a('md', 10, c: NodeComponent.motorizedDamper),
        a('oa', 20),
        a('ef', 100, c: NodeComponent.exhaustFan),
        a('out', 110),
        a('j', -10),
        a('loose', -20),
        a('jx', -15),
      ], edges: [
        d('i0', 'ahu', 'md'),
        d('i1', 'md', 'oa'),
        d('x0', 'ef', 'out', ServiceType.exhaust),
        d('s0', 'ahu', 'j'),
        d('s1', 'j', 'loose'),
        d('s2', 'j', 'jx'),
      ]);
      expect(isAirOpenBoundaryLeaf(net, 'oa'), isTrue);
      expect(isAirOpenBoundaryLeaf(net, 'out'), isTrue);
      expect(isAirOpenBoundaryLeaf(net, 'loose'), isFalse);
      final loose = {
        for (final x in networkElementDefects(net))
          if (x.isLooseEnd) x.nodeId,
      };
      expect(loose, {'loose', 'jx'});
    });

    test('a linear diffuser is a supply-air terminal (hvac-5-1)', () {
      expect(isSupplyAirTerminal(NodeComponent.linearDiffuser), isTrue);
      expect(isSupplyAirTerminal(NodeComponent.supplyDiffuser), isTrue);
      expect(isSupplyAirTerminal(NodeComponent.returnGrille), isFalse);
      expect(isSupplyAirTerminal(null), isFalse);
    });
  });

  group('balancePhases relocate keeps line totals == assigned ways', () {
    const p = PuilProfile();
    // A cos phi 1.0 single-phase way of (231 * A) W on a 3ph 400 V board
    // draws A amperes (Vph = round(400 / sqrt 3) = 231 V).
    ElectricalCircuit load(String id, double amps) => ElectricalCircuit(
          id: id,
          name: id,
          loadKind: LoadKind.socket,
          loadW: 231 * amps,
          cosPhi: 1,
          length: const Length(20),
        );

    // The truth the balance must report: each line = the sum of the design
    // currents of the ways assigned to it (3ph ways on all three).
    List<double> trueLines(ElectricalPanelResult r) {
      final l = [0.0, 0.0, 0.0];
      for (final c in r.circuits) {
        final a = c.designCurrent.amperes;
        switch (c.phase) {
          case PhaseAssignment.l1:
            l[0] += a;
          case PhaseAssignment.l2:
            l[1] += a;
          case PhaseAssignment.l3:
            l[2] += a;
          case PhaseAssignment.threePhase:
            l[0] += a;
            l[1] += a;
            l[2] += a;
        }
      }
      return l;
    }

    test('the reported counterexample: 3.6 / 3.1 / 6.6 / 13.2 A', () {
      final panel = ElectricalPanel(id: 'DB', name: 'DB', tag: 'DB', circuits: [
        load('c0', 3.6),
        load('c1', 3.1),
        load('c2', 6.6),
        load('c3', 13.2),
      ]);
      final r = computePanel(p, panel,
          opts: const ComputePanelOptions(priorAssignment: {
            'c0': PhaseAssignment.l2,
            'c1': PhaseAssignment.l3,
            'c2': PhaseAssignment.l1,
            'c3': PhaseAssignment.l1,
          }, phaseReassignThresholdA: 1.0));
      final t = trueLines(r);
      expect(r.phaseBalance.l1, closeTo(t[0], 0.051));
      expect(r.phaseBalance.l2, closeTo(t[1], 0.051));
      expect(r.phaseBalance.l3, closeTo(t[2], 0.051));
      // The 13.2 A way sits on SOME line, so the worst phase is >= 13.2 A and
      // the incomer can never be the 10 A rung the stale totals produced.
      final worst = [r.phaseBalance.l1, r.phaseBalance.l2, r.phaseBalance.l3]
          .reduce(math.max);
      expect(worst, greaterThanOrEqualTo(13.2 - 1e-9));
      expect(r.incomer.breaker.ratingA.amperes, greaterThanOrEqualTo(worst));
    });

    test('seeded property: random currents / priors / threshold', () {
      final rnd = math.Random(31);
      const lines = [
        PhaseAssignment.l1,
        PhaseAssignment.l2,
        PhaseAssignment.l3,
      ];
      for (var seed = 0; seed < 400; seed++) {
        final n = 2 + rnd.nextInt(7);
        final ways = <ElectricalCircuit>[];
        final prior = <String, PhaseAssignment>{};
        for (var i = 0; i < n; i++) {
          final amps = (10 + rnd.nextInt(200)) / 10.0;
          ways.add(load('w$i', amps));
          if (rnd.nextBool()) prior['w$i'] = lines[rnd.nextInt(3)];
        }
        final threshold = [0.0, 0.5, 1.0, 2.0][rnd.nextInt(4)];
        final r = computePanel(
            p, ElectricalPanel(id: 'DB', name: 'DB', tag: 'DB', circuits: ways),
            opts: ComputePanelOptions(
                priorAssignment: prior, phaseReassignThresholdA: threshold));
        final t = trueLines(r);
        // The balance rounds each line to 0.1 A; n ways of 0.1 A-rounded
        // design currents sum within n * 0.05 A + the final 0.05 A rounding.
        final tol = 0.05 * (n + 1) + 1e-9;
        expect(r.phaseBalance.l1, closeTo(t[0], tol), reason: 'seed $seed');
        expect(r.phaseBalance.l2, closeTo(t[1], tol), reason: 'seed $seed');
        expect(r.phaseBalance.l3, closeTo(t[2], tol), reason: 'seed $seed');
      }
    });
  });
}
