// Round 62 — the fire pump train is keyed on the pump it is.
//
//  * regression-yard-raise-inflates-jockey-leg /
//    fire-convergence-14-yard-raise-sizes-jockey-leg-at-38lps: the yard
//    (pillar) hydrant raise and the NFPA 20 suction rule never touch a
//    jockey pump's leg (sized on its own 1 % duty).
//  * regression-riser-discharge-below-nfpa20: a riser leaving the pump is
//    pump discharge piping (Table 4.28(a)), like a run.
//  * fire-convergence-14-pump-legs-sized-below-rated-flow: the suction /
//    discharge pipe is keyed on the flow the pump is RATED on, never on how
//    many terminals happen to be drawn.
//  * regression-duty-pick-sizer-vs-basis-disagree: on a fire service the
//    sizer's duty (tree) leg is the first-DRAWN pump's (n9 before n10).
//
// First principles (NFPA 20 Table 4.28(a), 4.16.6):
//  * 500 gpm = 500 x 3.785411784 / 60 = 31.545 L/s: the row is 5 in / 5 in;
//    on DN100 v150 = 1.5 x 0.031545 / (pi 0.1^2 / 4) = 6.02 m/s > 4.57, on
//    DN125 v150 = 0.047318 / 0.012272 = 3.86 m/s ⇒ DN125.
//  * 750 gpm = 47.318 L/s: the row is 6 in / 6 in ⇒ DN150.
//  * EH sprinkler remote area 43.33 L/s = 687 gpm ⇒ the 750 gpm row, DN150;
//    on DN125 v150 = 1.5 x 0.04333 / 0.012272 = 5.30 m/s > 4.57.
//  * a jockey at 1 % of 31.5 L/s = 0.315 L/s on the 6 m/s fire cap needs
//    d >= sqrt(4 x 0.000315 / (pi 6)) = 8.2 mm ⇒ the 25 mm fire-pipe
//    minimum, DN25 — whatever the main pumps carry.
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

BuildingLevels _floors(int n) => BuildingLevels(
    [for (var i = 0; i < n; i++) Floor('L$i', const Length(3.5))]);

const _cal = {'s1': ScaleCalibration(0.01)};
const _jockey = FlowRate(0.000315);

double _v150(EdgeSizing s) =>
    1.5 *
    s.flow.cubicMetersPerSecond /
    (math.pi * math.pow(s.diameter.meters, 2) / 4);

/// GT -> S (suction header) -> PA / PB / PJ, each through its own check
/// valve, into H -> a 4-node yard main; [pillars] puts a pillar hydrant on
/// every yard node, else a hydrant box.
Network _pumpRoom({required bool pillars}) {
  final term = pillars ? NodeComponent.pillarHydrant : NodeComponent.hydrantBox;
  return Network(nodes: [
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('S', 100),
    for (final (i, p) in ['A', 'B', 'J'].indexed) ...[
      _n('P$p', 200, y: 100.0 * i, role: NodeRole.plant, c: NodeComponent.pump),
      _n('C$p', 300, y: 100.0 * i, c: NodeComponent.checkValve),
    ],
    _n('H', 400),
    for (var k = 0; k < 4; k++) ...[
      _n('Y$k', 1000.0 + 2000 * k),
      _n('T$k', 1050.0 + 2000 * k, role: NodeRole.fixture, c: term),
    ],
  ], edges: [
    _e('g', 'GT', 'S'),
    for (final p in ['A', 'B', 'J']) ...[
      _e('s$p', 'S', 'P$p'),
      _e('d$p', 'P$p', 'C$p'),
      _e('h$p', 'C$p', 'H'),
    ],
    _e('y0', 'H', 'Y0'),
    for (var k = 1; k < 4; k++) _e('y$k', 'Y${k - 1}', 'Y$k'),
    for (var k = 0; k < 4; k++) _e('t$k', 'Y$k', 'T$k'),
  ]);
}

Map<String, EdgeSizing> _sizeRoom(Network net,
        {Map<String, Diameter> overrides = const {}}) =>
    autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {ServiceType.fireHydrant: FlowRate(0.005)},
      hydrantDesignFlow: standpipeFlow(1),
      building: _floors(1),
      calibrationBySheet: _cal,
      jockeyLegFlows: const {'PJ': _jockey},
      sizeOverrides: overrides,
    );

/// GT -> P on L0, then either a riser straight off the pump (P -> R1) or a
/// run P -> R0 and the riser R0 -> R1; [stacks] stacks of [floors] storeys
/// with a box on every floor above the pump.
Network _riserTower({required bool riserFirst, int stacks = 1}) {
  const floors = 5;
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('P', 100, role: NodeRole.plant, c: NodeComponent.pump),
    if (!riserFirst) _n('R0', 100),
    _n('R1', 100, floor: 1),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'P'),
    if (riserFirst)
      _e('d', 'P', 'R1', k: EdgeKind.riser)
    else ...[
      _e('d', 'P', 'R0'),
      _e('dr', 'R0', 'R1', k: EdgeKind.riser),
    ],
  ];
  for (var s = 0; s < stacks; s++) {
    nodes.add(_n('X${s}1', 1000.0 + 1000 * s, floor: 1));
    edges.add(_e('m$s', 'R1', 'X${s}1'));
    for (var f = 1; f < floors; f++) {
      if (f > 1) {
        nodes.add(_n('X$s$f', 1000.0 + 1000 * s, floor: f));
        edges.add(_e('x$s$f', 'X$s${f - 1}', 'X$s$f', k: EdgeKind.riser));
      }
      nodes.add(_n('B$s$f', 1100.0 + 1000 * s,
          floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
      edges.add(_e('b$s$f', 'X$s$f', 'B$s$f'));
    }
  }
  return Network(nodes: nodes, edges: edges);
}

Map<String, EdgeSizing> _sizeTower(Network net) => autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {ServiceType.fireHydrant: FlowRate(0.005)},
      hydrantDesignFlow: standpipeFlow(drawnStandpipeRiserCount(net)),
      building: _floors(5),
      calibrationBySheet: _cal,
    );

void main() {
  group('jockey legs keep their own duty', () {
    test('pillar yard == hydrant-box yard: the jockey leg is 0.315 L/s DN25',
        () {
      final pillar = _sizeRoom(_pumpRoom(pillars: true));
      final boxes = _sizeRoom(_pumpRoom(pillars: false));
      for (final id in ['sJ', 'dJ', 'hJ']) {
        expect(pillar[id]!.flow.inLitersPerSecond, closeTo(0.315, 1e-9),
            reason: id);
        expect(pillar[id]!.diameter.inMillimeters, 25, reason: id);
        expect(pillar[id]!.flow.inLitersPerSecond,
            closeTo(boxes[id]!.flow.inLitersPerSecond, 1e-9),
            reason: id);
        expect(pillar[id]!.diameter.inMillimeters,
            boxes[id]!.diameter.inMillimeters,
            reason: id);
      }
      // The main pumps' legs and the yard main still carry the 38 L/s
      // yard flow on >= DN150.
      for (final id in ['sA', 'dA', 'hA', 'y0']) {
        expect(pillar[id]!.flow.inLitersPerSecond,
            greaterThanOrEqualTo(kYardHydrantFlowLps - 1e-9),
            reason: id);
        expect(pillar[id]!.diameter.inMillimeters, greaterThanOrEqualTo(150),
            reason: id);
      }
    });

    test('an overridden DN32 jockey leg keeps 0.315 L/s (no false velocity)',
        () {
      final r = _sizeRoom(_pumpRoom(pillars: true),
          overrides: {'dJ': Diameter.mm(32)});
      expect(r['dJ']!.diameter.inMillimeters, 32);
      expect(r['dJ']!.flow.inLitersPerSecond, closeTo(0.315, 1e-9));
      // 0.000315 / (pi 0.032^2 / 4) = 0.39 m/s, far under the 6 m/s cap.
      expect(r['dJ']!.velocity.metersPerSecond, closeTo(0.392, 0.01));
    });
  });

  group('a riser leaving the pump is its discharge pipe', () {
    test('500 gpm: riser-first and run-first both DN125', () {
      final rf = _sizeTower(_riserTower(riserFirst: true));
      final run = _sizeTower(_riserTower(riserFirst: false));
      expect(rf['d']!.flow.inLitersPerSecond, closeTo(31.545, 0.01));
      expect(rf['d']!.diameter.inMillimeters, 125);
      expect(run['d']!.diameter.inMillimeters, 125);
      expect(run['dr']!.diameter.inMillimeters, 125,
          reason: 'reached through the bare bend R0, before any junction');
    });

    test('750 gpm (two stacks): riser-first DN150', () {
      final rf = _sizeTower(_riserTower(riserFirst: true, stacks: 2));
      expect(rf['d']!.flow.inLitersPerSecond, closeTo(47.318, 0.01));
      expect(rf['d']!.diameter.inMillimeters, 150);
      // The stack risers beyond the junction R1 keep their Class I size.
      expect(rf['x02']!.diameter.inMillimeters, lessThan(150));
    });
  });

  group('the pump train carries the rated flow', () {
    test('one Class I box: suction / discharge DN125 at 31.545 L/s', () {
      final net = Network(nodes: [
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('P', 100, role: NodeRole.plant, c: NodeComponent.pump),
        _n('J', 200),
        _n('B', 300, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
      ], edges: [
        _e('g', 'GT', 'P'),
        _e('d', 'P', 'J'),
        _e('x', 'J', 'B'),
      ]);
      final r = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.fireHydrant: FlowRate(0.005)},
        hydrantDesignFlow: standpipeFlow(1),
        building: _floors(1),
        calibrationBySheet: _cal,
      );
      for (final id in ['g', 'd']) {
        expect(r[id]!.flow.inLitersPerSecond, closeTo(31.545, 0.01),
            reason: id);
        expect(r[id]!.diameter.inMillimeters, 125, reason: id);
      }
      expect(_v150(r['g']!), lessThanOrEqualTo(kFirePumpSuctionMaxVelocityMps));
    });

    test('EH factory, 20 heads drawn (< the remote area): DN150', () {
      const cap = FlowRate(0.04333);
      final nodes = <NetNode>[
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('P', 100, role: NodeRole.plant, c: NodeComponent.pump),
      ];
      final edges = <NetEdge>[
        _e('g', 'GT', 'P', s: ServiceType.fireSprinkler),
      ];
      var prev = 'P';
      for (var i = 0; i < 20; i++) {
        nodes
          ..add(_n('M$i', 200.0 + 300 * i))
          ..add(_n('H$i', 200.0 + 300 * i,
              y: 100, role: NodeRole.fixture, c: NodeComponent.sprinklerHead));
        edges
          ..add(_e(i == 0 ? 'd' : 'm$i', prev, 'M$i',
              s: ServiceType.fireSprinkler))
          ..add(_e('h$i', 'M$i', 'H$i', s: ServiceType.fireSprinkler));
        prev = 'M$i';
      }
      final r = autoSizeNetwork(
        Network(nodes: nodes, edges: edges),
        const SizingContext(),
        // 20 x 1.5 L/s = 30 L/s drawn, under the 43.33 L/s remote area.
        leafDemand: const {ServiceType.fireSprinkler: FlowRate(0.0015)},
        sprinklerDemandCap: cap,
        building: _floors(1),
        calibrationBySheet: _cal,
      );
      for (final id in ['g', 'd']) {
        expect(r[id]!.flow.inLitersPerSecond, closeTo(43.33, 1e-6), reason: id);
        expect(r[id]!.diameter.inMillimeters, 150, reason: id);
      }
      expect(_v150(r['g']!), lessThanOrEqualTo(kFirePumpSuctionMaxVelocityMps));
    });
  });

  // Seeded property: two identical fire pumps on mirrored legs, minted ids
  // n9 / n10 and check valves whose String order disagrees with the pumps'
  // (n100 on n10's leg, n20 on n9's): however the nodes and edges are
  // ordered or drawn, the duty (tree) leg is the FIRST-drawn pump n9's and
  // the mirrored standby leg is n10's.
  test('property: the duty leg is the first-drawn pump (seeded)', () {
    final rnd = math.Random(62);
    for (var t = 0; t < 40; t++) {
      bool flip() => rnd.nextBool();
      NetEdge e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
          flip() ? _e(id, a, b, k: k) : _e(id, b, a, k: k);
      final nodes = <NetNode>[
        _n('n1', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('n2', 100),
        _n('n9', 200, role: NodeRole.plant, c: NodeComponent.pump),
        _n('n10', 200, y: 100, role: NodeRole.plant, c: NodeComponent.pump),
        _n('n20', 300, c: NodeComponent.checkValve),
        _n('n100', 300, y: 100, c: NodeComponent.checkValve),
        _n('n3', 400),
        _n('n4', 500, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
      ]..shuffle(rnd);
      // The pump legs are drawn in flow order (a coherent pump); the rest
      // in any direction.
      final edges = <NetEdge>[
        e('e1', 'n1', 'n2'),
        _e('e2', 'n2', 'n9'),
        _e('e3', 'n9', 'n20'),
        _e('e4', 'n20', 'n3'),
        _e('e5', 'n2', 'n10'),
        _e('e6', 'n10', 'n100'),
        _e('e7', 'n100', 'n3'),
        e('e8', 'n3', 'n4'),
      ]..shuffle(rnd);
      final standby = <String>{};
      autoSizeNetwork(
        Network(nodes: nodes, edges: edges),
        const SizingContext(),
        leafDemand: const {ServiceType.fireHydrant: FlowRate(0.005)},
        hydrantDesignFlow: standpipeFlow(1),
        building: _floors(1),
        calibrationBySheet: _cal,
        parallelLegEdgeIdsOut: standby,
      );
      expect(standby, containsAll(<String>['e6', 'e7']), reason: 'trial $t');
      expect(standby.intersection({'e2', 'e3', 'e4'}), isEmpty,
          reason: 'trial $t');
    }
  });
}
