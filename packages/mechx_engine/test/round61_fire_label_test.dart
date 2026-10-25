// Round 61 (regression-fire-system-label-tank-member-order) — a storage tank
// bounds fire systems and carries NO system label, so a riser component's
// systems are its non-tank members' labels: the tall-stack / branch-drop
// reading never depends on which member a Set lists first (edge order).
//
// Topology (a realistic top-floor booster): roof tank RT on L4. System Y is
// a gravity stack RT -riser-> Y3..Y0 with hose boxes on L1-L3. System X is
// RT -> booster XP -> header XH -> two one-storey wing risers A4->A3 and
// B4->B3, a box on each A3 / B3. X's wings are two independent stacks of X
// (no tall stack of X spans them): 2 parallel stacks = 500 + 250 = 750 gpm.
// Y is a different system (joined only THROUGH the tank) so its tall stack
// never makes X's wings branch drops. Order-independence (Round 7): the
// count is the same for every node / edge shuffle.
library;

import 'dart:math' as math;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
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

NetNode _box(String id, double x, int floor) => _n(id, x,
    floor: floor, role: NodeRole.fixture, c: NodeComponent.hydrantBox);

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.fireHydrant, kind: k);

Network _booster() {
  final nodes = <NetNode>[
    _n('RT', 0, floor: 4, role: NodeRole.plant, c: NodeComponent.roofTank),
    for (var f = 0; f < 4; f++) _n('Y$f', 0, floor: f),
    for (var f = 1; f < 4; f++) _box('YB$f', 50, f),
    _n('XP', 300, floor: 4, role: NodeRole.plant, c: NodeComponent.pump),
    _n('XH', 400, floor: 4),
    _n('A4', 800, floor: 4),
    _n('A3', 800, floor: 3),
    _box('AB', 850, 3),
    _n('B4', 1600, floor: 4),
    _n('B3', 1600, floor: 3),
    _box('BB', 1650, 3),
  ];
  final edges = <NetEdge>[
    _e('y4', 'RT', 'Y3', k: EdgeKind.riser),
    for (var f = 3; f > 0; f--)
      _e('y$f', 'Y$f', 'Y${f - 1}', k: EdgeKind.riser),
    for (var f = 1; f < 4; f++) _e('yb$f', 'Y$f', 'YB$f'),
    _e('xs', 'RT', 'XP'),
    _e('xd', 'XP', 'XH'),
    _e('xa', 'XH', 'A4'),
    _e('xb', 'XH', 'B4'),
    _e('ra', 'A4', 'A3', k: EdgeKind.riser),
    _e('rb', 'B4', 'B3', k: EdgeKind.riser),
    _e('ab', 'A3', 'AB'),
    _e('bb', 'B3', 'BB'),
  ];
  return Network(nodes: nodes, edges: edges);
}

void main() {
  test('booster wings off a roof tank count 2, invariant to order', () {
    final base = _booster();
    final rnd = math.Random(6101);
    final drawn = <int>{};
    final xCounts = <int>{};
    for (var trial = 0; trial < 60; trial++) {
      final nodes = [...base.nodes]..shuffle(rnd);
      final edges = [...base.edges]..shuffle(rnd);
      final net = Network(nodes: nodes, edges: edges);
      drawn.add(drawnStandpipeRiserCount(net));
      final x = fireRatingSystems(net).firstWhere(
          (s) => s.edges.any((e) => e.id == 'xd'));
      xCounts.add(parallelStandpipeCount(net, x.edges));
    }
    expect(xCounts, {2}, reason: 'two independent top-floor wing stacks');
    expect(drawn, {2});
  });
}
