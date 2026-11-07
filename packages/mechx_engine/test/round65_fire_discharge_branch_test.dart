// Round 65 (fire-convergence-17-discharge-header-floor-leaks-into-sprinkler-
// branch) — past a fire pump's discharge header the NFPA 20 discharge floor
// follows the onward MAIN only; a sprinkler-only branch off the header keeps
// its own size.
//
// 9-storey office: GT -> SH -> PA / PB / PJ, each on its own check-valve
// leg into header DH. DH -h0- an 8-storey Class I hydrant riser (one box a
// floor); DH -s0 (sprinkler)- SA -> an 8-storey OH1 sprinkler riser (4 heads
// a floor, remote-area cap 6 L/s). PJ is
// a jockey at 0.3 L/s.
//
//  * The pump is rated 500 gpm = 500 x 3.785411784 / 60 = 31.545 L/s:
//    h0 and the pump legs are DN125 (NFPA 20 Table 4.28(a) 500 gpm 5 in).
//  * s0 carries the sprinkler remote area, 6 L/s. On the 6 m/s fire cap
//    d >= sqrt(4 x 0.006 / (pi 6)) = 35.7 mm => DN40 is the smallest bore;
//    the sprinkler pipe minimum for a run (NFPA 13, DN25) does not govern,
//    and the riser it feeds sizes the same 6 L/s => s0 == the riser's bore
//    (v = 0.006 / (pi 0.04^2 / 4) = 4.77 m/s <= 6). Before the fix s0 was
//    issued DN125 at 31.55 L/s — 5x the flow the solve puts through it.
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

const _sp = ServiceType.fireSprinkler;

Network _office() {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('SH', 100),
    for (final (i, p) in ['A', 'B', 'J'].indexed) ...[
      _n('P$p', 200, y: 100.0 * i, role: NodeRole.plant, c: NodeComponent.pump),
      _n('C$p', 300, y: 100.0 * i, c: NodeComponent.checkValve),
    ],
    _n('DH', 400),
    _n('X0', 500),
    _n('SA', 400, y: 500),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'SH'),
    for (final p in ['A', 'B', 'J']) ...[
      _e('s$p', 'SH', 'P$p'),
      _e('d$p', 'P$p', 'C$p'),
      _e('l$p', 'C$p', 'DH'),
    ],
    _e('h0', 'DH', 'X0'),
    _e('s0', 'DH', 'SA', s: _sp),
  ];
  for (var f = 1; f <= 8; f++) {
    nodes
      ..add(_n('X$f', 500, floor: f))
      ..add(_n('B$f', 600,
          floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox))
      ..add(_n('Q$f', 400, y: 500, floor: f));
    edges
      ..add(_e('r$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser))
      ..add(_e('b$f', 'X$f', 'B$f'))
      ..add(_e('q$f', f == 1 ? 'SA' : 'Q${f - 1}', 'Q$f',
          k: EdgeKind.riser, s: _sp));
    var prev = 'Q$f';
    for (var h = 0; h < 4; h++) {
      nodes
        ..add(_n('M$f$h', 700.0 + 300 * h, floor: f, y: 500))
        ..add(_n('S$f$h', 700.0 + 300 * h,
            floor: f,
            y: 600,
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
  test('the sprinkler branch off the discharge header keeps its own size', () {
    final r = autoSizeNetwork(
      _office(),
      const SizingContext(),
      leafDemand: const {
        ServiceType.fireHydrant: FlowRate(0.005),
        _sp: FlowRate(0.0015),
      },
      hydrantDesignFlow: standpipeFlow(1),
      sprinklerDemandCap: const FlowRate(0.006),
      jockeyLegFlows: const {'PJ': FlowRate(0.0003)},
      building: BuildingLevels(
          [for (var i = 0; i < 9; i++) Floor('L$i', const Length(3.5))]),
      calibrationBySheet: const {'s1': ScaleCalibration(0.01)},
    );
    // The onward main and the pump legs keep the NFPA 20 discharge floor.
    expect(r['h0']!.flow.inLitersPerSecond, closeTo(31.545, 0.001));
    expect(r['h0']!.diameter.inMillimeters, 125);
    expect(r['lA']!.diameter.inMillimeters, 125);
    // The sprinkler branch: its own 6 L/s on the riser's bore.
    expect(r['s0']!.flow.inLitersPerSecond, closeTo(6.0, 1e-6));
    expect(r['s0']!.diameter.inMillimeters, r['q1']!.diameter.inMillimeters);
    expect(r['s0']!.diameter.inMillimeters, 40);
    expect(r['s0']!.flowFromId, 'DH');
  });
}
