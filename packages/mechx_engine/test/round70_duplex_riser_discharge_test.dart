// Round 70 (regression-duplex-riser-main-skips-nfpa20-discharge) — a riser
// main leaving a duplex pump room's DISCHARGE HEADER is the pump set's
// discharge pipe, floored at NFPA 20 Table 4.28(a) exactly like the same
// riser leaving a simplex room's bare discharge node.
//
// First principles: one Class I stack = 500 gpm = 31.545 L/s; the table's
// 500 gpm row is 5 in suction / 5 in discharge ⇒ DN125. The DN100 Class I
// riser minimum would carry v = 0.031545 / (pi x 0.1^2 / 4) = 4.02 m/s, but
// the table row governs the pump's own discharge main ⇒ DN125, simplex and
// duplex alike.
library;

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
        y: floor * 10.0,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.fireHydrant, kind: k);

/// GT -g- S -s1- P1 -d1- DH [S -s2- P2 -d2- DH], riser r1 DH->X1..X7 with a
/// hydrant box on each floor.
Network _room({required bool duplex}) => Network(nodes: [
      _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
      _n('S', 100),
      _n('P1', 200, role: NodeRole.plant, c: NodeComponent.pump),
      if (duplex) _n('P2', 210, role: NodeRole.plant, c: NodeComponent.pump),
      _n('DH', 300),
      for (var f = 1; f <= 7; f++) ...[
        _n('X$f', 300, floor: f),
        _n('B$f', 400,
            floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
      ],
    ], edges: [
      _e('g', 'GT', 'S'),
      _e('s1', 'S', 'P1'),
      _e('d1', 'P1', 'DH'),
      if (duplex) ...[_e('s2', 'S', 'P2'), _e('d2', 'P2', 'DH')],
      _e('r1', 'DH', 'X1', k: EdgeKind.riser),
      for (var f = 2; f <= 7; f++)
        _e('r$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser),
      for (var f = 1; f <= 7; f++) _e('b$f', 'X$f', 'B$f'),
    ]);

Map<String, EdgeSizing> _size(Network net) => autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {ServiceType.fireHydrant: FlowRate(0.005)},
      hydrantDesignFlow: standpipeFlow(1),
      building: BuildingLevels(
          [for (var i = 0; i < 8; i++) Floor('L$i', const Length(3.5))]),
      calibrationBySheet: const {'s1': ScaleCalibration(0.01)},
    );

void main() {
  test('riser main off a duplex discharge header = simplex (DN125, 500 gpm)',
      () {
    final simplex = _size(_room(duplex: false));
    final duplex = _size(_room(duplex: true));
    expect(simplex['r1']!.diameter.inMillimeters, 125);
    expect(duplex['r1']!.diameter.inMillimeters, 125);
    expect(duplex['r1']!.flow.inLitersPerSecond,
        closeTo(standpipeFlow(1).inLitersPerSecond, 1e-6));
    for (final id in ['g', 's1', 's2', 'd1', 'd2']) {
      expect(duplex[id]!.diameter.inMillimeters, 125, reason: id);
    }
    // Above the first storey the riser is the standpipe's own pipe.
    expect(duplex['r3']!.diameter.inMillimeters,
        simplex['r3']!.diameter.inMillimeters);
  });
}
