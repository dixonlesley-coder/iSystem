// Round 66 (fire-convergence-18-standby-discharge-unoriented-skips-nfpa20-
// floor) — a hospital pump room drawn on the sprinkler service under a
// hydrant main sizes like the same room drawn on the hydrant service.
//
// GT -g- SH; duty PA (sa, da) and standby PB (sb, db) from SH into the
// header DH; a jockey PJ (sj, dj) SH -> DH; an FDC F -fd- DH; DH -m- R0, a
// 12-storey combined riser R0..R11 (a hydrant box and 4 OH2 heads a floor).
// On its own service the sprinkler-drawn room is a zero-demand loop, so its
// legs carried a flow entry with NO direction: the cross-service pass raised
// db to 31.55 L/s but never oriented it, the NFPA 20 pass never walked PB's
// discharge and DH (one oriented mover inflow) was no header, so db and the
// system's discharge main m stayed DN100.
//
// First principles: the riser is one Class I stack, so the set delivers
// standpipeFlow(1) = 500 gpm = 31.545 L/s. Both PA and PB discharge into DH
// (away from the tank, SH -> P -> DH); NFPA 20 Table 4.28(a) for 500 gpm
// floors each pump's discharge and the main past the header at 5 in = DN125
// (on DN100 the 31.545 L/s would run at 0.031545 / (pi 0.1^2 / 4) =
// 4.02 m/s). The room's service label cannot change any of it.
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

NetEdge _e(String id, String a, String b,
        {EdgeKind k = EdgeKind.run, ServiceType s = ServiceType.fireHydrant}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

const _hy = ServiceType.fireHydrant, _sp = ServiceType.fireSprinkler;

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

Network _hospital(ServiceType room) {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('SH', 100),
    _n('PA', 200, role: NodeRole.plant, c: NodeComponent.pump),
    _n('PB', 200, y: 100, role: NodeRole.plant, c: NodeComponent.pump),
    _n('PJ', 200, y: 200, role: NodeRole.plant, c: NodeComponent.pump),
    _n('DH', 300),
    _n('F', 300, y: -200, c: NodeComponent.fireDeptConnection),
    _n('R0', 400),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'SH', s: room),
    _e('sa', 'SH', 'PA', s: room),
    _e('da', 'PA', 'DH', s: room),
    _e('sb', 'SH', 'PB', s: room),
    _e('db', 'PB', 'DH', s: room),
    _e('sj', 'SH', 'PJ', s: room),
    _e('dj', 'PJ', 'DH', s: room),
    _e('fd', 'F', 'DH', s: room),
    _e('m', 'DH', 'R0'),
  ];
  for (var f = 1; f < 12; f++) {
    nodes
      ..add(_n('R$f', 400, floor: f))
      ..add(_n('B$f', 500,
          floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
    edges
      ..add(_e('r$f', 'R${f - 1}', 'R$f', k: EdgeKind.riser))
      ..add(_e('b$f', 'R$f', 'B$f'));
    var prev = 'R$f';
    for (var h = 0; h < 4; h++) {
      nodes
        ..add(_n('M$f$h', 600.0 + 300 * h, floor: f, y: 400))
        ..add(_n('S$f$h', 600.0 + 300 * h,
            floor: f,
            y: 500,
            role: NodeRole.fixture,
            c: NodeComponent.sprinklerHead));
      edges
        ..add(_e('m$f$h', prev, 'M$f$h', s: _sp))
        ..add(_e('h$f$h', 'M$f$h', 'S$f$h', s: _sp));
      prev = 'M$f$h';
    }
  }
  return Network(nodes: nodes, edges: edges);
}

void main() {
  final hy = _size(_hospital(_hy));
  final sp = _size(_hospital(_sp));

  test('hydrant-drawn room: discharges + main DN125 at 31.545 L/s', () {
    for (final id in ['da', 'db', 'm']) {
      expect(hy[id]!.flow.inLitersPerSecond, closeTo(31.545, 0.001),
          reason: id);
      expect(hy[id]!.diameter.inMillimeters, 125, reason: id);
    }
    expect(hy['da']!.flowFromId, 'PA');
    expect(hy['db']!.flowFromId, 'PB');
  });

  test('sprinkler-drawn room == hydrant-drawn room', () {
    for (final id in ['g', 'sa', 'da', 'sb', 'db', 'sj', 'dj', 'm']) {
      expect(sp[id]?.diameter.inMillimeters, hy[id]?.diameter.inMillimeters,
          reason: id);
      expect(sp[id]?.flow.inLitersPerSecond,
          closeTo(hy[id]?.flow.inLitersPerSecond ?? 0, 1e-6),
          reason: id);
      expect(sp[id]?.flowFromId, hy[id]?.flowFromId, reason: id);
    }
  });
}
