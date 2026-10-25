// Round 58 (2026-10-18) — a standpipe STACK is decided by its own hose
// outlets first:
//
//   regression-pillar-drops-off-riser-base-count-as-stacks — one-storey drops
//     to pillar hydrants teed off a tall riser's BASE are no stacks (1).
//   regression-top-fed-twin-stacks-count-one — twin 2-storey stacks count 2
//     whether stack B is fed from A's base, a header or A's TOP node.
//   fire-convergence-10-outletless-supply-riser-counted-as-standpipe-stack —
//     a break-tank fill riser / a pump-room riser with no hose outlet of its
//     own is no stack.
//   fire-convergence-10-pillar-drops-reached-directly-counted-as-stacks —
//     drops to pillar hydrants off a ring at the pump level are no stacks.
//
// First principles: standpipeFlow(n) = 500 gpm + 250 gpm per extra stack
// (NFPA 14 / SNI 03-1745): 1 stack = 500 x 3.785411784 / 60 = 31.545 L/s,
// 2 stacks = 750 gpm = 47.318 L/s. At the 6 m/s fire velocity cap the pump
// discharge carrying 31.545 L/s needs d >= sqrt(4 x 0.031545 / (pi x 6)) =
// 0.0818 m => DN100; 47.318 L/s needs 0.1002 m => DN125.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
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

/// A hydrant stack [p]0..[p](top) with a box on every floor.
void _stack(List<NetNode> nodes, List<NetEdge> edges, String p, double x,
    {required int top}) {
  for (var f = 0; f <= top; f++) {
    nodes.add(_n('$p$f', x, floor: f));
    nodes.add(_box('${p}B$f', x + 5, f));
    edges.add(_e('${p}b$f', '$p$f', '${p}B$f'));
    if (f > 0) {
      edges.add(_e('${p}r$f', '$p${f - 1}', '$p$f', k: EdgeKind.riser));
    }
  }
}

/// GT -> FP -> HR0; a 4-storey stack HR0..HR3; a pillar ring P0..P3 on L0
/// teed off HR0; four one-storey drops P_k -> PT_k, each to one L1 pillar box.
Network _pillarsOffBase() {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('FP', 10, role: NodeRole.plant, c: NodeComponent.pump),
  ];
  final edges = <NetEdge>[_e('g', 'GT', 'FP'), _e('d', 'FP', 'HR0')];
  _stack(nodes, edges, 'HR', 30, top: 3);
  for (var k = 0; k < 4; k++) {
    nodes.add(_n('P$k', 100.0 + 40 * k));
    nodes.add(_n('PT$k', 100.0 + 40 * k, floor: 1));
    nodes.add(_box('PH$k', 105.0 + 40 * k, 1));
    edges.add(_e('pd$k', 'P$k', 'PT$k', k: EdgeKind.riser));
    edges.add(_e('ph$k', 'PT$k', 'PH$k'));
    edges.add(_e('pr$k', 'P$k', 'P${(k + 1) % 4}'));
  }
  edges.add(_e('hp', 'HR0', 'P0'));
  return Network(nodes: nodes, edges: edges);
}

/// Two 2-storey stacks A / B, a box on both floors of each. [feed]: 'base'
/// (FP -> A0 -> B0), 'header' (FP -> J -> A0, B0) or 'top' (FP -> A0, the
/// main to B drawn A1 -> B1).
Network _twins(String feed) {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('FP', 10, role: NodeRole.plant, c: NodeComponent.pump),
    if (feed == 'header') _n('J', 15),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'FP'),
    if (feed == 'header') ...[
      _e('d', 'FP', 'J'),
      _e('ja', 'J', 'A0'),
      _e('jb', 'J', 'B0'),
    ] else
      _e('d', 'FP', 'A0'),
    if (feed == 'base') _e('ab', 'A0', 'B0'),
    if (feed == 'top') _e('ab', 'A1', 'B1'),
  ];
  _stack(nodes, edges, 'A', 20, top: 1);
  _stack(nodes, edges, 'B', 60, top: 1);
  return Network(nodes: nodes, edges: edges);
}

/// Repro A (16 storeys): the low-zone pump PL on L0 feeds header D; two
/// stacks A / B (a box per floor) off D, and a plain fill riser
/// D -> T0..T15 -> the break tank BT15 (no outlet).
Network _fillRiser() {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('PL', 10, role: NodeRole.plant, c: NodeComponent.pump),
    _n('D', 20),
    _n('BT15', 400, floor: 15, role: NodeRole.plant, c: NodeComponent.roofTank),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'PL'),
    _e('d', 'PL', 'D'),
    _e('da', 'D', 'A0'),
    _e('db', 'D', 'B0'),
    _e('dt', 'D', 'T0'),
    _e('tb', 'T15', 'BT15'),
  ];
  _stack(nodes, edges, 'A', 100, top: 14);
  _stack(nodes, edges, 'B', 200, top: 14);
  for (var f = 0; f <= 15; f++) {
    nodes.add(_n('T$f', 300, floor: f));
    if (f > 0) edges.add(_e('tr$f', 'T${f - 1}', 'T$f', k: EdgeKind.riser));
  }
  return Network(nodes: nodes, edges: edges);
}

/// Repro B: floors B1 (0) + L0..L5 (1..6). GT -> FP (B1) -> D0; the pump
/// riser D0 -> R1 to an L0 ring S1 - N2 - S3 - N4 (pillar boxes on N2 / N4);
/// two indoor stacks through S1 and S3 run B1..L5 (bases fed from D0), a box
/// per floor.
Network _pumpRiserToRing() {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('FP', 10, role: NodeRole.plant, c: NodeComponent.pump),
    _n('D0', 20),
    _n('R1', 20, floor: 1),
    _n('N2', 140, floor: 1),
    _n('N4', 220, floor: 1),
    _box('PB2', 145, 1),
    _box('PB4', 225, 1),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'FP'),
    _e('d', 'FP', 'D0'),
    _e('pr', 'D0', 'R1', k: EdgeKind.riser),
    _e('rn', 'R1', 'N2'),
    _e('pb2', 'N2', 'PB2'),
    _e('pb4', 'N4', 'PB4'),
    _e('q12', 'S1', 'N2'),
    _e('q23', 'N2', 'S3'),
    _e('q34', 'S3', 'N4'),
    _e('q41', 'N4', 'S1'),
    _e('d1', 'D0', 'X10'),
    _e('d3', 'D0', 'X30'),
  ];
  for (final k in [1, 3]) {
    String id(int f) => f == 1 ? 'S$k' : 'X$k$f';
    for (var f = 0; f <= 6; f++) {
      nodes.add(_n(id(f), 100.0 * k, floor: f));
      nodes.add(_box('XB$k$f', 100.0 * k + 5, f));
      edges.add(_e('xb$k$f', id(f), 'XB$k$f'));
      if (f > 0) edges.add(_e('xr$k$f', id(f - 1), id(f), k: EdgeKind.riser));
    }
  }
  return Network(nodes: nodes, edges: edges);
}

/// Finding 4 (hospital): GT -> FP (B1) -> ring N1..N4 on B1; four one-storey
/// drops N_k -> PT_k to pillar boxes on L0; two indoor stacks rise B1..L5
/// from N2 and N4 (ids N20 / N40), a box per floor.
Network _hospitalRing() {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('FP', 10, role: NodeRole.plant, c: NodeComponent.pump),
    _n('N1', 100),
    _n('N3', 300),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'FP'),
    _e('d', 'FP', 'N1'),
    _e('q12', 'N1', 'N20'),
    _e('q23', 'N20', 'N3'),
    _e('q34', 'N3', 'N40'),
    _e('q41', 'N40', 'N1'),
  ];
  _stack(nodes, edges, 'N2', 200, top: 6);
  _stack(nodes, edges, 'N4', 400, top: 6);
  for (final (k, node) in [(1, 'N1'), (2, 'N20'), (3, 'N3'), (4, 'N40')]) {
    nodes.add(_n('PT$k', 100.0 * k + 20, floor: 1));
    nodes.add(_box('PH$k', 100.0 * k + 25, 1));
    edges.add(_e('pd$k', node, 'PT$k', k: EdgeKind.riser));
    edges.add(_e('ph$k', 'PT$k', 'PH$k'));
  }
  return Network(nodes: nodes, edges: edges);
}

/// A zoned tower from one ground pump room: the low-zone stack L0..L2 (a box
/// per floor) and the high-zone riser U0..U5 rising past the low zone with
/// boxes on L3..L5 only.
Network _zoned() {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('FP', 10, role: NodeRole.plant, c: NodeComponent.pump),
    _n('D', 20),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'FP'),
    _e('d', 'FP', 'D'),
    _e('dl', 'D', 'L0'),
    _e('du', 'D', 'U0'),
  ];
  _stack(nodes, edges, 'L', 100, top: 2);
  for (var f = 0; f <= 5; f++) {
    nodes.add(_n('U$f', 200, floor: f));
    if (f > 0) edges.add(_e('ur$f', 'U${f - 1}', 'U$f', k: EdgeKind.riser));
    if (f >= 3) {
      nodes.add(_box('UB$f', 205, f));
      edges.add(_e('ub$f', 'U$f', 'UB$f'));
    }
  }
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

double _dischargeLps(Network net, int floors) {
  final r = autoSizeNetwork(
    net,
    const SizingContext(),
    leafDemand: const {ServiceType.fireHydrant: FlowRate(0.005)},
    hydrantDesignFlow: standpipeFlow(drawnStandpipeRiserCount(net)),
    building: _floors(floors),
  );
  return r['d']!.flow.inLitersPerSecond;
}

void main() {
  const oneStack = 500 * 3.785411784 / 60; // 31.545 L/s
  const twoStacks = 750 * 3.785411784 / 60; // 47.318 L/s

  test('pillar drops teed off a stack BASE are no stacks: 1 (31.545 L/s)', () {
    final net = _pillarsOffBase();
    expect(drawnStandpipeRiserCount(net), 1);
    expect(_dischargeLps(net, 4), closeTo(oneStack, 1e-3));
  });

  test('twin 2-storey stacks count 2 base-, header- and TOP-fed (750 gpm)', () {
    for (final feed in ['base', 'header', 'top']) {
      final net = _twins(feed);
      expect(drawnStandpipeRiserCount(net), 2, reason: feed);
      expect(_dischargeLps(net, 2), closeTo(twoStacks, 1e-3), reason: feed);
    }
  });

  test('an outletless fill riser off the zone header is no stack: 2', () {
    final net = _fillRiser();
    expect(drawnStandpipeRiserCount(net), 2);
    expect(_dischargeLps(net, 16), closeTo(twoStacks, 1e-3));
  });

  test('a pump-room riser to a pillar ring is no stack: 2', () {
    expect(drawnStandpipeRiserCount(_pumpRiserToRing()), 2);
  });

  test('pillar drops off a ring at the pump level are no stacks: 2', () {
    final net = _hospitalRing();
    expect(drawnStandpipeRiserCount(net), 2);
    expect(_dischargeLps(net, 7), closeTo(twoStacks, 1e-3));
  });

  test(
      'a high-zone riser rising past the low zone serves from the storey '
      'below its lowest outlet: 1 stack per storey (31.545 L/s)', () {
    final net = _zoned();
    expect(drawnStandpipeRiserCount(net), 1);
    expect(_dischargeLps(net, 6), closeTo(oneStack, 1e-3));
  });

  test(
      'seeded property: every drawing direction / order keeps each count '
      '(pillars-off-base 1, twins 2, fill riser 2, pump riser 2, hospital 2)',
      () {
    final rnd = math.Random(5801);
    final cases = <(String, Network, int)>[
      ('pillarsOffBase', _pillarsOffBase(), 1),
      ('twins base', _twins('base'), 2),
      ('twins header', _twins('header'), 2),
      ('twins top', _twins('top'), 2),
      ('fillRiser', _fillRiser(), 2),
      ('pumpRiserToRing', _pumpRiserToRing(), 2),
      ('hospitalRing', _hospitalRing(), 2),
      ('zoned', _zoned(), 1),
    ];
    for (final (name, net, want) in cases) {
      for (var t = 0; t < 60; t++) {
        expect(drawnStandpipeRiserCount(_flipShuffle(net, rnd)), want,
            reason: '$name trial $t');
      }
    }
  });
}
