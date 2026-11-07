// Round 66 (fire-convergence-18-hydrant-labelled-pump-room-rates-sprinkler-
// only-system-as-class-i-standpipe) — a standpipe basis needs a drawn HOSE
// OUTLET (the mirror of the Round-64 rule: a sprinkler basis needs a drawn
// head). A sprinkler-only system whose pump-room pipes are drawn on the
// hydrant service is rated and sized on its sprinkler demand, never on a
// phantom 500 gpm Class I standpipe.
//
// Fixture: GT -g- SH; duty PB1 (sb1, db1) and standby PB2 (sb2, db2) into
// DB; DB -mb- Q0, a 12-storey sprinkler riser Q0..Q11 (4 m storeys, 4 OH2
// heads a floor, remote-area cap 12 L/s). No hose outlet anywhere.
//
// First principles: with no hose outlet there is no standpipe demand, so
// the pump train carries the sprinkler remote-area demand, 12 L/s, whatever
// service its pipes are labelled; NFPA 20 Table 4.28(a) for 12 L/s =
// 12 x 60 / 3.785 = 190 gpm (the 200 gpm row) floors the pump suction /
// discharge at 3 in = DN80. Labelling those pipes hydrant used to add
// standpipeFlow(1) = 31.545 L/s and size them DN125.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x,
        {int floor = 0,
        double y = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b,
        {EdgeKind k = EdgeKind.run,
        ServiceType s = ServiceType.fireSprinkler}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

const _hy = ServiceType.fireHydrant, _sp = ServiceType.fireSprinkler;
const _room = ['g', 'sb1', 'db1', 'sb2', 'db2', 'mb'];

Map<String, EdgeSizing> _size(Network net) => autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {_hy: FlowRate(0.005), _sp: FlowRate(0.0015)},
      hydrantDesignFlow: standpipeFlow(1),
      sprinklerDemandCap: const FlowRate(0.012),
      building: BuildingLevels(
          [for (var i = 0; i < 12; i++) Floor('L$i', const Length(4))]),
      calibrationBySheet: const {'s1': ScaleCalibration(0.01)},
    );

Network _sys(Map<String, ServiceType> svc) {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('SH', 100),
    _n('PB1', 200, role: NodeRole.plant, c: NodeComponent.pump),
    _n('PB2', 200, y: 100, role: NodeRole.plant, c: NodeComponent.pump),
    _n('DB', 300),
    _n('Q0', 400),
  ];
  NetEdge e(String id, String a, String b) => _e(id, a, b, s: svc[id] ?? _sp);
  final edges = <NetEdge>[
    e('g', 'GT', 'SH'),
    e('sb1', 'SH', 'PB1'),
    e('db1', 'PB1', 'DB'),
    e('sb2', 'SH', 'PB2'),
    e('db2', 'PB2', 'DB'),
    e('mb', 'DB', 'Q0'),
  ];
  for (var f = 1; f < 12; f++) {
    nodes.add(_n('Q$f', 400, floor: f));
    edges.add(_e('q$f', 'Q${f - 1}', 'Q$f', k: EdgeKind.riser));
    var prev = 'Q$f';
    for (var h = 0; h < 4; h++) {
      nodes
        ..add(_n('M$f$h', 600.0 + 300 * h, floor: f, y: 400))
        ..add(_n('S$f$h', 600.0 + 300 * h,
            floor: f,
            y: 500,
            role: NodeRole.fixture,
            c: NodeComponent.sprinklerHead));
      edges
        ..add(_e('m$f$h', prev, 'M$f$h'))
        ..add(_e('h$f$h', 'M$f$h', 'S$f$h'));
      prev = 'M$f$h';
    }
  }
  return Network(nodes: nodes, edges: edges);
}

void main() {
  final base = _size(_sys(const {}));

  test('sprinkler-drawn room: 12 L/s on DN80', () {
    for (final id in _room) {
      expect(base[id]!.flow.inLitersPerSecond, closeTo(12, 1e-6), reason: id);
      expect(base[id]!.diameter.inMillimeters, 80, reason: id);
    }
  });

  test('hydrant-labelled room: no hose outlet, no standpipe term', () {
    final net = _sys({for (final id in _room) id: _hy});
    final sys = fireRatingSystems(net).single;
    expect(sys.hasHydrant, isTrue);
    expect(sys.hasHoseOutlet(net), isFalse);
    expect(sys.standpipeTermApplies(net), isFalse);
    expect(
        fireSystemDesignFlow(net, sys, sprinklerDemand: const FlowRate(0.012))!
            .inLitersPerSecond,
        closeTo(12, 1e-9));
    final r = _size(net);
    for (final id in base.keys) {
      expect(r[id]!.diameter.inMillimeters, base[id]!.diameter.inMillimeters,
          reason: id);
      expect(r[id]!.flow.inLitersPerSecond,
          closeTo(base[id]!.flow.inLitersPerSecond, 1e-6),
          reason: id);
    }
  });

  test('seeded: the service of terminal-less pipes never moves a size', () {
    final rnd = math.Random(66);
    for (var trial = 0; trial < 40; trial++) {
      final svc = {for (final id in _room) id: rnd.nextBool() ? _hy : _sp};
      final net = _sys(svc);
      final r = _size(net);
      for (final id in base.keys) {
        expect(r[id]!.diameter.inMillimeters, base[id]!.diameter.inMillimeters,
            reason: 'trial $trial $svc $id');
        expect(r[id]!.flow.inLitersPerSecond,
            closeTo(base[id]!.flow.inLitersPerSecond, 1e-6),
            reason: 'trial $trial $svc $id');
      }
      for (final s in fireRatingSystems(net)) {
        expect(
            fireSystemDesignFlow(net, s, sprinklerDemand: const FlowRate(0.012))
                ?.inLitersPerSecond,
            closeTo(12, 1e-9),
            reason: 'trial $trial $svc');
      }
    }
  });

  test('a drawn hose outlet keeps the standpipe term', () {
    final net = _sys({for (final id in _room) id: _hy});
    final withBox = Network(nodes: [
      ...net.nodes,
      _n('B1', 500,
          floor: 1, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
    ], edges: [
      ...net.edges,
      _e('bx', 'Q1', 'B1', s: _hy),
    ]);
    final sys = fireRatingSystems(withBox).single;
    expect(sys.hasHoseOutlet(withBox), isTrue);
    expect(
        fireSystemDesignFlow(withBox, sys,
                sprinklerDemand: const FlowRate(0.012))!
            .inLitersPerSecond,
        closeTo(standpipeFlow(1).inLitersPerSecond, 1e-9));
  });
}
