/// Round 33 seed suite (2026-10-18) — pressure solves share the sizer's
/// demand set:
///   * hydraulics-3-1 — an air vent (fixture role, no demand) is never a
///     delivery / critical node: the pump head and the downfeed booster head
///     equal those of the same drawing without the AAV.
///   * hydraulics-3-4 — a LOADED open run end (the sizer gave it the default
///     terminal demand) is judged too: it becomes the critical node and no
///     delivery residual falls below the target.
///   * hydraulics-3-3 — a PDAM meter -> pump -> roof tank fill line roots at
///     the meter: no draw-off at the meter, the fill line carries the tank's
///     delivered flow toward the tank.
library;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _cw = ServiceType.coldWater;

NetNode _n(String id, double x, int floor,
        {NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: 0,
        floorIndex: floor,
        role: c?.role ?? role,
        component: c);

NetEdge _run(String id, String a, String b) =>
    NetEdge(id: id, fromId: a, toId: b, service: _cw);
NetEdge _riser(String id, String a, String b) =>
    NetEdge(id: id, fromId: a, toId: b, service: _cw, kind: EdgeKind.riser);

// 5 floors x 4 m; L4 is the plant / roof floor with no fixtures.
const _b5 = BuildingLevels([
  Floor('L0', Length(4)),
  Floor('L1', Length(4)),
  Floor('L2', Length(4)),
  Floor('L3', Length(4)),
  Floor('L4', Length(4)),
]);
const _cal = {'s1': ScaleCalibration(0.01)};
const _target = Pressure(49033.25); // 0.5 kgf/cm² = 5.0 m

/// Upfeed: pump P (L0) -> m0 -riser- m1 .. m4; fixture Fi off each mi
/// (i < 4); [top] = 'aav' (an air vent off m4), 'bare' (a bare run end off
/// m4) or 'none' (the riser stops at m3 — nothing on L4).
Network _upfeed(String top) => Network(nodes: [
      _n('P', 0, 0, c: NodeComponent.pump),
      for (var i = 0; i < (top == 'none' ? 4 : 5); i++) _n('m$i', 100, i),
      for (var i = 0; i < 4; i++) _n('F$i', 200, i, role: NodeRole.fixture),
      if (top == 'aav') _n('X4', 150, 4, c: NodeComponent.airVent),
      if (top == 'bare') _n('X4', 150, 4),
    ], edges: [
      _run('p0', 'P', 'm0'),
      for (var i = 0; i < (top == 'none' ? 3 : 4); i++)
        _riser('r$i', 'm$i', 'm${i + 1}'),
      for (var i = 0; i < 4; i++) _run('f$i', 'm$i', 'F$i'),
      if (top != 'none') _run('x4', 'm4', 'X4'),
    ]);

Map<String, EdgeSizing> _size(Network net) => autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {_cw: FlowRate(0.0002)},
      nodeFlowDemand: {
        for (final n in net.nodes)
          if (n.role == NodeRole.fixture &&
              n.component != NodeComponent.airVent)
            n.id: const FlowRate(0.0002),
      },
      building: _b5,
      calibrationBySheet: _cal,
    );

PressureSolution _solve(Network net, Map<String, EdgeSizing> sz) =>
    solvePressurized(
      net: net,
      service: _cw,
      sourceId: 'P',
      edgeFlows: {for (final e in sz.entries) e.key: e.value.flow},
      sizing: sz,
      calibrationBySheet: _cal,
      building: _b5,
      targetResidual: _target,
    );

void main() {
  group('an air vent is never the critical node (hydraulics-3-1)', () {
    test('upfeed head == the same drawing without the AAV', () {
      final withAav = _upfeed('aav');
      final szA = _size(withAav);
      // The AAV carries no flow (not a draw-off).
      expect(szA['x4']?.flow.cubicMetersPerSecond ?? 0, 0);
      final a = _solve(withAav, szA);
      final none = _upfeed('none');
      final b = _solve(none, _size(none));
      expect(a.criticalNodeId, 'F3');
      expect(a.deliveryNodeIds, isNot(contains('X4')));
      // First principles: head = friction(P -> F3) + elevation gain + target;
      // the AAV adds no flow and no delivery point, so the head is the
      // AAV-free drawing's to the bit.
      expect(a.requiredPumpHead.meters, b.requiredPumpHead.meters);
      // F3 sits at the L3 fixture height 13.1 m (12 + 1.1), the pump on the
      // L0 surface (0 m): the head is at least the lift + target.
      expect(a.requiredPumpHead.meters,
          greaterThan(13.1 + headFromPressure(_target).meters));
    });

    test('downfeed: no phantom booster for the AAV', () {
      // Roof tank T on L4 (at the roof, 20 m) -> m4 -riser- down to m0;
      // fixtures F0..F3; the AAV off m4.
      Network down(bool aav) => Network(nodes: [
            _n('T', 0, 4, c: NodeComponent.roofTank),
            for (var i = 0; i < 5; i++) _n('m$i', 100, i),
            for (var i = 0; i < 4; i++)
              _n('F$i', 200, i, role: NodeRole.fixture),
            if (aav) _n('X4', 150, 4, c: NodeComponent.airVent),
          ], edges: [
            _run('t4', 'T', 'm4'),
            for (var i = 0; i < 4; i++) _riser('r$i', 'm${i + 1}', 'm$i'),
            for (var i = 0; i < 4; i++) _run('f$i', 'm$i', 'F$i'),
            if (aav) _run('x4', 'm4', 'X4'),
          ]);
      DownfeedSolution solve(Network net) {
        final sz = _size(net);
        return solveDownfeed(
          net: net,
          service: _cw,
          tankId: 'T',
          edgeFlows: {for (final e in sz.entries) e.key: e.value.flow},
          sizing: sz,
          calibrationBySheet: _cal,
          building: _b5,
          targetResidual: _target,
        );
      }

      final a = solve(down(true));
      final b = solve(down(false));
      expect(a.criticalNodeId, b.criticalNodeId);
      expect(a.criticalNodeId, 'F3');
      expect(a.boosterHeadRequired.meters, b.boosterHeadRequired.meters);
      // F3 at 13.1 m under a 20 m tank: 6.9 m static, well above the 5 m
      // target after the small pipe friction ⇒ no booster.
      expect(a.boosterHeadRequired.meters, 0);
    });
  });

  group('a loaded open end is a delivery node (hydraulics-3-4)', () {
    test('the bare L4 end is critical; no delivery residual below target', () {
      final net = _upfeed('bare');
      final sz = _size(net);
      // The sizer loads the bare end with the default demand.
      expect(sz['x4']!.flow.cubicMetersPerSecond, closeTo(0.0002, 1e-12));
      expect(sz['x4']!.flowFromId, 'm4');
      final s = _solve(net, sz);
      expect(s.deliveryNodeIds, contains('X4'));
      expect(s.criticalNodeId, 'X4');
      final targetPa = _target.pascals;
      for (final id in s.deliveryNodeIds) {
        expect(s.residualPressure[id]!.pascals,
            greaterThanOrEqualTo(targetPa - 1e-6),
            reason: id);
      }
      // Round 33 r2 — X4 is a bare main on L4 the sizer loaded with the
      // DEFAULT TERMINAL demand (a fixture), so its residual is owed at the
      // L4 FIXTURE height, 17.1 m (16 + 1.1), never the L4 ceiling 19.7 m
      // (16 + 4 - 0.3) the main runs at: the head is that 17.1 m lift +
      // friction + target, strictly below the ceiling reading (the friction
      // P -> X4 is far under the 2.6 m difference on this short drawing).
      final t = headFromPressure(_target).meters;
      expect(s.requiredPumpHead.meters, greaterThan(17.1 + t));
      expect(s.requiredPumpHead.meters, lessThan(19.7 + t));
      // It is the critical node, so its residual is exactly the target.
      expect(s.residualPressure['X4']!.pascals, closeTo(targetPa, 1e-6));
      // Exact: the no-flow static at X4 is pump head - (judge elevation -
      // pump elevation 0 m on the L0 surface), so it pins the 17.1 m.
      expect(
          s.noFlowStaticPressure['X4']!.pascals,
          closeTo(
              pressureFromHead(Head(s.requiredPumpHead.meters - 17.1)).pascals,
              1e-6));
    });
  });

  group('PDAM meter -> pump -> roof tank fill line (hydraulics-3-3)', () {
    // WM (L0, the PDAM meter leaf) -> P (L0 pump) -> m0 -riser- m1 -riser-
    // m2 -> T (roof tank on L2, the roof); T -> d2 -riser- d1 -riser- d0
    // gravity downfeed; WCs W0/W1 off d0/d1.
    Network ruko() => Network(nodes: [
          _n('WM', -20, 0, c: NodeComponent.waterMeter),
          _n('P', 0, 0, c: NodeComponent.pump),
          _n('m0', 20, 0),
          _n('m1', 20, 1),
          _n('m2', 20, 2),
          _n('T', 40, 2, c: NodeComponent.roofTank),
          _n('d2', 60, 2),
          _n('d1', 60, 1),
          _n('d0', 60, 0),
          _n('W0', 80, 0, role: NodeRole.fixture),
          _n('W1', 80, 1, role: NodeRole.fixture),
        ], edges: [
          _run('wp', 'WM', 'P'),
          _run('pm', 'P', 'm0'),
          _riser('fr0', 'm0', 'm1'),
          _riser('fr1', 'm1', 'm2'),
          _run('ft', 'm2', 'T'),
          _run('td', 'T', 'd2'),
          _riser('dr1', 'd2', 'd1'),
          _riser('dr0', 'd1', 'd0'),
          _run('w0', 'd0', 'W0'),
          _run('w1', 'd1', 'W1'),
        ]);
    const b3 = BuildingLevels([
      Floor('L0', Length(3.5)),
      Floor('L1', Length(3.5)),
      Floor('L2', Length(3.5)),
    ]);

    test('roots at the meter; the fill line carries the tank flow inward', () {
      final net = ruko();
      final roots =
          serviceComponentRoots(net, _cw, demandNodeIds: const {'W0', 'W1'});
      expect(roots['T'], 'WM');
      final sz = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {_cw: FlowRate(0.0002)},
          nodeFlowDemand: const {
            'W0': FlowRate(0.0003),
            'W1': FlowRate(0.0003),
          },
          building: b3,
          calibrationBySheet: _cal);
      // No draw-off at the meter: every fill edge carries exactly what the
      // tank delivers downstream (0.3 + 0.3 L/s, flat-flow demands), flowing
      // TOWARD the tank.
      final tankOut = sz['td']!.flow.cubicMetersPerSecond;
      expect(tankOut, closeTo(0.0006, 1e-12));
      for (final id in ['wp', 'pm', 'fr0', 'fr1', 'ft']) {
        expect(sz[id]!.flow.cubicMetersPerSecond, closeTo(tankOut, 1e-12),
            reason: id);
      }
      expect(sz['wp']!.flowFromId, 'WM');
      expect(sz['pm']!.flowFromId, 'P');
      expect(sz['ft']!.flowFromId, 'm2');
      expect(sz['td']!.flowFromId, 'T');
    });

    test('a meter leaf on a plain branch bears no default demand', () {
      // P (plant) -> m0 -> F (fixture) and m0 -> WM (a meter left at a run
      // end): the meter is never a draw-off.
      final net = Network(nodes: [
        _n('P', 0, 0, c: NodeComponent.pump),
        _n('m0', 20, 0),
        _n('F', 40, 0, role: NodeRole.fixture),
        _n('WM', 20, 0, c: NodeComponent.waterMeter),
      ], edges: [
        _run('a', 'P', 'm0'),
        _run('b', 'm0', 'F'),
        _run('c', 'm0', 'WM'),
      ]);
      final sz = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {_cw: FlowRate(0.0002)});
      expect(sz['c']?.flow.cubicMetersPerSecond ?? 0, 0);
      expect(sz['a']!.flow.cubicMetersPerSecond, closeTo(0.0002, 1e-12));
    });
  });

  group('upfeed delivered field with drawn movers (hydraulics-3-2)', () {
    test('root pump + zone booster: residual = unboosted shifted per mover',
        () {
      // P (source, L0) -> m0 -riser- m1 -riser- m2 -> BS (booster on L2)
      // -> m2b -riser- m3 -riser- m4; fixtures off m0..m4 (F2 off m2, below
      // the booster; F3/F4 beyond it).
      final net = Network(nodes: [
        _n('P', 0, 0, c: NodeComponent.pump),
        _n('m0', 100, 0),
        _n('m1', 100, 1),
        _n('m2', 100, 2),
        _n('BS', 120, 2, c: NodeComponent.boosterSet),
        _n('m2b', 140, 2),
        _n('m3', 140, 3),
        _n('m4', 140, 4),
        for (var i = 0; i < 5; i++) _n('F$i', 200, i, role: NodeRole.fixture),
      ], edges: [
        _run('p0', 'P', 'm0'),
        _riser('r0', 'm0', 'm1'),
        _riser('r1', 'm1', 'm2'),
        _run('b0', 'm2', 'BS'),
        _run('b1', 'BS', 'm2b'),
        _riser('r2', 'm2b', 'm3'),
        _riser('r3', 'm3', 'm4'),
        _run('f0', 'm0', 'F0'),
        _run('f1', 'm1', 'F1'),
        _run('f2', 'm2', 'F2'),
        _run('f3', 'm3', 'F3'),
        _run('f4', 'm4', 'F4'),
      ]);
      final sz = _size(net);
      final base = _solve(net, sz);
      const rootHead = Head(15), boosterHead = Head(3);
      final d = solvePressurized(
        net: net,
        service: _cw,
        sourceId: 'P',
        edgeFlows: {for (final e in sz.entries) e.key: e.value.flow},
        sizing: sz,
        calibrationBySheet: _cal,
        building: _b5,
        targetResidual: _target,
        moverHeads: const {'P': rootHead, 'BS': boosterHead},
      );
      // First principles: every residual is linear in the source head; the
      // root pump develops 15 m instead of requiredPumpHead, and the booster
      // adds 3 m to every node it serves.
      expect(d.requiredPumpHead.meters, base.requiredPumpHead.meters);
      final shift =
          pressureFromHead(Head(base.requiredPumpHead.meters - rootHead.meters))
              .pascals;
      final boost = pressureFromHead(boosterHead).pascals;
      for (final id in ['m0', 'F0', 'F1', 'F2', 'm2']) {
        expect(d.residualPressure[id]!.pascals,
            closeTo(base.residualPressure[id]!.pascals - shift, 1e-6),
            reason: id);
      }
      for (final id in ['m2b', 'F3', 'F4']) {
        expect(d.residualPressure[id]!.pascals,
            closeTo(base.residualPressure[id]!.pascals - shift + boost, 1e-6),
            reason: id);
      }
      // A falsifiable field: F4 (needs > 17.1 + 5 m, gets 15 + 3 m) falls below the target.
      expect(d.targetHeldByDesign, isFalse);
    });
  });
}
