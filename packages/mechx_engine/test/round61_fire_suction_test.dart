// Round 61 (fire-convergence-13-fire-pump-suction-below-nfpa20) — a fire
// pump's suction keeps <= 15 ft/s (4.57 m/s) at 150 % of its rated flow
// (NFPA 20 4.16.6), and its suction and discharge pipes floor at the NFPA 20
// Table 4.28(a) sizes for the rated flow.
//
// First principles: one Class I stack = 500 gpm = 31.545 L/s. On DN100,
// v150 = 1.5 x 0.031545 / (pi x 0.100^2 / 4) = 6.02 m/s > 4.57 m/s; on DN125
// v150 = 0.047318 / 0.012272 = 3.86 m/s <= 4.57 m/s ⇒ DN125 suction, and the
// table's 500 gpm row is 5 in / 5 in ⇒ DN125 discharge too. Two stacks =
// 750 gpm = 47.318 L/s: DN125 gives v150 = 0.070977 / 0.012272 = 5.78 m/s,
// DN150 gives 0.070977 / 0.017671 = 4.02 m/s ⇒ DN150 (the table's 6 in).
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_pump_suction.dart';
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
        y: 0,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.fireHydrant, kind: k);

BuildingLevels _floors(int n) => BuildingLevels(
    [for (var i = 0; i < n; i++) Floor('L$i', const Length(3.5))]);

/// GT -> g -> P -> d -> CV -> d2 -> J; [stacks] 6-storey stacks off J, a box
/// on every floor of each.
Network _tower(int stacks) {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('P', 100, role: NodeRole.plant, c: NodeComponent.pump),
    _n('CV', 200, c: NodeComponent.checkValve),
    _n('J', 300),
    for (var s = 0; s < stacks; s++)
      for (var f = 0; f < 6; f++) ...[
        _n('S${s}R$f', 1000.0 + 1000 * s, floor: f),
        _n('S${s}B$f', 1100.0 + 1000 * s,
            floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
      ],
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'P'),
    _e('d', 'P', 'CV'),
    _e('d2', 'CV', 'J'),
    for (var s = 0; s < stacks; s++) ...[
      _e('m$s', 'J', 'S${s}R0'),
      for (var f = 1; f < 6; f++)
        _e('S${s}r$f', 'S${s}R${f - 1}', 'S${s}R$f', k: EdgeKind.riser),
      for (var f = 0; f < 6; f++) _e('S${s}b$f', 'S${s}R$f', 'S${s}B$f'),
    ],
  ];
  return Network(nodes: nodes, edges: edges);
}

Map<String, EdgeSizing> _size(Network net) => autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {ServiceType.fireHydrant: FlowRate(0.005)},
      hydrantDesignFlow: standpipeFlow(drawnStandpipeRiserCount(net)),
      building: _floors(6),
      calibrationBySheet: const {'s1': ScaleCalibration(0.01)},
    );

double _v150(EdgeSizing s) =>
    1.5 *
    s.flow.cubicMetersPerSecond /
    (math.pi * math.pow(s.diameter.meters, 2) / 4);

void main() {
  test('one stack (500 gpm): DN125 suction and discharge', () {
    final r = _size(_tower(1));
    expect(r['g']!.flow.inLitersPerSecond, closeTo(31.545, 0.01));
    expect(r['g']!.diameter.inMillimeters, 125);
    expect(_v150(r['g']!), lessThanOrEqualTo(kFirePumpSuctionMaxVelocityMps));
    expect(r['d']!.diameter.inMillimeters, greaterThanOrEqualTo(125));
    expect(r['d2']!.diameter.inMillimeters, greaterThanOrEqualTo(125),
        reason: 'through the check valve to the first junction');
  });

  test('two stacks (750 gpm): DN150 suction (6 in), discharge >= 6 in', () {
    final r = _size(_tower(2));
    expect(r['g']!.flow.inLitersPerSecond, closeTo(47.318, 0.01));
    expect(r['g']!.diameter.inMillimeters, 150);
    expect(_v150(r['g']!), lessThanOrEqualTo(kFirePumpSuctionMaxVelocityMps));
    expect(r['d']!.diameter.inMillimeters, greaterThanOrEqualTo(150));
  });

  test('Table 4.28(a) rows', () {
    FlowRate gpm(double g) => FlowRate.litersPerSecond(g * 3.785411784 / 60);
    expect(firePumpPipeRow(gpm(100)).suctionMm, 50);
    expect(firePumpPipeRow(gpm(500)).suctionMm, 125);
    expect(firePumpPipeRow(gpm(750)).dischargeMm, 150);
    expect(firePumpPipeRow(gpm(1000)).suctionMm, 200);
    expect(firePumpPipeRow(gpm(1000)).dischargeMm, 150);
  });

  test('a hand-overridden suction keeps its size', () {
    final net = _tower(1);
    final r = autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {ServiceType.fireHydrant: FlowRate(0.005)},
      hydrantDesignFlow: standpipeFlow(1),
      building: _floors(6),
      calibrationBySheet: const {'s1': ScaleCalibration(0.01)},
      sizeOverrides: {'g': Diameter.mm(100)},
    );
    expect(r['g']!.diameter.inMillimeters, 100);
  });

  // Round 61 (fire-convergence-13-yard-hydrants-rated-as-building-
  // standpipe) — a dead-end yard main with a pillar hydrant on each node:
  // every pipe feeding a pillar hydrant carries the 38 L/s yard flow (SNI
  // 03-1735 hidran halaman) on at least DN150 (NFPA 24 10.1.1). At 38 L/s
  // and the 6 m/s cap d >= sqrt(4 x 0.038 / (pi x 6)) = 0.0898 m ⇒ DN100 on
  // velocity, so the DN150 floor governs. The pump suction then takes the
  // NFPA 20 rule on 38 L/s = 602 gpm (the 750 gpm row: 6 in); v150 on DN150
  // = 0.057 / 0.017671 = 3.23 m/s.
  test('yard main: 38 L/s on >= DN150, laterals included', () {
    final net = _yard();
    final r = autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {ServiceType.fireHydrant: FlowRate(0.005)},
      building: _floors(1),
      calibrationBySheet: const {'s1': ScaleCalibration(0.01)},
    );
    for (final e in net.edges) {
      if (e.id == 'g') continue;
      expect(r[e.id]!.flow.inLitersPerSecond,
          greaterThanOrEqualTo(kYardHydrantFlowLps - 1e-9),
          reason: e.id);
      expect(r[e.id]!.diameter.inMillimeters,
          greaterThanOrEqualTo(kMinYardMainDiameterMm),
          reason: e.id);
    }
    expect(r['g']!.diameter.inMillimeters, 150);
    expect(_v150(r['g']!), lessThanOrEqualTo(kFirePumpSuctionMaxVelocityMps));
  });

  test('no pillar hydrant: the yard pass leaves sizing untouched', () {
    final net = _tower(1);
    final again = Map.of(_size(net));
    expect(raiseYardHydrantMains(net, again, const SizingContext()), isEmpty);
  });
}

Network _yard() {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('P', 100, role: NodeRole.plant, c: NodeComponent.pump),
    for (var k = 0; k < 6; k++) ...[
      _n('Y$k', 200.0 + 4000 * k),
      _n('PH$k', 200.0 + 4000 * k + 50,
          role: NodeRole.fixture, c: NodeComponent.pillarHydrant),
    ],
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'P'),
    _e('y0', 'P', 'Y0'),
    for (var k = 1; k < 6; k++) _e('y$k', 'Y${k - 1}', 'Y$k'),
    for (var k = 0; k < 6; k++) _e('l$k', 'Y$k', 'PH$k'),
  ];
  return Network(nodes: nodes, edges: edges);
}
