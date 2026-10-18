// Round 15 (2026-10-18) — regression + root-metamorphic mechanical findings,
// each pinned with a first-principles derivation and (where it fits) a seeded
// renaming / drawing-direction property (the round-7 determinism contract):
//   inline-fan-lets-fcu-root      a terminal FCU never roots a fan-driven duct;
//   parallel-source-mirror-fcus   an FCU stub is never a parallel source;
//   rain-multi-downpipe           two downpipes split the collector, no phantom;
//   cv-undirected-dutystandby     a valve drawn ambiguously is oriented by
//                                 topology, duty/standby legs keep the set flow;
//   pdam-fill-phantom             a GWT's fill line is an inlet, not a draw-off;
//   return-exhaust-flow-reversed  extract air flows TOWARD the fan.
import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/duct_static.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? component,
        FlowRate? airflow}) =>
    NetNode(
      id: id,
      sheetId: 's1',
      x: x,
      y: y,
      floorIndex: floor,
      role: role,
      component: component,
      airflow: airflow,
    );

NetEdge _e(String id, String a, String b, ServiceType s,
        {EdgeKind kind = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: kind);

double _curve(double ubap) => const SniProfile()
    .probableFlowForFixtureUnits(ubap)
    .inLitersPerSecond;

/// A seeded random renaming of [ids] whose string order differs from the
/// logical order (`n10` < `n9`).
Map<String, String> _rename(List<String> ids, int seed) {
  final rnd = math.Random(seed);
  final names = [
    for (var i = 0; i < ids.length; i++) 'n${rnd.nextInt(90) + 1}x$i',
  ]..shuffle(rnd);
  return {for (var i = 0; i < ids.length; i++) ids[i]: names[i]};
}

List<T> _shuffled<T>(List<T> xs, int seed) =>
    [...xs]..shuffle(math.Random(seed));

void main() {
  group('inline-fan-lets-fcu-root — a terminal FCU never roots the duct', () {
    // OA (bare intake leaf) → AF (inline supply fan) → J; J → d0, d1 (supply
    // diffusers 0.1 m³/s each) and J → F1 (FCU, airflow 0.1, degree 1).
    const q = FlowRate(0.1);
    const ids = ['OA', 'AF', 'J', 'd0', 'd1', 'F1'];
    Network build(Map<String, String> r) {
      String m(String id) => r[id] ?? id;
      return Network(nodes: [
        _n(m('OA'), 0, 0),
        _n(m('AF'), 40, 0,
            role: NodeRole.plant, component: NodeComponent.supplyFan),
        _n(m('J'), 80, 0),
        _n(m('d0'), 120, -20,
            role: NodeRole.fixture,
            component: NodeComponent.supplyDiffuser,
            airflow: q),
        _n(m('d1'), 120, 20,
            role: NodeRole.fixture,
            component: NodeComponent.supplyDiffuser,
            airflow: q),
        _n(m('F1'), 80, 60,
            role: NodeRole.plant, component: NodeComponent.fcu, airflow: q),
      ], edges: [
        _e('oa', m('OA'), m('AF'), ServiceType.duct),
        _e('sj', m('AF'), m('J'), ServiceType.duct),
        _e('j0', m('J'), m('d0'), ServiceType.duct),
        _e('j1', m('J'), m('d1'), ServiceType.duct),
        _e('jf', m('J'), m('F1'), ServiceType.duct),
      ]);
    }

    test('sj carries 0.1 + 0.1 + 0.1 = 0.3 m³/s from AF under ANY ids', () {
      for (var seed = 0; seed < 30; seed++) {
        final r = seed == 0 ? const <String, String>{} : _rename(ids, seed);
        String m(String id) => r[id] ?? id;
        final net = build(r);
        final demand = {m('d0'): q, m('d1'): q, m('F1'): q};
        final s = autoSizeNetwork(
            Network(nodes: net.nodes, edges: _shuffled(net.edges, seed)),
            const SizingContext(),
            leafDemand: const {ServiceType.duct: FlowRate(0.03)},
            nodeFlowDemand: demand);
        // Σ every terminal (two diffusers + the FCU's own airflow) = 0.3 m³/s
        // through the fan discharge AND the intake (was 0.03, Ø100).
        expect(s['sj']!.flow.cubicMetersPerSecond, closeTo(0.3, 1e-12),
            reason: 'seed $seed');
        expect(s['oa']!.flow.cubicMetersPerSecond, closeTo(0.3, 1e-12),
            reason: 'seed $seed');
        expect(s['sj']!.flowFromId, m('AF'), reason: 'seed $seed');
        // The FCU branch carries its own 0.1 m³/s, flowing INTO the unit.
        expect(s['jf']!.flow.cubicMetersPerSecond, closeTo(0.1, 1e-12),
            reason: 'seed $seed');
        expect(s['jf']!.flowFromId, m('J'), reason: 'seed $seed');
        final roots = serviceComponentRoots(net, ServiceType.duct,
            demandNodeIds: demand.keys.toSet());
        expect(roots[m('F1')], isNot(m('F1')), reason: 'seed $seed');
      }
    });

    test('a stand-alone FCU still roots its own diffuser run', () {
      // F1 (FCU, no airflow) → J → d0, d1 (0.1 each): the trunk carries 0.2
      // from the FCU (no other source exists).
      final net = Network(nodes: [
        _n('F1', 0, 0, role: NodeRole.plant, component: NodeComponent.fcu),
        _n('J', 40, 0),
        _n('d0', 80, -20, role: NodeRole.fixture, airflow: q),
        _n('d1', 80, 20, role: NodeRole.fixture, airflow: q),
      ], edges: [
        _e('fj', 'F1', 'J', ServiceType.duct),
        _e('j0', 'J', 'd0', ServiceType.duct),
        _e('j1', 'J', 'd1', ServiceType.duct),
      ]);
      final s = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {ServiceType.duct: FlowRate(0.03)},
          nodeFlowDemand: const {'d0': q, 'd1': q});
      expect(s['fj']!.flow.cubicMetersPerSecond, closeTo(0.2, 1e-12));
      expect(s['fj']!.flowFromId, 'F1');
    });
  });

  group('parallel-source-mirror — FCU stubs are not parallel sources', () {
    // PAU (ahu, degree 1) → J1 → J2; FCUs F0/F1 on J1, F2/F3 on J2, each an
    // explicit 0.05 m³/s. Trunk pj = 4 × 0.05 = 0.2; j12 = 2 × 0.05 = 0.1;
    // every stub its own 0.05, flowing FROM its junction; no mirrored legs.
    const q = FlowRate(0.05);
    test('each stub keeps 0.05 m³/s from the junction, any ids', () {
      const ids = ['PAU', 'J1', 'J2', 'F0', 'F1', 'F2', 'F3'];
      for (var seed = 0; seed < 30; seed++) {
        final r = seed == 0
            ? const <String, String>{}
            : seed == 1
                ? {'PAU': 'A0'}
                : _rename(ids, seed);
        String m(String id) => r[id] ?? id;
        final net = Network(nodes: [
          _n(m('PAU'), 0, 0,
              role: NodeRole.plant, component: NodeComponent.ahu),
          _n(m('J1'), 100, 0),
          _n(m('J2'), 200, 0),
          for (var i = 0; i < 4; i++)
            _n(m('F$i'), 100.0 + (i ~/ 2) * 100, i.isEven ? -50 : 50,
                role: NodeRole.plant, component: NodeComponent.fcu,
                airflow: q),
        ], edges: [
          _e('pj', m('PAU'), m('J1'), ServiceType.duct),
          _e('j12', m('J1'), m('J2'), ServiceType.duct),
          for (var i = 0; i < 4; i++)
            _e('s$i', m(i < 2 ? 'J1' : 'J2'), m('F$i'), ServiceType.duct),
        ]);
        final legs = <String>{};
        final s = autoSizeNetwork(net, const SizingContext(),
            leafDemand: const {ServiceType.duct: FlowRate(0.03)},
            nodeFlowDemand: {for (var i = 0; i < 4; i++) m('F$i'): q},
            parallelLegEdgeIdsOut: legs);
        expect(legs, isEmpty, reason: 'seed $seed');
        expect(s['pj']!.flow.cubicMetersPerSecond, closeTo(0.2, 1e-12),
            reason: 'seed $seed');
        expect(s['pj']!.flowFromId, m('PAU'), reason: 'seed $seed');
        expect(s['j12']!.flow.cubicMetersPerSecond, closeTo(0.1, 1e-12),
            reason: 'seed $seed');
        for (var i = 0; i < 4; i++) {
          expect(s['s$i']!.flow.cubicMetersPerSecond, closeTo(0.05, 1e-12),
              reason: 'seed $seed s$i');
          expect(s['s$i']!.flowFromId, m(i < 2 ? 'J1' : 'J2'),
              reason: 'seed $seed s$i');
        }
      }
    });
  });

  group('rain-multi-downpipe — two outfalls split the roof collector', () {
    // Roof (floor 3): RD0→A, RD1→C1, RD2→C2, RD3→B on the collector
    // A–C1–C2–B; downpipes A→O1 and B→O2 (risers) to bare grade outlets on
    // floor 0. 2 L/s per drain ⇒ 8 L/s total, each drain to its NEAREST
    // outfall: RD0+RD1 → O1 (4 L/s), RD2+RD3 → O2 (4 L/s).
    const ids = ['RD0', 'RD1', 'RD2', 'RD3', 'A', 'C1', 'C2', 'B', 'O1', 'O2'];
    Network build(Map<String, String> r) {
      String m(String id) => r[id] ?? id;
      return Network(nodes: [
        for (var i = 0; i < 4; i++)
          _n(m('RD$i'), i * 100.0, -40,
              floor: 3,
              role: NodeRole.fixture,
              component: NodeComponent.roofDrain),
        _n(m('A'), 0, 0, floor: 3),
        _n(m('C1'), 100, 0, floor: 3),
        _n(m('C2'), 200, 0, floor: 3),
        _n(m('B'), 300, 0, floor: 3),
        _n(m('O1'), 0, 0),
        _n(m('O2'), 300, 0),
      ], edges: [
        _e('r0', m('RD0'), m('A'), ServiceType.rainwater),
        _e('r1', m('RD1'), m('C1'), ServiceType.rainwater),
        _e('r2', m('RD2'), m('C2'), ServiceType.rainwater),
        _e('r3', m('RD3'), m('B'), ServiceType.rainwater),
        _e('ac', m('A'), m('C1'), ServiceType.rainwater),
        _e('cc', m('C1'), m('C2'), ServiceType.rainwater),
        _e('bc', m('C2'), m('B'), ServiceType.rainwater),
        _e('d1', m('A'), m('O1'), ServiceType.rainwater, kind: EdgeKind.riser),
        _e('d2', m('B'), m('O2'), ServiceType.rainwater, kind: EdgeKind.riser),
      ]);
    }

    test('no phantom load, both downpipes flow down, sizes name-blind', () {
      const perDrain = 0.002; // m³/s = 2 L/s
      for (var seed = 0; seed < 50; seed++) {
        final r = seed == 0 ? const <String, String>{} : _rename(ids, seed);
        String m(String id) => r[id] ?? id;
        final net = build(r);
        final s = autoSizeNetwork(
            Network(nodes: net.nodes, edges: _shuffled(net.edges, seed)),
            const SizingContext(),
            leafDemand: const {ServiceType.rainwater: FlowRate(perDrain)});
        // Each downpipe 2 × 2 = 4 L/s (was 10 / 2 by node id), flowing DOWN.
        expect(s['d1']!.flow.cubicMetersPerSecond, closeTo(2 * perDrain, 1e-12),
            reason: 'seed $seed');
        expect(s['d2']!.flow.cubicMetersPerSecond, closeTo(2 * perDrain, 1e-12),
            reason: 'seed $seed');
        expect(s['d1']!.flowFromId, m('A'), reason: 'seed $seed');
        expect(s['d2']!.flowFromId, m('B'), reason: 'seed $seed');
        // Total discharged = 4 drains × 2 L/s (no phantom outfall load).
        expect(
            s['d1']!.flow.cubicMetersPerSecond +
                s['d2']!.flow.cubicMetersPerSecond,
            closeTo(4 * perDrain, 1e-12),
            reason: 'seed $seed');
        // Collector legs carry their own drain toward the downpipe heads.
        expect(s['ac']!.flow.cubicMetersPerSecond, closeTo(perDrain, 1e-12));
        expect(s['bc']!.flow.cubicMetersPerSecond, closeTo(perDrain, 1e-12));
        expect(s['ac']!.flowFromId, m('C1'), reason: 'seed $seed');
        expect(s['bc']!.flowFromId, m('C2'), reason: 'seed $seed');
        expect(s['d1']!.diameter.inMillimeters,
            s['d2']!.diameter.inMillimeters,
            reason: 'seed $seed');
        // The drainage divide (C1–C2) is a closing edge: conservatively sized
        // on its larger neighbour and flagged provisional.
        expect(s['cc']!.loopUnbalanced, isTrue, reason: 'seed $seed');
      }
    });

    test('a single downpipe is unchanged (one outfall, no split)', () {
      final net = Network(nodes: [
        _n('RD0', 0, -40, floor: 1,
            role: NodeRole.fixture, component: NodeComponent.roofDrain),
        _n('RD1', 100, -40, floor: 1,
            role: NodeRole.fixture, component: NodeComponent.roofDrain),
        _n('A', 0, 0, floor: 1),
        _n('C', 100, 0, floor: 1),
        _n('O', 0, 0),
      ], edges: [
        _e('r0', 'RD0', 'A', ServiceType.rainwater),
        _e('r1', 'RD1', 'C', ServiceType.rainwater),
        _e('ac', 'A', 'C', ServiceType.rainwater),
        _e('d', 'A', 'O', ServiceType.rainwater, kind: EdgeKind.riser),
      ]);
      final s = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {ServiceType.rainwater: FlowRate(0.002)});
      expect(s['d']!.flow.cubicMetersPerSecond, closeTo(0.004, 1e-12));
      expect(s['d']!.loopUnbalanced, isFalse);
    });
  });

  group('cv-undirected — duty/standby legs survive any drawing direction', () {
    // GT → S; S → P1 → C1 → H and S → P2 → C2 → H; H → 4 fixtures × 2 UBAP.
    // A standby pump is a full-duty machine: BOTH legs carry curve(8 UBAP)
    // = 0.400 L/s; one leg is recorded as the mirrored parallel leg.
    test('every valve-edge drawing state and edge flip gives the same set', () {
      final q = _curve(8);
      expect(q, closeTo(0.400, 5e-4));
      // DN15 at 0.40 L/s would be v = 4Q/(πD²) = 2.26 m/s, over the 2.0 cap.
      expect(4 * 0.40e-3 / (math.pi * 0.015 * 0.015), closeTo(2.26, 5e-3));
      final rnd = math.Random(15);
      for (var trial = 0; trial < 60; trial++) {
        // Each valve: 0 = drawn in→out, 1 = in-edge reversed (both out),
        // 2 = out-edge reversed (both in). Plus random flips of the rest.
        final v1 = trial == 0 ? 0 : rnd.nextInt(3);
        final v2 = trial == 0 ? 2 : rnd.nextInt(3);
        bool flip() => trial > 1 && rnd.nextBool();
        NetEdge e(String id, String a, String b, bool rev) =>
            rev ? _e(id, b, a, ServiceType.coldWater)
                : _e(id, a, b, ServiceType.coldWater);
        final net = Network(nodes: [
          _n('GT', 0, 0,
              role: NodeRole.plant, component: NodeComponent.groundTank),
          _n('S', 40, 0),
          _n('P1', 80, -20,
              role: NodeRole.plant, component: NodeComponent.pump),
          _n('P2', 80, 20,
              role: NodeRole.plant, component: NodeComponent.pump),
          _n('C1', 120, -20, component: NodeComponent.checkValve),
          _n('C2', 120, 20, component: NodeComponent.checkValve),
          _n('H', 160, 0),
          for (var i = 0; i < 4; i++)
            _n('f$i', 240, i * 30.0, role: NodeRole.fixture),
        ], edges: [
          e('gs', 'GT', 'S', flip()),
          e('s1', 'S', 'P1', flip()),
          e('s2', 'S', 'P2', flip()),
          e('pc1', 'P1', 'C1', v1 == 1),
          e('ch1', 'C1', 'H', v1 == 2),
          e('pc2', 'P2', 'C2', v2 == 1),
          e('ch2', 'C2', 'H', v2 == 2),
          for (var i = 0; i < 4; i++) e('b$i', 'H', 'f$i', flip()),
        ]);
        final legs = <String>{};
        final s = autoSizeNetwork(net, const SizingContext(),
            leafDemand: const {ServiceType.coldWater: FlowRate(0)},
            leafFixtureUnits: const {ServiceType.coldWater: 2.0},
            parallelLegEdgeIdsOut: legs);
        for (final id in ['gs', 's1', 's2', 'pc1', 'pc2', 'ch1', 'ch2']) {
          expect(s[id]!.flow.inLitersPerSecond, closeTo(q, 1e-9),
              reason: 'trial $trial ($v1/$v2) $id');
        }
        expect(s['pc1']!.diameter.inMillimeters,
            s['pc2']!.diameter.inMillimeters);
        expect(s['ch2']!.diameter.inMillimeters, greaterThan(15),
            reason: 'trial $trial');
        // The standby leg (C2, after C1 by id) is the mirrored one.
        expect(legs, {'s2', 'pc2', 'ch2'}, reason: 'trial $trial');
        // Both discharges flow pump → header whatever the drawing.
        expect(s['ch1']!.flowFromId, 'C1', reason: 'trial $trial');
        expect(s['ch2']!.flowFromId, 'C2', reason: 'trial $trial');
      }
    });
  });

  group('pdam-fill — a ground tank\'s fill line is an inlet', () {
    // PDAM (bare leaf) → GT (inline ground tank) → P → H → 6 fixtures × 2
    // UBAP. The fill pipe pg carries no draw-off (0 UBAP) and is oriented
    // INTO the tank; the suction gp carries curve(12).
    test('pg has no phantom load and points into the tank', () {
      final net = Network(nodes: [
        _n('PDAM', 0, 0),
        _n('GT', 40, 0,
            role: NodeRole.plant, component: NodeComponent.groundTank),
        _n('P', 80, 0, role: NodeRole.plant, component: NodeComponent.pump),
        _n('H', 120, 0),
        for (var i = 0; i < 6; i++)
          _n('f$i', 200, i * 20.0, role: NodeRole.fixture),
      ], edges: [
        _e('pg', 'PDAM', 'GT', ServiceType.coldWater),
        _e('gp', 'GT', 'P', ServiceType.coldWater),
        _e('ph', 'P', 'H', ServiceType.coldWater),
        for (var i = 0; i < 6; i++)
          _e('b$i', 'H', 'f$i', ServiceType.coldWater),
      ]);
      final units = <String, double>{};
      final s = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {ServiceType.coldWater: FlowRate(0)},
          leafFixtureUnits: const {ServiceType.coldWater: 2.0},
          fixtureUnitsOut: units);
      expect(units['pg'], 0.0);
      expect(s['pg']!.flow.cubicMetersPerSecond, 0.0);
      expect(s['pg']!.flowFromId, 'PDAM');
      expect(units['gp'], closeTo(12, 1e-12));
      expect(s['gp']!.flow.inLitersPerSecond, closeTo(_curve(12), 1e-9));
      expect(s['gp']!.flowFromId, 'GT');
    });
  });

  group('return/exhaust flow direction — extract air flows TO the fan', () {
    test('G0/G1 → X0–X1–X2 → inline EF → louvre: every arrow fan-ward', () {
      const q = FlowRate(0.1);
      final net = Network(nodes: [
        _n('G0', 0, 0,
            role: NodeRole.fixture,
            component: NodeComponent.exhaustGrille,
            airflow: q),
        _n('G1', 0, 0,
            floor: 1,
            role: NodeRole.fixture,
            component: NodeComponent.exhaustGrille,
            airflow: q),
        _n('X0', 40, 0),
        _n('X1', 40, 0, floor: 1),
        _n('X2', 40, 0, floor: 2),
        _n('EF', 80, 0,
            floor: 2,
            role: NodeRole.plant,
            component: NodeComponent.exhaustFan),
        _n('L', 120, 0, floor: 2),
      ], edges: [
        _e('g0', 'G0', 'X0', ServiceType.exhaust),
        _e('g1', 'G1', 'X1', ServiceType.exhaust),
        _e('x01', 'X0', 'X1', ServiceType.exhaust, kind: EdgeKind.riser),
        _e('x12', 'X1', 'X2', ServiceType.exhaust, kind: EdgeKind.riser),
        _e('xe', 'X2', 'EF', ServiceType.exhaust),
        _e('el', 'EF', 'L', ServiceType.exhaust),
      ]);
      final s = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {ServiceType.exhaust: FlowRate(0.03)},
          nodeFlowDemand: const {'G0': q, 'G1': q});
      expect(s['g0']!.flowFromId, 'G0');
      expect(s['g1']!.flowFromId, 'G1');
      expect(s['x01']!.flowFromId, 'X0');
      expect(s['x12']!.flowFromId, 'X1');
      expect(s['xe']!.flowFromId, 'X2');
      expect(s['el']!.flowFromId, 'EF');
      // Magnitudes unchanged: the stack top + discharge carry 0.2 m³/s.
      expect(s['x12']!.flow.cubicMetersPerSecond, closeTo(0.2, 1e-12));
      expect(s['el']!.flow.cubicMetersPerSecond, closeTo(0.2, 1e-12));
    });

    test('a return-air ring solves the same fan static as its supply twin',
        () {
      // AHU → J0; ring J0–J1–J2–J0 with terminals at J1 (0.3) and J2 (0.1).
      // The fan walk runs OUTWARD from the AHU along the (flipped-back)
      // balanced orientation, so the return ring's index-run static equals
      // the geometrically identical SUPPLY ring's.
      const building = BuildingLevels([Floor('G', Length(4.0))]);
      const calibration = {'s1': ScaleCalibration(0.05)};
      Network ring(ServiceType svc) => Network(nodes: [
            _n('AHU', 0, 0, role: NodeRole.plant, component: NodeComponent.ahu),
            _n('J0', 200, 0),
            _n('J1', 600, -100, role: NodeRole.fixture),
            _n('J2', 300, 300, role: NodeRole.fixture),
          ], edges: [
            _e('a', 'AHU', 'J0', svc),
            _e('r01', 'J0', 'J1', svc),
            _e('r12', 'J1', 'J2', svc),
            _e('r20', 'J2', 'J0', svc),
          ]);
      DuctStaticSolution solve(ServiceType svc) {
        final net = ring(svc);
        final s = autoSizeNetwork(net, const SizingContext(),
            leafDemand: {svc: const FlowRate(0)},
            nodeFlowDemand: const {'J1': FlowRate(0.3), 'J2': FlowRate(0.1)},
            building: building,
            calibrationBySheet: calibration);
        return solveDuctStatic(
          net: net,
          service: svc,
          fanNodeId: 'AHU',
          edgeFlows: {for (final e in s.entries) e.key: e.value.flow},
          sizing: s,
          calibrationBySheet: calibration,
          building: building,
        );
      }

      final supply = solve(ServiceType.duct);
      final ret = solve(ServiceType.returnAir);
      expect(ret.totalStaticPressure.pascals,
          closeTo(supply.totalStaticPressure.pascals, 1e-9));
      expect(ret.criticalNodeId, supply.criticalNodeId);
    });
  });
}
