// Round 63 (fire-convergence-15-fdc-chain-walks-up-combined-main) — an FDC
// teed into a combined main ends its inlet chain at the first junction of
// ANY fire service, so the main keeps its tree orientation and size whether
// the drafter drew it as hydrant or sprinkler pipe, with or without the FDC.
//
// Probe: GT -> P -> H -> J1 (yard pillar tee) -> M, three combined risers
// off M (sprinkler-drawn, a hydrant box on every floor 1..4), FDC at M.
//
// First principles:
//  * three Class I stacks: standpipeFlow(3) = 500 + 2 x 250 = 1000 gpm, the
//    flow the caller passes as hydrantDesignFlow (1000 x 3.785411784 / 60 =
//    63.09 L/s);
//  * the main J1 -> M carries that flow FROM the pump side (flowFromId J1);
//    on the 6 m/s fire cap d >= sqrt(4 x 0.06309 / (pi x 6)) = 115.7 mm =>
//    DN125 (v = 0.06309 / 0.012272 = 5.14 m/s);
//  * the FDC chain (M -> F) is sized on the largest fire flow at its join
//    (63.09 L/s) and never below the DN100 FDC minimum => DN125 as well.
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

const _cal = {'s1': ScaleCalibration(0.01)};

Network _probe({required ServiceType main, required bool fdc}) {
  const sp = ServiceType.fireSprinkler;
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('P', 100, role: NodeRole.plant, c: NodeComponent.pump),
    _n('H', 200),
    _n('J1', 1000),
    _n('PL', 1000,
        y: 200, role: NodeRole.fixture, c: NodeComponent.pillarHydrant),
    _n('M', 2000),
    if (fdc) _n('F', 2000, y: -300, c: NodeComponent.fireDeptConnection),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'P', s: main),
    _e('d', 'P', 'H', s: main),
    _e('hj', 'H', 'J1', s: main),
    _e('pl', 'J1', 'PL'),
    _e('jm', 'J1', 'M', s: main),
    if (fdc) _e('f', 'F', 'M'),
  ];
  for (var s = 0; s < 3; s++) {
    nodes.add(_n('X${s}0', 2500.0 + 500 * s));
    edges.add(_e('m$s', 'M', 'X${s}0', s: sp));
    for (var f = 1; f <= 4; f++) {
      nodes
        ..add(_n('X$s$f', 2500.0 + 500 * s, floor: f))
        ..add(_n('B$s$f', 2600.0 + 500 * s,
            floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
      edges
        ..add(_e('r$s$f', 'X$s${f - 1}', 'X$s$f', k: EdgeKind.riser, s: sp))
        ..add(_e('b$s$f', 'X$s$f', 'B$s$f'));
    }
  }
  return Network(nodes: nodes, edges: edges);
}

Map<String, EdgeSizing> _size(Network net, Map<String, String> flowFrom) =>
    autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {
        ServiceType.fireHydrant: FlowRate(0.005),
        ServiceType.fireSprinkler: FlowRate(0.0015),
      },
      hydrantDesignFlow: standpipeFlow(3),
      building: BuildingLevels(
          [for (var i = 0; i < 5; i++) Floor('L$i', const Length(3.5))]),
      calibrationBySheet: _cal,
    )..forEach((k, v) {
        if (v.flowFromId != null) flowFrom[k] = v.flowFromId!;
      });

void main() {
  test('standpipeFlow(3) is 1000 gpm = 63.09 L/s', () {
    expect(standpipeFlow(3).inLitersPerSecond, closeTo(63.09, 0.01));
  });

  for (final main in [ServiceType.fireHydrant, ServiceType.fireSprinkler]) {
    for (final fdc in [false, true]) {
      test('main on ${main.name}, fdc $fdc: jm DN125 from J1', () {
        final from = <String, String>{};
        final r = _size(_probe(main: main, fdc: fdc), from);
        expect(r['jm']!.diameter.inMillimeters, 125);
        expect(r['jm']!.flow.inLitersPerSecond, closeTo(63.09, 0.05));
        expect(from['jm'], 'J1', reason: 'the main flows from the pump side');
        if (fdc) {
          expect(r['f']!.diameter.inMillimeters, greaterThanOrEqualTo(100));
          expect(r['f']!.diameter.inMillimeters, 125);
          expect(r['f']!.flow.inLitersPerSecond, closeTo(63.09, 0.05));
          expect(from['f'], 'F', reason: 'the FDC chain flows inward');
        }
      });
    }
  }
}
