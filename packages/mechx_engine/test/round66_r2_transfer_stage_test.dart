// Round 66 r2 — the Round-66 mover-leg re-orientation must never reverse a
// transfer / series stage pump's DISCHARGE in a mixed-service system.
//
// `fireSourceHops` seeds every non-mover fire plant at hop 0, the
// destination (break / roof) tank of a transfer stage included, so the hops
// FALL along the discharge toward it. Re-orienting every pipe of a pump's
// degree-2 legs "lower hop first" turned the discharge t / tr back into the
// pump (t from T0, tr from BT) and dropped them DN125 -> DN100, below the
// Round-61 NFPA 20 discharge floor. The gate now turns a leg pipe only when
// its arrow points back INTO the pump from the end with MORE hops.
//
// First principles: the transfer pump P lifts the zone the roof tank BT
// feeds — one Class I stack, standpipeFlow(1) = 500 gpm = 500 x 3.785411784
// / 60 = 31.545 L/s — and NFPA 20 Table 4.28(a) for 500 gpm floors its
// suction and discharge at 5 in = DN125 all the way to the tank. Which fire
// service a pump-room pipe is drawn on must not move a size or an arrow.
library;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
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

const _hy = ServiceType.fireHydrant, _sp = ServiceType.fireSprinkler;
const _cal = {'s1': ScaleCalibration(0.01)};

Map<String, EdgeSizing> _size(Network net) => autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {_hy: FlowRate(0.005), _sp: FlowRate(0.0015)},
      hydrantDesignFlow: standpipeFlow(1),
      sprinklerDemandCap: const FlowRate(0.012),
      building: BuildingLevels(
          [for (var i = 0; i < 9; i++) Floor('L$i', const Length(3.5))]),
      calibrationBySheet: _cal,
    );

NetEdge _e(String id, String a, String b, Map<String, ServiceType> svc,
        {EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: svc[id] ?? _hy, kind: k);

void _zone(List<NetNode> nodes, List<NetEdge> edges,
    Map<String, ServiceType> svc) {
  for (var f = 5; f <= 8; f++) {
    nodes
      ..add(_n('X$f', 500, floor: f))
      ..add(_n('B$f', 600,
          floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
    edges
      ..add(_e('r$f', 'X${f - 1}', 'X$f', svc, k: EdgeKind.riser))
      ..add(_e('b$f', 'X$f', 'B$f', svc));
  }
}

/// GT -g- SH -s- P -d- DS -t- T0 -tr(riser)- BT (roof tank, L4) -o- X4,
/// a hydrant riser X4..X8 with one box on L5..L8.
Network _transfer(Map<String, ServiceType> svc) {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('SH', 100),
    _n('P', 200, role: NodeRole.plant, c: NodeComponent.pump),
    _n('DS', 300),
    _n('T0', 400),
    _n('BT', 400, floor: 4, role: NodeRole.plant, c: NodeComponent.roofTank),
    _n('X4', 500, floor: 4),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'SH', svc),
    _e('s', 'SH', 'P', svc),
    _e('d', 'P', 'DS', svc),
    _e('t', 'DS', 'T0', svc),
    _e('tr', 'T0', 'BT', svc, k: EdgeKind.riser),
    _e('o', 'BT', 'X4', svc),
  ];
  _zone(nodes, edges, svc);
  return Network(nodes: nodes, edges: edges);
}

/// A series room: GT -g- SH -s- P1 -d- DS -t- T0 -tr(riser)- BT (break tank
/// on L4) -s2- P2 (L4) -d2- X4, the upper zone riser X4..X8 (box on L5..L8).
Network _series(Map<String, ServiceType> svc) {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('SH', 100),
    _n('P1', 200, role: NodeRole.plant, c: NodeComponent.pump),
    _n('DS', 300),
    _n('T0', 400),
    _n('BT', 400, floor: 4, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('P2', 450, floor: 4, role: NodeRole.plant, c: NodeComponent.pump),
    _n('X4', 500, floor: 4),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'SH', svc),
    _e('s', 'SH', 'P1', svc),
    _e('d', 'P1', 'DS', svc),
    _e('t', 'DS', 'T0', svc),
    _e('tr', 'T0', 'BT', svc, k: EdgeKind.riser),
    _e('s2', 'BT', 'P2', svc),
    _e('d2', 'P2', 'X4', svc),
  ];
  _zone(nodes, edges, svc);
  return Network(nodes: nodes, edges: edges);
}

void _expectSame(
    Map<String, EdgeSizing> r, Map<String, EdgeSizing> base, String why) {
  expect(r.keys.toSet(), base.keys.toSet(), reason: why);
  for (final id in base.keys) {
    expect(r[id]!.flow.inLitersPerSecond,
        closeTo(base[id]!.flow.inLitersPerSecond, 1e-6),
        reason: '$why $id');
    expect(r[id]!.diameter.inMillimeters, base[id]!.diameter.inMillimeters,
        reason: '$why $id');
    expect(r[id]!.flowFromId, base[id]!.flowFromId, reason: '$why $id');
  }
}

void main() {
  group('transfer stage', () {
    final base = _size(_transfer(const {}));

    test('all-hydrant: the discharge flows to the tank at DN125', () {
      for (final id in ['s', 'd', 't', 'tr']) {
        expect(base[id]!.diameter.inMillimeters, 125, reason: id);
        expect(base[id]!.flow.inLitersPerSecond, closeTo(31.545, 0.001),
            reason: id);
      }
      expect(base['d']!.flowFromId, 'P');
      expect(base['t']!.flowFromId, 'DS');
      expect(base['tr']!.flowFromId, 'T0');
    });

    test('only s on the sprinkler service == all-hydrant (the regression)',
        () {
      final r = _size(_transfer(const {'s': _sp}));
      expect(r['t']!.flowFromId, 'DS');
      expect(r['tr']!.flowFromId, 'T0');
      expect(r['t']!.diameter.inMillimeters, 125);
      expect(r['tr']!.diameter.inMillimeters, 125);
      _expectSame(r, base, 's sprinkler');
    });

    // Recorded residual (pre-existing on 0e4a3fc, unchanged here): drawing
    // g, d, t or tr ALONE on the sprinkler service still moves an arrow
    // (and a DN125 -> DN100) — the fragment it ends roots at the hop-0
    // tank. Only the drawing the Round-66 loop regressed is pinned.
  });

  group('series room (GT -> P1 -> break tank -> P2 -> upper zone)', () {
    final base = _size(_series(const {}));

    test('all-hydrant: both stages flow away from their tank', () {
      expect(base['d']!.flowFromId, 'P1');
      expect(base['t']!.flowFromId, 'DS');
      expect(base['tr']!.flowFromId, 'T0');
      expect(base['d2']!.flowFromId, 'P2');
      expect(base['s2']!.flowFromId, 'BT');
    });

    // Recorded residual (pre-existing on 0e4a3fc): g, s, t or tr alone on
    // the sprinkler service still moves an arrow / the lower discharge
    // bore; the lower discharge leg and both upper-stage legs are pinned.
    test('a pump-room pipe on the sprinkler service == all-hydrant', () {
      for (final id in ['d', 's2', 'd2']) {
        _expectSame(_size(_series({id: _sp})), base, '$id sprinkler');
      }
    });
  });
}
