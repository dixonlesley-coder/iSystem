// Round 56 (2026-10-18) — fire engine pins:
//
//   regression-feedsOwnOutlet-walks-past-first-hose-outlet — a hydrant box
//     drawn ON a cross-tie between a sprinkler riser and a hydrant stack is
//     still an outlet fed off the sprinkler riser above its base: 2 stacks.
//   fire-convergence-8-standpipe-stack-count-includes-ring-legs-pillar-
//     drops-and-fdc-riser — ring legs down a ramp, one-storey drops to
//     pillar hydrants and the FDC's inlet riser are no standpipe stacks.
//   fire-convergence-8-combined-riser-drawn-as-sprinkler-misses-class-ii-
//     standpipe-minimum — a combined riser takes the standpipe code minimum
//     whatever service it is drawn on.
//
// First principles: standpipeFlow(n) = 500 gpm + 250 gpm per extra stack
// (NFPA 14 / SNI 03-1745): 1 stack = 500 x 3.785411784 / 60 = 31.545 L/s,
// 2 stacks = 750 gpm = 47.318 L/s. A Class II hose-station system flows
// 100 gpm = 6.309 L/s; DN40 runs 6.309e-3 / (pi 0.040^2 / 4) = 5.02 m/s
// (inside the 6 m/s cap, so velocity alone stops at DN40), DN50 runs
// 3.21 m/s — the Class II riser minimum is DN50.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart'
    show kMinSprinklerPipeDiameterMm;
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
        {ServiceType s = ServiceType.fireHydrant, EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

NetNode _box(String id, double x, int floor) => _n(id, x,
    floor: floor, role: NodeRole.fixture, c: NodeComponent.hydrantBox);

BuildingLevels _floors(int n) => BuildingLevels(
    [for (var i = 0; i < n; i++) Floor('L$i', const Length(3.5))]);

/// Round 55's fixture: a hydrant stack H0..H5 (a box per floor) and a
/// sprinkler riser S0..S5 (3 heads per floor) off one pump discharge A.
Network _stackPlusSprinklerRiser() {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('FP', 10, role: NodeRole.plant, c: NodeComponent.pump),
    _n('A', 20),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'FP'),
    _e('d', 'FP', 'A'),
    _e('ah', 'A', 'H0'),
    _e('as', 'A', 'S0', s: ServiceType.fireSprinkler),
  ];
  for (var k = 0; k < 6; k++) {
    nodes.add(_n('H$k', 30, floor: k));
    nodes.add(_n('S$k', 60, floor: k));
    nodes.add(_box('B$k', 35, k));
    edges.add(_e('b$k', 'H$k', 'B$k'));
    if (k > 0) {
      edges.add(_e('hr$k', 'H${k - 1}', 'H$k', k: EdgeKind.riser));
      edges.add(_e('sr$k', 'S${k - 1}', 'S$k',
          s: ServiceType.fireSprinkler, k: EdgeKind.riser));
    }
    for (var j = 0; j < 3; j++) {
      nodes.add(_n('Q${k}_$j', 65.0 + j * 5,
          floor: k, role: NodeRole.fixture, c: NodeComponent.sprinklerHead));
      edges
          .add(_e('q${k}_$j', 'S$k', 'Q${k}_$j', s: ServiceType.fireSprinkler));
    }
  }
  return Network(nodes: nodes, edges: edges);
}

/// The 3-level car park: L0 pump room GT -> FP -> A, one hydrant trunk
/// HR0-HR1-HR2 with a box on L0 and L1, feeding a 4-box ring on L2.
/// [ramp]: the ring drops one storey down the ramp (Q3 / Q4 on L1, the legs
/// Q2-Q3 and Q4-Q1 drawn as risers). [pillars]: a ring on L1 teed off HR1
/// feeding 4 pillar hydrants on L2 by one-storey riser drops. [fdc]: the
/// street-level FDC on L2 dropping by a riser to the L0 discharge header.
/// [secondStack]: a genuine second 3-storey stack off A (a box per floor).
Network _carPark(
    {bool ramp = false,
    bool pillars = false,
    bool fdc = false,
    bool secondStack = false}) {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('FP', 10, role: NodeRole.plant, c: NodeComponent.pump),
    _n('A', 20),
    for (var f = 0; f < 3; f++) _n('HR$f', 30, floor: f),
    _box('BX0', 35, 0),
    _box('BX1', 35, 1),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'FP'),
    _e('d', 'FP', 'A'),
    _e('ah', 'A', 'HR0'),
    _e('t1', 'HR0', 'HR1', k: EdgeKind.riser),
    _e('t2', 'HR1', 'HR2', k: EdgeKind.riser),
    _e('bx0', 'HR0', 'BX0'),
    _e('bx1', 'HR1', 'BX1'),
  ];
  // The ring: Q1..Q4 with a box on each.
  final qFloor = {
    'Q1': 2,
    'Q2': 2,
    'Q3': ramp ? 1 : 2,
    'Q4': ramp ? 1 : 2,
  };
  for (final q in ['Q1', 'Q2', 'Q3', 'Q4']) {
    final i = int.parse(q.substring(1));
    nodes.add(_n(q, 100.0 + 40 * i, floor: qFloor[q]!));
    nodes.add(_box('B$q', 100.0 + 40 * i, qFloor[q]!));
    edges.add(_e('b$q', q, 'B$q'));
  }
  edges.addAll([
    _e('hq', 'HR2', 'Q1'),
    _e('q12', 'Q1', 'Q2'),
    _e('q23', 'Q2', 'Q3', k: ramp ? EdgeKind.riser : EdgeKind.run),
    _e('q34', 'Q3', 'Q4'),
    _e('q41', 'Q4', 'Q1', k: ramp ? EdgeKind.riser : EdgeKind.run),
  ]);
  if (pillars) {
    for (var k = 0; k < 4; k++) {
      nodes.add(_n('P$k', 300.0 + 40 * k, floor: 1));
      nodes.add(_n('PT$k', 300.0 + 40 * k, floor: 2));
      nodes.add(_box('PH$k', 305.0 + 40 * k, 2));
      edges.add(_e('pd$k', 'P$k', 'PT$k', k: EdgeKind.riser));
      edges.add(_e('ph$k', 'PT$k', 'PH$k'));
      edges.add(_e('pr$k', 'P$k', 'P${(k + 1) % 4}'));
    }
    edges.add(_e('hp', 'HR1', 'P0'));
  }
  if (fdc) {
    nodes.addAll([
      _n('F', 400, floor: 2, c: NodeComponent.fireDeptConnection),
      for (var f = 0; f < 3; f++) _n('FR$f', 410, floor: f),
    ]);
    edges.addAll([
      _e('f', 'F', 'FR2'),
      _e('fr2', 'FR1', 'FR2', k: EdgeKind.riser),
      _e('fr1', 'FR0', 'FR1', k: EdgeKind.riser),
      _e('fa', 'FR0', 'A'),
    ]);
  }
  if (secondStack) {
    for (var f = 0; f < 3; f++) {
      nodes.add(_n('K$f', 500, floor: f));
      nodes.add(_box('KB$f', 505, f));
      edges.add(_e('kb$f', 'K$f', 'KB$f'));
      if (f > 0) edges.add(_e('k$f', 'K${f - 1}', 'K$f', k: EdgeKind.riser));
    }
    edges.add(_e('ak', 'A', 'K0'));
  }
  return Network(nodes: nodes, edges: edges);
}

/// Round 56 r2 - a TWO-storey building with two genuine hydrant stacks A and
/// B, a box on both floors of each. [baseFed]: the main to B leaves from A's
/// base node (GT -> FP -> A0 -> B0); else a header J feeds both bases.
Network _twinStacks({required bool baseFed}) {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('FP', 10, role: NodeRole.plant, c: NodeComponent.pump),
    if (!baseFed) _n('J', 15),
    _n('A0', 20),
    _n('A1', 20, floor: 1),
    _n('B0', 60),
    _n('B1', 60, floor: 1),
    _box('AB0', 25, 0),
    _box('AB1', 25, 1),
    _box('BB0', 65, 0),
    _box('BB1', 65, 1),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'FP'),
    if (baseFed) ...[
      _e('d', 'FP', 'A0'),
      _e('ab', 'A0', 'B0'),
    ] else ...[
      _e('d', 'FP', 'J'),
      _e('ja', 'J', 'A0'),
      _e('jb', 'J', 'B0'),
    ],
    _e('ra', 'A0', 'A1', k: EdgeKind.riser),
    _e('rb', 'B0', 'B1', k: EdgeKind.riser),
    _e('ab0', 'A0', 'AB0'),
    _e('ab1', 'A1', 'AB1'),
    _e('bb0', 'B0', 'BB0'),
    _e('bb1', 'B1', 'BB1'),
  ];
  return Network(nodes: nodes, edges: edges);
}

Network _flipShuffle(Network net, math.Random rnd) {
  final edges = [
    for (final e in net.edges)
      rnd.nextBool()
          ? NetEdge(
              id: e.id,
              fromId: e.toId,
              toId: e.fromId,
              service: e.service,
              kind: e.kind)
          : e,
  ]..shuffle(rnd);
  final nodes = [...net.nodes]..shuffle(rnd);
  return Network(nodes: nodes, edges: edges);
}

void main() {
  group('regression-feedsOwnOutlet-walks-past-first-hose-outlet', () {
    test('a box ON a cross-tie off the sprinkler riser still counts it (2)',
        () {
      final base = _stackPlusSprinklerRiser();
      Network withBox({required bool tieToStack}) => Network(nodes: [
            ...base.nodes,
            _box('X', 70, 3),
          ], edges: [
            ...base.edges,
            _e('x', 'S3', 'X'),
            if (tieToStack) _e('xh', 'X', 'H3'),
          ]);
      // The box on a stub (Round 55) and on a cross-tie to H3 both make the
      // sprinkler riser a stack fed above its base: 2 parallel stacks.
      expect(drawnStandpipeRiserCount(withBox(tieToStack: false)), 2);
      expect(drawnStandpipeRiserCount(withBox(tieToStack: true)), 2);
      // 750 gpm = 750 x 3.785411784 / 60 = 47.318 L/s, never 31.5.
      expect(standpipeFlow(2).inLitersPerSecond,
          closeTo(750 * 3.785411784 / 60, 1e-9));
    });

    test('a BARE top-floor tie H5 -> S5 still counts one stack', () {
      final base = _stackPlusSprinklerRiser();
      final net = Network(
          nodes: base.nodes, edges: [...base.edges, _e('tie', 'H5', 'S5')]);
      expect(drawnStandpipeRiserCount(net), 1);
    });
  });

  group('fire-convergence-8 stack count: ring legs, pillar drops, FDC', () {
    test('the base car park counts one stack', () {
      expect(drawnStandpipeRiserCount(_carPark()), 1);
    });

    test(
        'ring legs down the ramp, pillar drops and the FDC riser are no '
        'stack: 1 (500 gpm, 31.545 L/s)', () {
      for (final (ramp, pillars, fdc) in [
        (true, false, false),
        (false, true, false),
        (false, false, true),
        (true, true, true),
      ]) {
        final net = _carPark(ramp: ramp, pillars: pillars, fdc: fdc);
        final n = drawnStandpipeRiserCount(net);
        expect(n, 1, reason: 'ramp=$ramp pillars=$pillars fdc=$fdc');
        expect(standpipeFlow(n).inLitersPerSecond,
            closeTo(500 * 3.785411784 / 60, 1e-9));
      }
    });

    test(
        'regression-twin-stack-base-fed-counts-one: two 2-storey stacks '
        'count 2 fed from a stack base or a header (750 gpm)', () {
      final rnd = math.Random(5602);
      for (final baseFed in [true, false]) {
        expect(drawnStandpipeRiserCount(_twinStacks(baseFed: baseFed)), 2,
            reason: 'baseFed=$baseFed');
        for (var t = 0; t < 50; t++) {
          final net = _flipShuffle(_twinStacks(baseFed: baseFed), rnd);
          expect(drawnStandpipeRiserCount(net), 2,
              reason: 'baseFed=$baseFed trial $t');
        }
      }
      // 750 gpm = 750 x 3.785411784 / 60 = 47.318 L/s.
      expect(standpipeFlow(2).inLitersPerSecond,
          closeTo(750 * 3.785411784 / 60, 1e-9));
    });

    test('a genuine second stack still counts (2)', () {
      expect(drawnStandpipeRiserCount(_carPark(secondStack: true)), 2);
      expect(
          drawnStandpipeRiserCount(_carPark(
              ramp: true, pillars: true, fdc: true, secondStack: true)),
          2);
    });

    test(
        'sizing: the pump discharge, trunk and ring carry 31.545 L/s, never '
        'the phantom 63 / 79 L/s', () {
      for (final (ramp, pillars) in [(true, false), (false, true)]) {
        final net = _carPark(ramp: ramp, pillars: pillars, fdc: true);
        final r = autoSizeNetwork(
          net,
          const SizingContext(),
          leafDemand: const {ServiceType.fireHydrant: FlowRate(0.005)},
          hydrantDesignFlow: standpipeFlow(drawnStandpipeRiserCount(net)),
          building: _floors(3),
        );
        // d = sqrt(4 x 0.031545 / (pi x 6)) = 0.0818 m => DN100 (4.02 m/s).
        for (final id in ['d', 't1', 't2']) {
          expect(r[id]!.flow.inLitersPerSecond, closeTo(31.545, 1e-3),
              reason: '$id ramp=$ramp');
          expect(r[id]!.diameter.inMillimeters, 100, reason: id);
        }
        for (final e in r.values) {
          expect(e.flow.inLitersPerSecond, lessThan(31.546),
              reason: '${e.edgeId} ramp=$ramp pillars=$pillars');
        }
      }
    });

    test(
        'seeded property: every variant, any drawing direction / order, '
        'counts 1 (+1 with a genuine second stack)', () {
      final rnd = math.Random(5601);
      for (var t = 0; t < 200; t++) {
        final second = rnd.nextBool();
        final net = _flipShuffle(
            _carPark(
                ramp: rnd.nextBool(),
                pillars: rnd.nextBool(),
                fdc: rnd.nextBool(),
                secondStack: second),
            rnd);
        expect(drawnStandpipeRiserCount(net), second ? 2 : 1,
            reason: 'trial $t');
      }
    });
  });

  group('fire-convergence-8 combined riser drawn as sprinkler', () {
    // An 18-storey Class II zone: GT -> FP -> A -> riser R0..R17; on every
    // floor a hose reel teed off the riser by a hydrant pipe and a sprinkler
    // branch (two heads). The riser is drawn on [riserService].
    Network tower(ServiceType riserService) {
      final nodes = <NetNode>[
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('FP', 10, role: NodeRole.plant, c: NodeComponent.pump),
        _n('A', 20),
      ];
      final edges = <NetEdge>[
        _e('g', 'GT', 'FP'),
        _e('d', 'FP', 'A'),
        _e('ar', 'A', 'R0', s: riserService),
      ];
      for (var f = 0; f < 18; f++) {
        nodes.add(_n('R$f', 30, floor: f));
        nodes.add(_n('HR$f', 40,
            floor: f, role: NodeRole.fixture, c: NodeComponent.hoseReel));
        edges.add(_e('h$f', 'R$f', 'HR$f'));
        for (var j = 0; j < 2; j++) {
          nodes.add(_n('SH${f}_$j', 60.0 + 5 * j,
              floor: f,
              role: NodeRole.fixture,
              c: NodeComponent.sprinklerHead));
          edges.add(_e('s${f}_$j', 'R$f', 'SH${f}_$j',
              s: ServiceType.fireSprinkler));
        }
        if (f > 0) {
          edges.add(
              _e('r$f', 'R${f - 1}', 'R$f', s: riserService, k: EdgeKind.riser));
        }
      }
      return Network(nodes: nodes, edges: edges);
    }

    Map<String, EdgeSizing> size(Network net) => autoSizeNetwork(
          net,
          const SizingContext(),
          leafDemand: const {
            ServiceType.fireHydrant: FlowRate(0.005),
            ServiceType.fireSprinkler: FlowRate(0.001),
          },
          sprinklerDemandCap: const FlowRate(0.005),
          hydrantDesignFlow: standpipeFlow(drawnStandpipeRiserCount(net)),
          building: _floors(18),
        );

    test(
        'the riser sizes DN50 (Class II minimum) on either service, with '
        'identical flows and bores everywhere', () {
      final hyd = size(tower(ServiceType.fireHydrant));
      final spr = size(tower(ServiceType.fireSprinkler));
      // 100 gpm = 100 x 3.785411784 / 60 = 6.309 L/s.
      const q = 100 * 3.785411784 / 60;
      for (var f = 1; f < 18; f++) {
        expect(spr['r$f']!.flow.inLitersPerSecond, closeTo(q, 1e-6),
            reason: 'r$f');
        expect(spr['r$f']!.diameter.inMillimeters, 50, reason: 'r$f');
        expect(hyd['r$f']!.diameter.inMillimeters, 50, reason: 'r$f');
      }
      for (final id in hyd.keys) {
        expect(spr[id]!.diameter.inMillimeters,
            hyd[id]!.diameter.inMillimeters,
            reason: id);
        expect(spr[id]!.flow.cubicMetersPerSecond,
            closeTo(hyd[id]!.flow.cubicMetersPerSecond, 1e-12),
            reason: id);
      }
      // A pure sprinkler branch keeps the 25 mm sprinkler floor.
      expect(spr['s0_0']!.diameter.inMillimeters, 25);
    });

    test('fireMinimumDiameter: a standpipe sprinkler pipe takes the hydrant '
        'floors of its class', () {
      const riser = NetEdge(
          id: 'e',
          fromId: 'a',
          toId: 'b',
          service: ServiceType.fireSprinkler,
          kind: EdgeKind.riser);
      const run = NetEdge(
          id: 'e', fromId: 'a', toId: 'b', service: ServiceType.fireSprinkler);
      double mm(NetEdge e, {bool hose = false, bool sp = false}) =>
          fireMinimumDiameter(e, hoseStation: hose, standpipe: sp)!
              .inMillimeters;
      expect(mm(riser), kMinSprinklerPipeDiameterMm);
      expect(mm(riser, sp: true), kMinRiserDiameterMm);
      expect(mm(riser, sp: true, hose: true), kMinClassIIRiserDiameterMm);
      expect(mm(run, sp: true), kMinHydrantBranchDiameterMm);
      expect(mm(run, sp: true, hose: true), kMinHoseStationBranchDiameterMm);
    });
  });
}
