// Round 48 — a hydrant RING main is trunk all the way round
// (mech-convergence-3-hydrant-ring-mixed-trunk-promotion).
import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, double y,
        {NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: 0,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b) =>
    NetEdge(id: id, fromId: a, toId: b, service: ServiceType.fireHydrant);

const _cal = {'s1': ScaleCalibration(0.1)}; // 0.1 m / px
const _b = BuildingLevels([Floor('GF', Length(6))]);

/// Single-storey factory: FT -> FP -> A, a 100 x 60 m ring
/// A-Y1-B-Y2-C-Y3-D-Y4-A with yard hydrant boxes HY1..HY4 on Y1..Y4.
Network _factory() => Network(nodes: [
      _n('FT', -200, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
      _n('FP', -100, 0, role: NodeRole.plant, c: NodeComponent.pump),
      _n('A', 0, 0),
      _n('Y1', 500, 0),
      _n('B', 1000, 0),
      _n('Y2', 1000, 300),
      _n('C', 1000, 600),
      _n('Y3', 500, 600),
      _n('D', 0, 600),
      _n('Y4', 0, 300),
      for (final (id, x, y) in [
        ('HY1', 500.0, -20.0),
        ('HY2', 1020.0, 300.0),
        ('HY3', 500.0, 620.0),
        ('HY4', -20.0, 300.0),
      ])
        _n(id, x, y, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
    ], edges: [
      _e('ft', 'FT', 'FP'),
      _e('fa', 'FP', 'A'),
      _e('a1', 'A', 'Y1'),
      _e('1b', 'Y1', 'B'),
      _e('b2', 'B', 'Y2'),
      _e('2c', 'Y2', 'C'),
      _e('c3', 'C', 'Y3'),
      _e('3d', 'Y3', 'D'),
      _e('d4', 'D', 'Y4'),
      _e('4a', 'Y4', 'A'),
      for (var i = 1; i <= 4; i++) _e('h$i', 'Y$i', 'HY$i'),
    ]);

const _ring = ['a1', '1b', 'b2', '2c', 'c3', '3d', 'd4', '4a'];

void main() {
  final net = _factory();
  final design = standpipeFlow(1); // 500 gpm = 31.545 L/s
  final sized = autoSizeNetwork(
    net,
    const SizingContext(),
    leafDemand: const {ServiceType.fireHydrant: FlowRate(0.005)},
    hydrantDesignFlow: design,
    building: _b,
    calibrationBySheet: _cal,
  );
  double len(NetEdge e) =>
      edgeLength(e, net, calibrationBySheet: _cal, building: _b).meters;

  test('every ring edge carries the 500 gpm design flow, one bore', () {
    // 500 gpm × 3.785411784 / 60 = 31.545 L/s; d = √(4Q / (π · 6 m/s)) =
    // 0.0818 m ⇒ DN100 round the WHOLE ring (the far side used to keep
    // 0.6–4.4 L/s and size DN65).
    for (final id in _ring) {
      expect(sized[id]!.flow.cubicMetersPerSecond,
          closeTo(design.cubicMetersPerSecond, 1e-12),
          reason: id);
      expect(sized[id]!.diameter.inMillimeters, closeTo(100, 1e-9), reason: id);
    }
    // No ring pipe carries more than the feed (the feed node never sends out
    // more per arm than it receives).
    final feed = sized['fa']!.flow.cubicMetersPerSecond;
    expect(feed, closeTo(design.cubicMetersPerSecond, 1e-12));
    for (final id in _ring) {
      expect(sized[id]!.flow.cubicMetersPerSecond, lessThanOrEqualTo(feed));
    }
    // A single-box branch keeps its own 5 L/s.
    expect(sized['h2']!.flow.cubicMetersPerSecond, closeTo(0.005, 1e-15));
  });

  test(
      'rated index friction >= the equal-head ring split to the governing '
      'hydrant', () {
    final sys = fireSystems(net).single;
    final f = fireIndexPathFrictionM(
        net: net, system: sys, pumpId: 'FP', sizing: sized, lengthOf: len)!;
    // HY2 (on Y2) governs: arms A-Y1-B-Y2 = 50 + 50 + 30 = 130 m and
    // A-Y4-D-Y3-C-Y2 = 30 + 30 + 50 + 50 + 30 = 190 m, both DN100, C 120.
    // Equal head: Q1 / Q2 = (190 / 130)^(1 / 1.852); Q1 + Q2 = 31.545 L/s.
    const c = 120.0;
    final d = sized['a1']!.diameter;
    double hw(double q, double l, [Diameter? bore]) => headLossHazenWilliams(
            flow: FlowRate(q),
            length: Length(l),
            diameter: bore ?? d,
            hazenWilliamsC: c)
        .meters;
    // Round 61 — the feed FP -> A is the pump DISCHARGE, floored at the
    // NFPA 20 Table 4.28(a) 5 in (DN125) for 500 gpm: its friction is
    // reckoned at its own bore.
    final dFeed = sized['fa']!.diameter;
    expect(dFeed.inMillimeters, 125);
    final q = design.cubicMetersPerSecond;
    final ratio = 1 / (1 + 1 / math.pow(190 / 130, 1 / 1.852));
    final q1 = q * ratio; // the short arm's share
    final split = hw(q1, 130) + hw(q, len(net.edgeById('fa')!), dFeed);
    expect(hw(q - q1, 190), closeTo(hw(q1, 130), 1e-6)); // equal head
    expect(f, greaterThanOrEqualTo(split));
    // The engine reads the full flow along the shorter arm (conservative).
    final fullArm = hw(q, 130) + hw(q, len(net.edgeById('fa')!), dFeed);
    expect(f, greaterThanOrEqualTo(fullArm - 1e-9));
  });

  test('a tree hydrant layout is unchanged (no cycle, no promotion)', () {
    final tree = Network(nodes: net.nodes, edges: [
      for (final e in net.edges)
        if (e.id != '4a') e
    ]);
    final s = autoSizeNetwork(
      tree,
      const SizingContext(),
      leafDemand: const {ServiceType.fireHydrant: FlowRate(0.005)},
      hydrantDesignFlow: design,
      building: _b,
      calibrationBySheet: _cal,
    );
    // The open end D-Y4 serves one box only (5 L/s) — a tree branch.
    expect(s['d4']!.flow.cubicMetersPerSecond, closeTo(0.005, 1e-12));
    expect(s['a1']!.flow.cubicMetersPerSecond,
        closeTo(design.cubicMetersPerSecond, 1e-12));
  });
}
