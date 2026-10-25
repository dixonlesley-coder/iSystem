// Round 59 (fire-convergence-11-run-and-pump-legs-feeding-single-outlet-
// standpipe-sized-on-one-box) — every pipe between the fire pump and a
// standpipe stack carries the stack's standpipe flow by continuity, even
// when the stack has ONE hose outlet (a roof hose station) so the
// accumulated flow on the run / pump legs is only one box's 5 L/s.
//
// First principles: one stack = 500 gpm = 500 x 3.785411784 / 60 =
// 31.545 L/s; at the 6 m/s fire velocity cap d >= sqrt(4 x 0.031545 /
// (pi x 6)) = 0.0818 m => DN100 (also the Class I riser minimum). Two
// stacks = 750 gpm = 47.318 L/s.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x,
        {int floor = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: 0,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.fireHydrant, kind: k);

NetNode _box(String id, double x, int floor) => _n(id, x,
    floor: floor, role: NodeRole.fixture, c: NodeComponent.hydrantBox);

BuildingLevels _floors(int n) => BuildingLevels(
    [for (var i = 0; i < n; i++) Floor('L$i', const Length(3.5))]);

/// 4 storeys: GT -> FP -> J -> run (20 m at 0.01 m/px) -> R0, risers
/// R0..R3, ONE hydrant box on L3.
Network _roofStation() {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('FP', 100, role: NodeRole.plant, c: NodeComponent.pump),
    _n('J', 200),
    for (var f = 0; f < 4; f++) _n('R$f', 2200, floor: f),
    _box('HB', 2300, 3),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'FP'),
    _e('d', 'FP', 'J'),
    _e('run', 'J', 'R0'),
    for (var f = 1; f < 4; f++)
      _e('r$f', 'R${f - 1}', 'R$f', k: EdgeKind.riser),
    _e('hb', 'R3', 'HB'),
  ];
  return Network(nodes: nodes, edges: edges);
}

/// The shophouse: GT -> FP -> J, J -> A0 and J -> B0 ('header'), or the
/// chained A0 -> B0 ('chain'); one-storey risers A0->A1 / B0->B1, one box
/// each on L1.
Network _shophouse(String feed) {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('FP', 100, role: NodeRole.plant, c: NodeComponent.pump),
    _n('J', 200),
    _n('A0', 600),
    _n('A1', 600, floor: 1),
    _box('AB', 700, 1),
    _n('B0', 1600),
    _n('B1', 1600, floor: 1),
    _box('BB', 1700, 1),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'FP'),
    _e('d', 'FP', 'J'),
    if (feed == 'header') ...[
      _e('ja', 'J', 'A0'),
      _e('jb', 'J', 'B0'),
    ] else ...[
      _e('ja', 'J', 'A0'),
      _e('ab', 'A0', 'B0'),
    ],
    _e('ar', 'A0', 'A1', k: EdgeKind.riser),
    _e('br', 'B0', 'B1', k: EdgeKind.riser),
    _e('ah', 'A1', 'AB'),
    _e('bh', 'B1', 'BB'),
  ];
  return Network(nodes: nodes, edges: edges);
}

Network _flipShuffle(Network net, math.Random rnd) {
  final edges = [
    for (final e in net.edges)
      rnd.nextBool()
          ? NetEdge(
              id: e.id,
              fromId: e.toId,
              toId: e.fromId,
              service: e.service,
              kind: e.kind)
          : e,
  ]..shuffle(rnd);
  final nodes = [...net.nodes]..shuffle(rnd);
  return Network(nodes: nodes, edges: edges);
}

Map<String, EdgeSizing> _size(Network net, int floors) => autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {ServiceType.fireHydrant: FlowRate(0.005)},
      hydrantDesignFlow: standpipeFlow(drawnStandpipeRiserCount(net)),
      building: _floors(floors),
      calibrationBySheet: const {'s1': ScaleCalibration(0.01)},
    );

void main() {
  const oneStack = 500 * 3.785411784 / 60; // 31.545 L/s
  const twoStacks = 750 * 3.785411784 / 60; // 47.318 L/s

  test(
      'a one-outlet roof stack: suction, discharge and run carry 31.545 L/s '
      'DN100 like the riser', () {
    final r = _size(_roofStation(), 4);
    for (final id in ['g', 'd', 'run', 'r1', 'r3']) {
      expect(r[id]!.flow.inLitersPerSecond, closeTo(oneStack, 1e-3),
          reason: id);
      expect(r[id]!.diameter.inMillimeters, closeTo(100, 1e-9), reason: id);
    }
  });

  test(
      'shophouse twins: header legs and the chained leg carry the stack '
      'flow downstream', () {
    final h = _size(_shophouse('header'), 2);
    // Two stacks => the discharge carries 750 gpm; each header leg serves
    // ONE stack => 500 gpm.
    expect(h['d']!.flow.inLitersPerSecond, closeTo(twoStacks, 1e-3));
    for (final id in ['ja', 'jb']) {
      expect(h[id]!.flow.inLitersPerSecond, closeTo(oneStack, 1e-3),
          reason: id);
      expect(h[id]!.diameter.inMillimeters, closeTo(100, 1e-9), reason: id);
    }
    final c = _size(_shophouse('chain'), 2);
    expect(c['ja']!.flow.inLitersPerSecond, closeTo(twoStacks, 1e-3));
    expect(c['ab']!.flow.inLitersPerSecond, closeTo(oneStack, 1e-3));
    expect(c['ab']!.diameter.inMillimeters, closeTo(100, 1e-9));
  });

  test('seeded property: flips / shuffles never change a size or flow', () {
    final rnd = math.Random(5901);
    for (final (name, net, floors) in [
      ('roof', _roofStation(), 4),
      ('header', _shophouse('header'), 2),
      ('chain', _shophouse('chain'), 2),
    ]) {
      final base = _size(net, floors);
      for (var t = 0; t < 40; t++) {
        final r = _size(_flipShuffle(net, rnd), floors);
        for (final id in base.keys) {
          expect(
              r[id]!.diameter.inMillimeters, base[id]!.diameter.inMillimeters,
              reason: '$name $id trial $t');
          expect(r[id]!.flow.inLitersPerSecond,
              closeTo(base[id]!.flow.inLitersPerSecond, 1e-9),
              reason: '$name $id trial $t');
        }
      }
    }
  });
}
