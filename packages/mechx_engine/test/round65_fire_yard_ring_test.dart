// Round 65 (fire-convergence-17-yard-ring-arms-sized-by-drawn-service) — a
// looped yard main supplying pillar hydrants sizes every arm on the full
// yard flow on the DN150 private main, whichever fire service the ring was
// drawn on.
//
// Distribution centre: GT -> P -> J0, ring J0..J5 (r1..r6, 40 m arms at
// 0.01 m/px), pillar hydrants on hydrant stubs off J1 / J2 / J4, a lateral
// J3 -> L -> PH3, and a sprinkler take-off J5 -> SA feeding 30 extra-hazard
// heads (remote area 10 mm/min x 260 m2 = 2600 L/min = 43.33 L/s).
//
// Every ring arm supplies a pillar hydrant (each arm lies on the one cycle,
// and r1 J0 -> J1 has PH1 downstream), so each carries >= 38 L/s
// (kYardHydrantFlowLps, SNI 03-1735) on >= DN150 (kMinYardMainDiameterMm,
// NFPA 24): on DN150, v = 0.038 / (pi 0.15^2 / 4) = 0.038 / 0.017671
// = 2.15 m/s <= 6 m/s, so DN150 governs. Before the fix the ring drawn on
// the sprinkler service kept r5 / r6 at DN65 / DN100 (the Hardy-Cross split
// turned them toward the sprinkler take-off, away from every pillar).
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
        {double y = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: 0,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b,
        {ServiceType s = ServiceType.fireHydrant}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: EdgeKind.run);

const _hy = ServiceType.fireHydrant, _sp = ServiceType.fireSprinkler;
const _eh = FlowRate(0.04333);

Map<String, EdgeSizing> _size(Network net) => autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {_hy: FlowRate(0.005), _sp: FlowRate(0.0015)},
      hydrantDesignFlow: standpipeFlow(1),
      sprinklerDemandCap: _eh,
      building: const BuildingLevels([Floor('L0', Length(6))]),
      calibrationBySheet: const {'s1': ScaleCalibration(0.01)},
    );

const _ring = ['r1', 'r2', 'r3', 'r4', 'r5', 'r6'];

/// [ring] is the service of the ring arms r1..r6; [flip] names the ring
/// arms drawn backwards.
Network _yard(ServiceType ring, {Set<String> flip = const {}}) {
  const pts = <String, (double, double)>{
    'J0': (0, 0),
    'J1': (4000, 0),
    'J2': (8000, 0),
    'J3': (8000, 4000),
    'J4': (4000, 4000),
    'J5': (0, 4000),
  };
  final nodes = <NetNode>[
    _n('GT', -2000, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('P', -1000, role: NodeRole.plant, c: NodeComponent.pump),
    for (final p in pts.entries) _n(p.key, p.value.$1, y: p.value.$2),
    for (final k in ['1', '2', '4'])
      _n('PH$k', pts['J$k']!.$1, y: pts['J$k']!.$2 + 300,
          role: NodeRole.fixture, c: NodeComponent.pillarHydrant),
    _n('L', 10000, y: 4000),
    _n('PH3', 10000, y: 4300,
        role: NodeRole.fixture, c: NodeComponent.pillarHydrant),
    _n('SA', -1000, y: 4000),
  ];
  NetEdge arm(String id, String a, String b) =>
      flip.contains(id) ? _e(id, b, a, s: ring) : _e(id, a, b, s: ring);
  final edges = <NetEdge>[
    _e('g', 'GT', 'P'),
    _e('d', 'P', 'J0'),
    arm('r1', 'J0', 'J1'),
    arm('r2', 'J1', 'J2'),
    arm('r3', 'J2', 'J3'),
    arm('r4', 'J3', 'J4'),
    arm('r5', 'J4', 'J5'),
    arm('r6', 'J5', 'J0'),
    _e('p1', 'J1', 'PH1'),
    _e('p2', 'J2', 'PH2'),
    _e('p4', 'J4', 'PH4'),
    _e('l1', 'J3', 'L'),
    _e('l2', 'L', 'PH3'),
    _e('sa', 'J5', 'SA', s: _sp),
  ];
  var prev = 'SA';
  for (var h = 0; h < 30; h++) {
    nodes
      ..add(_n('M$h', -1300.0 - 300 * h, y: 4000))
      ..add(_n('S$h', -1300.0 - 300 * h,
          y: 4300, role: NodeRole.fixture, c: NodeComponent.sprinklerHead));
    edges
      ..add(_e('m$h', prev, 'M$h', s: _sp))
      ..add(_e('h$h', 'M$h', 'S$h', s: _sp));
    prev = 'M$h';
  }
  return Network(nodes: nodes, edges: edges);
}

void main() {
  for (final svc in [_hy, _sp]) {
    test('ring on ${svc.name}: every arm >= 38 L/s on >= DN150', () {
      final r = _size(_yard(svc));
      for (final id in _ring) {
        expect(r[id]!.flow.inLitersPerSecond, greaterThanOrEqualTo(38 - 1e-9),
            reason: id);
        expect(r[id]!.diameter.inMillimeters, greaterThanOrEqualTo(150),
            reason: id);
      }
      // The pump train carries at least the sprinkler remote area.
      expect(r['d']!.flow.inLitersPerSecond, greaterThanOrEqualTo(43.33 - 1e-6));
    });
  }

  test('seeded: ring service + arm direction never move a ring arm bore', () {
    final base = _size(_yard(_hy));
    final rnd = math.Random(65);
    for (var trial = 0; trial < 40; trial++) {
      final svc = rnd.nextBool() ? _hy : _sp;
      final flip = {
        for (final id in _ring)
          if (rnd.nextBool()) id,
      };
      final r = _size(_yard(svc, flip: flip));
      for (final id in [..._ring, 'g', 'd', 'l1', 'l2']) {
        final why = 'trial $trial ${svc.name} flip $flip $id';
        expect(r[id]!.diameter.inMillimeters,
            base[id]!.diameter.inMillimeters,
            reason: why);
        expect(r[id]!.flow.inLitersPerSecond, greaterThanOrEqualTo(38 - 1e-9),
            reason: why);
      }
    }
  });
}
