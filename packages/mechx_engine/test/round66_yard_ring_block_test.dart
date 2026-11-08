// Round 66 (regression-yard-ring-arms-merge-cycles-at-articulation-node) —
// a yard-ring cycle group is one BICONNECTED block: a sprinkler loop teed
// AT a ring node shares only that articulation node with the yard ring, so
// it is its own block, supplies no pillar hydrant, and keeps its own
// sprinkler sizing (never the 38 L/s / DN150 yard main).
//
// Fixture: GT -> P -> J0, a hydrant ring J0-J1-J2-J3 (40 m arms at
// 0.01 m/px), a pillar hydrant off J1, and a sprinkler loop X1-X2-X3
// (q1 T->X1, q2 X1->X2, q3 X2->X3, q4 X3->T) with 4 heads on each X node.
// T is either the ring node J3 itself ("at") or the far end of a 3 m
// sprinkler stub J3 -> T ("stub").
//
// First principles: the loop's flow is set by its own heads alone; whether
// its tee node is a ring node or a stub end 3 m off one cannot change how
// its 12 heads draw water, so q1..q4 carry the same flows and bores in both
// drawings, and by continuity at T: q1 + q4 = the 12-head demand that the
// stub carries. Every ring arm supplies the pillar (each lies on the one
// yard cycle) and keeps >= 38 L/s on >= DN150 in both drawings.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _hy = ServiceType.fireHydrant, _sp = ServiceType.fireSprinkler;

NetNode _n(String id, double x,
        {double y = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: 0,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b, {ServiceType s = _hy}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: EdgeKind.run);

Map<String, EdgeSizing> _size(Network net) => autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {_hy: FlowRate(0.005), _sp: FlowRate(0.0015)},
      hydrantDesignFlow: standpipeFlow(1),
      sprinklerDemandCap: const FlowRate(0.04333),
      building: const BuildingLevels([Floor('L0', Length(6))]),
      calibrationBySheet: const {'s1': ScaleCalibration(0.01)},
    );

Network _yard({required bool stub, Set<String> flip = const {}}) {
  final nodes = <NetNode>[
    _n('GT', -2000, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('P', -1000, role: NodeRole.plant, c: NodeComponent.pump),
    _n('J0', 0),
    _n('J1', 4000),
    _n('J2', 4000, y: 4000),
    _n('J3', 0, y: 4000),
    _n('PH1', 4000,
        y: -300, role: NodeRole.fixture, c: NodeComponent.pillarHydrant),
    if (stub) _n('T', 0, y: 4300),
    _n('X1', -1000, y: 5000),
    _n('X2', 0, y: 6000),
    _n('X3', 1000, y: 5000),
  ];
  final t = stub ? 'T' : 'J3';
  NetEdge e(String id, String a, String b, {ServiceType s = _hy}) =>
      flip.contains(id) ? _e(id, b, a, s: s) : _e(id, a, b, s: s);
  final edges = <NetEdge>[
    _e('g', 'GT', 'P'),
    _e('d', 'P', 'J0'),
    e('r1', 'J0', 'J1'),
    e('r2', 'J1', 'J2'),
    e('r3', 'J2', 'J3'),
    e('r4', 'J3', 'J0'),
    _e('p1', 'J1', 'PH1'),
    if (stub) _e('st', 'J3', 'T', s: _sp),
    e('q1', t, 'X1', s: _sp),
    e('q2', 'X1', 'X2', s: _sp),
    e('q3', 'X2', 'X3', s: _sp),
    e('q4', 'X3', t, s: _sp),
  ];
  for (final x in ['X1', 'X2', 'X3']) {
    final xn = nodes.firstWhere((n) => n.id == x);
    for (var h = 0; h < 4; h++) {
      nodes.add(_n('$x-S$h', xn.x + 100.0 * (h + 1),
          y: xn.y + 200,
          role: NodeRole.fixture,
          c: NodeComponent.sprinklerHead));
      edges.add(_e('$x-h$h', x, '$x-S$h', s: _sp));
    }
  }
  return Network(nodes: nodes, edges: edges);
}

void main() {
  test('a sprinkler loop teed AT a ring node sizes like one 3 m off it', () {
    final at = _size(_yard(stub: false));
    final st = _size(_yard(stub: true));
    for (final id in ['q1', 'q2', 'q3', 'q4']) {
      expect(at[id]!.diameter.inMillimeters, st[id]!.diameter.inMillimeters,
          reason: id);
      expect(at[id]!.flow.inLitersPerSecond,
          closeTo(st[id]!.flow.inLitersPerSecond, 1e-6),
          reason: id);
      expect(at[id]!.diameter.inMillimeters, lessThan(150), reason: id);
      expect(at[id]!.flow.inLitersPerSecond, lessThan(38), reason: id);
    }
    // Continuity at T: the two loop legs leaving T carry the stub's flow.
    expect(at['q1']!.flow.inLitersPerSecond + at['q4']!.flow.inLitersPerSecond,
        closeTo(st['st']!.flow.inLitersPerSecond, 1e-6));
    for (final r in [at, st]) {
      for (final id in ['r1', 'r2', 'r3', 'r4']) {
        expect(r[id]!.diameter.inMillimeters, greaterThanOrEqualTo(150),
            reason: id);
        expect(r[id]!.flow.inLitersPerSecond, greaterThanOrEqualTo(38 - 1e-9),
            reason: id);
      }
    }
  });

  test('seeded: drawn direction never makes the loop a yard main', () {
    final base = _size(_yard(stub: true));
    final rnd = math.Random(66);
    const ids = ['r1', 'r2', 'r3', 'r4', 'q1', 'q2', 'q3', 'q4'];
    for (var trial = 0; trial < 30; trial++) {
      final flip = {
        for (final id in ids)
          if (rnd.nextBool()) id,
      };
      final r = _size(_yard(stub: rnd.nextBool(), flip: flip));
      for (final id in ['q1', 'q2', 'q3', 'q4']) {
        expect(r[id]!.diameter.inMillimeters, base[id]!.diameter.inMillimeters,
            reason: 'trial $trial flip $flip $id');
      }
      for (final id in ['r1', 'r2', 'r3', 'r4']) {
        expect(r[id]!.diameter.inMillimeters, greaterThanOrEqualTo(150),
            reason: 'trial $trial flip $flip $id');
      }
    }
  });
}
