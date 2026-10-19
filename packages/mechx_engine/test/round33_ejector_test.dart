/// Round 33 seed suite (2026-10-18) — sewage ejectors:
///   * regression-ejector-pit-valve-reverses-force-main — a suction gate
///     valve between pit and ejector keeps the pit an ejector pit: the
///     drawing sizes exactly like the valveless one (every edge DN75 /
///     20 DFU flowing pump -> sewer), the duty point carries the pit's flow,
///     and a duplex set with a valve on each pit edge is still one set.
///   * regression-force-main-floor-reducer-downstream — gravity drainage
///     downstream of a force main is never below the DN50 solids bore (no
///     reducer in the direction of flow).
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/ejector.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
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

const _b3 = BuildingLevels([
  Floor('B2', Length(3)),
  Floor('B1', Length(3)),
  Floor('L0', Length(3)),
], groundIndex: 2);

({Map<String, EdgeSizing> sz, Map<String, double> fu}) _size(Network net,
    Map<String, double> dfu) {
  final fu = <String, double>{};
  final sz = autoSizeNetwork(net, const SizingContext(),
      leafDemand: const {}, nodeDrainageUnits: dfu, fixtureUnitsOut: fu);
  return (sz: sz, fu: fu);
}

void main() {
  group('a suction valve between pit and ejector keeps the pit', () {
    // WC (20 DFU) -> PIT -> [GV1] -> EJ -> H -riser- R1 -> SW.
    // First principles: the pit's contents are PUMPED onward, so the outfall
    // is SW and every edge carries the pit's 20 DFU; a drain carrying a WC
    // floors at DN75 (`kMinWcDrainMm`). A gate valve on the suction is an
    // inline pass-through device and changes none of that.
    Network single({required bool valve, int seed = -1}) {
      final nodes = [
        _n('WC', -50, 0, role: NodeRole.fixture),
        _n('PIT', 0, 0, component: NodeComponent.groundTank),
        if (valve) _n('GV1', 10, 0, component: NodeComponent.gateValve),
        _n('EJ', 20, 0, component: NodeComponent.pump),
        _n('H', 30, 0),
        _n('R1', 40, 0, floor: 2),
        _n('SW', 140, 0, floor: 2),
      ];
      final edges = [
        _e('in', 'WC', 'PIT'),
        if (valve) ...[
          _e('pg', 'PIT', 'GV1'),
          _e('pe', 'GV1', 'EJ'),
        ] else
          _e('pe', 'PIT', 'EJ'),
        _e('h1', 'EJ', 'H'),
        _e('rs', 'H', 'R1', kind: EdgeKind.riser),
        _e('sw', 'R1', 'SW'),
      ];
      if (seed >= 0) {
        nodes.shuffle(math.Random(seed));
        edges.shuffle(math.Random(seed + 1));
      }
      return Network(nodes: nodes, edges: edges);
    }

    test('sizes identically to the valveless drawing', () {
      final base = _size(single(valve: false), const {'WC': 20});
      for (var seed = -1; seed < 12; seed++) {
        final r = _size(single(valve: true, seed: seed), const {'WC': 20});
        for (final id in ['in', 'pg', 'pe', 'h1', 'rs', 'sw']) {
          final src = id == 'pg' ? 'pe' : id;
          expect(r.sz[id]!.diameter.inMillimeters, 75, reason: '$seed $id');
          expect(r.sz[id]!.diameter.inMillimeters,
              base.sz[src]!.diameter.inMillimeters);
          expect(r.fu[id], 20, reason: '$seed $id');
        }
        // Flow runs pump -> sewer, never back into the pit.
        expect(r.sz['h1']!.flowFromId, 'EJ');
        expect(r.sz['rs']!.flowFromId, 'H');
        expect(r.sz['sw']!.flowFromId, 'R1');
        expect(r.sz['pe']!.flowFromId, 'GV1');
        expect(r.sz['pg']!.flowFromId, 'PIT');
      }
    });

    test('the pit is found through the valve; duty flow = curve(20 DFU)', () {
      final net = single(valve: true);
      final pit = ejectorPitOf(net, 'EJ')!;
      expect(pit.pitId, 'PIT');
      expect([for (final c in pit.chain) c.edge.id], ['pg', 'pe']);
      expect([for (final c in pit.chain) c.from], ['PIT', 'GV1']);
      expect([for (final s in ejectorForceMainSteps(net, 'EJ')) s.edge.id],
          ['h1', 'rs', 'sw']);
      final r = _size(net, const {'WC': 20});
      final p = ejectorDutyPoint(
          net: net,
          pumpId: 'EJ',
          sizing: r.sz,
          edgeFixtureUnits: r.fu,
          building: _b3,
          calibrationBySheet: const {'s1': ScaleCalibration(0.05)})!;
      final expected =
          const SniProfile().probableFlowForFixtureUnits(20).inLitersPerSecond;
      expect(p.flow.inLitersPerSecond, closeTo(expected, 1e-12));
      // Same as the valveless drawing.
      final r0 = _size(single(valve: false), const {'WC': 20});
      final p0 = ejectorDutyPoint(
          net: single(valve: false),
          pumpId: 'EJ',
          sizing: r0.sz,
          edgeFixtureUnits: r0.fu,
          building: _b3,
          calibrationBySheet: const {'s1': ScaleCalibration(0.05)})!;
      expect(p.flow.inLitersPerSecond, closeTo(p0.flow.inLitersPerSecond, 1e-12));
      expect(p.staticLift.meters, closeTo(p0.staticLift.meters, 1e-9));
    });

    test('duplex with a valve on each pit edge is still one set', () {
      final net = Network(nodes: [
        _n('WC', -50, 0, role: NodeRole.fixture),
        _n('PIT', 0, 0, component: NodeComponent.groundTank),
        _n('GVa', 10, 0, component: NodeComponent.gateValve),
        _n('GVb', 10, 20, component: NodeComponent.gateValve),
        _n('EJ', 20, 0, component: NodeComponent.pump),
        _n('EJ2', 20, 20, component: NodeComponent.pump),
        _n('H', 34, 10),
        _n('R1', 40, 0, floor: 2),
        _n('SW', 140, 0, floor: 2),
      ], edges: [
        _e('in', 'WC', 'PIT'),
        _e('ga', 'PIT', 'GVa'),
        _e('pe', 'GVa', 'EJ'),
        _e('gb', 'PIT', 'GVb'),
        _e('pe2', 'GVb', 'EJ2'),
        _e('h1', 'EJ', 'H'),
        _e('h2', 'EJ2', 'H'),
        _e('rs', 'H', 'R1', kind: EdgeKind.riser),
        _e('sw', 'R1', 'SW'),
      ]);
      final sets = duplexEjectorSets(net);
      expect(sets, hasLength(1));
      expect(sets.single.pitId, 'PIT');
      expect(sets.single.headerId, 'H');
      expect(sets.single.duty.pitEdgeIds, ['ga', 'pe']);
      expect(sets.single.standby.single.pitEdgeIds, ['gb', 'pe2']);
      final legs = <String>{};
      final fu = <String, double>{};
      final sz = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {},
          nodeDrainageUnits: const {'WC': 20},
          fixtureUnitsOut: fu,
          parallelLegEdgeIdsOut: legs);
      for (final id in ['ga', 'pe', 'gb', 'pe2', 'h1', 'h2', 'rs', 'sw']) {
        expect(sz[id]!.diameter.inMillimeters, 75, reason: id);
        expect(fu[id], 20, reason: id);
        expect(sz[id]!.loopUnbalanced, isFalse, reason: id);
      }
      expect(sz['gb']!.flowFromId, 'PIT');
      expect(sz['pe2']!.flowFromId, 'GVb');
      expect(sz['h2']!.flowFromId, 'EJ2');
      expect(legs, containsAll(['gb', 'pe2', 'h2']));
    });
  });

  group('no reducer downstream of a force main', () {
    // Gravity pipe carrying the pumped discharge is at least the DN50 bore
    // of the force main feeding it (IPC 704.2: no reduction in the direction
    // of flow; sewage pumps pass 2 in solids).
    test('a light branch joining after the force main', () {
      // LV (1) -> PIT -> EJ -riser- R1 -> J; LV2 (1) -> J; J -> SW.
      // The DFU table gives sw (2 DFU) DN40; it carries the pumped flow, so
      // it floors at DN50; the incoming LV2 branch is untouched.
      final net = Network(nodes: [
        _n('LV', -50, 0, role: NodeRole.fixture),
        _n('PIT', 0, 0, component: NodeComponent.groundTank),
        _n('EJ', 20, 0, component: NodeComponent.pump),
        _n('R1', 40, 0, floor: 2),
        _n('J', 80, 0, floor: 2),
        _n('LV2', 80, 40, floor: 2, role: NodeRole.fixture),
        _n('SW', 140, 0, floor: 2),
      ], edges: [
        _e('in', 'LV', 'PIT'),
        _e('pe', 'PIT', 'EJ'),
        _e('rs', 'EJ', 'R1', kind: EdgeKind.riser),
        _e('rj', 'R1', 'J'),
        _e('l2', 'LV2', 'J'),
        _e('sw', 'J', 'SW'),
      ]);
      final r = _size(net, const {'LV': 1, 'LV2': 1});
      expect(r.fu['sw'], 2);
      for (final id in ['rs', 'rj', 'sw']) {
        expect(r.sz[id]!.diameter.inMillimeters, 50, reason: id);
      }
      expect(r.sz['sw']!.stackRaisedForBranch, isTrue);
      expect(r.sz['l2']!.diameter.inMillimeters, lessThan(50));
      expect(r.sz['l2']!.stackRaisedForBranch, isFalse);
    });

    test('a duplex header with a floor drain', () {
      final net = Network(nodes: [
        _n('LV', -50, 0, role: NodeRole.fixture),
        _n('PIT', 0, 0, component: NodeComponent.groundTank),
        _n('EJ', 20, 0, component: NodeComponent.pump),
        _n('EJ2', 20, 20, component: NodeComponent.pump),
        _n('H', 34, 10),
        _n('FD', 34, 40, role: NodeRole.fixture),
        _n('R1', 40, 0, floor: 2),
        _n('SW', 140, 0, floor: 2),
      ], edges: [
        _e('in', 'LV', 'PIT'),
        _e('pe', 'PIT', 'EJ'),
        _e('pe2', 'PIT', 'EJ2'),
        _e('h1', 'EJ', 'H'),
        _e('h2', 'EJ2', 'H'),
        _e('fd', 'FD', 'H'),
        _e('rs', 'H', 'R1', kind: EdgeKind.riser),
        _e('sw', 'R1', 'SW'),
      ]);
      final r = _size(net, const {'LV': 1, 'FD': 1});
      for (final id in ['h1', 'h2', 'rs', 'sw']) {
        expect(r.sz[id]!.diameter.inMillimeters, greaterThanOrEqualTo(50),
            reason: id);
      }
    });

    test('a hand override downstream below the bore is flagged, not resized',
        () {
      final net = Network(nodes: [
        _n('LV', -50, 0, role: NodeRole.fixture),
        _n('PIT', 0, 0, component: NodeComponent.groundTank),
        _n('EJ', 20, 0, component: NodeComponent.pump),
        _n('R1', 40, 0, floor: 2),
        _n('J', 80, 0, floor: 2),
        _n('LV2', 80, 40, floor: 2, role: NodeRole.fixture),
        _n('SW', 140, 0, floor: 2),
      ], edges: [
        _e('in', 'LV', 'PIT'),
        _e('pe', 'PIT', 'EJ'),
        _e('rs', 'EJ', 'R1', kind: EdgeKind.riser),
        _e('rj', 'R1', 'J'),
        _e('l2', 'LV2', 'J'),
        _e('sw', 'J', 'SW'),
      ]);
      final sz = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {},
          nodeDrainageUnits: const {'LV': 1, 'LV2': 1},
          sizeOverrides: {'sw': Diameter.mm(40)});
      expect(sz['sw']!.diameter.inMillimeters, 40);
      expect(sz['sw']!.belowCodeMinimum, isTrue);
    });
  });
}
