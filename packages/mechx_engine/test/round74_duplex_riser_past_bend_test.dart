// Round 74 (fire-convergence-25) — a riser reached from a duplex DISCHARGE
// HEADER through bare bends (header -> main -> bend(s) -> riser foot) is the
// pump set's discharge main, floored at NFPA 20 Table 4.28(a) exactly like
// the same riser in a simplex room.
//
// First principles: one Class I stack = 500 gpm = 31.545 L/s; the 500 gpm
// table row is 5 in discharge ⇒ DN125. In the Class I DN100 riser the same
// flow is v = 0.031545 / (pi x 0.1^2 / 4) = 4.02 m/s (6.0 m/s at 150 %);
// in DN125, 2.57 / 3.85 m/s. The bore of one riser at one pump flow must not
// depend on whether a standby pump is drawn.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _floors = 10;

NetNode _n(String id, double x,
        {int floor = 0,
        double y = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y + floor * 10.0,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.fireHydrant, kind: k);

/// GT -g- SH -s1- P1 -d1- DH (+ standby / third pump legs), DH -m0- K1 ..
/// Kb -mb- X0 (bare bends), riser X0..X10 with a hydrant box per floor.
Network _room({required int pumps, required int bends}) {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('SH', 100),
    for (var i = 1; i <= pumps; i++)
      _n('P$i', 200, y: (i - 1) * 3.0, role: NodeRole.plant,
          c: NodeComponent.pump),
    _n('DH', 300),
    for (var k = 1; k <= bends; k++)
      _n('K$k', 300 + 100.0 * k, y: k.isOdd ? 50 : 0),
    _n('X0', 300 + 100.0 * (bends + 1)),
    for (var f = 1; f <= _floors; f++) ...[
      _n('X$f', 300 + 100.0 * (bends + 1), floor: f),
      _n('B$f', 500 + 100.0 * (bends + 1),
          floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
    ],
  ];
  final chain = ['DH', for (var k = 1; k <= bends; k++) 'K$k', 'X0'];
  final edges = <NetEdge>[
    _e('g', 'GT', 'SH'),
    for (var i = 1; i <= pumps; i++) ...[
      _e('s$i', 'SH', 'P$i'),
      _e('d$i', 'P$i', 'DH'),
    ],
    for (var k = 0; k + 1 < chain.length; k++)
      _e('m$k', chain[k], chain[k + 1]),
    for (var f = 1; f <= _floors; f++)
      _e('x$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser),
    for (var f = 1; f <= _floors; f++) _e('b$f', 'X$f', 'B$f'),
  ];
  return Network(nodes: nodes, edges: edges);
}

Map<String, EdgeSizing> _size(Network net) => autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {ServiceType.fireHydrant: FlowRate(0.005)},
      hydrantDesignFlow: standpipeFlow(1),
      building: BuildingLevels([
        for (var i = 0; i <= _floors; i++) Floor('L$i', const Length(4))
      ]),
      calibrationBySheet: const {'s1': ScaleCalibration(0.01)},
    );

void main() {
  test('the reviewer case: one bend, simplex vs duplex — x1 DN125 both', () {
    final simplex = _size(_room(pumps: 1, bends: 1));
    final duplex = _size(_room(pumps: 2, bends: 1));
    expect(simplex['x1']!.diameter.inMillimeters, 125);
    expect(duplex['x1']!.diameter.inMillimeters, 125);
    expect(duplex['x1']!.flow.inLitersPerSecond,
        closeTo(standpipeFlow(1).inLitersPerSecond, 1e-6));
    final v100 = standpipeFlow(1).cubicMetersPerSecond / (math.pi * 0.01 / 4);
    expect(v100, closeTo(4.02, 0.01));
  });

  test('seeded: simplex / duplex / three pumps over 0..3 bends — every '
      'common pipe bore and flow equal', () {
    final rnd = math.Random(74);
    for (var bends = 0; bends <= 3; bends++) {
      final ref = _size(_room(pumps: 1, bends: bends));
      final ids = [
        'g', 's1', 'd1',
        for (var k = 0; k <= bends; k++) 'm$k',
        for (var f = 1; f <= _floors; f++) ...['x$f', 'b$f'],
      ];
      for (final pumps in [2, 3]) {
        final got = _size(_room(pumps: pumps, bends: bends));
        for (final id in ids) {
          expect(got[id]!.diameter.inMillimeters,
              ref[id]!.diameter.inMillimeters,
              reason: 'bends $bends pumps $pumps $id');
          expect(got[id]!.flow.inLitersPerSecond,
              closeTo(ref[id]!.flow.inLitersPerSecond, 1e-6),
              reason: 'bends $bends pumps $pumps $id');
        }
      }
      // Above the first storey the riser keeps the standpipe's own size.
      final r = rnd.nextInt(_floors - 2) + 3;
      expect(ref['x$r']!.diameter.inMillimeters, lessThanOrEqualTo(125));
    }
  });
}
